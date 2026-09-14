# Allr

Self-hosted [Allr](https://allr.work) agent — the gateway and the dashboard,
built from the local source tree at `ALLR_SOURCE_DIR`. This is the backend that
the **Allr Universal** client (`apps/hermes-universal`, the Tauri desktop /
Android / iOS app) connects to as a *remote* gateway.

## Setup

```bash
cp .env.example .env

openssl rand -base64 32          # -> ALLR_BASIC_AUTH_SECRET

$EDITOR .env
../dev up allr
```

The first start builds the image from source and is **slow** — a multi-stage
build that compiles SQLite, installs Python 3.13 via `uv` with most extras,
runs `npm install` across the workspace, and builds both the dashboard SPA and
the terminal UI. Later starts reuse the image.

- Dashboard: <https://allr.dev.internal> (or `http://127.0.0.1:9119`)
- Login: the `ALLR_BASIC_AUTH_USERNAME` / `ALLR_BASIC_AUTH_PASSWORD` from `.env`
  (`admin` / `allrdev` by default — deliberately simple, for testing)
- Dex (OIDC): <http://auth.localhost:5556>, dev account `dev@allr.test` /
  `allrdev`. See [Login modes](#login-modes) for what it is for.

> **Rebuilding after a source change.** `../dev up allr` runs a plain
> `docker compose up -d`, which builds only when the image tag is *missing*.
> After the first build it will happily start a stale image and your change
> will look like it did nothing. Build explicitly:
>
> ```bash
> docker compose build allr && ../dev up allr
> ```
>
> Python under `hermes_cli/dashboard_auth/` is bind-mounted from the source
> tree, so edits there need only a restart — see the mount comment in
> `docker-compose.yml`.

> **If the build dies at `apt-get` with exit 100** — "Temporary failure
> resolving deb.debian.org" — that is DNS, not the Dockerfile. This host's
> only nameserver is a NetBird overlay address, which a build container on the
> default bridge cannot route to. The `build.network: host` line in
> `docker-compose.yml` is the fix; drop it if you ever move to a host with an
> ordinary resolver.

## Connecting Allr Universal

Run `./dev trust-ca` once on the machine running the client, or it will reject
Caddy's certificate. Then in Universal choose a **remote** backend and enter:

| Field | Value |
|---|---|
| URL | `https://allr.dev.internal` |
| Username | `admin` |
| Password | `allrdev` |

Universal probes `/api/status`, discovers that the backend is gated and offers a
password provider, POSTs the credentials to `/auth/login`, stores the session
cookie, then mints a single-use ticket and opens `wss://allr.dev.internal/api/ws`.

## Login modes

`dashboard.login` decides whether Allr renders its own sign-in page or hands
sign-in to an identity provider. Set it with `ALLR_LOGIN_MODE` in `.env`
(or `dashboard.login` in `data/config.yaml`; the env var wins when non-empty).

`external` only changes anything when the OIDC provider is the **only** one
registered. It deliberately still renders the page when a password provider is
present — that is the way back into a deployment whose IdP is down — so the
two knobs interact:

| `ALLR_LOGIN_MODE` | `ALLR_BASIC_AUTH_USERNAME` | `/login` does |
|---|---|---|
| `internal` | set | renders: password form + a Dex button |
| `internal` | *empty* | renders: a chooser with one Dex button |
| `external` | *empty* | **302 straight to Dex** |
| `external` | set | renders anyway — the break-glass guard |

Switching costs a container recreate, not a rebuild:

```bash
$EDITOR .env          # ALLR_LOGIN_MODE / ALLR_BASIC_AUTH_USERNAME
docker compose up -d  # recreates with the new env
```

Flipping `dashboard.login` in `data/config.yaml` is faster still — `load_config()`
caches on the file's mtime and size, so it takes effect on the next request with
no restart at all. Leave `ALLR_LOGIN_MODE` blank for that to be what decides.

### Why Dex is at `auth.localhost`, not `auth.dev.internal`

The issuer string has to be byte-identical for the browser and for the agent
container — OIDC discovery pins it — and both have to reach it. `*.localhost`
is loopback by RFC 6761, so the browser gets there via the published port,
while a `auth.localhost` network alias on the Dex service points the agent at
the same name over `devnet`.

Routing Dex through Caddy instead fails twice: the agent would have to trust
Caddy's internal CA, and CoreDNS answers every `*.dev.internal` name with
`DEV_HOST_IP` — `127.0.0.1`, which inside the agent container is the agent
itself. Plain HTTP is legal here only because of the hostname; allr-agent
rejects an `http://` issuer on anything but localhost.

## Authentication, and why it is not in Caddy

Allr's dashboard auth gate engages automatically on **any** non-loopback bind,
and it cannot be switched off — `--insecure` and `ALLR_DASHBOARD_INSECURE` are
accepted and ignored since the June 2026 hardening, and `start_server` refuses
to bind at all when no auth provider is registered. Because Caddy has to reach
this container over `devnet`, the dashboard binds `0.0.0.0`, so an auth provider
is mandatory.

This instance registers two providers, both purely from environment variables,
so no secret is ever committed:

- `dashboard_auth/basic` — a username and password, stateless HMAC-signed
  sessions, no IDP and no database. This is what the Universal client logs in
  against, so it is a feature here rather than an obstacle.
- `dashboard_auth/self_hosted` — generic OIDC, pointed at the Dex container.
  Present so [`dashboard.login: external`](#login-modes) has a non-password
  provider to hand off to; blank the basic-auth vars to leave it alone.

A Caddy `basic_auth` block would be the wrong layer. Universal authenticates
with a session cookie plus a minted WebSocket ticket, not an `Authorization:
Basic` header, so a proxy-level challenge on `/auth/login` and the `/api/ws`
upgrade would lock out the client this instance exists to test — while
duplicating a gate the application already enforces.

## What differs from upstream

| Upstream | Here | Why |
|---|---|---|
| separate `gateway` + `dashboard` containers | one container, `ALLR_DASHBOARD=1` | two containers on one data dir corrupts session and memory stores; the split only works under a shared PID namespace |
| `network_mode: host` | `devnet` bridge | Caddy routes to it by container name |
| dashboard on `127.0.0.1` | `0.0.0.0`, gated | reachable as `allr.dev.internal` |
| no auth configured | `dashboard_auth/basic` | a non-loopback bind fails closed without a provider |
| — | `dashboard_auth/self_hosted` + a Dex container | a non-password provider is the only way `dashboard.login: external` is observable |
| `restart: unless-stopped` | `restart: "no"` | nothing may come back when dockerd starts |
| `~/.allr` volume | `./data` | isolated from the real host profile |
| — | `FORWARDED_ALLOW_IPS` | uvicorn otherwise trusts only `127.0.0.1` and drops Caddy's `X-Forwarded-Proto`, stripping `Secure` from session cookies |

## Data

Everything persistent lives in `./data` (gitignored), mounted at `/opt/data`:
`config.yaml`, `.env`, `state.db`, `sessions/`, `memories/`, `skills/`, `cron/`,
`logs/`, `profiles/`.

It starts **empty**. The dashboard runs and you can log in, but the agent cannot
answer anything until it has an LLM provider key. Either add one in the
dashboard's settings after logging in, or seed the files directly — e.g. copy
`~/.allr/config.yaml` and `~/.allr/.env` into `./data/` if you already have a
working profile on the host.

Teardown:

```bash
../dev down allr
rm -rf data/            # destroys sessions, memories and state.db
rm -rf dex/data/        # Dex's sqlite: signing keys, so this invalidates tokens
docker image rm allr-agent
```

## Caveats

- **The agent can run shell commands.** `TERMINAL_ENV` defaults to `local`,
  which means commands run as the in-image `hermes` user inside this container.
  The `/api/shell-pty` endpoint additionally refuses to serve a network-bound
  dashboard unless `terminal.allow_unsandboxed_shell: true` is set in
  `data/config.yaml`, so the terminal tab is off until you opt in.
- **Long agent turns can drop WebSockets.** On a non-loopback bind uvicorn's
  20s keepalive is active, and a GIL-heavy turn can stall the event loop past
  it. Universal reconnects on its own; this is upstream behaviour, not a
  proxying fault.
- **Browser CORS is hardcoded to localhost origins.** That is fine here because
  Caddy serves the SPA and the API under one hostname, so requests are
  same-origin.
