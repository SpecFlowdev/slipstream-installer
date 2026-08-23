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

---

## Requirements

- **Linux with systemd**, x86_64 or arm64
- **Root**, to install the service and bind the DNS port
- **A domain you control**, whose `NS` record can be pointed at this host
- **UDP reachable** on the listen port, port 53 by default

---

## Why this installer

- **Usable the moment it finishes** — offers to install a SOCKS5 proxy as the tunnel's target, so the client's local port works as a proxy straight away instead of pointing at a port with nothing behind it.
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
| `/usr/local/bin/slipstream-server` | Server binary — the service runs this |
| `/usr/local/bin/slipstream-client` | Client binary, bundled in the same archive; useful for testing the tunnel from the server itself |
| `/etc/slipstream/` | `cert.pem`, `key.pem` — generated on first start |
| `/var/lib/slipstream/reset-seed` | Stateless-reset seed, preserved across restarts |
| `/etc/systemd/system/slipstream-server.service` | Service unit |

With the SOCKS5 proxy enabled, two more:

| Path | Contents |
| --- | --- |
| `/usr/bin/microsocks` | SOCKS5 server, installed from the distribution's packages |
| `/etc/systemd/system/slipstream-socks.service` | Proxy service unit, bound to loopback |
| `/etc/slipstream/socks-credentials` | SOCKS5 username and password, mode 0600 |

---

## Using the tunnel

Start the client on your own machine with the certificate copied from the server:

```sh
slipstream-client --domain t.example.com --resolver <resolver-ip:53> \
    --cert ./cert.pem --tcp-listen-port 7000
```

With the SOCKS5 proxy installed, point applications at `127.0.0.1:7000` as a **SOCKS5 proxy** and they go out through the server. Use the username and password the installer printed — they are also in `/etc/slipstream/socks-credentials` on the server, and they are what stops anyone who discovers your domain from using the proxy too.

Without the proxy, that port is a plain TCP forward to whatever target you chose.

---

## Security

**Pinned checksums.** Release archives are verified against a SHA256 baked into `install.sh`. Checking only the `.sha256` published beside the archive would not catch a swapped release, since anyone able to replace one could replace the other. Installing a non-default release falls back to that release's published checksum, and the script says so when it does.

**No root at runtime.** The service runs as the unprivileged `slipstream` system user. Binding port 53 comes from `CAP_NET_BIND_SERVICE` alone rather than from running as root, and `NoNewPrivileges` blocks escalation.

**Sandboxed.** `ProtectSystem=strict` with `ReadWritePaths` narrowed to its own config and state directories, plus `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `ProtectProc=invisible`, kernel/cgroup/clock protections, `RestrictAddressFamilies=AF_INET AF_INET6`, `MemoryDenyWriteExecute`, and a `@system-service` syscall filter.

**No Docker, deliberately.** Upstream publishes no container image. Installing through Docker would add the daemon's root-equivalent socket to the attack surface without improving on the sandbox above.

**Certificates.** The server generates a self-signed P-256 certificate on first start, and the client pins that exact leaf. No CA is trusted and no ACME challenge port is exposed.

**The tunnel does not authenticate clients.** Certificate pinning proves the *server's* identity to the client, not the other way round — the server accepts any client that completes the handshake. Anyone who learns your tunnel domain can therefore open a connection and reach whatever sits at the forwarding target. That is why the SOCKS5 proxy is installed with a username and a 24-character random password, generated at install time and saved to `/etc/slipstream/socks-credentials`. Point the tunnel at a target of your own instead and that service needs access control of its own.

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
sudo systemctl disable --now slipstream-server slipstream-socks
sudo rm -f /etc/systemd/system/slipstream-{server,socks}.service
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/slipstream-{server,client}
sudo rm -rf /etc/slipstream /var/lib/slipstream
sudo userdel slipstream
sudo apt-get remove -y microsocks    # only if the proxy was installed
```

---

<div align="center">

Apache-2.0 · Installs [Mygod/slipstream-rust](https://github.com/Mygod/slipstream-rust)

</div>
