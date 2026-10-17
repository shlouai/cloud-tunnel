#!/usr/bin/env bash
#
# ssctl.sh - deploy and manage Xray VLESS + REALITY on an existing EC2 host.
#
# The script runs locally and drives the remote host over SSH. It does not
# touch AWS APIs: the instance, its security group and its key pair are yours.
#
set -euo pipefail

VERSION="1.0.0"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF="${SSCTL_CONF:-$SCRIPT_DIR/ssctl.conf}"
STATE_DIR="${SSCTL_STATE_DIR:-$HOME/.cloud-tunnel}"
LEGACY_STATE_DIR="$HOME/.ec2ss"

REMOTE_BIN="/usr/local/bin/xray"
REMOTE_ETC="/usr/local/etc/xray"
REMOTE_CONF="$REMOTE_ETC/config.json"
UNIT_PATH="/etc/systemd/system/xray.service"

# --- defaults, overridden by ssctl.conf -------------------------------------
SERVER_HOST=""
SSH_USER="ubuntu"
SSH_PORT="22"
SSH_KEY=""
XRAY_PORT="443"
REALITY_DEST="www.bing.com:443"
REALITY_SERVER_NAME="www.bing.com"
CLIENT_HOST=""
PROFILE_NAME="ec2-reality"
XRAY_VERSION="latest"

# --- generated at deploy time -----------------------------------------------
UUID=""
PRIVATE_KEY=""
PUBLIC_KEY=""
SHORT_ID=""
ARCH=""

DRY_RUN=0
FORCE=0
SSH_ARGS=()
SSH_KEY_RESOLVED=""

# --- output ------------------------------------------------------------------
if [[ -t 2 ]]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_RST=$'\033[0m'
else
    C_RED=""; C_GRN=""; C_YEL=""; C_RST=""
fi

log()  { printf '%s==>%s %s\n' "$C_GRN" "$C_RST" "$*" >&2; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '%s[error]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }

usage() {
    cat >&2 <<EOF
ssctl.sh $VERSION - Xray VLESS+REALITY on an existing EC2 host

Usage: ./ssctl.sh <command> [--dry-run] [--force]

Commands:
  deploy      install, configure, enable on boot and start
  start       start the remote service
  stop        stop the remote service
  restart     restart the remote service
  status      service state, listening port and reachability
  config      print the client config (vless:// and Clash Verge Rev YAML)
  logs        show the last 50 log lines from the remote service
  uninstall   stop and remove Xray from the remote host

Flags:
  --dry-run   print what would run on the remote host, execute nothing
  --force     reinstall the binary / regenerate keys on deploy

Config: $CONF
State:  $STATE_DIR
EOF
}

# --- config / state ----------------------------------------------------------
expand_tilde() {
    case "$1" in
        "~")    printf '%s\n' "$HOME" ;;
        "~/"*)  printf '%s\n' "$HOME/${1#\~/}" ;;
        *)      printf '%s\n' "$1" ;;
    esac
}

