#!/usr/bin/env bash
#
# slipstream-server installer.
#
# Installs a prebuilt slipstream-server release binary and registers it as a
# hardened systemd service. No compilation is involved.
#
#   sudo ./install.sh
#
# The script is interactive: it asks for the domain and the forwarding target
# after it starts. Every prompt can also be preseeded with an environment
# variable, which makes the script usable unattended.
#
set -euo pipefail

readonly UPSTREAM_REPO="Mygod/slipstream-rust"
readonly VERSION="${SLIPSTREAM_VERSION:-v0.1.1}"

readonly BIN_DIR="/usr/local/bin"
readonly CONF_DIR="/etc/slipstream"
readonly STATE_DIR="/var/lib/slipstream"
readonly UNIT_PATH="/etc/systemd/system/slipstream-server.service"
readonly SOCKS_UNIT_PATH="/etc/systemd/system/slipstream-socks.service"
readonly SOCKS_CRED_PATH="/etc/slipstream/socks-credentials"
readonly SERVICE_USER="slipstream"

# Checksums of the release archives this installer is pinned to. Verifying
# against a value baked into the script - rather than only against the .sha256
# published next to the archive - is what makes a swapped release detectable.
readonly SHA256_X86_64="5572d407d685a4a87e4de5a7121566d48ac719068e50ad69705793dc6d9ff682"
readonly SHA256_ARM64="4220db98c49617c8453514afe6ea7455ccc6f31aad14f206643e9d81cd9b7e31"

WORK_DIR=""

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m error\033[0m %s\n' "$*" >&2; exit 1; }

cleanup() {
  [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]] && rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

preflight() {
  [[ "$(uname -s)" == "Linux" ]] || die "This installer supports Linux only."
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./install.sh"
  command -v systemctl >/dev/null 2>&1 || die "systemd is required."

  local missing=()
  local tool
  for tool in curl tar sha256sum install useradd; do
    command -v "${tool}" >/dev/null 2>&1 || missing+=("${tool}")
  done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing required tools: ${missing[*]}"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  ARCH_SLUG="x86_64"; EXPECTED_SHA256="${SHA256_X86_64}" ;;
    aarch64|arm64) ARCH_SLUG="arm64";  EXPECTED_SHA256="${SHA256_ARM64}" ;;
    *) die "Unsupported architecture: $(uname -m). Prebuilt binaries exist for x86_64 and arm64." ;;
  esac
  ASSET="slipstream-linux-${ARCH_SLUG}"
}

# --------------------------------------------------------------------------
# Interactive configuration
# --------------------------------------------------------------------------

# /dev/tty can exist as a node yet fail to open when the process has no
# controlling terminal (cron, CI, some service managers). Only an actual open
# proves prompting will work, so probe it once up front.
detect_tty() {
  if { : < /dev/tty; } 2>/dev/null; then
    HAVE_TTY=1
  else
    HAVE_TTY=0
  fi
}

# Reads a value from the terminal even when the script itself arrived on stdin
# (curl | bash). Falls back to the supplied default when no terminal exists.
# Callers run this in a command substitution, where `exit` would only leave the
# subshell - so this never fails fatally; prompts that cannot be defaulted are
# rejected by prompt_config before it gets here.
read_value() {
  local prompt="$1" default="${2:-}" reply=""

  if [[ "${HAVE_TTY}" -ne 1 ]]; then
    printf '%s\n' "${default}"
    return
  fi

  if [[ -n "${default}" ]]; then
    printf '%s [%s]: ' "${prompt}" "${default}" > /dev/tty
  else
    printf '%s: ' "${prompt}" > /dev/tty
  fi
  IFS= read -r reply < /dev/tty || true

  printf '%s\n' "${reply:-${default}}"
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

valid_hostport() {
  [[ "$1" =~ ^[^[:space:]]+:[0-9]{1,5}$ ]]
}

# Decides whether to stand up a SOCKS5 proxy as the tunnel's target. An
# explicit SLIPSTREAM_TARGET means the operator already has somewhere to send
# traffic, so the proxy is off by default in that case.
prompt_socks() {
  local answer

  if [[ -n "${SLIPSTREAM_SOCKS:-}" ]]; then
    answer="${SLIPSTREAM_SOCKS}"
  elif [[ -n "${SLIPSTREAM_TARGET:-}" ]]; then
    answer="n"
  else
    answer="$(read_value 'Install a SOCKS5 proxy here and tunnel to it? [Y/n]' 'Y')"
  fi

  case "${answer}" in
    [yY1]*|true|TRUE) INSTALL_SOCKS=1 ;;
    *)                INSTALL_SOCKS=0 ;;
  esac

  [[ "${INSTALL_SOCKS}" -eq 1 ]] || return 0

  SOCKS_PORT="${SLIPSTREAM_SOCKS_PORT:-1080}"
  if ! [[ "${SOCKS_PORT}" =~ ^[0-9]{1,5}$ ]] || (( SOCKS_PORT < 1 || SOCKS_PORT > 65535 )); then
    die "Invalid SOCKS port: ${SOCKS_PORT}"
  fi
}

