defmodule LegendWeb.AshActor do
  @moduledoc """
  Threads the device assigned by `LegendWeb.DeviceAuth` into the Ash actor so the
  device-gated JSON:API (session lifecycle) can attribute remote interventions in
  the audit trail. Runs after `DeviceAuth` in the Ash forward pipeline.

  A loopback caller (`:local`) leaves the actor unset, so its lifecycle actions
  audit `device_id: nil`. The actor lands in `conn.private.ash.actor`, where
  AshJsonApi reads it (`Ash.PlugHelpers.get_actor/1`).
  """
  import Ash.PlugHelpers, only: [set_actor: 2]

  alias Legend.Core.Devices.Device

  def init(opts), do: opts

  def call(%{assigns: %{device: %Device{} = device}} = conn, _opts), do: set_actor(conn, device)
  def call(conn, _opts), do: conn
end
