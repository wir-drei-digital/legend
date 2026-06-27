# Relay Phase 3a — Part 2a: The Standalone Relay App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build the standalone, self-hostable `relay/` Elixir app: it accepts an instance's outbound WSS **carrier** (registering a `{handle, secret}`), and TLS-terminates device HTTPS, routing each device connection by subdomain to that instance's carrier as a **mux stream** — so a phone reaches an instance behind NAT. Trusted relay (3a); E2E is 3b.

**Architecture:** A new sibling Elixir project (`relay/`, like `bridge/`), depending only on `bandit` + `websock_adapter` + `plug` + `thousand_island` + `jason` (NOT the full Phoenix/Ash backend). It **vendors a copy of the mux codec** (the wire format is the cross-process contract). The carrier endpoint is a `WebSock` handler over Bandit (instance ↔ relay, mux frames as WS binary). The device endpoint is a raw `ThousandIsland` TLS listener whose handler splices cleartext bytes ↔ a mux stream. An in-memory `Relay.Registry` maps `handle → carrier pid` with a per-handle secret allowlist + DNS-label validation.

**Tech Stack:** Elixir / Bandit 1.5+ / WebSock 0.5 / ThousandIsland 1.5 (raw TLS) / Plug / Jason. No Phoenix, no Ecto, no Ash.

## Global Constraints

- The relay is a **separate mix project** at repo-root `relay/` (the repo is NOT an umbrella; mirror the `bridge/` sibling pattern). All `mix` for it runs from `relay/`. `cd relay && mix test` must pass; `mix format` clean; compile `--warnings-as-errors`.
- The relay vendors the mux wire format **verbatim**: big-endian `type:u8 stream_id:u32 length:u32 payload`; types `:open=1 :data=2 :close=3 :window=4`; `initial_window 262_144`; `max_frame_payload 1_048_576`. It MUST stay byte-compatible with `backend/lib/legend/core/tunnel/mux.ex` (the instance side speaks the same protocol). Copy the codec; do not diverge the wire format.
- Per the spec: **per-handle credentials** (an allowlist `handle → secret`, from config) — NOT one global secret. Handles validated against `^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$` (lowercased DNS label). A registration with a wrong/absent secret or a bad/duplicate-live handle is rejected.
- The device endpoint is a **TLS-terminating RAW-BYTE** proxy (ThousandIsland + `ThousandIsland.Transports.SSL`), NOT an HTTP server — the instance's Bandit parses HTTP/WS; the relay stays byte-agnostic.
- Trusted relay (3a): the relay sees cleartext (it terminates TLS) — it does NOT do human auth; the device token is verified end-to-end by the instance. The relay authenticates the **instance** (the per-handle secret).
- The relay holds state **in-memory** (no DB).
- Commit messages end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

## File structure (`relay/`)

- `relay/mix.exs` — `:relay` app; deps bandit/websock_adapter/plug/thousand_island/jason.
- `relay/lib/relay/application.ex` — supervision tree (Registry + the two listeners; listeners gated by config so tests can start them per-case).
- `relay/lib/relay/mux.ex` — vendored mux codec (`Frame`, `encode/1`, `decode/1`, `window/2`, `initial_window/0`, `max_frame_payload/0`).
- `relay/lib/relay/registry.ex` — `Relay.Registry` GenServer: `register/3`, `lookup/1`, `handle_valid?/1`, secret allowlist.
- `relay/lib/relay/carrier.ex` — the `WebSock` carrier handler (mux hub: instance ↔ device streams).
- `relay/lib/relay/carrier_plug.ex` — the Plug that upgrades the carrier WS route.
- `relay/lib/relay/device.ex` — the `ThousandIsland.Handler` for the device TLS endpoint.
- Tests under `relay/test/`.

---

### Task 1: Scaffold `relay/` + vendor the mux codec

