defmodule LegendWeb.PairController do
  @moduledoc """
  Public pairing redeem — the sole pre-auth human write. Validates a single-use,
  TTL-bounded code and mints a device token. Rate-limited at the router/edge in a
  later phase; single-use + short TTL bound abuse here.
  """
  use LegendWeb, :controller

  require Logger

  alias Legend.Core.Devices
  alias LegendWeb.DeviceToken

  def redeem(conn, %{"code" => code} = params) when is_binary(code) do
    attrs = %{name: params["name"], public_key: params["public_key"]}

    case Devices.redeem_pairing_code(code, attrs) do
      {:ok, device} ->
        Devices.audit!(%{device_id: device.id, session_id: nil, action: "pair"})

        json(conn, %{
          token: DeviceToken.sign(device.id),
          device: %{id: device.id, name: device.name}
        })

      {:error, reason} ->
        Logger.info("pairing redeem rejected: #{reason}")
        conn |> put_status(422) |> json(%{error: "pairing failed"})
    end
  end

  def redeem(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "missing required param: code"})
end
