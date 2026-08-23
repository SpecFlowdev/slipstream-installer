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

# Reads a value from the terminal even when the script itself arrived on stdin
# (curl | bash). Falls back to the supplied default when no terminal exists.
read_value() {
  local prompt="$1" default="${2:-}" reply=""

  if [[ ! -r /dev/tty ]]; then
    [[ -n "${default}" ]] || die "No terminal available and no default for: ${prompt}"
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

prompt_config() {
  DOMAIN="${SLIPSTREAM_DOMAIN:-}"
  while ! valid_domain "${DOMAIN}"; do
    [[ -n "${DOMAIN}" ]] && warn "Not a valid domain: ${DOMAIN}"
    DOMAIN="$(read_value 'Tunnel domain (the zone delegated to this host, e.g. t.example.com)')"
    [[ -n "${DOMAIN}" ]] || warn "Domain is required."
  done

  TARGET="${SLIPSTREAM_TARGET:-}"
  while ! valid_hostport "${TARGET}"; do
    [[ -n "${TARGET}" ]] && warn "Expected HOST:PORT, got: ${TARGET}"
    TARGET="$(read_value 'Forward decrypted traffic to' '127.0.0.1:5201')"
  done

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

  cat <<EOF

  slipstream-server is running.

  Domain            ${DOMAIN}
  DNS listen port   ${DNS_PORT}
  Forwarding to     ${TARGET}
  Certificate       ${CONF_DIR}/cert.pem
  Cert SHA256       ${fingerprint}

  Next steps
    1. Delegate ${DOMAIN} to this host with an NS record pointing at its
       public IP, and make sure UDP/${DNS_PORT} is reachable.
    2. Copy ${CONF_DIR}/cert.pem to the client machine.
    3. Start the client against it:

       slipstream-client --domain ${DOMAIN} --resolver <resolver-ip:53> \\
           --cert ./cert.pem --tcp-listen-port 7000

  Manage the service
    systemctl status slipstream-server
    journalctl -u slipstream-server -f

EOF
}

main() {
  preflight
  detect_arch
  prompt_config
  check_port_conflict
  fetch_binaries
  install_files
  write_unit
  start_service
  summary
}

main "$@"
