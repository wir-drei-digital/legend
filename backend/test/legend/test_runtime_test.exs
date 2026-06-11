defmodule Legend.TestRuntimeTest do
  use ExUnit.Case, async: false

  alias Legend.Runtime.CommandSpec

  test "is registered in the test runtime registry" do
    assert {:ok, Legend.TestRuntime} = Legend.Runtime.Registry.fetch("test")
  end

  test "start notifies the subscribed test process and returns a handle" do
    Legend.TestRuntime.subscribe()
    spec = %CommandSpec{cmd: "claude"}

    assert {:ok, handle} = Legend.TestRuntime.start(spec, %{owner: self()})
    assert_receive {:test_runtime, :start, ^spec, %{owner: _}}

    assert :ok = Legend.TestRuntime.write(handle, "hello")
    assert_receive {:test_runtime, :write, "hello"}

    assert :ok = Legend.TestRuntime.resize(handle, 120, 40)
    assert_receive {:test_runtime, :resize, 120, 40}
  end

  test "start returns an error for the magic cmd \"fail\"" do
    assert {:error, "boom"} =
             Legend.TestRuntime.start(%CommandSpec{cmd: "fail"}, %{owner: self()})
  end

  test "stop delivers a runtime_exit to the owner" do
    {:ok, handle} = Legend.TestRuntime.start(%CommandSpec{cmd: "claude"}, %{owner: self()})
    assert :ok = Legend.TestRuntime.stop(handle)
    assert_receive {:runtime_exit, nil}
  end
end
