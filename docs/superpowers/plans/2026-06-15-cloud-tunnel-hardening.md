# Cloud Tunnel Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Narrow, authenticate, and session-bind the cloud-runtime reverse tunnel; close it on agent exit; constrain remote→host spawning; bound the stream mux; gate launch on carrier readiness; version the bridge; and surface runtime/harness compatibility in the UI.

**Architecture:** Each cloud session's de-mux `Server` owns a dedicated loopback `Bandit` listener on an ephemeral port that serves *only* an authenticated, session-bound `POST /api/mcp` (+ `GET /api/health`) via a new `LegendWeb.TunnelPlug`; the `Server` dials that listener instead of the full Phoenix endpoint. MCP dispatch is lifted into `Legend.Core.MCP` so the main endpoint (local sessions) and the tunnel listener (cloud sessions) share it. Robustness limits land symmetrically in `mux.ex` and `bridge/src/mux.rs`.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 / Bandit 1.5 / Plug.Router; Rust (tokio) bridge; SvelteKit 2 / Svelte 5 runes.

**Spec:** `docs/superpowers/specs/2026-06-15-cloud-tunnel-hardening-design.md`

---

## File structure

**Create:**
- `backend/lib/legend/core/mcp.ex` — `Legend.Core.MCP` shared JSON-RPC dispatch.
- `backend/lib/legend_web/tunnel_auth.ex` — `LegendWeb.TunnelAuth` boundary auth + session binding.
- `backend/lib/legend_web/tunnel_plug.ex` — `LegendWeb.TunnelPlug` minimal listener (MCP + health).
- `backend/test/legend/core/mcp_test.exs`
- `backend/test/legend_web/tunnel_plug_test.exs`
- `backend/test/legend/core/signals/spawn_policy_test.exs`

**Modify:**
- `backend/lib/legend_web/controllers/mcp_controller.ex` — thin wrapper over `Legend.Core.MCP`.
- `backend/lib/legend/tunnels/sprite_proxy/server.ex` — own the listener; mux limits; readiness.
- `backend/lib/legend/tunnels/sprite_proxy.ex` — `open/1` passes `session_id`+`notify`; readiness wait; bridge versioning.
- `backend/lib/legend/sprites/proxy.ex` — signal `:carrier_ready` on the connected ack.
- `backend/lib/legend/core/agents/session_server.ex` — close the tunnel on `:runtime_exit`.
- `backend/lib/legend/core/signals/tools.ex` — spawn policy + `runtime` arg.
- `backend/lib/legend/core/tunnel/mux.ex` — frame-size cap + `decode/1` contract.
- `backend/lib/legend_web/controllers/harness_controller.ex` — `provisionable` field.
- `bridge/src/mux.rs`, `bridge/src/main.rs` — frame/stream/timeout limits + `--version`.
- `frontend/src/lib/sessions.ts`, `frontend/src/lib/components/NewSessionDialog.svelte` — compatibility guard.
- `backend/test/legend/tunnels/sprite_proxy/server_test.exs` — new readiness/listener tests.
- `docs/ARCHITECTURE.md`.

**Commit discipline:** run all `git` from the repo root `/Users/daniel/Development/legend` (NOT from `backend/` — relative `backend/...` paths break after `cd backend`). Every commit message ends with:
```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```
`mix` commands run from `backend/`. Backend gate: `cd backend && mix precommit`.

---

# PHASE 1 — Security boundary

## Task 1: Extract `Legend.Core.MCP` (shared dispatch)

**Files:**
- Create: `backend/lib/legend/core/mcp.ex`
- Modify: `backend/lib/legend_web/controllers/mcp_controller.ex`
- Test: `backend/test/legend/core/mcp_test.exs`

- [ ] **Step 1: Write the failing test**

`backend/test/legend/core/mcp_test.exs`:
```elixir
defmodule Legend.Core.MCPTest do
  use Legend.DataCase, async: false
  alias Legend.Core.MCP

  test "id-less notifications are accepted" do
    assert MCP.handle(%{}, %{"method" => "notifications/initialized"}) == :accepted
  end

  test "initialize returns the server info" do
    assert {:ok, %{result: %{serverInfo: %{name: "legend"}}}} =
             MCP.handle(%{}, %{"method" => "initialize", "id" => 1, "params" => %{}})
  end

  test "tools/list exposes both signal and library tools" do
    {:ok, %{result: %{tools: tools}}} = MCP.handle(%{}, %{"method" => "tools/list", "id" => 2})
    names = Enum.map(tools, & &1["name"] || &1.name)
    assert "send_message" in names and "library_write" in names
  end

  test "an unknown method returns -32601" do
    assert {:ok, %{error: %{code: -32601}}} =
             MCP.handle(%{}, %{"method" => "nope", "id" => 3})
  end
end
```

- [ ] **Step 2: Run it — expect failure** (`Legend.Core.MCP` undefined)

Run: `cd backend && mix test test/legend/core/mcp_test.exs`
Expected: FAIL — `module Legend.Core.MCP is not available`.

- [ ] **Step 3: Create `Legend.Core.MCP`**

`backend/lib/legend/core/mcp.ex`:
```elixir
defmodule Legend.Core.MCP do
  @moduledoc """
  Transport-agnostic MCP JSON-RPC handling — the agent-facing twin of the
  JSON:API surface. Shared by `LegendWeb.MCPController` (main endpoint, local
  sessions) and `LegendWeb.TunnelPlug` (per-session tunnel listener, cloud
  sessions). The caller session is resolved by each web layer's auth; this
  module never authenticates.
  """

  alias Legend.Core.Library
  alias Legend.Core.Signals.Tools

  @tool_providers [Tools, Library.Tools]
  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)
  @default_protocol_version "2025-03-26"

  @doc "Tool definitions across all providers."
  def tools, do: Enum.flat_map(@tool_providers, & &1.list())

  @doc """
  Handle a decoded JSON-RPC request for `session`. Returns `:accepted` for an
  id-less notification (the web layer replies 202) or `{:ok, response_map}` for
  a request (the web layer replies 200 JSON).
  """
  @spec handle(map(), map()) :: :accepted | {:ok, map()}
  def handle(_session, %{"method" => _} = params) when not is_map_key(params, "id"),
    do: :accepted

  def handle(session, %{"method" => method, "id" => id} = params) do
    {:ok, rpc_response(id, dispatch(method, params["params"] || %{}, session))}
  end

  def handle(_session, _params) do
    {:ok, rpc_response(nil, {:error, %{code: -32600, message: "invalid request"}})}
  end

  defp dispatch("initialize", params, _session) do
    version =
      if params["protocolVersion"] in @protocol_versions,
        do: params["protocolVersion"],
        else: @default_protocol_version

    {:ok,
     %{
       protocolVersion: version,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "legend", version: to_string(Application.spec(:legend, :vsn))}
     }}
  end

  defp dispatch("ping", _params, _session), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _session), do: {:ok, %{tools: tools()}}

  defp dispatch("tools/call", %{"name" => name} = params, session) do
    args = params["arguments"] || %{}

    result =
      case provider_for(name) do
        Tools -> Tools.dispatch(session, name, args)
        Library.Tools -> Library.Tools.dispatch(name, args)
        nil -> {:error, "unknown tool: #{name}"}
      end

    case result do
      {:ok, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: false}}
      {:error, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: true}}
    end
  end

  defp dispatch(method, _params, _session) do
    {:error, %{code: -32601, message: "method not found: #{method}"}}
  end

  defp provider_for(name) do
    Enum.find(@tool_providers, fn mod -> Enum.any?(mod.list(), &(&1.name == name)) end)
  end

  defp rpc_response(id, {:ok, result}), do: %{jsonrpc: "2.0", id: id, result: result}
  defp rpc_response(id, {:error, error}), do: %{jsonrpc: "2.0", id: id, error: error}
end
```

