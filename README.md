# slipstream-installer

Interactive installer for [slipstream](https://github.com/Mygod/slipstream-rust)
server — a DNS tunnel that carries QUIC over DNS queries and responses.

The installer downloads a **prebuilt release binary** and registers it as a
hardened systemd service. Nothing is compiled, so a fresh install takes seconds.

## Usage

```sh
git clone https://github.com/SpecFlowdev/slipstream-installer
cd slipstream-installer
sudo ./install.sh
```

The script asks for the domain and the forwarding target after it starts:

```
Tunnel domain (the zone delegated to this host, e.g. t.example.com): t.example.com
Forward decrypted traffic to [127.0.0.1:5201]:
DNS listen port [53]:
```

## Unattended install

Every prompt can be preseeded. When a variable is set, its prompt is skipped.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SLIPSTREAM_DOMAIN` | — | Tunnel domain (required) |
| `SLIPSTREAM_TARGET` | `127.0.0.1:5201` | Where decrypted traffic is forwarded |
| `SLIPSTREAM_DNS_PORT` | `53` | UDP port the server listens on |
| `SLIPSTREAM_VERSION` | `v0.1.1` | Upstream release to install |

```sh
sudo SLIPSTREAM_DOMAIN=t.example.com SLIPSTREAM_TARGET=127.0.0.1:1080 ./install.sh
```

## What gets installed

| Path | Contents |
| --- | --- |
| `/usr/local/bin/slipstream-server` | Server binary |
| `/usr/local/bin/slipstream-client` | Client binary (shipped in the same archive) |
| `/etc/slipstream/` | `cert.pem`, `key.pem` |
| `/var/lib/slipstream/reset-seed` | Stateless-reset seed, kept across restarts |
| `/etc/systemd/system/slipstream-server.service` | Service unit |

Supported architectures: `x86_64` and `arm64`.

## Security notes

**Pinned checksums.** The SHA256 of each release archive is baked into
`install.sh` and checked before anything is unpacked. Verifying only against the
`.sha256` file published next to the archive would not detect a swapped release,
since an attacker able to replace one could replace both. Overriding
`SLIPSTREAM_VERSION` falls back to the published checksum and warns about it.

**No root at runtime.** The service runs as the unprivileged `slipstream` system
user. Binding port 53 is granted through `CAP_NET_BIND_SERVICE` alone rather
than by running as root, and `NoNewPrivileges` blocks privilege escalation.

**Sandboxed.** The unit applies `ProtectSystem=strict` with `ReadWritePaths`
limited to its own config and state directories, plus `PrivateTmp`,
`PrivateDevices`, `ProtectHome`, `ProtectProc=invisible`, kernel and cgroup
protections, `RestrictAddressFamilies=AF_INET AF_INET6`,
`MemoryDenyWriteExecute`, and a `@system-service` syscall filter.

**No Docker.** Upstream publishes no container image, and a Docker install would
add the daemon's root-equivalent socket to the attack surface without improving
isolation over the systemd sandbox above.

**Certificates.** The server generates a self-signed P-256 certificate on first
start. The client pins that exact leaf certificate, so no CA is involved and no
ACME challenge port needs to be exposed.

## After installing

1. Delegate the domain to this host with an `NS` record pointing at its public
   IP, and open UDP on the listen port.
2. Copy `/etc/slipstream/cert.pem` to the client machine.
3. Connect:

   ```sh
   slipstream-client --domain t.example.com --resolver <resolver-ip:53> \
       --cert ./cert.pem --tcp-listen-port 7000
   ```

## Managing the service

```sh
systemctl status slipstream-server
systemctl restart slipstream-server
journalctl -u slipstream-server -f
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

## License

Apache-2.0
