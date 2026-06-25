# Remote Access Foundation — Design

**Date:** 2026-06-24
**Status:** Draft
**Builds on:** agent sessions PoC (`2026-06-11-agent-sessions-poc-design.md`), sprites reverse tunnel (`2026-06-13-sprites-reverse-tunnel-design.md` — the `Tunnel` seam and the recorded "auth before any broader remote exposure" caveat), `docs/VISION.md` (Federation; Local-first; Data sovereignty).
**Part of:** Federation — **Slice 1 of 3**. Slice 2 (unified fleet view) and Slice 3 (the relay + managed offering) are **deferred**; this spec builds the auth + reachability foundation both depend on and designs their seams.

## Problem

Sessions run where the agent runs — a `SessionServer` GenServer pinned to one machine, its scrollback/timeline held **only in that process's memory** (`Scrollback`/`Transcript` are not persisted; only the session *record* hits SQLite). The user wants to **check in on, and intervene in, those live sessions from another device** — phone, work machine — and vice versa.

This is **not a sync problem.** A running session is a process, not data; you can't replicate it, you attach to its live stream. Cold-replicating the SQLite DB + library tree over a mounted cloud drive (iCloud/Dropbox/NFS) handles the *record* well enough for continuity — but only as **single-writer / one-machine-active-at-a-time** (SQLite corrupts under concurrent writers on a synced FS). Live remote access is a separate mechanism: **proxy/attach, not sync.** Sync is explicitly out of scope here.

Today's posture blocks remote access by construction, which is *fine* while it's loopback-only and becomes *dangerous* the moment it isn't:

- The backend **binds loopback** (sidecar-first design; prod `runtime.exs` + the desktop sidecar at `127.0.0.1:4807`).
- `LegendWeb.UserSocket.connect/3` accepts **every** connection with zero auth.
- The session/library/settings HTTP APIs have no human-facing auth.

The crux: the remote experience the user wants is **full control** — type, submit prompts, answer ACP permission requests, `Ctrl-C` a runaway, `stop`. On a mesh that is *almost free* — it's the same [`SessionChannel`](backend/lib/legend_web/channels/session_channel.ex) (`input`/`prompt`/`resize`/`stop`/`permission` already wired), just reachable. Read-only would be *more* code (a write-path gate), not less. So choosing full control moves the **entire** cost into one place: **authentication** — because once the backend is reachable, auth is the only thing between "anything that can reach the network" and **arbitrary code execution on the user's machine** (an agent runs code; driving it remotely is RCE-as-a-feature).

So this spec is, in one line: **make one Legend instance safely, fully controllable from a remote browser — authentication first, reachability second, transport-agnostic throughout.**

## Decomposition (and why this is Slice 1)

| Slice | Delivers | Status |
|---|---|---|
| **1 — Foundation (this spec)** | One instance, fully controllable from a paired remote browser over a mesh. Auth + opt-in reachable bind + pairing + the remote web client. | **In scope** |
| **2 — Unified fleet view** | One UI listing sessions across *all* your instances (local + laptop + work). On a mesh this is mostly **frontend fan-out** (the browser opens one socket per instance and merges). | Deferred; seam preserved |
| **3 — Relay + managed offering** | From-anywhere without a VPN / sleeping-laptop reach; the **one-click hosted** product. An *always-on rendezvous* the instance dials outbound. | Deferred; seam preserved |

The boundary between slices is **the transport**. Slice 1's auth + attach machinery is identical whether bytes arrive over a mesh (now), the browser fanning out to peers (Slice 2), or a relay (Slice 3). We build the seam so later slices are new *transports*, not rewrites — exactly the role the existing [`Legend.Core.Tunnel`](backend/lib/legend/core/tunnel.ex) seam already plays for the agent→backend direction (the relay is the same idea pointed at devices/instances instead of sprites).

## Decision: loopback-or-paired-device trust, opt-in reachable bind, device pairing