- [ ] **Step 4: Run the new test — expect PASS**

Run: `cd backend && mix test test/legend/core/mcp_test.exs`
Expected: PASS (4 tests). (`tools/list` names are atom-keyed maps from the providers — the test handles both `&1["name"]` and `&1.name`.)

- [ ] **Step 5: Refactor `MCPController` to delegate**

Replace the body of `backend/lib/legend_web/controllers/mcp_controller.ex` with:
```elixir
defmodule LegendWeb.MCPController do
  @moduledoc """
  MCP over streamable HTTP for **local** sessions on the main endpoint. Auth is
  the per-session bearer token, which also identifies the caller. Cloud sessions
  reach MCP through `LegendWeb.TunnelPlug` instead; both share `Legend.Core.MCP`.
  """

  use LegendWeb, :controller

  alias Legend.Core.Agents
  alias Legend.Core.MCP

  plug :authenticate

  def handle(conn, params) do
    case MCP.handle(conn.assigns.mcp_session, params) do
      :accepted -> send_resp(conn, 202, "")
      {:ok, response} -> json(conn, response)
    end
  end

  defp authenticate(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         token when token != "" <- token,
         {:ok, session} <- Agents.get_session_by_token(token) do
      assign(conn, :mcp_session, session)
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid or missing token"})
        |> halt()
    end
  end
end
```

- [ ] **Step 6: Run the existing MCP/messaging tests — expect PASS (pure refactor)**

Run: `cd backend && mix test test/legend_web/controllers/mcp_library_test.exs test/legend/core/mcp_test.exs`
Expected: PASS. Then `cd backend && mix test` to confirm no broader regression.

- [ ] **Step 7: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/core/mcp.ex backend/lib/legend_web/controllers/mcp_controller.ex backend/test/legend/core/mcp_test.exs
git commit -m "refactor: lift MCP JSON-RPC dispatch into Legend.Core.MCP

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `LegendWeb.TunnelAuth` + `LegendWeb.TunnelPlug`

**Files:**
- Create: `backend/lib/legend_web/tunnel_auth.ex`
- Create: `backend/lib/legend_web/tunnel_plug.ex`
- Test: `backend/test/legend_web/tunnel_plug_test.exs`

- [ ] **Step 1: Write the failing test**

`backend/test/legend_web/tunnel_plug_test.exs`:
```elixir
defmodule LegendWeb.TunnelPlugTest do
  use Legend.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    {:ok, a} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    {:ok, b} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    %{a: Agents.get_session!(a.id), b: Agents.get_session!(b.id)}
  end

  defp call(conn, bound_session_id) do
    LegendWeb.TunnelPlug.call(conn, LegendWeb.TunnelPlug.init(bound_session_id: bound_session_id))
  end

  defp mcp_conn(token, body) do
    conn(:post, "/api/mcp", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> maybe_auth(token)
  end

  defp maybe_auth(conn, nil), do: conn
  defp maybe_auth(conn, token), do: put_req_header(conn, "authorization", "Bearer #{token}")

  test "the bound session's token reaches MCP", %{a: a} do
    conn = call(mcp_conn(a.mcp_token, %{jsonrpc: "2.0", id: 1, method: "tools/list"}), a.id)
    assert conn.status == 200
    assert %{"result" => %{"tools" => _}} = Jason.decode!(conn.resp_body)
  end

  test "a token for a different session is rejected with 403", %{a: a, b: b} do
    conn = call(mcp_conn(b.mcp_token, %{jsonrpc: "2.0", id: 1, method: "tools/list"}), a.id)
    assert conn.status == 403
  end

  test "a missing token is rejected with 401", %{a: a} do
    conn = call(mcp_conn(nil, %{jsonrpc: "2.0", id: 1, method: "tools/list"}), a.id)
    assert conn.status == 401
  end

  test "health needs no token", %{a: a} do
    conn = call(conn(:get, "/api/health"), a.id)
    assert conn.status == 200 and conn.resp_body == "ok"
  end

  test "non-MCP routes are not mounted (404)", %{a: a} do
    for path <- ["/api/sessions", "/api/settings/library-path", "/api/library/file"] do
      conn = call(conn(:get, path) |> put_req_header("authorization", "Bearer #{a.mcp_token}"), a.id)
      assert conn.status == 404, "#{path} should not be reachable through the tunnel"
    end
  end
end
```

- [ ] **Step 2: Run it — expect failure** (`LegendWeb.TunnelPlug` undefined)

Run: `cd backend && mix test test/legend_web/tunnel_plug_test.exs`
Expected: FAIL — module not available.

- [ ] **Step 3: Create `LegendWeb.TunnelAuth`**

`backend/lib/legend_web/tunnel_auth.ex`:
```elixir
defmodule LegendWeb.TunnelAuth do
  @moduledoc """
  Boundary auth for the per-session tunnel listener. Rejects any request without
  a valid bearer token (401), then enforces that the token resolves to the *one*
  session this tunnel was opened for (403) — so a leaked token is useless except
  through its own tunnel.
  """

  import Plug.Conn
  alias Legend.Core.Agents

  @spec authenticate(Plug.Conn.t(), String.t()) ::
          {:ok, Plug.Conn.t(), struct()} | {:error, Plug.Conn.t()}
  def authenticate(conn, bound_session_id) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         token when token != "" <- token,
         {:ok, session} <- Agents.get_session_by_token(token) do
      if session.id == bound_session_id do
        {:ok, conn, session}
      else
        {:error, deny(conn, 403, "token not valid for this tunnel")}
      end
    else
      _ -> {:error, deny(conn, 401, "invalid or missing token")}
    end
  end

  defp deny(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
```

- [ ] **Step 4: Create `LegendWeb.TunnelPlug`**

