defmodule Legend.Sprites.ExecTest do
  use ExUnit.Case, async: true

  alias Legend.Core.Runtime.CommandSpec
  alias Legend.Sprites.Exec

  test "exec_url/1 builds the spawn WSS url" do
    assert Exec.exec_url("s1") == "wss://api.sprites.dev/v1/sprites/s1/exec"
  end

  test "attach_url/2 builds the path-based attach url" do
    assert Exec.attach_url("s1", "7") == "wss://api.sprites.dev/v1/sprites/s1/exec/7"
  end

  test "spawn_query/2 repeats cmd per argv element and sets the tty params" do
    spec = %CommandSpec{cmd: "bash", args: ["-lc", "echo hi"]}
    qs = Exec.spawn_query(spec, rows: 30, cols: 100)

    assert qs =~ "path=bash"
    assert qs =~ "tty=true"
    assert qs =~ "stdin=true"
    assert qs =~ "detachable=true"
    assert qs =~ "rows=30"
    assert qs =~ "cols=100"

    # cmd is repeated once per argv element (executable first).
    assert qs =~ "cmd=bash"
    assert qs =~ "cmd=-lc"
    assert qs =~ "cmd=echo+hi"
  end

  test "spawn_query/2 defaults rows/cols when not given" do
    qs = Exec.spawn_query(%CommandSpec{cmd: "sh"}, [])
    assert qs =~ "rows=24"
    assert qs =~ "cols=80"
  end
end
