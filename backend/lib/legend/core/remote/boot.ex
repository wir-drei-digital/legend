defmodule Legend.Core.Remote.Boot do
  @moduledoc """
  Applies the `remote_access` config to the right endpoint BEFORE that endpoint's
  child starts. Runs sync in `start_link` (the `Library.Seeder` pattern) and
  returns `:ignore` — no process stays alive; it only mutates `Application` env,
  it does NOT start the carrier/ingress processes (those are supervised by
  `Legend.Federation.Supervisor`). Disabled = no-op (loopback).

    * `"direct"` mode binds `LegendWeb.Endpoint` to `0.0.0.0` (host →
      `check_origin`/`url`).
    * `"via_relay"` mode leaves the main endpoint loopback and instead points
      `LegendWeb.RelayIngressEndpoint`'s `check_origin`/`url` at
      `<relay_handle>.<relay-host>` so relay-routed WebSocket origins pass.
  """
  require Logger

  alias Legend.Core.Remote

  def start_link(_opts) do
    :ok = apply!()
    :ignore
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :transient
    }
  end

  @spec apply!() :: :ok
  def apply! do
    config = Remote.config()

    cond do
      not config.enabled -> :ok
      config.mode == "via_relay" -> apply_via_relay!(config)
      true -> apply_direct!(config)
    end

    :ok
  end

  defp apply_direct!(config) do
    existing = Application.get_env(:legend, LegendWeb.Endpoint, [])

    Application.put_env(
      :legend,
      LegendWeb.Endpoint,
      Remote.endpoint_overrides(existing, config)
    )

    Logger.info(
      "[remote] remote access ENABLED (direct) — endpoint bound 0.0.0.0 (host: #{config.host})"
    )
  end

  defp apply_via_relay!(config) do
    vhost = "#{config.relay_handle}.#{relay_host(config.relay_url)}"
    existing = Application.get_env(:legend, LegendWeb.RelayIngressEndpoint, [])

    updated =
      existing
      |> Keyword.put(:check_origin, ["//#{vhost}"])
      |> Keyword.update(:url, [host: vhost], &Keyword.put(&1, :host, vhost))

    Application.put_env(:legend, LegendWeb.RelayIngressEndpoint, updated)

    Logger.info(
      "[remote] remote access ENABLED (via relay) — ingress origin //#{vhost} (relay: #{config.relay_url})"
    )
  end

  # The relay's own host (the carrier dials this); the instance is reached at the
  # <handle>. subdomain of it.
  defp relay_host(relay_url) do
    case URI.parse(relay_url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> relay_url
    end
  end
end
