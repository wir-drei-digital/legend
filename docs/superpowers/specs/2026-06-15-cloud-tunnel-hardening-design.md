# Cloud Tunnel Hardening — Design

**Status:** approved (design), pending implementation
**Date:** 2026-06-15
**Builds on:** Spec 1 (reverse tunnel), Spec 2a (sprites runtime), Spec 2b (library + messaging over the tunnel)

## Goal

Close the security and robustness gaps that the cloud-runtime tunnel opened. Today a sprite
sandbox reaches the **entire** Phoenix endpoint over its loopback tunnel, can spawn a shell on the
host, keeps a network path alive after the agent dies, and rides an unbounded stream mux. This spec
narrows the tunnel to an authenticated, session-bound MCP surface; closes the path on exit;
constrains agent spawning; bounds the mux; gates launch on carrier readiness; versions the bridge;
and surfaces runtime/harness compatibility in the UI.

This is one cohesive effort ("harden the cloud tunnel"), executed in three phases in risk order.

## Threat model & trust posture

Single-user, local-first PoC. The host backend is trusted. A **sprite sandbox is semi-trusted**:
it runs the user's own agent, but the agent (or a process it spawns, or a future compromise) is the
realistic adversary for the tunnel boundary. The defenses below assume the *content flowing back
through the tunnel may be hostile* even though the user started the session. Federation /
multi-tenant exposure remains out of scope (see Spec 2b deferred list); per-session library scoping
and a write-size cap are still gates for that future and are **not** part of this spec.

`SPRITES_TOKEN` stays a backend-only secret, never sent into a sprite. No third-party tunnels.

## Verified current state (the gaps)

All confirmed by reading the code on 2026-06-15:

| # | Gap | Evidence |
|---|-----|----------|
| 1 | Tunnel targets the **whole** endpoint | `SpriteProxy.open` → `Server.start_link(target_port: endpoint_port())`; `handle_frame(:open)` dials `127.0.0.1:<endpoint_port>`. All routes reachable. |
| 2 | Only `/api/mcp` is authenticated | `router.ex`: `/api/sessions` (JSON:API), `/api/settings/*`, `/api/library/*`, `/api/harnesses`, `/socket` are all unauthenticated. |
| 3 | No tunnel↔session binding | `MCPController.authenticate` resolves token→session but nothing ties a request to the tunnel it arrived on. |
| 4 | Tunnel never closed on runtime exit | `SessionServer.handle_info({:runtime_exit, …})` does not touch `state.tunnel`; only `terminate/2` (on delete) closes it. An `:exited` server keeps the `SpriteProxy.Server` reconnecting forever. |
| 5 | `start_agent` escalates remote→local | `Signals.Tools.start_agent` calls `Agents.start_session/1` with **no** `runtime_id`; `Session.runtime_id` defaults to `"local_pty"`. A sprite agent spawns a host shell. |
| 6 | Mux has no limits | `mux.rs` `read_frame` does `vec![0u8; length]` for a u32 `length` (up to 4 GiB); `mux.ex` buffers until `len` bytes arrive. No frame cap, stream cap, or idle timeout either side. |
| 7 | `open/1` returns before carrier is usable | `Server.start_link` returns after `init`; the carrier connects + receives `{"status":"connected"}` asynchronously in `Proxy.handle_continue(:open)`. The agent can launch against a not-yet-ready MCP URL. |
| 8 | Bridge path unversioned | `@bridge_dest "/tmp/legend-bridge"`; `pgrep -x legend-bridge` skips relaunch even when a *stale* (older-protocol) bridge from a prior Legend version is the running one. |
| 9 | UI surfaces no compatibility | Frontend fetches `Runtime.capabilities` but never renders/uses it; all harness×runtime combos presented as valid; a no-installer harness on a provisioning runtime fails at launch with a generic error. |

---

## Phase 1 — Security boundary (gaps 1, 2, 3, 4, 5)

