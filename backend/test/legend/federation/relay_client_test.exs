defmodule Legend.Federation.RelayClientTest do
  @moduledoc """
  Gated end-to-end test for the outbound carrier — run with `mix test --only integration`.

  ## Harness: a minimal in-test Bandit + WebSock `/carrier` server (the relay's role)

  The real Part-2a relay app lives in a separate Mix project (`/relay`), so it can't
  be started from the backend's test VM. Instead this boots a REAL Bandit listener
  on an ephemeral port serving `/carrier` via a `WebSock` handler that mirrors
  `Relay.Carrier`'s protocol exactly:

    * registration is the FIRST BINARY frame `{"handle","secret"}` (verified, then
      the handler announces itself to the test as `{:registered, pid}`);
    * thereafter it exchanges `Legend.Core.Tunnel.Mux` frames as WS binary messages;
    * `{:device_open, _}` from the test pushes an OPEN frame (what the relay does per
      device connection) and DATA frames the instance sends back are surfaced to the
      test as `{:from_instance, bytes}` — exactly the `Relay.Carrier`/`Relay.Device`
      message contract.

  The "ingress" (Task 1's `RelayIngressEndpoint`) is stood in for by a raw TCP echo
  listener on `target_port`. The assertion is a genuine bidirectional round-trip:
  device bytes -> relay OPEN/DATA -> real Mint.WebSocket carrier -> RelayClient.Server
  -> echo ingress -> back over the carrier -> relay -> device. No `assert true`.
  """
  use ExUnit.Case, async: false

  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame
  alias Legend.Federation.RelayClient
  alias Legend.Federation.RelayClient.Carrier

  @moduletag :integration

  @handle "laptop"
  @secret "s3cret"

  setup do
    # 1. Echo "ingress" standing in for LegendWeb.RelayIngressEndpoint.
    target_port = start_echo_ingress()

    # 2. Real Bandit /carrier WS server (the relay's carrier hub) on an ephemeral port.
    relay_port = free_port()

    start_supervised!(
      {Bandit,
       plug: {__MODULE__.CarrierPlug, test_pid: self(), handle: @handle, secret: @secret},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: relay_port}
    )

    %{target_port: target_port, relay_url: "ws://127.0.0.1:#{relay_port}"}
  end

  test "device bytes round-trip through a real Mint.WebSocket carrier to the echo ingress",
       %{target_port: target_port, relay_url: relay_url} do
    {:ok, _client} =
      RelayClient.start_link(%{
        relay_url: relay_url,
        handle: @handle,
        secret: @secret,
        target_port: target_port
      })

    # The carrier connected and registered {handle, secret} as the first binary frame.
    assert_receive {:registered, carrier_handler}, 5_000

    # The relay opens a stream toward the instance (one per device connection).
    send(carrier_handler, {:device_open, self()})
    assert_receive {:stream, id}, 2_000

    # device -> instance: DATA arrives, the Server dials the echo ingress and writes it,
    # the echo bounces it, and it comes back out the carrier as a DATA frame -> the relay.
    send(carrier_handler, {:device_data, id, "ping"})
    assert_receive {:from_instance, "ping"}, 5_000

    # A second round-trip proves the spliced socket stays live across frames.
    send(carrier_handler, {:device_data, id, "more bytes"})
    assert_receive {:from_instance, "more bytes"}, 5_000
  end

  test "the carrier reconnects and re-registers after the connection drops",
       %{target_port: target_port, relay_url: relay_url} do
    {:ok, _client} =
      RelayClient.start_link(%{
        relay_url: relay_url,
        handle: @handle,
        secret: @secret,
        target_port: target_port
      })

    assert_receive {:registered, first_handler}, 5_000

    # Kill the relay-side WS handler — the carrier socket drops, the carrier process
    # exits, and RelayClient must dial a fresh carrier that re-registers.
    Process.exit(first_handler, :kill)

    assert_receive {:registered, second_handler}, 8_000
    assert second_handler != first_handler

    # The re-established carrier still carries a real round-trip.
    send(second_handler, {:device_open, self()})
    assert_receive {:stream, id}, 2_000
    send(second_handler, {:device_data, id, "after-reconnect"})
    assert_receive {:from_instance, "after-reconnect"}, 5_000
  end

  test "a successful WS registration notifies the owner with {:carrier_up, _}",
       %{relay_url: relay_url} do
    # Drive the Carrier directly with the test as both `server` and `owner` so the
    # post-register notifications land where we can assert on them. The backoff
    # reset in RelayClient hangs off exactly this {:carrier_up, _} signal.
    {:ok, carrier} =
      Carrier.connect(%{
        relay_url: relay_url,
        handle: @handle,
        secret: @secret,
        server: self(),
        owner: self()
      })

    assert_receive {:registered, _handler}, 5_000
    assert_receive {:set_carrier, ^carrier}, 5_000
    assert_receive {:carrier_up, ^carrier}, 5_000
  end

  # --- helpers ---------------------------------------------------------------

  defp free_port do
    {:ok, lsock} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(lsock)
    :gen_tcp.close(lsock)
    port
  end

  # A raw TCP echo server bound to an ephemeral loopback port. Each accepted
  # connection echoes every byte it receives back to the sender.
  defp start_echo_ingress do
    {:ok, lsock} =
      :gen_tcp.listen(0, [
        :binary,
        ip: {127, 0, 0, 1},
        active: false,
        packet: :raw,
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(lsock)

    {:ok, acceptor} = Task.start_link(fn -> accept_loop(lsock) end)
    on_exit(fn -> if Process.alive?(acceptor), do: Process.exit(acceptor, :kill) end)

    port
  end

  defp accept_loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        spawn(fn -> echo(sock) end)
        accept_loop(lsock)

      {:error, :closed} ->
        :ok
    end
  end

  defp echo(sock) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, data} ->
        :gen_tcp.send(sock, data)
        echo(sock)

      {:error, _} ->
        :ok
    end
  end

  # --- in-test relay /carrier endpoint ---------------------------------------

  defmodule CarrierPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/carrier"} = conn, opts) do
      conn
      |> WebSockAdapter.upgrade(Legend.Federation.RelayClientTest.CarrierMock, opts,
        timeout: 60_000
      )
      |> halt()
    end

    def call(conn, _opts),
      do: conn |> put_resp_content_type("text/plain") |> send_resp(404, "not found")
  end

  # Mirrors Relay.Carrier: registration as the first binary frame, then mux frames.
  defmodule CarrierMock do
    @moduledoc false
    @behaviour WebSock

    alias Legend.Core.Tunnel.Mux
    alias Legend.Core.Tunnel.Mux.Frame

    @impl true
    def init(opts) do
      {:ok,
       %{
         test: Keyword.fetch!(opts, :test_pid),
         handle: Keyword.fetch!(opts, :handle),
         secret: Keyword.fetch!(opts, :secret),
         registered: false,
         buffer: "",
         next_id: 1
       }}
    end

    @impl true
    def handle_in({msg, opcode: :binary}, %{registered: false} = state) do
      with {:ok, %{"handle" => h, "secret" => s}} <- Jason.decode(msg),
           true <- h == state.handle and s == state.secret do
        send(state.test, {:registered, self()})
        {:ok, %{state | registered: true}}
      else
        _ -> {:stop, :normal, 1008, state}
      end
    end

    def handle_in({bin, opcode: :binary}, %{registered: true} = state) do
      case Mux.decode(state.buffer <> bin) do
        {:ok, frames, rest} ->
          Enum.each(frames, fn
            %Frame{type: :data, payload: p} -> send(state.test, {:from_instance, p})
            _ -> :ok
          end)

          {:ok, %{state | buffer: rest}}

        {:error, :frame_too_large} ->
          {:stop, :normal, 1009, state}
      end
    end

    def handle_in(_other, state), do: {:ok, state}

    @impl true
    def handle_info({:device_open, _from}, state) do
      id = state.next_id
      send(state.test, {:stream, id})

      {:push, {:binary, Mux.encode(%Frame{type: :open, stream_id: id, payload: ""})},
       %{state | next_id: id + 1}}
    end

    def handle_info({:device_data, id, bytes}, state) do
      {:push, {:binary, Mux.encode(%Frame{type: :data, stream_id: id, payload: bytes})}, state}
    end

    def handle_info(_msg, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