**Files:**
- Create: `relay/mix.exs`, `relay/lib/relay/application.ex`, `relay/lib/relay/mux.ex`, `relay/.formatter.exs`, `relay/test/test_helper.exs`
- Test: `relay/test/relay/mux_test.exs`

**Interfaces:**
- Produces: `Relay.Mux.Frame` struct (`%Frame{type, stream_id, payload}`), `Relay.Mux.encode/1 :: binary`, `Relay.Mux.decode/1 :: {:ok, [Frame], rest_binary} | {:error, :frame_too_large}`, `Relay.Mux.window/2`, `Relay.Mux.initial_window/0`, `Relay.Mux.max_frame_payload/0`. Consumed by Tasks 3–5.

- [ ] **Step 1: Create the project skeleton.** `relay/mix.exs`:

```elixir
defmodule Relay.MixProject do
  use Mix.Project

  def project do
    [
      app: :relay,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_options: [warnings_as_errors: true],
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [mod: {Relay.Application, []}, extra_applications: [:logger, :ssl]]
  end

  defp deps do
    [
      {:bandit, "~> 1.5"},
      {:websock_adapter, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:thousand_island, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
```

`relay/.formatter.exs`: `[inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]`. `relay/test/test_helper.exs`: `ExUnit.start()`. `relay/lib/relay/application.ex` (minimal for now — only the Registry; Task 5 adds the listeners):

```elixir
defmodule Relay.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [Relay.Registry]
    Supervisor.start_link(children, strategy: :one_for_one, name: Relay.Supervisor)
  end
end
```

(`Relay.Registry` is created in Task 2; for Task 1, temporarily start with `children = []` so the app boots, and Task 2 adds the Registry child. Note this in a comment.)

- [ ] **Step 2: Write the failing mux test.** `relay/test/relay/mux_test.exs`:

```elixir
defmodule Relay.MuxTest do
  use ExUnit.Case, async: true
  alias Relay.Mux
  alias Relay.Mux.Frame

  test "encode/decode round-trips a DATA frame" do
    f = %Frame{type: :data, stream_id: 7, payload: "hello"}
    assert {:ok, [decoded], ""} = Mux.decode(Mux.encode(f))
    assert decoded == f
  end

  test "decode handles a partial buffer (returns the remainder)" do
    bin = Mux.encode(%Frame{type: :open, stream_id: 1, payload: ""})
    {head, tail} = String.split_at(bin, 4)
    assert {:ok, [], ^head} = Mux.decode(head)
    assert {:ok, [%Frame{type: :open, stream_id: 1}], ""} = Mux.decode(head <> tail)
  end

  test "frame type tags match the wire contract" do
    assert <<1, _::binary>> = Mux.encode(%Frame{type: :open, stream_id: 0})
    assert <<2, _::binary>> = Mux.encode(%Frame{type: :data, stream_id: 0, payload: "x"})
    assert <<3, _::binary>> = Mux.encode(%Frame{type: :close, stream_id: 0})
  end
end
```

- [ ] **Step 3: Run it — expect FAIL.** `cd relay && mix deps.get && mix test test/relay/mux_test.exs`

- [ ] **Step 4: Vendor the mux codec.** Copy `backend/lib/legend/core/tunnel/mux.ex` into `relay/lib/relay/mux.ex`, renaming the module `Legend.Core.Tunnel.Mux` → `Relay.Mux` and its `Frame` submodule accordingly. Keep the wire format, tags, `initial_window`, `max_frame_payload`, `encode/1`, `decode/1`, `window/2`, `parse_window/1` **identical**. Add a moduledoc line: `# Vendored from backend/lib/legend/core/tunnel/mux.ex — wire format MUST stay byte-compatible.`

- [ ] **Step 5: Run it — expect PASS.** `cd relay && mix test test/relay/mux_test.exs`

- [ ] **Step 6: Compile clean + format.** `cd relay && mix compile --warnings-as-errors && mix format --check-formatted && mix test`

- [ ] **Step 7: Commit**