### Trust model — the one rule

All authorization reduces to a single rule, enforced at two choke points — the socket's `connect/3` and one HTTP plug:

> **A request is trusted iff it arrives on loopback, OR it carries a valid, non-revoked device token. Otherwise it is rejected.**

- **Loopback = physically at the machine.** The desktop app (Tauri webview → sidecar on `127.0.0.1`) and the instance's own browser are trusted with zero pairing — the *same* assumption Legend makes today, now made **explicit** instead of *implicit-because-unreachable*. Loopback is also the **trust root** that bootstraps pairing (below): no chicken-and-egg, because loopback always exists on the instance itself.
- **Everything else** — the tailnet now, the relay later — must present a paired-device token.

**Soundness constraint — no localhost-collapsing proxy in front.** If a TLS-terminating reverse proxy (Tailscale *Serve*, nginx) forwards to `127.0.0.1`, Phoenix sees *every* remote user as loopback and waves them through — a total auth bypass. Therefore, when remote access is enabled, **Phoenix binds the reachable interface directly and terminates TLS itself** (cert supplied by the mesh, e.g. `tailscale cert <name>`), so a remote peer arrives with its real (non-loopback) source IP and "loopback = local" stays true. The peer IP comes from the socket/conn `peer_data`, never from a spoofable forwarded header (no trusted proxy exists in this topology).

### Threat model (single-user)

