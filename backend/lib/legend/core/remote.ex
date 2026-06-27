defmodule Legend.Core.Remote do
  @moduledoc """
  Opt-in remote reachability. Reads the `"remote_access"` setting and produces
  endpoint config overrides applied at boot (`Legend.Core.Remote.Boot`). Two
  modes:

    * `"direct"` (default) — the main endpoint binds `0.0.0.0` for mesh/LAN
      reach; the Phase-1 loopback-or-token gate (`DeviceAuth` + socket auth) is
      the network boundary, with `host` driving `check_origin`/`url`.
    * `"via_relay"` — the main endpoint stays loopback; the `RelayIngressEndpoint`
      + `Legend.Federation.RelayClient` carrier expose the instance through a
      relay (`relay_url`/`relay_handle`/`relay_secret`). Relayed traffic is
      stamped `via_relay` so it never inherits loopback trust.

  Off by default (loopback-only). Reconfiguring is restart-to-apply.
  """

  alias Legend.Core.Settings

  @key "remote_access"

  @type t :: %{
          enabled: boolean,
          mode: String.t(),
          host: String.t() | nil,
          relay_url: String.t() | nil,
          relay_handle: String.t() | nil,
          relay_secret: String.t() | nil
        }

  @spec config() :: t()
  def config do
    case Settings.get_setting(@key) do
      nil ->
        disabled()

      raw ->
        case Jason.decode(raw) do
          {:ok, %{"enabled" => enabled} = m} -> build_config(!!enabled, m)
          _ -> disabled()
        end
    end
  end

  # "via_relay" needs the relay triple; "direct" (default) needs a host. Either
  # way a partial/malformed config fails safe to disabled — the network boundary
  # never half-opens.
  defp build_config(false, _m), do: disabled()

  defp build_config(true, m) do
    case mode_of(m["mode"]) do
      "via_relay" ->
        relay_url = blank_to_nil(m["relay_url"])
        relay_handle = blank_to_nil(m["relay_handle"])
        relay_secret = blank_to_nil(m["relay_secret"])

        if relay_url && relay_handle && relay_secret do
          %{
            enabled: true,
            mode: "via_relay",
            host: blank_to_nil(m["host"]),
            relay_url: relay_url,
            relay_handle: relay_handle,
            relay_secret: relay_secret
          }
        else
          disabled()
        end

      "direct" ->
        case blank_to_nil(m["host"]) do
          nil -> disabled()
          host -> %{disabled() | enabled: true, mode: "direct", host: host}
        end
    end
  end

  @spec put_config(map) :: :ok
  def put_config(%{enabled: enabled} = cfg) do
    payload =
      Jason.encode!(%{
        enabled: !!enabled,
        mode: mode_of(cfg[:mode]),
        host: blank_to_nil(cfg[:host]),
        relay_url: blank_to_nil(cfg[:relay_url]),
        relay_handle: blank_to_nil(cfg[:relay_handle]),
        relay_secret: blank_to_nil(cfg[:relay_secret])
      })

    Settings.put_setting!(%{key: @key, value: payload})
    :ok
  end

  defp mode_of("via_relay"), do: "via_relay"
  defp mode_of(_), do: "direct"

  @spec clear() :: :ok
  def clear do
    Settings.remove_setting(@key)
    :ok
  end

  @doc """
  Whether the relay ingress endpoint (and its federation carrier) should boot:
  remote access is on, the persisted mode is `"via_relay"`, and the relay triple
  is present. `config/0` already fails partial via_relay configs safe to
  disabled, so the field checks here are belt-and-suspenders.
  """
  @spec relay_ingress_enabled?() :: boolean()
  def relay_ingress_enabled? do
    case config() do
      %{
        enabled: true,
        mode: "via_relay",
        relay_url: url,
        relay_handle: handle,
        relay_secret: secret
      } ->
        is_binary(url) and is_binary(handle) and is_binary(secret)

      _ ->
        false
    end
  end

  @doc """
  Pure: merge remote overrides onto the endpoint's existing config. Enabled →
  bind `0.0.0.0` (port preserved), extend `check_origin` and set `url` host for
  the configured host. Disabled → `existing` unchanged.
  """
  @spec endpoint_overrides(keyword, map) :: keyword
  def endpoint_overrides(existing, %{enabled: false}), do: existing

  def endpoint_overrides(existing, %{enabled: true, host: host}) do
    http = existing |> Keyword.get(:http, []) |> Keyword.put(:ip, {0, 0, 0, 0})

    existing
    |> Keyword.put(:http, http)
    |> Keyword.put(:force_ssl, false)
    |> maybe_put_host(host)
  end

  defp maybe_put_host(cfg, nil), do: cfg

  defp maybe_put_host(cfg, host) do
    # check_origin may be a list (prod) or `false` (dev convenience). When
    # enabling remote we always want origin checking, so fall back to a
    # localhost baseline rather than appending to a non-list.
    origins =
      case Keyword.get(cfg, :check_origin) do
        list when is_list(list) -> list
        _ -> ["//localhost"]
      end

    cfg
    |> Keyword.put(:check_origin, Enum.uniq(origins ++ ["//#{host}"]))
    |> Keyword.update(:url, [host: host], &Keyword.put(&1, :host, host))
  end

  defp disabled,
    do: %{
      enabled: false,
      mode: "direct",
      host: nil,
      relay_url: nil,
      relay_handle: nil,
      relay_secret: nil
    }

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
  defp blank_to_nil(_), do: nil
end