### 1.1 Per-session tunnel listener (gaps 1 + 2 + 3, unified)

**Decision (approved):** each session's de-mux `Server` owns a **dedicated loopback listener on an
OS-assigned ephemeral port**, bound to `127.0.0.1` only, serving a minimal plug that mounts **only**
`POST /api/mcp` and `GET /api/health`. The `Server` dials *that* listener instead of the Phoenix
endpoint. One mechanism delivers all three gaps; a single shared listener cannot deliver gap 3
(the `Server` raw-relays opaque TCP, so it can't tell a shared listener which tunnel a request came
from). Ephemeral port ⇒ **no new config** in any env file and no second desktop-sidecar port.

**New module `LegendWeb.TunnelPlug`** (a `Plug.Router`):

```elixir
defmodule LegendWeb.TunnelPlug do
  use Plug.Router

  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :match
  plug :dispatch

  # Bandit passes {LegendWeb.TunnelPlug, bound_session_id: id} → opts reach call/2.
  def call(conn, opts) do
    super(assign(conn, :bound_session_id, Keyword.fetch!(opts, :bound_session_id)), opts)
  end

  get "/api/health" do
    send_resp(conn, 200, "ok")          # no auth, no data — connectivity probe only
  end

  post "/api/mcp" do
    case LegendWeb.TunnelAuth.authenticate(conn, conn.assigns.bound_session_id) do
      {:ok, conn, session} ->
        case Legend.Core.MCP.handle(session, conn.body_params) do
          :accepted -> send_resp(conn, 202, "")
          {:ok, response} -> send_json(conn, 200, response)
        end

      {:error, conn} ->
        conn   # TunnelAuth already sent 401/403 + halted
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

**New module `LegendWeb.TunnelAuth`** — boundary auth + session binding:

```elixir
def authenticate(conn, bound_session_id) do
  with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
       token when token != "" <- token,
       {:ok, session} <- Agents.get_session_by_token(token) do
    if session.id == bound_session_id do
      {:ok, conn, session}
    else
      {:error, conn |> send_resp(403, ~s({"error":"token not valid for this tunnel"})) |> halt()}
    end
  else
    _ -> {:error, conn |> send_resp(401, ~s({"error":"invalid or missing token"})) |> halt()}
  end
end
```

The bound id is the session id (the sprite is named by session id; `open(%{session_id: name})`
already carries it). A leaked token is useless except through its own tunnel.

### 1.2 Extract shared MCP dispatch (`Legend.Core.MCP`)

Local sessions still reach MCP at the main endpoint (`mcp_url()`), cloud sessions via `TunnelPlug`.
Both need identical JSON-RPC handling, so lift it out of `MCPController` into a core module:

```elixir
defmodule Legend.Core.MCP do
  @tool_providers [Legend.Core.Signals.Tools, Legend.Core.Library.Tools]

  # :accepted for id-less notifications; {:ok, response_map} otherwise.
  @spec handle(Agents.Session.t(), map()) :: :accepted | {:ok, map()}
  def handle(session, params)

  def tools(), do: Enum.flat_map(@tool_providers, & &1.list())
