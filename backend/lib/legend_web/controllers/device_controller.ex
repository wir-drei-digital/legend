defmodule LegendWeb.DeviceController do
  @moduledoc """
  Device management — generate pairing codes, list devices, revoke, audit.
  Loopback-only (`LegendWeb.LoopbackOnly`): management/enrollment requires
  physical possession of the instance, never a remote device token. Revoking
  disconnects the device's live sockets.
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
        # device_id = the ACTOR (loopback => nil); the revoked target id is kept
        # in session_id (free string column) so the trail still says what was
        # revoked — no schema change.
        Devices.audit!(%{
          device_id: actor_id(Map.get(conn.assigns, :device)),
          session_id: id,
          action: "revoke"
        })

        # Drop any live sockets this device holds.
        LegendWeb.Endpoint.broadcast("device:#{id}", "disconnect", %{})
        json(conn, %{data: device_view(revoked)})

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "device not found"})

      {:error, _} ->
        conn |> put_status(500) |> json(%{error: "internal error"})
    end
  end

  def audit(conn, _params) do
    json(conn, %{data: Enum.map(Devices.list_audit!(), &audit_view/1)})
  end

  # The audit actor: a paired device records its id; the loopback/local actor
  # (`:local`) records nil per the AuditEvent contract.
  defp actor_id(%Legend.Core.Devices.Device{id: id}), do: id
  defp actor_id(_), do: nil

  defp device_view(d) do
    %{
      id: d.id,
      name: d.name,
      paired_at: d.paired_at,
      last_seen_at: d.last_seen_at,
      revoked_at: d.revoked_at
    }
  end

  defp audit_view(e) do
    %{
      id: e.id,
      device_id: e.device_id,
      session_id: e.session_id,
      action: e.action,
      at: e.inserted_at
    }
  end
end
