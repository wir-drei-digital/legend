defmodule Legend.Core.Remote do
  @moduledoc """
  Opt-in remote reachability. Reads the `"remote_access"` setting and produces
  endpoint config overrides applied at boot (`Legend.Core.Remote.Boot`). When
  enabled the endpoint binds `0.0.0.0` — the Phase-1 loopback-or-token gate
  (`DeviceAuth` + socket auth) is the network boundary. Off by default
  (loopback-only). Reconfiguring is restart-to-apply.
  """

  alias Legend.Core.Settings

  @key "remote_access"

  @spec config() :: %{enabled: boolean, host: String.t() | nil}
  def config do
    case Settings.get_setting(@key) do
      nil ->
        disabled()

      raw ->
        case Jason.decode(raw) do
          {:ok, %{"enabled" => enabled} = m} ->
            %{enabled: !!enabled, host: blank_to_nil(m["host"])}

          _ ->
            disabled()
        end
    end
  end

  @spec put_config(%{enabled: boolean, host: String.t() | nil}) :: :ok
  def put_config(%{enabled: enabled} = cfg) do
    payload = Jason.encode!(%{enabled: !!enabled, host: blank_to_nil(cfg[:host])})
    Settings.put_setting!(%{key: @key, value: payload})
    :ok
  end

  @spec clear() :: :ok
  def clear do
    Settings.remove_setting(@key)
    :ok
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

  defp disabled, do: %{enabled: false, host: nil}
  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v) when is_binary(v), do: v
  defp blank_to_nil(_), do: nil
end