`backend/lib/legend_web/tunnel_plug.ex`:
```elixir
defmodule LegendWeb.TunnelPlug do
  @moduledoc """
  The entire HTTP surface a cloud sandbox can reach over its reverse tunnel:
  `POST /api/mcp` (authenticated + bound to one session) and an unauthenticated
  `GET /api/health` connectivity probe. Nothing else is mounted — the main
  Phoenix endpoint is unreachable through any tunnel. Bandit starts one of these
  per cloud session as `{LegendWeb.TunnelPlug, bound_session_id: id}`.
  """

  use Plug.Router

  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :match
  plug :dispatch

  # Inject the per-listener bound session id (from Bandit's plug opts) into assigns
  # before the route pipeline runs.
  def call(conn, opts) do
    super(assign(conn, :bound_session_id, Keyword.fetch!(opts, :bound_session_id)), opts)
  end

  get "/api/health" do
    send_resp(conn, 200, "ok")
  end

  post "/api/mcp" do
    case LegendWeb.TunnelAuth.authenticate(conn, conn.assigns.bound_session_id) do
      {:ok, conn, session} ->
        case Legend.Core.MCP.handle(session, conn.body_params) do
          :accepted ->
            send_resp(conn, 202, "")

          {:ok, response} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(response))
        end

      {:error, conn} ->
        conn
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
```

> Note: `super(conn, opts)` in `call/2` works because `Plug.Router`/`Plug.Builder` makes the generated `call/2` overridable. This is the documented idiom for passing per-instance config to a `Plug.Router`.

- [ ] **Step 5: Run the test — expect PASS**

Run: `cd backend && mix test test/legend_web/tunnel_plug_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend_web/tunnel_auth.ex backend/lib/legend_web/tunnel_plug.ex backend/test/legend_web/tunnel_plug_test.exs
git commit -m "feat: per-session tunnel listener plug (narrow + auth + bind)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `Server` owns the per-session listener

**Files:**
- Modify: `backend/lib/legend/tunnels/sprite_proxy/server.ex`
- Modify: `backend/lib/legend/tunnels/sprite_proxy.ex`
- Test: `backend/test/legend/tunnels/sprite_proxy/server_test.exs`

The `Server` allocates an ephemeral loopback port, starts a `LegendWeb.TunnelPlug` listener bound to the session, and dials *that* on OPEN frames. `target_port` stays a supported test override (existing `Server` tests pass a custom echo port and must keep working).

- [ ] **Step 1: Write the failing test** (append to `server_test.exs`)

```elixir
  test "with no target_port it allocates a session-bound listener serving health" do
    srv =
      start_supervised!(
        {Server, [session_id: "sess-1", sprite: "s", control_port: 9000,
                  connector: fn _s, _p, _srv -> {:ok, spawn(fn -> Process.sleep(:infinity) end)} end]}
      )

    port = :sys.get_state(srv).target_port
    assert is_integer(port) and port > 0

    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    :ok = :gen_tcp.send(sock, "GET /api/health HTTP/1.1\r\nHost: x\r\n\r\n")
    {:ok, resp} = :gen_tcp.recv(sock, 0, 1000)
    assert resp =~ "200" and resp =~ "ok"
    :gen_tcp.close(sock)
  end
```

- [ ] **Step 2: Run it — expect failure** (`Keyword.fetch!(:session_id)` / no listener)

Run: `cd backend && mix test test/legend/tunnels/sprite_proxy/server_test.exs`
Expected: FAIL — the new test errors (`session_id` not handled / `target_port` nil).

- [ ] **Step 3: Update `Server` to own the listener**

In `backend/lib/legend/tunnels/sprite_proxy/server.ex`:

Replace `init/1`:
```elixir
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {target_port, listener} = resolve_target(opts)

    state = %{
      target_port: target_port,
      listener: listener,
      sprite: Keyword.fetch!(opts, :sprite),
      control_port: Keyword.fetch!(opts, :control_port),
      connector: Keyword.get(opts, :connector, &default_connect/3),
      reconnect_base_ms: Keyword.get(opts, :reconnect_base_ms, 500),
      notify: Keyword.get(opts, :notify),
      ready_notified: false,
      out: nil,
      attempt: 0,
      buffer: "",
      streams: %{},
      ids: %{}
    }

    {:ok, state, {:continue, :connect}}
  end

  # Production: allocate an ephemeral loopback port and a TunnelPlug listener
  # bound to this session. Tests may pass :target_port to dial a fixture instead
  # (then no listener is started).
  defp resolve_target(opts) do
    case Keyword.get(opts, :target_port) do
      nil ->
        session_id = Keyword.fetch!(opts, :session_id)
        {:ok, listener, port} = start_listener(session_id)
        {port, listener}

      port ->
        {port, nil}
    end
  end

  defp start_listener(session_id) do
    {:ok, probe} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(probe)
    :gen_tcp.close(probe)

    {:ok, listener} =
      Bandit.start_link(
        plug: {LegendWeb.TunnelPlug, bound_session_id: session_id},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: port,
        thousand_island_options: [num_acceptors: 2]
      )

    {:ok, listener, port}
  end
```

Add the listener-EXIT clause **above** the carrier-EXIT clause:
```elixir
  # The listener (a linked process) died — unexpected for a loopback Bandit; fail
  # the tunnel visibly rather than serve a half-broken path. The SessionServer
  # surfaces it; resume reopens a fresh tunnel + listener.
  def handle_info({:EXIT, pid, reason}, %{listener: pid} = state) when is_pid(pid) do
    {:stop, {:listener_down, reason}, state}
  end
```

Replace the two `terminate/2` clauses with one that tears down both:
```elixir
  @impl true
  def terminate(_reason, state) do
    if is_pid(state[:listener]) and Process.alive?(state.listener),
      do: Process.exit(state.listener, :shutdown)

    carrier = state[:out]
    if is_pid(carrier) and Process.alive?(carrier),
      do: Process.exit(carrier, :shutdown)

    :ok
  end
```

- [ ] **Step 4: Update `SpriteProxy.open/1`** in `backend/lib/legend/tunnels/sprite_proxy.ex`:
```elixir
  @impl true
  def open(%{session_id: name}) do
    with {:ok, bin} <- read_bridge(),
         :ok <- ensure_bridge(name, bin),
         {:ok, srv} <-
           Server.start_link(
             sprite: name,
             session_id: name,
             control_port: @control_port,
             notify: self()
           ) do
      # The Server owns the carrier + the session-bound listener.
      {:ok, %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{server: srv}}}
    end
  end
