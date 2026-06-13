defmodule Legend.Sprites.Proxy do
  @moduledoc """
  Carrier WebSocket client for the sprites.dev `/proxy` endpoint.

  Opens a WSS connection to `wss://api.sprites.dev/v1/sprites/<name>/proxy`,
  sends an init frame to bind the sprite's reverse tunnel to a local TCP port,
  waits for `{"status":"connected"}`, then acts as a transparent relay:

  - Inbound BINARY frames from the carrier → forwarded to `server` pid as
    `{:carrier_data, binary}`.
  - `{:carrier_out, binary}` messages sent to this process → encoded as a
    BINARY frame and written to the carrier socket.

  ## Connect/retry
  A small exponential backoff (5 attempts × 200 ms base) is applied before
  giving up. This lets a freshly-launched local bridge finish binding its
  listen port before the proxy tries to send data to it.

  ## Limitations (UNVERIFIED)
  The Mint.WebSocket connect/relay loop compiles and follows the hexdocs API
  exactly, but has NOT been exercised against a live sprites.dev endpoint.
  Treat as unverified until integration tests run in an environment that has a
  valid SPRITES_TOKEN and a live sprite.
  """

  use GenServer

  require Logger

  @base_url "wss://api.sprites.dev/v1/sprites"
  @connect_host "api.sprites.dev"
  @connect_port 443

  # Public helpers (pure — tested offline)

  @doc "Returns the WSS URL for a named sprite's proxy endpoint."
  @spec proxy_url(String.t()) :: String.t()
  def proxy_url(name), do: "#{@base_url}/#{name}/proxy"

  @doc """
  Returns a JSON string instructing the sprite to tunnel to 127.0.0.1:<port>.

  NOTE: Jason serialises map keys alphabetically, so the output is
  `{"port":<n>,"host":"127.0.0.1"}` — key order is not protocol-significant.
  """
  @spec init_message(non_neg_integer()) :: String.t()
  def init_message(port), do: Jason.encode!(%{host: "127.0.0.1", port: port})

  # GenServer API

  @doc "Starts a linked carrier WebSocket GenServer for `name` tunnelling to `target_port`."
  @spec connect(String.t(), non_neg_integer(), pid()) :: {:ok, pid()} | {:error, term()}
  def connect(name, target_port, server) do
    GenServer.start_link(__MODULE__, {name, target_port, server})
  end

  @doc "Stops the carrier cleanly."
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.stop(pid, :normal)

  # GenServer callbacks

  @impl true
  def init({name, target_port, server}) do
    state = %{
      name: name,
      target_port: target_port,
      server: server,
      conn: nil,
      websocket: nil,
      ref: nil,
      # Track whether we've received the {"status":"connected"} ack
      connected: false,
      # Retry state
      attempt: 0,
      max_attempts: 5,
      retry_base_ms: 200
    }

    {:ok, state, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    case token() do
      nil ->
        Logger.error("[Sprites.Proxy] SPRITES_TOKEN is not set — cannot open carrier")
        {:stop, {:shutdown, :no_token}, state}

      tkn ->
        do_open(state, tkn)
    end
  end

  # Mux server pushes bytes out the carrier via plain message or cast.
  @impl true
  def handle_info({:carrier_out, bin}, state) do
    handle_cast({:carrier_out, bin}, state)
  end

  # Carrier sends data back to us (Mint socket messages).
  def handle_info(message, %{conn: conn, websocket: ws, ref: ref} = state)
      when not is_nil(conn) and not is_nil(ws) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn2, responses} ->
        state2 = %{state | conn: conn2}
        handle_responses(responses, ref, state2)

      {:error, conn2, reason, _partial} ->
        Logger.error("[Sprites.Proxy] stream error: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | conn: conn2}}

      :unknown ->
        {:noreply, state}
    end
  end

  # Before the websocket is set up — silently drop unknown messages.
  def handle_info(_message, state), do: {:noreply, state}

  # Mux server wants to push bytes out the carrier.
  @impl true
  def handle_cast({:carrier_out, bin}, %{conn: conn, websocket: ws, ref: ref} = state) do
    case Mint.WebSocket.encode(ws, {:binary, bin}) do
      {:ok, ws2, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn2} ->
            {:noreply, %{state | conn: conn2, websocket: ws2}}

          {:error, conn2, reason} ->
            Logger.error("[Sprites.Proxy] send error: #{inspect(reason)}")
            {:stop, {:shutdown, reason}, %{state | conn: conn2, websocket: ws2}}
        end

      {:error, ws2, reason} ->
        Logger.error("[Sprites.Proxy] encode error: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | websocket: ws2}}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when not is_nil(conn) do
    # Best-effort close frame; ignore errors
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Private helpers

  defp do_open(%{name: name, target_port: target_port, attempt: attempt} = state, tkn) do
    path = "/v1/sprites/#{name}/proxy"
    headers = [{"Authorization", "Bearer #{tkn}"}]

    with {:ok, conn} <- Mint.HTTP.connect(:https, @connect_host, @connect_port),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:wss, conn, path, headers) do
      # Now wait synchronously for the HTTP upgrade response before continuing.
      # We do this by receiving directly so we can gate on the connected ack.
      case await_upgrade(conn, ref) do
        {:ok, conn2, status, resp_headers} ->
          case Mint.WebSocket.new(conn2, ref, status, resp_headers) do
            {:ok, conn3, ws} ->
              # Send the init frame
              case send_text(conn3, ws, ref, init_message(target_port)) do
                {:ok, conn4, ws2} ->
                  {:noreply, %{state | conn: conn4, websocket: ws2, ref: ref, connected: false}}

                {:error, conn4, reason} ->
                  Logger.error("[Sprites.Proxy] init send failed: #{inspect(reason)}")
                  maybe_retry(state, reason, conn4, tkn)
              end

            {:error, conn3, reason} ->
              Logger.error("[Sprites.Proxy] WebSocket.new failed: #{inspect(reason)}")
              maybe_retry(state, reason, conn3, tkn)
          end

        {:error, reason} ->
          Logger.error("[Sprites.Proxy] upgrade response error: #{inspect(reason)}")
          maybe_retry(state, reason, nil, tkn)
      end
    else
      {:error, reason} ->
        Logger.warning(
          "[Sprites.Proxy] connect/upgrade failed (attempt #{attempt + 1}): #{inspect(reason)}"
        )

        maybe_retry(state, reason, nil, tkn)

      {:error, conn, reason} ->
        Logger.warning(
          "[Sprites.Proxy] connect/upgrade failed (attempt #{attempt + 1}): #{inspect(reason)}"
        )

        Mint.HTTP.close(conn)
        maybe_retry(state, reason, nil, tkn)
    end
  end

  defp maybe_retry(%{attempt: attempt, max_attempts: max} = state, _reason, conn, tkn)
       when attempt < max - 1 do
    if conn, do: Mint.HTTP.close(conn)
    delay = state.retry_base_ms * (attempt + 1)
    Logger.info("[Sprites.Proxy] retrying in #{delay}ms (attempt #{attempt + 1}/#{max})")
    Process.sleep(delay)
    do_open(%{state | attempt: attempt + 1, conn: nil, websocket: nil, ref: nil}, tkn)
  end

  defp maybe_retry(%{max_attempts: max} = state, reason, conn, _tkn) do
    if conn, do: Mint.HTTP.close(conn)
    Logger.error("[Sprites.Proxy] exhausted #{max} attempts, giving up: #{inspect(reason)}")
    {:stop, {:shutdown, reason}, %{state | conn: nil}}
  end

  # Receive the HTTP/1.1 upgrade response synchronously (100 ms per recv attempt, 10 tries).
  defp await_upgrade(conn, ref) do
    do_await_upgrade(conn, ref, [], 10)
  end

  defp do_await_upgrade(_conn, _ref, _acc, 0) do
    {:error, :upgrade_timeout}
  end

  defp do_await_upgrade(conn, ref, acc, retries) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn2, responses} ->
            acc2 = acc ++ responses
            # Check if we have all three parts: status, headers, done
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
      100 ->
        do_await_upgrade(conn, ref, acc, retries - 1)
    end
  end

  defp send_text(conn, ws, ref, text) do
    case Mint.WebSocket.encode(ws, {:text, text}) do
      {:ok, ws2, data} ->
        case Mint.WebSocket.stream_request_body(conn, ref, data) do
          {:ok, conn2} -> {:ok, conn2, ws2}
          {:error, conn2, reason} -> {:error, conn2, reason}
        end

      {:error, _ws2, reason} ->
        {:error, conn, reason}
    end
  end

  defp handle_responses([], _ref, state), do: {:noreply, state}

  defp handle_responses([{:data, ref, raw} | rest], ref, state) do
    case Mint.WebSocket.decode(state.websocket, raw) do
      {:ok, ws2, frames} ->
        state2 = %{state | websocket: ws2}
        state3 = Enum.reduce(frames, state2, &dispatch_frame(&1, &2))
        handle_responses(rest, ref, state3)

      {:error, ws2, reason} ->
        Logger.error("[Sprites.Proxy] decode error: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, %{state | websocket: ws2}}
    end
  end

  defp handle_responses([{:close, _ref2, _code, _reason} | _rest], _ref, state) do
    Logger.info("[Sprites.Proxy] carrier closed by remote")
    {:stop, {:shutdown, :remote_close}, state}
  end

  defp handle_responses([_other | rest], ref, state) do
    handle_responses(rest, ref, state)
  end

  defp dispatch_frame({:text, json}, state) do
    # Gate on the {"status":"connected"} ack before forwarding binary data
    case Jason.decode(json) do
      {:ok, %{"status" => "connected"}} ->
        Logger.info("[Sprites.Proxy] carrier connected for sprite #{state.name}")
        %{state | connected: true}

      {:ok, other} ->
        Logger.debug("[Sprites.Proxy] text frame (ignored): #{inspect(other)}")
        state

      {:error, _} ->
        Logger.debug("[Sprites.Proxy] non-JSON text frame (ignored): #{inspect(json)}")
        state
    end
  end

  defp dispatch_frame({:binary, bin}, %{connected: true, server: server} = state) do
    send(server, {:carrier_data, bin})
    state
  end

  defp dispatch_frame({:binary, _bin}, state) do
    # Not yet connected — discard
    Logger.warning("[Sprites.Proxy] binary frame before connected ack — dropping")
    state
  end

  defp dispatch_frame({:ping, _}, state), do: state
  defp dispatch_frame({:pong, _}, state), do: state
  defp dispatch_frame({:close, _, _}, state), do: state

  defp token, do: Application.get_env(:legend, :sprites_token)
end
