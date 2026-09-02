# Hermes

Self-hosted **Hermes** agent — the gateway and the dashboard, built from the
local source tree at `HERMES_SOURCE_DIR`
(`~/Documents/Projects/mjx-hermes-agent`).

This is the same codebase [`allr/`](../allr/) builds, one rebrand upstream.
`mjx-hermes-agent` is where the latest upstream merges land, so this instance
exists to run them side by side with the Allr fork: separate container, separate
image, separate data directory, separate hostname. Neither can see the other's
sessions, memories or state.

## Setup

```bash
cp .env.example .env
cp agent.env.example agent.env

openssl rand -base64 32          # -> HERMES_BASIC_AUTH_SECRET

$EDITOR .env                     # ports, dashboard login, source dir
$EDITOR agent.env                # OPENROUTER_API_KEY and friends
../dev up hermes
```

The first start builds the image from source and is **slow** — a multi-stage
build that compiles SQLite, installs Python via `uv` with most extras, runs
`npm install` across the workspace, and builds both the dashboard SPA and the
terminal UI. Later starts reuse the image.

- Dashboard: <https://hermes.dev.internal> (or `http://127.0.0.1:9120`)
- Login: the `HERMES_BASIC_AUTH_USERNAME` / `HERMES_BASIC_AUTH_PASSWORD` from
  `.env` (`admin` / `hermesdev` by default — deliberately simple, for testing)

Port 9120, not 9119: `allr/` already binds 9119 on the host. Inside the
container the dashboard still listens on 9119, which is what Caddy proxies to.

## Testing an upstream merge

```bash
git -C ~/Documents/Projects/mjx-hermes-agent pull
../dev down hermes
docker compose build --no-cache      # or drop --no-cache for an incremental build
../dev up hermes
```

`../dev up` does not rebuild on its own — Compose reuses an existing image tag,
so pulling new commits without a `build` leaves you testing the old tree.

## Two env files, and why

| File | Read by | Holds |
|---|---|---|
| `.env` | Docker Compose, for `${...}` interpolation | source dir, host port, dashboard login, UID/GID |
| `agent.env` | the container, via `env_file:` | provider API keys — `OPENROUTER_API_KEY`, … |

Keeping them apart means the plumbing stays diffable against
[`allr/.env.example`](../allr/.env.example) while the credentials sit in one
obvious place. Both are gitignored and both have a committed `.example`.

Hermes does **not** scrub credential env vars at startup — shell exports are a
documented way to supply them (`hermes_cli/env_loader.py`) — so everything in
`agent.env` reaches the gateway and the dashboard.

One precedence rule to know: a key present in `data/.env` beats the value from
`agent.env`. That is `get_env_value_prefer_dotenv`, and it exists so rotating a
key in `.env` mid-session is not shadowed by a stale inherited value. The
dashboard's settings page and `hermes setup` both write `data/.env`, so once you
set a key through the UI, editing `agent.env` stops having any effect for that
key until you remove it from `data/.env`.

Compose's `env_file` parser is not a shell: quotes are kept as part of the
value, so write `OPENROUTER_API_KEY=sk-or-...` with no quotes and no `export`.

## Authentication, and why it is not in Caddy

Hermes's dashboard auth gate engages automatically on **any** non-loopback bind,
and it cannot be switched off — `--insecure` and `HERMES_DASHBOARD_INSECURE` are
accepted and ignored since the June 2026 hardening, and `start_server` refuses
to bind at all when no auth provider is registered. Because Caddy has to reach
this container over `devnet`, the dashboard binds `0.0.0.0`, so an auth provider
is mandatory.

This instance uses the bundled `dashboard_auth/basic` provider: a username and
password, stateless HMAC-signed sessions, no OAuth IDP and no database. It is
configured purely through environment variables, so no secret is ever committed.

A Caddy `basic_auth` block would be the wrong layer. The Universal client
authenticates with a session cookie plus a minted WebSocket ticket, not an
`Authorization: Basic` header, so a proxy-level challenge on `/auth/login` and
the `/api/ws` upgrade would lock out the client this instance exists to test —
while duplicating a gate the application already enforces.

## What differs from upstream

| Upstream | Here | Why |
|---|---|---|
| separate `gateway` + `dashboard` containers | one container, `HERMES_DASHBOARD=1` | two containers on one data dir corrupts session and memory stores; the split only works under a shared PID namespace |
| `network_mode: host` | `devnet` bridge | Caddy routes to it by container name |
| dashboard on `127.0.0.1` | `0.0.0.0`, gated | reachable as `hermes.dev.internal` |
| no auth configured | `dashboard_auth/basic` | a non-loopback bind fails closed without a provider |
| `restart: unless-stopped` | `restart: "no"` | nothing may come back when dockerd starts |
| `~/.hermes` volume | `./data` | isolated from the real host profile, and from `allr/data` |
| host port 9119 | host port 9120 | `allr/` already has 9119 |
| — | `env_file: agent.env` | provider keys without hand-seeding `data/.env` first |
| — | `FORWARDED_ALLOW_IPS` | uvicorn otherwise trusts only `127.0.0.1` and drops Caddy's `X-Forwarded-Proto`, stripping `Secure` from session cookies |

## Data

Everything persistent lives in `./data` (gitignored), mounted at `/opt/data`
as `HERMES_HOME`: `config.yaml`, `.env`, `state.db`, `sessions/`, `memories/`,
`skills/`, `cron/`, `logs/`, `profiles/`.

It starts **empty**. With a key in `agent.env` the agent can answer immediately;
without one the dashboard runs and you can log in, but nothing else works. To
start from a profile you already have, copy `~/.hermes/config.yaml` (and
`~/.hermes/.env`) into `./data/` before the first start.

Teardown:

```bash
../dev down hermes
rm -rf data/            # destroys sessions, memories and state.db
docker image rm hermes-agent
```

## Caveats

- **The agent can run shell commands.** `TERMINAL_ENV` defaults to `local`,
  which means commands run as the in-image `hermes` user inside this container.
  The `/api/shell-pty` endpoint additionally refuses to serve a network-bound
  dashboard unless `terminal.allow_unsandboxed_shell: true` is set in
  `data/config.yaml`, so the terminal tab is off until you opt in.
- **Long agent turns can drop WebSockets.** On a non-loopback bind uvicorn's
  20s keepalive is active, and a GIL-heavy turn can stall the event loop past
  it. Clients reconnect on their own; this is upstream behaviour, not a
  proxying fault.
- **Browser CORS is hardcoded to localhost origins.** That is fine here because
  Caddy serves the SPA and the API under one hostname, so requests are
  same-origin.
- **Do not point this and `allr/` at the same data directory.** Cross-container
  sharing of one `HERMES_HOME` corrupts session files and memory stores. They
  are deliberately separate; keep them that way.
