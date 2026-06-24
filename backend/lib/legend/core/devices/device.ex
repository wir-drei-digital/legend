defmodule Legend.Core.Devices.Device do
  @moduledoc """
  A paired device authorized to reach this instance remotely. The credential is
  a stateless `Phoenix.Token` carrying this id (minted at pairing); revocation is
  the server-side `revoked_at` check. `public_key` is reserved for the future
  zero-knowledge relay and is unused today.
  """
  use Ash.Resource, otp_app: :legend, domain: Legend.Core.Devices, data_layer: AshSqlite.DataLayer

  sqlite do
    table "devices"
    repo Legend.Repo
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(sort: [inserted_at: :desc])
    end

    create :pair do
      accept [:name, :public_key]

      validate match(:name, ~r/\A[^[:cntrl:]]*\z/u) do
        message "must not contain control characters"
        where present(:name)
      end

      validate string_length(:name, max: 120) do
        where present(:name)
      end

      change set_attribute(:paired_at, &DateTime.utc_now/0)
    end

    update :touch do
      require_atomic? false
      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
    end

    update :revoke do
      require_atomic? false
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true
    # Reserved for the future zero-knowledge relay; unused in v1.
    attribute :public_key, :string, public?: true

    attribute :paired_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_seen_at, :utc_datetime_usec, public?: true
    attribute :revoked_at, :utc_datetime_usec, public?: true

    timestamps()
  end
end
