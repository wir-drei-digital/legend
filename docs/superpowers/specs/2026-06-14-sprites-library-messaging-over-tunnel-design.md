# Library + Messaging over the Reverse Tunnel (Spec 2b) — Design

**Date:** 2026-06-14
**Status:** Draft
**Builds on:** sprites reverse tunnel (`2026-06-13-sprites-reverse-tunnel-design.md`, Spec 1), sprites runtime (`2026-06-14-sprites-runtime-design.md`, Spec 2a), agent messaging (`2026-06-12-agent-messaging-design.md`), shared library (`2026-06-11-shared-library-design.md`)
**Part of:** the cloud-runtime effort — the final slice. Spec 1 built the tunnel seam; Spec 2a built the Sprites runtime (deliberately library/messaging-**dark**: `:api` runtimes get no `LEGEND_LIBRARY`/MCP env). This spec wires the tunnel into the session so a cloud agent is a full Legend participant.

## Problem

A Sprites session today runs an agent in the cloud, but it is **isolated**: `Legend.Runtimes.Sprites` declares `library: :api`, and `SessionServer` injects no `LEGEND_MCP_URL`/`LEGEND_SESSION_TOKEN`/`LEGEND_LIBRARY` for `:api` runtimes. So a cloud agent cannot message other agents (`send_message`/`read_messages`), delegate, or touch the shared library. The orchestration point — agents collaborating through Legend — does not reach the cloud.

Two things stand between us and that:

1. **The tunnel has never run live.** Spec 1 wrote the `Tunnel` seam, `SpriteProxy` provider, mux codec, and the `legend-bridge` Rust crate, but none of it was exercised against a real sprite (no cross-compiled bridge; the carrier WSS was never connected). Live bring-up surfaced two concrete blockers during Spec 2a probing (below).
2. **The library has no cloud-reachable interface.** Local (`:path`) agents read the library off the filesystem at `$LEGEND_LIBRARY`. A cloud (`:api`) agent has no such filesystem. The chosen interface is **MCP tools** (decided: "go with A … this works already for messages"), which don't exist yet.

## Decision

Ship in **two phases inside one spec** — Phase 1 retires the tunnel risk; Phase 2 delivers the payoff on top.

- **Phase 1 — bring the Spec-1 tunnel to life.** Cross-compile the bridge for sprites, fix the carrier's HTTP/2 bug, add carrier reconnect-on-drop, and run Spec 1's deferred end-to-end verification (reach the local backend *from inside a real sprite*).
- **Phase 2 — library + messaging over the tunnel.** Add library MCP tools; make `SessionServer` open the tunnel for tunnel-declaring runtimes, rewrite the MCP URL to the tunnel's loopback `base_url`, inject the session token + an `:api`-mode library primer, reconnect/close across the session lifecycle.

Messaging needs **no new tools** — the five signal-bus tools already exist; the cloud agent just needs to reach `/api/mcp` through the tunnel. Only the library interface is new.

## Data path (Spec 1, now made real)

```
  agent in sprite ──HTTP──▶ legend-bridge :7777 (data)
                                   │ one mux stream per connection
                                   ▼
                          SpriteProxy carrier  ── proxy WSS ──▶ api.sprites.dev
                          (backend, outbound)                        │
                                   ▲                                 ▼ relays to
                          backend dials its own              sprite 127.0.0.1:9000
                          LegendWeb.Endpoint loopback        (bridge control port)
                                   │
                                   ▼
                          /api/mcp · /api/library
```

The tunnel returns a loopback `base_url` (`http://127.0.0.1:7777`); the agent believes the backend is local and authenticates with its per-session bearer token exactly as a local agent does.

---

## Phase 1 — Tunnel bring-up

### 1.1 Build the bridge for sprites