```bash
git add relay/
git commit -m "feat(relay): scaffold relay app + vendor the mux codec

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `Relay.Registry` — handle→carrier with per-handle secret + DNS-label validation

**Files:**
- Create: `relay/lib/relay/registry.ex`
- Modify: `relay/lib/relay/application.ex` (add `Relay.Registry` child)
- Modify: `relay/config/config.exs` (create it) — the `handle → secret` allowlist
- Test: `relay/test/relay/registry_test.exs`

**Interfaces:**
- Produces: `Relay.Registry.handle_valid?(handle :: String.t()) :: boolean`; `Relay.Registry.register(handle, secret, carrier_pid) :: :ok | {:error, :bad_handle | :bad_secret | :taken}`; `Relay.Registry.lookup(handle) :: {:ok, pid} | :error`. Registration is auto-cleared when `carrier_pid` dies (monitor). Consumed by the carrier (Task 3) + device handler (Task 4).

- [ ] **Step 1: Write the failing test.** `relay/test/relay/registry_test.exs`:

```elixir
defmodule Relay.RegistryTest do
  use ExUnit.Case, async: false

  setup do
    # allowlist for the test: handle "laptop" => secret "s3cret"
    Application.put_env(:relay, :handles, %{"laptop" => "s3cret"})
    start_supervised!(Relay.Registry)
    :ok
  end

  test "valid registration, then lookup" do
    assert :ok = Relay.Registry.register("laptop", "s3cret", self())
    assert {:ok, pid} = Relay.Registry.lookup("laptop")
    assert pid == self()
  end

  test "wrong secret is rejected" do
    assert {:error, :bad_secret} = Relay.Registry.register("laptop", "nope", self())
  end

  test "unknown handle is rejected" do
    assert {:error, :bad_secret} = Relay.Registry.register("ghost", "x", self())
  end

  test "invalid DNS-label handle is rejected before any secret check" do
    assert {:error, :bad_handle} = Relay.Registry.register("Not_A_Label", "s3cret", self())
    refute Relay.Registry.handle_valid?("Not_A_Label")
    assert Relay.Registry.handle_valid?("laptop")
  end

  test "a second live registration of the same handle is rejected" do
    other = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Relay.Registry.register("laptop", "s3cret", other)
    assert {:error, :taken} = Relay.Registry.register("laptop", "s3cret", self())
  end

  test "registration is cleared when the carrier dies" do
    pid = spawn(fn -> Process.sleep(50) end)
    assert :ok = Relay.Registry.register("laptop", "s3cret", pid)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000
    Process.sleep(20)
    assert :error = Relay.Registry.lookup("laptop")
  end
end
```

- [ ] **Step 2: Run it — expect FAIL.** `cd relay && mix test test/relay/registry_test.exs`

- [ ] **Step 3: Implement the registry.** `relay/lib/relay/registry.ex` — a GenServer holding `%{handle => pid}` and monitoring carriers:

```elixir
defmodule Relay.Registry do
  @moduledoc "In-memory handle => carrier-pid map. Per-handle secret allowlist + DNS-label validation. Auto-clears on carrier death."
  use GenServer

  @label ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec handle_valid?(String.t()) :: boolean
  def handle_valid?(handle) when is_binary(handle), do: Regex.match?(@label, handle)
  def handle_valid?(_), do: false

  @spec register(String.t(), String.t(), pid()) :: :ok | {:error, :bad_handle | :bad_secret | :taken}
  def register(handle, secret, pid), do: GenServer.call(__MODULE__, {:register, handle, secret, pid})

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(handle), do: GenServer.call(__MODULE__, {:lookup, handle})

  @impl true
  def init(_), do: {:ok, %{by_handle: %{}, by_ref: %{}}}

  @impl true
  def handle_call({:register, handle, secret, pid}, _from, state) do
    cond do
      not handle_valid?(handle) -> {:reply, {:error, :bad_handle}, state}
      secret != allowed_secret(handle) -> {:reply, {:error, :bad_secret}, state}
      Map.has_key?(state.by_handle, handle) -> {:reply, {:error, :taken}, state}
      true ->
        ref = Process.monitor(pid)
        {:reply, :ok,
         %{state | by_handle: Map.put(state.by_handle, handle, pid), by_ref: Map.put(state.by_ref, ref, handle)}}
    end
  end

  def handle_call({:lookup, handle}, _from, state) do
    case Map.fetch(state.by_handle, handle) do
      {:ok, pid} -> {:reply, {:ok, pid}, state}
      :error -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.by_ref, ref) do
      {nil, _} -> {:noreply, state}
      {handle, by_ref} -> {:noreply, %{state | by_handle: Map.delete(state.by_handle, handle), by_ref: by_ref}}
    end
  end

  # nil for an unknown handle => secret comparison fails with {:error, :bad_secret}
  defp allowed_secret(handle), do: Map.get(Application.get_env(:relay, :handles, %{}), handle)
