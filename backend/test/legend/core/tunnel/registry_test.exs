defmodule Legend.Core.Tunnel.RegistryTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Tunnel.Registry

  defmodule FakeTunnel do
    @behaviour Legend.Core.Tunnel
    def id, do: "fake"
    def open(_), do: {:ok, %{base_url: "http://127.0.0.1:1", handle: nil}}
    def close(_), do: :ok
  end

  setup do
    prev = Application.get_env(:legend, :tunnels)
    Application.put_env(:legend, :tunnels, [FakeTunnel])
    on_exit(fn -> Application.put_env(:legend, :tunnels, prev) end)
  end

  test "fetch/1 returns the module for a known id" do
    assert {:ok, FakeTunnel} = Registry.fetch("fake")
  end

  test "fetch/1 returns :error for an unknown id" do
    assert :error = Registry.fetch("nope")
  end

  test "list/0 returns configured modules" do
    assert [FakeTunnel] = Registry.list()
  end
end
