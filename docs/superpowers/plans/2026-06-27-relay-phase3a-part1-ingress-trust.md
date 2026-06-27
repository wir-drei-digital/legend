# Relay Phase 3a — Part 1: Remote Ingress + `via_relay` Trust Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the instance-side, trust-preserving relay ingress — a dedicated Phoenix endpoint whose connections are stamped `via_relay` so that **no** relayed request (HTTP or socket) ever inherits loopback trust — without any relay/networking yet. This is Part 1 of Phase 3a; Part 2 adds the relay app + the federation carrier that splices into this ingress.

**Architecture:** A shared `LegendWeb.ViaRelay` marker is threaded into the three trust choke points (`DeviceAuth`, `LoopbackOnly`, `UserSocket`) so `via_relay ⇒ non-loopback` — defaulting **off** (zero behavior change for the existing endpoint). A new `LegendWeb.RelayIngressEndpoint` (its own Bandit listener, private port) mounts **static + router + socket**, stamps `via_relay` on every connection, drops `/api/mcp`, and sets `check_origin` for the relay host. It boots only behind a flag (default off).

**Tech Stack:** Elixir / Phoenix 1.8 (Bandit) / Plug. No new dependencies.

## Global Constraints

- All `mix` from `backend/`. `mix precommit` (compile `--warnings-as-errors` + format + test) MUST pass before a task is done. DB-touching ExUnit modules are `async: false` (SQLite write-lock).
- The trust rule is unchanged for the existing endpoint: loopback OR valid device token. This plan ONLY adds: when a connection is marked `via_relay`, it is treated as **non-loopback** — a device token is required (HTTP + socket) and loopback-only management 403s.
- `via_relay` defaults to **absent/false**. The main `LegendWeb.Endpoint` must behave exactly as today (no `via_relay` stamping). Existing tests must stay green.
- The loopback predicate is `LegendWeb.RemotePeer.loopback?/1` (`{127,_,_,_}` and `::1`); do not change it.
- `via_relay` carriers (per the spec): HTTP via a `Plug.Conn` assign set by a head-of-pipeline plug on the ingress endpoint; socket via Phoenix `connect_info` (arbitrary trailing keywords ARE supported by Phoenix connect_info — `[:peer_data, via_relay: true]` puts `via_relay: true` in the `connect_info` map).
- The relay ingress excludes `/api/mcp` (agent surface; a public relay must not expose it) and serves the same router otherwise. Public routes that stay reachable on the ingress: `POST /api/pair`, `GET /api/health`.
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File structure

- Create `backend/lib/legend_web/via_relay.ex` — the marker (`conn?/1`, `info?/1`, `stamp/1`).
- Modify `backend/lib/legend_web/device_auth.ex`, `backend/lib/legend_web/loopback_only.ex`, `backend/lib/legend_web/channels/user_socket.ex` — honor the marker.
- Create `backend/lib/legend_web/relay_ingress_endpoint.ex` — the dedicated endpoint.
- Modify `backend/config/config.exs` + `backend/config/runtime.exs` — config for the new endpoint.
- Modify `backend/lib/legend/application.ex` — supervise the ingress endpoint behind a flag (default off).
- Tests: `backend/test/legend_web/via_relay_test.exs`, additions to `device_auth_test.exs` / the loopback + socket tests, and `backend/test/legend_web/relay_ingress_endpoint_test.exs`.

---

### Task 1: `ViaRelay` marker honored by all three choke points

**Files:**
- Create: `backend/lib/legend_web/via_relay.ex`
- Modify: `backend/lib/legend_web/device_auth.ex`, `backend/lib/legend_web/loopback_only.ex`, `backend/lib/legend_web/channels/user_socket.ex`
- Test: `backend/test/legend_web/via_relay_test.exs`; extend `backend/test/legend_web/device_auth_test.exs` and the existing loopback/user-socket tests.

**Interfaces:**
- Produces: `LegendWeb.ViaRelay.conn?(%Plug.Conn{}) :: boolean`, `LegendWeb.ViaRelay.info?(map) :: boolean`, `LegendWeb.ViaRelay.stamp(%Plug.Conn{}) :: %Plug.Conn{}`. Consumed by `DeviceAuth`, `LoopbackOnly`, `UserSocket` (this task) and `RelayIngressEndpoint` (Task 2).
- Contract: a `via_relay`-marked conn/connect_info is treated as **non-loopback** at every choke point.

- [ ] **Step 1: Write the failing test for the marker**

Create `backend/test/legend_web/via_relay_test.exs`:

```elixir
defmodule LegendWeb.ViaRelayTest do
  use ExUnit.Case, async: true
  alias LegendWeb.ViaRelay

  test "stamp marks a conn; conn? reads it" do
    conn = %Plug.Conn{} |> ViaRelay.stamp()
    assert ViaRelay.conn?(conn)
    refute ViaRelay.conn?(%Plug.Conn{})
  end

  test "info? reads the connect_info map" do
    assert ViaRelay.info?(%{via_relay: true})
    refute ViaRelay.info?(%{peer_data: %{address: {127, 0, 0, 1}}})
    refute ViaRelay.info?(%{})
  end
end
```

- [ ] **Step 2: Run it — expect FAIL** (`LegendWeb.ViaRelay` undefined). `cd backend && mix test test/legend_web/via_relay_test.exs`

- [ ] **Step 3: Create the marker**

Create `backend/lib/legend_web/via_relay.ex`:

```elixir
defmodule LegendWeb.ViaRelay do
  @moduledoc """
  Marks a connection as arriving through the relay ingress. A `via_relay`
  connection is ALWAYS treated as non-loopback by the trust choke points
  (`DeviceAuth`, `LoopbackOnly`, `UserSocket`) — even though the relay splice
  dials `127.0.0.1`, so a device token is required and loopback-only management
  is rejected. The main endpoint never stamps this, so its behavior is unchanged.
  """
  @key :via_relay

  @doc "True when an HTTP conn was stamped by the relay ingress."
  def conn?(%Plug.Conn{assigns: assigns}), do: Map.get(assigns, @key) == true

  @doc "True when socket `connect_info` carries the relay marker."
  def info?(%{via_relay: true}), do: true
  def info?(_), do: false

  @doc "Stamp an HTTP conn as via-relay (used by the ingress endpoint head plug)."
  def stamp(%Plug.Conn{} = conn), do: Plug.Conn.assign(conn, @key, true)
end
```

- [ ] **Step 4: Run it — expect PASS.** `mix test test/legend_web/via_relay_test.exs`

- [ ] **Step 5: Write the failing choke-point tests**

