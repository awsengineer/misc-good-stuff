#!/bin/bash
# Backs up local directories and files to S3 using sync/cp.
# Supports dry-run mode, exclude patterns, and cron-friendly PATH setup.
#
# Usage: ./backup-laptop-to-s3.sh [--dry-run]
#
# Cron example (daily at 13:00 system local time):
#   0 13 * * * /path/to/backup-laptop-to-s3.sh
# Note: macOS cron does NOT honor CRON_TZ — jobs always run in system local time.
#
# Note: --delete is used with s3 sync, meaning files deleted locally will also
# be deleted from S3. If you want to keep deleted files in S3, remove --delete.

# --- Configuration ---
S3_BUCKET="s3://YOUR-BUCKET-NAME"
AWS_PROFILE="default"

STORAGE_CLASS="STANDARD"  # Options: STANDARD, INTELLIGENT_TIERING, STANDARD_IA, ONEZONE_IA, GLACIER_IR, GLACIER, DEEP_ARCHIVE
LOG_FILE="$HOME/.local/log/s3-backup.log"

# S3 health-check endpoint — set to your bucket's region for faster checks
S3_HEALTH_URL="https://s3.amazonaws.com"

EXCLUDE_PATTERNS=(
  "*/node_modules/*"
  "*/.git/*"
  "*/.DS_Store"
  "*/.cache/*"
  "*/credentials"
  "*/sso/cache/*"
  # Add your own patterns below
)

BACKUP_DIRS=(
  "$HOME/bin"
  "$HOME/Documents"
  "$HOME/.bashrc"
  # Add your own directories/files below
)
# --- End Configuration ---

set -euo pipefail
# Cron uses a minimal PATH — add common binary locations
export PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

# macOS default soft FD limit is 256; aws s3 sync on deep trees
# can blow past it with Errno 24 "Too many open files".
ulimit -n 4096

mkdir -p "$(dirname "$LOG_FILE")"

# Log rotation — keep last 500 lines
tail -n 500 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE" 2>/dev/null || true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Verify aws CLI is available
if ! command -v aws &>/dev/null; then
  log "ERROR: aws CLI not found in PATH ($PATH)"
  exit 1
fi

# Build excludes as an array (avoids eval)
EXCLUDES=()
for p in "${EXCLUDE_PATTERNS[@]}"; do
  EXCLUDES+=(--exclude "$p")
done

DRY_RUN=""
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="--dryrun"

if [[ ${#BACKUP_DIRS[@]} -eq 0 ]]; then
  log "ERROR: No directories configured. Edit BACKUP_DIRS in $0"
  exit 1
fi

START_TIME=$(date +%s)
log "=== S3 backup started ${DRY_RUN:+(dry run)} ==="

# Network preflight — avoid FAIL spam when laptop is offline
if ! curl -fsS --max-time 5 "$S3_HEALTH_URL" >/dev/null 2>&1; then
  log "No network connectivity to S3, skipping run"
  exit 0
fi

FAILED=0
SUCCEEDED=0
SKIPPED=0

for dir in "${BACKUP_DIRS[@]}"; do
  if [[ -f "$dir" ]]; then
    prefix=$(basename "$dir")
    log "Copying $dir -> $S3_BUCKET/$prefix"
    if aws s3 cp "$dir" "$S3_BUCKET/$prefix" \
      --profile "$AWS_PROFILE" \
      --storage-class "$STORAGE_CLASS" \
      --no-progress \
      $DRY_RUN >> "$LOG_FILE" 2>&1; then
      SUCCEEDED=$((SUCCEEDED + 1))
    else
      log "FAIL: $dir"
      FAILED=$((FAILED + 1))
    fi
    continue
  fi

  if [[ ! -d "$dir" ]]; then
    log "SKIP: $dir (not found)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  prefix=$(basename "$dir")
  log "Syncing $dir -> $S3_BUCKET/$prefix"
  if aws s3 sync "$dir" "$S3_BUCKET/$prefix" \
    --profile "$AWS_PROFILE" \
    --storage-class "$STORAGE_CLASS" \
    --delete \
    --no-progress \
    "${EXCLUDES[@]}" \
    $DRY_RUN >> "$LOG_FILE" 2>&1; then
    SUCCEEDED=$((SUCCEEDED + 1))
  else
    log "FAIL: $dir"
    FAILED=$((FAILED + 1))
  fi
done

ELAPSED=$(( $(date +%s) - START_TIME ))
log "=== S3 backup finished: ${SUCCEEDED} ok, ${FAILED} failed, ${SKIPPED} skipped (${ELAPSED}s) ==="
exit $((FAILED > 0 ? 1 : 0))
