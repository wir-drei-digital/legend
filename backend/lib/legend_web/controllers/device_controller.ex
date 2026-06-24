defmodule LegendWeb.DeviceController do
  @moduledoc """
  Device management — generate pairing codes, list devices, revoke. Device-gated
  by `DeviceAuth` (loopback or a paired device); in practice driven from the
  loopback-trusted instance. Revoking disconnects the device's live sockets.
  """
  use LegendWeb, :controller

  alias Legend.Core.Devices

  def create_pair_code(conn, _params) do
    code = Devices.generate_pairing_code!()
    json(conn, %{code: code.code, expires_at: code.expires_at})
  end

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Devices.list_devices!(), &device_view/1)})
  end

  def revoke(conn, %{"id" => id}) do
    case Devices.get_device(id) do
      {:ok, device} ->
        revoked = Devices.revoke_device!(device)
        Devices.audit!(%{device_id: id, session_id: nil, action: "revoke"})
        # Drop any live sockets this device holds.
        LegendWeb.Endpoint.broadcast("device:#{id}", "disconnect", %{})
        json(conn, %{data: device_view(revoked)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "device not found"})

      {:error, _} ->
        conn |> put_status(500) |> json(%{error: "internal error"})
    end
  end

  defp device_view(d) do
    %{
      id: d.id,
      name: d.name,
      paired_at: d.paired_at,
      last_seen_at: d.last_seen_at,
      revoked_at: d.revoked_at
    }
  end
end
