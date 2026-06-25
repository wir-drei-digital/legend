defmodule LegendWeb.RemoteController do
  @moduledoc """
  `/api/settings/remote-access` — the opt-in toggle. Device-gated. Enabling binds
  `0.0.0.0` at the next boot (restart-to-apply); `host` is the mesh name/IP the
  instance is reached at (for `check_origin`/`url`). A host is required when
  enabling so the WebSocket origin check stays meaningful.
  """
  use LegendWeb, :controller

  alias Legend.Core.Remote

  def show(conn, _params), do: json(conn, %{data: Remote.config()})

  def update(conn, params) do
    enabled = params["enabled"] == true
    host = params["host"]

    cond do
      enabled and blank?(host) ->
        error(conn, "host is required when enabling remote access")

      enabled and not valid_host?(host) ->
        error(conn, "host must not contain control characters")

      true ->
        :ok = Remote.put_config(%{enabled: enabled, host: host})
        json(conn, %{data: Remote.config(), restart_required: true})
    end
  end

  def delete(conn, _params) do
    :ok = Remote.clear()
    json(conn, %{data: Remote.config()})
  end

  defp blank?(v), do: v in [nil, ""]
  defp valid_host?(v), do: is_binary(v) and v =~ ~r/\A[^[:cntrl:]]+\z/u
  defp error(conn, msg), do: conn |> put_status(422) |> json(%{error: msg})
end
