#!/usr/bin/env bash
#
# slipstream-server installer.
#
# Installs a prebuilt slipstream-server release binary and registers it as a
# hardened systemd service. No compilation is involved.
#
#   sudo ./install.sh              install (asks for the domain)
#   sudo ./install.sh --uninstall  remove everything it installed
#   ./install.sh --help            every option and environment variable
#
# The script is interactive: it asks for the domain and a couple of yes/no
# questions after it starts. Every answer can also be preseeded with an
# environment variable, which makes the script usable unattended.
#
set -euo pipefail

readonly SELF_VERSION="1.1.0"
readonly UPSTREAM_REPO="Mygod/slipstream-rust"
readonly PINNED_VERSION="v0.1.1"
readonly VERSION="${SLIPSTREAM_VERSION:-${PINNED_VERSION}}"

readonly BIN_DIR="/usr/local/bin"
readonly CONF_DIR="/etc/slipstream"
readonly STATE_DIR="/var/lib/slipstream"
readonly UNIT_PATH="/etc/systemd/system/slipstream-server.service"
readonly SOCKS_UNIT_PATH="/etc/systemd/system/slipstream-socks.service"
readonly SOCKS_CRED_PATH="/etc/slipstream/socks-credentials"
readonly SYSCTL_PATH="/etc/sysctl.d/99-slipstream.conf"
readonly RESOLVED_DROPIN="/etc/systemd/resolved.conf.d/slipstream.conf"
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

# Runs on every exit, including the paths that never download anything. The
# `if` matters: as a bare `[[ ... ]] && rm`, the test failing made cleanup
# return 1, and bash hands an EXIT trap's status to the shell - so the script
# exited 1 after a *successful* install, and `./install.sh && something` never
# ran the something.
cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf "${WORK_DIR}"
  fi
}
trap cleanup EXIT

usage() {
  cat <<EOF
slipstream-server installer ${SELF_VERSION}

  sudo ./install.sh                 Install and start the server.
  sudo ./install.sh --uninstall     Stop and remove everything it installed.
       ./install.sh --help          This text.
       ./install.sh --version       Print the installer version.

Answers can be preseeded, which also makes the script run unattended:

  SLIPSTREAM_DOMAIN           Tunnel domain. Required when there is no
                              terminal to ask on.
  SLIPSTREAM_DNS_PORT         DNS listen port. Default 53.
  SLIPSTREAM_SOCKS            y/n - install a SOCKS5 proxy as the tunnel
                              target. Default y, unless SLIPSTREAM_TARGET
                              is set.
  SLIPSTREAM_SOCKS_PORT       Loopback port for that proxy. Default 1080.
  SLIPSTREAM_SOCKS_USER       Proxy username. Default slipstream.
  SLIPSTREAM_SOCKS_PASSWORD   Proxy password. Generated when unset, and
                              reused from an earlier install if present.
  SLIPSTREAM_TARGET           Forward tunnelled traffic here instead of to
                              a proxy installed by this script. HOST:PORT.

Tuning, passed straight to slipstream-server:

  SLIPSTREAM_FALLBACK         HOST:PORT to relay packets that are not DNS
                              at all to, letting another service share the
                              DNS port. Ordinary DNS queries are answered by
                              slipstream itself either way. Off when unset.
  SLIPSTREAM_MAX_CONNECTIONS  Concurrent tunnel connections. Default 256.
  SLIPSTREAM_IDLE_TIMEOUT     Seconds before an idle connection is dropped.
                              Default 60.

System changes, each asked before it happens:

  SLIPSTREAM_SYSCTL           y/n - raise the UDP socket buffers. Default y.
  SLIPSTREAM_FIREWALL         y/n - open the DNS port in ufw or firewalld.
                              Default y.
  SLIPSTREAM_VERSION          Upstream release to install. Default ${PINNED_VERSION};
                              anything else is verified against the checksum
                              published with that release rather than the one
                              pinned here.
EOF
}

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

# Yes/no with a preseed variable, used for the questions that change the
# system rather than just configure the tunnel.
confirm() {
  local prompt="$1" default="$2" preset="${3:-}" answer

  if [[ -n "${preset}" ]]; then
    answer="${preset}"
  else
    answer="$(read_value "${prompt}" "${default}")"
  fi

  case "${answer}" in
    [yY1]*|true|TRUE) return 0 ;;
    *)                return 1 ;;
  esac
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]
}