# Git Bash may resolve `ssh` to the native Windows binary, which needs a
# Windows-style key path instead of a POSIX one.
ssh_path() {
    local p="$1" bin
    if command -v cygpath >/dev/null 2>&1; then
        bin="$(command -v ssh 2>/dev/null || true)"
        case "$bin" in
            /c/Windows/*|/mnt/c/Windows/*|*.exe) cygpath -w "$p"; return ;;
        esac
    fi
    printf '%s\n' "$p"
}

load_conf() {
    [[ -f "$CONF" ]] || die "config not found: $CONF
Copy the example first:  cp ssctl.conf.example ssctl.conf"

    # shellcheck disable=SC1090
    source "$CONF"

    [[ -n "$SERVER_HOST" ]] || die "SERVER_HOST is required in $CONF"
    [[ -n "$SSH_KEY" ]]     || die "SSH_KEY is required in $CONF"

    SSH_KEY="$(expand_tilde "$SSH_KEY")"
    [[ -f "$SSH_KEY" ]] || die "ssh key not found: $SSH_KEY"
    SSH_KEY_RESOLVED="$(ssh_path "$SSH_KEY")"

    [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || die "XRAY_PORT must be a number, got: $XRAY_PORT"

    # Address written into the client config. Defaults to the SSH host, but an
    # IP avoids any DNS dependency on the client side.
    CLIENT_HOST="${CLIENT_HOST:-$SERVER_HOST}"

    SSH_ARGS=(
        -i "$SSH_KEY_RESOLVED"
        -p "$SSH_PORT"
        -o BatchMode=yes
        -o StrictHostKeyChecking=accept-new
        -o ConnectTimeout=10
        -o ServerAliveInterval=15
        -o ServerAliveCountMax=3
        "$SSH_USER@$SERVER_HOST"
    )
}

state_file() {
    local host_safe="${SERVER_HOST//[^A-Za-z0-9._-]/_}"
    printf '%s/%s.state' "$STATE_DIR" "$host_safe"
}

load_state() {
    local f legacy
    f="$(state_file)"
    if [[ ! -f "$f" && -z "${SSCTL_STATE_DIR:-}" ]]; then
        # migrate state written by older versions (before the project rename)
        legacy="$LEGACY_STATE_DIR/${SERVER_HOST//[^A-Za-z0-9._-]/_}.state"
        if [[ -f "$legacy" ]]; then
            mkdir -p "$STATE_DIR"
            chmod 700 "$STATE_DIR" 2>/dev/null || true
            cp -p "$legacy" "$f"
            log "migrated state from $legacy"
        fi
    fi
    [[ -f "$f" ]] || return 1
    # shellcheck disable=SC1090
    source "$f"
    return 0
}

save_state() {
    local f
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR" 2>/dev/null || true
    f="$(state_file)"
    (
        umask 077
        cat >"$f" <<EOF
# cloud-tunnel state, written $(date -u '+%Y-%m-%dT%H:%M:%SZ')
STATE_HOST='$SERVER_HOST'
STATE_CLIENT_HOST='$CLIENT_HOST'
STATE_PORT='$XRAY_PORT'
STATE_DEST='$REALITY_DEST'
STATE_SERVER_NAME='$REALITY_SERVER_NAME'
STATE_PROFILE='$PROFILE_NAME'
STATE_UUID='$UUID'
STATE_PRIVATE_KEY='$PRIVATE_KEY'
STATE_PUBLIC_KEY='$PUBLIC_KEY'
STATE_SHORT_ID='$SHORT_ID'
EOF
    )
    log "state saved to $f"
}

# --- remote execution --------------------------------------------------------
remote() {
    local cmd="$1"
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s ssh %s@%s -- %s\n' \
            "$C_YEL" "$C_RST" "$SSH_USER" "$SERVER_HOST" "$cmd" >&2
        return 0
    fi
    ssh "${SSH_ARGS[@]}" "$cmd"
}

# Runs a script from stdin on the remote host. Values are passed as env vars so
# the script body can stay in a quoted heredoc without local interpolation.
remote_script() {
    local envs="${1:-}" script
    script="$(cat)"
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s remote script (env: %s):\n' "$C_YEL" "$C_RST" "$envs" >&2
        printf '%s\n' "$script" | sed 's/^/    /' >&2
        return 0
    fi
    printf '%s\n' "$script" | ssh "${SSH_ARGS[@]}" "env $envs bash -s"
}

remote_write_file() {
    local path="$1" content="$2" mode="${3:-600}" owner="${4:-root}"
    if (( DRY_RUN )); then
        printf '%s[dry-run]%s write %s (mode %s, owner %s):\n' \
            "$C_YEL" "$C_RST" "$path" "$mode" "$owner" >&2
        printf '%s\n' "$content" | sed 's/^/    /' >&2
        return 0
    fi
    printf '%s\n' "$content" | ssh "${SSH_ARGS[@]}" \
        "sudo mkdir -p '$(dirname -- "$path")' && sudo tee '$path' >/dev/null \
         && sudo chmod '$mode' '$path' && sudo chown '$owner' '$path'"
}

tcp_probe() {
    local host="$1" port="$2"
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
    else
        bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
    fi
}

# --- local preflight ---------------------------------------------------------
preflight() {
    [[ "$SSH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "SSH_USER looks invalid: $SSH_USER"

    local mode after
    mode="$(stat -c '%a' "$SSH_KEY" 2>/dev/null || stat -f '%Lp' "$SSH_KEY" 2>/dev/null || echo '')"
    if [[ -n "$mode" && "$mode" != "600" && "$mode" != "400" ]]; then
        chmod 600 "$SSH_KEY" 2>/dev/null || true
        after="$(stat -c '%a' "$SSH_KEY" 2>/dev/null || stat -f '%Lp' "$SSH_KEY" 2>/dev/null || echo '')"
        if [[ -n "$after" && "$after" != "600" && "$after" != "400" ]]; then
            warn "ssh key permissions report $after and could not be changed on this filesystem"
            warn "if ssh refuses the key, tighten its permissions manually"
        fi
    fi

    log "checking ssh to $SSH_USER@$SERVER_HOST:$SSH_PORT"
    if ! remote "true" >/dev/null 2>&1; then
        die "cannot ssh to $SSH_USER@$SERVER_HOST:$SSH_PORT with $SSH_KEY
Check: the instance is running, the key matches, the security group allows your IP on port $SSH_PORT."
    fi
}

# --- remote preflight --------------------------------------------------------
remote_preflight() {
    if (( DRY_RUN )); then
        ARCH="${ARCH:-x86_64}"
        return 0
    fi

    local report
    report="$(remote_script "" <<'EOF'
echo "ARCH=$(uname -m)"
echo "SUDO=$(sudo -n true >/dev/null 2>&1 && echo yes || echo no)"
echo "SYSTEMD=$(command -v systemctl >/dev/null 2>&1 && echo yes || echo no)"
echo "CURL=$(command -v curl >/dev/null 2>&1 && echo yes || echo no)"
echo "UNZIP=$(command -v unzip >/dev/null 2>&1 && echo yes || echo no)"
echo "NOBODY=$(id -u nobody >/dev/null 2>&1 && echo yes || echo no)"
EOF
)"

    local key val
    local sudo_ok="" systemd_ok="" curl_ok="" unzip_ok="" nobody_ok=""
    while IFS='=' read -r key val; do
        case "$key" in
            ARCH)    ARCH="$val" ;;
            SUDO)    sudo_ok="$val" ;;
            SYSTEMD) systemd_ok="$val" ;;
            CURL)    curl_ok="$val" ;;
            UNZIP)   unzip_ok="$val" ;;
            NOBODY)  nobody_ok="$val" ;;
        esac
    done <<<"$report"

    [[ -n "$ARCH" ]] || die "could not detect the remote architecture"

    [[ "$sudo_ok" == "yes" ]] || die "passwordless sudo is required on the remote host"
    [[ "$systemd_ok" == "yes" ]] || die "systemd is required on the remote host"
    [[ "$curl_ok" == "yes" ]] || die "curl is required on the remote host"

    if [[ "$nobody_ok" != "yes" ]]; then
        warn "user 'nobody' not found; the service will run as root instead"
    fi

    if [[ "$unzip_ok" != "yes" ]]; then
        log "unzip is missing on the remote host; installing it"
        remote_script "" <<'EOF'
set -e
if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unzip
elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y -q unzip
elif command -v yum >/dev/null 2>&1; then
    sudo yum install -y -q unzip
else
    echo "no supported package manager; install unzip manually" >&2
    exit 1
fi
EOF
    fi

    check_port_free
}

check_port_free() {
    local busy
    busy="$(remote "sudo ss -lntpH 'sport = :$XRAY_PORT' 2>/dev/null || true" | tr -d '\r')"

    if [[ -z "$busy" ]]; then
        return 0
    fi

    if remote "systemctl is-active --quiet xray" >/dev/null 2>&1; then
        log "port $XRAY_PORT is held by the existing xray service; it will be restarted"
        return 0
    fi

    printf '%s\n' "$busy" >&2
    die "port $XRAY_PORT is already in use on $SERVER_HOST by something other than xray"
}

# --- deploy steps ------------------------------------------------------------
detect_asset() {
    case "$ARCH" in
        x86_64|amd64)       printf 'Xray-linux-64.zip\n' ;;
        aarch64|arm64)      printf 'Xray-linux-arm64-v8a.zip\n' ;;
        armv7l|armv7|armhf) printf 'Xray-linux-arm32-v7a.zip\n' ;;
        i386|i686)          printf 'Xray-linux-32.zip\n' ;;
        *)                  die "unsupported architecture: $ARCH" ;;
    esac
}

install_xray() {
    local asset
    asset="$(detect_asset)"
    log "remote architecture: $ARCH (asset: $asset)"

    if (( DRY_RUN )); then
        log "[dry-run] would install $asset to $REMOTE_BIN"
        return 0
    fi

    local existing
    existing="$(remote "if [ -x $REMOTE_BIN ]; then $REMOTE_BIN version 2>/dev/null | head -1; else echo none; fi" | tr -d '\r')"
    [[ -n "$existing" ]] || existing="none"

    if [[ "$existing" != "none" ]] && (( ! FORCE )); then
        if [[ "$XRAY_VERSION" == "latest" ]] || [[ "$existing" == *"${XRAY_VERSION#v}"* ]]; then
            log "Xray already installed: $existing"
            return 0
        fi
    fi

    log "installing Xray ($XRAY_VERSION)"
    remote_script "ASSET='$asset' XRAY_VERSION='$XRAY_VERSION'" <<'EOF'
set -euo pipefail
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ "$XRAY_VERSION" = "latest" ]; then
    url="https://github.com/XTLS/Xray-core/releases/latest/download/$ASSET"
else
    url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/$ASSET"
fi

echo "downloading $url"
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/xray.zip" "$url"
unzip -oq "$tmp/xray.zip" -d "$tmp/x"
sudo install -m 0755 "$tmp/x/xray" /usr/local/bin/xray
/usr/local/bin/xray version | head -1
EOF
}

local_shortid() {
    od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

generate_credentials() {
    if (( DRY_RUN )); then
        UUID="00000000-0000-0000-0000-000000000000"
        PRIVATE_KEY="<generated on a real run>"
        PUBLIC_KEY="<generated on a real run>"
        SHORT_ID="$(local_shortid)"
        log "[dry-run] would generate UUID and x25519 keypair"
        return 0
    fi

    log "generating UUID and x25519 keypair"
    local out uuid priv pub
    out="$(remote "$REMOTE_BIN uuid && echo @@ && $REMOTE_BIN x25519" | tr -d '\r')"

    uuid="$(printf '%s\n' "$out" | sed -n '1p' | tr -d '[:space:]')"
    # Current output: "PrivateKey: <key>" / "Password (PublicKey): <key>" / "Hash32: <key>"
    priv="$(printf '%s\n' "$out" | sed -n '/^PrivateKey:/{s/^PrivateKey:[[:space:]]*//;p;q}')"
    pub="$(printf '%s\n' "$out" | sed -n '/^Password/{s/^.*:[[:space:]]*//;p;q}')"
    # Older releases print "Private key:" / "Public key:"
    [[ -n "$priv" ]] || priv="$(printf '%s\n' "$out" | grep -m1 -i 'private key' | awk '{print $NF}' || true)"
    [[ -n "$pub" ]]  || pub="$(printf '%s\n' "$out" | grep -m1 -i 'public key'  | awk '{print $NF}' || true)"

    [[ -n "$uuid" && -n "$priv" && -n "$pub" ]] \
        || die "could not parse xray output:
