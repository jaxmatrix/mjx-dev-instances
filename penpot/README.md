# Penpot

Self-hosted [Penpot](https://penpot.app). Based on the upstream compose file,
with the bundled Postgres and Valkey removed in favour of the shared `shared/`
stack.

## Setup

```bash
cp .env.example .env

# Master key
python3 -c "import secrets; print(secrets.token_urlsafe(64))"   # -> PENPOT_SECRET_KEY
openssl rand -base64 24                                          # -> PENPOT_DATABASE_PASSWORD

$EDITOR .env
../dev up penpot
```

`./dev` starts `shared/`, waits for Postgres and Valkey to report healthy,
creates the `penpot` role and database if they do not exist, then starts this
project. The backend runs its own migrations on first boot.

- App: <https://penpot.dev.internal> (or `http://127.0.0.1:9001`)
- Mail sink: <https://mail.dev.internal> (or `http://127.0.0.1:1080`)

Email verification is disabled, but invitations and password resets still send
mail — read it in the mailcatcher rather than configuring a real SMTP provider.

## What differs from upstream

| Upstream | Here | Why |
|---|---|---|
| `penpot-postgres` service | `postgresql://shared-postgres/penpot` | one shared Postgres for all instances |
| `penpot-valkey` service | `redis://shared-valkey/1` | one shared cache; index 1 avoids collisions |
| `restart: always` | `restart: "no"` | nothing may come back when dockerd starts |
| `disable-secure-session-cookies` | removed | Caddy terminates real TLS |
| `PENPOT_TELEMETRY_ENABLED: true` | `false` | dev instance |
| `depends_on: service_healthy` on db | handled by `./dev` | compose `depends_on` cannot cross projects |

Postgres 17 is well within Penpot's requirement of >= 13.

## Accessing over plain HTTP

`PENPOT_PUBLIC_URI` must match how the browser actually reaches Penpot. To use
`http://127.0.0.1:9001` instead of the dev domain, set that as
`PENPOT_PUBLIC_URI` **and** add `disable-secure-session-cookies` to
`PENPOT_FLAGS` in `docker-compose.yml` — otherwise the session cookie is marked
Secure, the browser drops it over HTTP, and login silently fails to stick.

## OIDC / OAuth

Testing OAuth against a real hostname is the reason the dev domain exists. To
enable it, add `enable-login-with-oidc` to `PENPOT_FLAGS` and set on the backend:

```yaml
PENPOT_OIDC_BASE_URI: https://auth.dev.internal/
PENPOT_OIDC_CLIENT_ID: penpot
PENPOT_OIDC_CLIENT_SECRET: ...
```

Endpoints are autodiscovered from `PENPOT_OIDC_BASE_URI`; override individually
with `PENPOT_OIDC_AUTH_URI`, `PENPOT_OIDC_TOKEN_URI`, `PENPOT_OIDC_USER_URI` and
`PENPOT_OIDC_JWKS_URI` if the provider has no discovery document.

The redirect URI to register with the provider is
`https://penpot.dev.internal/api/auth/oauth/oidc/callback`.

Note that **Google and Apple will not accept a `.dev.internal` redirect URI** —
they require a public, verifiable domain. GitHub, GitLab and self-hosted
providers (Keycloak, Authentik, Zitadel) accept arbitrary hosts and work fine.
See the root README for the escape hatch if a Google login is needed.

## Data

- Postgres database `penpot` in the shared stack (`shared_pgdata` volume).
- Uploaded assets in the `penpot_assets` named volume.

Removing the instance leaves both intact:

```bash
../dev down penpot            # stops containers, keeps data
docker volume rm penpot_assets                        # drops assets
docker exec shared-postgres psql -U postgres -c 'DROP DATABASE penpot'
```
