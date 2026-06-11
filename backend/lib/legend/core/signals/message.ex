defmodule Legend.Core.Signals.Message do
  @moduledoc """
  One envelope on the signal bus: pairwise, exactly one recipient. A session's
  inbox is its rows with `read_at IS NULL`. `from_session_id` nil means the
  human. Session ids are plain uuids (no FK) so the timeline survives session
  deletion as an audit trail.
  """

  use Ash.Resource,
    otp_app: :legend,
    domain: Legend.Core.Signals,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource]

  alias Legend.Core.Signals.Validations.SessionExists

  sqlite do
    table "messages"
    repo Legend.Repo
  end

  json_api do
    type "message"
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(sort: [inserted_at: :desc], limit: 200)
    end

    read :unread_for do
      argument :session_id, :uuid, allow_nil?: false
      filter expr(to_session_id == ^arg(:session_id) and is_nil(read_at))
      prepare build(sort: [inserted_at: :asc])
    end

    create :send do
      accept [:from_session_id, :to_session_id, :kind, :payload, :read_at]
      validate {SessionExists, attribute: :to_session_id}
    end

    # The human-facing JSON:API action: sender is always the human (nil),
    # kind is always :message — nothing forgeable is accepted.
    create :send_as_human do
      accept [:to_session_id, :payload]
      validate {SessionExists, attribute: :to_session_id}
    end

    update :mark_read do
      require_atomic? false
      change set_attribute(:read_at, &DateTime.utc_now/0)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :from_session_id, :uuid, public?: true
    attribute :to_session_id, :uuid, allow_nil?: false, public?: true

    attribute :kind, :atom,
      allow_nil?: false,
      default: :message,
      public?: true,
      constraints: [one_of: [:message, :handoff, :system]]

    attribute :payload, :string,
      allow_nil?: false,
      public?: true,
      constraints: [max_length: 65_536]

    attribute :read_at, :utc_datetime, public?: true

    timestamps public?: true
  end
end
