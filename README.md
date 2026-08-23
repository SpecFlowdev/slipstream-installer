<div align="center">

**English** · [Русский](README.ru.md)

<img src="assets/banner.svg" alt="Slipstream Installer" width="100%">

### One-command installer for the [slipstream](https://github.com/Mygod/slipstream-rust) DNS tunnel server

Linux · x86_64 · arm64

[![License](https://img.shields.io/badge/license-Apache--2.0-3b82f6?style=flat-square)](LICENSE)
[![Upstream](https://img.shields.io/badge/slipstream-v0.1.1-22d3a8?style=flat-square)](https://github.com/Mygod/slipstream-rust/releases/tag/v0.1.1)
[![Install](https://img.shields.io/badge/install-prebuilt%20binary-38bdf8?style=flat-square)](#install)
[![Service](https://img.shields.io/badge/systemd-hardened-a78bfa?style=flat-square)](#security)

</div>

---

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/SpecFlowdev/slipstream-installer/main/install.sh | sudo bash
```

That's it. No flags, no arguments — the script asks for what it needs after it starts.

---

## Why this installer

- **No compiling** — installs a prebuilt release binary. Building slipstream from source pulls in picoquic, picotls and OpenSSL through CMake; this takes seconds instead.
- **Asks, doesn't guess** — the domain and forwarding target are prompted at runtime, so there is no command line to get wrong. Prompts read from the terminal directly, so they work even through `curl | bash`.
- **Pinned checksums** — the SHA256 of each release archive is baked into the script, not just fetched next to the download.
- **Not root at runtime** — the service runs as an unprivileged user and binds port 53 through a single capability.
- **Handles the port 53 collision** — detects the `systemd-resolved` stub listener that silently breaks DNS binds on Ubuntu and Debian, and offers to disable it.
- **Self-configuring TLS** — the server generates its own certificate on first start. No CA, no ACME, no extra open port.

---

## What gets installed

| Path | Contents |
| --- | --- |
| `/usr/local/bin/slipstream-server` | Server binary |
| `/usr/local/bin/slipstream-client` | Client binary, shipped in the same archive |
| `/etc/slipstream/` | `cert.pem`, `key.pem` — generated on first start |
| `/var/lib/slipstream/reset-seed` | Stateless-reset seed, preserved across restarts |
| `/etc/systemd/system/slipstream-server.service` | Service unit |

---

## Security

**Pinned checksums.** Release archives are verified against a SHA256 baked into `install.sh`. Checking only the `.sha256` published beside the archive would not catch a swapped release, since anyone able to replace one could replace the other. Overriding `SLIPSTREAM_VERSION` falls back to the published checksum and says so.

**No root at runtime.** The service runs as the unprivileged `slipstream` system user. Binding port 53 comes from `CAP_NET_BIND_SERVICE` alone rather than from running as root, and `NoNewPrivileges` blocks escalation.

**Sandboxed.** `ProtectSystem=strict` with `ReadWritePaths` narrowed to its own config and state directories, plus `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `ProtectProc=invisible`, kernel/cgroup/clock protections, `RestrictAddressFamilies=AF_INET AF_INET6`, `MemoryDenyWriteExecute`, and a `@system-service` syscall filter.

**No Docker, deliberately.** Upstream publishes no container image. Installing through Docker would add the daemon's root-equivalent socket to the attack surface without improving on the sandbox above.

**Certificates.** The server generates a self-signed P-256 certificate on first start, and the client pins that exact leaf. No CA is trusted and no ACME challenge port is exposed.

---

## Managing the service

```sh
systemctl status slipstream-server      # state
journalctl -u slipstream-server -f      # follow logs
systemctl restart slipstream-server     # restart
```

## Uninstall

```sh
sudo systemctl disable --now slipstream-server
sudo rm -f /etc/systemd/system/slipstream-server.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/slipstream-{server,client}
sudo rm -rf /etc/slipstream /var/lib/slipstream
sudo userdel slipstream
```

---

<div align="center">

Apache-2.0 · Installs [Mygod/slipstream-rust](https://github.com/Mygod/slipstream-rust)

</div>
