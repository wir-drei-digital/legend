defmodule Legend.TestRuntime do
  @moduledoc """
  In-memory `Legend.Runtime` for tests — the second runtime implementation that
  proves the seam. Tests observe calls by subscribing (`subscribe/0`) and drive
  output/exit by sending `{:runtime_output, data}` / `{:runtime_exit, code}`
  directly to the owning SessionServer pid.
  """

  @behaviour Legend.Runtime

  def subscribe, do: Application.put_env(:legend, :test_runtime_listener, self())

  @impl true
  def id, do: "test"

  @impl true
  def start(%Legend.Runtime.CommandSpec{cmd: "fail"}, _opts), do: {:error, "boom"}

  def start(spec, opts) do
    notify({:test_runtime, :start, spec, opts})
    {:ok, %{owner: Map.fetch!(opts, :owner)}}
  end

  @impl true
  def write(_handle, data) do
    notify({:test_runtime, :write, data})
    :ok
  end

  @impl true
  def resize(_handle, cols, rows) do
    notify({:test_runtime, :resize, cols, rows})
    :ok
  end

  @impl true
  def stop(%{owner: owner}) do
    notify({:test_runtime, :stop})
    send(owner, {:runtime_exit, nil})
    :ok
  end

  defp notify(msg) do
    case Application.get_env(:legend, :test_runtime_listener) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