$out"

    UUID="$uuid"
    PRIVATE_KEY="$priv"
    PUBLIC_KEY="$pub"
    SHORT_ID="$(local_shortid)"
}

write_remote_config() {
    local owner="nobody"
    if (( ! DRY_RUN )); then
        if ! remote "id -u nobody >/dev/null 2>&1"; then
            owner="root"
        fi
    fi

    local config
    config="$(cat <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $XRAY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$REALITY_DEST",
          "xver": 0,
          "serverNames": [
            "$REALITY_SERVER_NAME"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
EOF
)"
    log "writing $REMOTE_CONF"
    remote_write_file "$REMOTE_CONF" "$config" 600 "$owner"
}

write_systemd_unit() {
    local user="nobody"
    if (( ! DRY_RUN )); then
        if ! remote "id -u nobody >/dev/null 2>&1"; then
            user="root"
        fi
    fi

    local unit
    unit="$(cat <<EOF
[Unit]
Description=Xray Service (VLESS + REALITY)
After=network.target nss-lookup.target

[Service]
User=$user
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$REMOTE_BIN run -config $REMOTE_CONF
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
)"
    log "writing $UNIT_PATH"
    remote_write_file "$UNIT_PATH" "$unit" 644 "root"
}

configure_bbr() {
    if (( DRY_RUN )); then
        log "[dry-run] would enable BBR"
        return 0
    fi

    local result
    result="$(remote_script "" <<'EOF'
cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
if [ "$cc" = "bbr" ]; then
    echo "already-bbr"
    exit 0
fi
printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' \
    | sudo tee /etc/sysctl.d/99-bbr.conf >/dev/null
if sudo sysctl --system >/dev/null 2>&1; then
    echo "enabled:$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
else
    echo "failed"
fi
EOF
)"

    case "$result" in
        *already-bbr*)  log "BBR already enabled" ;;
        *enabled:bbr*)  log "BBR enabled" ;;
        *)              warn "could not enable BBR (kernel may lack support); continuing" ;;
    esac
}

