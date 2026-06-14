defmodule Legend.Tunnels.Test do
  @moduledoc "In-memory tunnel double for tests. Records open/close to the listener pid."
  @behaviour Legend.Core.Tunnel

  @impl true
  def id, do: "test_tunnel"

  @impl true
  def open(target) do
    notify({:test_tunnel, :open, target})
    {:ok, %{base_url: "http://127.0.0.1:9999", handle: %{target: target}}}
  end

  @impl true
  def close(handle) do
    notify({:test_tunnel, :close, handle})
    :ok
  end

  defp notify(msg) do
    case Application.get_env(:legend, :test_runtime_listener) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
