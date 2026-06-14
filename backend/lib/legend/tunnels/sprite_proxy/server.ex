defmodule Legend.Tunnels.SpriteProxy.Server do
  @moduledoc """
  De-mux side of the reverse tunnel. Owns the carrier: connects it, links to it
  (trapping exits), reconnects with backoff when it drops (sprite hibernation),
  and bridges carrier mux frames <-> loopback TCP to the local endpoint.

  The `:connector` option (default `Legend.Sprites.Proxy.connect/3`) is the seam
  that lets tests drive reconnection without a live sprite.
  """
  use GenServer
  require Logger
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      target_port: Keyword.fetch!(opts, :target_port),
      sprite: Keyword.fetch!(opts, :sprite),
      control_port: Keyword.fetch!(opts, :control_port),
      connector: Keyword.get(opts, :connector, &default_connect/3),
      reconnect_base_ms: Keyword.get(opts, :reconnect_base_ms, 500),
      out: nil,
      attempt: 0,
      buffer: "",
      streams: %{},
      ids: %{}
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect_carrier(state)}

  @impl true
  def handle_info({:carrier_data, bin}, state) do
    {frames, rest} = Mux.decode(state.buffer <> bin)
    {:noreply, Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)}
  end

  def handle_info({:tcp, sock, data}, state) do
    case Map.get(state.ids, sock) do
      nil ->
        {:noreply, state}

      id ->
        out(state, %Frame{type: :data, stream_id: id, payload: data})
        {:noreply, state}
    end
  end

  def handle_info({:tcp_closed, sock}, state) do
    case Map.get(state.ids, sock) do
      nil ->
        {:noreply, state}

      id ->
        out(state, %Frame{type: :close, stream_id: id, payload: ""})
        {:noreply, drop(state, id)}
    end
  end

  def handle_info({:tcp_error, sock, _reason}, state) do
    case Map.get(state.ids, sock) do
      nil -> {:noreply, state}
      id -> {:noreply, drop(state, id)}
    end
  end

  # The carrier (a linked process) died — reset in-flight streams and reconnect.
  def handle_info({:EXIT, pid, _reason}, %{out: pid} = state) do
    Enum.each(Map.keys(state.streams), &close_sock(state, &1))
    state = %{state | out: nil, streams: %{}, ids: %{}, buffer: ""}
    schedule_reconnect(state)
    {:noreply, %{state | attempt: state.attempt + 1}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, state), do: {:noreply, connect_carrier(state)}

  @impl true
  def terminate(_reason, %{out: carrier}) when is_pid(carrier) do
    # Tear the carrier down with the Server. :shutdown to the (non-trapping)
    # carrier kills it immediately; its socket is closed by the OS.
    if Process.alive?(carrier), do: Process.exit(carrier, :shutdown)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp connect_carrier(state) do
    case state.connector.(state.sprite, state.control_port, self()) do
      {:ok, carrier} ->
        # Link so the carrier's death surfaces as {:EXIT, …} (we trap), and so
        # stopping this Server tears the carrier down too.
        Process.link(carrier)
        %{state | out: carrier, attempt: 0}

      {:error, reason} ->
        Logger.warning("[SpriteProxy.Server] carrier connect failed: #{inspect(reason)}")
        schedule_reconnect(state)
        %{state | attempt: state.attempt + 1}
    end
  end

  defp schedule_reconnect(state) do
    Process.send_after(self(), :reconnect, state.reconnect_base_ms * (state.attempt + 1))
  end

  defp default_connect(sprite, control_port, server),
    do: Legend.Sprites.Proxy.connect(sprite, control_port, server)

  defp handle_frame(%Frame{type: :open, stream_id: id}, state) do
    case :gen_tcp.connect(~c"127.0.0.1", state.target_port, [:binary, active: true, packet: :raw]) do
      {:ok, sock} ->
        %{state | streams: Map.put(state.streams, id, sock), ids: Map.put(state.ids, sock, id)}

      {:error, reason} ->
        out(state, %Frame{type: :close, stream_id: id, payload: ""})
        Logger.warning("tunnel dial: #{inspect(reason)}")
        state
    end
  end

  defp handle_frame(%Frame{type: :data, stream_id: id, payload: p}, state) do
    with sock when not is_nil(sock) <- Map.get(state.streams, id) do
      :gen_tcp.send(sock, p)
    end

    state
  end

  defp handle_frame(%Frame{type: :close, stream_id: id}, state), do: drop(state, id)
  defp handle_frame(%Frame{type: :window}, state), do: state

  defp out(%{out: pid}, %Frame{} = f) when is_pid(pid),
    do: send(pid, {:carrier_out, Mux.encode(f)})

  defp out(_state, _frame), do: :ok

  defp drop(state, id) do
    case Map.get(state.streams, id) do
      nil ->
        state

      sock ->
        :gen_tcp.close(sock)
        %{state | streams: Map.delete(state.streams, id), ids: Map.delete(state.ids, sock)}
    end
  end

  defp close_sock(state, id) do
    case Map.get(state.streams, id) do
      nil -> :ok
      sock -> :gen_tcp.close(sock)
    end
  end
end
