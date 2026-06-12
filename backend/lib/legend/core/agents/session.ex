defmodule Legend.Core.Agents.Session do
  @moduledoc """
  An agent session: one harness composed with one runtime. The record mirrors
  the live SessionServer process; lifecycle actions keep the two in lockstep.
  """

  use Ash.Resource,
    otp_app: :legend,
    domain: Legend.Core.Agents,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshJsonApi.Resource]

  import Ash.Resource.Validation.Builtins

  alias Legend.Core.Agents.Validations.KnownRegistryId

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

    read :by_token do
      argument :token, :string, allow_nil?: false, sensitive?: true
      get? true
      filter expr(mcp_token == ^arg(:token))
    end

    create :start do
      accept [:name, :harness_id, :runtime_id, :cwd, :spawned_by_session_id, :instructions]

      validate {KnownRegistryId, attribute: :harness_id, registry: Legend.Core.Harness.Registry}
      validate {KnownRegistryId, attribute: :runtime_id, registry: Legend.Core.Runtime.Registry}

      # name flows into the PTY nudge label and renders in the UI / read_messages
      # output — reject control chars (the PTY-injection vector) and cap length.
      validate match(:name, ~r/\A[^[:cntrl:]]*\z/u) do
        message "must not contain control characters"
        where present(:name)
      end

      validate string_length(:name, max: 120) do
        where present(:name)
      end

      # after_transaction (not after_action): SessionServer.start_session/1
      # writes to the DB from the server process, which must run OUTSIDE the
      # enclosing create transaction.
      change after_transaction(fn
               _changeset, {:ok, session}, _context ->
                 case Legend.Core.Agents.SessionServer.start_session(session) do
                   {:ok, _pid} ->
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   :ignore ->
                     # init marked the record :failed before returning :ignore
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   {:error, reason} ->
                     {:ok, Legend.Core.Agents.fail_session!(session, %{error: inspect(reason)})}
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

    # Boot janitor: the process died with the previous backend run; the record
    # stays resumable.
    update :interrupt do
      require_atomic? false
      change set_attribute(:status, :interrupted)
      change set_attribute(:ended_at, &DateTime.utc_now/0)
    end

    # Manual resume (also from :exited — continue a finished conversation).
    # Same record/process lockstep pattern as :start; SessionServer marks the
    # record :running (or :failed) from its own process, outside this txn.
    update :resume do
      require_atomic? false

      validate Legend.Core.Agents.Validations.ResumableStatus

      change set_attribute(:status, :starting)
      change set_attribute(:exit_code, nil)
      change set_attribute(:error, nil)
      change set_attribute(:ended_at, nil)

      change after_transaction(fn
               _changeset, {:ok, session}, _context ->
                 case Legend.Core.Agents.SessionServer.start_session(session, :resume) do
                   {:ok, _pid} ->
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   :ignore ->
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   {:error, reason} ->
                     {:ok, Legend.Core.Agents.fail_session!(session, %{error: inspect(reason)})}
                 end

               _changeset, {:error, _} = error, _context ->
                 error
             end)
    end

    destroy :destroy do
      primary? true
      require_atomic? false

      change before_action(fn changeset, _context ->
               Legend.Core.Agents.SessionServer.ensure_stopped(changeset.data.id)
               changeset
             end)

      change after_transaction(fn
               _changeset, {:ok, _} = result, _context ->
                 Legend.Core.Agents.Notifications.sessions_changed()
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
    attribute :cwd, :string, public?: true, default: &Legend.Core.Agents.Session.default_cwd/0

    attribute :status, :atom,
      allow_nil?: false,
      default: :starting,
      public?: true,
      constraints: [one_of: [:starting, :running, :exited, :failed, :interrupted]]

    attribute :exit_code, :integer, public?: true
    attribute :error, :string, public?: true
    attribute :started_at, :utc_datetime, public?: true
    attribute :ended_at, :utc_datetime, public?: true

    # Delegation lineage: the session that called start_agent/handoff to create this one.
    attribute :spawned_by_session_id, :uuid, public?: true

    # Launch task delivered as the CLI's initial prompt (spawned sessions only).
    attribute :instructions, :string, public?: true, constraints: [max_length: 65_536]

    # Bearer token mapping MCP calls to this session. Nullable only for
    # pre-feature rows (dead after restart anyway); never exposed via JSON:API.
    attribute :mcp_token, :string,
      sensitive?: true,
      default: &Legend.Core.Agents.Session.generate_token/0

    timestamps public?: true
  end

  @doc false
  def default_cwd, do: System.user_home!()

  @doc false
  def generate_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
end
