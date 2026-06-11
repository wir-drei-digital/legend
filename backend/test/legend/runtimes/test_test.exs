defmodule Legend.Runtimes.TestTest do
  use ExUnit.Case, async: false

  alias Legend.Core.Runtime.CommandSpec

  test "is registered in the test runtime registry" do
    assert {:ok, Legend.Runtimes.Test} = Legend.Core.Runtime.Registry.fetch("test")
  end

  test "start notifies the subscribed test process and returns a handle" do
    Legend.Runtimes.Test.subscribe()
    spec = %CommandSpec{cmd: "claude"}

    assert {:ok, handle} = Legend.Runtimes.Test.start(spec, %{owner: self()})
    assert_receive {:test_runtime, :start, ^spec, %{owner: _}}

    assert :ok = Legend.Runtimes.Test.write(handle, "hello")
    assert_receive {:test_runtime, :write, "hello"}

    assert :ok = Legend.Runtimes.Test.resize(handle, 120, 40)
    assert_receive {:test_runtime, :resize, 120, 40}
  end

  test "start returns an error for the magic cmd \"fail\"" do
    assert {:error, "boom"} =
             Legend.Runtimes.Test.start(%CommandSpec{cmd: "fail"}, %{owner: self()})
  end

  test "stop delivers a runtime_exit to the owner" do
    {:ok, handle} = Legend.Runtimes.Test.start(%CommandSpec{cmd: "claude"}, %{owner: self()})
    assert :ok = Legend.Runtimes.Test.stop(handle)
    assert_receive {:runtime_exit, nil}
  end
end
