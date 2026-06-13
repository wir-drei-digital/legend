# Sprites Reverse Tunnel — Design

**Date:** 2026-06-13
**Status:** Draft
**Builds on:** agent messaging (`2026-06-12-agent-messaging-design.md`), shared library (`2026-06-11-shared-library-design.md`)
**Part of:** the cloud-runtime effort (Spec 1 of 2). Spec 2 — *Sprites runtime + provisioning + library-over-MCP* — consumes this tunnel; it is **not** in scope here.

## Problem

We want to run agent sessions in [sprites.dev](https://sprites.dev) (Fly's persistent Firecracker microVMs) so agents are cloud-hosted, isolated, and survive the laptop closing. A cloud agent is only useful to Legend if it can still **call back into the backend** — for agent-to-agent messaging (`send_message`/`read_messages`) and shared-library access. That callback is the whole orchestration point.

Two traffic planes, only one of which is hard:

- **Control plane — backend → sprite (already reachable).** Creating, exec-ing, and driving the sprite are *outbound* calls from the backend to public Fly endpoints (`api.sprites.dev`, the per-sprite WSS). A backend behind NAT reaches these fine. No tunnel.
- **Data plane — agent-in-sprite → backend (the hard part).** The agent's MCP (`POST /api/mcp`) and library (`/api/library/*`) calls must reach the backend. The sprite can dial any public host, but the **local backend is not publicly addressable** (NAT, no inbound, loopback bind). Something must make it reachable.

The product is privacy-first (data sovereignty, OSS). Routing agent↔backend traffic through a third-party tunnel (Cloudflare quick tunnel terminates TLS at their edge; ngrok is proprietary) is off-brand and adds a vendor. The constraint: **no new third party, no public exposure, no manual user setup.**

## Decision: a reverse tunnel that rides sprites' own proxy

The sprites API exposes `WSS /v1/sprites/{name}/proxy` — after a JSON handshake (`{"host","port"}`) it becomes a raw bidirectional TCP relay between the **token-holding client (our backend)** and a port **inside the sprite**. That is a backend→sprite pipe. We turn it into a sprite→backend path with a small reverse-tunnel bridge, so the only trust boundary is "sprites" — which the user has already chosen by running agents there. Nothing is exposed publicly; the backend never opens an inbound port.

A pluggable **`Tunnel` seam** wraps this so real federation (the auto-paired, authenticated, outbound version of the same idea) drops in later as another provider without touching the runtime or library code that consumes it.

### Data flow

```
  In the sprite (Fly cloud)                  Local machine (behind NAT)

  agent CLI ──HTTP──▶ legend-bridge          Phoenix backend
                       :7777 (data)            /api/mcp, /api/library
                       :9000 (control) ◀──┐    (loopback :4100 / :4807)
                                          │              ▲
                          sprites proxy   │              │ dials localhost
                          WSS carrier  ───┼──────────────┤
                                          └── SpriteProxy tunnel (mux/de-mux)
                                              backend opens the proxy WSS,
                                              outbound → api.sprites.dev
```

1. The backend (outbound only) opens `WSS /v1/sprites/{name}/proxy` targeting the sprite's `127.0.0.1:9000` — the bridge's **control** port. This single pipe is the carrier.
2. Backend and bridge speak a small **stream-multiplexing protocol** over the carrier.
3. Inside the sprite the agent's HTTP client connects to the bridge's **data** port `127.0.0.1:7777` — this loopback URL is exactly what the agent is handed as its backend base URL.
4. Per inbound agent connection the bridge opens a new mux stream over the carrier.
5. The backend accepts the stream, dials its own `LegendWeb.Endpoint` loopback port, and splices `stream ↔ socket`.
6. So `agent → 127.0.0.1:7777 → mux → backend → 127.0.0.1:<endpoint> → /api/mcp | /api/library → back`. The agent believes the backend is local.

### Why a multiplexer (and not something simpler)

The proxy gives **one** carrier pipe per sprite, but the agent makes **concurrent** connections (e.g. a `read_messages` MCP call while a library read is in flight). One pipe + many concurrent connections ⇒ multiplexing. We own **both** ends, so a **minimal custom frame protocol** is the right call — it avoids depending on a yamux implementation in Elixir (none mature):

- Frame = `stream_id` + `type` + `length` + `payload`.
- Types: `OPEN` (bridge announces a new agent connection), `DATA`, `CLOSE`, `WINDOW` (credit-based flow control so a slow reader can't force unbounded buffering).
- MCP/library are short request/response exchanges (streamable HTTP, **no SSE** — confirmed in `MCPController`), so streams are short-lived and flow-control needs are modest; bounded per-stream buffers suffice. The exact wire format is pinned in the plan.

Rejected alternative: an HTTP-aware bridge that frames whole requests/responses. Raw TCP mux keeps the bridge HTTP-agnostic and sidesteps keep-alive/chunked-encoding edge cases.

## Components

### `Legend.Core.Tunnel` (behaviour) + `Legend.Core.Tunnel.Registry`

```elixir
@callback id() :: String.t()
# Make the local backend reachable from inside `target`. Returns the loopback
# base URL the agent uses (e.g. "http://127.0.0.1:7777") and an opaque handle.
@callback open(target :: map()) ::
            {:ok, %{base_url: String.t(), handle: term()}} | {:error, String.t()}
@callback close(handle :: term()) :: :ok
```

`target` is opaque (for the sprite provider: `%{sprite: name, token: ...}`). **The tunnel is a per-runtime concern, not a global one** — different runtimes pair with different transports: sprites → the sprite-proxy reverse tunnel; a self-hosted box you control → WireGuard/Tailscale/direct; local Docker → none at all. So tunnels live in a **registry keyed by id**, mirroring `:runtimes`/`:harnesses`: `config :legend, :tunnels, [Legend.Tunnels.SpriteProxy]`, with `Legend.Core.Tunnel.Registry.fetch/1` + `list/0`. **Which tunnel a runtime uses is declared by the runtime (Spec 2)** — `Legend.Runtimes.Sprites` will name `"sprite_proxy"`; a future self-hosted runtime names its own (or `nil` for direct reachability). This spec provides the registry and the one `SpriteProxy` provider. The endpoint loopback port the backend dials comes from `LegendWeb.Endpoint` config, not hardcoded.

### `Legend.Sprites` — minimal API client

Only what this spec needs (the full runtime adapter is Spec 2): bearer auth from `SPRITES_TOKEN`, `create_sprite/1`, `exec/3` (HTTP POST, non-interactive — used to launch the bridge), filesystem `write_file/3` + `chmod` (upload the bridge binary), and `open_proxy/3` (the `…/proxy` WSS, returning a process/stream the tunnel drives). HTTP via an HTTP client (e.g. `Req`); the proxy carrier needs an **outbound WebSocket client** (`Mint.WebSocket` / `:gun` / `WebSockex` — chosen in the plan), since the backend has only server-side Phoenix sockets today.

### `legend-bridge` — the in-sprite binary

A **static, dependency-free binary** (Rust, `x86_64-unknown-linux-musl` leaning — reuses the existing Tauri Rust toolchain; final target arch pinned in the plan against sprites' microVM arch). It:

- listens on `127.0.0.1:9000` (control) for the backend's proxy connection and on `127.0.0.1:7777` (data) for the agent;
- speaks the mux protocol over the control pipe;
- opens one mux stream per inbound data connection and splices bytes both ways.

Both listeners are **loopback-only** — nothing in the sprite is exposed beyond the agent itself. The binary is **owned and delivered by the Tunnel provider**, not by harness provisioning (Spec 2): on `open/1`, the provider uploads it via the sprites filesystem API, `chmod +x`, and launches it via exec. It is idempotent (skip upload if present and version-matched). The bridge being tunnel-owned is what keeps this spec independent of the harness `provision/0` work.

### `Legend.Tunnels.SpriteProxy` — the provider

`open/1`: ensure the bridge is present and running in the sprite → open the proxy WSS to `127.0.0.1:9000` → start the backend-side mux process → return `%{base_url: "http://127.0.0.1:7777", handle: pid}`. The mux process accepts streams, dials `LegendWeb.Endpoint` loopback, splices, and **reconnects the carrier** on drop (sprite hibernation/network blips) with backoff. `close/1` tears down the mux and the carrier; the bridge process dies with the sprite.

Lifecycle ownership: in Spec 2 the `SessionServer`/runtime calls `open/1` once the sprite is up (before the agent needs MCP) and `close/1` on session stop. In this spec a test harness drives `open`/`close` directly.

## What the agent sees

The tunnel returns a loopback `base_url`. Spec 2 injects it as the agent's backend URL (`LEGEND_MCP_URL = base_url <> "/api/mcp"`, library URL likewise) for `:api`-library runtimes — superseding the earlier idea of a static `LEGEND_PUBLIC_URL` config knob; the URL is now produced dynamically by the tunnel. Paths and the per-session bearer token are unchanged: the agent still authenticates MCP/library with its session token exactly as a local agent would.

## Security posture

- **No public exposure, no inbound port.** Both sprite listeners are loopback; the backend only makes outbound calls. The carrier is the sprites proxy, authenticated by `SPRITES_TOKEN`.
- **Trust boundary = sprites**, already chosen by running agents there. No Cloudflare/ngrok; no third party sees plaintext.
- **MCP/library still require the per-session bearer token** end to end — the tunnel carries bytes, it does not grant access.
- `SPRITES_TOKEN` is a backend secret (config/env), never sent into a sprite. Consistent with the single-user loopback posture and the recorded "auth before any broader remote exposure" caveat.

## Scope

**In this spec:** the `Tunnel` seam; `Legend.Sprites` minimal client (create/exec/fs/proxy-WSS); the `legend-bridge` binary; the backend mux + splice; the `SpriteProxy` provider with reconnect; config; and an **isolated end-to-end verification** that needs none of the runtime work.

**Deferred to Spec 2:** the `Runtime` behaviour implementation (PTY over WSS exec, `attach` for reattach, `capabilities`, `teardown`); the harness `provision/0` install contract; runtime-aware `:path` vs `:api` library injection and the `mcp_url`/library-url rewrite; the new MCP **library tools**; `SessionServer` wiring and the `:provisioning` status; the UI; and the app-level sprite lifecycle (1:1 session↔sprite, hibernate, destroy-on-delete).

## Error handling

- **Carrier drops** (hibernation, network) → mux reconnects with backoff; in-flight streams fail and the agent's HTTP client retries (MCP/library calls are idempotent reads or token-scoped writes). Repeated failure surfaces as `{:error, reason}` from a future `open` and is logged.
- **Sprite cold/absent** → `open/1` returns `{:error, ...}`; provider does not retry forever.
- **Bridge crash** → exec relaunches it on the next `open`; a crash mid-session drops the carrier (handled above).
- **Backend endpoint refuses the loopback dial** (boot race) → that stream resets; agent retries.
- **Backpressure** → `WINDOW` credits bound per-stream buffering; a stalled stream stops reading rather than growing memory.
- **Bad `SPRITES_TOKEN`** → client surfaces the API 401 as a clear `{:error, ...}`.

## Testing

- **Mux unit tests** (no network): frame round-trip; interleaved concurrent streams stay isolated; `CLOSE` half-close semantics; `WINDOW` flow control bounds buffering; carrier-drop mid-stream resets cleanly.
- **`Legend.Sprites` client:** request shaping against a mock; auth header; error mapping (401/404/5xx → `{:error, msg}`).
- **Provider integration (gated on `SPRITES_TOKEN`, opt-in like other live-credential tests):** create a sprite → `open/1` → from inside the sprite (via the client's exec) `curl http://127.0.0.1:7777/api/health` reaches the **local** backend; then `POST /api/mcp` (a token-authenticated `tools/list`) and `GET /api/library/tree` succeed; **concurrency** (two simultaneous in-sprite requests) both complete; kill the carrier and confirm reconnect; `close/1` tears everything down; `DELETE` the sprite.
- **Manual acceptance:** with the backend running locally and a real `SPRITES_TOKEN`, the integration script above prints the backend's health JSON *from inside a cloud sprite* with nothing publicly exposed.
- `mix precommit` (compile --warnings-as-errors + format + test) green.

## Open questions (resolved during planning, not left vague)

- **Bridge arch/target** — confirm sprites' microVM architecture and pin the musl target (likely `x86_64-unknown-linux-musl`); decide cross-compile in CI vs a checked-in artifact, mirroring how the Burrito sidecar binary is handled.
- **WSS client** for the proxy carrier — the backend has no outbound WebSocket client yet; pick `Mint.WebSocket` / `:gun` / `WebSockex` in the plan.
- **Bridge versioning** — embed a version string so `open/1` can skip re-upload; trivial, format pinned in the plan.

## Decisions log

| Decision | Rationale |
|---|---|
| Reverse tunnel over the sprites `…/proxy`, not Cloudflare/ngrok | No new third party, no plaintext to an edge, no public exposure; trust boundary stays "sprites" — aligns with the privacy-first vision |
| Pluggable `Tunnel` seam | Federation (auto-paired outbound tunnel + auth) slots in later as another provider; runtime/library code consumes `base_url` and doesn't care which transport is live |
| Tunnels are a per-runtime registry, not one global provider | Different runtimes need different transports (sprite-proxy / WireGuard / none); the runtime declares its tunnel id (Spec 2), matching the harness/runtime registry pattern |
| Custom minimal stream-mux, both ends ours | One carrier pipe + concurrent agent connections needs muxing; we own both ends, so avoid an (absent) Elixir yamux dependency |
| Raw TCP mux, not HTTP-aware framing | Bridge stays HTTP-agnostic; sidesteps keep-alive/chunked edge cases; MCP/library are plain request/response anyway |
| Loopback-only listeners in the sprite | Nothing in the sprite is reachable except by the agent; defence in depth on top of the proxy's token auth |
| Bridge owned by the Tunnel provider, not harness `provision/0` | Keeps this spec independent of Spec 2's provisioning machinery; the bridge is transport infra, the harness installer is agent infra |
| Static (Rust/musl) bridge binary | Dependency-free across arbitrary sprite images; reuses the existing Rust toolchain rather than adding Go |
| Tunnel returns a dynamic loopback `base_url` | Supersedes a static `LEGEND_PUBLIC_URL` knob; the agent always talks to `127.0.0.1:<bridge>` and thinks the backend is local |
| Spec split (tunnel first, runtime second) | The tunnel is the novel, riskiest piece and is independently verifiable with no runtime work; everything in Spec 2 depends on it |
| v1 flow control = bounded mpsc/mailbox backpressure, not WINDOW crediting | MCP/library are short request/response (no SSE); the WINDOW frame type exists in the codec but crediting is deferred until streaming/SSE MCP arrives |
