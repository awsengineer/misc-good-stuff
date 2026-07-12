# Build an OpenVPN server on Linux and connect a MacBook

*Step-by-step educational material*

Learn the networking and security concepts, build a certificate-authenticated full-tunnel VPN on Ubuntu or Debian, create a macOS profile, and prove that routing, DNS and encryption work.

| | |
|---|---|
| **Server** | Ubuntu or Debian Linux |
| **VPN software** | OpenVPN Community Edition |
| **Mac client** | OpenVPN Connect 3.x |
| **Authentication** | X.509 certificates + tls-crypt |

> Set your values once in the two variable files described in [Set your variables](#2-set-your-variables) — one for the Linux server, one for the Mac client. Every command below sources one of those files, so nothing here needs manual find-and-replace. Do not paste commands into production before understanding their effect.

## Contents

- [Learning goals](#learning-goals)
- [1. Core concepts](#1-core-concepts)
- [2. Set your variables](#2-set-your-variables)
- [3. Prepare and inspect Linux](#3-prepare-and-inspect-linux)
- [4. Install OpenVPN and Easy-RSA](#4-install-openvpn-and-easy-rsa)
- [5. Build the certificate authority and identities](#5-build-the-certificate-authority-and-identities)
- [6. Configure the OpenVPN server](#6-configure-the-openvpn-server)
- [7. Configure Linux forwarding and NAT](#7-configure-linux-forwarding-and-nat)
- [8. Open only the network perimeter you need](#8-open-only-the-network-perimeter-you-need)
- [9. Build a self-contained Mac client profile](#9-build-a-self-contained-mac-client-profile)
- [10. Transfer the profile securely](#10-transfer-the-profile-securely)
- [11. Import the profile into OpenVPN Connect](#11-import-the-profile-into-openvpn-connect)
- [12. Start services and verify end to end](#12-start-services-and-verify-end-to-end)
- [13. Handle a dynamic MacBook public IP](#13-handle-a-dynamic-macbook-public-ip)
- [14. Operate and maintain the VPN securely](#14-operate-and-maintain-the-vpn-securely)
- [15. Troubleshoot systematically](#15-troubleshoot-systematically)
- [Glossary and official sources](#glossary-and-official-sources)

## Learning goals

By the end, you should be able to explain and implement:

- [ ] How an encrypted tunnel differs from ordinary internet routing.
- [ ] Why a certificate authority, server certificate and client certificate are separate.
- [ ] How the Mac reaches the public VPN endpoint and receives a private tunnel address.
- [ ] Why Linux forwarding and source NAT are required for a full-tunnel VPN.
- [ ] How host firewalls and cloud security groups protect different layers.
- [ ] How to assemble, transfer and import a self-contained `.ovpn` profile.
- [ ] How to verify identity, encryption, routes, DNS and public egress.
- [ ] How to handle a MacBook whose physical public IP changes.
- [ ] How to revoke a lost client and renew certificates.

> **Scope:** Commands target Ubuntu or Debian with systemd and the `iptables` compatibility interface backed by nftables. Adapt package management and firewall persistence for other Linux distributions.

## 1. Core concepts

### The two layers of traffic

OpenVPN wraps an original packet inside an encrypted UDP packet:

```
[MacBook]                [Public network]              [Linux OpenVPN]              [Destination]
Original packet    →     Encrypted UDP packet     →     Decrypts,               →    Sees the VPN
enters a virtual          travels to                     authenticates and            server's public
tunnel interface          $VPN_ENDPOINT                  forwards                     egress identity
```

| Term | Meaning |
|---|---|
| Outer packet | The encrypted UDP packet between the Mac's physical public address and the server's public endpoint. |
| Inner packet | The original application traffic carried inside the tunnel. |
| `tun` interface | A virtual Layer 3 network interface carrying IP packets. |
| Full tunnel | The Mac routes ordinary IPv4 internet traffic and DNS through the VPN. |
| Split tunnel | Only selected private networks use the VPN; other traffic exits locally. |
| Forwarding | Linux moves packets between the VPN interface and its external interface. |
| Source NAT | Linux rewrites VPN-client source addresses so return traffic knows how to come back. |

### Authentication and encryption

- The **certificate authority (CA)** signs identities you trust.
- The **server certificate** lets the Mac verify it reached the intended server.
- The **client certificate** lets the server verify this Mac is authorized.
- **TLS** protects the control channel where peers authenticate and negotiate keys.
- **AEAD data ciphers**, such as AES-GCM and ChaCha20-Poly1305, encrypt and authenticate tunnel data.
- **`tls-crypt`** adds a shared key that encrypts and authenticates OpenVPN control packets before the normal TLS exchange.

## 2. Set your variables

This guide runs on two machines, so it uses two small variable files instead of inline placeholders:

- **Linux server:** `/etc/openvpn/vpn-vars.env` — root-owned, mode `0600`.
- **Mac client:** `~/.config/openvpn/vpn-vars.env` — mode `0600`.

Every command block from here on starts with a `source` line that loads the file for that machine, so each block is copy-paste-safe on its own. Four values — `VPN_ENDPOINT`, `VPN_PORT`, `SERVER_USER`, `CLIENT_PROFILE_FILE` — exist in **both** files and must match; nothing enforces that automatically, so update both when you change one.

Values shown as `CHANGE_ME` are yours to decide and have no safe default. Everything else already has a sensible default you can keep or override.

> **Avoid address overlap:** If the VPN subnet overlaps the Mac's Wi-Fi, office, hotspot, container or cloud network, routing becomes ambiguous. Choose a private range not already used in the environments where the Mac will connect.

### Linux server variables

| Variable | What to choose | Default in the file below |
|---|---|---|
| `VPN_ENDPOINT` | A stable DNS name or static public address for the Linux server. | `CHANGE_ME` |
| `VPN_PORT` | A UDP listener port. | `1194` (the conventional OpenVPN port) |
| `VPN_NETWORK_ADDRESS` | An unused private network address that does not overlap the Mac's common local networks. | `CHANGE_ME` |
| `VPN_NETMASK` | The matching subnet mask. | `CHANGE_ME` |
| `VPN_SUBNET_CIDR` | The same VPN network in CIDR notation, used by firewall rules. | `CHANGE_ME` |
| `CA_NAME` | A simple internal CA name. | `home-ca` |
| `SERVER_CERT_NAME` | A simple internal certificate name. | `vpn-server` |
| `CLIENT_CERT_NAME` | A unique name for the first client device. | `laptop-client` |
| `CLIENT_PROFILE_FILE` | The filename (without `.ovpn`) for that client's exported profile. | `laptop-client` |
| `DNS_RESOLVER_1` | A primary resolver reachable through the tunnel. | `CHANGE_ME` |
| `DNS_RESOLVER_2` | A secondary resolver reachable through the tunnel, pushed alongside the first. | `CHANGE_ME` |
| `SERVER_USER` | An existing unprivileged Linux account used to stage the profile for transfer. | `CHANGE_ME` |
| `SERVER_USER_GROUP` | That account's primary group. Look it up with `id -gn "$SERVER_USER"` rather than guessing. | `CHANGE_ME` |

The external interface (`EXTERNAL_INTERFACE` in the original plan) is deliberately not stored here — every script below discovers it live with `ip -4 route show default`, so it can never go stale.

*Run on Linux*

```bash
sudo install -d -m 0700 /etc/openvpn

sudo tee /etc/openvpn/vpn-vars.env >/dev/null <<'VARS'
VPN_ENDPOINT="CHANGE_ME"
VPN_PORT="1194"
VPN_NETWORK_ADDRESS="CHANGE_ME"
VPN_NETMASK="CHANGE_ME"
VPN_SUBNET_CIDR="CHANGE_ME"
CA_NAME="home-ca"
SERVER_CERT_NAME="vpn-server"
CLIENT_CERT_NAME="laptop-client"
CLIENT_PROFILE_FILE="laptop-client"
DNS_RESOLVER_1="CHANGE_ME"
DNS_RESOLVER_2="CHANGE_ME"
SERVER_USER="CHANGE_ME"
SERVER_USER_GROUP="CHANGE_ME"
VARS

sudo chown root:root /etc/openvpn/vpn-vars.env
sudo chmod 0600 /etc/openvpn/vpn-vars.env
```

Edit the values (`sudoedit /etc/openvpn/vpn-vars.env`), then load and validate them:

```bash
source /etc/openvpn/vpn-vars.env

missing=""
[ "$VPN_ENDPOINT" != "CHANGE_ME" ] || missing="$missing VPN_ENDPOINT"
[ "$VPN_NETWORK_ADDRESS" != "CHANGE_ME" ] || missing="$missing VPN_NETWORK_ADDRESS"
[ "$VPN_NETMASK" != "CHANGE_ME" ] || missing="$missing VPN_NETMASK"
[ "$VPN_SUBNET_CIDR" != "CHANGE_ME" ] || missing="$missing VPN_SUBNET_CIDR"
[ "$DNS_RESOLVER_1" != "CHANGE_ME" ] || missing="$missing DNS_RESOLVER_1"
[ "$DNS_RESOLVER_2" != "CHANGE_ME" ] || missing="$missing DNS_RESOLVER_2"
[ "$SERVER_USER" != "CHANGE_ME" ] || missing="$missing SERVER_USER"
[ "$SERVER_USER_GROUP" != "CHANGE_ME" ] || missing="$missing SERVER_USER_GROUP"

if [ -n "$missing" ]; then
  echo "Edit /etc/openvpn/vpn-vars.env and set:$missing" >&2
  exit 1
fi
echo "Linux variables loaded."
```

### Mac client variables

| Variable | What to choose | Default in the file below |
|---|---|---|
| `VPN_ENDPOINT` | Must match the Linux file. | `CHANGE_ME` |
| `VPN_PORT` | Must match the Linux file. | `1194` |
| `SERVER_USER` | Must match the Linux file. | `CHANGE_ME` |
| `CLIENT_PROFILE_FILE` | Must match the Linux file. | `laptop-client` |
| `PROFILE_DISPLAY_NAME` | The name shown for this profile inside OpenVPN Connect. | `Home VPN` |
| `VPN_SECURITY_GROUP_ID` | The AWS security group that guards the VPN listener. | `CHANGE_ME` |
| `AWS_REGION` | The AWS region of that security group. | `CHANGE_ME` |
| `SSM_INSTANCE_ID` | The EC2 instance ID of the Linux server, used to reach it via AWS Systems Manager instead of SSH. | `CHANGE_ME` |
| `TRUSTED_IP_CHECK_URL` | A public IPv4-echo service you trust, used to discover the Mac's current physical IP. | `CHANGE_ME` |
| `TEST_IPV4_DESTINATION` | Any routable public IPv4 address you're comfortable testing a route to. | `CHANGE_ME` |
| `TEST_HOSTNAME` | A hostname to test DNS and HTTPS against. | `example.com` (IANA-reserved for documentation and test use) |

*Run on the Mac*

```bash
install -d -m 0700 "$HOME/.config/openvpn"

tee "$HOME/.config/openvpn/vpn-vars.env" >/dev/null <<'VARS'
VPN_ENDPOINT="CHANGE_ME"
VPN_PORT="1194"
SERVER_USER="CHANGE_ME"
CLIENT_PROFILE_FILE="laptop-client"
PROFILE_DISPLAY_NAME="Home VPN"
VPN_SECURITY_GROUP_ID="CHANGE_ME"
AWS_REGION="CHANGE_ME"
SSM_INSTANCE_ID="CHANGE_ME"
TRUSTED_IP_CHECK_URL="CHANGE_ME"
TEST_IPV4_DESTINATION="CHANGE_ME"
TEST_HOSTNAME="example.com"
VARS

chmod 0600 "$HOME/.config/openvpn/vpn-vars.env"
```

Edit the values, then load and validate them:

```bash
source "$HOME/.config/openvpn/vpn-vars.env"

missing=""
[ "$VPN_ENDPOINT" != "CHANGE_ME" ] || missing="$missing VPN_ENDPOINT"
[ "$SERVER_USER" != "CHANGE_ME" ] || missing="$missing SERVER_USER"
[ "$VPN_SECURITY_GROUP_ID" != "CHANGE_ME" ] || missing="$missing VPN_SECURITY_GROUP_ID"
[ "$AWS_REGION" != "CHANGE_ME" ] || missing="$missing AWS_REGION"
[ "$SSM_INSTANCE_ID" != "CHANGE_ME" ] || missing="$missing SSM_INSTANCE_ID"
[ "$TRUSTED_IP_CHECK_URL" != "CHANGE_ME" ] || missing="$missing TRUSTED_IP_CHECK_URL"
[ "$TEST_IPV4_DESTINATION" != "CHANGE_ME" ] || missing="$missing TEST_IPV4_DESTINATION"

if [ -n "$missing" ]; then
  echo "Edit ~/.config/openvpn/vpn-vars.env and set:$missing" >&2
  exit 1
fi
echo "Mac variables loaded."
```

### Reach Linux without SSH: an SSM helper function

Every `*Run on Linux*` block from here on is written to be piped into the function below, run from the Mac. It uses AWS Systems Manager Run Command instead of SSH: no inbound port, no key pair, no dependency on the Mac's changing public IP.

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux() {
  : "${SSM_INSTANCE_ID:?}" "${AWS_REGION:?}"
  local payload params_file cmd_id invocation_file rc

  payload="$(base64 | tr -d '\n')" || return 1
  params_file="$(mktemp)" || return 1
  printf '{"commands":["echo %s | base64 -d | bash -s"]}' "$payload" > "$params_file"

  cmd_id="$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$SSM_INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters "file://$params_file" \
    --query 'Command.CommandId' --output text 2>&1)" || { rm -f "$params_file"; printf '%s\n' "$cmd_id" >&2; return 1; }
  rm -f "$params_file"

  aws ssm wait command-executed \
    --region "$AWS_REGION" \
    --command-id "$cmd_id" \
    --instance-id "$SSM_INSTANCE_ID" 2>/dev/null

  invocation_file="$(mktemp)" || return 1
  if ! aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$cmd_id" \
    --instance-id "$SSM_INSTANCE_ID" > "$invocation_file" 2>&1; then
    cat "$invocation_file" >&2
    rm -f "$invocation_file"
    return 1
  fi

  jq -j '.StandardOutputContent' < "$invocation_file"
  jq -j '.StandardErrorContent'  < "$invocation_file" >&2
  rc="$(jq -r '.ResponseCode' < "$invocation_file")"
  rm -f "$invocation_file"
  return "$rc"
}
```

It reads a script from stdin, ships it base64-encoded inside a Run Command parameter file, waits for the command to finish, then fetches the result — so heredocs, quotes and `$(...)` all survive with no escaping, and `ssm_linux`'s own exit code is the real remote exit code (`ResponseCode`, reported natively by the API). Needs `jq` locally (already used elsewhere in this guide).

Smoke-test it:

```bash
echo 'uname -a; whoami' | ssm_linux
echo "exit status: $?"
```

> **Why this shape, not a live session — verified against a live instance:** an earlier draft of this helper used `aws ssm start-session --document-name AWS-StartInteractiveCommand`, which opens a live streamed session. Direct testing against a real EC2 instance found a real race condition in that approach: the session can close before the last chunk of output finishes arriving, and this happened unpredictably — including truncating a ~5 KB payload mid-line in roughly 1 run out of 5, even with a trailing `sleep` added to try to outlast it. Worse, a failing remote command was indistinguishable from a successful one: `aws ssm start-session` always exited `0` locally regardless of what ran remotely. `send-command` + `AWS-RunShellScript` doesn't stream — the instance writes its result server-side and this function fetches it once with `get-command-invocation` — which was reliable across every repeated test (large payloads came back byte-identical across 3 separate runs) and reports exit status natively, no workaround needed. The tradeoff: each call is a few seconds slower than a live session (submit, poll, fetch are three API round trips instead of one), which you'll notice most on the frequent small commands in the next few sections.

> **Identity note:** commands run as `root` on the instance (Run Command's default), so every `sudo` already written in this guide is a no-op there — harmless, but you won't see a permission prompt where you might expect one. This is a different identity from `$SERVER_USER`, which section 10 uses only to stage the transferred `.ovpn` profile for `scp`.

> **Prerequisites:** locally, AWS CLI v2 and `jq`; IAM permission for `ssm:SendCommand`, `ssm:GetCommandInvocation`, and `ssm:ListCommandInvocations` on `$SSM_INSTANCE_ID`. On the instance, the SSM Agent registered and running — standard on EC2 Ubuntu AMIs when the instance has an IAM instance profile granting SSM (for example `AmazonSSMManagedInstanceCore`). Output is capped at 24,000 characters per stream (`StandardOutputContent`/`StandardErrorContent`) — well above anything in this guide; the largest single payload here is the ~5 KB base64 client profile in section 9.

> **What this cannot do:** a few steps in section 5 and section 14 unlock the CA private key and prompt for its passphrase. A non-interactive command has no way to answer that prompt, so those steps are marked **Run interactively** and use a live session instead — `aws ssm start-session --target "$SSM_INSTANCE_ID" --region "$AWS_REGION"` — with no document, so it drops you into an ordinary shell. (This is the one place a live session is actually the right tool: you're typing a passphrase yourself, so the race condition above doesn't apply — there's no unattended output to lose.) The same applies to `sudoedit /etc/openvpn/vpn-vars.env` above: open that plain session, don't pipe an editor invocation through `ssm_linux`.

## 3. Prepare and inspect Linux

Do not change the server until you know its operating system, default interface, firewall manager, existing listeners and forwarding state.

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
cat /etc/os-release
uname -a
ip -4 route show default
sudo ss -lntu
sysctl net.ipv4.ip_forward
sudo ufw status verbose 2>/dev/null || true
sudo firewall-cmd --state 2>/dev/null || true
sudo nft list ruleset
sudo iptables --version
REMOTE
```

Find the external interface deterministically:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
EXT_IF="$(ip -4 route show default | awk 'NR == 1 {print $5}')"
printf 'External interface: %s\n' "$EXT_IF"
REMOTE
```

### Create a configuration backup

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
sudo install -d -m 0700 "/var/backups/openvpn-$STAMP"

if sudo test -e /etc/openvpn; then
  sudo tar -C / -czf "/var/backups/openvpn-$STAMP/etc-openvpn.tar.gz" etc/openvpn
fi
REMOTE
```

> **Use the server's existing firewall system:** If UFW or firewalld is active, implement forwarding and NAT using that system's supported persistence model. The later iptables/systemd method is appropriate when neither manager owns the host firewall or when you have deliberately integrated it with existing Docker rules.

## 4. Install OpenVPN and Easy-RSA

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
sudo apt-get update
sudo apt-get install -y openvpn easy-rsa

openvpn --version | head -n 1
dpkg-query -W openvpn easy-rsa
REMOTE
```

`openvpn` provides the VPN daemon. `easy-rsa` provides scripts for creating and maintaining a small X.509 public key infrastructure.

## 5. Build the certificate authority and identities

### Create the Easy-RSA workspace

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env

sudo make-cadir /etc/openvpn/easy-rsa
sudo chown -R "$(id -un)":"$(id -gn)" /etc/openvpn/easy-rsa
cd /etc/openvpn/easy-rsa

./easyrsa init-pki
REMOTE
```

### Create the CA, and sign the server and client certificates

**Run interactively — this cannot be piped.** `build-ca` sets a CA private-key passphrase, and every signing operation below (`build-server-full`, `build-client-full`, `gen-crl`) unlocks that same CA key and re-prompts for it. A piped, non-interactive command has no way to answer that prompt. Open one plain session and run all of the following in it, in order:

```bash
source ~/.config/openvpn/vpn-vars.env
aws ssm start-session --target "$SSM_INSTANCE_ID" --region "$AWS_REGION"
```

Inside that session:

```bash
source /etc/openvpn/vpn-vars.env
cd /etc/openvpn/easy-rsa

EASYRSA_REQ_CN="$CA_NAME" ./easyrsa build-ca
```

This prompts for a CA passphrase. Protect it: the CA private key can authorize new clients. For a higher-security design, keep the CA offline and transfer only certificate signing requests.

```bash
./easyrsa build-server-full "$SERVER_CERT_NAME" nopass
```

`nopass` here means the server's own key is unencrypted — systemd must start OpenVPN without someone entering a password at every reboot, so its filesystem permissions matter instead. Signing this certificate still unlocks the CA key, so it still prompts for the CA passphrase above.

Choose one of these models for the Mac client certificate:

```bash
# Safer for a portable laptop: prompts for a private-key password.
./easyrsa build-client-full "$CLIENT_CERT_NAME"

# More convenient autologin profile: private key has no password.
# Understand that possession of the profile is then sufficient to connect.
./easyrsa build-client-full "$CLIENT_CERT_NAME" nopass
```

Run only one of those commands for a given name. Both still prompt for the CA passphrase.

```bash
./easyrsa gen-crl
```

This also unlocks the CA key. You can end the interactive session after this line.

### Create control-channel material

Back on the Mac — this doesn't touch the CA key, so it goes through the helper:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
openvpn --genkey secret /etc/openvpn/easy-rsa/pki/tls-crypt.key
REMOTE
```

### Install the server files

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env
cd /etc/openvpn/easy-rsa

sudo install -d -m 0755 /etc/openvpn/server

sudo install -m 0644 pki/ca.crt /etc/openvpn/server/ca.crt
sudo install -m 0644 "pki/issued/$SERVER_CERT_NAME.crt" /etc/openvpn/server/server.crt
sudo install -m 0600 "pki/private/$SERVER_CERT_NAME.key" /etc/openvpn/server/server.key
sudo install -m 0644 pki/crl.pem /etc/openvpn/server/crl.pem
sudo install -m 0600 pki/tls-crypt.key /etc/openvpn/server/tls-crypt.key
REMOTE
```

### Verify the certificate chain and purposes

Verifying a certificate needs no private key, so this is safe to pipe:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env
cd /etc/openvpn/easy-rsa

openssl verify \
  -CAfile pki/ca.crt \
  "pki/issued/$SERVER_CERT_NAME.crt" \
  "pki/issued/$CLIENT_CERT_NAME.crt"

openssl x509 -in "pki/issued/$SERVER_CERT_NAME.crt" -noout -subject -issuer -dates -purpose
openssl x509 -in "pki/issued/$CLIENT_CERT_NAME.crt" -noout -subject -issuer -dates -purpose
REMOTE
```

## 6. Configure the OpenVPN server

Generate `/etc/openvpn/server/server.conf` directly from your variables — no manual editing, no placeholders left behind.

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env

sudo tee /etc/openvpn/server/server.conf >/dev/null <<CONF
port ${VPN_PORT}
proto udp4
dev tun0
topology subnet
server ${VPN_NETWORK_ADDRESS} ${VPN_NETMASK}

ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
crl-verify /etc/openvpn/server/crl.pem
dh none
ecdh-curve prime256v1
tls-crypt /etc/openvpn/server/tls-crypt.key
tls-version-min 1.2
tls-cert-profile preferred
verify-client-cert require
remote-cert-eku "TLS Web Client Authentication"
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256

# Full-tunnel IPv4 and DNS.
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS ${DNS_RESOLVER_1}"
push "dhcp-option DNS ${DNS_RESOLVER_2}"

# Use this for an IPv4-only VPN design to prevent IPv6 bypass.
push "block-ipv6"

keepalive 10 120
explicit-exit-notify 1
persist-key
persist-tun
user nobody
group nogroup
verb 3
CONF

sudo chown root:root /etc/openvpn/server/server.conf
sudo chmod 0600 /etc/openvpn/server/server.conf
REMOTE
```

Because the inner `<<CONF` heredoc is unquoted, `${VPN_PORT}` and friends expand to your actual values on the remote side before the file is written — read it back with `echo 'sudo cat /etc/openvpn/server/server.conf' | ssm_linux` to confirm. (The outer `<<'REMOTE'` heredoc is quoted deliberately, so nothing in this block expands locally on the Mac before it's shipped.)

### Full tunnel versus split tunnel

- Keep `redirect-gateway` for a full tunnel.
- For split tunnel, remove it and push only explicit routes, such as `push "route <PRIVATE_NETWORK> <PRIVATE_NETMASK>"`, where `<PRIVATE_NETWORK>`/`<PRIVATE_NETMASK>` are the private network you want routed — this is an alternate path, so it isn't part of the standard variable file.
- Only push DNS that is reachable under the selected routing model.

## 7. Configure Linux forwarding and NAT

### Enable persistent IPv4 forwarding

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
printf '%s\n' 'net.ipv4.ip_forward = 1' | \
  sudo tee /etc/sysctl.d/99-openvpn-forward.conf >/dev/null

sudo sysctl --system
sysctl net.ipv4.ip_forward
REMOTE
```

### Create an idempotent firewall helper

This example cooperates with Docker by using `DOCKER-USER` when that chain exists. The script sources `/etc/openvpn/vpn-vars.env` itself at run time, so it always uses your current `VPN_SUBNET_CIDR` — even after a reboot — without needing to be regenerated.

The outer block below uses the `REMOTE` heredoc delimiter to ship the whole thing through `ssm_linux`; the inner `SCRIPT` heredoc is unrelated and, because it's still single-quoted, still writes `openvpn-nat` byte-for-byte with no expansion at any layer:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
sudo tee /usr/local/sbin/openvpn-nat >/dev/null <<'SCRIPT'
#!/bin/sh
set -eu

. /etc/openvpn/vpn-vars.env
VPN_SUBNET="$VPN_SUBNET_CIDR"
EXT_IF="$(ip -4 route show default | awk 'NR == 1 {print $5}')"

if iptables -nL DOCKER-USER >/dev/null 2>&1; then
  FORWARD_CHAIN="DOCKER-USER"
else
  FORWARD_CHAIN="FORWARD"
fi

case "${1:-}" in
  start)
    iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$EXT_IF" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -I POSTROUTING 1 -s "$VPN_SUBNET" -o "$EXT_IF" -j MASQUERADE

    iptables -C "$FORWARD_CHAIN" -i tun0 -o "$EXT_IF" -j ACCEPT 2>/dev/null || \
      iptables -I "$FORWARD_CHAIN" 1 -i tun0 -o "$EXT_IF" -j ACCEPT

    iptables -C "$FORWARD_CHAIN" -i "$EXT_IF" -o tun0 \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
      iptables -I "$FORWARD_CHAIN" 1 -i "$EXT_IF" -o tun0 \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ;;
  stop)
    iptables -C "$FORWARD_CHAIN" -i "$EXT_IF" -o tun0 \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null && \
      iptables -D "$FORWARD_CHAIN" -i "$EXT_IF" -o tun0 \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT || true

    iptables -C "$FORWARD_CHAIN" -i tun0 -o "$EXT_IF" -j ACCEPT 2>/dev/null && \
      iptables -D "$FORWARD_CHAIN" -i tun0 -o "$EXT_IF" -j ACCEPT || true

    iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$EXT_IF" \
      -j MASQUERADE 2>/dev/null && \
      iptables -t nat -D POSTROUTING -s "$VPN_SUBNET" -o "$EXT_IF" \
        -j MASQUERADE || true
    ;;
  *)
    echo "Usage: $0 {start|stop}" >&2
    exit 2
    ;;
esac
SCRIPT

sudo chmod 0755 /usr/local/sbin/openvpn-nat
REMOTE
```

### Persist those rules with systemd

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
sudo tee /etc/systemd/system/openvpn-nat.service >/dev/null <<'UNIT'
[Unit]
Description=OpenVPN forwarding and NAT rules
After=network-online.target openvpn-server@server.service
Requires=openvpn-server@server.service
PartOf=openvpn-server@server.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/openvpn-nat start
ExecStop=/usr/local/sbin/openvpn-nat stop

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
REMOTE
```

> **Do not mix firewall managers casually:** Direct iptables rules can conflict with UFW, firewalld or configuration-management tools. Choose one ownership model and verify rules after Docker or firewall restarts.

## 8. Open only the network perimeter you need

Two controls are separate:

1. The **cloud or upstream firewall** decides whether an encrypted UDP packet can reach the Linux server.
2. The **Linux forwarding rules** decide whether authenticated inner traffic can leave `tun0`.

### Generic rule

| Direction | Protocol | Port | Source |
|---|---|---|---|
| Inbound | UDP | Your configured `$VPN_PORT` | Either the required client networks or a deliberately chosen broader source |

### AWS CLI example

This discovers the Mac's current public IP the same way [section 13](#13-handle-a-dynamic-macbook-public-ip) does, so there's no IP to hardcode even for this first rule.

*Run on the Mac (or wherever you manage this security group)*

```bash
source ~/.config/openvpn/vpn-vars.env

CLIENT_PUBLIC_IP="$(curl -4 -fsS --max-time 10 "$TRUSTED_IP_CHECK_URL" | tr -d '[:space:]')"

aws ec2 authorize-security-group-ingress \
  --group-id "$VPN_SECURITY_GROUP_ID" \
  --protocol udp \
  --port "$VPN_PORT" \
  --cidr "${CLIENT_PUBLIC_IP}/32" \
  --region "$AWS_REGION"
```

A dedicated VPN security group is easier to reason about than mixing the listener with unrelated application rules.

> **Source restriction is optional, certificate authentication is not:** A source `/32` reduces who can reach the listener but requires updates whenever the Mac's public IP changes. A mobile VPN commonly permits a broader source and relies on certificate authentication plus `tls-crypt`. Choose based on your threat model and operating model.

## 9. Build a self-contained Mac client profile

A self-contained profile carries non-secret directives plus four inline blocks:

- The CA certificate
- The Mac client certificate
- The Mac client private key
- The shared `tls-crypt` key

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env
cd /etc/openvpn/easy-rsa

PROFILE="/root/${CLIENT_PROFILE_FILE}.ovpn"
CLIENT_NAME="$CLIENT_CERT_NAME"

sudo bash -c "cat > '$PROFILE'" <<EOF
client
dev tun
proto udp4
remote ${VPN_ENDPOINT} ${VPN_PORT}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name ${SERVER_CERT_NAME} name
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
auth SHA256
verb 3

<ca>
$(awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' pki/ca.crt)
</ca>
<cert>
$(awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "pki/issued/$CLIENT_NAME.crt")
</cert>
<key>
$(cat "pki/private/$CLIENT_NAME.key")
</key>
<tls-crypt>
$(cat pki/tls-crypt.key)
</tls-crypt>
EOF

sudo chmod 0600 "$PROFILE"
REMOTE
```

> **This pipe carries a private key.** Unlike every other block in this guide, the payload here contains the Mac client's actual private key material, assembled server-side into `$PROFILE`. The SSM session is TLS-encrypted end to end and the key never leaves the AWS network boundary you already trust for management access, but it's worth knowing this block is categorically different from a config-file push — it's the one place secrets flow through this channel rather than being generated and consumed entirely on one side.

### Validate structure without printing secrets

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env
PROFILE="/root/${CLIENT_PROFILE_FILE}.ovpn"

sudo test "$(grep -c -- 'BEGIN CERTIFICATE' "$PROFILE")" -eq 2
sudo test "$(grep -Ec -- 'BEGIN (RSA |ENCRYPTED )?PRIVATE KEY' "$PROFILE")" -eq 1
sudo grep -q -- 'BEGIN OpenVPN Static key' "$PROFILE"
echo "Profile structure looks complete"
REMOTE
```

> **The profile is a credential:** Do not paste it into chat, email it, commit it to Git or store it in a shared folder. If the private key has no password, anyone holding this file can authenticate as the Mac client.

## 10. Transfer the profile securely

### Option A: SCP over an authenticated SSH path

Stage a user-readable copy on Linux:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env

sudo install -m 0600 -o "$SERVER_USER" -g "$SERVER_USER_GROUP" \
  "/root/${CLIENT_PROFILE_FILE}.ovpn" \
  "/home/$SERVER_USER/${CLIENT_PROFILE_FILE}.ovpn"
REMOTE
```

This staged copy is readable by `$SERVER_USER`, the account the `scp` step below authenticates as over SSH — a separate access path from the `root` identity `ssm_linux` runs as. If the server has no SSH listener open, use Option B instead.

On the Mac:

```bash
source ~/.config/openvpn/vpn-vars.env

install -d -m 0700 "$HOME/.config/openvpn"

scp "$SERVER_USER@$VPN_ENDPOINT:/home/$SERVER_USER/${CLIENT_PROFILE_FILE}.ovpn" \
  "$HOME/.config/openvpn/${CLIENT_PROFILE_FILE}.ovpn"

chmod 0600 "$HOME/.config/openvpn/${CLIENT_PROFILE_FILE}.ovpn"
```

After confirming the Mac copy exists, remove the temporary staged server copy:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env
rm -f "/home/$SERVER_USER/${CLIENT_PROFILE_FILE}.ovpn"
REMOTE
```

### Option B: Managed session transport

When SSH is closed, use an authenticated management channel such as AWS Systems Manager Run Command — the same mechanism `ssm_linux` uses — instead of `scp`:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<REMOTE > "/tmp/${CLIENT_PROFILE_FILE}.ovpn.b64"
source /etc/openvpn/vpn-vars.env
base64 "/home/\$SERVER_USER/${CLIENT_PROFILE_FILE}.ovpn"
REMOTE

install -d -m 0700 "$HOME/.config/openvpn"
base64 -d < "/tmp/${CLIENT_PROFILE_FILE}.ovpn.b64" > "$HOME/.config/openvpn/${CLIENT_PROFILE_FILE}.ovpn"

shred -u "/tmp/${CLIENT_PROFILE_FILE}.ovpn.b64" 2>/dev/null || rm -f "/tmp/${CLIENT_PROFILE_FILE}.ovpn.b64"
chmod 0600 "$HOME/.config/openvpn/${CLIENT_PROFILE_FILE}.ovpn"
```

`$CLIENT_PROFILE_FILE` expands locally (it's already sourced into this shell); `\$SERVER_USER` is escaped so it expands on the remote side instead, after the heredoc's own `source /etc/openvpn/vpn-vars.env` line loads it there.

`ssm_linux`'s `send-command` transport returns output as a single clean value with no session banners to strip and no line-ending corruption to guard against — unlike the live-session approach this guide used earlier, this needs no sentinel markers. Verified end-to-end against a live instance with a 4 KB payload, byte-for-byte identical to the source file. Preserve the file bytes exactly, validate the decoded structure with the same checks as [section 9](#9-build-a-self-contained-mac-client-profile), keep mode `600` throughout, and avoid logging the profile body — the intermediate `.b64` file holds base64, not the raw PEM blocks, but it still holds the key, so don't skip the `shred`/`rm` cleanup line. Run the staging and cleanup blocks above exactly as written; only the transfer step itself changes.

## 11. Import the profile into OpenVPN Connect

### Install the client

Install the current OpenVPN Connect release for macOS from OpenVPN's official website. Open it once and complete the application's consent prompts.

### Import through the interface

The graphical import dialog can't read your variable file, so look up the values first:

```bash
source ~/.config/openvpn/vpn-vars.env
printf 'File to import: %s\nDisplay name: %s\n' \
  "$HOME/.config/openvpn/${CLIENT_PROFILE_FILE}.ovpn" "$PROFILE_DISPLAY_NAME"
```

1. Open OpenVPN Connect.
2. Open **My Profiles**.
3. Choose the file-import option.
4. Select the file path printed above.
5. Confirm the profile name and certificate prompt.

### Or import with the supported CLI

```bash
source ~/.config/openvpn/vpn-vars.env

OPENVPN_CONNECT="/Applications/OpenVPN Connect/OpenVPN Connect.app/Contents/MacOS/OpenVPN Connect"

"$OPENVPN_CONNECT" \
  --import-profile="$HOME/.config/openvpn/${CLIENT_PROFILE_FILE}.ovpn" \
  --name="$PROFILE_DISPLAY_NAME"

"$OPENVPN_CONNECT" --list-profiles
```

The OpenVPN Connect CLI supports importing and listing profiles, but connection control is normally performed with the application toggle.

## 12. Start services and verify end to end

### Start Linux services

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env

sudo systemctl enable --now openvpn-server@server.service
sudo systemctl enable --now openvpn-nat.service

sudo systemctl --no-pager --full status openvpn-server@server.service
sudo systemctl --no-pager --full status openvpn-nat.service
sudo ss -lunp "sport = :$VPN_PORT"
REMOTE
```

The OpenVPN status should contain `Initialization Sequence Completed`.

### Connect the Mac

```bash
source ~/.config/openvpn/vpn-vars.env
printf 'Enable this profile in OpenVPN Connect: %s\n' "$PROFILE_DISPLAY_NAME"
```

If the client private key is encrypted, enter its password when prompted.

### Verify on the Mac

```bash
source ~/.config/openvpn/vpn-vars.env

# A new utun interface should have a VPN address.
ifconfig

# A normal IPv4 destination should route through utun.
route -n get "$TEST_IPV4_DESTINATION"

# Inspect scoped DNS resolvers.
scutil --dns

# This should report the VPN server's public egress identity.
curl -4 "$TRUSTED_IP_CHECK_URL"

# Test name resolution and HTTPS.
dscacheutil -q host -a name "$TEST_HOSTNAME"
curl -4 -I "https://$TEST_HOSTNAME"
```

### Verify on Linux

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
sudo cat /run/openvpn-server/status-server.log
sudo journalctl -u openvpn-server@server --since "15 minutes ago" --no-pager
sudo iptables -t nat -nvL POSTROUTING
sudo iptables -nvL DOCKER-USER
ip address show tun0
REMOTE
```

### What proof looks like

- [ ] The server status lists your configured `$CLIENT_CERT_NAME`.
- [ ] The Mac has a private VPN address on a `utun` interface.
- [ ] The route for a normal destination uses that `utun` interface.
- [ ] The public egress identity matches the Linux server's stable endpoint.
- [ ] DNS resolution and HTTPS succeed.
- [ ] NAT and forwarding packet counters increase while the Mac sends traffic.
- [ ] Server logs show a modern TLS control channel and an AEAD data cipher.

## 13. Handle a dynamic MacBook public IP

If the upstream firewall allows only the Mac's current physical `/32`, it must be updated whenever the Mac changes ISP, Wi-Fi, hotspot or location.

### The important distinction

- **Disconnected:** an IP-check service reports the physical public IP required by the OpenVPN listener rule.
- **Connected:** the same service reports the VPN server's egress identity, not the Mac's physical public IP.

### Simple AWS update workflow

Run this while disconnected, before connecting the VPN. It authorizes the new source before revoking older OpenVPN rules. It reads the same `~/.config/openvpn/vpn-vars.env` you already set up, so there's nothing left to fill in inline.

```bash
#!/bin/bash
set -euo pipefail

source "$HOME/.config/openvpn/vpn-vars.env"

CLIENT_IP="$(curl -4 -fsS --max-time 10 "$TRUSTED_IP_CHECK_URL" | tr -d '[:space:]')"
CLIENT_CIDR="${CLIENT_IP}/32"

is_ipv4() {
  local ip="$1"
  local octet
  local -a octets

  IFS=. read -r -a octets <<< "$ip"
  [[ "${#octets[@]}" -eq 4 ]] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

if ! is_ipv4 "$CLIENT_IP"; then
  echo "Could not determine a valid public IPv4 address" >&2
  exit 1
fi

desired_rule="$(aws ec2 describe-security-group-rules \
  --region "$AWS_REGION" \
  --filters "Name=group-id,Values=$VPN_SECURITY_GROUP_ID" \
  --query "SecurityGroupRules[?!IsEgress && IpProtocol==\`udp\` && FromPort==\`$VPN_PORT\` && ToPort==\`$VPN_PORT\` && CidrIpv4==\`$CLIENT_CIDR\`].SecurityGroupRuleId" \
  --output text)"

if [[ -z "$desired_rule" || "$desired_rule" == "None" ]]; then
  aws ec2 authorize-security-group-ingress \
    --group-id "$VPN_SECURITY_GROUP_ID" \
    --protocol udp \
    --port "$VPN_PORT" \
    --cidr "$CLIENT_CIDR" \
    --region "$AWS_REGION"
fi

old_rules="$(aws ec2 describe-security-group-rules \
  --region "$AWS_REGION" \
  --filters "Name=group-id,Values=$VPN_SECURITY_GROUP_ID" \
  --query "SecurityGroupRules[?!IsEgress && IpProtocol==\`udp\` && FromPort==\`$VPN_PORT\` && ToPort==\`$VPN_PORT\` && CidrIpv4!=\`$CLIENT_CIDR\`].SecurityGroupRuleId" \
  --output text)"

if [[ -n "$old_rules" && "$old_rules" != "None" ]]; then
  read -r -a rule_ids <<< "$old_rules"
  aws ec2 revoke-security-group-ingress \
    --group-id "$VPN_SECURITY_GROUP_ID" \
    --security-group-rule-ids "${rule_ids[@]}" \
    --region "$AWS_REGION"
fi

printf 'OpenVPN ingress now allows %s\n' "$CLIENT_CIDR"
```

> **Operational tradeoff:** Restricting the listener to one dynamic `/32` improves perimeter filtering but creates a dependency on AWS credentials and the updater. If the Mac moves networks, the VPN cannot reconnect until the update succeeds.

## 14. Operate and maintain the VPN securely

### Add a second device

**Run interactively** — like section 5, this unlocks the CA key and prompts for its passphrase:

```bash
source ~/.config/openvpn/vpn-vars.env
aws ssm start-session --target "$SSM_INSTANCE_ID" --region "$AWS_REGION"
```

Inside that session:

```bash
source /etc/openvpn/vpn-vars.env
SECOND_CLIENT_CERT_NAME="CHANGE_ME"   # e.g. second-client
[ "$SECOND_CLIENT_CERT_NAME" != "CHANGE_ME" ] || { echo "Set SECOND_CLIENT_CERT_NAME above" >&2; exit 1; }

cd /etc/openvpn/easy-rsa
./easyrsa build-client-full "$SECOND_CLIENT_CERT_NAME"
./easyrsa gen-crl
```

Never reuse the first Mac's private key — this creates a distinct certificate. Then repeat [section 9](#9-build-a-self-contained-mac-client-profile), using `CLIENT_NAME="$SECOND_CLIENT_CERT_NAME"` in place of `CLIENT_NAME="$CLIENT_CERT_NAME"` and a different `PROFILE` filename so you don't overwrite the first device's profile. Repeat [section 10](#10-transfer-the-profile-securely) to transfer it, using that new filename in place of `CLIENT_PROFILE_FILE`.

### Revoke a lost or retired client

**Run interactively** — `revoke` and `gen-crl` both unlock the CA key:

```bash
source ~/.config/openvpn/vpn-vars.env
aws ssm start-session --target "$SSM_INSTANCE_ID" --region "$AWS_REGION"
```

Inside that session:

```bash
source /etc/openvpn/vpn-vars.env

cd /etc/openvpn/easy-rsa
./easyrsa revoke "$CLIENT_CERT_NAME"
./easyrsa gen-crl
```

Installing the new CRL and restarting OpenVPN don't touch the CA key, so once the CRL is regenerated, end the interactive session and finish from the Mac:

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env
cd /etc/openvpn/easy-rsa

sudo install -m 0644 pki/crl.pem /etc/openvpn/server/crl.pem
sudo systemctl restart openvpn-server@server
REMOTE
```

Restarting OpenVPN disconnects active clients. Plan the change and verify the new CRL afterward.

### Monitor certificate expiry

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env

openssl x509 -in /etc/openvpn/server/server.crt -noout -subject -dates
openssl x509 -in \
  "/etc/openvpn/easy-rsa/pki/issued/${CLIENT_CERT_NAME}.crt" \
  -noout -subject -dates
REMOTE
```

### Back up the state that matters

- `/etc/openvpn/server`: runtime configuration and server keys.
- `/etc/openvpn/easy-rsa/pki`: CA database, CA key, issued certificates and revocation state.
- `/etc/openvpn/vpn-vars.env`: your chosen network, DNS and account values.
- `/etc/sysctl.d/99-openvpn-forward.conf`: forwarding persistence.
- `/usr/local/sbin/openvpn-nat` and its systemd unit.
- The Mac profile and OpenVPN Connect configuration, stored securely.

> **Protect the backup like a credential vault:** A PKI backup can contain the CA private key and every client private key generated on the server. Encrypt it, restrict access and test restoration without publishing its contents.

## 15. Troubleshoot systematically

| Symptom | Likely layer | Checks |
|---|---|---|
| Connection times out with no server log entry | DNS, public route, cloud firewall or listener | Resolve your `$VPN_ENDPOINT`, inspect the UDP rule, run `ss`, and confirm the Mac's physical IP is allowed. |
| Server logs certificate verification failure | PKI | Check CA match, certificate purpose, expiry, CN, CRL and the embedded profile blocks. |
| Tunnel connects but internet fails | Forwarding or NAT | Check `ip_forward`, NAT and forwarding counters, external interface, and outbound cloud rules. |
| IP traffic works but names do not resolve | DNS | Inspect `scutil --dns`, verify pushed resolvers, and test whether they are reachable through the tunnel. |
| Some sites stall or large transfers fail | Path MTU | Look for repeated `EMSGSIZE` or fragmentation errors. Measure before introducing `mssfix` or a smaller tunnel MTU. |
| IPv6 bypasses the VPN | IPv6 policy | Verify the client installed an IPv6 reject/tunnel route. Either configure full IPv6 tunneling or block it deliberately. |
| Works until reboot | Persistence | Check both services are enabled, sysctl is persistent, and firewall ownership does not flush the rules. |
| Works until Docker restarts | Firewall chain ownership | Inspect `DOCKER-USER` and re-evaluate the systemd ordering or Docker-compatible firewall policy. |

### Read-only diagnostic bundle

*Run on the Mac, targeting Linux*

```bash
source ~/.config/openvpn/vpn-vars.env

ssm_linux <<'REMOTE'
source /etc/openvpn/vpn-vars.env

sudo systemctl --no-pager --full status openvpn-server@server openvpn-nat
sudo journalctl -u openvpn-server@server --since "30 minutes ago" --no-pager
sudo cat /run/openvpn-server/status-server.log
sudo ss -lunp "sport = :$VPN_PORT"
sysctl net.ipv4.ip_forward
ip -4 route
sudo iptables -t nat -nvL POSTROUTING
sudo iptables -nvL DOCKER-USER
sudo nft list ruleset
REMOTE
```

## Glossary and official sources

| Term | Short definition |
|---|---|
| AEAD | Authenticated encryption with associated data; encrypts data and verifies integrity in one construction. |
| CIDR | Notation that combines a network address and prefix length, commonly used in firewall rules. |
| CN | Common Name, an X.509 subject field used here as a readable certificate identity. |
| CRL | Certificate Revocation List, a signed list of certificates no longer trusted. |
| EIP | Elastic IP, AWS terminology for an account-allocated static public IPv4 address. |
| NAT | Network Address Translation; source NAT rewrites client source addresses for routed egress. |
| PKI | Public Key Infrastructure: CA, keys, certificates, issuance records and revocation state. |
| TLS | The protocol OpenVPN uses for peer authentication and control-channel key negotiation. |
| TUN | A virtual Layer 3 interface carrying routed IP packets. |

### Official documentation

- [OpenVPN 2.6 Manual](https://openvpn.net/community-docs/community-articles/openvpn-2-6-manual.html)
- [Routing all client traffic through OpenVPN](https://openvpn.net/community-docs/routing-all-client-traffic--including-web-traffic--through-the-vpn.html)
- [Install OpenVPN Connect on macOS](https://openvpn.net/connect-docs/macos-installation-guide.html)
- [OpenVPN Connect command-line functionality on macOS](https://openvpn.net/connect-docs/command-line-functionality-macos.html)
- [Import an OpenVPN Connect profile](https://openvpn.net/connect-docs/import-profile.html)
- [AWS VPC security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)
- [Configure AWS security-group rules](https://docs.aws.amazon.com/vpc/latest/userguide/working-with-security-group-rules.html)
- [AWS Elastic IP addresses](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/elastic-ip-addresses-eip.html)
- [AWS Systems Manager Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command.html)
- [AWS CLI `send-command` reference](https://docs.aws.amazon.com/cli/latest/reference/ssm/send-command.html)
- [AWS CLI `get-command-invocation` reference](https://docs.aws.amazon.com/cli/latest/reference/ssm/get-command-invocation.html)
- [AWS CLI Session Manager `start-session` reference](https://docs.aws.amazon.com/cli/latest/reference/ssm/start-session.html) — used only for the interactive CA-passphrase steps in sections 5 and 14

---

*Generic educational material. Every environment-specific value lives in one of the two variable files described in [Set your variables](#2-set-your-variables). No real infrastructure identifiers, addresses, client names, certificate fingerprints or credentials are included.*
