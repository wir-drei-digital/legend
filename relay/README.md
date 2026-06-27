# relay

A standalone Elixir app — the trusted self-host relay for Legend (Phase 3a).

Devices dial its public TLS endpoint; the Legend instance dials its loopback carrier endpoint and multiplexes streams back to the relay ingress. The relay operator is inside the trust boundary (the relay terminates TLS and sees bearer tokens); run one you control. Phase 3b (E2E) removes the operator from the boundary.

## Quick-start (dev / testing)

```bash
cd relay
mix deps.get
# Carrier only (no TLS cert → device listener is skipped with a warning)
RELAY_HANDLES="laptop:s3cret" mix run --no-halt
```

To enable the device-facing TLS listener, supply a cert/key (see Deploy below).

## Deploy

### 1. DNS and TLS

Point a wildcard A/CNAME record at the relay host:

```
*.relay.example.com  →  <relay-ip>
```

Obtain a wildcard TLS certificate for `*.relay.example.com` (Let's Encrypt / ACME DNS-01 or your CA). The relay's device listener uses this cert directly.

### 2. Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `RELAY_HANDLES` | yes | — | Comma-separated `handle:secret` allowlist, e.g. `laptop:s3cret,home:other`. Secrets may contain colons. Malformed entries are skipped with a warning. |
| `RELAY_DEVICE_PORT` | no | `4443` | Port the device-facing TLS endpoint binds (public-facing). |
| `RELAY_CERTFILE` | yes (device listener) | — | Path to the wildcard TLS certificate file. Without this the device listener is disabled. |
| `RELAY_KEYFILE` | yes (device listener) | — | Path to the TLS private key file. Without this the device listener is disabled. |
| `RELAY_CARRIER_PORT` | no | `4900` | Port the carrier (instance-to-relay WebSocket) listens on. |
| `RELAY_CARRIER_IP` | no | `127.0.0.1` | IP the carrier binds. **Leave at loopback** unless your TLS front terminates elsewhere. The registration secret crosses this connection in cleartext; it MUST NOT be exposed without TLS termination. |

### 3. TLS-front the carrier

The carrier endpoint (`RELAY_CARRIER_PORT`, default 4900) binds loopback by default because the registration secret crosses it in cleartext. You MUST sit a TLS-terminating reverse proxy (Caddy, Nginx, HAProxy) in front of it:

```
# Example Caddy snippet
relay.example.com {
  reverse_proxy /carrier localhost:4900
}
```

The instance dials `wss://relay.example.com/carrier` (the proxied TLS URL); the raw carrier Bandit process handles `ws://` on the loopback side.

### 4. Run

```bash
RELAY_HANDLES="laptop:s3cret" \
RELAY_DEVICE_PORT=4443 \
RELAY_CERTFILE=/path/to/fullchain.pem \
RELAY_KEYFILE=/path/to/privkey.pem \
RELAY_CARRIER_PORT=4900 \
mix run --no-halt
# or via a release:
# _build/prod/rel/relay/bin/relay start
```

The relay logs:

- At boot: carrier listener on `:4900` (loopback) and device listener on `:4443` (TLS).
- When an instance registers: the carrier `REGISTER` frame is accepted for handle `laptop`.
- When an instance drops: the handle goes offline (reconnect is handled by the instance).

---

## End-to-end: instance ↔ relay ↔ device

### How it works

```
phone / browser
  |  HTTPS (TLS-SNI: laptop.relay.example.com)
  ↓
relay:4443  ← Relay.Device (ThousandIsland TLS, wildcard cert)
  |  SNI → handle="laptop" → Relay.Registry.lookup("laptop")
  |  opens mux OPEN frame on carrier WS
  ↓
relay:4900 (loopback, TLS-fronted)
  ↑  Relay.Carrier WebSocket
  |  Legend.Federation.RelayClient.Carrier (instance side)
  ↓
127.0.0.1:4808  ← LegendWeb.RelayIngressEndpoint
  |  :relay_guards stamps every connection via_relay
  |  /api/mcp → 404 (not exposed over relay)
  ↓
LegendWeb.Router → same controllers / channels as the main endpoint
  |  DeviceAuth / UserSocket: via_relay ⇒ device token REQUIRED (no loopback bypass)
  ↓
Legend instance
```

### Instance configuration

#### Step 1 — Set "via relay" in Legend Settings

In the running Legend instance open **Settings → Remote access** and switch mode to **Via relay**. Enter:

| Field | Example |
|---|---|
| Relay URL | `https://relay.example.com` |
| Relay handle | `laptop` |
| Relay secret | `s3cret` |

Save and **restart Legend**. The instance also accepts this configuration programmatically:

```bash
curl -X PUT http://localhost:4100/api/settings/remote_access \
  -H 'Content-Type: application/json' \
  -d '{"enabled":true,"mode":"via_relay","relay_url":"https://relay.example.com","relay_handle":"laptop","relay_secret":"s3cret"}'
```

#### Step 2 — What happens on boot

`Legend.Core.Remote.Boot` reads the persisted setting and patches `LegendWeb.RelayIngressEndpoint`'s `check_origin` to `["//laptop.relay.example.com"]` before the endpoint starts.

`Legend.Federation.Supervisor` then starts:

1. `LegendWeb.RelayIngressEndpoint` on `127.0.0.1:4808` (override with `RELAY_INGRESS_PORT`).
2. `Legend.Federation.RelayClient` — starts the splice `Server` then dials `wss://relay.example.com/carrier`, sends `REGISTER {handle="laptop", secret="s3cret"}`. On success the relay logs the handle online.

Carrier drop → linear-with-cap backoff reconnect (500 ms base, 30 s cap); the splice Server survives a re-point.

#### Step 3 — Pair from your phone

In Legend **Settings → Remote access → Generate code**. The QR encodes:

```
https://laptop.relay.example.com/pair?code=<one-time-code>
```

Scan from the phone (any network, no VPN). The pair flow is per-origin — the relay origin pairs independently from any mesh/direct origin.

After pairing the phone holds a device token for origin `laptop.relay.example.com`. Subsequent requests to `https://laptop.relay.example.com` must include that token in the `Authorization: Bearer <token>` header (HTTP) or `token=<token>` query param (WebSocket). No token → **401** at the ingress.

---

## Gated acceptance checklist

Run through these steps against a live relay + instance + phone before shipping.

### Gate 1 — Carrier registration

- [ ] Start the relay with `RELAY_HANDLES="laptop:s3cret"` + device TLS listener.
- [ ] Configure the instance (via relay, URL/handle/secret) and restart.
- [ ] **Observe relay logs:** `[Relay.Carrier] registered handle=laptop` (or equivalent). Handle is now online in `Relay.Registry`.
- [ ] **Confirm:** no log line for a wrong-secret attempt reaching registration (try `RELAY_HANDLES="laptop:wrong"` on the instance — expect WS close from relay, not a silent accept).

### Gate 2 — Phone request routes relay → ingress → instance

- [ ] On the phone navigate to `https://laptop.relay.example.com` (or any public `/api/health`).
- [ ] **Observe:** the relay device listener accepts a TLS connection on port 4443, SNI resolves to handle `laptop`, a mux stream opens on the carrier.
- [ ] **Observe:** `LegendWeb.RelayIngressEndpoint` logs the request; response returns 200 from the instance (Phoenix).
- [ ] **Confirm SNI routing:** point a second instance at handle `home` (with `RELAY_HANDLES="laptop:s3cret,home:other2"`) and confirm `https://home.relay.example.com` reaches the second instance, not the first.

### Gate 3 — Device token required at ingress (no loopback bypass)

- [ ] From the phone send a token-gated request **without** a device token:
  ```bash
  curl https://laptop.relay.example.com/api/sessions
  ```
- [ ] **Expect: 401** from `DeviceAuth`. The relay passes the request through; the instance rejects it.
- [ ] Retry with a valid token (`Authorization: Bearer <token>`):
  ```bash
  curl -H "Authorization: Bearer <token>" https://laptop.relay.example.com/api/sessions
  ```
- [ ] **Expect: 200** (or appropriate JSON).
- [ ] **Confirm `/api/mcp` is closed:** `curl https://laptop.relay.example.com/api/mcp` → **404** (the relay ingress drops it before the router).

### Gate 4 — Session, ACP permission, stop — over the relay

- [ ] On the phone open the Legend UI at `https://laptop.relay.example.com`.
- [ ] Start a new session. Confirm the session prompt appears and the PTY connects over the relay WebSocket.
- [ ] Trigger an ACP permission request (any tool call requiring consent). Confirm the permission dialog appears and can be approved on the phone.
- [ ] Send a stop-work signal. Confirm the session responds (process exit or idle).

### Gate 5 — Carrier drop → reconnect

- [ ] With a session active from the phone, kill or restart the relay process.
- [ ] **Observe instance logs:** `[RelayClient] carrier start failed` / EXIT and then reconnect attempts with backoff.
- [ ] Restart the relay (or let it stay up if you just disconnected momentarily).
- [ ] **Observe:** `[RelayClient]` dials and re-registers. The relay logs the handle online again.
- [ ] Open a new session from the phone. Confirm it reaches the instance.
- [ ] *Note:* in-flight streams at the time of drop are lost; new sessions after reconnect work normally.

---

## Known limitations (Phase 3a)

**No backpressure / rate-limiting on the public device endpoint.** The mux codec carries `WINDOW` frames but neither the relay nor the instance honors them in 3a. Device ↔ instance bytes flow unbounded (`Relay.Device.handle_data/3` → carrier, and carrier → device). This is a memory-DoS surface — acceptable for self-host where the operator is the only victim, but a non-self-host/managed deployment (3c) MUST first enforce per-stream WINDOW credit, `read_timeout`, and connection rate-limiting.

**The carrier endpoint must be TLS-fronted.** The registration secret crosses the carrier WebSocket in cleartext; the carrier Bandit listener binds loopback by default (`RELAY_CARRIER_IP` to override). Never expose `RELAY_CARRIER_PORT` publicly without a TLS-terminating front.

**Trusted-relay model.** The relay operator is inside the trust boundary. The relay terminates device TLS and sees bearer tokens; a compromised relay can read, modify, or replay traffic. Device auth still rejects arbitrary internet clients that lack a valid token. Phase 3b (E2E via `Device.public_key`) moves the relay outside the trust boundary.

**Host must be awake.** If the Legend instance is offline the carrier is disconnected and devices cannot reach it. There is no queuing or offline delivery.