end
```

`MCPController` becomes a thin wrapper: its `authenticate` plug (token→session, **no** binding — it's
same-host loopback for local sessions) then `Legend.Core.MCP.handle/2`. Behaviour is unchanged for
local sessions; this is a pure refactor on that path, covered by the existing
`mcp_library_test.exs` / messaging tests.

### 1.3 `Server` owns the listener

`Legend.Tunnels.SpriteProxy.Server.init` gains opts `:session_id` and `:notify` (the `open` caller,
for readiness — see §2.2). In `init` it:

1. Allocates a free loopback port: `{:ok, s} = :gen_tcp.listen(0, ip: {127,0,0,1}); {:ok, port} = :inet.port(s); :gen_tcp.close(s)`. (Accepted tiny TOCTOU race — loopback, single-user.)
2. Starts the listener **linked**: `Bandit.start_link(plug: {LegendWeb.TunnelPlug, bound_session_id: session_id}, scheme: :http, ip: {127,0,0,1}, port: port, thousand_island_options: [num_acceptors: 2])`.
3. Sets `target_port: port` in state and stores `listener: pid`.

`handle_frame(:open)` is unchanged except it dials the listener's `target_port` (already reads
`state.target_port`). `terminate/2` stops the listener (`Process.alive?` guard) in addition to the
carrier. A `{:EXIT, listener, reason}` (the listener pid) → `{:stop, {:listener_down, reason}, state}`
(loopback Bandit crash is unexpected; fail safe and visible rather than a silent half-broken tunnel —
the session shows `:exited`, scrollback preserved, and resume reopens a fresh tunnel). Accepted v1
simplification: no in-place listener restart.

`SpriteProxy.open` passes `session_id: name` (and `notify: self()` for §2.2) to `Server.start_link`.
`@bridge_dest`/`@control_port`/`@data_port` and the handle shape (`%{server: srv}`) are unchanged.

### 1.4 Close the tunnel on runtime exit (gap 4)

`SessionServer.handle_info({:runtime_exit, code}, state)` (the non-`exited?` clause): after
`finish_session!`, call `maybe_close_tunnel(state.tunnel)` and set `tunnel: nil` in the returned
state. Scrollback and the `:exited` server stay; the network path dies with the agent process.
`terminate/2` remains the backstop (`maybe_close_tunnel(nil)` is already a no-op). The crashed-runtime
path (`{:EXIT, _pid, _reason}` → `handle_info({:runtime_exit, nil}, …)`) inherits the fix.

### 1.5 Spawn policy (gap 5)

`Signals.Tools.start_agent` resolves `runtime_id = args["runtime"] || session.runtime_id` (**inherit
the caller's runtime by default**) and runs an authorization check before `start_session`:

```elixir
defp authorize_spawn(caller_session, target_runtime_id) do
  with {:ok, target_mod} <- Runtime.Registry.fetch(target_runtime_id) do
    caller_caps = caps_for(caller_session.runtime_id)
    target_caps = Runtime.capabilities(target_mod)

    cond do
      target_runtime_id == caller_session.runtime_id -> :ok          # inherit / same
      host_runtime?(target_caps) and remote_caller?(caller_caps) and
          not allow_remote_host_spawn?() ->
        {:error, "remote sessions cannot spawn host (#{target_runtime_id}) sessions"}
      true -> :ok                                                    # e.g. local→cloud
    end
  else
    :error -> {:error, "unknown runtime: #{target_runtime_id}"}
  end
end

