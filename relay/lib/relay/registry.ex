defmodule Relay.Registry do
  @moduledoc "In-memory handle => carrier-pid map. Per-handle secret allowlist + DNS-label validation. Auto-clears on carrier death."
  use GenServer

  @label ~r/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec handle_valid?(String.t()) :: boolean
  def handle_valid?(handle) when is_binary(handle), do: Regex.match?(@label, handle)
  def handle_valid?(_), do: false

  @spec register(String.t(), String.t(), pid()) ::
          :ok | {:error, :bad_handle | :bad_secret | :taken}
  def register(handle, secret, pid),
    do: GenServer.call(__MODULE__, {:register, handle, secret, pid})

  @spec lookup(String.t()) :: {:ok, pid()} | :error
  def lookup(handle), do: GenServer.call(__MODULE__, {:lookup, handle})

  @impl true
  def init(_), do: {:ok, %{by_handle: %{}, by_ref: %{}}}

  @impl true
  def handle_call({:register, handle, secret, pid}, _from, state) do
    cond do
      not handle_valid?(handle) ->
        {:reply, {:error, :bad_handle}, state}

      secret != allowed_secret(handle) ->
        {:reply, {:error, :bad_secret}, state}

      Map.has_key?(state.by_handle, handle) ->
        {:reply, {:error, :taken}, state}

      true ->
        ref = Process.monitor(pid)

        {:reply, :ok,
         %{
           state
           | by_handle: Map.put(state.by_handle, handle, pid),
             by_ref: Map.put(state.by_ref, ref, handle)
         }}
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
      {nil, _} ->
        {:noreply, state}

      {handle, by_ref} ->
        {:noreply, %{state | by_handle: Map.delete(state.by_handle, handle), by_ref: by_ref}}
    end
  end

  # nil for an unknown handle => secret comparison fails with {:error, :bad_secret}
  defp allowed_secret(handle), do: Map.get(Application.get_env(:relay, :handles, %{}), handle)
end