prompt_config() {
  # The domain is the one setting with no sensible default. Without a terminal
  # to ask on it has to come from the environment, or the loops below would
  # spin forever on an empty answer.
  if [[ "${HAVE_TTY}" -ne 1 && -z "${SLIPSTREAM_DOMAIN:-}" ]]; then
    die "No terminal available to prompt on. Set SLIPSTREAM_DOMAIN to install unattended, e.g. SLIPSTREAM_DOMAIN=t.example.com $0"
  fi

  DOMAIN="${SLIPSTREAM_DOMAIN:-}"
  while ! valid_domain "${DOMAIN}"; do
    [[ -n "${DOMAIN}" ]] && warn "Not a valid domain: ${DOMAIN}"
    DOMAIN="$(read_value 'Tunnel domain (the zone delegated to this host, e.g. t.example.com)')"
    [[ -n "${DOMAIN}" ]] || warn "Domain is required."
  done

  # The tunnel only carries traffic to whatever listens on the target address.
  # Without something there the tunnel connects and then dies at the last hop,
  # so offer to put a SOCKS5 proxy on the other end and be done with it.
  prompt_socks

  if [[ "${INSTALL_SOCKS}" -eq 1 ]]; then
    TARGET="127.0.0.1:${SOCKS_PORT}"
  else
    TARGET="${SLIPSTREAM_TARGET:-}"
    while ! valid_hostport "${TARGET}"; do
      [[ -n "${TARGET}" ]] && warn "Expected HOST:PORT, got: ${TARGET}"
      TARGET="$(read_value 'Forward decrypted traffic to' '127.0.0.1:5201')"
    done
  fi

  DNS_PORT="${SLIPSTREAM_DNS_PORT:-}"
  while ! [[ "${DNS_PORT}" =~ ^[0-9]{1,5}$ ]] || (( DNS_PORT < 1 || DNS_PORT > 65535 )); do
    [[ -n "${DNS_PORT}" ]] && warn "Invalid port: ${DNS_PORT}"
    DNS_PORT="$(read_value 'DNS listen port' '53')"
  done
}

# --------------------------------------------------------------------------
# Port 53 conflict
# --------------------------------------------------------------------------

