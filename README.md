# dev_instances

Self-hosted services for development, each in its own folder, **started by hand
and never on boot**.

| Instance | What it is | Dev URL |
|---|---|---|
| [`shared/`](shared/) | Postgres 17 + Valkey 8.1, used by any instance that needs them | — |
| [`openviking/`](openviking/) | OpenViking context DB, Gemini embedding 2 + LiteLLM VLM | <https://openviking.dev.internal> |
| [`penpot/`](penpot/) | Penpot design tool | <https://penpot.dev.internal> |
| [`allr/`](allr/) | Allr agent gateway + dashboard | <https://allr.dev.internal> |
| [`hermes/`](hermes/) | Hermes agent gateway + dashboard — the upstream of `allr/` | <https://hermes.dev.internal> |
| [`devdns/`](devdns/) | CoreDNS for `*.dev.internal` + Caddy wildcard TLS | *(serves the rest)* |

Two rules shape the whole repo:

1. **Nothing starts automatically.** Docker is never enabled at boot, and every
   service in every compose file uses `restart: "no"` — including the ones
   upstream ships as `always` or `unless-stopped`, which would otherwise come
   back the moment `dockerd` starts.
2. **Datastores are shared, not duplicated.** An instance that needs Postgres or
   Redis uses `shared/` rather than declaring its own. Penpot's bundled
   `penpot-postgres` and `penpot-valkey` services are removed for exactly this
   reason.

## One-time host setup

```bash
sudo pacman -S --needed docker docker-compose docker-buildx
sudo usermod -aG docker $USER     # then log out and back in
```

Do **not** run `systemctl enable docker`. Arch does not enable it on install, so
there is nothing to undo — just never enable it. Start it per session:

```bash
sudo systemctl start docker.socket
```

Then configure the repo:

```bash
cp .env.example .env
$EDITOR .env                      # DEV_HOST_IP — see devdns/README.md
```

Each instance has its own `.env.example` documenting its secrets. `./dev` refuses
to start an instance whose `.env` is missing and tells you what to copy.

## Usage

```bash
./dev up devdns                   # DNS + TLS
./dev trust-ca                    # install Caddy's root CA (once per machine)

./dev up penpot                   # brings up shared/, creates its DB, then starts
./dev up openviking
./dev up allr                     # first run builds the image — slow
./dev up hermes                   # same, from the upstream source tree

./dev status
./dev logs penpot penpot-backend
./dev down penpot                 # leaves everything else running
./dev down --all
```

`./dev up` handles the ordering that Compose cannot express across projects: it
creates the `devnet` network, starts `shared/` when the instance needs it, waits
for Postgres and Valkey to report healthy, creates the instance's database role
if absent, and only then starts the instance.

Adding another service means dropping in a folder with a `docker-compose.yml`
and an `instance.env` — `./dev` discovers it, and the DNS wildcard already
resolves its name. Only a `handle` block in `devdns/caddy/Caddyfile` is needed.

## How the dev domain works

```
*.dev.internal ──► CoreDNS ──► DEV_HOST_IP ──► Caddy :443 ──► routed by Host header
anything else  ──► CoreDNS ──► 1.1.1.1 / 9.9.9.9
```

CoreDNS is a *complete* resolver, not just an authority for one domain, which is
what lets it be registered in NetBird as a **primary** nameserver. That form is
required here: NetBird match domains on Linux need `systemd-resolved`, which is
inactive on this machine. See [`devdns/README.md`](devdns/README.md) for the
NetBird dashboard settings and the trade-off that comes with it.

Caddy issues a wildcard certificate from its own local CA, so dev links are real
HTTPS. That is the point of the whole arrangement — OAuth redirect URIs and
`Secure`-flagged session cookies cannot be tested against `localhost` alone.

### Reaching it from other NetBird peers

Out of the box `DEV_HOST_IP=127.0.0.1`, which is local-only: a remote peer that
resolved `penpot.dev.internal` would get its own loopback. Three things make the
dev domain work across the mesh:

1. **Point the domain at this peer.** Read this machine's NetBird address with
   `netbird status | grep 'NetBird IP'` and set it as `DEV_HOST_IP` in both
   `.env` and `devdns/.env`, then `./dev restart devdns` — the Corefile is
   templated at container start, so a restart is required.
2. **Register CoreDNS in the NetBird dashboard** under **DNS → Nameservers**:
   the peer's NetBird IP on `53/udp`, **no match domains — mark it primary /
   "all domains"**, distributed to the groups that should resolve dev names.
   Match domains on Linux need `systemd-resolved`, which is inactive here; the
   primary form is safe because CoreDNS forwards everything outside
   `dev.internal` upstream.
3. **Install the root CA on each peer.** `./dev trust-ca --export-only` writes
   `devdns/caddy/root.crt` for copying; DNS alone only gets them to Caddy.

Verify from another peer with `netbird status -d | grep -i nameservers`
(`1/1 Available`) and `dig penpot.dev.internal +short`.

The full procedure, the primary-vs-match-domain rationale, the trade-off that
comes with it, and troubleshooting are in [`devdns/README.md`](devdns/README.md).

### Caveat: Google and Apple OAuth

Both require redirect URIs on a public, verifiable domain and will reject
`*.dev.internal` at registration time. GitHub, GitLab, and self-hosted OIDC
providers (Keycloak, Authentik, Zitadel) accept arbitrary hosts and work fine.

If a Google or Apple login has to be tested, the escape hatch is a real owned
domain with a Let's Encrypt **DNS-01** wildcard certificate, served by the same
Caddy and resolved internally by the same CoreDNS to NetBird IPs — a Caddyfile
and Corefile change rather than a redesign.

## Ports

Everything is loopback-only except DNS and the proxy, which have to be reachable
from other peers.

| Service | Host bind |
|---|---|
| CoreDNS | `0.0.0.0:53` udp+tcp |
| Caddy | `0.0.0.0:80`, `0.0.0.0:443` |
| Postgres | `127.0.0.1:5432` |
| Valkey | `127.0.0.1:6379` |
| OpenViking | `127.0.0.1:1933` |
| Penpot | `127.0.0.1:9001` |
| Allr dashboard | `127.0.0.1:9119` |
| Hermes dashboard | `127.0.0.1:9120` |
| Mailcatcher | `127.0.0.1:1080` |

## Verifying nothing starts on boot

```bash
systemctl is-enabled docker docker.socket    # both: disabled
grep -rh 'restart:' */docker-compose.yml | sort -u   # only restart: "no"
```

After a reboot, `docker ps` should error because the daemon is not running.