start_service() {
    log "starting xray"
    remote "sudo systemctl daemon-reload"
    remote "sudo systemctl enable xray >/dev/null 2>&1 || true"
    remote "sudo systemctl restart xray"

    if (( DRY_RUN )); then
        return 0
    fi

    local i state="unknown"
    for i in 1 2 3 4 5 6 7 8 9 10; do
        state="$(remote "systemctl is-active xray 2>/dev/null || true" | tr -d '\r')"
        [[ "$state" == "active" ]] && break
        sleep 1
    done

    if [[ "$state" != "active" ]]; then
        warn "xray did not become active; recent logs:"
        remote "sudo journalctl -u xray -n 30 --no-pager 2>/dev/null || true" >&2 || true
        die "service failed to start"
    fi
    log "service is active"
}

# Runs a throwaway Xray client on the server and drives a request through it.
# This validates the REALITY handshake and the disguise target without needing
# the EC2 security group to be open yet.
verify_reality() {
    if (( DRY_RUN )); then
        log "[dry-run] would verify the REALITY handshake over loopback"
        return 0
    fi

    log "verifying the REALITY handshake over loopback"
    local result
    result="$(remote_script \
        "UUID='$UUID' PUB='$PUBLIC_KEY' SID='$SHORT_ID' PORT='$XRAY_PORT' SNI='$REALITY_SERVER_NAME'" \
        <<'EOF'
set -u
socks_port=$(( 20000 + RANDOM % 20000 ))
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; kill "${pid:-}" 2>/dev/null' EXIT

cat > "$tmp/client.json" <<JSON
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "listen": "127.0.0.1", "port": $socks_port, "protocol": "socks", "settings": { "udp": false } }
  ],
  "outbounds": [
    {
      "protocol": "vless",
      "settings": { "vnext": [ { "address": "127.0.0.1", "port": $PORT, "users": [
        { "id": "$UUID", "encryption": "none", "flow": "xtls-rprx-vision" }
      ] } ] },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": { "serverName": "$SNI", "fingerprint": "chrome", "publicKey": "$PUB", "shortId": "$SID" }
      }
    }
  ]
}
JSON

