defmodule Relay.IntegrationTest do
  @moduledoc """
  Gated end-to-end spike — run with `mix test --only integration`.

  ## Harness: Option A (real carrier listener + a raw WS mock instance)

  This boots the REAL carrier Bandit listener on an ephemeral port and connects a
  mock instance over a hand-rolled `:gen_tcp` WebSocket client (no WS client dep is
  available — bandit/websock_adapter are server-side only). The mock instance
  registers `{handle, secret}` exactly as `Legend.Federation.RelayClient` will in
  Part 2b. The device side is driven through the carrier message protocol — the
  exact messages `Relay.Device` emits (`{:open, pid}` / `{:stream_data, id, bytes}`)
  and consumes (`{:to_device, bytes}`) — because the real device handler needs a TLS
  socket (`:ssl.connection_information/2` for SNI) that has no plaintext equivalent.

  So this proves the composition that has no unit coverage: Registry + the real
  Carrier WebSock handler running under Bandit + Mux framing over a real socket +
  the device splice routing, with a genuine byte round-trip in BOTH directions.
  Real TLS device byte-splicing (cert handling) is the manual live-acceptance.
  """
  use ExUnit.Case, async: false
  import Bitwise

  alias Relay.Mux
  alias Relay.Mux.Frame

  @moduletag :integration

  setup do
    prev = Application.get_env(:relay, :handles)
    on_exit(fn -> Application.put_env(:relay, :handles, prev) end)
    Application.put_env(:relay, :handles, %{"laptop" => "s3cret"})
    start_supervised!(Relay.Registry)
    port = free_port()
    start_supervised!({Bandit, plug: Relay.CarrierPlug, scheme: :http, port: port})
    %{port: port}
  end

  test "device bytes round-trip through the relay to a registered instance", %{port: port} do
    # 1. Mock instance dials /carrier and registers {handle, secret}.
    sock = ws_connect(port)
    ws_send_binary(sock, Jason.encode!(%{handle: "laptop", secret: "s3cret"}))
    carrier = await_carrier("laptop")

    # 2. Device opens a stream on that carrier (what Relay.Device.handle_connection does).
    send(carrier, {:open, self()})
    assert_receive {:stream, id}, 2_000
    # The instance sees an OPEN mux frame arrive over the real WS.
    assert {:ok, [%Frame{type: :open, stream_id: ^id}], ""} = Mux.decode(ws_recv_binary(sock))

    # 3. device -> instance: device bytes become a DATA mux frame at the instance.
    send(carrier, {:stream_data, id, "ping"})

    assert {:ok, [%Frame{type: :data, stream_id: ^id, payload: "ping"}], ""} =
             Mux.decode(ws_recv_binary(sock))

    # 4. instance -> device: the instance echoes a DATA frame; it routes back to the device.
    ws_send_binary(sock, Mux.encode(%Frame{type: :data, stream_id: id, payload: "pong"}))
    assert_receive {:to_device, "pong"}, 2_000

    # 5. instance closes the stream; the device handler is told to close.
    ws_send_binary(sock, Mux.encode(%Frame{type: :close, stream_id: id}))
    assert_receive {:to_device_close}, 2_000

    :gen_tcp.close(sock)
  end

  # --- helpers ---------------------------------------------------------------

  defp free_port do
    {:ok, lsock} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(lsock)
    :gen_tcp.close(lsock)
    port
  end

  defp await_carrier(handle, attempts \\ 100)
  defp await_carrier(handle, 0), do: flunk("carrier #{inspect(handle)} never registered")

  defp await_carrier(handle, attempts) do
    case Relay.Registry.lookup(handle) do
      {:ok, pid} ->
        pid

      :error ->
        Process.sleep(20)
        await_carrier(handle, attempts - 1)
    end
  end

  # Minimal RFC 6455 client. Frames we send are masked (client→server MUST mask);
  # frames we read from the server are unmasked, but we de-mask defensively.
  defp ws_connect(port) do
    {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    req =
      "GET /carrier HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{key}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n\r\n"

    :ok = :gen_tcp.send(sock, req)
    resp = recv_http_response(sock, "")
    assert resp =~ "101", "expected a WebSocket upgrade, got: #{inspect(resp)}"
    sock
  end

  defp recv_http_response(sock, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, more} = :gen_tcp.recv(sock, 0, 5_000)
      recv_http_response(sock, acc <> more)
    end
  end

  defp ws_send_binary(sock, payload) do
    len = byte_size(payload)
    mask = :crypto.strong_rand_bytes(4)

    header =
      cond do
        len <= 125 -> <<0x82, 1::1, len::7>>
        len <= 0xFFFF -> <<0x82, 1::1, 126::7, len::16>>
        true -> <<0x82, 1::1, 127::7, len::64>>
      end

    :ok = :gen_tcp.send(sock, header <> mask <> mask_payload(payload, mask))
  end

  defp ws_recv_binary(sock, timeout \\ 5_000) do
    {:ok, <<_fin_op, len_byte>>} = :gen_tcp.recv(sock, 2, timeout)
    masked? = (len_byte &&& 0x80) != 0

    len =
      case len_byte &&& 0x7F do
        126 ->
          {:ok, <<l::16>>} = :gen_tcp.recv(sock, 2, timeout)
          l

        127 ->
          {:ok, <<l::64>>} = :gen_tcp.recv(sock, 8, timeout)
          l

        l ->
          l
      end

    mask =
      if masked? do
        {:ok, m} = :gen_tcp.recv(sock, 4, timeout)
        m
      end

    payload = if len > 0, do: recv_exact(sock, len, timeout), else: ""
    if mask, do: mask_payload(payload, mask), else: payload
  end

  defp recv_exact(sock, len, timeout) do
    {:ok, bytes} = :gen_tcp.recv(sock, len, timeout)
    bytes
  end

  defp mask_payload(payload, mask) do
    :crypto.exor(payload, mask_stream(mask, byte_size(payload)))
  end

  defp mask_stream(mask, len) do
    :binary.copy(mask, div(len, 4)) <> binary_part(mask, 0, rem(len, 4))
  end
end
