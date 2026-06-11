defmodule Legend.Core.Settings.Setting do
  @moduledoc "A persisted key-value setting. Keys are well-known strings (e.g. \"library_path\")."

  use Ash.Resource,
    otp_app: :legend,
    domain: Legend.Core.Settings,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "settings"
    repo Legend.Repo
  end

  actions do
    defaults [:read]

    create :put do
      accept [:key, :value]
      upsert? true
      upsert_fields [:value]
    end

    destroy :destroy do
      primary? true
    end
  end

  attributes do
    attribute :key, :string, primary_key?: true, allow_nil?: false, public?: true
    attribute :value, :string, allow_nil?: false, public?: true
    timestamps()
  end
end
