defmodule Legend.Runtimes.LocalPtyTest do
  use ExUnit.Case, async: false

  alias Legend.Core.Runtime.CommandSpec
  alias Legend.Runtimes.LocalPty

  test "id" do
    assert LocalPty.id() == "local_pty"
  end

  test "spawns a real PTY process, round-trips IO, resizes, and exits" do
    spec = %CommandSpec{cmd: "cat", args: [], env: %{"TERM" => "xterm-256color"}}
    assert {:ok, handle} = LocalPty.start(spec, %{owner: self(), cwd: "/tmp", rows: 24, cols: 80})

    :ok = LocalPty.write(handle, "hello\n")
    assert collect_output() =~ "hello"

    # Resize must not crash the process.
    :ok = LocalPty.resize(handle, 120, 40)

    :ok = LocalPty.stop(handle)
    assert_receive {:runtime_exit, _code_or_nil}, 10_000
  end

  test "missing executable returns an error without spawning" do
    spec = %CommandSpec{cmd: "definitely-not-a-real-binary-xyz", args: []}
    assert {:error, message} = LocalPty.start(spec, %{owner: self()})
    assert message =~ "definitely-not-a-real-binary-xyz"
  end

  test "process exiting on its own delivers its exit code" do
    spec = %CommandSpec{cmd: "sh", args: ["-c", "exit 3"]}
    assert {:ok, _handle} = LocalPty.start(spec, %{owner: self()})
    assert_receive {:runtime_exit, 3}, 10_000
  end

  defp collect_output(acc \\ "") do
    receive do
      {:runtime_output, data} ->
        acc = acc <> data
        if acc =~ "hello", do: acc, else: collect_output(acc)
    after
      5_000 -> flunk("no output received, got so far: #{inspect(acc)}")
    end
  end
end
