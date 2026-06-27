defmodule Legend.Federation.RelayClient.Carrier do
  @moduledoc """
  Outbound `Mint.WebSocket` carrier from this instance to a relay's `/carrier`.

  Modeled on `Legend.Sprites.Proxy` (the proven sprites reverse-tunnel carrier),
  it dials the relay over WS/WSS, sends the **registration JSON** `{handle, secret}`
  as the FIRST BINARY frame (the relay's `Relay.Carrier` reads registration as a
  binary message), then splices mux frames transparently:

    * inbound BINARY frames from the relay -> `send(server, {:carrier_data, binary})`;
    * `{:carrier_out, binary}` messages to this process -> encoded as a BINARY frame
      and written to the carrier socket.

  After a successful upgrade+registration it tells the `server`
  (`Legend.Federation.RelayClient.Server`) who its carrier is via
  `{:set_carrier, self()}`, so the splice can emit return traffic back here.

  Unlike `Sprites.Proxy` there is no `{"status":"connected"}` ack to gate on — the
  relay starts muxing immediately — so binary frames forward as soon as the socket
  is up. Reconnect-with-backoff is owned by the parent `Legend.Federation.RelayClient`:
  this process simply exits (linked) when the connection drops or fails to open, and
  the parent dials a fresh carrier.

  ## Limitations
  Exercised by `test/legend/federation/relay_client_test.exs` (`--only integration`)
  against a real Bandit `/carrier` WS server. Not yet run against the deployed relay
  app over WSS.
  """

  use GenServer
  require Logger

  # GenServer API

  @doc """
  Starts a linked carrier WebSocket GenServer.

  Opts (map): `relay_url` (e.g. `"wss://relay.example.com"`), `handle`, `secret`,
  `server` (the `RelayClient.Server` pid to splice with), and optional `owner` (the
  `RelayClient` pid notified with `{:carrier_up, self()}` once registration succeeds).
  """
  @spec connect(map()) :: {:ok, pid()} | {:error, term()}
  def connect(%{relay_url: _, handle: _, secret: _, server: _} = opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Stops the carrier cleanly."
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.stop(pid, :normal)

  # Pure helper (tested offline)

  @doc """
  Resolves the relay URL into the `{mint_scheme, ws_scheme, host, port, path}`
  tuple the Mint connect/upgrade calls need. The path is the relay's base path
  with `/carrier` appended.

  ## Examples

      iex> Legend.Federation.RelayClient.Carrier.carrier_target("ws://127.0.0.1:4000")
      {:http, :ws, "127.0.0.1", 4000, "/carrier"}

      iex> Legend.Federation.RelayClient.Carrier.carrier_target("wss://relay.example.com/base/")
      {:https, :wss, "relay.example.com", 443, "/base/carrier"}
  """
  @spec carrier_target(String.t()) ::
          {:http | :https, :ws | :wss, String.t(), :inet.port_number(), String.t()}
  def carrier_target(relay_url) do
    uri = URI.parse(relay_url)
    {mint_scheme, ws_scheme, default_port} = schemes(uri.scheme)
    base = uri.path |> to_string() |> String.trim_trailing("/")
    {mint_scheme, ws_scheme, uri.host, uri.port || default_port, base <> "/carrier"}
  end

  defp schemes("wss"), do: {:https, :wss, 443}
  defp schemes("https"), do: {:https, :wss, 443}
  defp schemes(_ws), do: {:http, :ws, 80}

  # GenServer callbacks

  @impl true
  def init(opts) do
    state = %{
      relay_url: opts.relay_url,
      handle: opts.handle,
      secret: opts.secret,
      server: opts.server,
      owner: Map.get(opts, :owner),
      conn: nil,
      websocket: nil,
      ref: nil
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state), do: do_open(state)

  # The mux server pushes bytes out the carrier via a plain message.
  @impl true
  def handle_info({:carrier_out, bin}, state) do
    handle_cast({:carrier_out, bin}, state)
  end

  # A decoded WS close frame signalled remote shutdown — exit so the parent reconnects.
  def handle_info(:carrier_closed, state) do
    {:stop, {:shutdown, :remote_close}, state}
  end

  # Carrier sends data back to us (Mint socket messages).
  def handle_info(message, %{conn: conn, websocket: ws, ref: ref} = state)
      when not is_nil(conn) and not is_nil(ws) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn2, responses} ->
        handle_responses(responses, ref, %{state | conn: conn2})

      {:error, conn2, reason, _partial} ->
        Logger.warning("[RelayClient.Carrier] stream error: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | conn: conn2}}

      :unknown ->
        {:noreply, state}
    end
  end

  # Before the websocket is set up — silently drop unknown messages.
  def handle_info(_message, state), do: {:noreply, state}

  # The mux server wants to push bytes out the carrier.
  @impl true
  def handle_cast({:carrier_out, bin}, %{conn: conn, websocket: ws, ref: ref} = state) do
    case Mint.WebSocket.encode(ws, {:binary, bin}) do
      {:ok, ws2, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn2} ->
            {:noreply, %{state | conn: conn2, websocket: ws2}}

          {:error, conn2, reason} ->
            Logger.warning("[RelayClient.Carrier] send error: #{inspect(reason)}")
            {:stop, {:shutdown, reason}, %{state | conn: conn2, websocket: ws2}}
        end

      {:error, ws2, reason} ->
        Logger.warning("[RelayClient.Carrier] encode error: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | websocket: ws2}}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

  defp do_open(state) do
    {mint_scheme, ws_scheme, host, port, path} = carrier_target(state.relay_url)

    with {:ok, conn} <- Mint.HTTP.connect(mint_scheme, host, port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []),
         {:ok, conn, status, resp_headers} <- await_upgrade(conn, ref),
         {:ok, conn, ws} <- Mint.WebSocket.new(conn, ref, status, resp_headers),
         {:ok, conn, ws} <- send_registration(conn, ws, ref, state) do
      # Registered: wire ourselves to the splice so return traffic flows back here,
      # and tell the owner the dial succeeded so it can reset its reconnect backoff.
      send(state.server, {:set_carrier, self()})
      if state.owner, do: send(state.owner, {:carrier_up, self()})
      {:noreply, %{state | conn: conn, websocket: ws, ref: ref}}
    else
      {:error, reason} ->
        Logger.warning("[RelayClient.Carrier] open failed: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, state}

      {:error, conn, reason} ->
        Logger.warning("[RelayClient.Carrier] open failed: #{inspect(reason)}")
        if conn, do: Mint.HTTP.close(conn)
        {:stop, {:shutdown, reason}, state}
    end
  end

  # The registration JSON is sent as a BINARY frame (Relay.Carrier reads the first
  # binary message as `{handle, secret}`).
  defp send_registration(conn, ws, ref, state) do
    payload = Jason.encode!(%{handle: state.handle, secret: state.secret})

    case Mint.WebSocket.encode(ws, {:binary, payload}) do
      {:ok, ws2, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn2} -> {:ok, conn2, ws2}
          {:error, conn2, reason} -> {:error, conn2, reason}
        end

      {:error, _ws2, reason} ->
        {:error, conn, reason}
    end
  end

  # Receive the HTTP/1.1 upgrade response synchronously (100 ms per recv, 10 tries).
  defp await_upgrade(conn, ref), do: do_await_upgrade(conn, ref, [], 10)

  defp do_await_upgrade(_conn, _ref, _acc, 0), do: {:error, :upgrade_timeout}

  defp do_await_upgrade(conn, ref, acc, retries) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn2, responses} ->
            acc2 = acc ++ responses

            has_status = Enum.any?(acc2, &match?({:status, ^ref, _}, &1))
            has_headers = Enum.any?(acc2, &match?({:headers, ^ref, _}, &1))
            has_done = Enum.any?(acc2, &match?({:done, ^ref}, &1))

            if has_status and has_headers and has_done do
              {:status, _, status} = Enum.find(acc2, &match?({:status, ^ref, _}, &1))
              {:headers, _, resp_headers} = Enum.find(acc2, &match?({:headers, ^ref, _}, &1))
              {:ok, conn2, status, resp_headers}
            else
              do_await_upgrade(conn2, ref, acc2, retries - 1)
            end

          {:error, _conn2, reason, _} ->
            {:error, reason}

          :unknown ->
            do_await_upgrade(conn, ref, acc, retries - 1)
        end
    after
      100 -> do_await_upgrade(conn, ref, acc, retries - 1)
    end
  end

  defp handle_responses([], _ref, state), do: {:noreply, state}

  defp handle_responses([{:data, ref, raw} | rest], ref, state) do
    case Mint.WebSocket.decode(state.websocket, raw) do
      {:ok, ws2, frames} ->
        state2 = Enum.reduce(frames, %{state | websocket: ws2}, &dispatch_frame/2)
        handle_responses(rest, ref, state2)

      {:error, ws2, reason} ->
        Logger.warning("[RelayClient.Carrier] decode error: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | websocket: ws2}}
    end
  end

  defp handle_responses([{:close, _ref2, _code, _reason} | _rest], _ref, state) do
    Logger.info("[RelayClient.Carrier] carrier closed by remote")
    {:stop, {:shutdown, :remote_close}, state}
  end

  defp handle_responses([_other | rest], ref, state) do
    handle_responses(rest, ref, state)
  end

  defp dispatch_frame({:binary, bin}, %{server: server} = state) do
    send(server, {:carrier_data, bin})
    state
  end

  defp dispatch_frame({:close, _code, _reason}, state) do
    Logger.info("[RelayClient.Carrier] decoded WS close frame — stopping")
    send(self(), :carrier_closed)
    state
  end

  defp dispatch_frame(_frame, state), do: state
end