Add to `backend/test/legend_web/device_auth_test.exs` (keep the module's existing `async` setting):

```elixir
  test "a via_relay conn on loopback is NOT trusted (token required)" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> LegendWeb.ViaRelay.stamp()
      |> LegendWeb.DeviceAuth.call([])

    # no token + via_relay => denied even though remote_ip is loopback
    assert conn.status == 401
    assert conn.halted
  end
```

Add to the `LoopbackOnly` test file (e.g. `backend/test/legend_web/loopback_only_test.exs`; create it if absent, `async: true`):

```elixir
defmodule LegendWeb.LoopbackOnlyTest do
  use LegendWeb.ConnCase, async: true

  test "loopback passes" do
    conn = build_conn() |> Map.put(:remote_ip, {127, 0, 0, 1}) |> LegendWeb.LoopbackOnly.call([])
    refute conn.halted
  end

  test "via_relay on loopback is rejected (403)" do
    conn =
      build_conn()
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> LegendWeb.ViaRelay.stamp()
      |> LegendWeb.LoopbackOnly.call([])

    assert conn.status == 403
    assert conn.halted
  end
end
```

Add to the user-socket test (e.g. `backend/test/legend_web/channels/user_socket_test.exs`; create if absent, `async: false` — it touches devices):

```elixir
defmodule LegendWeb.UserSocketTest do
  use LegendWeb.ChannelCase, async: false

  test "loopback connects with no token" do
    assert {:ok, socket} =
             LegendWeb.UserSocket.connect(%{}, socket(LegendWeb.UserSocket), %{
               peer_data: %{address: {127, 0, 0, 1}}
             })

    assert socket.assigns.device_id == nil
  end

  test "via_relay connect on loopback without a token is rejected" do
    assert :error =
             LegendWeb.UserSocket.connect(%{}, socket(LegendWeb.UserSocket), %{
               peer_data: %{address: {127, 0, 0, 1}},
               via_relay: true
             })
  end
end
```

- [ ] **Step 6: Run them — expect FAIL** (the choke points don't honor `via_relay` yet). `cd backend && mix test test/legend_web/device_auth_test.exs test/legend_web/loopback_only_test.exs test/legend_web/channels/user_socket_test.exs`

- [ ] **Step 7: Honor `via_relay` in `DeviceAuth`**

In `backend/lib/legend_web/device_auth.ex`, change the loopback branch condition (currently `RemotePeer.loopback?(conn.remote_ip) ->`) to also require NOT via_relay:

```elixir
  def call(conn, _opts) do
    cond do
      not LegendWeb.ViaRelay.conn?(conn) and RemotePeer.loopback?(conn.remote_ip) ->
        assign(conn, :device, :local)

      true ->
        case token(conn) do
          {:ok, t} ->
            case DeviceToken.verify(t) do
              {:ok, device} -> assign(conn, :device, device)
              {:error, _} -> deny(conn)
            end

          :error ->
            deny(conn)
        end
    end
  end
```

- [ ] **Step 8: Honor `via_relay` in `LoopbackOnly`**

In `backend/lib/legend_web/loopback_only.ex`:

```elixir
  def call(conn, _opts) do
    if not LegendWeb.ViaRelay.conn?(conn) and RemotePeer.loopback?(conn.remote_ip) do
      conn
    else
      conn
      |> put_status(403)
      |> Phoenix.Controller.json(%{error: "loopback only"})
      |> halt()
    end
  end
```

- [ ] **Step 9: Honor `via_relay` in `UserSocket`**

In `backend/lib/legend_web/channels/user_socket.ex`, change the `connect/3` loopback condition:

```elixir
  def connect(params, socket, connect_info) do
    if not LegendWeb.ViaRelay.info?(connect_info) and loopback?(connect_info) do
      {:ok, assign(socket, :device_id, nil)}
    else
      with token when is_binary(token) <- params["token"],
           {:ok, device} <- DeviceToken.verify(token) do
        _ = Devices.touch_device!(device)
        {:ok, assign(socket, :device_id, device.id)}
      else
        _ -> :error
      end
    end
  end
```

(Leave the existing `loopback?/1` private helpers unchanged.)

- [ ] **Step 10: Run the choke-point tests — expect PASS** (and the existing device_auth / socket tests still pass). `cd backend && mix test test/legend_web/device_auth_test.exs test/legend_web/loopback_only_test.exs test/legend_web/channels/user_socket_test.exs test/legend_web/via_relay_test.exs`

- [ ] **Step 11: `mix precommit`** — full suite green.

- [ ] **Step 12: Commit**

```bash
git add backend/lib/legend_web/via_relay.ex backend/lib/legend_web/device_auth.ex backend/lib/legend_web/loopback_only.ex backend/lib/legend_web/channels/user_socket.ex backend/test/legend_web/via_relay_test.exs backend/test/legend_web/device_auth_test.exs backend/test/legend_web/loopback_only_test.exs backend/test/legend_web/channels/user_socket_test.exs
git commit -m "feat(relay): via_relay marker => non-loopback at all three choke points

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `RelayIngressEndpoint` (static + router + socket; stamps via_relay; no /api/mcp)

**Files:**
- Create: `backend/lib/legend_web/relay_ingress_endpoint.ex`
- Modify: `backend/config/config.exs` (config for the new endpoint), `backend/config/runtime.exs` (secret_key_base + check_origin for the relay host at runtime)
- Test: `backend/test/legend_web/relay_ingress_endpoint_test.exs`

**Interfaces:**
- Consumes: `LegendWeb.ViaRelay.stamp/1` (Task 1), `LegendWeb.Router`, `LegendWeb.UserSocket`, `LegendWeb.static_paths/0`.
- Produces: `LegendWeb.RelayIngressEndpoint` — a `Phoenix.Endpoint`. Part 2's federation carrier splices relay streams to its `http` port. Every request/socket is `via_relay`; `/api/mcp` → 404.

- [ ] **Step 1: Add endpoint config**

In `backend/config/config.exs`, after the `LegendWeb.Endpoint` config, add a minimal config for the ingress endpoint (it shares the same `:legend` otp_app; `server: false` so it only starts when supervised explicitly):

```elixir
config :legend, LegendWeb.RelayIngressEndpoint,
  url: [host: "localhost"],
  render_errors: [
    formats: [json: LegendWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Legend.PubSub,
  server: false
```

(Match the `render_errors`/`pubsub_server` values used by `LegendWeb.Endpoint` in this file — read that block and mirror it.)

In `backend/config/runtime.exs`, in the `config_env() == :prod` block (and dev as needed for local testing), give the ingress its `secret_key_base` (reuse the same one) and a default `check_origin` (Part 2 extends it with the relay host):

```elixir
  config :legend, LegendWeb.RelayIngressEndpoint,
    secret_key_base: env!("SECRET_KEY_BASE", :string),
    check_origin: false
```

(`check_origin: false` is a placeholder for Part 1's isolated tests; Part 2 sets it to `["//<handle>.<relay-host>"]` when relay mode is configured. Note this in a code comment.)

- [ ] **Step 2: Write the failing endpoint test**

Create `backend/test/legend_web/relay_ingress_endpoint_test.exs`. Use `Phoenix.ConnTest` dispatching **through the ingress endpoint** (`@endpoint LegendWeb.RelayIngressEndpoint`) — this exercises the full endpoint pipeline (static + `relay_guards` + router) with no real listener or HTTP client. `Phoenix.ConnTest`'s `build_conn/0` has `remote_ip` `{127,0,0,1}` (loopback) by default, which is exactly the crux: `via_relay` must override loopback. The endpoint is `server: false`, so `start_supervised!` boots its config/pubsub without opening a port.

```elixir
defmodule LegendWeb.RelayIngressEndpointTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest

  @endpoint LegendWeb.RelayIngressEndpoint

  setup do
    start_supervised!(LegendWeb.RelayIngressEndpoint)
    :ok
  end

  test "a device-gated/management route without a token is rejected (via_relay, despite loopback conn)" do
    # build_conn() has remote_ip 127.0.0.1; the ingress stamps via_relay, so
    # /api/devices (loopback-only management) is 403 rather than served.
    conn = get(build_conn(), "/api/devices")
    assert conn.status in [401, 403]
  end

  test "/api/mcp is not routed on the relay ingress (404)" do
    conn = post(build_conn(), "/api/mcp", %{})
    assert conn.status == 404
  end

  test "/api/health is reachable through the ingress (200)" do
    conn = get(build_conn(), "/api/health")
    assert conn.status == 200
  end
end
```

Add to `backend/config/test.exs` (config-only; `server: false` ⇒ no listener, ConnTest dispatches in-process):

```elixir
config :legend, LegendWeb.RelayIngressEndpoint,
  secret_key_base: String.duplicate("a", 64),
  check_origin: false,
  server: false
```

- [ ] **Step 3: Run it — expect FAIL** (`LegendWeb.RelayIngressEndpoint` undefined). `cd backend && mix test test/legend_web/relay_ingress_endpoint_test.exs`

- [ ] **Step 4: Create the ingress endpoint**

Create `backend/lib/legend_web/relay_ingress_endpoint.ex`. It mirrors `LegendWeb.Endpoint`'s socket/static/plug stack (read `endpoint.ex` and match it), with two additions: the socket carries `via_relay: true` in `connect_info`, and a `:relay_guards` plug runs just before the router to drop `/api/mcp` and stamp `via_relay`:

```elixir
defmodule LegendWeb.RelayIngressEndpoint do
  @moduledoc """
  A dedicated Phoenix endpoint for relay-routed traffic. The Part-2 federation
  carrier splices each relay stream to this endpoint's loopback port. Because the
  splice dials 127.0.0.1, this endpoint STAMPS every connection `via_relay` so the
  trust choke points never grant loopback trust — a device token is required and
  loopback-only management 403s. `/api/mcp` is not exposed (agent-only surface).
  Mounts static + router + socket (all of which live at the endpoint layer).
  """
  use Phoenix.Endpoint, otp_app: :legend

  socket "/socket", LegendWeb.UserSocket,
    websocket: [connect_info: [:peer_data, via_relay: true]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :legend,
    gzip: not code_reloading?,
    only: LegendWeb.static_paths()

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json, AshJsonApi.Plug.Parser],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head

  plug :relay_guards

  plug LegendWeb.Router

  # Drop the agent MCP surface on the public relay ingress, and stamp every other
  # connection via_relay (=> never loopback-trusted downstream).
  def relay_guards(%Plug.Conn{path_info: ["api", "mcp" | _]} = conn, _opts) do
    conn
    |> Plug.Conn.put_status(404)
    |> Phoenix.Controller.json(%{error: "not found"})
    |> Plug.Conn.halt()
  end

  def relay_guards(conn, _opts), do: LegendWeb.ViaRelay.stamp(conn)
end
```

- [ ] **Step 5: Run it — expect PASS** (the three endpoint tests). If `connect_info: [:peer_data, via_relay: true]` is rejected by this Phoenix version (it should be accepted — arbitrary trailing keywords are valid connect_info), fall back to a thin `LegendWeb.RelayUserSocket` that `use Phoenix.Socket`, delegates channels to `UserSocket`, and overrides `connect/3` to force the token path; report which path you took. `cd backend && mix test test/legend_web/relay_ingress_endpoint_test.exs`

- [ ] **Step 6: `mix precommit`** — full suite green (the new endpoint is `server: false` outside its test, so it doesn't affect other tests).

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend_web/relay_ingress_endpoint.ex backend/config/config.exs backend/config/runtime.exs backend/config/test.exs backend/test/legend_web/relay_ingress_endpoint_test.exs
git commit -m "feat(relay): RelayIngressEndpoint (static+router+socket; via_relay; no /api/mcp)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Supervise the ingress behind a flag (default off)

**Files:**
- Modify: `backend/lib/legend/application.ex` (conditionally start `LegendWeb.RelayIngressEndpoint`)
- Modify: `backend/lib/legend/core/remote.ex` (a `relay_ingress_enabled?/0` flag — read-only for now; Part 2 wires it to settings)
- Test: `backend/test/legend/core/remote_test.exs` (the flag default)

**Interfaces:**
- Produces: `Legend.Core.Remote.relay_ingress_enabled?() :: boolean` (default `false`). Consumed by `application.ex` to decide whether to add the ingress child. Part 2 makes this true when relay mode is configured + enabled.

- [ ] **Step 1: Write the failing test**

Add to `backend/test/legend/core/remote_test.exs`:

```elixir
  test "relay ingress is disabled by default" do
    refute Legend.Core.Remote.relay_ingress_enabled?()
  end
```

- [ ] **Step 2: Run it — expect FAIL.** `cd backend && mix test test/legend/core/remote_test.exs`

- [ ] **Step 3: Add the flag**

In `backend/lib/legend/core/remote.ex`, add (Part 2 will replace the body with the real relay-mode read; for now it is a pure default-off flag):

```elixir
  @doc """
  Whether the relay ingress endpoint should boot. Default off; Part 2 wires this
  to the persisted "via relay" remote-access mode.
  """
  @spec relay_ingress_enabled?() :: boolean()
  def relay_ingress_enabled?, do: false
```

- [ ] **Step 4: Run it — expect PASS.** `mix test test/legend/core/remote_test.exs`

- [ ] **Step 5: Conditionally supervise the ingress**

In `backend/lib/legend/application.ex`, add the ingress endpoint to the children list **only** when the flag is set (read the current `children` assembly and insert this near `LegendWeb.Endpoint`, after `Legend.Core.Remote.Boot`):

```elixir
    children =
      base_children ++
        if Legend.Core.Remote.relay_ingress_enabled?(),
          do: [LegendWeb.RelayIngressEndpoint],
          else: []
```

(Adapt to the file's actual children-assembly shape — the key requirement: `LegendWeb.RelayIngressEndpoint` is in the supervision tree iff `relay_ingress_enabled?/0` is true. Default off ⇒ not started ⇒ no behavior change.)

- [ ] **Step 6: `mix precommit`** — full suite green; the app still boots with the ingress absent (default off).

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend/application.ex backend/lib/legend/core/remote.ex backend/test/legend/core/remote_test.exs
git commit -m "feat(relay): supervise RelayIngressEndpoint behind a default-off flag

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `cd backend && mix precommit` — green; the main endpoint behaves exactly as before (no `via_relay` stamping on it).
- [ ] Confirm the trust invariants hold on the ingress: a device-gated route without a token → 401; management → 403; `/api/mcp` → 404; `/api/health`/`/api/pair` reachable; socket connect without a token → rejected (the user-socket test). These are the spec's crux — they must pass before Part 2 splices real relay traffic in.

## Notes / hand-off to Part 2

- Part 2 builds the `relay/` app (carrier registration with per-handle allowlist + DNS-label validation; TLS-terminating raw-byte device proxy; subdomain routing; in-memory registry), the `Legend.Federation.RelayClient` (outbound Mint.WebSocket carrier + the accept-streams-and-splice server, adapting `Legend.Tunnels.SpriteProxy.Server`'s proven splice to dial **this ingress's** http port), the Remote-access **"via relay"** settings mode + relay-URL pairing QR + per-origin-repair note, and flips `relay_ingress_enabled?/0` to read the persisted relay mode + sets the ingress `check_origin` to the relay host.
- The ingress's `http` port for Part 2's splice: Part 2 starts the ingress on a known/ephemeral loopback port and the federation server dials it (mirroring `SpriteProxy.Server`'s `:gen_tcp.connect(~c"127.0.0.1", target_port, ...)`).