- **Defending:** RCE-grade control of the instance from anyone who can reach its now-open network interface (the tailnet; later the relay's reach). One human, many devices — **no multi-user/RBAC**; "prove this device is mine," not "which user are you."
- **Enrollment gate:** physical possession of an already-trusted device (loopback) to add a new one.
- **Containment:** per-device, individually-revocable credentials; a lost phone is revoked without re-keying the rest.
- **Single-writer model** (from the SQLite caveat): one instance *owns* a session; remote devices *attach* to the owner and forward input over its channel — exactly as the local browser does. No remote process is spawned; nothing new reaches `runtime.write/2` that didn't already.

### Why device pairing (not a password, not an IdP)

- **Password → token** — simplest, but one phishable/guessable secret, no per-device granularity, ages badly under the relay's public exposure. Rejected as primary.
- **Delegate to transport/IdP** (Tailscale Serve identity headers, OAuth proxy, GitHub/Google) — least code, but couples identity to one transport (the relay needs its own mechanism regardless), invites "just trust this header" misconfig, and drags a cloud IdP into a local-first product. Rejected as primary.
- **Device pairing (the "WhatsApp Web" model) — chosen.** Right security model for full-control-from-anywhere (enrollment needs physical possession; per-device revocation), **transport-agnostic** (the credential authorizes the *channel*, identical over mesh and relay), and **local-first** (the instance is its own authority; no external dependency).

## Components

### Reachability: opt-in bind + direct TLS

- **`remote_access` is off by default.** A setting (`Legend.Core.Settings`, like `library_path`, with a dedicated endpoint — generic CRUD is wrong for a side-effecting toggle) flips the instance from loopback-only to **binding the reachable interface + (optional) TLS**, and *only then* is pairing active. Today's loopback-only behavior is the untouched default — local-first means remote is explicit opt-in.
- **Two bind paths to cover:** the web release (`runtime.exs`) and the **desktop sidecar** (`desktop/src-tauri/src/main.rs` currently pins `127.0.0.1`/`PORT=4807`). Enabling remote on desktop means the sidecar binds the reachable interface — a deliberate, surfaced change, not a silent default.
- **Bind `0.0.0.0` when remote access is enabled; the loopback-or-token gate is the network boundary.** (Supersedes the earlier "specific mesh interface, not `0.0.0.0`" note.) Rationale: on desktop the Tauri webview needs `localhost` *and* remote devices need the mesh interface simultaneously; `0.0.0.0` serves both, and a non-loopback caller still needs a valid device token (hostile LAN/wifi gets 401). The defense-in-depth alternative — a second listener bound only to the mesh IP, leaving the port unreachable on other networks — is deferred (dual-listener; more plumbing, and Phoenix channels over a hand-started Bandit need verification). TLS (https on a second port for PWA secure-context) is also deferred; a mesh already encrypts the transport, so `http://` over the tailnet is confidential including the token. Reconfiguring is restart-to-apply.
- **TLS is optional on a mesh.** WireGuard already encrypts the transport, so `http://` over the tailnet is confidential *including the pairing token*. TLS is a **recommended upgrade** for browser polish only — PWA install + Web Push require a "secure context" (HTTPS). When enabled, Phoenix terminates TLS directly (Bandit `https`) with the mesh-issued cert; cert renewal/reload is an operability concern (see Setup).
- **CORS/origin:** the remote browser loads the SPA **same-origin** from the instance (the catch-all `SPAController` + same-origin `PUBLIC_*` defaults), so channel/socket traffic is same-origin `wss://` — **no CORS involved** (Corsica stays scoped to the cross-origin desktop case). `check_origin` must allow the configured remote host (the tailnet name); pinned in the plan.

### `Legend.Core.Devices` — domain + resources

A new Ash domain (AshSqlite), registered in `ash_domains`, **using the `AshJsonApi.Domain` extension even if it exposes zero JSON:API routes** (the router probes every registered domain — the recorded `Settings` gotcha). Human-facing endpoints are plain controllers (loopback-gated), not generic JSON:API CRUD.

- **`Device`** — `id`, `name`, `public_key` (string, **nullable**), `paired_at`, `last_seen_at`, `revoked_at`.
  - The credential is a stateless [`Phoenix.Token`](https://hexdocs.pm/phoenix/Phoenix.Token.html) carrying `device_id` (signed with `secret_key_base`); we store **no token**, only the `Device`. Auth = verify signature → load device → reject if `revoked_at` set → bump `last_seen_at`. Revocation is thus immediate and server-side; secret rotation invalidates all device tokens (re-pair) — acceptable.
  - **`public_key` is the forward-compat seam for the zero-knowledge relay** (Commercial seam, below): pairing happens over the trusted loopback path, the perfect moment to register a device public key so the *future* relay can broker an end-to-end-encrypted channel and stay blind. **v1 does not use it** (the mesh is already encrypted; E2E buys nothing yet) — the field and the pairing handshake slot exist so E2E is a clean extension, not a re-pair/migration.
- **`PairingCode`** — short-lived (TTL), single-use: `code`, `expires_at`, `redeemed_at`, `device_id` (set on redeem). A small table (auditable) rather than ephemeral ETS; the plan pins the choice.

### Pairing flow

```
  Trusted instance (loopback)              New device (phone, over the mesh)

  Devices screen ── generate ──▶ PairingCode (TTL, single-use)
        │
        └─ render QR: { instance mesh URL, code }
                                   │  scan (native camera) → opens URL+code
                                   ▼
                          SPA loads same-origin, POST /api/pair { code }
                                   │
        validate (unredeemed, unexpired) ─┘
        mint Phoenix.Token(device_id) ─────────────▶ stored on device
                                   │
        device now sends token as a socket param + Bearer header
```

- **Generate** (loopback-only): a `Devices` screen mints a `PairingCode` and renders a **QR** encoding `{ instance URL, code }`.
- **Redeem:** the phone (already mesh-reachable) loads the same-origin SPA via the QR URL and `POST`s the code to a pairing endpoint (open to non-loopback **only** for code redemption — the one pre-auth write, rate-limited, single-use, TTL-bounded). The server validates and mints the device token; the SPA stores it (the private key, if/when E2E lands, is a non-extractable WebCrypto key in IndexedDB).
- **Native-camera scan** (opening the URL) avoids in-page `getUserMedia`, which needs a secure context — so pairing works even on plain `http://` over the mesh; manual code entry is the fallback.

### Auth choke points

- **Socket** — `UserSocket.connect/3` gains `connect_info: [:peer_data]`; trusts loopback peers, else verifies the `token` socket param. Identity (`device_id` or `:local`) is assigned for channels + audit. `SessionChannel.join` already loads the session; it inherits the socket's trust.
- **HTTP** — a `DeviceAuth` plug (loopback OR valid `Authorization: Bearer` device token) on the human-facing scopes. **Router order is load-bearing** (`/api/health` first, the AshJsonApiRouter `forward`, SPA catch-all last) — the plug is threaded into the human pipelines without disturbing that order; pinned in the plan.

### What is gated vs left open

- **Gated by `DeviceAuth`:** the session/signals channels and the sessions / library / settings / harness / runtime HTTP APIs.
- **`/api/health`** stays open (probe).
- **`/api/mcp`** keeps its **existing per-session `mcp_token`** — *agent* auth, a separate axis from human/device auth; we never conflate them. Binding the tailnet does expose `/api/mcp`, still protected by the session token; over an encrypted mesh that is acceptable for v1 (flagged, not solved here).
- **`POST /api/pair`** — the sole pre-auth write: single-use, TTL-bounded, rate-limited.

### Audit trail

An append-only `AuditEvent` (`device_id`, `session_id`, `action`, `at`) covering **connection/attach and discrete control actions** — pairing, revoke, remote attach, `stop`, permission decisions, prompt submissions — **not** raw keystrokes (`input` bytes would be high-volume and low-value). Cheap insurance proportionate to RCE-grade exposure; surfaced read-only on the Devices screen.

### Remote UX

- **Same SPA, same origin** — a phone hitting `https://laptop.tailnet.ts.net` gets the real app with zero transport config (the frontend already defaults to same-origin; `wss://` channels "just work").
- **A minimal responsive session route** — the desktop tiling shell (`docs/VISION.md` windowing core) is rough at ~380px, so v1 adds a lean phone path: **session list → single-session view** (terminal/ACP) with input affordances. A responsive route, **not** a separate app; heavier mobile polish is deferred. *(This is the one genuinely visual surface; mock it during planning if useful.)*
- **A `Devices` management screen** (loopback-trusted): list paired devices, `last_seen_at`, **revoke**; generate pairing QR; view the audit trail.

## Setup & operability (what the user actually does)

The mesh is the **user's transport**, underneath Legend — Legend takes **no dependency** on it and bundles nothing. On the Tailscale free tier (100 devices / 3 users; client is OSS, only the control plane is proprietary):

1. **Install the mesh client on both devices, sign in.** The bulk of setup, and it's the mesh's (well-trodden) onboarding — no port-forwarding, firewall rules, or public IP.
2. **Toggle "Enable remote access" in Legend.** Binds the reachable interface; pairing becomes active.
3. **Pair** — scan the QR from the phone.

No cert, domain, or server required for steps 1–3 (the mesh encrypts; TLS is the optional PWA-polish upgrade — `tailscale cert <name>`, configured in v1 by pointing Legend at the cert path; auto-provisioning and renewal/hot-reload are deferred). The honest limitation: **no always-on intermediary**, so the instance must be **awake and online** and both devices need the VPN client running — precisely the gap Slice 3 closes. The fully-OSS mesh (Headscale/raw WireGuard) is supported identically but shifts real ops onto the user (run a coordination server), approaching the relay's burden — a deliberate, eyes-open trade.

**v1 setup-assist scope:** detect the reachable interface/name, surface the instance URL + pairing QR. **Defer** cert automation (point at a cert path).

## Commercial seam & forward path

The monetization boundary falls exactly on the **transport seam** — the managed product *is* the hosted **relay (Slice 3)**, not a fork of the app. Open-core done right (Tailscale/Bitwarden/Ghost): the entire codebase, relay included, stays open and self-hostable; what's sold is **running it** — reach + hosted identity + TLS/name + Web Push — collapsed to one sign-in. Guardrails this spec commits to so it stays "fair and reasonable":

- **The OSS + self-host + mesh path is never crippled** — paid adds *convenience*, never *capability*.
- **Pay-as-you-go on real cost drivers** (relay bandwidth, push, later compute/storage); no seat fees.
- **Zero-knowledge relay** — you pay for *reach*, not for the relay reading your data: it brokers an **end-to-end-encrypted** channel between device and instance and forwards ciphertext. This is the principled differentiator and the reason the `Device.public_key` seam exists *now* (keys established at loopback pairing time; E2E implemented when the relay lands).
- **Compounds:** once *reach + identity* are hosted, the same account meters the other expensive-to-self-host axes the vision already names — **compute** (the [`Sprites`](backend/lib/legend/runtimes/sprites.ex) cloud runtime, already in-tree) and **storage** (E2E sync) — each with an open self-host alternative.

None of Slice 3 is built here; this section justifies the two seams Slice 1 *does* build: the transport-agnostic credential, and `Device.public_key`.

## Scope

**In this spec:** the loopback-or-paired-device trust rule at both choke points (`UserSocket.connect/3` via `peer_data`; the `DeviceAuth` plug); the `remote_access` opt-in setting + reachable bind on both web-release and desktop-sidecar paths; direct-TLS termination (optional) with the no-proxy constraint; the `Legend.Core.Devices` domain (`Device`, `PairingCode`); the pairing flow (`POST /api/pair`, QR generate, token mint) with `Device.public_key` reserved for E2E; the `AuditEvent` log at control-action granularity; the `Devices` management screen + pairing-redeem screen + minimal responsive session route; `check_origin` for the remote host; tests; and a live phone↔laptop acceptance pass.

**Deferred:** Slice 2 (unified fleet view / frontend fan-out across instances); Slice 3 (the relay transport, hosted account, Web Push, zero-knowledge E2E using `public_key`, cert automation); record **sync** (the mounted-cloud-drive cold path is the user's, not built here); device-keypair *use* (field reserved, unused in v1); hardening `/api/mcp` against tailnet exposure beyond its existing session token; heavier mobile UX.

## Error handling

- **Unauthenticated remote connect** (no/invalid/expired/revoked token, non-loopback) → socket `connect` returns `:error`; HTTP plug returns 401. No partial access.
- **Expired/redeemed pairing code** → `POST /api/pair` 4xx; the code is single-use and TTL-bounded, so a leaked-but-stale code is inert.
- **Revoked device** → next verify fails (server-side `revoked_at` check); existing sockets are disconnected via the socket `id/1` broadcast-disconnect pattern (assign a per-device socket id so revoke can `Endpoint.broadcast(disconnect)`).
- **Remote access enabled but no reachable interface / cert** → the toggle surfaces a clear error and **stays loopback-only** (fail safe, never bind half-configured).
- **Proxy misconfiguration** (someone fronts it anyway) → documented as unsupported; the no-proxy/direct-TLS rule is the mitigation, called out in setup docs.
- **Lost device** → revoke from the Devices screen; per-device scoping means no re-keying of others.

## Testing

- **Trust rule (unit, both choke points):** loopback allowed without a token; valid token allowed; expired / revoked / malformed / absent token rejected; non-loopback peer without token rejected. A regression test for the **proxy-collapse bypass** (a forwarded-for header must NOT confer loopback trust).
- **Pairing lifecycle:** generate → redeem once → second redeem rejected; TTL expiry; redeem mints a working token; revoke disconnects live sockets and blocks reconnect.
- **`remote_access` toggle:** default off = loopback-only (unchanged behavior); on = reachable bind + pairing active; half-configured fails safe to loopback.
- **Audit:** control actions logged at the defined granularity; raw keystrokes not logged.
- **Live acceptance (gated/opt-in, like the sprites live tests):** over a real tailnet, a phone pairs via QR and **drives** a live session on the laptop — submits a prompt, answers an ACP permission, `stop`s — with the instance bound non-loopback and no proxy in front.
- `cd backend && mix precommit` (compile --warnings-as-errors + format + test) and `cd frontend && bun run check` green.

## Open questions (to resolve during planning, not left vague)

- **`peer_data` reliability across bind modes** (Bandit, http vs https, IPv6 loopback `::1`) — confirm the loopback predicate covers `127.0.0.0/8` + `::1` and nothing else.
- **`PairingCode` store** — table vs Cachex/ETS; the plan pins it (leaning a table for auditability + TTL sweep).
- **Token expiry policy** — long-lived + revocation (simplest) vs short-lived + refresh; v1 leans long-lived signed token with server-side revocation.
- **Desktop sidecar bind** — how `main.rs` learns "remote enabled" (env from the setting, or the sidecar reads it on boot) and how the reachable interface/cert are selected.
- **Responsive route shape** — reuse the tiling session surface at a phone breakpoint vs a dedicated mobile route; decided with a mock in planning.

## Decisions log

| Decision | Rationale |
|---|---|
| Slice 1 = auth + reachability foundation; fleet view (2) and relay (3) deferred behind a transport seam | The hard, reusable engineering (auth, remote attach, web client) is identical across transports; later slices become new transports, not rewrites |
| Federation = live attach/proxy, **not** sync | A live session is a process pinned to its machine with in-memory scrollback; you attach to its stream. Record sync (mounted cloud drive, single-writer) is a separate, out-of-scope mechanism |
| One rule: loopback **or** valid device token | Collapses all authz to two choke points; loopback doubles as the pairing trust root, matching Legend's existing implicit-because-unreachable assumption |
| Bind directly + terminate TLS in Phoenix; **no** localhost-collapsing proxy | A TLS-terminating proxy to `127.0.0.1` would make every remote peer look like loopback — a total auth bypass; direct bind keeps "loopback = local" true |
| TLS optional on a mesh | WireGuard already encrypts the transport (token included); TLS is a PWA/secure-context upgrade, not a confidentiality requirement |
| Full control, not read-only | Same `SessionChannel` handlers, reachable + authed; read-only would be *more* code (a write gate). The cost is auth strength, not new code |
| Remote access **off by default**, explicit opt-in toggle | Local-first; "your machine isn't reachable unless you say so" |
| Device pairing (WhatsApp-Web model) over password / IdP | Physical-possession enrollment + per-device revocation; transport-agnostic credential; local-first (no external IdP) |
| Stateless `Phoenix.Token(device_id)`, revocation via `Device.revoked_at` | No token-at-rest to leak; immediate server-side revocation; idiomatic Phoenix |
| `Device.public_key` reserved now, unused in v1 | Loopback pairing is the right moment to establish keys for the future **zero-knowledge relay**; reserving the field/handshake slot avoids a re-pair migration |
| Relay = the monetization boundary; managed offering is hosted relay, app stays fully OSS | Open-core done right; paid sells *running it* (reach/identity/TLS/push), never capability; zero-knowledge keeps it "fair" |
| Audit at control-action granularity, not keystrokes | Proportionate insurance for RCE-grade exposure without high-volume, low-value keystroke logging |
| Mesh is the user's transport; Legend bundles no VPN | Keeps Legend transport-agnostic and dependency-free; the mesh choice (Tailscale free vs OSS Headscale/WireGuard) is the user's ops trade |
| Bind `0.0.0.0` + DeviceAuth, not a specific-interface bind | Desktop needs loopback (webview) + mesh (remote) at once; `0.0.0.0` serves both and the tested auth rule is the gate. Interface-isolation (dual listener) deferred as defense-in-depth. |
