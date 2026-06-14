defmodule Legend.Core.RuntimeTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Runtime

  test "capabilities/1 returns defaults for a runtime that doesn't export capabilities/0" do
    assert Runtime.capabilities(Legend.Runtimes.LocalPty) ==
             %{provisions?: false, library: :path, tunnel: nil}
  end

  defmodule CapRuntime do
    @behaviour Legend.Core.Runtime
    def id, do: "cap"
    def start(_s, _o), do: {:ok, %{}}
    def write(_h, _d), do: :ok
    def resize(_h, _c, _r), do: :ok
    def stop(_h), do: :ok
    def capabilities, do: %{provisions?: true, library: :api, tunnel: "sprite_proxy"}
  end

  test "capabilities/1 merges a runtime's declared capabilities over the defaults" do
    assert Runtime.capabilities(CapRuntime) ==
             %{provisions?: true, library: :api, tunnel: "sprite_proxy"}
  end
end
