defmodule Legend.Tunnels.SpriteProxy do
  @moduledoc "Reverse tunnel riding sprites' /proxy WSS. Tunnel id \"sprite_proxy\"."
  @behaviour Legend.Core.Tunnel

  alias Legend.Core.Runtime.CommandSpec
  alias Legend.Sprites.{Client, Exec}
  alias Legend.Tunnels.SpriteProxy.Server

  @control_port 9000
  @data_port 7777
  @ready_timeout_ms 15_000

  @impl true
  def id, do: "sprite_proxy"

  @impl true
  def open(%{session_id: name}) do
    with {:ok, bin} <- read_bridge(),
         :ok <- ensure_bridge(name, bin),
         {:ok, srv} <-
           Server.start_link(
             sprite: name,
             session_id: name,
             control_port: @control_port,
             notify: self()
           ),
         :ok <- await_ready(srv) do
      # The Server owns the carrier + the session-bound listener.
      {:ok, %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{server: srv}}}
    end
  end

  defp await_ready(srv) do
    receive do
      {:tunnel_ready, ^srv} -> :ok
    after
      @ready_timeout_ms ->
        stop(srv)
        {:error, "tunnel carrier readiness timed out after #{@ready_timeout_ms}ms"}
    end
  end

  @impl true
  def close(%{server: server}) do
    stop(server)
    :ok
  end

  defp stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _ -> :ok
  end

  defp read_bridge do
    path = Path.join([:code.priv_dir(:legend), "tunnel", "legend-bridge-x86_64-linux"])

    case File.read(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, e} -> {:error, "bridge binary missing at #{path}: #{:file.format_error(e)}"}
    end
  end

  # Content-address the bridge so a stale binary from a prior Legend version is
  # detected and replaced. The launch path embeds the hash, so `pgrep -f <dest>`
  # tells us whether OUR exact version is already running (resume fast-path); any
  # other bridge is killed (they share the fixed 9000/7777).
  defp ensure_bridge(name, bin) do
    sha = :crypto.hash(:sha256, bin) |> Base.encode16(case: :lower) |> binary_part(0, 8)
    dest = "/tmp/legend-bridge-#{sha}"

    # `^` anchors the match to the START of the command line, so it matches the
    # bridge process (argv = "<dest>") but NOT the `sh -c "pgrep …<dest>…"` wrapper
    # running this very check (its command line starts with "sh").
    case Exec.run(name, sh("pgrep -f '^#{dest}' >/dev/null 2>&1")) do
      {:ok, %{status: 0}} -> :ok
      _ -> deliver_and_launch(name, dest, bin)
    end
  end

  defp deliver_and_launch(name, dest, bin) do
    with {:ok, _} <- Client.write_file(name, dest, bin),
         {:ok, %{status: 0}} <- Exec.run(name, sh(launch_cmd(dest))) do
      :ok
    else
      {:ok, %{status: s, stdout: out}} -> {:error, "bridge launch failed (#{s}): #{out}"}
      {:error, reason} -> {:error, "bridge delivery failed: #{reason}"}
    end
  end

  defp launch_cmd(dest) do
    # `^` anchors to the START of the command line so pkill reaps stale bridge
    # processes (argv begins with "/tmp/legend-bridge-") WITHOUT killing the
    # `sh -c "…setsid /tmp/legend-bridge-…"` wrapper running this script (its
    # command line begins with "sh", not "/tmp"). An unanchored pattern would
    # SIGTERM that wrapper before `setsid` runs and the bridge would never launch.
    "pkill -f '^/tmp/legend-bridge-' >/dev/null 2>&1 || true ; " <>
      "setsid #{dest} >/tmp/bridge.log 2>&1 & ; sleep 0.3"
  end

  defp sh(cmd), do: %CommandSpec{cmd: "sh", args: ["-c", cmd], io: :pipes}
end
