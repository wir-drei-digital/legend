defmodule Legend.Runtimes.TestHostApi do
  @moduledoc """
  In-memory `Legend.Core.Runtime` double that executes on the host (no tunnel)
  yet speaks the library over MCP (`library: :api`). Exists to exercise the
  spawn-gate's fail-closed host classification: such a runtime must be treated
  as host (not spawnable from a remote caller) even though it isn't `:path`.
  """
  @behaviour Legend.Core.Runtime

  @impl true
  def id, do: "test_host_api"

  @impl true
  def capabilities, do: %{provisions?: false, library: :api, tunnel: nil}

  @impl true
  def start(_spec, opts), do: {:ok, %{owner: Map.fetch!(opts, :owner)}}

  @impl true
  def write(_handle, _data), do: :ok

  @impl true
  def resize(_handle, _cols, _rows), do: :ok

  @impl true
  def stop(_handle), do: :ok
end
