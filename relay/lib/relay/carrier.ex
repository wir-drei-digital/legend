defmodule Relay.Carrier do
  @moduledoc """
  The mux hub for one registered instance, run as a WebSock handler. The instance
  dials this over WSS and registers `{handle, secret}` (first binary message);
  thereafter both sides exchange mux frames as WS binary messages. The relay OPENs
  one stream per device connection toward the instance and routes instance→device
  DATA/CLOSE frames to the owning device handler process.
  """
  @behaviour WebSock
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
      {nil, _} ->
        state

      {dpid, streams} ->
        send(dpid, {:to_device_close})
        %{state | streams: streams}
    end
  end

  defp route_from_instance(_other, state), do: state
end