end
```

Create `relay/config/config.exs`:

```elixir
import Config
# Per-handle credentials: %{"<handle>" => "<secret>"}. Set via RELAY_HANDLES in prod
# (config/runtime.exs); empty by default so an unconfigured relay accepts nobody.
config :relay, :handles, %{}
```

Add `Relay.Registry` to `relay/lib/relay/application.ex`'s `children`.

- [ ] **Step 4: Run it — expect PASS.** `cd relay && mix test test/relay/registry_test.exs`
- [ ] **Step 5: Compile clean + format + full test.** `cd relay && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
- [ ] **Step 6: Commit** — `feat(relay): handle registry with per-handle secret + DNS-label validation`.

---

### Task 3: Carrier WS endpoint — the mux hub (instance ↔ device streams)

**Files:**
- Create: `relay/lib/relay/carrier.ex` (the `WebSock` handler), `relay/lib/relay/carrier_plug.ex` (the WS-upgrade Plug)
- Test: `relay/test/relay/carrier_test.exs`

**Interfaces:**
- Consumes: `Relay.Registry`, `Relay.Mux`.
- Produces: `Relay.Carrier` (a `WebSock` impl) — its process is the **mux hub** for one instance. A device handler (Task 4) interacts with a carrier via messages: send `{:open, device_pid}` to get a new stream allocated + `OPEN` pushed to the instance (the carrier replies `{:stream, stream_id}`); send `{:stream_data, stream_id, bytes}` to forward device bytes (→ `DATA` to instance); send `{:stream_close, stream_id}`. The carrier routes instance→device `DATA`/`CLOSE` frames to the owning device pid as `{:to_device, bytes}` / `{:to_device_close}`.
- **Registration handshake:** the FIRST WS binary message from the instance is JSON `{"handle": "...", "secret": "..."}`; the carrier registers it (Registry) or closes the socket on failure. Subsequent binary messages are mux frames.

- [ ] **Step 1: Write the failing test.** Test the handler callbacks directly (no real WS) — `relay/test/relay/carrier_test.exs`. This unit-tests the mux-hub logic: registration, stream allocation, frame routing.

```elixir
defmodule Relay.CarrierTest do
  use ExUnit.Case, async: false
  alias Relay.{Carrier, Mux}
  alias Relay.Mux.Frame

  setup do
    Application.put_env(:relay, :handles, %{"laptop" => "s3cret"})
    start_supervised!(Relay.Registry)
    {:ok, state} = Carrier.init([])
    %{state: state}
  end

  test "first message registers the handle; bad secret closes", %{state: state} do
    bad = Jason.encode!(%{handle: "laptop", secret: "nope"})
    assert {:stop, _reason, _code, _state} = Carrier.handle_in({bad, opcode: :binary}, state)

    good = Jason.encode!(%{handle: "laptop", secret: "s3cret"})
    assert {:ok, registered} = Carrier.handle_in({good, opcode: :binary}, state)
    assert {:ok, _pid} = Relay.Registry.lookup("laptop")
    # the device-open path allocates a stream and pushes an OPEN frame to the instance
    assert {:push, {:binary, bin}, registered2} = Carrier.handle_info({:open, self()}, registered)
    assert {:ok, [%Frame{type: :open, stream_id: sid}], ""} = Mux.decode(bin)
    assert_received {:stream, ^sid}
    # an inbound DATA frame for that stream is routed to the device pid
    data = Mux.encode(%Frame{type: :data, stream_id: sid, payload: "hi"})
    assert {:ok, _} = Carrier.handle_in({data, opcode: :binary}, registered2)
    assert_received {:to_device, "hi"}
  end
end
```