```
(Remove the `target_port: endpoint_port()` line and the now-unused `endpoint_port/0` private function.)

- [ ] **Step 5: Run the Server tests — expect PASS** (existing tests use `target_port:` override and are unchanged)

Run: `cd backend && mix test test/legend/tunnels/sprite_proxy/server_test.exs test/legend/tunnels/sprite_proxy_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/tunnels/sprite_proxy/server.ex backend/lib/legend/tunnels/sprite_proxy.ex backend/test/legend/tunnels/sprite_proxy/server_test.exs
git commit -m "feat: tunnel Server owns a session-bound loopback listener

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Close the tunnel on runtime exit

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex`
- Test: `backend/test/legend/core/agents/session_tunnel_test.exs`

- [ ] **Step 1: Write the failing test** (append to `session_tunnel_test.exs`)

```elixir
  test "runtime exit closes the tunnel but keeps the session alive for scrollback" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    {:ok, s} = Agents.start_session(%{name: "exit", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    pid = Legend.Core.Agents.SessionServer.whereis(s.id)
    send(pid, {:runtime_exit, 0})

    assert_receive {:test_tunnel, :close, _}, 1000
    assert Agents.get_session!(s.id).status == :exited
    assert Process.alive?(pid)
  end
```

- [ ] **Step 2: Run it — expect failure** (no `{:test_tunnel, :close, _}` arrives)

Run: `cd backend && mix test test/legend/core/agents/session_tunnel_test.exs -n "runtime exit closes"`
Expected: FAIL — `assert_receive {:test_tunnel, :close, _}` times out.

- [ ] **Step 3: Close the tunnel in the `:runtime_exit` handler**

In `backend/lib/legend/core/agents/session_server.ex`, replace the live `:runtime_exit` clause:
```elixir
  def handle_info({:runtime_exit, code}, state) do
    session = Agents.finish_session!(state.session, %{exit_code: code})
    maybe_close_tunnel(state.tunnel)
    notify_spawner_of_exit(session, code)
    broadcast(session.id, {:session_exit, code})
    Notifications.sessions_changed()
    {:noreply, %{state | session: session, exited?: true, tunnel: nil}}
  end
```
(`tunnel: nil` makes `terminate/2`'s `maybe_close_tunnel` a no-op; closing twice is harmless anyway.)

- [ ] **Step 4: Run the tunnel tests — expect PASS**

Run: `cd backend && mix test test/legend/core/agents/session_tunnel_test.exs`
Expected: PASS (all, including the existing leak/resume tests).

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/core/agents/session_server.ex backend/test/legend/core/agents/session_tunnel_test.exs
git commit -m "fix: close the tunnel on runtime exit, not only on session delete

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Spawn policy (remote→host gate)

**Files:**
- Modify: `backend/lib/legend/core/signals/tools.ex`
- Test: `backend/test/legend/core/signals/spawn_policy_test.exs`

- [ ] **Step 1: Write the failing test**

`backend/test/legend/core/signals/spawn_policy_test.exs`:
```elixir
defmodule Legend.Core.Signals.SpawnPolicyTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals.Tools
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)
      Application.delete_env(:legend, :allow_remote_host_spawn)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  defp session(runtime_id),
    do: %Legend.Core.Agents.Session{id: Ecto.UUID.generate(), runtime_id: runtime_id, cwd: "/tmp"}

  test "a remote caller may not spawn a host runtime" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    assert {:error, msg} = Tools.authorize_spawn(session("test"), "local_pty")
    assert msg =~ "may not spawn host"
  end

  test "the override flag allows remote -> host" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    Application.put_env(:legend, :allow_remote_host_spawn, true)
    assert :ok = Tools.authorize_spawn(session("test"), "local_pty")
  end

  test "the same runtime is always allowed (inherit)" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    assert :ok = Tools.authorize_spawn(session("test"), "test")
  end

  test "a host caller may spawn a host runtime" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :path, tunnel: nil})
    assert :ok = Tools.authorize_spawn(session("test"), "local_pty")
  end

  test "a local caller may delegate upward to a remote runtime" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    assert :ok = Tools.authorize_spawn(session("local_pty"), "test")
  end

  test "an unknown target runtime is rejected" do
    assert {:error, msg} = Tools.authorize_spawn(session("test"), "nope")
    assert msg =~ "unknown runtime"
  end

  test "start_agent from a remote session denies a host runtime and creates no child" do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    {:ok, caller} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000
    before = length(Agents.list_sessions!())

    assert {:error, msg} =
             Tools.dispatch(Agents.get_session!(caller.id), "start_agent", %{
               "harness" => "claude_code",
               "instructions" => "do x",
               "runtime" => "local_pty"
             })

    assert msg =~ "may not spawn host"
    assert length(Agents.list_sessions!()) == before
  end

  test "start_agent inherits the caller's runtime by default" do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "test_tunnel"})
    {:ok, caller} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_tunnel, :open, _}, 1000

    {:ok, _text} =
      Tools.dispatch(Agents.get_session!(caller.id), "start_agent", %{
        "harness" => "claude_code",
        "instructions" => "child task"
      })

    child = Enum.find(Agents.list_sessions!(), &(&1.spawned_by_session_id == caller.id))
    assert child.runtime_id == "test"
  end
end
```

- [ ] **Step 2: Run it — expect failure** (`Tools.authorize_spawn/2` undefined)

Run: `cd backend && mix test test/legend/core/signals/spawn_policy_test.exs`
Expected: FAIL — function undefined.

- [ ] **Step 3: Add the policy + `runtime` arg to `Tools`**

In `backend/lib/legend/core/signals/tools.ex`:

Add `alias Legend.Core.Runtime` to the alias block.

Add `runtime` to the `start_agent` tool's `inputSchema.properties` (after `cwd`):
```elixir
            runtime: %{
              type: "string",
              description: "optional runtime id; defaults to inheriting yours"
            }
```

Update the `start_agent` dispatch clause to thread `runtime`:
```elixir
  def dispatch(
        session,
        "start_agent",
        %{"harness" => harness, "instructions" => instructions} = args
      )
      when is_binary(harness) and is_binary(instructions) do
    start_agent(session, harness, instructions, args["name"], args["cwd"], args["runtime"])
  end
