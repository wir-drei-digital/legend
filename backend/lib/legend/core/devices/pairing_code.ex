defmodule Legend.Core.Devices.PairingCode do
  @moduledoc """
  A short-lived, single-use code minted on a loopback-trusted screen and redeemed
  by a new device to pair. TTL-bounded; `redeemed_at` enforces single use.
  """
  use Ash.Resource, otp_app: :legend, domain: Legend.Core.Devices, data_layer: AshSqlite.DataLayer

  @ttl_seconds 600

  sqlite do
    table "pairing_codes"
    repo Legend.Repo
  end

  actions do
    defaults [:read]

    create :generate do
      change fn changeset, _ctx ->
        code = :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)

        changeset
        |> Ash.Changeset.force_change_attribute(:code, code)
        |> Ash.Changeset.force_change_attribute(
          :expires_at,
          DateTime.add(DateTime.utc_now(), @ttl_seconds, :second)
        )
      end
    end

    read :by_code do
      argument :code, :string, allow_nil?: false
      get? true
      filter expr(code == ^arg(:code))
    end

    # Atomic single-use claim: the `filter` is appended to the UPDATE's WHERE
    # clause, so the row is claimable only while `redeemed_at IS NULL`. A second
    # claim of an already-redeemed code matches zero rows and Ash surfaces a
    # stale-record error instead of re-stamping — this is the TOCTOU chokepoint.
    update :claim do
      require_atomic? false
      change set_attribute(:redeemed_at, &DateTime.utc_now/0)
      change filter expr(is_nil(redeemed_at))
    end

    # Test-only: backdate expiry to exercise the expired path.
    update :expire_for_test do
      accept [:expires_at]
      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :redeemed_at, :utc_datetime_usec, public?: true
    timestamps()
  end

  identities do
    identity :unique_code, [:code]
  end
end
