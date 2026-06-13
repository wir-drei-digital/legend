defmodule Legend.Tunnels.SpriteProxy.Server do
  @moduledoc "De-mux side of the reverse tunnel: carrier frames <-> loopback TCP to the local endpoint."
  use GenServer
  require Logger
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Set the pid that receives outbound {:carrier_out, bin} frames (the carrier)."
  def set_out(srv, pid), do: GenServer.cast(srv, {:set_out, pid})

  @impl true
  def init(opts) do
    {:ok,
     %{
       target_port: Keyword.fetch!(opts, :target_port),
       out: nil,
       buffer: "",
       streams: %{},
       ids: %{}
     }}
  end

  @impl true
  def handle_cast({:set_out, pid}, state), do: {:noreply, %{state | out: pid}}

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

  defp handle_frame(%Frame{type: :open, stream_id: id}, state) do
    case :gen_tcp.connect(~c"127.0.0.1", state.target_port, [
           :binary,
           active: true,
           packet: :raw
         ]) do
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
end
