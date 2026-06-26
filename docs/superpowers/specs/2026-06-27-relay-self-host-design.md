# Relay (Self-Host MVP) — Design

**Date:** 2026-06-27
**Status:** Draft (rev 2 — incorporates the relay-spec security/mechanics review)
**Builds on:** remote-access foundation (`2026-06-24-remote-access-foundation-design.md` — the device-token trust rule + the "no localhost-collapsing proxy" soundness constraint) and its hardening (the `LoopbackOnly` plug); sprites reverse tunnel (`2026-06-13-sprites-reverse-tunnel-design.md` — the stream-**mux protocol** this reuses, and its "raw TCP, HTTP-agnostic" splice decision); `docs/VISION.md` (Federation).
**Part of:** Federation — **Slice 3 (the relay)**, decomposed into 3a/3b/3c. This is **Slice 3a**.

## Problem

The merged remote-access foundation makes an instance controllable from a paired remote browser **over a mesh VPN**. The honest limitation, by construction: the host must be **awake and online**, **both devices need the mesh client running**, and the network must let the mesh connect (corporate wifi / some cellular block it). The user wants to reach their instance **from anywhere, no VPN client, no inbound reachability** — the instance is behind NAT with no public address.

The mechanism is a **relay**: an always-on public rendezvous the instance **dials outbound**, that a remote device reaches over plain HTTPS, and that forwards bytes between them. This is the inverse of the sprites reverse tunnel (there the backend dials *into* a sprite; here the instance dials *out* so devices can reach *it*) and reuses that spec's mux.

What the relay does **not** solve: the host must still be **running** — the relay is an always-on *meeting point*, not an always-on *instance* (truly-always-on is the separate Sprites cloud-compute axis). In scope here is **reachability**, not host uptime.

## Decomposition (and why this is Slice 3a)

| Slice | Delivers | Status |
|---|---|---|
| **3a — Self-host relay MVP (this spec)** | Reach your instance from anywhere via a relay **you run**. **Trusted** relay (terminates the device TLS; the relay operator is inside the trust boundary — see Trust model). Fleet-ready addressing. | **In scope** |
| **3b — Zero-knowledge E2E** | The relay becomes a **blind** ciphertext pipe; device↔instance is end-to-end encrypted via the `Device.public_key` reserved at pairing — removing the relay operator from the trust boundary. | Deferred; seam preserved |
| **3c — Managed offering** | Hosted relay + account/identity + auto TLS/hostname + Web Push, collapsed to one sign-in. Same relay code; adds the paid convenience layer. | Deferred; seam preserved |

The 3a→3b/3c boundary is **the trust placement** — the routing, instance-side ingress, and device-token auth are identical whether the relay sees plaintext (3a), forwards ciphertext (3b), or is hosted with an account (3c). 3a is the open-core base.

## Trust model (read this before the mechanics)

**3a is a *trusted-relay* model. The relay operator is inside your trust boundary.** Because the relay terminates the device's TLS, it sees the cleartext stream — including the **device bearer token / socket `token` param**. A malicious or compromised relay can therefore **read, modify, or replay** your traffic and **impersonate a paired device** to your instance. So:

- **What device auth *does* protect in 3a:** arbitrary *other* clients on the internet that reach the relay or the instance cannot get in without a valid device token — the auth rule is still enforced end-to-end at the instance, and a random network peer is rejected.
- **What it does *not* protect in 3a:** you against the relay operator. Self-hosting means *you* are the operator, which is the point — but the spec must not claim the relay "cannot impersonate a device." It can. **3b (E2E) is what moves the relay out of the trust boundary**; until then, run a relay you control.

This honest framing supersedes any "trusted relay cannot impersonate a device" phrasing.

## Decision: a trusted self-host relay over the existing mux, fleet-ready by subdomain, with a trust-preserving remote-ingress endpoint

### Reuse the mux *protocol* — but a new federation seam, not the `Tunnel` behaviour

The relay reuses the **stream-mux protocol** (`Legend.Core.Tunnel.Mux` ↔ the `bridge` mux: `OPEN`/`DATA`/`CLOSE`/`WINDOW`, big-endian `type:u8 stream_id:u32 length:u32 payload`) and its **raw-TCP, HTTP-agnostic** splice approach. It does **not** implement the existing `Legend.Core.Tunnel` behaviour: that contract is **per-runtime/per-session and agent-facing** (`open(target) -> %{base_url, handle}` so an in-runtime agent reaches the backend; driven by `SessionServer`). Relay mode is the opposite on every axis — **instance-global, boot/settings-driven, device-facing, no agent `base_url`**. So 3a introduces a **sibling federation seam** (`Legend.Federation.*`, instance-global) rather than overloading `Tunnel`. The mux module is shared infrastructure; the two seams are peers.