/usr/local/bin/xray run -c "$tmp/client.json" >"$tmp/client.log" 2>&1 &
pid=$!
sleep 2
code="$(curl -sS --max-time 10 -x "socks5h://127.0.0.1:$socks_port" \
    -o /dev/null -w '%{http_code}' https://www.google.com/generate_204 2>/dev/null || true)"
echo "HTTPS_CODE=${code:-000}"
EOF
)"

    if [[ "$result" == *"HTTPS_CODE=204"* ]]; then
        log "REALITY handshake verified"
    else
        warn "REALITY self-test failed (${result:-no output})"
        warn "the disguise target may not support the handshake; try another REALITY_DEST"
    fi
}

# --- client config -----------------------------------------------------------
client_config_yaml() {
    cat <<EOF
# Generated by cloud-tunnel for Clash Verge Rev (mihomo)
# Import as a Local profile: Profiles -> New -> Local -> select this file.

mixed-port: 7897
allow-lan: false
mode: rule
log-level: info
ipv6: false

proxies:
  - name: "$PROFILE_NAME"
    type: vless
    server: $CLIENT_HOST
    port: $XRAY_PORT
    uuid: "$UUID"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: "$REALITY_SERVER_NAME"
    client-fingerprint: chrome
    reality-opts:
      public-key: "$PUBLIC_KEY"
      short-id: "$SHORT_ID"

proxy-groups:
  - name: "PROXY"
    type: select
    proxies:
      - "$PROFILE_NAME"
      - "DIRECT"

rules:
  - MATCH,PROXY
EOF
}