defp host_runtime?(caps), do: caps.tunnel == nil and caps.library == :path
defp remote_caller?(caps), do: caps.tunnel != nil
defp allow_remote_host_spawn?, do: Application.get_env(:legend, :allow_remote_host_spawn, false)
```

"Host runtime" is classified by **capabilities** (`tunnel: nil, library: :path` → `local_pty`), not a
hardcoded id. The dangerous direction (remote→host) is gated behind `:allow_remote_host_spawn`
(default **false**, read at runtime, no config-file change required). `local→cloud` and
`same-runtime` stay open. The optional `runtime` arg is added to the `start_agent` tool inputSchema
(default = inherit) so cross-runtime delegation is possible *and* the denial is testable. `handoff`'s
spawn path (`handoff_spawn`) inherits the same `start_agent` and is therefore covered.

### Phase 1 tests

- **`LegendWeb.TunnelPlug` / `TunnelAuth`** (unit, `Plug.Test`): no token → 401; valid token for a
  *different* session → 403; valid token for the bound session → MCP `tools/list` succeeds; requests
  to `/api/sessions`, `/api/settings/library-path`, `/api/library/file`, `/socket` → **404** (not
  mounted); `GET /api/health` → 200 without a token.
- **Runtime-exit closes tunnel** (extend `session_tunnel_test.exs`): start a session with a
  tunnel-capable runtime double; send `{:runtime_exit, 0}`; assert `{:test_tunnel, :close, _}` is
  received and the session is `:exited`.
- **Spawn policy** (`signals/tools_test.exs` or a new `spawn_policy_test.exs`): remote caller +
  `runtime: "local_pty"` → error, no child session created; same with `allow_remote_host_spawn: true`
  → child created; local caller, no `runtime` arg → child inherits `local_pty`; remote caller, no
  `runtime` arg → child inherits the remote runtime.

Tests need both a **host-capability** runtime double and a **remote-capability** runtime double
(caps `tunnel: "test_tunnel", library: :api`). Extend the existing test runtime / config rather than
adding production code (see plan).

---

## Phase 2 — Robustness (gaps 6, 7, 8)

### 2.1 Mux resource limits (gap 6)

Concrete limits (approved), applied **symmetrically** in `mux.rs` and `mux.ex`:

| Limit | Value | On violation |
|-------|-------|--------------|
| Max frame payload | **1 MiB** (`1_048_576`) | close carrier |
| Max concurrent streams / tunnel | **256** | reply CLOSE for the over-cap stream |
| Per-stream idle timeout | **120 s** | close that stream |
| Per-stream backpressure | bounded | Rust: existing bounded channels; Elixir: `active: :once` re-arm |

**Elixir (`mux.ex`):** change `decode/1` contract to `{:ok, [Frame], leftover} | {:error, :frame_too_large}`;
reject at the header (`when len > @max_frame_payload`) *before* matching the payload binary, so the
buffer can never accumulate beyond one max frame. `Server.handle_info({:carrier_data, …})` matches the
new contract; `{:error, :frame_too_large}` → log + drop the carrier (kills `state.out`, which triggers
the existing reconnect path; a persistently hostile sprite only DoSes itself — accepted). Stream cap in
`handle_frame(:open)`: `map_size(state.streams) >= @max_streams` → `out` a CLOSE, don't dial. Idle
timeout via a periodic `:sweep` (every 30 s) closing streams whose last-activity exceeds 120 s; track
`last_seen` per stream and refresh on `:tcp`/`:data`. Switch the dial to `active: :once` and re-arm
with `:inet.setopts(sock, active: :once)` after each `{:tcp, …}`.

**Rust (`mux.rs`):** `read_frame` rejects `length > MAX_FRAME_PAYLOAD` before allocating; cap the
streams `HashMap` at `MAX_STREAMS`; add a per-stream read timeout (`tokio::time::timeout`, 120 s) that
closes the stream. Add a `#[cfg(test)]` unit test for the oversized-frame rejection.

### 2.2 Carrier readiness gate (gap 7)