### Architecture — instance dials out; relay opens streams

- **Carrier:** the **instance dials an outbound WSS carrier** to the relay (NAT-friendly, outbound only) and registers.
- **Streams:** over that one carrier, the **relay `OPEN`s one mux stream per device connection** toward the instance (relay = the `bridge`/opener role); the **instance accepts each stream and splices it** to its remote-ingress endpoint (instance = the accept+splice role).

### The relay's device endpoint is a TLS-terminating *raw-byte* reverse proxy

"Terminate TLS then splice" must be precise: the relay does **not** parse the HTTP request and re-emit it (after parsing you no longer have the connection bytes, and you inherit every keep-alive/chunked/upgrade edge case). Instead, mirroring the bridge's HTTP-agnostic design:

1. The relay **terminates TLS itself** (it needs SNI/Host → handle anyway), yielding the **cleartext TCP byte stream**.
2. It splices those raw bytes over a mux stream to the instance.
3. The **instance's remote-ingress endpoint (Bandit) parses the HTTP/1.1, WebSocket upgrade, keep-alive, and chunked bodies** — exactly as it would for a direct client. The relay stays byte-agnostic; **WebSocket upgrades, keep-alive, and chunked transfer just work** because a real Phoenix/Bandit endpoint is on the other end. **Backpressure** is the mux's bounded per-stream buffering (`WINDOW` frames exist; v1 relies on bounded mpsc, same as the bridge).