```

Replace `start_agent/5` with `start_agent/6` (resolve target runtime, authorize, pass `runtime_id`):
```elixir
  defp start_agent(session, harness, instructions, name, cwd, runtime) do
    max = Application.get_env(:legend, :max_running_sessions, 10)
    target_runtime = runtime || session.runtime_id

    cond do
      Harness.Registry.fetch(harness) == :error ->
        {:error, "unknown harness: #{harness}. Known: #{known_harnesses()}"}

      running_count() >= max ->
        {:error, "session cap reached (#{max} running) — stop a session first"}

      true ->
        with :ok <- authorize_spawn(session, target_runtime) do
          start_child(session, harness, instructions, name, cwd, target_runtime)
        end
    end
  end

  defp start_child(session, harness, instructions, name, cwd, target_runtime) do
    case Agents.start_session(%{
           harness_id: harness,
           name: name,
           cwd: cwd || session.cwd,
           runtime_id: target_runtime,
           spawned_by_session_id: session.id,
           instructions: instructions
         }) do
      {:ok, %{status: :failed} = failed} ->
        {:error, "agent failed to start: #{failed.error}"}

      {:ok, new_session} ->
        audit(session.id, new_session.id, :system, "started with instructions:\n#{instructions}")

        {:ok,
         "Started session #{new_session.id} (#{harness}). It was told to report back " <>
           "to you; you will also get a system message when it exits."}

      {:error, error} ->
        {:error, "could not start agent: #{render_error(error)}"}
    end
  end

  @doc """
  Spawn-runtime policy. A remote caller (its runtime declares a tunnel) may not
  spawn a host runtime (`tunnel: nil, library: :path`, e.g. `local_pty`) unless
  `:allow_remote_host_spawn` is set. Same-runtime (inherit) and upward delegation
  (host → remote) are always allowed.
  """
  @spec authorize_spawn(struct(), String.t()) :: :ok | {:error, String.t()}
  def authorize_spawn(caller_session, target_runtime_id) do
    case Runtime.Registry.fetch(target_runtime_id) do
      :error ->
        {:error, "unknown runtime: #{target_runtime_id}"}

      {:ok, target_mod} ->
        cond do
          target_runtime_id == caller_session.runtime_id ->
            :ok

          host_runtime?(Runtime.capabilities(target_mod)) and
              remote_caller?(caller_session) and not allow_remote_host_spawn?() ->
            {:error,
             "remote sessions may not spawn host (#{target_runtime_id}) sessions; " <>
               "set :allow_remote_host_spawn to override"}

          true ->
            :ok
        end
    end
  end

  defp remote_caller?(%{runtime_id: rid}) do
    case Runtime.Registry.fetch(rid) do
      {:ok, mod} -> Runtime.capabilities(mod).tunnel != nil
      :error -> false
    end
  end

  defp host_runtime?(caps), do: caps.tunnel == nil and caps.library == :path
  defp allow_remote_host_spawn?, do: Application.get_env(:legend, :allow_remote_host_spawn, false)
```

Also update `handoff_spawn/3` (it calls `start_agent`) — change its call to pass `nil` runtime:
```elixir
  defp handoff_spawn(session, harness, summary) do
    instructions =
      "You are taking over work handed off by another agent. Handoff summary:\n\n" <> summary

    with {:ok, text} <- start_agent(session, harness, instructions, nil, nil, nil) do
      {:ok, "Handed off. " <> text}
    end
  end
```

- [ ] **Step 4: Run the spawn-policy + existing messaging tests — expect PASS**

Run: `cd backend && mix test test/legend/core/signals/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/core/signals/tools.ex backend/test/legend/core/signals/spawn_policy_test.exs
git commit -m "feat: deny remote->host start_agent unless allow_remote_host_spawn

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Phase 1 gate**

Run: `cd backend && mix precommit`
Expected: clean (compile --warnings-as-errors + format + full suite green).

---

# PHASE 2 — Robustness

## Task 6: Mux frame-size cap (Elixir)

**Files:**
- Modify: `backend/lib/legend/core/tunnel/mux.ex`
- Modify: `backend/lib/legend/tunnels/sprite_proxy/server.ex`
- Test: `backend/test/legend/core/tunnel/mux_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

`backend/test/legend/core/tunnel/mux_test.exs`:
```elixir
defmodule Legend.Core.Tunnel.MuxTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame

  test "round-trips a frame and reports leftover" do
    bin = Mux.encode(%Frame{type: :data, stream_id: 7, payload: "hi"})
    assert {:ok, [%Frame{type: :data, stream_id: 7, payload: "hi"}], "x"} = Mux.decode(bin <> "x")
  end

  test "an incomplete frame is left in the buffer" do
    <<head::binary-size(5), _::binary>> = Mux.encode(%Frame{type: :data, stream_id: 1, payload: "abc"})
    assert {:ok, [], ^head} = Mux.decode(head)
  end

  test "a frame whose declared length exceeds the cap is rejected" do
    oversized = <<2, 1::32, Mux.max_frame_payload() + 1::32>>
    assert {:error, :frame_too_large} = Mux.decode(oversized)
  end
end
```

- [ ] **Step 2: Run it — expect failure** (`decode/1` returns a 2-tuple; `max_frame_payload/0` undefined)

Run: `cd backend && mix test test/legend/core/tunnel/mux_test.exs`
Expected: FAIL.

- [ ] **Step 3: Add the cap + new `decode/1` contract** in `backend/lib/legend/core/tunnel/mux.ex`:
```elixir
  @max_frame_payload 1_048_576
  @doc "Maximum accepted frame payload (1 MiB). Keep in lockstep with bridge/src/mux.rs."
  def max_frame_payload, do: @max_frame_payload

  @doc "Consume as many whole frames as `buffer` holds. {:error, :frame_too_large} aborts."
  @spec decode(binary()) :: {:ok, [Frame.t()], binary()} | {:error, :frame_too_large}
  def decode(buffer), do: decode(buffer, [])

  defp decode(<<_tag, _id::32, len::32, _rest::binary>>, _acc) when len > @max_frame_payload do
    {:error, :frame_too_large}
  end

  defp decode(<<tag, id::32, len::32, payload::binary-size(len), rest::binary>>, acc) do
    decode(rest, [%Frame{type: Map.fetch!(@type_of, tag), stream_id: id, payload: payload} | acc])
  end

  defp decode(leftover, acc), do: {:ok, Enum.reverse(acc), leftover}
```

- [ ] **Step 4: Update the `Server` carrier-data handler** in `server.ex`:
```elixir
  def handle_info({:carrier_data, bin}, state) do
    case Mux.decode(state.buffer <> bin) do
      {:ok, frames, rest} ->
        {:noreply, Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)}

      {:error, :frame_too_large} ->
        Logger.warning("[SpriteProxy.Server] oversized mux frame — dropping carrier")
        drop_carrier(state)
    end
  end
```
Add the helper:
```elixir
  defp drop_carrier(%{out: carrier} = state) when is_pid(carrier) do
    if Process.alive?(carrier), do: Process.exit(carrier, :kill)
    {:noreply, state}
  end

  defp drop_carrier(state), do: {:noreply, state}
```
(Killing the carrier triggers the existing `{:EXIT, carrier}` reset+reconnect path.)

Also update the one existing destructure in `server_test.exs` line ~53 from `{[%Frame{...}], ""} = Mux.decode(bin)` to `{:ok, [%Frame{...}], ""} = Mux.decode(bin)`.

- [ ] **Step 5: Run mux + server + tunnel-wiring tests — expect PASS**

Run: `cd backend && mix test test/legend/core/tunnel/mux_test.exs test/legend/tunnels/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/core/tunnel/mux.ex backend/lib/legend/tunnels/sprite_proxy/server.ex backend/test/legend/core/tunnel/mux_test.exs backend/test/legend/tunnels/sprite_proxy/server_test.exs
git commit -m "feat: cap mux frame payload at 1 MiB; drop carrier on violation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Mux stream cap + idle sweep + active:once (Elixir)