`Proxy.dispatch_frame({:text, …})` already flips `connected: true` on `{"status":"connected"}`; add
`send(state.server, :carrier_ready)` there. `Server` handles `:carrier_ready` → on the **first** ack,
`send(notify, {:tunnel_ready, self()})` and set a `ready_notified` flag (reconnects after a running
session don't re-block). `SpriteProxy.open`, after `Server.start_link` returns, blocks:

```elixir
receive do
  {:tunnel_ready, ^srv} -> {:ok, %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{server: srv}}}
after
  @ready_timeout_ms -> stop(srv); {:error, "tunnel carrier readiness timed out"}
end
```

`@ready_timeout_ms` = **15_000** (covers the WSS handshake + the `Proxy`'s 5×200 ms retry ladder).
`open/1` already runs synchronously inside `SessionServer.init` after `ensure_bridge`, so blocking here
is fine; a timeout fails the session cleanly via the existing `maybe_open_tunnel` error path. The
Phase-1 `Server` changes already thread `notify`; this phase adds the `:carrier_ready`/`:tunnel_ready`
plumbing and the `receive`.

### 2.3 Bridge versioning (gap 8)

Content-address the bridge by a short hash of the binary the backend is about to deliver, so a stale
bridge from a prior Legend version is detected and replaced (they share the fixed `9000/7777`, so the
stale one *must* be killed):

```elixir
defp ensure_bridge(name, bin) do
  sha = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower) |> binary_part(0, 8)
  dest = "/tmp/legend-bridge-#{sha}"
  # 1. Is OUR version already running? (resume fast-path)
  case Exec.run(name, spec("pgrep -f '#{dest}' >/dev/null 2>&1")) do
    {:ok, %{status: 0}} -> :ok
    _ -> deliver_and_launch(name, dest, bin)   # upload, kill any stale, launch
  end
end
```

`deliver_and_launch`: `Client.write_file(name, dest, bin)` then `Exec.run` of
`pkill -f '/tmp/legend-bridge-' >/dev/null 2>&1 || true ; setsid #{dest} >/tmp/bridge.log 2>&1 & ; sleep 0.3`.
The launch path is keyed on the versioned `dest`, so `pgrep -f '<dest>'` detects *our exact* version and
`pkill -f '/tmp/legend-bridge-'` reaps any other. Add a `--version` flag to the Rust bridge
(prints `env!("CARGO_PKG_VERSION")` and exits 0) for debugging. The cross-compiled binary stays
gitignored at `backend/priv/tunnel/legend-bridge-x86_64-linux`; Rust changes are validated by
`cargo test`, and live use requires `just build-bridge` (noted, optional, like the 2a/2b capstones).

---

## Phase 3 — UI compatibility (gap 9)

**Backend:** `HarnessController.index` adds `provisionable: Harness.provision_for(mod) != nil` to each
harness map. (No new endpoint; `GET /api/runtimes` already returns `capabilities`.)

**Frontend:** add `provisionable: boolean` to the `Harness` interface. In `NewSessionDialog`, compute
`incompatible = selectedRuntime?.capabilities?.provisions && !selectedHarness?.provisionable`; when
true, disable **Start** and show a clear reason (e.g. "hermes can't be auto-installed on this runtime
— pick a different harness or runtime"). Continue to surface the existing harness `setup.status`
(already fetched). This is presentation only; backend validation remains the source of truth.

**Tests:** `bun run check` (svelte-check) must stay clean; a lightweight component assertion for the
disabled-Start path if the frontend test harness supports it (confirm in plan), else manual + check.

---

## Out of scope / accepted caveats

- **Per-session library scoping & write-size cap** — gates for federation/multi-tenant, not this
  spec (carried from Spec 2b deferred list).
- **Listener crash auto-restart** — a loopback Bandit crash stops the `Server` (fail-safe, visible);
  no in-place restart in v1.
- **Symlink escape** in the library containment — unchanged single-user PoC caveat.
- **Mux flow-control (WINDOW frames)** — remain no-ops; backpressure is bounded channels +
  `active: :once`, not credit-based windows.
- **Ephemeral-port TOCTOU** — the `listen(0)`→close→bind window is accepted on loopback.

## Documentation

`docs/ARCHITECTURE.md` gets: the tunnel-boundary model (per-session listener, MCP+health only, auth +
session binding), the close-on-exit and spawn-policy rules, the mux limits, the readiness gate, the
bridge-versioning scheme, and the `:allow_remote_host_spawn` config knob. Update in the same cycle.

## Test/verification summary

`cd backend && mix precommit` (compile --warnings-as-errors + format + test), `cd frontend && bun run
check`, `cd bridge && cargo test`. Live e2e (optional capstone, like 2a/2b): rebuild the bridge
(`just build-bridge`) and confirm a real sprites session reaches MCP through the narrowed,
auth-bound listener and is denied a `local_pty` spawn.