A fronting Caddy is therefore an **L4/SNI passthrough** (TCP, not HTTP) so the relay can terminate TLS and keep raw bytes — or the relay owns TLS directly with a wildcard cert. (An HTTP-aware Caddy that terminates TLS would force the relay into the parse-and-re-emit shape we're rejecting.) The plan pins the TLS topology.

### Addressing — fleet-ready by **subdomain**, with per-handle credentials

A device targets an instance by **subdomain**: `https://<handle>.relay.example.com`. Subdomain (not path) is required because the SPA uses **root-relative** paths (`/api/...`, `/socket`, `/_app/...`); a path prefix breaks them, a subdomain keeps the whole app same-origin under the handle host. Self-host needs **wildcard DNS** (`*.relay.example.com`) + a **wildcard TLS cert**.

**Credentials are per-handle, not one global secret.** A single shared `RELAY_SECRET` + multiple handles = handle hijack (any instance holding the secret claims any offline handle). The relay holds an **allowlist map `handle → secret`** (config/env); registration must match the handle's own secret. Handles are validated against a **strict DNS-label** pattern (`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`, lowercased) to prevent subdomain/routing injection. The MVP ships/tests **one** handle; a second is another allowlist entry + registration — no relay rewrite, and the substrate Slice 2 fans out over.

### Trust preservation — the one novel security surface (applies to HTTP **and** sockets)

The relay is a **TLS-terminating proxy in front of the instance** — the exact total-bypass hazard the foundation flagged: the instance's splice dials a **local private port**, so *every* trust check that reads the peer address — `DeviceAuth` (HTTP) via `conn.remote_ip`, `LoopbackOnly` (management) via `conn.remote_ip`, **and `UserSocket.connect/3` (channels) via `peer_data`** — would otherwise see `127.0.0.1` and grant **loopback trust**. The marker must therefore reach **all three**.

Mechanism: a **dedicated remote-ingress *endpoint*** — `LegendWeb.RelayIngressEndpoint`, its own Bandit listener on a private port — that the federation provider splices relay streams to. Crucially it is a **full Phoenix endpoint, not just `LegendWeb.Router`**: it mounts **`Plug.Static`** (so `/_app/*` SPA assets serve), the **router**, and the **`/socket` Phoenix socket** — all of which live in `endpoint.ex`, not the router; a router-only listener would 404 the assets and have no channels. The ingress stamps every connection `via_relay` (an HTTP `conn` assign / private, and the socket `connect_info`), and the three choke points treat **`via_relay ⇒ non-loopback`**:

- `DeviceAuth`: `via_relay` → never loopback-trusted → a valid **device token is required**.
- `LoopbackOnly` (management — pairing-code gen, revoke, device list/audit, remote-access config): `via_relay` → **403**. A remote relay user **cannot enroll or manage devices**.
- `UserSocket.connect/3`: `via_relay` → never loopback → the socket **`token` param is required**.
- Public routes stay public on the ingress: `POST /api/pair` (pre-auth redeem) and `/api/health` only. **`/api/mcp` is excluded from the relay ingress entirely** — the agent MCP surface is for in-runtime agents (reached via the loopback/runtime tunnel), browsers never need it, and a *public* relay is a materially broader exposure than the tailnet caveat already flagged. The remote ingress simply does not route `/api/mcp`.

The relay authenticates the **instance** (per-handle secret); the **device token is verified end-to-end by the instance** at the ingress — the relay performs no human auth (and, per the trust model, in 3a it *could* abuse a token it sees; 3b closes that). `check_origin` on the ingress admits `<handle>.relay.example.com` (reusing the Phase-2a `check_origin` extension).

## Components

### `relay/` — a new self-hostable Elixir release

Small app; reuses `Legend.Core.Tunnel.Mux`. Two faces:

- **Carrier endpoint (WSS):** instances connect and register `{handle, secret}` against the **per-handle allowlist** (+ DNS-label validation). On success it holds the persistent mux carrier and records `handle → carrier` in an **in-memory registry** (no DB for the MVP — it is ephemeral connection state). Rejects a bad/duplicate handle or a wrong secret.
- **Device endpoint:** the **TLS-terminating raw-byte reverse proxy** above — SNI/Host → handle → carrier → one mux stream per device TCP connection, splicing raw cleartext bytes. Unknown/offline handle → a clear "instance offline" response, not a hang.

Standard Elixir release on a small VPS; TLS via the relay itself (wildcard cert) or an L4/SNI-passthrough Caddy. Config: the `handle → secret` allowlist, the wildcard host, listen ports.

### `Legend.Federation.RelayClient` — the instance-side provider (new seam)

Instance-global, boot/settings-driven (NOT a `Tunnel` provider). On enable: opens the outbound WSS carrier to `RELAY_URL`, registers `RELAY_HANDLE` + its secret, then accepts mux streams and splices each to the **remote-ingress endpoint**. **Initial-connect retry + reconnect-with-backoff** on carrier drop (the carrier is long-lived; reconnect is needed from the start, unlike the sprites tunnel which deferred it). Disable/`close` tears down the carrier.

### `LegendWeb.RelayIngressEndpoint` — the trust-preserving ingress

A dedicated Phoenix endpoint (own Bandit listener, private port) mounting **static + router + socket**, stamping `via_relay`, with `check_origin` for the relay host and **no `/api/mcp` route**. Boots via a `Remote.Boot`-style child **only when relay mode is enabled**; off by default. `DeviceAuth`/`LoopbackOnly`/`UserSocket` are extended to honor `via_relay` (small, shared change).

### Settings / pairing surface

The **Remote access** settings section gains a **"via relay"** mode (loopback-only to configure, like all remote-access config): relay URL + handle + secret. The pairing **QR encodes `https://<handle>.relay.example.com/pair?code=…`**. **Per-origin pairing:** device tokens live in **origin-scoped** browser storage, so a device paired over the mesh (`http://host:4807`) does **not** carry its token to the relay origin (`https://<handle>.relay.example.com`) — **the relay origin requires its own pairing.** This is acceptable (pairing is cheap, single-use TTL); no cross-origin token migration is built. The frontend is otherwise unchanged (same-origin under the relay host).

## Data flow

```
  phone ─HTTPS→ <handle>.relay.example.com         instance (behind NAT)
                     │  relay TERMINATES TLS          RelayIngressEndpoint :PRIV
                     │  → raw cleartext bytes          (static + router + socket,
                     │  OPEN + DATA (mux)               stamped via_relay)
   relay registry ───┤  over the instance's                   ▲
   handle → carrier  │  outbound WSS carrier  ──────── splice raw bytes
   (per-handle secret)└──────────────────────────────────────┘
                       instance dials the carrier OUTBOUND → relay
```

1. Instance enables relay mode → dials the carrier, registers `{handle, secret}` (matched against the allowlist).
2. Phone opens `https://<handle>.relay.example.com` → relay terminates TLS, resolves the subdomain → carrier.
3. Relay `OPEN`s a mux stream and splices the phone's raw byte stream ↔ stream.
4. Instance accepts the stream and splices it to `RelayIngressEndpoint` (Bandit parses HTTP/WS), stamped `via_relay`.
5. Static assets serve, public routes (`/pair`, `/health`) open, device-gated routes require a token, management 403s, sockets require a token — all because `via_relay ⇒ non-loopback` at every choke point. `/api/mcp` is not routed.
6. The phone gets the same-origin SPA + API + `wss://` channels and drives sessions; the device token is verified by the instance.

## Setup & operability

1. **Run the relay** — deploy the `relay` release on a small VPS; wildcard DNS `*.relay.example.com` → it; TLS via the relay (wildcard cert) or L4/SNI-passthrough Caddy; configure the `handle → secret` allowlist.
2. **Point the instance at it** — set `RELAY_URL` / `RELAY_HANDLE` / its secret; enable **Settings → Remote access → via relay** (loopback-trusted) and restart.
3. **Pair on the relay origin** — generate a code, scan the QR (relay-subdomain URL) from the phone on any network.

No VPN client, no inbound port, works on cellular/corporate wifi. Honest limit: the **host must be awake and online**; and in 3a you must **trust the relay operator** (run your own). 3c collapses steps 1–2 into a hosted account; 3b removes the trust-the-operator caveat.

## Scope

**In this spec:** the `relay` Elixir release (carrier registration with per-handle credentials + DNS-label handle validation; subdomain device routing; TLS-terminating **raw-byte** reverse proxy; in-memory handle registry; reuses the mux); the `Legend.Federation.RelayClient` instance provider (outbound carrier, mux-splice, reconnect-with-backoff); the `LegendWeb.RelayIngressEndpoint` (static+router+socket, `via_relay`, `check_origin`, **no `/api/mcp`**); the shared `via_relay ⇒ non-loopback` change across `DeviceAuth`/`LoopbackOnly`/`UserSocket`; subdomain/wildcard-TLS addressing; the Remote-access **"via relay"** settings mode + relay-URL pairing QR + the **per-origin re-pair** note; self-host ops docs; the tests below; a gated live phone↔relay↔instance acceptance.

**Deferred:** 3b (zero-knowledge E2E via `public_key` — and with it, removing the relay operator from the trust boundary); 3c (hosted relay, account/identity, auto TLS/hostname, Web Push); the multi-instance fan-out **UI** (Slice 2 — the relay is fleet-ready; the unified view is separate); conveying the real device IP into audit over the relay (MVP audits by `device_id`; the device IP needs `OPEN`-frame metadata / a trusted forwarded field — deferred); cross-origin token migration (per-origin pairing instead); host uptime (Sprites axis).

## Error handling

- **Carrier drop** → provider reconnects with backoff; in-flight streams reset, the device client retries; the relay marks the handle offline until re-registration.
- **Offline/unknown handle at the device endpoint** → clear "instance offline / unknown" response, not a hang.
- **Bad/duplicate handle or wrong per-handle secret** → relay refuses registration; instance surfaces the error and stays loopback-only.
- **Relayed device-gated request without a valid token** → ingress **401** (regression-tested — the trust invariant).
- **Management action over the relay** → **403** (`via_relay ⇒ not loopback`).
- **`/api/mcp` over the relay** → **404** (not routed on the ingress).
- **Relay unreachable at enable** → fail safe; instance stays loopback-only, error surfaced.

## Testing

- **Mux** — existing unit tests reused unchanged.
- **Relay routing/registration (unit):** register `{handle, secret}` against the allowlist; **wrong secret rejected**; **handle hijack** (instance A's secret cannot claim handle B); **duplicate live handle** rejected; **DNS-label validation** rejects bad handles; subdomain→carrier resolution; **offline/unknown handle** → clear error.
- **Remote-ingress trust (unit — the crux), HTTP and socket:**
  - HTTP: a `via_relay` device-gated request **without** a token → **401**; with a valid token → allowed; a **management** route over `via_relay` → **403**; `POST /api/pair` over `via_relay` → allowed; `/api/mcp` over the ingress → **404**.
  - **Static:** the ingress serves **`/_app/*`** SPA assets (regression: a router-only listener would 404 these).
  - **Socket:** `/socket` connect over `via_relay` **without** a token → **rejected** (despite the local TCP peer being `127.0.0.1`); **with** a token → **accepted**.
  - A regression asserting `via_relay` **never** confers loopback trust on any of the three paths.
- **Provider (gated/opt-in):** instance dials a real relay, registers, a stream splices end-to-end; carrier-drop → reconnect.
- **Live acceptance (gated):** over a deployed relay, a phone on cellular loads `https://<handle>.relay.example.com`, pairs via QR, and **drives a real WebSocket session** through the relay (prompt, ACP permission, stop) — instance behind NAT, no mesh running.
- `cd backend && mix precommit`, the `relay` release's own checks, and `cd frontend && bun run check` green.

## Open questions (resolve during planning)

- **`RelayIngressEndpoint` packaging** — a second `Phoenix.Endpoint` module sharing the router + socket + static config with `LegendWeb.Endpoint` (DRY the plug stack) vs. a thin wrapper. The plan pins it (leaning a dedicated endpoint module that reuses the existing router/socket/static config and adds the `via_relay` stamp + `check_origin` + mcp exclusion).
- **`via_relay` plumbing** — exact carriers for the marker: HTTP `conn` private/assign set by a head-of-pipeline plug on the ingress endpoint, and socket `connect_info` set via the ingress's `socket/3` config; confirm both reach `DeviceAuth`/`LoopbackOnly`/`UserSocket` cleanly.
- **Relay TLS topology** — relay-owns-TLS (wildcard cert) vs. L4/SNI-passthrough Caddy; the plan documents the recommended path + DNS/cert prerequisites (must preserve raw-byte splicing — no HTTP-terminating front).
- **Outbound WSS client** — reuse the sprites tunnel's choice (`Mint.WebSocket`/`:gun`/`WebSockex`); confirm it suits a long-lived carrier with reconnect.
- **Relay release packaging** — a second release target in `mix.exs` vs. a separate mini-app; keep it minimal (mux + WSS carrier endpoint + TLS-terminating raw proxy + the allowlist).
- **Handle identity for 3c** — the MVP `handle → secret` allowlist is replaced by account-derived credentials in the managed offering; keep the registration payload shaped so the swap is additive.

## Decisions log

| Decision | Rationale |
|---|---|
| 3a = **trusted** self-host relay; the relay operator is **inside** the trust boundary until 3b | The relay terminates TLS and sees bearer tokens — it can replay/impersonate. Device auth still rejects arbitrary *other* clients; E2E (3b) is what removes the operator from the boundary. No overclaiming. |
| Reuse the mux **protocol** + raw-TCP splice; introduce a **sibling federation seam**, not a `Tunnel` provider | `Legend.Core.Tunnel` is per-session, agent-facing, returns a `base_url`; relay mode is instance-global, boot/settings-driven, device-facing. Shared mux, peer seams. |
| Relay device endpoint = **TLS-terminating raw-byte** reverse proxy; the instance's Bandit parses HTTP/WS | Parsing-and-re-emitting loses the connection bytes and inherits keep-alive/chunked/upgrade edge cases; raw-byte splice (the bridge's proven choice) makes WS/keep-alive/chunked "just work" on a real endpoint. Caddy, if used, is L4/SNI passthrough. |
| Remote ingress is a **full Phoenix endpoint** (static + router + **socket**), not just the router | `Plug.Static` and `/socket` live in `endpoint.ex`; a router-only listener 404s `/_app/*` and has no channels. |
| `via_relay ⇒ non-loopback` across **`DeviceAuth` + `LoopbackOnly` + `UserSocket`** | The splice dials a local port, so *every* peer-address check sees `127.0.0.1`; the marker must reach HTTP auth, HTTP management, and socket connect alike, or the bypass survives in whichever path is missed. |
| **Exclude `/api/mcp`** from the relay ingress | The agent MCP surface is for in-runtime agents via the loopback/runtime tunnel; browsers never need it; a *public* relay is a far broader exposure than the tailnet caveat. |
| **Per-handle credentials** (allowlist) + strict DNS-label validation, not one global `RELAY_SECRET` | A global secret lets any instance claim any offline handle (hijack); per-handle secrets + label validation make fleet addressing safe. |
| **Per-origin pairing** (no token migration) | Device tokens are origin-scoped in browser storage; mesh origin ≠ relay origin, so the relay origin pairs separately. Pairing is cheap; migration is unwarranted complexity. |
| Subdomain addressing (`<handle>.relay`), not path | Root-relative SPA paths break under a path prefix; a subdomain keeps the app same-origin. |
| Fleet-ready registration, ship one handle first | Matches "reach my laptop OR work machine"; second handle is another allowlist entry; substrate for Slice 2 with no relay rewrite. |
| Relay state in-memory (no DB) for the MVP | `handle → carrier` is ephemeral connection state; persistence buys nothing until managed multi-tenant. |
| Host-uptime out of scope | The relay is an always-on meeting point, not an always-on instance (Sprites axis). |
