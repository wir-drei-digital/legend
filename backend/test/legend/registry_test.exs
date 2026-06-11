defmodule Legend.RegistryTest do
  use ExUnit.Case, async: true

  defmodule FakeHarness do
    @behaviour Legend.Harness

    @impl true
    def definition do
      %Legend.Harness.Definition{
        id: "fake",
        name: "Fake",
        description: "test harness",
        kind: :terminal
      }
    end
  end

  defmodule FakeRuntime do
    @behaviour Legend.Runtime

    @impl true
    def id, do: "fake_rt"
    @impl true
    def start(_spec, _opts), do: {:error, "not a real runtime"}
    @impl true
    def write(_handle, _data), do: :ok
    @impl true
    def resize(_handle, _cols, _rows), do: :ok
    @impl true
    def stop(_handle), do: :ok
  end

  describe "Legend.Harness.Registry" do
    setup do
      original = Application.get_env(:legend, :harnesses, [])
      Application.put_env(:legend, :harnesses, [FakeHarness])
      on_exit(fn -> Application.put_env(:legend, :harnesses, original) end)
    end

    test "list/0 returns definitions" do
      assert [%Legend.Harness.Definition{id: "fake", kind: :terminal}] =
               Legend.Harness.Registry.list()
    end

    test "fetch/1 finds a module by string id" do
      assert {:ok, FakeHarness} = Legend.Harness.Registry.fetch("fake")
      assert :error = Legend.Harness.Registry.fetch("nope")
    end
  end

  describe "Legend.Runtime.Registry" do
    setup do
      original = Application.get_env(:legend, :runtimes, [])
      Application.put_env(:legend, :runtimes, [FakeRuntime])
      on_exit(fn -> Application.put_env(:legend, :runtimes, original) end)
    end

    test "fetch/1 finds a module by string id" do
      assert {:ok, FakeRuntime} = Legend.Runtime.Registry.fetch("fake_rt")
      assert :error = Legend.Runtime.Registry.fetch("nope")
    end
  end

  test "CommandSpec defaults" do
    spec = %Legend.Runtime.CommandSpec{cmd: "echo"}
    assert spec.args == []
    assert spec.env == %{}
    assert spec.io == :pty
  end
end