**Files:**
- Modify: `backend/lib/legend/tunnels/sprite_proxy/server.ex`
- Test: `backend/test/legend/tunnels/sprite_proxy/server_test.exs`

- [ ] **Step 1: Write the failing tests** (append to `server_test.exs`)

```elixir
  test "OPEN beyond the stream cap is refused with a CLOSE" do
    # A real listener so stream 1's dial SUCCEEDS and occupies the only slot;
    # stream 2 then hits the cap and is refused with a CLOSE back out the carrier.
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    spawn_link(fn -> {:ok, _} = :gen_tcp.accept(lsock); Process.sleep(:infinity) end)

    srv =
      start_supervised!(
        {Server,
         [target_port: port, sprite: "s", control_port: 9000, max_streams: 1,
          connector: relay_connector(self())]}
      )

    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 2, payload: ""})})

    # stream 1 connected (no CLOSE); only stream 2's cap-refusal frame comes back.
    assert_receive {:carrier_out, bin}, 1000
    assert {:ok, [%Frame{type: :close, stream_id: 2}], ""} = Mux.decode(bin)
  end

  test "the idle sweep closes a stream with no activity" do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(lsock)
    spawn_link(fn -> {:ok, _} = :gen_tcp.accept(lsock); Process.sleep(:infinity) end)

    srv =
      start_supervised!(
        {Server,
         [target_port: port, sprite: "s", control_port: 9000, idle_ms: 0,
          connector: relay_connector(self())]}
      )

    send(srv, {:carrier_data, Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})})
    send(srv, :sweep)

    assert_receive {:carrier_out, bin}, 1000
    assert {:ok, [%Frame{type: :close, stream_id: 1}], ""} = Mux.decode(bin)
  end
```

- [ ] **Step 2: Run — expect failure** (no cap, no `:sweep` handler)

Run: `cd backend && mix test test/legend/tunnels/sprite_proxy/server_test.exs`
Expected: FAIL on the two new tests.

- [ ] **Step 3: Implement the caps + sweep** in `server.ex`

Add to `init/1`'s `state` map: `max_streams: Keyword.get(opts, :max_streams, 256)`, `idle_ms: Keyword.get(opts, :idle_ms, 120_000)`, `last_seen: %{}`. At the end of `init`, schedule the sweep: change the return to start a sweep timer first:
```elixir
    Process.send_after(self(), :sweep, 30_000)
    {:ok, state, {:continue, :connect}}
```

Replace `handle_frame(:open)` with a cap + monotonic-stamp version, and dial with `active: :once`:
```elixir
  defp handle_frame(%Frame{type: :open, stream_id: id}, state) do
    cond do
      Map.has_key?(state.streams, id) ->
        state

      map_size(state.streams) >= state.max_streams ->
        out(state, %Frame{type: :close, stream_id: id, payload: ""})
        Logger.warning("[SpriteProxy.Server] stream cap #{state.max_streams} reached — refusing #{id}")
        state

      true ->
        case :gen_tcp.connect(~c"127.0.0.1", state.target_port, [:binary, active: :once, packet: :raw]) do
          {:ok, sock} ->
            %{
              state
              | streams: Map.put(state.streams, id, sock),
                ids: Map.put(state.ids, sock, id),
                last_seen: Map.put(state.last_seen, id, now_ms())
            }

          {:error, reason} ->
            out(state, %Frame{type: :close, stream_id: id, payload: ""})
            Logger.warning("tunnel dial: #{inspect(reason)}")
            state
        end
    end
  end
```

In the `{:tcp, sock, data}` handler, refresh `last_seen` and re-arm `active: :once`:
```elixir
  def handle_info({:tcp, sock, data}, state) do
    case Map.get(state.ids, sock) do
      nil ->
        {:noreply, state}

      id ->
        out(state, %Frame{type: :data, stream_id: id, payload: data})
        :inet.setopts(sock, active: :once)
        {:noreply, %{state | last_seen: Map.put(state.last_seen, id, now_ms())}}
    end
  end
```

Refresh `last_seen` on inbound DATA too (in `handle_frame(:data)` return `%{state | last_seen: Map.put(state.last_seen, id, now_ms())}` when the stream exists).

Add the sweep handler + helpers:
```elixir
  def handle_info(:sweep, state) do
    cutoff = now_ms() - state.idle_ms

    stale = for {id, ts} <- state.last_seen, ts <= cutoff, do: id

    state =
      Enum.reduce(stale, state, fn id, acc ->
        out(acc, %Frame{type: :close, stream_id: id, payload: ""})
        drop(acc, id)
      end)

    Process.send_after(self(), :sweep, 30_000)
    {:noreply, state}
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
```

Update `drop/1` to also drop `last_seen`:
```elixir
  defp drop(state, id) do
    case Map.get(state.streams, id) do
      nil ->
        state

      sock ->
        :gen_tcp.close(sock)
        %{
          state
          | streams: Map.delete(state.streams, id),
            ids: Map.delete(state.ids, sock),
            last_seen: Map.delete(state.last_seen, id)
        }
    end
  end
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd backend && mix test test/legend/tunnels/sprite_proxy/server_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/tunnels/sprite_proxy/server.ex backend/test/legend/tunnels/sprite_proxy/server_test.exs
git commit -m "feat: cap concurrent tunnel streams, sweep idle, backpressure via active:once

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Rust bridge limits + `--version`

**Files:**
- Modify: `bridge/src/mux.rs`
- Modify: `bridge/src/main.rs`

- [ ] **Step 1: Write the failing Rust test** (append to `bridge/src/mux.rs`)

```rust
#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn rejects_oversized_frame_header() {
        // type=DATA, stream=1, length = MAX_FRAME_PAYLOAD + 1
        let mut bytes = vec![DATA];
        bytes.extend_from_slice(&1u32.to_be_bytes());
        bytes.extend_from_slice(&((MAX_FRAME_PAYLOAD + 1) as u32).to_be_bytes());
        let mut cursor = std::io::Cursor::new(bytes);
        assert!(read_frame(&mut cursor).await.is_err());
    }
}
```

- [ ] **Step 2: Run — expect failure** (`MAX_FRAME_PAYLOAD` undefined / no cap)

Run: `cd bridge && cargo test`
Expected: FAIL to compile (unknown `MAX_FRAME_PAYLOAD`).

- [ ] **Step 3: Add the frame cap** in `bridge/src/mux.rs`

Add near the other constants:
```rust
/// Maximum accepted frame payload (1 MiB). Keep in lockstep with mux.ex.
pub const MAX_FRAME_PAYLOAD: usize = 1_048_576;
```
In `read_frame`, after computing `length`, before allocating:
```rust
    if length > MAX_FRAME_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame payload exceeds MAX_FRAME_PAYLOAD",
        ));
    }
