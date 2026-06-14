defmodule Legend.Tunnels.SpriteProxy do
  @moduledoc "Reverse tunnel riding sprites' /proxy WSS. Tunnel id \"sprite_proxy\"."
  @behaviour Legend.Core.Tunnel

  alias Legend.Core.Runtime.CommandSpec
  alias Legend.Sprites.{Client, Exec}
  alias Legend.Tunnels.SpriteProxy.Server

  @control_port 9000
  @data_port 7777
  @bridge_dest "/tmp/legend-bridge"

  @impl true
  def id, do: "sprite_proxy"

  @impl true
  def open(%{session_id: name}) do
    with {:ok, bin} <- read_bridge(),
         :ok <- ensure_bridge(name, bin),
         {:ok, srv} <-
           Server.start_link(
             target_port: endpoint_port(),
             sprite: name,
             control_port: @control_port
           ) do
      # The Server owns the carrier (connects + reconnects internally).
      {:ok, %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{server: srv}}}
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

  # Upload sets mode 0755 at write time; launch over the VERIFIED WSS exec (the
  # REST exec returns the raw stream protocol, not JSON). setsid detaches the
  # bridge so it survives the exec session; pgrep guards against a second launch
  # (e.g. on resume the bridge is already running and the ports are bound).
  defp ensure_bridge(name, bin) do
    with {:ok, _} <- Client.write_file(name, @bridge_dest, bin),
         {:ok, %{status: 0}} <- launch_bridge(name) do
      :ok
    else
      {:ok, %{status: s, stdout: out}} -> {:error, "bridge launch failed (#{s}): #{out}"}
      {:error, reason} -> {:error, "bridge delivery failed: #{reason}"}
    end
  end

  defp launch_bridge(name) do
    cmd =
      "(pgrep -x legend-bridge >/dev/null 2>&1 || " <>
        "setsid #{@bridge_dest} >/tmp/bridge.log 2>&1 &) ; sleep 0.3"

    Exec.run(name, %CommandSpec{cmd: "sh", args: ["-c", cmd], io: :pipes})
  end

  defp endpoint_port, do: LegendWeb.Endpoint.config(:http)[:port]
end