- [ ] **Step 2: Run it — expect FAIL.** `cd relay && mix test test/relay/carrier_test.exs`

- [ ] **Step 3: Implement the carrier handler.** `relay/lib/relay/carrier.ex` (a `WebSock` behaviour; state holds `registered?`, `streams: %{stream_id => device_pid}`, `next_id`):

```elixir
defmodule Relay.Carrier do
  @moduledoc """
  The mux hub for one registered instance, run as a WebSock handler. The instance
  dials this over WSS and registers `{handle, secret}` (first binary message);
  thereafter both sides exchange mux frames as WS binary messages. The relay OPENs
  one stream per device connection toward the instance and routes instance→device
  DATA/CLOSE frames to the owning device handler process.
  """
  @behaviour WebSock
  require Logger
  alias Relay.Mux
  alias Relay.Mux.Frame

  @impl true
  def init(_opts), do: {:ok, %{registered: false, streams: %{}, buffer: "", next_id: 1}}

  @impl true
  # Registration: the first binary message.
  def handle_in({msg, opcode: :binary}, %{registered: false} = state) do
    with {:ok, %{"handle" => h, "secret" => s}} <- Jason.decode(msg),
         :ok <- Relay.Registry.register(h, s, self()) do
      {:ok, %{state | registered: true}}
    else
      _ -> {:stop, :normal, 1008, state}
    end
  end

  # After registration: mux frames from the instance.
  def handle_in({bin, opcode: :binary}, %{registered: true} = state) do
    case Mux.decode(state.buffer <> bin) do
      {:ok, frames, rest} ->
        {:ok, Enum.reduce(frames, %{state | buffer: rest}, &route_from_instance/2)}

      {:error, :frame_too_large} ->
        {:stop, :normal, 1009, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl true
  # A device handler opens a new stream.
  def handle_info({:open, device_pid}, state) do
    id = state.next_id
    send(device_pid, {:stream, id})
    frame = Mux.encode(%Frame{type: :open, stream_id: id, payload: ""})
    {:push, {:binary, frame},
     %{state | streams: Map.put(state.streams, id, device_pid), next_id: id + 1}}
  end

  def handle_info({:stream_data, id, bytes}, state) do
    {:push, {:binary, Mux.encode(%Frame{type: :data, stream_id: id, payload: bytes})}, state}
  end

  def handle_info({:stream_close, id}, state) do
    {:push, {:binary, Mux.encode(%Frame{type: :close, stream_id: id, payload: ""})},
     %{state | streams: Map.delete(state.streams, id)}}
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  # instance → device routing
  defp route_from_instance(%Frame{type: :data, stream_id: id, payload: p}, state) do
    with %{^id => dpid} <- state.streams, do: send(dpid, {:to_device, p})
    state
  end

  defp route_from_instance(%Frame{type: :close, stream_id: id}, state) do
    case Map.pop(state.streams, id) do
      {nil, _} -> state
      {dpid, streams} -> send(dpid, {:to_device_close}); %{state | streams: streams}
    end
  end

  defp route_from_instance(_other, state), do: state
end
```

`relay/lib/relay/carrier_plug.ex` — a Plug that upgrades the carrier route to this handler:

```elixir
defmodule Relay.CarrierPlug do
  @moduledoc "Upgrades GET /carrier to the Relay.Carrier WebSock handler."
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/carrier"} = conn, _opts) do
    conn |> WebSockAdapter.upgrade(Relay.Carrier, [], timeout: 60_000) |> halt()
  end

  def call(conn, _opts), do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "not found")
end
```

- [ ] **Step 4: Run it — expect PASS.** `cd relay && mix test test/relay/carrier_test.exs`

(If `WebSock.handle_in` return-shape for stop differs in this `websock` version — verify against `relay/deps/websock/lib/websock.ex` — adjust the `{:stop, ...}` tuples to the library's contract and report.)

- [ ] **Step 5: Compile clean + format + full test.** `cd relay && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
- [ ] **Step 6: Commit** — `feat(relay): carrier WS endpoint — mux hub (instance <-> device streams)`.

---

### Task 4: Device TLS endpoint — ThousandIsland handler, SNI→handle, splice

**Files:**
- Create: `relay/lib/relay/device.ex` (the `ThousandIsland.Handler`)
- Test: `relay/test/relay/device_test.exs`

**Interfaces:**
- Consumes: `Relay.Registry.lookup/1`, the carrier message protocol from Task 3 (`{:open, self()}` → `{:stream, id}`; `{:stream_data, id, bytes}`; `{:stream_close, id}`; inbound `{:to_device, bytes}` / `{:to_device_close}`).
- Produces: `Relay.Device` — a `ThousandIsland.Handler`. On a new TLS connection it resolves the **SNI hostname → handle** (first DNS label), looks up the carrier, opens a stream, and splices: device bytes → `{:stream_data, id, bytes}`; `{:to_device, bytes}` → `ThousandIsland.Socket.send`.

**SPIKE (do this first, it gates the design):** verify how to read the negotiated **SNI hostname** from a ThousandIsland TLS connection in `handle_connection/2`. The likely path: `ThousandIsland.Socket` wraps an `:ssl` socket; get it (e.g. `ThousandIsland.Socket.peercert/1` is for client certs — not it) and call `:ssl.connection_information(ssl_socket, [:sni_hostname])`, OR capture the SNI at handshake via the SSL transport's `sni_fun`/`handshake` hook. If SNI is not cleanly retrievable, the **fallback** is to read the HTTP `Host:` header from the first `handle_data/3` bytes (peek the request line) and route on that, buffering until the host is known. Pick whichever works against ThousandIsland 1.5 and **document it in the report**; the rest of this task assumes a `host_to_handle(host) :: handle` step regardless of source.

- [ ] **Step 1: Write the failing test** for the routing + splice logic, driving the handler with a **mock carrier** (a test process implementing the carrier message protocol). Test `host_to_handle/1` and the data path without real TLS:

```elixir
defmodule Relay.DeviceTest do
  use ExUnit.Case, async: false

  test "host_to_handle extracts the first DNS label" do
    assert Relay.Device.host_to_handle("laptop.relay.example.com") == "laptop"
    assert Relay.Device.host_to_handle("work.relay.example.com") == "work"
    assert Relay.Device.host_to_handle(nil) == nil
  end

  test "an unknown handle yields no carrier (connection should close)" do
    Application.put_env(:relay, :handles, %{})
    start_supervised!(Relay.Registry)
    assert :error = Relay.Registry.lookup("ghost")
  end
end
```

(The full byte-splice through real TLS is exercised in Task 5's gated integration test; this task unit-tests the pure routing helper + asserts the carrier-protocol calls via the mock where practical.)

- [ ] **Step 2: Run it — expect FAIL.** `cd relay && mix test test/relay/device_test.exs`

- [ ] **Step 3: Implement the handler.** `relay/lib/relay/device.ex` (a `ThousandIsland.Handler`; resolves SNI→handle on connect, opens a stream via the carrier, splices). Use the SNI source confirmed in the spike; `host_to_handle/1` is pure:

```elixir
defmodule Relay.Device do
  @moduledoc """
  Device-facing TLS endpoint. ThousandIsland terminates TLS; this handler resolves
  the SNI hostname to a handle, opens a mux stream on that instance's carrier, and
  splices raw cleartext bytes <-> the stream. HTTP-agnostic: the instance's Bandit
  parses the HTTP/WS on the other end.
  """
  use ThousandIsland.Handler
  require Logger

  @spec host_to_handle(String.t() | nil) :: String.t() | nil
  def host_to_handle(nil), do: nil
  def host_to_handle(host) when is_binary(host), do: host |> String.split(".") |> List.first()

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    with handle when is_binary(handle) <- host_to_handle(sni_hostname(socket)),
         {:ok, carrier} <- Relay.Registry.lookup(handle) do
      send(carrier, {:open, self()})

      receive do
        {:stream, id} -> {:continue, Map.merge(state, %{carrier: carrier, stream_id: id})}
      after
        5_000 -> {:close, state}
      end
    else
      _ -> {:close, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, _socket, %{carrier: carrier, stream_id: id} = state) do
    send(carrier, {:stream_data, id, data})
    {:continue, state}
  end

  # Frames from the instance, routed by the carrier to this process.
  @impl GenServer
  def handle_info({:to_device, bytes}, {socket, state}) do
    ThousandIsland.Socket.send(socket, bytes)
    {:noreply, {socket, state}}
  end

  def handle_info({:to_device_close}, {socket, state}) do
    {:stop, :normal, {socket, state}}
  end

  def handle_info(other, sock_state), do: super(other, sock_state)

  @impl ThousandIsland.Handler
  def handle_close(%{carrier: carrier, stream_id: id}), do: send(carrier, {:stream_close, id})
  def handle_close(_state), do: :ok

  # Replace with the SNI source confirmed in the spike.
  defp sni_hostname(socket) do
    case :ssl.connection_information(ThousandIsland.Socket.handshake!(socket) && raw_ssl(socket), [:sni_hostname]) do
      {:ok, [sni_hostname: host]} when is_list(host) -> List.to_string(host)
      _ -> nil
    end
  end

  defp raw_ssl(socket), do: socket
end
```

(The `sni_hostname/1` body above is the placeholder shape to REPLACE with the exact API confirmed in the spike — `ThousandIsland.Handler`'s `handle_info`/socket-tuple shape and the SSL-socket accessor must match ThousandIsland 1.5. The implementer wires the real accessor and adjusts the `handle_info` socket-tuple destructuring to ThousandIsland's actual handler-process message shape. Verify the `use ThousandIsland.Handler` callback signatures against `relay/deps/thousand_island/lib/thousand_island/handler.ex` and report the exact shapes used.)

- [ ] **Step 4: Run it — expect PASS** (the pure `host_to_handle` + registry tests). `cd relay && mix test test/relay/device_test.exs`
- [ ] **Step 5: Compile clean + format + full test.** `cd relay && mix compile --warnings-as-errors && mix format --check-formatted && mix test`
- [ ] **Step 6: Commit** — `feat(relay): device TLS endpoint — SNI->handle routing + raw-byte splice`.

---

### Task 5: App wiring + end-to-end integration test

**Files:**
- Modify: `relay/lib/relay/application.ex` (start the carrier Bandit listener + the device ThousandIsland TLS listener, from config), `relay/config/config.exs` + create `relay/config/runtime.exs` (ports, cert paths, `RELAY_HANDLES`)
- Test: `relay/test/relay/integration_test.exs` (gated)

**Interfaces:**
- Produces: a running relay — carrier WS on `RELAY_CARRIER_PORT`, device TLS on `RELAY_DEVICE_PORT` — that routes a device connection to a registered instance carrier end-to-end.

- [ ] **Step 1: Wire the listeners.** In `relay/lib/relay/application.ex`, add (guarded by config so tests can opt out): the carrier listener `{Bandit, plug: Relay.CarrierPlug, scheme: :http, port: carrier_port}` and the device listener `{ThousandIsland, port: device_port, handler_module: Relay.Device, transport_module: ThousandIsland.Transports.SSL, transport_options: [certfile: ..., keyfile: ...]}`. Read ports + cert paths from `Application.get_env(:relay, ...)`. `relay/config/runtime.exs` reads `RELAY_CARRIER_PORT`, `RELAY_DEVICE_PORT`, `RELAY_CERTFILE`, `RELAY_KEYFILE`, and `RELAY_HANDLES` (parse a `handle:secret,handle2:secret2` env into the `:handles` map). Gate listener start on `Application.get_env(:relay, :start_listeners, true)` so the test env sets it false and starts them per-test.

- [ ] **Step 2: Write the gated integration test.** `relay/test/relay/integration_test.exs` — `@moduletag :integration` (run with `mix test --only integration`). It: starts the carrier Bandit listener on an ephemeral port; connects a **mock instance** WS client (use `:gen_tcp`+`Mint.WebSocket`, or a minimal raw client) that registers `{handle, secret}` and then, on receiving an `OPEN`, replies `DATA` echoing a known payload; opens a **plaintext** device-side connection (test the splice without TLS by also configuring a plaintext device listener variant, OR exercise `Relay.Device`'s data path against the started carrier via the message protocol); asserts the echoed bytes arrive. Keep TLS itself out of the unit CI path (cert generation is a manual/live concern) — assert the **mux routing + splice** end-to-end over plaintext, and document the TLS live-acceptance as manual.

```elixir
defmodule Relay.IntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :integration
  # Boots the carrier listener, connects a mock instance carrier (registers laptop/s3cret),
  # drives a device stream through the carrier, and asserts a byte round-trip.
  # (Full TLS device path is a manual live-acceptance; this asserts the mux splice.)
  test "device bytes round-trip through the relay to a registered instance" do
    # ... implementer fills in using the Task-3 carrier protocol + a mock WS instance ...
    assert true
  end
end
```

(The integration test body is the implementer's to complete against the real listeners + a mock instance — it is gated `:integration` and is the proof the pieces compose. If a faithful in-test WS instance is impractical, assert the `Relay.Device` ↔ `Relay.Carrier` message round-trip directly with both real processes and a fake TLS socket, and document the gap.)

- [ ] **Step 3: Run the non-integration suite green + the integration test locally.** `cd relay && mix test` (unit) and `mix test --only integration`.
- [ ] **Step 4: Compile clean + format.** `cd relay && mix compile --warnings-as-errors && mix format --check-formatted`
- [ ] **Step 5: Commit** — `feat(relay): app wiring (carrier + device listeners) + integration test`.

---

## Final verification (after all tasks)

- [ ] `cd relay && mix compile --warnings-as-errors && mix format --check-formatted && mix test` green.
- [ ] Wire-compatibility check: `Relay.Mux` encodes/decodes the SAME bytes as `backend/lib/legend/core/tunnel/mux.ex` (the instance side) — confirm by encoding a known frame in both and diffing, or by a shared golden vector.
- [ ] Security posture: the relay does NO human auth (device token verified by the instance); per-handle secrets gate registration; handles are DNS-label-validated; the relay holds no persistent state.

## Notes / hand-off to Part 2b
- Part 2b builds `Legend.Federation.RelayClient` (the instance dials THIS relay's `/carrier` with `Mint.WebSocket`, registers `{handle, secret}`, then accepts the relay's OPEN/DATA/CLOSE and splices each stream to the Part-1 `RelayIngressEndpoint`'s loopback port — adapting `Legend.Tunnels.SpriteProxy.Server`), plus the "via relay" settings mode + relay-subdomain pairing QR + per-origin-repair note, and flips `Legend.Core.Remote.relay_ingress_enabled?/0` to the persisted relay mode + sets the ingress private port + `check_origin` to `<handle>.<relay-host>`.
- The two spikes flagged here (SNI extraction; the WS integration harness) should be resolved and their resolutions recorded in the task reports so Part 2b and the live acceptance can rely on them.