```

- [ ] **Step 4: Add the stream cap + per-stream read timeout + `--version`** in `bridge/src/main.rs`

Add a constant:
```rust
/// Maximum concurrent streams per carrier session.
const MAX_STREAMS: usize = 256;
/// Per-stream idle/read timeout.
const STREAM_IDLE: std::time::Duration = std::time::Duration::from_secs(120);
```
At the top of `main` (before binding listeners), handle `--version`:
```rust
    if std::env::args().any(|a| a == "--version") {
        println!("{}", env!("CARGO_PKG_VERSION"));
        return;
    }
```
In the carrier session's stream-registry insert path, refuse new streams beyond the cap (where the streams `HashMap` is populated on OPEN) — reply with a CLOSE frame and skip registering when `streams.len() >= MAX_STREAMS`. Wrap the per-stream socket read in `tokio::time::timeout(STREAM_IDLE, …)`; on elapse, close the stream and emit a CLOSE frame.

> The exact insertion points depend on the current `run_carrier_session` shape; the implementer reads `main.rs` and applies the cap at the OPEN handler and the timeout at the agent→carrier read loop. Keep the wire behaviour identical to the Elixir side (CLOSE on refusal/timeout).

- [ ] **Step 5: Run — expect PASS**

Run: `cd bridge && cargo test`
Expected: PASS. Then `cd bridge && cargo build --release` (sanity; the cross-compiled artifact for live use comes from `just build-bridge`, optional).

- [ ] **Step 6: Commit**

```bash
cd /Users/daniel/Development/legend
git add bridge/src/mux.rs bridge/src/main.rs
git commit -m "feat(bridge): cap frame size and stream count, add read timeout and --version

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Carrier readiness gate

**Files:**
- Modify: `backend/lib/legend/sprites/proxy.ex`
- Modify: `backend/lib/legend/tunnels/sprite_proxy/server.ex`
- Modify: `backend/lib/legend/tunnels/sprite_proxy.ex`
- Test: `backend/test/legend/tunnels/sprite_proxy/server_test.exs`

- [ ] **Step 1: Write the failing test** (append to `server_test.exs`)

```elixir
  test "the server notifies :tunnel_ready once the carrier acks" do
    test = self()

    connector = fn _s, _p, srv ->
      send(srv, :carrier_ready)
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end

    srv =
      start_supervised!(
        {Server,
         [target_port: 0, sprite: "s", control_port: 9000, connector: connector, notify: test]}
      )

    assert_receive {:tunnel_ready, ^srv}, 1000
  end
```

- [ ] **Step 2: Run — expect failure** (no `:carrier_ready`/`:tunnel_ready` plumbing)

Run: `cd backend && mix test test/legend/tunnels/sprite_proxy/server_test.exs -n "tunnel_ready"`
Expected: FAIL — message never arrives.

- [ ] **Step 3: Signal readiness from the `Proxy`** in `backend/lib/legend/sprites/proxy.ex`

In `dispatch_frame({:text, json}, state)`, the `{"status" => "connected"}` branch becomes:
```elixir
      {:ok, %{"status" => "connected"}} ->
        Logger.info("[Sprites.Proxy] carrier connected for sprite #{state.name}")
        send(state.server, :carrier_ready)
        %{state | connected: true}
```

- [ ] **Step 4: Forward readiness from the `Server`** in `server.ex`

Add a handler (place near the other `handle_info`s):
```elixir
  def handle_info(:carrier_ready, %{ready_notified: false, notify: notify} = state) when is_pid(notify) do
    send(notify, {:tunnel_ready, self()})
    {:noreply, %{state | ready_notified: true}}
  end

  def handle_info(:carrier_ready, state), do: {:noreply, state}
```

- [ ] **Step 5: Block `open/1` on readiness** in `backend/lib/legend/tunnels/sprite_proxy.ex`

Add `@ready_timeout_ms 15_000` near the other module attrs, and have `open/1` wait after the Server starts:
```elixir
  @impl true
  def open(%{session_id: name}) do
    with {:ok, bin} <- read_bridge(),
         :ok <- ensure_bridge(name, bin),
         {:ok, srv} <-
           Server.start_link(sprite: name, session_id: name, control_port: @control_port, notify: self()),
         :ok <- await_ready(srv) do
      {:ok, %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{server: srv}}}
    end
  end

  defp await_ready(srv) do
    receive do
      {:tunnel_ready, ^srv} -> :ok
    after
      @ready_timeout_ms ->
        stop(srv)
        {:error, "tunnel carrier readiness timed out after #{@ready_timeout_ms}ms"}
    end
  end
```

- [ ] **Step 6: Run — expect PASS**

