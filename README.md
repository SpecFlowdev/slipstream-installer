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

That's it. No flags, no arguments — the script asks for what it needs after it starts:

```
==> Tunnel domain (the zone delegated to this host, e.g. t.example.com): t.example.com
==> Forward decrypted traffic to [127.0.0.1:5201]:
==> DNS listen port [53]:

==> Downloading slipstream-linux-x86_64.tar.gz (v0.1.1)
==> Verifying SHA256
==> Installing binaries to /usr/local/bin
==> Creating system user slipstream
==> Writing /etc/systemd/system/slipstream-server.service
==> Enabling and starting slipstream-server

  slipstream-server is running.
```

Prefer to read before you run? Reasonable:

```sh
git clone https://github.com/SpecFlowdev/slipstream-installer
cd slipstream-installer
sudo ./install.sh
```

---

## Why this installer

- **No compiling** — installs a prebuilt release binary. Building slipstream from source pulls in picoquic, picotls and OpenSSL through CMake; this takes seconds instead.
- **Asks, doesn't guess** — the domain and forwarding target are prompted at runtime, so there is no command line to get wrong. Prompts read from the terminal directly, so they work even through `curl | bash`.
- **Pinned checksums** — the SHA256 of each release archive is baked into the script, not just fetched next to the download.
- **Not root at runtime** — the service runs as an unprivileged user and binds port 53 through a single capability.
- **Handles the port 53 collision** — detects the `systemd-resolved` stub listener that silently breaks DNS binds on Ubuntu and Debian, and offers to disable it.
- **Self-configuring TLS** — the server generates its own certificate on first start. No CA, no ACME, no extra open port.

---

## Configuration

Every prompt can be preseeded with an environment variable. When one is set, its prompt is skipped — which makes the same script usable unattended.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SLIPSTREAM_DOMAIN` | *(prompted)* | Tunnel domain delegated to this host |
| `SLIPSTREAM_TARGET` | `127.0.0.1:5201` | Where decrypted traffic is forwarded |
| `SLIPSTREAM_DNS_PORT` | `53` | UDP port the server listens on |
| `SLIPSTREAM_VERSION` | `v0.1.1` | Upstream release to install |

```sh
sudo SLIPSTREAM_DOMAIN=t.example.com SLIPSTREAM_TARGET=127.0.0.1:1080 ./install.sh
```

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

## After installing

**1. Delegate the domain.** Point an `NS` record for your tunnel domain at this host's public IP, and open UDP on the listen port.

```
t.example.com.    IN  NS  ns1.example.com.
ns1.example.com.  IN  A   203.0.113.10
```

**2. Copy the certificate** from `/etc/slipstream/cert.pem` to the client machine. The client pins this exact certificate, so it has to be transferred once by hand.

**3. Connect.**

```sh
slipstream-client --domain t.example.com --resolver 1.1.1.1:53 \
    --cert ./cert.pem --tcp-listen-port 7000
```

Traffic sent to `127.0.0.1:7000` on the client now surfaces at the server's forwarding target.

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