# systemd-resolved keeps a stub listener on 127.0.0.53:53, which collides with
# the wildcard bind slipstream-server uses.
check_port_conflict() {
  [[ "${DNS_PORT}" == "53" ]] || return 0
  systemctl is-active --quiet systemd-resolved 2>/dev/null || return 0
  grep -qsE '^\s*DNSStubListener\s*=\s*no' /etc/systemd/resolved.conf /etc/systemd/resolved.conf.d/*.conf 2>/dev/null && return 0

  warn "systemd-resolved holds a DNS stub listener on port 53."
  local answer
  answer="$(read_value 'Disable the stub listener so slipstream can bind port 53? [y/N]' 'N')"
  case "${answer}" in
    [yY]*)
      mkdir -p /etc/systemd/resolved.conf.d
      printf '[Resolve]\nDNSStubListener=no\n' > /etc/systemd/resolved.conf.d/slipstream.conf
      # Keep name resolution working once the stub is gone.
      [[ -e /etc/resolv.conf ]] && ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
      systemctl restart systemd-resolved
      log "Stub listener disabled."
      ;;
    *)
      warn "Leaving systemd-resolved as is. The service will fail to bind port 53."
      ;;
  esac
}

# --------------------------------------------------------------------------
# Download and install
# --------------------------------------------------------------------------

fetch_binaries() {
  WORK_DIR="$(mktemp -d)"
  local base="https://github.com/${UPSTREAM_REPO}/releases/download/${VERSION}"
  local archive="${WORK_DIR}/${ASSET}.tar.gz"

  log "Downloading ${ASSET}.tar.gz (${VERSION})"
  curl -fsSL --retry 3 --retry-delay 2 -o "${archive}" "${base}/${ASSET}.tar.gz" \
    || die "Download failed: ${base}/${ASSET}.tar.gz"

  # A pinned checksum only applies to the pinned version. If the operator asked
  # for a different one, fall back to the checksum published by the release.
  local expected="${EXPECTED_SHA256}"
  if [[ "${VERSION}" != "v0.1.1" ]]; then
    warn "Version overridden to ${VERSION}; verifying against the published checksum instead of the pinned one."
    expected="$(curl -fsSL --retry 3 "${base}/${ASSET}.sha256" | awk '{print $1}')" \
      || die "Could not fetch checksum for ${VERSION}"
  fi

  log "Verifying SHA256"
  printf '%s  %s\n' "${expected}" "${archive}" | sha256sum -c - >/dev/null 2>&1 \
    || die "Checksum mismatch. Refusing to install."

  tar -xzf "${archive}" -C "${WORK_DIR}" || die "Failed to extract archive."
  [[ -f "${WORK_DIR}/${ASSET}/slipstream-server" ]] || die "Archive did not contain slipstream-server."
}

install_files() {
  log "Installing binaries to ${BIN_DIR}"
  install -m 0755 "${WORK_DIR}/${ASSET}/slipstream-server" "${BIN_DIR}/slipstream-server"
  install -m 0755 "${WORK_DIR}/${ASSET}/slipstream-client" "${BIN_DIR}/slipstream-client"

  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    log "Creating system user ${SERVICE_USER}"
    useradd --system --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "${SERVICE_USER}"
  fi

  install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0750 "${CONF_DIR}" "${STATE_DIR}"
}

# microsocks is a ~30KB SOCKS5 server with no config file, packaged by the
# distribution - so it stays patched through the normal update path instead of
# needing another pinned download here.

# slipstream does not authenticate clients - certificate pinning proves the
# server to the client, not the reverse - so anyone who learns the tunnel
# domain can open a connection. The proxy's own credentials are what stops
# them turning it into an open proxy.
resolve_socks_credentials() {
  SOCKS_USER="${SLIPSTREAM_SOCKS_USER:-slipstream}"

  if [[ -n "${SLIPSTREAM_SOCKS_PASSWORD:-}" ]]; then
    SOCKS_PASS="${SLIPSTREAM_SOCKS_PASSWORD}"
  elif [[ -f "${SOCKS_CRED_PATH}" ]]; then
    # Reuse the existing password so re-running does not break configured clients.
    SOCKS_PASS="$(sed -n 's/^password=//p' "${SOCKS_CRED_PATH}" | head -1)"
    SOCKS_USER="$(sed -n 's/^username=//p' "${SOCKS_CRED_PATH}" | head -1)"
    : "${SOCKS_USER:=slipstream}"
  fi

  if [[ -z "${SOCKS_PASS:-}" ]]; then
    # Alphanumeric only: the password ends up in a systemd unit and an argv.
    # head reads a fixed block first so nothing downstream closes the pipe
    # early and trips pipefail with SIGPIPE.
    SOCKS_PASS="$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  fi

  [[ ${#SOCKS_PASS} -ge 16 ]] || die "Could not generate a SOCKS password."

  case "${SOCKS_USER}${SOCKS_PASS}" in
    *[[:space:]\'\"\$\\%]*) die "SOCKS credentials must be alphanumeric." ;;
  esac
}

install_socks() {
  [[ "${INSTALL_SOCKS}" -eq 1 ]] || return 0

  if ! command -v microsocks >/dev/null 2>&1; then
    command -v apt-get >/dev/null 2>&1 \
      || die "microsocks is not installed and this system has no apt-get. Install microsocks manually, or re-run and answer 'n' to the SOCKS prompt."
    log "Installing microsocks"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq microsocks >/dev/null 2>&1 \
      || die "Failed to install microsocks. Enable the 'universe' component, or re-run and answer 'n' to the SOCKS prompt."
  fi

  resolve_socks_credentials

  install -d -o "${SERVICE_USER}" -g "${SERVICE_USER}" -m 0750 "${CONF_DIR}"
  umask 077
  cat > "${SOCKS_CRED_PATH}" <<EOF
username=${SOCKS_USER}
password=${SOCKS_PASS}
EOF
  chmod 0600 "${SOCKS_CRED_PATH}"

  log "Writing ${SOCKS_UNIT_PATH}"
  # Bound to loopback so it is never exposed to the network directly, and
  # password-protected because the tunnel itself lets in anyone who knows the
  # domain. DynamicUser gives it a throwaway identity with no access to the
  # server's private key.
  cat > "${SOCKS_UNIT_PATH}" <<EOF
[Unit]
Description=SOCKS5 proxy for the slipstream tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
ExecStart=/usr/bin/microsocks -i 127.0.0.1 -p ${SOCKS_PORT} -u ${SOCKS_USER} -P ${SOCKS_PASS}
Restart=on-failure
RestartSec=2

# Needs no privileges at all: loopback bind on an unprivileged port.
CapabilityBoundingSet=
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectProc=invisible
UMask=0077

ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
  # The unit carries the proxy password, so keep it off world-readable mode.
  chmod 0640 "${SOCKS_UNIT_PATH}"

  log "Enabling and starting slipstream-socks"
  systemctl daemon-reload
  systemctl enable --quiet slipstream-socks.service
  systemctl restart slipstream-socks.service

  sleep 1
  if ! systemctl is-active --quiet slipstream-socks.service; then
    journalctl -u slipstream-socks.service -n 20 --no-pager >&2 || true
    die "The SOCKS5 proxy failed to start; the tunnel would have nowhere to deliver traffic."
  fi
}

write_unit() {
  log "Writing ${UNIT_PATH}"
  cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=Slipstream DNS tunnel server
Documentation=https://github.com/${UPSTREAM_REPO}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
ExecStart=${BIN_DIR}/slipstream-server \\
    --domain ${DOMAIN} \\
    --dns-listen-port ${DNS_PORT} \\
    --target-address ${TARGET} \\
    --cert ${CONF_DIR}/cert.pem \\
    --key ${CONF_DIR}/key.pem \\
    --reset-seed ${STATE_DIR}/reset-seed
Restart=on-failure
RestartSec=2

# Bind port 53 without running as root.
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes

# Filesystem isolation. The service only writes its own cert and state.
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${CONF_DIR} ${STATE_DIR}
PrivateTmp=yes
PrivateDevices=yes
ProtectProc=invisible
UMask=0077

# Kernel and process isolation.
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
RestrictAddressFamilies=AF_INET AF_INET6
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${UNIT_PATH}"
}

start_service() {
  log "Enabling and starting slipstream-server"
  systemctl daemon-reload
  systemctl enable --quiet slipstream-server.service
  systemctl restart slipstream-server.service

  sleep 2
  if ! systemctl is-active --quiet slipstream-server.service; then
    warn "Service failed to start. Recent log:"
    journalctl -u slipstream-server.service -n 30 --no-pager >&2 || true
    die "Installation finished but the service is not running."
  fi
}

summary() {
  # The server generates a self-signed certificate on first start; the client
  # pins that exact leaf, so no CA is involved.
  local fingerprint="unavailable"
  if [[ -f "${CONF_DIR}/cert.pem" ]] && command -v openssl >/dev/null 2>&1; then
    fingerprint="$(openssl x509 -in "${CONF_DIR}/cert.pem" -noout -fingerprint -sha256 2>/dev/null \
      | cut -d= -f2 || echo unavailable)"
  fi

  local forwarding="${TARGET}"
  local services="slipstream-server"
  local credentials=""
  local closing="       Anything sent to 127.0.0.1:7000 comes out at ${TARGET}."
  if [[ "${INSTALL_SOCKS}" -eq 1 ]]; then
    forwarding="${TARGET}  (SOCKS5)"
    services="slipstream-server slipstream-socks"
    credentials="  SOCKS5 username    ${SOCKS_USER}
  SOCKS5 password    ${SOCKS_PASS}
                     also saved in ${SOCKS_CRED_PATH}
"
    closing="       Then point applications at 127.0.0.1:7000 as a SOCKS5 proxy,
       using the username and password above. They are required: the tunnel
       accepts anyone who knows ${DOMAIN}, so the proxy password is what
       keeps it from being an open proxy."
  fi

  cat <<EOF

  slipstream-server is running.

  Domain            ${DOMAIN}
  DNS listen port   ${DNS_PORT}
  Forwarding to     ${forwarding}
  Certificate       ${CONF_DIR}/cert.pem
  Cert SHA256       ${fingerprint}
${credentials}
  Next steps
    1. Delegate ${DOMAIN} to this host with an NS record pointing at its
       public IP, and make sure UDP/${DNS_PORT} is reachable.
    2. Copy ${CONF_DIR}/cert.pem to the client machine.
    3. Start the client against it:

       slipstream-client --domain ${DOMAIN} --resolver <resolver-ip:53> \\
           --cert ./cert.pem --tcp-listen-port 7000

${closing}

  Manage the service
    systemctl status ${services}
    journalctl -u slipstream-server -f

EOF
}

main() {
  preflight
  detect_tty
  detect_arch
  prompt_config
  check_port_conflict
  fetch_binaries
  install_files
  install_socks
  write_unit
  start_service
  summary
}

main "$@"
