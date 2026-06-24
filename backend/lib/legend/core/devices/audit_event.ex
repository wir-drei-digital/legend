defmodule Legend.Core.Devices.AuditEvent do
  @moduledoc """
  Append-only trail of remote interventions at control-action granularity (NOT
  raw keystrokes). `device_id` nil = a loopback/local actor.
  """
  use Ash.Resource, otp_app: :legend, domain: Legend.Core.Devices, data_layer: AshSqlite.DataLayer

  sqlite do
    table "audit_events"
    repo Legend.Repo
  end

  actions do
    defaults [:read]

    create :record do
      accept [:device_id, :session_id, :action]
    end

    read :list do
      prepare build(sort: [inserted_at: :desc])
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :device_id, :string, public?: true
    attribute :session_id, :string, public?: true
    attribute :action, :string, allow_nil?: false, public?: true
    timestamps()
  end
end