Run: `cd backend && mix test test/legend/tunnels/`
Expected: PASS (the Server-level readiness test; `open/1`'s receive is exercised live, like the rest of the `Proxy` WSS path).

- [ ] **Step 7: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/sprites/proxy.ex backend/lib/legend/tunnels/sprite_proxy/server.ex backend/lib/legend/tunnels/sprite_proxy.ex backend/test/legend/tunnels/sprite_proxy/server_test.exs
git commit -m "feat: gate tunnel open on carrier readiness ack

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Bridge versioning (content-addressed)

**Files:**
- Modify: `backend/lib/legend/tunnels/sprite_proxy.ex`

This path runs over the live WSS exec, so it has no offline unit test (like `ensure_bridge` today). The change is small and verified by the live capstone; reason carefully and keep it mechanical.

- [ ] **Step 1: Replace `ensure_bridge/2` + `launch_bridge/1`** in `sprite_proxy.ex`

Remove `@bridge_dest "/tmp/legend-bridge"`. Replace the two functions:
```elixir
  # Content-address the bridge so a stale binary from a prior Legend version is
  # detected and replaced. The launch path embeds the hash, so `pgrep -f <dest>`
  # tells us whether OUR exact version is already running (resume fast-path); any
  # other bridge is killed (they share the fixed 9000/7777).
  defp ensure_bridge(name, bin) do
    sha = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    dest = "/tmp/legend-bridge-#{sha}"

    case Exec.run(name, sh("pgrep -f '#{dest}' >/dev/null 2>&1")) do
      {:ok, %{status: 0}} -> :ok
      _ -> deliver_and_launch(name, dest, bin)
    end
  end

  defp deliver_and_launch(name, dest, bin) do
    with {:ok, _} <- Client.write_file(name, dest, bin),
         {:ok, %{status: 0}} <- Exec.run(name, sh(launch_cmd(dest))) do
      :ok
    else
      {:ok, %{status: s, stdout: out}} -> {:error, "bridge launch failed (#{s}): #{out}"}
      {:error, reason} -> {:error, "bridge delivery failed: #{reason}"}
    end
  end

  defp launch_cmd(dest) do
    "pkill -f '/tmp/legend-bridge-' >/dev/null 2>&1 || true ; " <>
      "setsid #{dest} >/tmp/bridge.log 2>&1 & ; sleep 0.3"
  end

  defp sh(cmd), do: %CommandSpec{cmd: "sh", args: ["-c", cmd], io: :pipes}
```
(`CommandSpec` is already aliased; keep the alias.)

- [ ] **Step 2: Compile + run the tunnel tests** (no behaviour change to the unit-tested paths)

Run: `cd backend && mix compile --warnings-as-errors && mix test test/legend/tunnels/`
Expected: clean + PASS.

- [ ] **Step 3: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend/tunnels/sprite_proxy.ex
git commit -m "feat: content-address the bridge; kill stale, skip when our version runs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Phase 2 gate**

Run: `cd backend && mix precommit && cd ../bridge && cargo test`
Expected: clean + PASS.

---

# PHASE 3 — UI compatibility

## Task 11: Backend `provisionable` field

**Files:**
- Modify: `backend/lib/legend_web/controllers/harness_controller.ex`
- Test: `backend/test/legend_web/controllers/harness_controller_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

`backend/test/legend_web/controllers/harness_controller_test.exs`:
```elixir
defmodule LegendWeb.HarnessControllerTest do
  use LegendWeb.ConnCase, async: true

  test "GET /api/harnesses reports provisionable per harness", %{conn: conn} do
    data = conn |> get("/api/harnesses") |> json_response(200) |> Map.fetch!("data")
    by_id = Map.new(data, &{&1["id"], &1})

    assert Map.has_key?(by_id, "claude_code")
    assert by_id["claude_code"]["provisionable"] == true
    # Every harness carries the boolean.
    assert Enum.all?(data, &is_boolean(&1["provisionable"]))
  end
end
```

- [ ] **Step 2: Run — expect failure** (no `provisionable` key)

Run: `cd backend && mix test test/legend_web/controllers/harness_controller_test.exs`
Expected: FAIL.

- [ ] **Step 3: Add the field** in `harness_controller.ex` `index/2`:
```elixir
        %{
          id: d.id,
          name: d.name,
          description: d.description,
          kind: d.kind,
          resumable: d.resumable,
          provisionable: Harness.provision_for(mod) != nil,
          setup: Harness.setup_for(mod)
        }
```

- [ ] **Step 4: Run — expect PASS**

Run: `cd backend && mix test test/legend_web/controllers/harness_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/daniel/Development/legend
git add backend/lib/legend_web/controllers/harness_controller.ex backend/test/legend_web/controllers/harness_controller_test.exs
git commit -m "feat: expose harness provisionable in GET /api/harnesses

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Frontend compatibility guard

**Files:**
- Modify: `frontend/src/lib/sessions.ts`
- Modify: `frontend/src/lib/components/NewSessionDialog.svelte`

- [ ] **Step 1: Add `provisionable` to the `Harness` interface** in `sessions.ts`:
```ts
export interface Harness {
	id: string;
	name: string;
	description: string;
	kind: 'terminal' | 'acp' | 'native';
	resumable: boolean;
	provisionable: boolean;
	setup: HarnessSetup;
}
```

- [ ] **Step 2: Add the compatibility derived state + guard** in `NewSessionDialog.svelte`

After the existing `selectedRuntime` derived (line ~30):
```svelte
	const incompatible = $derived(
		!!selectedRuntime?.capabilities?.provisions &&
			!!selectedHarness &&
			!selectedHarness.provisionable
	);
```

Add a message block (next to the existing `{#if error}` block, inside the form):
```svelte
				{#if incompatible && selectedHarness && selectedRuntime}
					<p class="text-sm text-destructive">
						{selectedHarness.name} can't be auto-installed on {runtimeLabel(selectedRuntime.id)} —
						pick a different harness or runtime.
					</p>
				{/if}
```

Disable Start when incompatible:
```svelte
			<Button onclick={create} disabled={creating || !harnessId || incompatible}>
				{creating ? 'Starting…' : 'Start session'}
			</Button>
```

- [ ] **Step 3: Run the frontend check — expect clean**

Run: `cd frontend && bun run check`
Expected: 0 errors (svelte-check + tsc).

- [ ] **Step 4: Commit**

```bash
cd /Users/daniel/Development/legend
git add frontend/src/lib/sessions.ts frontend/src/lib/components/NewSessionDialog.svelte
git commit -m "feat: disable incompatible harness/runtime combos in the new-session dialog

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Documentation + final verification

**Files:**
- Modify: `docs/ARCHITECTURE.md`

- [ ] **Step 1: Update `docs/ARCHITECTURE.md`**

In the cloud-runtime / tunnel section, record:
- The tunnel boundary: a **per-session** loopback `Bandit` listener (ephemeral port, `LegendWeb.TunnelPlug`) serves only `POST /api/mcp` (auth + session binding via `LegendWeb.TunnelAuth`) and `GET /api/health`; the main Phoenix endpoint is unreachable through any tunnel. MCP dispatch is shared via `Legend.Core.MCP`.
- The tunnel closes on `:runtime_exit` (not only on delete).
- Spawn policy: children inherit the caller's runtime; remote→host spawns are denied unless `config :legend, :allow_remote_host_spawn` (default false).
- Mux limits: 1 MiB frame cap, 256 streams, 120 s idle, `active: :once` backpressure (lockstep in `mux.ex` + `bridge/src/mux.rs`).
- `open/1` blocks on the carrier `{"status":"connected"}` ack (`@ready_timeout_ms`).
- Bridge is content-addressed at `/tmp/legend-bridge-<sha8>`; stale bridges are killed.

Update the spec index with the hardening spec + plan paths.

- [ ] **Step 2: Full verification**

Run:
```bash
cd backend && mix precommit
cd ../frontend && bun run check
cd ../bridge && cargo test
```
Expected: all clean/green.

- [ ] **Step 3: Commit**

```bash
cd /Users/daniel/Development/legend
git add docs/ARCHITECTURE.md
git commit -m "docs: record cloud-tunnel hardening in ARCHITECTURE

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: Final review + finish**

Dispatch a final whole-branch review (subagent-driven-development's final reviewer), address any findings, then use **superpowers:finishing-a-development-branch** (the user merges locally; do not push).

---

## Notes for the executor

- **Lockstep:** the 1 MiB frame cap MUST match in `mux.ex` (`@max_frame_payload`) and `mux.rs` (`MAX_FRAME_PAYLOAD`).
- **Test isolation:** spawn/tunnel tests start real `SessionServer`s on the in-memory `Test` runtime; every setup must terminate `SessionSupervisor` children on exit (the established pattern).
- **No `cd backend &&` before `git add backend/...`** — run git from the repo root.
- **`window.confirm`/`alert` are no-ops in Tauri** — the UI guard is a disabled button + inline message, never a dialog prompt.
- **Live capstone (optional):** `just build-bridge`, then a real sprites session reaching MCP through the narrowed listener and being denied a `local_pty` spawn — mirrors the 2a/2b acceptance.