Sprites run **x86_64 Linux** (confirmed during 2a probing: `bash … (x86_64-pc-linux-gnu)`). The only compiled artifact today is a macOS-native build. Cross-compile to **`x86_64-unknown-linux-musl`** (static, dependency-free across arbitrary sprite images — Spec 1's decision) via **`cargo-zigbuild`**, reusing the **zig already vendored for Burrito**. If zig 0.15.2 proves incompatible with `cargo-zigbuild`, the fallback linker is `musl-cross` (Homebrew).

- A `just build-bridge` task runs the cross-compile and writes the binary to `backend/priv/bridge/legend-bridge-x86_64-linux-musl` (gitignored, like the SPA build artifacts).
- `SpriteProxy.open/1` reads the binary from `priv/` and returns `{:error, "run just build-bridge"}` if it is absent.
- **Deferred:** automated bridge packaging into the web/sidecar releases. For this spec the binary is built locally; release integration is a follow-up (noted in scope).

### 1.2 Fix the carrier HTTP/2 bug

`Legend.Sprites.Proxy` (the carrier) calls `Mint.HTTP.connect(:https, …)` without forcing HTTP/1.1. Against the live API this fails with `%Mint.WebSocketError{reason: :extended_connect_disabled}` (the server sets `enable_connect_protocol: false`; WS-over-HTTP/2 per RFC 8441 is rejected). This is the exact bug fixed in `Legend.Sprites.Exec` during 2a. Fix: `Mint.HTTP.connect(:https, host, port, protocols: [:http1])`.

### 1.3 Deliver + launch the bridge

In `SpriteProxy.open/1`, before connecting the carrier:

1. **Presence/version check** via the WSS exec (`Legend.Sprites.Exec.run/3`, already verified in 2a): run a small command that prints the installed bridge version (e.g. `legend-bridge --version` or a sentinel file). Skip upload if present and version-matched (the bridge embeds a version string).
2. **Upload** via the sprites **filesystem API** (`Client.write_file/3`, base64) → `chmod +x`. **Probe-first:** the first Phase-1 task verifies the fs API round-trips a binary (write → read back → exec). **Documented fallback:** if the fs API proves unreliable, stream the binary as base64 over a non-TTY WSS exec (`base64 -d > …`); this requires adding a non-TTY exec mode to `Legend.Sprites.Exec` (clean binary stdin via the stream-id protocol `<<0,stdin>>`/`<<4>>`-EOF) and is only built if the probe fails.
3. **Launch detached** so the bridge outlives the exec session: `setsid legend-bridge >/tmp/legend-bridge.log 2>&1 &` (listens on `127.0.0.1:9000` control + `127.0.0.1:7777` data, loopback-only).
4. **Connect the carrier:** open the proxy WSS to `127.0.0.1:9000` (JSON handshake `{"host":"127.0.0.1","port":9000}`), then drive the mux `Server`.

### 1.4 Carrier reconnect-on-drop

Sprites hibernate when idle, dropping the carrier WSS. The mux `Server` **monitors the carrier process**; on exit it re-opens the proxy WSS with backoff (the bridge accepts sequential carrier connections — Spec 1). In-flight mux streams reset; the agent's HTTP client retries (MCP/library calls are idempotent reads or token-scoped writes). The session/PTY is independent of the carrier — a carrier blip never kills the agent.

### 1.5 Phase-1 exit criteria (Spec 1's deferred e2e, run for real)

With the backend running locally and a valid `SPRITES_TOKEN`, against a live sprite:

- `curl http://127.0.0.1:7777/api/health` *from inside the sprite* returns the backend's health JSON.
- A token-authenticated `POST http://127.0.0.1:7777/api/mcp` `tools/list` succeeds.
- Two concurrent in-sprite requests both complete (mux stream isolation).
- Killing the carrier and re-issuing a request succeeds after reconnect.
- Nothing is publicly exposed; the backend opens no inbound port.

---

## Phase 2 — Library + messaging over the tunnel

### 2.1 Library MCP tools (`Legend.Core.Library.Tools`)

A new module mirroring `Legend.Core.Signals.Tools` (pure dispatch: `(caller session, tool name, string-keyed args) → {:ok, text} | {:error, text}`), exposing four tools through the `Legend.Core.Library` containment chokepoint:

| Tool | Args | Wraps |
|---|---|---|
| `library_list` | _(none)_ | `Library.list_tree/0` (whole tree, serialized to text) |
| `library_read` | `path` | `Library.read/1` (`{:error, :not_text}` → "not a text file") |
| `library_write` | `path`, `content` | `Library.write/2` |
| `library_delete` | `path` | `Library.delete/1` |

- **Auth/identity:** unchanged — the per-session bearer token authenticates and identifies the caller (the MCP controller's existing `authenticate` plug). The tools never take a caller identity.
- **Containment:** every path goes through `Library.safe_path` (lexical, `{:error, :unsafe_path}` rejected) — write is no riskier than the existing `/api/library/*` HTTP API.
- **Error rendering:** `{:error, atom}` → a short sanitized message (e.g. `:unsafe_path` → "path escapes the library", `:not_text` → "not a text file"); never leak absolute paths or internals (matches the signal-tools posture).
- **Exposure:** available to **every** MCP caller (no per-caller gating — YAGNI; tools are token-scoped). Local `:path` agents may use the filesystem or the tools; cloud `:api` agents use the tools.

### 2.2 MCP dispatch composition (small structural change)

`LegendWeb.MCPController` currently routes `tools/list`/`tools/call` to `Signals.Tools` only. Generalize to a list of tool providers `[Signals.Tools, Library.Tools]`:

- `tools/list` → `Enum.flat_map(providers, & &1.list())`.
- `tools/call` → route by name to the provider whose `list/0` advertises it; unknown → `-32601`-style "unknown tool". (Both modules keep their own `dispatch/3`; the controller picks the owner by name rather than chaining catch-alls, so neither module's fallthrough masks the other.)

### 2.3 Tunnel lifecycle in `SessionServer`

For a runtime whose `capabilities.tunnel` is non-nil, `init` gains tunnel steps. Ordering for a tunneled `:api` runtime:

1. `caps = Runtime.capabilities(runtime)` (Spec 2a).
2. `maybe_provision/4` (Spec 2a) — for Sprites this ensures the sprite exists (idempotent create keyed by `session.id`) and the harness is installed.
3. **Open the tunnel:** `tunnel = Tunnel.Registry.fetch(caps.tunnel)`; `{:ok, %{base_url, handle: tunnel_handle}} = tunnel.open(%{session_id: session.id})`. The target is the **generic `%{session_id: …}`** — `SpriteProxy` interprets it as the sprite name (which already equals `session.id`), so `SessionServer` stays transport-agnostic and needs no new `Runtime` callback.
4. `spec = build_command(build_opts(session, mode, caps, base_url))` and `platform_env(session, caps, base_url)` (signatures gain `base_url`; nil for `:path`).
5. `start_or_attach/4` (Spec 2a) launches/reattaches the agent.
6. Hold `tunnel_handle` in server state; `tunnel.close(tunnel_handle)` on `terminate` / runtime exit.

**Open failure** (sprite cold, bridge won't launch, carrier exhausts initial-connect retries) → `SessionServer` fails the session with a clear error (a half-wired `:api` agent is worse than a loud failure). A *mid-session* carrier drop is handled by §1.4 reconnect, not by failing the session.

### 2.4 Wiring the agent to the tunnel

`build_opts`/`platform_env` for `:api` now receive `base_url` and produce (compare Spec 2a, where `:api` produced empty):

- **MCP:** `mcp_url = base_url <> "/api/mcp"` (instead of `LegendWeb.Endpoint.url()`); `:mcp` opts (`%{url, token: session.mcp_token}`) + `LEGEND_MCP_URL`/`LEGEND_SESSION_TOKEN` env. → **messaging works with zero new tooling.**
- **Library:** an `:api`-mode primer (`Library.primer(:api)`) telling the agent to use the `library_*` MCP tools (there is no `$LEGEND_LIBRARY` filesystem in the sandbox). `Library.primer/0` becomes `Library.primer(mode)` — `:path` keeps the existing "$LEGEND_LIBRARY filesystem" text; `:api` describes the tools. **No `LEGEND_LIBRARY` env** for `:api`.
- **Messaging primer + instructions** flow exactly as for local agents.

`:path` runtimes: `base_url` is nil, `mcp_url` is the endpoint URL, behavior unchanged.

### 2.5 Resume interaction

On `:resume`, the agent process is still alive in the sprite (Exec reattach, Spec 2a), but the carrier died with the backend. Resume therefore **re-opens a fresh tunnel** (step 3 runs again). The loopback `base_url` is stable (`127.0.0.1:7777`), so the agent's baked-in MCP config still points to the right place — reattach + re-open and the backend is reachable again. No agent reconfiguration.

---

## Components touched

**Phase 1 (mostly existing Spec-1 code, brought live):**
- `bridge/` — cross-compile target + `just build-bridge`; embed a version string.
- `backend/lib/legend/sprites/proxy.ex` — `protocols: [:http1]` fix.
- `backend/lib/legend/tunnels/sprite_proxy.ex` + `…/server.ex` — bridge deliver/launch, carrier reconnect-on-drop monitor.
- `backend/lib/legend/sprites/client.ex` — verify/finalize `write_file`/`chmod` shapes against the live fs API.

**Phase 2 (new + wiring):**
- `backend/lib/legend/core/library/tools.ex` — **new**, the four library MCP tools.
- `backend/lib/legend_web/controllers/mcp_controller.ex` — provider composition.
- `backend/lib/legend/core/library.ex` — `primer/1` (mode-aware).
- `backend/lib/legend/core/agents/session_server.ex` — tunnel open/close, `base_url` through `build_opts`/`platform_env`, resume re-open.
- `backend/test/support/tunnels/test.ex` — **new** `Legend.Tunnels.Test` double (records open/close, returns a fake `base_url`).

## Error handling

- **Tunnel open fails** → session `:failed` with a clear reason.
- **Carrier drops mid-session** → reconnect with backoff (§1.4); in-flight calls fail and retry; session unaffected.
- **Library tool errors** (`:unsafe_path`, `:not_text`, not-found, IO) → MCP `isError` result, sanitized message.
- **Bridge binary missing** → `open` returns `{:error, "run just build-bridge"}`.
- **Bad `SPRITES_TOKEN`** → the API 401 surfaces as `{:error, …}` from `open` → session `:failed`.

## Testing

- **Offline:**
  - `Library.Tools` unit tests: each op through the chokepoint; `:unsafe_path` rejection; `:not_text` mapping; error sanitization.
  - `/api/mcp`: `tools/list` includes the four library tools; a token-auth `library_write` → `library_read` round-trips against the real endpoint (no tunnel).
  - `SessionServer` wiring via `Legend.Tunnels.Test` + the Test runtime declaring a tunnel capability: assert `open`/`close` called, `base_url`-derived `LEGEND_MCP_URL` in the spec env, `:api` library primer present, `:path` unchanged.
- **Live (gated on `SPRITES_TOKEN`, opt-in):** Phase-1 exit criteria (§1.5).
- **Manual acceptance:** a cloud Claude Code session messages a local agent and gets a reply; `library_write`s an artifact and reads it back; goes idle (sprite hibernates) then resumes and still reaches the backend; deleting the session tears down the tunnel + sprite.
- `mix precommit` green.

## Scope

**In:** bridge cross-compile + `just build-bridge`; carrier HTTP/1.1 fix; bridge deliver/launch (fs API, probe-first); carrier reconnect-on-drop; live e2e bring-up; `Library.Tools` (4 tools); MCP provider composition; `Library.primer/1`; `SessionServer` tunnel open/close + `base_url` wiring + resume re-open; `Legend.Tunnels.Test`.

**Deferred:** federation (auth + auto-pairing — the recorded "auth before broader remote exposure" caveat still stands); non-sprite tunnels (WireGuard/Docker); library search/indexing; automated bridge packaging into releases (built locally via `just` for now); SSE/streaming MCP (the mux `WINDOW` crediting stays dormant — MCP is request/response); the non-TTY exec mode (only built if the fs-API probe fails).

## Decisions log

| Decision | Rationale |
|---|---|
| One spec, two phases (tunnel bring-up → payoff) | The bring-up and the wiring are one dependency chain; keeping them together means the final live test exercises the whole real path |
| Library access via MCP tools, not a mount/CLI | The agent already speaks MCP (the bus); no filesystem in an `:api` sandbox; "works already for messages" |
| Full read-write library tools (list/read/write/delete) | Parity with `:path` agents and the UI; the library is the substrate for handoffs/artifacts — a read-only cloud agent is lopsided; containment already enforced |
| Library tools exposed to all MCP callers | No per-caller gating needed — token-scoped like the signal tools; local agents simply prefer the filesystem (YAGNI) |
| Carrier reconnect-on-drop included (not deferred) | Sprites hibernate when idle → the carrier drops in the *normal* always-on lifecycle, not as a corner case |
| Bridge delivery via the sprites fs API, probe-first | Delivery is a per-provider concern behind the `Tunnel` seam, so "sprites-specific" is fine; base64-over-exec is the documented fallback if the fs API is unreliable |
| Generic `%{session_id}` tunnel target | Keeps `SessionServer` transport-agnostic; `SpriteProxy` maps it to the sprite name (already = `session.id`); avoids a new `Runtime` callback |
| `base_url` threaded into `build_opts`/`platform_env` | The MCP URL must point at the tunnel loopback, not the endpoint, for `:api` runtimes; `:path` passes nil and is unchanged |
| Resume re-opens a fresh tunnel | The agent survives in the sprite but the carrier died with the backend; the stable loopback `base_url` means no agent reconfiguration |
| `cargo-zigbuild` to musl-static, reusing vendored zig | Static binary works across arbitrary sprite images; reuses the toolchain already present for Burrito; `musl-cross` fallback |
