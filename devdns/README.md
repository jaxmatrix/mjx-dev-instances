# devdns — internal dev DNS + TLS

Two containers:

- **CoreDNS** — authoritative for `*.dev.internal`, forwards everything else
  upstream. Registered in NetBird so every peer can resolve dev names.
- **Caddy** — wildcard TLS for `*.dev.internal` from its own local CA, routing
  to each instance by `Host` header.

Together they turn `https://penpot.dev.internal` into a real, trusted URL that
works from any NetBird peer — which is what makes OAuth redirect URIs and
`Secure` session cookies testable without owning a public domain.

## Setup

```bash
cp .env.example .env
$EDITOR .env          # set DEV_HOST_IP
../dev up devdns
../dev trust-ca       # install Caddy's root CA (once per machine)
```

### DEV_HOST_IP

This is the address every `*.dev.internal` name resolves to. For other NetBird
peers to reach the services it must be this machine's **NetBird IP**:

```bash
netbird up                        # the daemon reports NeedsLogin until you do
netbird status -d | grep -i -A1 'NetBird IP'
```

Use `127.0.0.1` for a purely local setup.

## How name resolution works

```
*.dev.internal ─┐
                ├─► CoreDNS ─► DEV_HOST_IP ─► Caddy :443 ─► routes on Host header
  dev.internal ─┘
anything else ──► CoreDNS ─► DNS_UPSTREAM_1 / _2
```

A **wildcard** answers the whole domain, so adding a service means adding a
`handle` block to `caddy/Caddyfile` — never a DNS record. `coredns/hosts.dev` is
the override file for names that must point somewhere other than this host.

Verify all three behaviours:

```bash
dig @127.0.0.1 penpot.dev.internal +short        # -> DEV_HOST_IP
dig @127.0.0.1 anything-new.dev.internal +short  # -> DEV_HOST_IP  (wildcard)
dig @127.0.0.1 github.com +short                 # -> real answer  (forwarding)
```

## Registering with NetBird

Registering CoreDNS as a NetBird nameserver is what makes `*.dev.internal`
resolve on **other** peers, not just this machine. Four steps.

### 1. Point DEV_HOST_IP at this peer's NetBird IP

While `DEV_HOST_IP=127.0.0.1`, every dev name resolves to the *querying* peer's
own loopback, so a remote peer that resolves `penpot.dev.internal` connects to
itself and gets nothing. Other peers can only reach the services if the name
resolves to this machine's NetBird address:

```bash
netbird status | grep 'NetBird IP'        # 100.x.y.z/16 — take the address, drop /16
```

Set it in **both** env files — `devdns/.env` is what Compose substitutes into
the Corefile, and the root `.env` is what `./dev status` reports:

```bash
sed -i 's/^DEV_HOST_IP=.*/DEV_HOST_IP=100.x.y.z/' .env devdns/.env
./dev restart devdns
dig @127.0.0.1 penpot.dev.internal +short     # -> 100.x.y.z
```

### 2. Add the nameserver in the NetBird dashboard

**DNS → Nameservers → Add Nameserver**

| Field | Value |
|---|---|
| Name | `devdns` (anything) |
| Nameserver | this peer's NetBird IP, port `53`, protocol UDP |
| Match domains | **none** — enable "All domains" / mark as primary |
| Distribution groups | the group(s) whose peers should resolve dev names |

The distribution groups decide which peers get the resolver, so a group holding
just your own devices keeps it off everything else.

### 3. Verify

On any peer in a distribution group:

```bash
netbird status -d | grep -i nameservers     # Nameservers: 1/1 Available
dig penpot.dev.internal +short              # -> this peer's NetBird IP
dig github.com +short                       # still resolves — CoreDNS forwards
curl -I https://penpot.dev.internal         # 200/302 once the CA is trusted
```

`Nameservers: 0/0 Available` means nothing is registered for that peer — either
no nameserver group exists yet, or the peer is not in a distribution group.

