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

  test "spawn_query/2 uses tty=false for a :pipes spec" do
    qs = Exec.spawn_query(%CommandSpec{cmd: "claude-code-acp", io: :pipes}, [])
    assert qs =~ "tty=false"
    refute qs =~ "tty=true"
    assert qs =~ "stdin=true"
    assert qs =~ "detachable=true"
    assert qs =~ "cmd=claude-code-acp"
  end

  test "spawn_query/2 keeps tty=true for a :pty spec (unchanged)" do
    qs =
      Exec.spawn_query(%CommandSpec{cmd: "bash", args: ["-lc", "echo hi"], io: :pty},
        rows: 30,
        cols: 100
      )

    assert qs =~ "tty=true"
    assert qs =~ "rows=30"
    assert qs =~ "cols=100"
  end

  # SpriteProxy bridge commands (sprite_proxy.ex sh/1) are io: :pipes — confirm they
  # take the tty=false branch (this is the only offline guard for that regression).
  test "spawn_query/2 yields tty=false for an io: :pipes sh bridge spec" do
    qs = Exec.spawn_query(%CommandSpec{cmd: "sh", args: ["-c", "pgrep -f x"], io: :pipes}, [])
    assert qs =~ "tty=false"
  end

  describe "demux_output/2 (pipes mode)" do
    test "0x01 prefix is stdout" do
      assert Exec.demux_output(<<1>> <> "hello", true) == {:stdout, "hello"}
    end

    test "0x02 prefix is stderr" do
      assert Exec.demux_output(<<2>> <> "oops", true) == {:stderr, "oops"}
    end

    test "0x03 prefix is the exit control frame (code as a byte)" do
      assert Exec.demux_output(<<3, 7>>, true) == {:exit, 7}
    end

    test "an empty or unknown-stream frame is ignored" do
      assert Exec.demux_output(<<>>, true) == :ignore
      assert Exec.demux_output(<<9>> <> "x", true) == :ignore
    end
  end

  test "demux_output/2 returns raw stdout in tty mode (no prefix)" do
    assert Exec.demux_output("raw terminal bytes", false) == {:stdout, "raw terminal bytes"}
  end

  test "encode_stdin/2 prefixes 0x00 in pipes mode, passes through in tty mode" do
    assert Exec.encode_stdin("line\n", true) == <<0>> <> "line\n"
    assert Exec.encode_stdin("line\n", false) == "line\n"
  end

  test "collect_run accumulates stdout and stderr into the combined result" do
    parent = self()
    ref = make_ref()
    collector = spawn(fn -> Legend.Sprites.Exec.collect_run(parent, ref, "") end)
    send(collector, {:runtime_output, "OUT"})
    send(collector, {:runtime_stderr, "ERR"})
    send(collector, {:runtime_exit, 3})
    assert_receive {^ref, 3, combined}
    assert combined =~ "OUT"
    assert combined =~ "ERR"
  end

  @tag :live_sprites
  test "live: non-TTY exec demuxes stdout/stderr and reports the exit code" do
    token = Application.get_env(:legend, :sprites_token)

    if token in [nil, ""],
      do: flunk("set SPRITES_TOKEN (app env :sprites_token) for :live_sprites")

    # Legend.Sprites.Client compiles plug: {Req.Test, __MODULE__} in test env.
    # Bypass it by calling the sprites.dev REST API directly with Req (no plug).
    base = "https://api.sprites.dev/v1"
    auth = {:bearer, token}
    name = "lt-pipes-#{System.system_time(:second)}"

    {:ok, %{status: s}} =
      Req.post(base <> "/sprites",
        auth: auth,
        json: %{name: name, url_settings: %{auth: "sprite"}}
      )

    assert s in 200..299
    Process.sleep(3_000)

    spec = %CommandSpec{
      cmd: "sh",
      args: ["-c", "printf OUT; printf ERR 1>&2; exit 5"],
      io: :pipes
    }

    result = Legend.Sprites.Exec.run(name, spec, 60_000)
    Req.delete(base <> "/sprites/#{name}", auth: auth)

    assert {:ok, %{stdout: combined, status: 5}} = result
    assert combined =~ "OUT"
    assert combined =~ "ERR"
  end
end
