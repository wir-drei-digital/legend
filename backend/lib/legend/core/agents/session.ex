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
      accept [
        :name,
        :harness_id,
        :runtime_id,
        :cwd,
        :spawned_by_session_id,
        :instructions,
        :transport
      ]

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

      # Normalize cwd up front so grouping keys are stable across sessions
      # ("~/p" and "/Users/x/p/" collapse to one). Runtime-aware — see
      # normalize_cwd/2 (remote sandbox paths stay opaque).
      change fn changeset, _context ->
        cwd = Ash.Changeset.get_attribute(changeset, :cwd)
        rid = Ash.Changeset.get_attribute(changeset, :runtime_id)

        case __MODULE__.normalize_cwd(cwd, rid) do
          nil -> changeset
          normalized -> Ash.Changeset.force_change_attribute(changeset, :cwd, normalized)
        end
      end

      # Default transport from the harness when the picker didn't supply one.
      # The attribute carries default: :terminal, so a fresh changeset already
      # reports :terminal — check the action input (params), not the resolved
      # attribute, to tell "picker chose terminal" from "nobody chose".
      change fn changeset, _context ->
        supplied? =
          Map.has_key?(changeset.params, :transport) or
            Map.has_key?(changeset.params, "transport")

        if supplied? do
          changeset
        else
          hid = Ash.Changeset.get_attribute(changeset, :harness_id)
          rid = Ash.Changeset.get_attribute(changeset, :runtime_id)
          Ash.Changeset.force_change_attribute(changeset, :transport, default_transport(hid, rid))
        end
      end

      # Auto-name from the launch instructions when the user left the name blank.
      # Spawned/delegated sessions carry instructions as the CLI's initial prompt;
      # deriving here (inside the insert) makes the name correct in the create
      # response with no extra write. A user-provided name always wins.
      change fn changeset, _context ->
        name = Ash.Changeset.get_attribute(changeset, :name)

        if is_nil(name) or String.trim(name) == "" do
          instructions = Ash.Changeset.get_attribute(changeset, :instructions)

          case Legend.Core.Agents.SessionName.derive(instructions) do
            nil -> changeset
            derived -> Ash.Changeset.force_change_attribute(changeset, :name, derived)
          end
        else
          changeset
        end
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
    update :mark_provisioning do
      require_atomic? false
      change set_attribute(:status, :provisioning)
    end

    update :mark_running do
      require_atomic? false
      accept [:runtime_ref]
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

    # Manual resume from any stopped state — :interrupted, :exited (continue a
    # finished conversation), or :failed (recover from a launch/handshake error).
    # Same record/process lockstep pattern as :start; SessionServer marks the
    # record :running (or :failed) from its own process, outside this txn.
    update :resume do
      require_atomic? false

      validate Legend.Core.Agents.Validations.ResumableStatus

      change set_attribute(:status, :starting)
      change set_attribute(:exit_code, nil)
      change set_attribute(:error, nil)
      change set_attribute(:ended_at, nil)

      # The old server may still be alive (an :exited server keeps scrollback
      # until deleted) — stop it so the restart can re-register under the same
      # id. Runs after validation: a rejected resume never kills anything.
      change before_action(fn changeset, _context ->
               Legend.Core.Agents.SessionServer.ensure_stopped(changeset.data.id)
               changeset
             end)

      change after_transaction(fn
               _changeset, {:ok, session}, _context ->
                 case Legend.Core.Agents.SessionServer.start_session(session, :resume) do
                   {:ok, _pid} ->
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   :ignore ->
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   {:error, {:already_started, _pid}} ->
                     # Lost a benign race with another resume — the session is live.
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   {:error, reason} ->
                     {:ok, Legend.Core.Agents.fail_session!(session, %{error: inspect(reason)})}
                 end

               _changeset, {:error, _} = error, _context ->
                 error
             end)
    end

    update :set_conversation_id do
      require_atomic? false
      accept [:conversation_id]
    end

    update :set_transport do
      require_atomic? false
      accept [:transport]

      # Switching transport relaunches the run, so reset the same four lifecycle
      # fields :resume does — otherwise an :exited/:failed session would surface
      # as :running while still carrying the finished run's exit_code/error/ended_at.
      # No ResumableStatus validation: set_transport is intentionally allowed from
      # more states than :resume (a live :running session can be switched too).
      change set_attribute(:status, :starting)
      change set_attribute(:exit_code, nil)
      change set_attribute(:error, nil)
      change set_attribute(:ended_at, nil)

      # Relaunch into the same conversation under the new transport, if live.
      change before_action(fn changeset, _context ->
               Legend.Core.Agents.SessionServer.ensure_stopped(changeset.data.id)
               changeset
             end)

      change after_transaction(fn
               _changeset, {:ok, session}, _context ->
                 case Legend.Core.Agents.SessionServer.start_session(session, :switch) do
                   {:ok, _pid} ->
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   :ignore ->
                     {:ok, Legend.Core.Agents.get_session!(session.id)}

                   {:error, {:already_started, _}} ->
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
               session = changeset.data
               Legend.Core.Agents.SessionServer.ensure_stopped(session.id)
               maybe_teardown_runtime(session)
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
      constraints: [one_of: [:starting, :provisioning, :running, :exited, :failed, :interrupted]]

    # Opaque, runtime-specific handle for reattaching after a backend restart
    # (e.g. %{"sprite" => name, "exec_id" => id}). nil for runtimes that don't reattach.
    attribute :runtime_ref, :map, public?: true

    attribute :transport, :atom,
      allow_nil?: false,
      default: :terminal,
      public?: true,
      constraints: [one_of: [:terminal, :acp]]

    # The agent's durable conversation handle, SHARED across transports so a
    # transport switch resumes the same conversation. nil until the first launch
    # resolves it: terminal pins it to the session id (already used as
    # --session-id at first launch); ACP captures the adapter's id from
    # session/new. Either way, later launches pass it as --session-id/--resume
    # (terminal) or session/load (ACP).
    attribute :conversation_id, :string, public?: true

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
  def default_transport(harness_id, runtime_id) do
    with {:ok, hmod} <- Legend.Core.Harness.Registry.fetch(harness_id),
         transports = hmod.definition().transports,
         [first | _] <- transports do
      if remote_auth_runtime?(runtime_id) and :terminal in transports do
        :terminal
      else
        first
      end
    else
      _ -> :terminal
    end
  end

  # A provisioning runtime is a fresh remote box needing interactive (PTY) first-run
  # auth, so an ACP-capable session starts in :terminal until the human authenticates;
  # they then switch to :acp on the same persisted sprite.
  defp remote_auth_runtime?(runtime_id) do
    case Legend.Core.Runtime.Registry.fetch(runtime_id) do
      {:ok, rmod} -> Legend.Core.Runtime.capabilities(rmod).provisions?
      :error -> false
    end
  end

  @doc false
  def default_cwd, do: System.user_home!()

  @doc """
  Normalizes a session working directory so grouping keys are stable.

  Local runtime (`"local_pty"`): expands a leading `~`, absolutizes (collapsing
  `.`/`..`), and strips a trailing slash. Remote runtimes: treats the path as
  opaque — strips only a trailing slash; the path lives in a sandbox, not on this
  host, so host-home expansion would be wrong. Blank/`nil` → `nil` (the attribute
  default applies).
  """
  @spec normalize_cwd(String.t() | nil, String.t() | nil) :: String.t() | nil
  def normalize_cwd(nil, _runtime_id), do: nil

  def normalize_cwd(cwd, runtime_id) when is_binary(cwd) do
    case String.trim(cwd) do
      "" ->
        nil

      trimmed when runtime_id == "local_pty" ->
        trimmed |> expand_local() |> strip_trailing_slash()

      trimmed ->
        strip_trailing_slash(trimmed)
    end
  end

  defp expand_local("~"), do: System.user_home!()
  defp expand_local("~/" <> rest), do: System.user_home!() |> Path.join(rest) |> Path.expand()
  defp expand_local("/" <> _ = abs), do: Path.expand(abs)
  defp expand_local(other), do: other

  defp strip_trailing_slash("/"), do: "/"

  defp strip_trailing_slash(path) do
    case String.replace_trailing(path, "/", "") do
      "" -> "/"
      stripped -> stripped
    end
  end

  @doc false
  def generate_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  @doc false
  def maybe_teardown_runtime(%{runtime_id: rid, runtime_ref: ref}) when not is_nil(ref) do
    with {:ok, runtime} <- Legend.Core.Runtime.Registry.fetch(rid),
         true <- function_exported?(runtime, :teardown, 1) do
      # Best effort: a teardown failure must not block record deletion.
      try do
        runtime.teardown(ref)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  def maybe_teardown_runtime(_session), do: :ok
end
