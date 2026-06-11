defmodule Legend.Agents.Session do
  @moduledoc """
  An agent session: one harness composed with one runtime. The record mirrors
  the live SessionServer process; lifecycle actions keep the two in lockstep.
  """

  use Ash.Resource,
    otp_app: :legend,
    domain: Legend.Agents,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource]

  alias Legend.Agents.Validations.KnownRegistryId

  sqlite do
    table "sessions"
    repo Legend.Repo
  end

  json_api do
    type "session"
  end

  actions do
    defaults [:read]

    read :list do
      prepare build(sort: [inserted_at: :desc])
    end

    create :start do
      accept [:name, :harness_id, :runtime_id, :cwd]

      validate {KnownRegistryId, attribute: :harness_id, registry: Legend.Harness.Registry}
      validate {KnownRegistryId, attribute: :runtime_id, registry: Legend.Runtime.Registry}

      # after_transaction (not after_action): SessionServer.start_session/1
      # writes to the DB from the server process, which must run OUTSIDE the
      # enclosing create transaction.
      change after_transaction(fn
               _changeset, {:ok, session}, _context ->
                 case Legend.Agents.SessionServer.start_session(session) do
                   {:ok, _pid} ->
                     {:ok, Legend.Agents.get_session!(session.id)}

                   :ignore ->
                     # init marked the record :failed before returning :ignore
                     {:ok, Legend.Agents.get_session!(session.id)}

                   {:error, reason} ->
                     {:ok, Legend.Agents.fail_session!(session, %{error: inspect(reason)})}
                 end

               _changeset, {:error, _} = error, _context ->
                 error
             end)
    end

    # require_atomic? false on all updates: AshSqlite has no atomic-update
    # support, and Ash 3 defaults to requiring it.
    update :mark_running do
      require_atomic? false
      change set_attribute(:status, :running)
      change set_attribute(:started_at, &DateTime.utc_now/0)
    end

    update :finish do
      require_atomic? false
      accept [:exit_code]
      change set_attribute(:status, :exited)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    update :fail do
      require_atomic? false
      accept [:error]
      change set_attribute(:status, :failed)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change before_action(fn changeset, _context ->
               Legend.Agents.SessionServer.ensure_stopped(changeset.data.id)
               changeset
             end)

      change after_transaction(fn
               _changeset, {:ok, _} = result, _context ->
                 Legend.Agents.Notifications.sessions_changed()
                 result

               _changeset, other, _context ->
                 other
             end)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, public?: true
    attribute :harness_id, :string, allow_nil?: false, public?: true
    attribute :runtime_id, :string, allow_nil?: false, default: "local_pty", public?: true
    attribute :cwd, :string, public?: true, default: &Legend.Agents.Session.default_cwd/0

    attribute :status, :atom,
      allow_nil?: false,
      default: :starting,
      public?: true,
      constraints: [one_of: [:starting, :running, :exited, :failed]]

    attribute :exit_code, :integer, public?: true
    attribute :error, :string, public?: true
    attribute :started_at, :utc_datetime, public?: true
    attribute :ended_at, :utc_datetime, public?: true

    timestamps public?: true
  end

  @doc false
  def default_cwd, do: System.user_home!()
end
