defmodule LegendWeb.RemoteController do
  @moduledoc """
  `/api/settings/remote-access` — the opt-in toggle. Loopback-only
  (`LegendWeb.LoopbackOnly`): reconfiguring the network boundary requires
  physical possession of the instance, never a remote device token. Two modes,
  both restart-to-apply:

    * `"direct"` (default) — binds `0.0.0.0` at the next boot; `host` is the
      mesh name/IP the instance is reached at (`check_origin`/`url`) and is
      required when enabling so the WebSocket origin check stays meaningful.
    * `"via_relay"` — exposes the instance through a relay; `relay_url`,
      `relay_handle`, and `relay_secret` are all required when enabling.
  """
  use LegendWeb, :controller

  alias Legend.Core.Remote

  def show(conn, _params), do: json(conn, %{data: Remote.config()})

  def update(conn, params) do
    enabled = params["enabled"] == true
    mode = if params["mode"] == "via_relay", do: "via_relay", else: "direct"
    host = params["host"]
    relay = [params["relay_url"], params["relay_handle"], params["relay_secret"]]

    cond do
      enabled and mode == "via_relay" and Enum.any?(relay, &blank?/1) ->
        error(conn, "relay_url, relay_handle and relay_secret are required for via_relay mode")

      enabled and mode == "via_relay" and not Enum.all?(relay, &ctrl_free?/1) ->
        error(conn, "relay fields must not contain control characters")

      enabled and mode == "direct" and blank?(host) ->
        error(conn, "host is required when enabling remote access")

      enabled and mode == "direct" and not ctrl_free?(host) ->
        error(conn, "host must not contain control characters")

      true ->
        :ok =
          Remote.put_config(%{
            enabled: enabled,
            mode: mode,
            host: host,
            relay_url: params["relay_url"],
            relay_handle: params["relay_handle"],
            relay_secret: params["relay_secret"]
          })

        json(conn, %{data: Remote.config(), restart_required: true})
    end
  end

  def delete(conn, _params) do
    :ok = Remote.clear()
    json(conn, %{data: Remote.config()})
  end

  @doc """
  Enumerates this machine's non-loopback IPv4 addresses so the settings UI can
  suggest a reachable mesh host. `suggested` flags the Tailscale CGNAT-range
  address (`100.64.0.0/10`) when present.
  """
  def interfaces(conn, _params) do
    candidates =
      case :inet.getifaddrs() do
        {:ok, ifs} ->
          for {_name, opts} <- ifs,
              {:addr, addr} <- opts,
              # IPv4 only: getifaddrs also yields 8-element IPv6 tuples — guard
              # tuple_size so they neither crash the destructure nor pollute the list.
              tuple_size(addr) == 4,
              {a, b, c, d} = addr,
              a != 127 do
            "#{a}.#{b}.#{c}.#{d}"
          end

        _ ->
          []
      end
      |> Enum.uniq()

    suggested = Enum.find(candidates, &tailscale?/1)
    json(conn, %{data: %{candidates: candidates, suggested: suggested}})
  end

  defp blank?(v), do: v in [nil, ""]
  defp ctrl_free?(v), do: is_binary(v) and v =~ ~r/\A[^[:cntrl:]]+\z/u
  defp error(conn, msg), do: conn |> put_status(422) |> json(%{error: msg})

  defp tailscale?(ip) do
    case String.split(ip, ".") do
      [a, b | _] -> a == "100" and String.to_integer(b) in 64..127
      _ -> false
    end
  end
end
