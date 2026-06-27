defmodule Legend.Federation.RelayClient.Server do
  @moduledoc """
  The splice between a relay carrier and the local relay ingress.

  The relay opens a mux stream (toward this instance) per remote device
  connection. This server receives those frames as `{:carrier_data, bin}`,
  and for each `OPEN` dials `127.0.0.1:target_port` — the
  `LegendWeb.RelayIngressEndpoint` loopback port (Task 1) — so the relayed
  traffic is stamped `via_relay` and the Part-1 trust rule applies. `DATA`
  frames are spliced both ways; `CLOSE` tears the stream down. Return traffic
  is emitted as `{:carrier_out, Mux.encode(frame)}` to the carrier.

  This is `Legend.Tunnels.SpriteProxy.Server` minus the inbound listener: the
  relay (not us) opens streams, so there is no Bandit listener to start and no
  carrier dialer here. The live carrier is wired in by Task 3 after it connects,
  via a `{:set_carrier, pid}` message.
  """
  use GenServer
  require Logger
  alias Legend.Core.Tunnel.Mux
  alias Legend.Core.Tunnel.Mux.Frame

  # Mirror SpriteProxy.Server's per-carrier stream cap so a misbehaving relay
  # can't open unbounded loopback sockets.
  @default_max_streams 256

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      target_port: fetch!(opts, :target_port),
      carrier: get(opts, :carrier, nil),
      max_streams: get(opts, :max_streams, @default_max_streams),
      buffer: "",
      streams: %{},
      ids: %{}
    }

    {:ok, state}
  end

  # Task 3 wires the live carrier after it connects (and can re-point it on
  # reconnect). Re-pointing leaves in-flight streams intact; new return traffic
  # simply flows to the new carrier.
  @impl true
  def handle_info({:set_carrier, pid}, state) when is_pid(pid) do
    {:noreply, %{state | carrier: pid}}
  end

  def handle_info({:carrier_data, bin}, state) do
    case Mux.decode(state.buffer <> bin) do
      {:ok, frames, rest} ->
        {:noreply, Enum.reduce(frames, %{state | buffer: rest}, &handle_frame/2)}

      {:error, :frame_too_large} ->
        Logger.warning("[RelayClient.Server] oversized mux frame — dropping all streams")
        {:noreply, drop_all(state)}
    end
  end

  def handle_info({:tcp, sock, data}, state) do
    case Map.get(state.ids, sock) do
      nil ->
        {:noreply, state}

      id ->
        out(state, %Frame{type: :data, stream_id: id, payload: data})
        :inet.setopts(sock, active: :once)
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

  # Defensive catch-all: a stray/unexpected message must not crash the splice and
  # drop in-flight streams. Mirrors the `Carrier`'s own catch-all.
  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_frame(%Frame{type: :open, stream_id: id}, state) do
    cond do
      Map.has_key?(state.streams, id) ->
        state

      map_size(state.streams) >= state.max_streams ->
        out(state, %Frame{type: :close, stream_id: id, payload: ""})

        Logger.warning(
          "[RelayClient.Server] stream cap #{state.max_streams} reached — refusing #{id}"
        )

        state

      true ->
        case :gen_tcp.connect(~c"127.0.0.1", state.target_port, [
               :binary,
               active: :once,
               packet: :raw
             ]) do
          {:ok, sock} ->
            %{
              state
              | streams: Map.put(state.streams, id, sock),
                ids: Map.put(state.ids, sock, id)
            }

          {:error, reason} ->
            out(state, %Frame{type: :close, stream_id: id, payload: ""})
            Logger.warning("[RelayClient.Server] ingress dial failed: #{inspect(reason)}")
            state
        end
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

  defp out(%{carrier: pid}, %Frame{} = f) when is_pid(pid),
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

  defp drop_all(state) do
    state = Enum.reduce(Map.keys(state.streams), state, fn id, acc -> drop(acc, id) end)
    %{state | buffer: ""}
  end

  defp fetch!(opts, key) when is_map(opts), do: Map.fetch!(opts, key)
  defp fetch!(opts, key), do: Keyword.fetch!(opts, key)

  defp get(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp get(opts, key, default), do: Keyword.get(opts, key, default)
end