valid_hostport() {
  [[ "$1" =~ ^[^[:space:]]+:[0-9]{1,5}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 ))
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
  valid_port "${SOCKS_PORT}" || die "Invalid SOCKS port: ${SOCKS_PORT}"
}

# The tuning flags. These are deliberately environment-only: the defaults are
# right for almost everyone, and asking four more questions would make the
# common install longer for no gain.
resolve_tuning() {
  FALLBACK="${SLIPSTREAM_FALLBACK:-}"
  if [[ -n "${FALLBACK}" ]] && ! valid_hostport "${FALLBACK}"; then
    die "SLIPSTREAM_FALLBACK must be HOST:PORT, got: ${FALLBACK}"
  fi

  MAX_CONNECTIONS="${SLIPSTREAM_MAX_CONNECTIONS:-256}"
  [[ "${MAX_CONNECTIONS}" =~ ^[0-9]+$ ]] && (( MAX_CONNECTIONS >= 1 )) \
    || die "SLIPSTREAM_MAX_CONNECTIONS must be a positive number, got: ${MAX_CONNECTIONS}"

  IDLE_TIMEOUT="${SLIPSTREAM_IDLE_TIMEOUT:-60}"
  [[ "${IDLE_TIMEOUT}" =~ ^[0-9]+$ ]] && (( IDLE_TIMEOUT >= 1 )) \
    || die "SLIPSTREAM_IDLE_TIMEOUT must be a positive number of seconds, got: ${IDLE_TIMEOUT}"
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
  while ! valid_port "${DNS_PORT}"; do
    [[ -n "${DNS_PORT}" ]] && warn "Invalid port: ${DNS_PORT}"
    DNS_PORT="$(read_value 'DNS listen port' '53')"
  done

  resolve_tuning
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
  if confirm 'Disable the stub listener so slipstream can bind port 53? [y/N]' 'N'; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNSStubListener=no\n' > "${RESOLVED_DROPIN}"
    # Keep name resolution working once the stub is gone.
    [[ -e /etc/resolv.conf ]] && ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    log "Stub listener disabled."
  else
    warn "Leaving systemd-resolved as is. The service will fail to bind port 53."
  fi
}

# --------------------------------------------------------------------------
# Host tuning
# --------------------------------------------------------------------------

# The tunnel moves a great many small UDP datagrams. On a busy link the
# kernel's default socket buffers overflow, and packets it drops look like
# loss to QUIC, which then backs off - so the single largest thing standing
# between this server and its throughput is a setting the operator would
# otherwise have to find in the README and apply by hand.
#
# The `default` pair is what actually changes anything here: slipstream never
# calls setsockopt(SO_RCVBUF), so its socket gets whatever the default is. The
# `max` pair only raises the ceiling an application may ask for.
tune_sysctl() {
  confirm 'Raise the UDP socket buffers to 25 MiB (recommended)? [Y/n]' 'Y' "${SLIPSTREAM_SYSCTL:-}" || {
    log "Leaving socket buffers alone."
    return 0
  }

  log "Writing ${SYSCTL_PATH}"
  cat > "${SYSCTL_PATH}" <<'EOF'
# Installed by slipstream-installer. Remove this file to revert.
#
# The tunnel's UDP socket takes whatever rmem_default/wmem_default are, so
# those two are what raise its throughput; the max pair only lifts the
# ceiling. These apply to every socket on the machine, which is the right
# trade on a host dedicated to the tunnel and the wrong one on a shared box.
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_default=26214400
EOF
  chmod 0644 "${SYSCTL_PATH}"
  sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported a problem; the values apply on next boot."
}

