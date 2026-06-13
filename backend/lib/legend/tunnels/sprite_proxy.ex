defmodule Legend.Tunnels.SpriteProxy do
  @moduledoc "Reverse tunnel riding sprites' /proxy WSS. Tunnel id \"sprite_proxy\"."
  @behaviour Legend.Core.Tunnel

  alias Legend.Sprites.{Client, Proxy}
  alias Legend.Tunnels.SpriteProxy.Server

  @control_port 9000
  @data_port 7777
  @bridge_dest "/tmp/legend-bridge"

  @impl true
  def id, do: "sprite_proxy"

  @impl true
  def open(%{sprite: name}) do
    with {:ok, bin} <- read_bridge(),
         :ok <- ensure_bridge(name, bin),
         {:ok, srv} <- Server.start_link(target_port: endpoint_port()),
         {:ok, carrier} <- Proxy.connect(name, @control_port, srv) do
      Server.set_out(srv, carrier)

      {:ok,
       %{base_url: "http://127.0.0.1:#{@data_port}", handle: %{carrier: carrier, server: srv}}}
    end
  end

  @impl true
  def close(%{carrier: carrier, server: server}) do
    stop(server)
    stop(carrier)
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

  defp ensure_bridge(name, bin) do
    with {:ok, _} <- Client.write_file(name, @bridge_dest, bin),
         {:ok, _} <- Client.chmod(name, @bridge_dest, "0755"),
         {:ok, _} <-
           Client.exec(name, %{
             command: "sh",
             args: ["-c", "setsid #{@bridge_dest} >/tmp/bridge.log 2>&1 &"]
           }) do
      :ok
    end
  end

  defp endpoint_port, do: LegendWeb.Endpoint.config(:http)[:port]
end