print_client_config() {
    local uri out safe
    uri="vless://${UUID}@${CLIENT_HOST}:${XRAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${PROFILE_NAME}"

    printf '\n================ VLESS URI ================\n%s\n\n' "$uri"
    printf '%s\n' '========== Clash Verge Rev (mihomo) =========='
    client_config_yaml

    if (( ! DRY_RUN )); then
        safe="${PROFILE_NAME//[^A-Za-z0-9._-]/_}"
        out="$PWD/clash-${safe}.yaml"
        client_config_yaml >"$out"
        log "client config written to $out"
    fi
}

# --- commands ----------------------------------------------------------------
cmd_deploy() {
    load_conf
    preflight
    remote_preflight

    if load_state && (( ! FORCE )) && [[ -n "${STATE_UUID:-}" && -n "${STATE_PRIVATE_KEY:-}" ]]; then
        UUID="$STATE_UUID"
        PRIVATE_KEY="$STATE_PRIVATE_KEY"
        PUBLIC_KEY="$STATE_PUBLIC_KEY"
        SHORT_ID="$STATE_SHORT_ID"
        log "reusing existing credentials from $(state_file) (use --force to regenerate)"
    else
        UUID=""; PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
    fi

    install_xray

    if [[ -z "$UUID" || -z "$PRIVATE_KEY" ]]; then
        generate_credentials
    fi

    write_remote_config
    write_systemd_unit
    configure_bbr
    start_service
    verify_reality

    if (( ! DRY_RUN )); then
        save_state
    fi

    if (( ! DRY_RUN )); then
        if tcp_probe "$SERVER_HOST" "$XRAY_PORT"; then
            log "port $XRAY_PORT is reachable from this machine"
        else
            warn "port $XRAY_PORT is NOT reachable from this machine."
            warn "Most likely the EC2 security group does not allow inbound $XRAY_PORT."
            warn "Open it in the AWS console, then re-run: bash ssctl.sh status"
        fi
    fi

    print_client_config
}

cmd_start() {
    load_conf
    remote "sudo systemctl start xray"
    remote "systemctl is-active xray 2>/dev/null || true"
}

cmd_stop() {
    load_conf
    remote "sudo systemctl stop xray"
    remote "systemctl is-active xray 2>/dev/null || true"
}

cmd_restart() {
    load_conf
    remote "sudo systemctl restart xray"
    remote "systemctl is-active xray 2>/dev/null || true"
}