### 4. Give each peer the root CA

DNS only gets the peer to Caddy; the certificate still has to be trusted. See
[Trusting the CA](#trusting-the-ca) below — `../dev trust-ca --export-only`
writes `caddy/root.crt` for copying to the other machines.

### Why primary, and not a match domain

**Register it as a primary nameserver, not a match-domain one.** This is
deliberate:

- NetBird match domains on Linux require `systemd-resolved`, which is inactive
  on this machine (NetworkManager owns `/etc/resolv.conf`). With the resolvconf
  manager, NetBird refuses to configure DNS at all unless a nameserver group
  covering all domains exists.
- NetBird's own guidance is to configure at least one primary nameserver without
  match domains assigned to all peers.
- It is safe here precisely because CoreDNS is a *complete* resolver — anything
  outside `dev.internal` is forwarded upstream, not dropped.

**Trade-off:** while a peer uses this as its primary nameserver, all of that
peer's DNS depends on CoreDNS being reachable. Since this stack is started
manually, add a second nameserver to the same group as a fallback, or expect
name resolution to fail on those peers whenever devdns is down.

### Troubleshooting

- **`Nameservers: 0/0 Available`** — the peer is in no distribution group, or no
  nameserver group exists. Both are dashboard-side.
- **Peers resolve nothing while this host resolves fine.** NetBird runs its own
  resolver on the NetBird IP at port `5053` and points `/etc/resolv.conf` there;
  CoreDNS binds `0.0.0.0:53`, which covers the same address. Queries from this
  host land on CoreDNS, but a NetBird DNS interception on that address can take
  queries arriving over `wt0` first. Check with `ss -lunp | grep -E ':53|:5053'`;
  if the two are fighting, register the nameserver on a non-standard port and set
  `DNS_PORT` in `devdns/.env` to match.
- **DNS resolves but nothing connects.** Check the NetBird access-control policy
  allows the group to reach this peer on `udp/53` and `tcp/443`, and that no host
  firewall blocks them on `wt0`.
- **Everything looks right but names still resolve to `127.0.0.1`.** `DEV_HOST_IP`
  was changed without restarting: the Corefile is templated at container start.
  `./dev restart devdns`.

## Trusting the CA

Caddy signs the wildcard certificate with a CA it generates itself. Until that
CA is trusted, browsers and `curl` reject the certificate.

```bash
../dev trust-ca
```

This copies `/data/caddy/pki/authorities/local/root.crt` out of the container
and installs it with `sudo trust anchor --store` (p11-kit, the Manjaro path).

**Firefox** keeps its own trust store and needs one of:

- `about:config` → `security.enterprise_roots.enabled` → `true`, or
- Settings → Privacy & Security → Certificates → View Certificates → Authorities
  → Import → `devdns/caddy/root.crt`

**Other NetBird peers** need the same root certificate installed. `./dev
trust-ca --export-only` writes it to `devdns/caddy/root.crt` for copying.

The CA private key lives in the `caddy_data` named volume. `docker compose down`
keeps it; `docker compose down -v` destroys it, after which a new root is
generated and every machine must re-trust.

## Adding a service

1. Add a `handle` block to `caddy/Caddyfile`:

   ```
   @grafana host grafana.{$DEV_DOMAIN}
   handle @grafana {
       reverse_proxy grafana:3000
   }
   ```

2. Make sure the container joins the `devnet` network and is reachable by that
   name.
3. `../dev restart devdns`

No DNS change is needed — the wildcard already resolves the name.

## Port 53

CoreDNS binds `0.0.0.0:53`. Nothing else on this machine currently listens
there; `avahi-daemon` holds 5353 (mDNS), which does not conflict. If
`systemd-resolved` is ever enabled it will claim `127.0.0.53:53` and the bind
will fail — either set `DNSStubListener=no` in `/etc/systemd/resolved.conf` or
narrow `DNS_BIND_IP` in `.env` to a specific interface address.
