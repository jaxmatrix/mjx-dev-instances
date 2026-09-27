# Jaeger

[Jaeger](https://www.jaegertracing.io/) v2 all-in-one — OTLP collector plus
query UI — for inspecting traces from the mobile app (and anything else that
speaks OpenTelemetry).

Storage is the default **in-memory** backend: spans survive only for the life of
the container. That matches how this repo runs services (started by hand, never
on boot).

## Setup

```bash
cp .env.example .env
../dev up jaeger
../dev restart devdns          # if you just added the Caddy routes
```

| What | URL |
|---|---|
| UI | <https://jaeger.dev.internal> (or `http://127.0.0.1:16686`) |
| OTLP HTTP | <https://otel.dev.internal> → `POST /v1/traces` |
| OTLP gRPC | `127.0.0.1:4317` (loopback only) |

## Pointing a mobile app at it

On a NetBird peer (or a phone on the mesh), set the OTLP HTTP endpoint to the
Caddy hostname:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=https://otel.dev.internal
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
```

The device must trust Caddy's local CA. On this machine that is
`./dev trust-ca`; for a phone, export the cert and install it:

```bash
../dev trust-ca --export-only    # writes devdns/caddy/root.crt
```

### Emulators / simulators on this host

Skip HTTPS and talk to the loopback publish:

| Client | OTLP HTTP endpoint |
|---|---|
| Android emulator | `http://10.0.2.2:4318` |
| iOS simulator | `http://127.0.0.1:4318` |

## Smoke test

```bash
curl -sS -X POST http://127.0.0.1:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[]}'
```

Then open the UI and search for recent traces from your instrumented app.

## Notes

- No auth on the UI or collector — reachability is the NetBird mesh (and
  loopback). Do not publish these ports beyond that.
- `JAEGER_VERSION` is pinned in `.env.example`; bump when you want a newer
  all-in-one image.
