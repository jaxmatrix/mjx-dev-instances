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

## Authentication, and why it is not in Caddy

Allr's dashboard auth gate engages automatically on **any** non-loopback bind,
and it cannot be switched off — `--insecure` and `ALLR_DASHBOARD_INSECURE` are
accepted and ignored since the June 2026 hardening, and `start_server` refuses
to bind at all when no auth provider is registered. Because Caddy has to reach
this container over `devnet`, the dashboard binds `0.0.0.0`, so an auth provider
is mandatory.

This instance uses the bundled `dashboard_auth/basic` provider: a username and
password, stateless HMAC-signed sessions, no OAuth IDP and no database. It is
configured purely through environment variables, so no secret is ever committed.

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
