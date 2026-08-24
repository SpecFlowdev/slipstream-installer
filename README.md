<div align="center">

**English** · [Русский](README.ru.md)

<img src="assets/banner.svg" alt="Slipstream Server Installer" width="100%">

### One-command installer for the [slipstream](https://github.com/Mygod/slipstream-rust) DNS tunnel **server**

Linux · x86_64 · arm64

[![License](https://img.shields.io/badge/license-Apache--2.0-3b82f6?style=flat-square)](LICENSE)
[![Upstream](https://img.shields.io/badge/slipstream-v0.1.1-22d3a8?style=flat-square)](https://github.com/Mygod/slipstream-rust/releases/tag/v0.1.1)
[![Install](https://img.shields.io/badge/install-prebuilt%20binary-38bdf8?style=flat-square)](#install)
[![Service](https://img.shields.io/badge/systemd-hardened-a78bfa?style=flat-square)](#security)

</div>

---

## Install

Run on the machine that will host the tunnel server:

```sh
curl -fsSL https://raw.githubusercontent.com/SpecFlowdev/slipstream-installer/main/install.sh | sudo bash
```

It asks for the tunnel domain, offers to put a SOCKS5 proxy behind it, and prints everything a client needs when it finishes.

```sh
sudo ./install.sh --uninstall   # stop and remove everything it installed
./install.sh --help             # every option and environment variable
```

---

## Running it unattended

Every answer can be preseeded, which also makes the script usable from a provisioning tool. Only the domain has no sensible default:

```sh
SLIPSTREAM_DOMAIN=t.example.com sudo -E ./install.sh
```

| Variable | Default | What it does |
| --- | --- | --- |
| `SLIPSTREAM_DOMAIN` | — | Tunnel domain. Required when there is no terminal to ask on |
| `SLIPSTREAM_DNS_PORT` | `53` | DNS listen port |
| `SLIPSTREAM_SOCKS` | `y` | Install a SOCKS5 proxy as the tunnel target |
| `SLIPSTREAM_SOCKS_PORT` | `1080` | Loopback port for that proxy |
| `SLIPSTREAM_SOCKS_USER` | `slipstream` | Proxy username |
| `SLIPSTREAM_SOCKS_PASSWORD` | generated | Proxy password; reused from an earlier install when present |
| `SLIPSTREAM_TARGET` | — | Forward to your own service instead of an installed proxy |
| `SLIPSTREAM_SYSCTL` | `y` | Raise the UDP socket buffers |
| `SLIPSTREAM_FIREWALL` | `y` | Open the DNS port in `ufw` or `firewalld` |
| `SLIPSTREAM_VERSION` | `v0.1.1` | Upstream release to install |

Three more are passed straight through to `slipstream-server`:

| Variable | Default | What it does |
| --- | --- | --- |
| `SLIPSTREAM_MAX_CONNECTIONS` | `256` | Concurrent tunnel connections |
| `SLIPSTREAM_IDLE_TIMEOUT` | `60` | Seconds before an idle connection is dropped |
| `SLIPSTREAM_FALLBACK` | off | `HOST:PORT` to relay packets that **are not DNS** to, letting another service share the DNS port. Ordinary DNS queries are answered by slipstream itself either way |

---

## Requirements

- **Linux with systemd**, x86_64 or arm64
- **Root**, to install the service and bind the DNS port
- **A domain you control**, whose `NS` record can be pointed at this host. Keep it short: the client's payload per query is `(240 − domain length) / 1.6` bytes, so a shorter domain is a faster tunnel
- **UDP reachable** on the listen port, port 53 by default

---

## Why this installer

- **Usable the moment it finishes** — offers to install a SOCKS5 proxy as the tunnel's target, so connecting clients reach a working proxy instead of a port with nothing behind it.
- **No compiling** — installs a prebuilt release binary. Building slipstream from source pulls in picoquic, picotls and OpenSSL through CMake; this takes seconds instead.
- **Asks, doesn't guess** — the domain and forwarding target are prompted at runtime, so there is no command line to get wrong. Prompts read from the terminal directly, so they work even through `curl | bash`.
- **Pinned checksums** — the SHA256 of each release archive is baked into the script, not just fetched next to the download.
- **Not root at runtime** — the service runs as an unprivileged user and binds port 53 through a single capability.
- **Handles the port 53 collision** — detects the `systemd-resolved` stub listener that silently breaks DNS binds on Ubuntu and Debian, and offers to disable it.
- **Tunes the host** — offers to raise the UDP socket buffers, which is the single largest thing standing between this server and its throughput and otherwise a step people skip.
- **Opens the firewall** — spots a running `ufw` or `firewalld` and offers to let the DNS port through, since an unopened firewall looks exactly like a broken tunnel.
- **Checks the port really bound** — an active unit is not a listening socket; slipstream warns and carries on when a bind does not go its way, so the installer looks at the socket rather than trusting the unit.
- **Removes itself** — `--uninstall` stops the services, deletes the units, binary and tuning file, and asks before touching the certificate your clients pinned.
- **Self-configuring TLS** — the server generates its own certificate on first start. No CA, no ACME, no extra open port.

---

## Tuning the socket buffers

The tunnel moves a lot of small UDP datagrams. On a busy link the kernel's
default socket buffers overflow and the packets it drops look like loss to
QUIC, which backs off.

**The installer offers to do this for you** and writes the same file; answer
`n`, or set `SLIPSTREAM_SYSCTL=n`, to keep the host untouched. By hand it is:

```sh
sudo tee /etc/sysctl.d/99-slipstream.conf >/dev/null <<'EOF'
net.core.rmem_max=26214400
net.core.wmem_max=26214400
net.core.rmem_default=26214400
net.core.wmem_default=26214400
EOF
sudo sysctl --system
```

The two `default` values are the ones that change anything here: slipstream
never calls `setsockopt(SO_RCVBUF)`, so its UDP socket gets whatever the
default is. The `max` pair only raises the ceiling an application is allowed
to ask for, and is worth setting so nothing is capped later.

Note that `rmem_default` and `wmem_default` apply to **every** socket on the
host, so this trades memory across all processes for tunnel throughput. On a
machine that only runs the tunnel that is the intent; on a shared box, set
just the `max` pair and leave the defaults alone.

---

## What gets installed

| Path | Contents |
| --- | --- |
| `/usr/local/bin/slipstream-server` | Server binary — the service runs this |
| `/etc/slipstream/` | `cert.pem`, `key.pem` — generated on first start |
| `/var/lib/slipstream/reset-seed` | Stateless-reset seed, preserved across restarts |
| `/etc/systemd/system/slipstream-server.service` | Service unit |
| `/etc/sysctl.d/99-slipstream.conf` | UDP buffer sizes, only if you accepted the tuning |

With the SOCKS5 proxy enabled, three more:

| Path | Contents |
| --- | --- |
| `microsocks` | SOCKS5 server, installed from the distribution's packages (`apt`, `dnf`, `pacman` or `apk`) |
| `/etc/systemd/system/slipstream-socks.service` | Proxy service unit, bound to loopback |
| `/etc/slipstream/socks-credentials` | SOCKS5 username and password, mode 0600 |

---

## Connecting to it

This repository installs and configures the **server only**. The client is a separate project: [SpecFlowdev/slipstream-client](https://github.com/SpecFlowdev/slipstream-client) — a desktop app for Linux and Windows, with its own downloads and documentation.

Everything a client needs is produced here, and the installer prints all of it when it finishes:

| Setting | Where it comes from |
| --- | --- |
| Tunnel domain | What you entered during install |
| Server certificate | `/etc/slipstream/cert.pem` — copy it to the client; it is public data, not a secret |
| SOCKS5 username and password | Printed at the end, and stored in `/etc/slipstream/socks-credentials` |

---

## Security

**Pinned checksums.** Release archives are verified against a SHA256 baked into `install.sh`. Checking only the `.sha256` published beside the archive would not catch a swapped release, since anyone able to replace one could replace the other. Installing a non-default release falls back to that release's published checksum, and the script says so when it does.

**No root at runtime.** The service runs as the unprivileged `slipstream` system user. Binding port 53 comes from `CAP_NET_BIND_SERVICE` alone rather than from running as root, and `NoNewPrivileges` blocks escalation.

**Sandboxed.** `ProtectSystem=strict` with `ReadWritePaths` narrowed to its own config and state directories, plus `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `ProtectProc=invisible`, kernel/cgroup/clock protections, `RestrictAddressFamilies=AF_INET AF_INET6`, `MemoryDenyWriteExecute`, and a `@system-service` syscall filter.

**No Docker, deliberately.** Upstream publishes no container image. Installing through Docker would add the daemon's root-equivalent socket to the attack surface without improving on the sandbox above.

**Certificates.** The server generates a self-signed P-256 certificate on first start, and the client pins that exact leaf. No CA is trusted and no ACME challenge port is exposed.

**The tunnel does not authenticate clients.** Certificate pinning proves the *server's* identity to the client, not the other way round — the server accepts any client that completes the handshake. Anyone who learns your tunnel domain can therefore open a connection and reach whatever sits at the forwarding target. That is why the SOCKS5 proxy is installed with a username and a 24-character random password, generated at install time and saved to `/etc/slipstream/socks-credentials`. Point the tunnel at a target of your own instead and that service needs access control of its own.

**Keeping the domain secret is not a control.** Delegating the zone by `NS` publishes it by construction, and queries reach you through whichever recursive resolvers your clients use, so filtering by source address is not available either. A long random subdomain does not fix that — sustained tunnel traffic surfaces in passive DNS anyway — and it costs throughput directly: the client's payload per query is `(240 − domain length) / 1.6` bytes, so every extra character is bandwidth given up. Treat the authentication on the forwarding target as the security boundary, not the domain.

**The proxy is not exposed directly.** `microsocks` binds `127.0.0.1` only, so it is never reachable from the network — just through the tunnel, or from the host. It runs under `DynamicUser`, a throwaway identity with an empty capability set and no access to the server's private key. The password is kept out of `ps` by microsocks itself and out of world-readable files by mode `0640` on the unit, though any local user on the host can still reach the proxy port.

---

## Managing the service

```sh
systemctl status slipstream-server      # state
journalctl -u slipstream-server -f      # follow logs
systemctl restart slipstream-server     # restart
```

---

## Uninstall

```sh
sudo ./install.sh --uninstall
```

Stops and disables both services, removes the units, the binary and the
sysctl file, and drops the `slipstream` user.

The certificate is what your clients pinned, so `/etc/slipstream` and
`/var/lib/slipstream` are **kept unless you say otherwise** — deleting them
means handing every configured client a new certificate. The script asks, and
defaults to keeping them.

Two things it deliberately leaves alone, both reported at the end: a firewall
rule it may have added, and the `systemd-resolved` stub listener if that was
disabled during install. Removing either is a decision about the host, not
about this tunnel. `microsocks` came from your package manager and is removed
the same way, if you want it gone.

---

<div align="center">

Apache-2.0 · Installs [Mygod/slipstream-rust](https://github.com/Mygod/slipstream-rust)

</div>
