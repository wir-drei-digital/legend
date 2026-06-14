defmodule Legend.Runtimes.Test do
  @moduledoc """
  In-memory `Legend.Core.Runtime` for tests — the second runtime implementation that
  proves the seam. Tests observe calls by subscribing (`subscribe/0`) and drive
  output/exit by sending `{:runtime_output, data}` / `{:runtime_exit, code}`
  directly to the owning SessionServer pid.
  """

  @behaviour Legend.Core.Runtime

  def subscribe, do: Application.put_env(:legend, :test_runtime_listener, self())

  def set_capabilities(caps), do: Application.put_env(:legend, :test_runtime_capabilities, caps)
  def set_detect(result), do: Application.put_env(:legend, :test_runtime_detect, result)

  @impl true
  def id, do: "test"

  @impl true
  def start(%Legend.Core.Runtime.CommandSpec{cmd: "fail"}, _opts), do: {:error, "boom"}

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

  @impl true
  def capabilities,
    do:
      Application.get_env(:legend, :test_runtime_capabilities, %{
        provisions?: false,
        library: :path,
        tunnel: nil
      })

  @impl true
  def exec(_handle, %Legend.Core.Runtime.CommandSpec{cmd: "claude", args: ["--version"]}) do
    notify({:test_runtime, :exec, :detect})
    # default: harness "not installed" (status 1) so SessionServer runs install; override per test
    Application.get_env(:legend, :test_runtime_detect, {:ok, %{stdout: "", status: 1}})
  end

  def exec(_handle, spec) do
    notify({:test_runtime, :exec, spec})
    {:ok, %{stdout: "", status: 0}}
  end

  @impl true
  def attach(ref, opts) do
    notify({:test_runtime, :attach, ref})
    {:ok, %{owner: Map.fetch!(opts, :owner), ref: ref}}
  end

  @impl true
  def teardown(ref) do
    notify({:test_runtime, :teardown, ref})
    :ok
  end

  defp notify(msg) do
    case Application.get_env(:legend, :test_runtime_listener) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