# A tunnel nobody can reach looks exactly like a broken tunnel, and an
# unopened firewall is the most common reason for it. Only touches a firewall
# that is actually running.
open_firewall() {
  local tool=""
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    tool="ufw"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    tool="firewalld"
  else
    return 0
  fi

  confirm "Open UDP/${DNS_PORT} in ${tool}? [Y/n]" 'Y' "${SLIPSTREAM_FIREWALL:-}" || {
    warn "Leaving ${tool} alone. UDP/${DNS_PORT} must be reachable for the tunnel to work."
    return 0
  }

  case "${tool}" in
    ufw)
      ufw allow "${DNS_PORT}/udp" >/dev/null 2>&1 \
        && log "Opened UDP/${DNS_PORT} in ufw." \
        || warn "Could not add the ufw rule; open UDP/${DNS_PORT} by hand."
      ;;
    firewalld)
      if firewall-cmd --permanent --add-port="${DNS_PORT}/udp" >/dev/null 2>&1 \
         && firewall-cmd --reload >/dev/null 2>&1; then
        log "Opened UDP/${DNS_PORT} in firewalld."
      else
        warn "Could not add the firewalld rule; open UDP/${DNS_PORT} by hand."
      fi
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
  if [[ "${VERSION}" != "${PINNED_VERSION}" ]]; then
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
  # The release archive also carries slipstream-client; this installer is
  # server-only, so it is left unpacked.
  install -m 0755 "${WORK_DIR}/${ASSET}/slipstream-server" "${BIN_DIR}/slipstream-server"

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
install_microsocks_package() {
  command -v microsocks >/dev/null 2>&1 && return 0

  log "Installing microsocks"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq microsocks >/dev/null 2>&1 && return 0
    die "Failed to install microsocks. Enable the 'universe' component, or re-run and answer 'n' to the SOCKS prompt."
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q microsocks >/dev/null 2>&1 && return 0
    die "Failed to install microsocks. Enable EPEL, or re-run and answer 'n' to the SOCKS prompt."
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed microsocks >/dev/null 2>&1 && return 0
    die "Failed to install microsocks. Install it by hand, or re-run and answer 'n' to the SOCKS prompt."
  elif command -v apk >/dev/null 2>&1; then
    apk add --quiet microsocks >/dev/null 2>&1 && return 0
    die "Failed to install microsocks. Install it by hand, or re-run and answer 'n' to the SOCKS prompt."
  fi

  die "microsocks is not installed and no supported package manager was found. Install microsocks manually, or re-run and answer 'n' to the SOCKS prompt."
}

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

  install_microsocks_package
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
ExecStart=$(command -v microsocks) -i 127.0.0.1 -p ${SOCKS_PORT} -u ${SOCKS_USER} -P ${SOCKS_PASS}
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

  # Optional flags are assembled first so the unit only carries what was
  # actually asked for, rather than spelling out defaults.
  local extra=""
  [[ -n "${FALLBACK}" ]] && extra+=" \\
    --fallback ${FALLBACK}"

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
    --reset-seed ${STATE_DIR}/reset-seed \\
    --max-connections ${MAX_CONNECTIONS} \\
    --idle-timeout-seconds ${IDLE_TIMEOUT}${extra}
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

  # An active unit is not the same as a bound socket. slipstream-server warns
  # and carries on rather than exiting when a bind does not go its way, so the
  # unit can be happily "active" with nothing actually listening.
  #
  # Deliberately conservative: this only reports a problem when ss ran and
  # produced a listing that genuinely lacks the port. No ss, or ss returning
  # nothing at all, means we cannot tell - and a false "nothing is listening"
  # on a working install would be worse than not looking.
  command -v ss >/dev/null 2>&1 || return 0
  local listening
  listening="$(ss -lun 2>/dev/null)" || return 0
  [[ -n "${listening}" ]] || return 0

  if ! grep -qE "[:.]${DNS_PORT}([[:space:]]|$)" <<<"${listening}"; then
    warn "The service is running, but nothing appears to be listening on UDP/${DNS_PORT}."
    warn "Check the log below and whether something else holds the port."
    journalctl -u slipstream-server.service -n 20 --no-pager >&2 || true
  fi
}

