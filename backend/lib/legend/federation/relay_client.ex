defmodule Legend.Federation.RelayClient do
  @moduledoc """
  Supervises one instance↔relay connection: the `Server` splice plus the live
  `Carrier` WebSocket, wired together and kept connected.

  On start it launches `Legend.Federation.RelayClient.Server` (the relay-side
  splice, pointed at the local relay ingress `target_port`) and then dials a
  `Legend.Federation.RelayClient.Carrier` to the relay's `/carrier`. The Carrier
  registers `{handle, secret}` and, once up, sends `{:set_carrier, pid}` to the
  Server so return traffic flows back out.

  Both children are linked and this process traps exits:

    * the **Carrier** dropping (relay restart, network blip, remote close) triggers a
      backoff reconnect — a fresh Carrier dials, re-registers, and re-points the
      Server via a new `{:set_carrier, …}`. In-flight loopback streams on the Server
      survive a re-point; new return traffic simply flows to the new Carrier.
    * the **Server** dying is fatal (its loopback bookkeeping is gone) — we stop and
      let whatever supervises *this* process restart the whole pair.

  This mirrors `Legend.Tunnels.SpriteProxy.Server`'s carrier-reconnect shape, but
  split out into a dedicated owner because the federation `Server` (unlike the
  sprites one) deliberately does not dial or own its carrier.
  """
  use GenServer
  require Logger

  alias Legend.Federation.RelayClient.Carrier
  alias Legend.Federation.RelayClient.Server

  # Unbounded attempts (a relay will come back), but the delay is capped.
  @max_reconnect_ms 30_000

  @doc """
  Starts the supervisor. Opts (map): `relay_url`, `handle`, `secret`, `target_port`.
  """
  @spec start_link(map()) :: GenServer.on_start()
  def start_link(%{relay_url: _, handle: _, secret: _, target_port: _} = opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    case Server.start_link(%{target_port: opts.target_port}) do
      {:ok, server} ->
        state = %{
          relay_url: opts.relay_url,
          handle: opts.handle,
          secret: opts.secret,
          server: server,
          carrier: nil,
          attempt: 0,
          reconnect_base_ms: Map.get(opts, :reconnect_base_ms, 500)
        }

        {:ok, state, {:continue, :connect}}

      {:error, reason} ->
        {:stop, {:server_start_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect_carrier(state)}

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, connect_carrier(state)}

  # The carrier (linked) died — reconnect with backoff. A fresh carrier re-registers
  # and re-points the server.
  def handle_info({:EXIT, pid, _reason}, %{carrier: pid} = state) do
    schedule_reconnect(state)
    {:noreply, %{state | carrier: nil, attempt: state.attempt + 1}}
  end

  # The server (linked) died — fatal; bubble up so our supervisor restarts the pair.
  def handle_info({:EXIT, pid, reason}, %{server: pid} = state) do
    {:stop, {:server_down, reason}, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    stop_child(state[:carrier])
    stop_child(state[:server])
    :ok
  end

  # Private helpers

  defp connect_carrier(state) do
    opts = %{
      relay_url: state.relay_url,
      handle: state.handle,
      secret: state.secret,
      server: state.server
    }

    case Carrier.connect(opts) do
      {:ok, carrier} ->
        # start_link already linked us; record it and reset backoff. Actual
        # connect/register happens in the carrier's :continue — a failure there
        # surfaces as {:EXIT, carrier, …} and reconnects.
        %{state | carrier: carrier, attempt: 0}

      {:error, reason} ->
        Logger.warning("[RelayClient] carrier start failed: #{inspect(reason)}")
        schedule_reconnect(state)
        %{state | attempt: state.attempt + 1}
    end
  end

  defp schedule_reconnect(state) do
    delay = min(state.reconnect_base_ms * (state.attempt + 1), @max_reconnect_ms)
    Process.send_after(self(), :reconnect, delay)
  end

  defp stop_child(pid) when is_pid(pid) do
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
  end

  defp stop_child(_), do: :ok
end