cmd_status() {
    load_conf
    if load_state; then
        XRAY_PORT="${STATE_PORT:-$XRAY_PORT}"
        SERVER_HOST="${STATE_HOST:-$SERVER_HOST}"
    fi

    if (( ! DRY_RUN )) && ! remote "true" >/dev/null 2>&1; then
        warn "cannot reach $SSH_USER@$SERVER_HOST:$SSH_PORT over SSH; skipping remote checks"
        warn "the proxy itself is independent of SSH; testing port $XRAY_PORT instead"
        if tcp_probe "$SERVER_HOST" "$XRAY_PORT"; then
            log "port $XRAY_PORT is reachable from this machine"
        else
            warn "port $XRAY_PORT is NOT reachable from this machine"
        fi
        warn "check the EC2 security group allows inbound $SSH_PORT (management) and $XRAY_PORT (proxy)"
        return 0
    fi

    log "service state"
    remote "systemctl is-active xray 2>/dev/null || echo inactive" || true

    log "listening socket"
    remote "sudo ss -lntpH 'sport = :$XRAY_PORT' 2>/dev/null || true" || true

    log "installed version"
    remote "$REMOTE_BIN version 2>/dev/null | head -1 || echo 'not installed'" || true

    if (( DRY_RUN )); then
        return 0
    fi

    if tcp_probe "$SERVER_HOST" "$XRAY_PORT"; then
        log "port $XRAY_PORT is reachable from this machine"
    else
        warn "port $XRAY_PORT is NOT reachable from this machine"
        warn "check the EC2 security group allows inbound $XRAY_PORT from your IP"
    fi
}

cmd_config() {
    load_conf
    load_state || die "no saved state for $SERVER_HOST; run ./ssctl.sh deploy first"

    [[ -n "${STATE_UUID:-}" ]] || die "state file has no credentials; run ./ssctl.sh deploy first"
    UUID="$STATE_UUID"
    PRIVATE_KEY="${STATE_PRIVATE_KEY:-}"
    PUBLIC_KEY="${STATE_PUBLIC_KEY:-}"
    SHORT_ID="${STATE_SHORT_ID:-}"
    SERVER_HOST="${STATE_HOST:-$SERVER_HOST}"
    CLIENT_HOST="${STATE_CLIENT_HOST:-$CLIENT_HOST}"
    XRAY_PORT="${STATE_PORT:-$XRAY_PORT}"
    REALITY_SERVER_NAME="${STATE_SERVER_NAME:-$REALITY_SERVER_NAME}"
    PROFILE_NAME="${STATE_PROFILE:-$PROFILE_NAME}"

    print_client_config
}

cmd_logs() {
    load_conf
    remote "sudo journalctl -u xray -n 50 --no-pager 2>/dev/null || true"
}

cmd_uninstall() {
    load_conf

    warn "this stops and removes Xray from $SERVER_HOST"
    if (( ! DRY_RUN )); then
        local ans=""
        printf "Type 'yes' to continue: " >&2
        read -r ans || true
        [[ "$ans" == "yes" ]] || die "aborted"
    fi

    remote_script "" <<'EOF'
set -e
sudo systemctl disable --now xray >/dev/null 2>&1 || true
sudo rm -f /etc/systemd/system/xray.service
sudo systemctl daemon-reload
sudo rm -rf /usr/local/etc/xray
sudo rm -f /usr/local/bin/xray
echo "removed"
EOF

    log "Xray removed"
    log "local state kept at $(state_file)" || true
}

# --- entry point -------------------------------------------------------------
main() {
    local args=() a
    for a in "$@"; do
        case "$a" in
            --dry-run) DRY_RUN=1 ;;
            --force)   FORCE=1 ;;
            -h|--help) usage; exit 0 ;;
            *)         args+=("$a") ;;
        esac
    done

    if ((${#args[@]})); then
        set -- "${args[@]}"
    else
        set --
    fi

    local cmd="${1:-}"
    [[ -n "$cmd" ]] || { usage; exit 1; }

    case "$cmd" in
        deploy)    cmd_deploy ;;
        start)     cmd_start ;;
        stop)      cmd_stop ;;
        restart)   cmd_restart ;;
        status)    cmd_status ;;
        config)    cmd_config ;;
        logs)      cmd_logs ;;
        uninstall) cmd_uninstall ;;
        -h|--help) usage ;;
        *)         usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"