summary() {
  # The server generates a self-signed certificate on first start; it is the
  # leaf that connecting clients pin, so no CA is involved.
  local fingerprint="unavailable"
  if [[ -f "${CONF_DIR}/cert.pem" ]] && command -v openssl >/dev/null 2>&1; then
    fingerprint="$(openssl x509 -in "${CONF_DIR}/cert.pem" -noout -fingerprint -sha256 2>/dev/null \
      | cut -d= -f2 || echo unavailable)"
  fi

  local forwarding="${TARGET}"
  local services="slipstream-server"
  local credentials=""
  local extras=""
  local handover="    2. Hand the domain above and ${CONF_DIR}/cert.pem to whatever
       connects to this server."

  [[ -n "${FALLBACK}" ]] && extras+="  Non-DNS relay     ${FALLBACK}
"
  if [[ "${INSTALL_SOCKS}" -eq 1 ]]; then
    forwarding="${TARGET}  (SOCKS5)"
    services="slipstream-server slipstream-socks"
    credentials="  SOCKS5 username    ${SOCKS_USER}
  SOCKS5 password    ${SOCKS_PASS}
                     also saved in ${SOCKS_CRED_PATH}
"
    handover="    2. Hand the domain above, ${CONF_DIR}/cert.pem and the SOCKS5
       credentials to whatever connects to this server. The credentials are
       required: the tunnel accepts anyone who knows ${DOMAIN}, so the proxy
       password is what keeps it from being an open proxy."
  fi

  cat <<EOF

  slipstream-server is running.

  Domain            ${DOMAIN}
  DNS listen port   ${DNS_PORT}
  Forwarding to     ${forwarding}
  Certificate       ${CONF_DIR}/cert.pem
  Cert SHA256       ${fingerprint}
${extras}${credentials}
  Next steps
    1. Delegate ${DOMAIN} to this host with an NS record pointing at its
       public IP, and make sure UDP/${DNS_PORT} is reachable.
${handover}
    3. The desktop client is at
       https://github.com/SpecFlowdev/slipstream-client

  Manage the service
    systemctl status ${services}
    journalctl -u slipstream-server -f
    sudo ./install.sh --uninstall

EOF
}

# --------------------------------------------------------------------------
# Uninstall
# --------------------------------------------------------------------------

uninstall() {
  [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./install.sh --uninstall"
  detect_tty

  log "Stopping services"
  local unit
  for unit in slipstream-server.service slipstream-socks.service; do
    systemctl disable --now --quiet "${unit}" 2>/dev/null || true
  done

  rm -f "${UNIT_PATH}" "${SOCKS_UNIT_PATH}"
  systemctl daemon-reload
  rm -f "${BIN_DIR}/slipstream-server"

  if [[ -f "${SYSCTL_PATH}" ]]; then
    rm -f "${SYSCTL_PATH}"
    sysctl --system >/dev/null 2>&1 || true
    log "Removed ${SYSCTL_PATH}"
  fi

  # The certificate is the thing clients pinned. Deleting it means every
  # configured client has to be handed a new one, so it is never removed
  # without asking - and the default is to keep it.
  if [[ -d "${CONF_DIR}" || -d "${STATE_DIR}" ]]; then
    if confirm "Delete ${CONF_DIR} and ${STATE_DIR}, including the certificate clients pinned? [y/N]" 'N'; then
      rm -rf "${CONF_DIR}" "${STATE_DIR}"
      log "Removed configuration and state."
    else
      log "Kept ${CONF_DIR} and ${STATE_DIR}."
    fi
  fi

  if id -u "${SERVICE_USER}" >/dev/null 2>&1 && [[ ! -d "${CONF_DIR}" ]]; then
    userdel "${SERVICE_USER}" 2>/dev/null || true
  fi

  if [[ -f "${RESOLVED_DROPIN}" ]]; then
    warn "systemd-resolved's stub listener is still disabled by ${RESOLVED_DROPIN}."
    warn "Remove that file and restart systemd-resolved to put it back."
  fi

  cat <<EOF

  slipstream-server has been removed.

  Anything left behind is listed above. The firewall rule, if one was added,
  is left in place - removing it is not this script's call to make.

EOF
}

# --------------------------------------------------------------------------

main() {
  case "${1:-}" in
    -h|--help)     usage; exit 0 ;;
    -v|--version)  printf 'slipstream-installer %s\n' "${SELF_VERSION}"; exit 0 ;;
    --uninstall)   uninstall; exit 0 ;;
    "")            ;;
    *)             die "Unknown option: $1 (try --help)" ;;
  esac

  preflight
  detect_tty
  detect_arch
  prompt_config
  check_port_conflict
  fetch_binaries
  install_files
  install_socks
  write_unit
  tune_sysctl
  open_firewall
  start_service
  summary
}

main "$@"
