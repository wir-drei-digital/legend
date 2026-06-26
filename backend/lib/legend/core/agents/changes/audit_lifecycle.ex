defmodule Legend.Core.Agents.Changes.AuditLifecycle do
  @moduledoc """
  Best-effort, remote-only audit of a session lifecycle action
  (start/resume/transport/delete).

  After the primary transaction commits, records an `AuditEvent` attributing the
  Ash actor — the device threaded in by `LegendWeb.AshActor`. Remote-only, like
  the channel audit (`SessionChannel.audit_control/2`): a loopback/local/internal
  caller (no device actor) writes NO row, since the trail records remote
  interventions, not local activity. The audit runs post-commit and is wrapped so
  a failed audit insert can never roll back or fail the session operation.

  Pass the external lifecycle name as the `:action` option, e.g.
  `change {AuditLifecycle, action: "transport"}` for the `:set_transport` action.
  """
  use Ash.Resource.Change

  require Logger

  alias Legend.Core.Devices
  alias Legend.Core.Devices.Device

  @impl true
  def change(changeset, opts, context) do
    action = Keyword.fetch!(opts, :action)
    device_id = device_id(context.actor)

    Ash.Changeset.after_transaction(changeset, fn changeset, result ->
      case result do
        {:ok, record} -> record_audit(device_id, session_id(changeset, record), action)
        _ -> :ok
      end

      result
    end)
  end

  defp device_id(%Device{id: id}), do: id
  defp device_id(_), do: nil

  defp session_id(changeset, record) do
    (is_map(record) && Map.get(record, :id)) || changeset.data.id
  end

  # Remote-only: a loopback/internal/MCP-spawned actor (device_id nil) writes no row.
  defp record_audit(nil, _session_id, _action), do: :ok

  defp record_audit(device_id, session_id, action) do
    Devices.audit!(%{device_id: device_id, session_id: session_id, action: action})
  rescue
    error ->
      Logger.warning("session lifecycle audit (#{action}) failed: #{Exception.message(error)}")
      :error
  end
end
