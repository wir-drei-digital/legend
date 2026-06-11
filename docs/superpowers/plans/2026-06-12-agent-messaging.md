# Agent Messaging & Delegation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agents in Legend sessions message each other, delegate by spawning sessions, and hand off — via Legend-provided MCP tools — with the human watching and joining all traffic in the UI.

**Architecture:** New `Legend.Core.Signals` Ash domain with a pairwise `Message` resource (inbox = unread rows). A hand-rolled streamable-HTTP MCP endpoint (`POST /api/mcp`) authenticates agents by per-session bearer token and exposes five tools. `SessionServer` injects MCP env/config at launch, subscribes to its session's inbox topic, and nudges the PTY with a debounced one-liner. A `signals:timeline` channel feeds the UI (global timeline page + per-session panel + sidebar badges).

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 (AshSqlite, AshJsonApi), hand-rolled MCP JSON-RPC (decision: no MCP library — the needed surface is 5 methods; anubis/hermes_mcp bring supervision machinery we don't need, and a dep named `hermes_mcp` would collide confusingly with our Hermes harness), SvelteKit 2 / Svelte 5 runes.

**Spec:** `docs/superpowers/specs/2026-06-12-agent-messaging-design.md`

**Conventions that apply to every task:**
- Work in `backend/` for Elixir tasks: `cd backend && mix test test/path_test.exs`.
- Run `mix format` before each commit. Final task runs `mix precommit`.
- Migrations are generated with `mix ash.codegen <name>`, applied with `mix ash.setup` (the `test` alias migrates the test DB automatically).
- New JSON endpoints go in the **first** router scope (before the AshJsonApi forward) — router order is load-bearing.
- Registry ids are matched by string comparison, never `String.to_atom`.

---

### Task 1: `Message` resource + `Signals` domain + migration

**Files:**
- Create: `backend/lib/legend/core/signals.ex`
- Create: `backend/lib/legend/core/signals/message.ex`
- Create: `backend/lib/legend/core/signals/validations/session_exists.ex`
- Modify: `backend/config/config.exs` (register domain; add `max_running_sessions`)
- Test: `backend/test/legend/core/signals/message_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.Signals.MessageTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    b = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    %{a: a, b: b}
  end

  test "send creates a message with defaults", %{a: a, b: b} do
    message =
      Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "hello"})

    assert message.kind == :message
    assert message.from_session_id == a.id
    assert message.to_session_id == b.id
    assert message.read_at == nil
  end

  test "send rejects an unknown target session", %{a: a} do
    assert {:error, %Ash.Error.Invalid{}} =
             Signals.send_message(%{
               from_session_id: a.id,
               to_session_id: Ash.UUID.generate(),
               payload: "hello"
             })
  end

  test "send rejects an oversized payload", %{a: a, b: b} do
    assert {:error, %Ash.Error.Invalid{}} =
             Signals.send_message(%{
               from_session_id: a.id,
               to_session_id: b.id,
               payload: String.duplicate("x", 65_537)
             })
  end

  test "from_session_id may be nil (human)", %{b: b} do
    message = Signals.send_message!(%{to_session_id: b.id, payload: "hi from human"})
    assert message.from_session_id == nil
  end

  test "unread_for returns only unread messages for the session, oldest first", %{a: a, b: b} do
    m1 = Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "one"})
    m2 = Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "two"})
    _other = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "nope"})

    Signals.mark_message_read!(m1)

    assert [unread] = Signals.unread_messages!(b.id)
    assert unread.id == m2.id
  end

  test "mark_read sets read_at", %{a: a, b: b} do
    m = Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "x"})
    read = Signals.mark_message_read!(m)
    assert %DateTime{} = read.read_at
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/signals/message_test.exs`
Expected: FAIL — `Legend.Core.Signals` is undefined.

- [ ] **Step 3: Create the validation module**

`backend/lib/legend/core/signals/validations/session_exists.ex`:

```elixir
defmodule Legend.Core.Signals.Validations.SessionExists do
  @moduledoc "Validates that an attribute references an existing session record."

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if is_atom(opts[:attribute]), do: {:ok, opts}, else: {:error, "attribute required"}
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      id ->
        case Legend.Core.Agents.get_session(id) do
          {:ok, _session} -> :ok
          {:error, _} -> {:error, field: attribute, message: "unknown session"}
        end
    end
  end
end
```

- [ ] **Step 4: Create the Message resource**

`backend/lib/legend/core/signals/message.ex`:

```elixir
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
```

- [ ] **Step 5: Create the Signals domain**

`backend/lib/legend/core/signals.ex`:

```elixir
defmodule Legend.Core.Signals do
  @moduledoc """
  The signal bus: agent-to-agent and human-to-agent messages, the per-session
  inbox, and the JSON:API surface at /api/messages.
  """

  use Ash.Domain, otp_app: :legend, extensions: [AshJsonApi.Domain]

  json_api do
    routes do
      base_route "/messages", Legend.Core.Signals.Message do
        index :list
        post :send_as_human
      end
    end
  end

  resources do
    resource Legend.Core.Signals.Message do
      define :send_message, action: :send
      define :send_human_message, action: :send_as_human
      define :list_messages, action: :list
      define :unread_messages, action: :unread_for, args: [:session_id]
      define :mark_message_read, action: :mark_read
    end
  end
end
```

- [ ] **Step 6: Register the domain and the session cap in config**

In `backend/config/config.exs`, change the `ash_domains` line and add `max_running_sessions` to the same `config :legend` block that holds `:harnesses`:

```elixir
  ash_domains: [Legend.Core.Agents, Legend.Core.Signals],
```

```elixir
  max_running_sessions: 10,
```

- [ ] **Step 7: Generate and apply the migration**

Run: `cd backend && mix ash.codegen add_messages && mix ash.setup`
Expected: a new migration in `priv/repo/migrations/` creating `messages`; migration applies cleanly. Inspect it — it must create the `messages` table with all attributes from Step 4.

- [ ] **Step 8: Run tests to verify they pass**

Run: `cd backend && mix test test/legend/core/signals/message_test.exs`
Expected: PASS (6 tests).

- [ ] **Step 9: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: Message resource + Signals domain (signal bus core)"
```

---

### Task 2: Session gains `spawned_by_session_id`, `instructions`, `mcp_token`

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex`
- Modify: `backend/lib/legend/core/agents.ex`
- Test: `backend/test/legend/core/agents/session_test.exs` (append)

- [ ] **Step 1: Write the failing test** — append to `backend/test/legend/core/agents/session_test.exs` (inside the existing top-level module, after the existing tests; reuse the file's existing setup/cleanup conventions):

```elixir
  describe "messaging fields" do
    test "start accepts spawned_by_session_id and instructions" do
      parent = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

      child =
        Agents.start_session!(%{
          harness_id: "hermes",
          runtime_id: "test",
          cwd: "/tmp",
          spawned_by_session_id: parent.id,
          instructions: "summarize the README"
        })

      assert child.spawned_by_session_id == parent.id
      assert child.instructions == "summarize the README"
    end

    test "every session gets a unique mcp_token and is fetchable by it" do
      a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
      b = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

      assert is_binary(a.mcp_token) and byte_size(a.mcp_token) >= 24
      assert a.mcp_token != b.mcp_token

      assert {:ok, found} = Agents.get_session_by_token(a.mcp_token)
      assert found.id == a.id
      assert {:error, _} = Agents.get_session_by_token("nope")
    end
  end
```

If the existing file's tests don't already clean up SessionServers, add the same `on_exit` DynamicSupervisor sweep used in Task 1's setup.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: FAIL — unknown attributes / undefined `get_session_by_token`.

- [ ] **Step 3: Add attributes and actions to the Session resource**

In `backend/lib/legend/core/agents/session.ex`:

Add to the `attributes` block (after `ended_at`):

```elixir
    # Delegation lineage: the session that called start_agent/handoff to create this one.
    attribute :spawned_by_session_id, :uuid, public?: true

    # Launch task delivered as the CLI's initial prompt (spawned sessions only).
    attribute :instructions, :string, public?: true, constraints: [max_length: 65_536]

    # Bearer token mapping MCP calls to this session. Nullable only for
    # pre-feature rows (dead after restart anyway); never exposed via JSON:API.
    attribute :mcp_token, :string, sensitive?: true, default: &Legend.Core.Agents.Session.generate_token/0
```

Change the `:start` action's accept list:

```elixir
      accept [:name, :harness_id, :runtime_id, :cwd, :spawned_by_session_id, :instructions]
```

Add a read action after `:list`:

```elixir
    read :by_token do
      argument :token, :string, allow_nil?: false, sensitive?: true
      get? true
      filter expr(mcp_token == ^arg(:token))
    end
```

Add at the bottom of the module, next to `default_cwd/0`:

```elixir
  @doc false
  def generate_token, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
```

- [ ] **Step 4: Add the code interface** — in `backend/lib/legend/core/agents.ex`, inside the `resource Legend.Core.Agents.Session do` block:

```elixir
      define :get_session_by_token, action: :by_token, args: [:token]
```

- [ ] **Step 5: Generate and apply the migration**

Run: `cd backend && mix ash.codegen add_session_messaging_fields && mix ash.setup`
Expected: migration adding the three nullable columns to `sessions`.

- [ ] **Step 6: Run tests**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: session spawned_by/instructions/mcp_token for messaging"
```

---

### Task 3: Notifications (PubSub) + broadcast on send + `read_inbox!`

**Files:**
- Create: `backend/lib/legend/core/signals/notifications.ex`
- Create: `backend/lib/legend/core/signals/changes/broadcast.ex`
- Modify: `backend/lib/legend/core/signals/message.ex` (wire the change)
- Modify: `backend/lib/legend/core/signals.ex` (add `read_inbox!/1`)
- Test: `backend/test/legend/core/signals/notifications_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.Signals.NotificationsTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals
  alias Legend.Core.Signals.Notifications

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    b = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp", name: "researcher"})
    %{a: a, b: b}
  end

  test "send broadcasts to the recipient inbox and the timeline", %{a: a, b: b} do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.inbox_topic(a.id))
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    message = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "hi"})

    assert_receive {:new_message, %{id: id, from_label: "researcher", payload: "hi"}}
    assert id == message.id
    assert_receive {:signal, %{id: ^id, kind: :message}}
  end

  test "a pre-read message (audit record) skips the inbox but hits the timeline", %{a: a, b: b} do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.inbox_topic(a.id))
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    Signals.send_message!(%{
      from_session_id: b.id,
      to_session_id: a.id,
      kind: :handoff,
      payload: "delivered at launch",
      read_at: DateTime.utc_now()
    })

    refute_receive {:new_message, _}, 100
    assert_receive {:signal, %{kind: :handoff}}
  end

  test "human sender gets the 'human' label", %{a: a} do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.inbox_topic(a.id))
    Signals.send_message!(%{to_session_id: a.id, payload: "hello"})
    assert_receive {:new_message, %{from_label: "human"}}
  end

  test "read_inbox! returns unread oldest-first, marks them read, broadcasts read ids", %{
    a: a,
    b: b
  } do
    m1 = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "one"})
    m2 = Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "two"})

    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    assert [r1, r2] = Signals.read_inbox!(a.id)
    assert {r1.id, r2.id} == {m1.id, m2.id}
    assert %DateTime{} = r1.read_at

    assert_receive {:signals_read, %{session_id: session_id, ids: ids}}
    assert session_id == a.id
    assert Enum.sort(ids) == Enum.sort([m1.id, m2.id])

    assert Signals.read_inbox!(a.id) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/signals/notifications_test.exs`
Expected: FAIL — `Notifications` undefined.

- [ ] **Step 3: Create Notifications**

`backend/lib/legend/core/signals/notifications.ex`:

```elixir
defmodule Legend.Core.Signals.Notifications do
  @moduledoc """
  PubSub fan-out for the signal bus. `inbox:<session_id>` drives the per-session
  nudge; the `signals` topic drives the live UI timeline. Messages created
  already-read (audit records delivered out of band, e.g. handoff-at-launch)
  skip the inbox broadcast.
  """

  @timeline "signals"

  def timeline_topic, do: @timeline
  def inbox_topic(session_id), do: "inbox:#{session_id}"

  def message_created(%{read_at: %DateTime{}} = message) do
    broadcast(@timeline, {:signal, summary(message)})
  end

  def message_created(message) do
    summary = summary(message)
    broadcast(inbox_topic(message.to_session_id), {:new_message, summary})
    broadcast(@timeline, {:signal, summary})
  end

  def messages_read(session_id, ids) do
    broadcast(@timeline, {:signals_read, %{session_id: session_id, ids: ids}})
  end

  @doc "Wire-format map for channel payloads and broadcasts."
  def summary(message) do
    %{
      id: message.id,
      from_session_id: message.from_session_id,
      from_label: from_label(message.from_session_id),
      to_session_id: message.to_session_id,
      kind: message.kind,
      payload: message.payload,
      read_at: message.read_at,
      inserted_at: message.inserted_at
    }
  end

  defp from_label(nil), do: "human"

  defp from_label(session_id) do
    case Legend.Core.Agents.get_session(session_id) do
      {:ok, session} -> session.name || session.harness_id
      {:error, _} -> "unknown"
    end
  end

  defp broadcast(topic, payload) do
    Phoenix.PubSub.broadcast(Legend.PubSub, topic, payload)
  end
end
```

- [ ] **Step 4: Create the Broadcast change and wire it**

`backend/lib/legend/core/signals/changes/broadcast.ex`:

```elixir
defmodule Legend.Core.Signals.Changes.Broadcast do
  @moduledoc "Broadcasts a created message after the transaction commits."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, message} = result ->
        Legend.Core.Signals.Notifications.message_created(message)
        result

      _changeset, error ->
        error
    end)
  end
end
```

In `backend/lib/legend/core/signals/message.ex`, add to **both** create actions (`:send` and `:send_as_human`), after the `validate` line:

```elixir
      change Legend.Core.Signals.Changes.Broadcast
```

- [ ] **Step 5: Add `read_inbox!/1`** — in `backend/lib/legend/core/signals.ex`, after the `resources do ... end` block:

```elixir
  @doc """
  Drains a session's inbox: returns unread messages oldest-first, marks them
  read, and broadcasts the read ids so UI unread badges update.
  """
  def read_inbox!(session_id) do
    case unread_messages!(session_id) do
      [] ->
        []

      messages ->
        read = Enum.map(messages, &mark_message_read!/1)
        Legend.Core.Signals.Notifications.messages_read(session_id, Enum.map(read, & &1.id))
        read
    end
  end
```

- [ ] **Step 6: Run tests**

Run: `cd backend && mix test test/legend/core/signals/`
Expected: PASS (all Task 1 + Task 3 tests).

- [ ] **Step 7: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: signal bus broadcasts and inbox draining"
```

---

### Task 4: messaging primer + MCP tools (`Legend.Core.Signals.Tools`)

**Files:**
- Modify: `backend/lib/legend/core/signals.ex` (add `messaging_primer/1`)
- Create: `backend/lib/legend/core/signals/tools.ex`
- Test: `backend/test/legend/core/signals/tools_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.Signals.ToolsTest do
  use Legend.DataCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals
  alias Legend.Core.Signals.Tools

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    b = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    %{a: a, b: b}
  end

  test "tool list exposes the five tools" do
    names = Enum.map(Tools.list(), & &1.name)

    assert Enum.sort(names) ==
             ["handoff", "list_agents", "read_messages", "send_message", "start_agent"]

    assert Enum.all?(Tools.list(), &match?(%{inputSchema: %{type: "object"}}, &1))
  end

  test "send_message delivers to a session id", %{a: a, b: b} do
    assert {:ok, text} = Tools.dispatch(a, "send_message", %{"to" => b.id, "content" => "hi"})
    assert text =~ "Delivered"
    assert [%{payload: "hi", from_session_id: from}] = Signals.unread_messages!(b.id)
    assert from == a.id
  end

  test "send_message to 'requester' resolves the spawner", %{a: a} do
    child =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        spawned_by_session_id: a.id
      })

    assert {:ok, _} = Tools.dispatch(child, "send_message", %{"to" => "requester", "content" => "done"})
    assert [%{payload: "done"}] = Signals.unread_messages!(a.id)

    assert {:error, text} = Tools.dispatch(a, "send_message", %{"to" => "requester", "content" => "x"})
    assert text =~ "no requester"
  end

  test "send_message to an unknown session errors", %{a: a} do
    assert {:error, text} =
             Tools.dispatch(a, "send_message", %{"to" => Ash.UUID.generate(), "content" => "x"})

    assert text =~ "unknown session"
  end

  test "read_messages drains the inbox", %{a: a, b: b} do
    {:ok, _} = Tools.dispatch(a, "send_message", %{"to" => b.id, "content" => "first"})
    {:ok, _} = Tools.dispatch(a, "send_message", %{"to" => b.id, "content" => "second"})

    assert {:ok, text} = Tools.dispatch(b, "read_messages", %{})
    assert text =~ "first"
    assert text =~ "second"

    assert {:ok, "No unread messages."} = Tools.dispatch(b, "read_messages", %{})
  end

  test "start_agent spawns a session with lineage, instructions, and audit record", %{a: a} do
    assert {:ok, text} =
             Tools.dispatch(a, "start_agent", %{
               "harness" => "hermes",
               "instructions" => "summarize the README",
               "name" => "summarizer"
             })

    assert text =~ "Started session"

    child = Enum.find(Agents.list_sessions!(), &(&1.name == "summarizer"))
    assert child.spawned_by_session_id == a.id
    assert child.instructions == "summarize the README"
    assert child.cwd == a.cwd

    # Audit record on the timeline, already read (delivered at launch).
    assert Signals.unread_messages!(child.id) == []
    assert Enum.any?(Signals.list_messages!(), &(&1.kind == :system and &1.to_session_id == child.id))
  end

  test "start_agent rejects unknown harness and enforces the session cap", %{a: a} do
    assert {:error, text} =
             Tools.dispatch(a, "start_agent", %{"harness" => "nope", "instructions" => "x"})

    assert text =~ "unknown harness"

    original = Application.get_env(:legend, :max_running_sessions)
    Application.put_env(:legend, :max_running_sessions, 1)
    on_exit(fn -> Application.put_env(:legend, :max_running_sessions, original) end)

    assert {:error, text} =
             Tools.dispatch(a, "start_agent", %{"harness" => "hermes", "instructions" => "x"})

    assert text =~ "session cap"
  end

  test "handoff to an existing session sends a :handoff message", %{a: a, b: b} do
    assert {:ok, _} = Tools.dispatch(a, "handoff", %{"to" => b.id, "summary" => "take over"})
    assert [%{kind: :handoff, payload: "take over"}] = Signals.unread_messages!(b.id)
  end

  test "handoff to a harness id spawns with the summary as launch context", %{a: a} do
    assert {:ok, text} = Tools.dispatch(a, "handoff", %{"to" => "hermes", "summary" => "state: done X, next Y"})
    assert text =~ "Handed off"

    child = Enum.find(Agents.list_sessions!(), &(&1.spawned_by_session_id == a.id))
    assert child.instructions =~ "state: done X, next Y"
  end

  test "handoff to an id that is neither errors", %{a: a} do
    assert {:error, text} = Tools.dispatch(a, "handoff", %{"to" => "nope", "summary" => "x"})
    assert text =~ "unknown session or harness"
  end

  test "list_agents lists sessions with status", %{a: a} do
    assert {:ok, text} = Tools.dispatch(a, "list_agents", %{})
    assert text =~ a.id
    assert text =~ "claude_code"
  end

  test "unknown tool errors", %{a: a} do
    assert {:error, _} = Tools.dispatch(a, "fly_to_moon", %{})
  end

  test "messaging_primer mentions the session id and the requester when spawned", %{a: a} do
    primer = Signals.messaging_primer(a)
    assert primer =~ a.id
    refute primer =~ "You were started by"

    child =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        spawned_by_session_id: a.id
      })

    child_primer = Signals.messaging_primer(child)
    assert child_primer =~ "You were started by session #{a.id}"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/signals/tools_test.exs`
Expected: FAIL — `Tools` undefined.

- [ ] **Step 3: Add `messaging_primer/1`** — in `backend/lib/legend/core/signals.ex`, after `read_inbox!/1`:

```elixir
  @doc "Launch-context primer teaching an agent its identity and the messaging tools."
  def messaging_primer(session) do
    spawner =
      case session.spawned_by_session_id do
        nil ->
          ""

        id ->
          "\nYou were started by session #{id} (your requester). Report progress and your " <>
            "final result to it with send_message(to: \"requester\", ...). Always send a " <>
            "final message before you finish."
      end

    """
    ## Legend messaging

    You are agent session #{session.id} in Legend, an orchestrator that runs multiple \
    agent sessions which can message each other. You have these MCP tools on the \
    `legend` server:

    - send_message(to, content): message another session; to is a session id, or "requester" for the session that started you
    - read_messages(): read your unread inbox. A line like "[legend] N unread message(s) ..." appearing in your input means you should call this
    - start_agent(harness, instructions, name?, cwd?): delegate — start another agent session; it is told to report back to you and you get a system message when it exits
    - handoff(to, summary): pass your work to another session (session id) or a fresh agent (harness id); the summary should carry full state and next steps
    - list_agents(): list all sessions and their status

    Put large content in the shared library (path in LEGEND_LIBRARY) and send paths, \
    not file bodies.#{spawner}
    """
  end
```

- [ ] **Step 4: Create the Tools module**

`backend/lib/legend/core/signals/tools.ex`:

```elixir
defmodule Legend.Core.Signals.Tools do
  @moduledoc """
  The MCP tool surface for messaging. Pure dispatch from (caller session, tool
  name, string-keyed args) to {:ok, text} | {:error, text}; the MCP controller
  wraps results in JSON-RPC. The caller session comes from token auth — agents
  never assert their own identity.
  """

  alias Legend.Core.Agents
  alias Legend.Core.Harness
  alias Legend.Core.Signals

  def list do
    [
      %{
        name: "send_message",
        description:
          "Send a message to another Legend agent session. Use to: \"requester\" to reach the session that started you.",
        inputSchema: %{
          type: "object",
          properties: %{
            to: %{type: "string", description: "target session id, or \"requester\""},
            content: %{type: "string", description: "the message text"}
          },
          required: ["to", "content"]
        }
      },
      %{
        name: "read_messages",
        description: "Read and clear your unread inbox of messages from other sessions and the human.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "start_agent",
        description:
          "Start another agent session to delegate work to. It receives your instructions at launch, is told to report back to you, and you get a system message when it exits.",
        inputSchema: %{
          type: "object",
          properties: %{
            harness: %{type: "string", description: "harness id, e.g. \"claude_code\" or \"hermes\""},
            instructions: %{type: "string", description: "the task for the new agent"},
            name: %{type: "string", description: "optional display name"},
            cwd: %{type: "string", description: "optional working directory (defaults to yours)"}
          },
          required: ["harness", "instructions"]
        }
      },
      %{
        name: "handoff",
        description:
          "Hand your work off and step back. to is an existing session id, or a harness id to spawn a fresh agent with your summary as its launch context. The summary must carry full state and next steps.",
        inputSchema: %{
          type: "object",
          properties: %{
            to: %{type: "string", description: "session id or harness id"},
            summary: %{type: "string", description: "full state of the work and next steps"}
          },
          required: ["to", "summary"]
        }
      },
      %{
        name: "list_agents",
        description: "List all Legend sessions with their status.",
        inputSchema: %{type: "object", properties: %{}}
      }
    ]
  end

  def dispatch(session, "send_message", %{"to" => to, "content" => content})
      when is_binary(to) and is_binary(content) do
    with {:ok, target_id} <- resolve_target(session, to) do
      create_message(session.id, target_id, :message, content)
    end
  end

  def dispatch(session, "read_messages", _args) do
    case Signals.read_inbox!(session.id) do
      [] -> {:ok, "No unread messages."}
      messages -> {:ok, Enum.map_join(messages, "\n\n", &format_message/1)}
    end
  end

  def dispatch(session, "start_agent", %{"harness" => harness, "instructions" => instructions} = args)
      when is_binary(harness) and is_binary(instructions) do
    start_agent(session, harness, instructions, args["name"], args["cwd"])
  end

  def dispatch(session, "handoff", %{"to" => to, "summary" => summary})
      when is_binary(to) and is_binary(summary) do
    case Agents.get_session(to) do
      {:ok, target} ->
        create_message(session.id, target.id, :handoff, summary)

      {:error, _} ->
        case Harness.Registry.fetch(to) do
          {:ok, _module} -> handoff_spawn(session, to, summary)
          :error -> {:error, "unknown session or harness id: #{to}"}
        end
    end
  end

  def dispatch(_session, "list_agents", _args) do
    lines =
      Enum.map_join(Agents.list_sessions!(), "\n", fn s ->
        "#{s.id} | #{s.name || "-"} | #{s.harness_id} | #{s.status}"
      end)

    {:ok, "id | name | harness | status\n" <> lines}
  end

  def dispatch(_session, name, _args) do
    {:error, "unknown tool or missing required arguments: #{name}"}
  end

  defp resolve_target(session, "requester") do
    case session.spawned_by_session_id do
      nil -> {:error, "this session has no requester — pass an explicit session id"}
      id -> {:ok, id}
    end
  end

  defp resolve_target(_session, to) do
    case Agents.get_session(to) do
      {:ok, target} -> {:ok, target.id}
      {:error, _} -> {:error, "unknown session: #{to}"}
    end
  end

  defp create_message(from_id, to_id, kind, payload) do
    case Signals.send_message(%{
           from_session_id: from_id,
           to_session_id: to_id,
           kind: kind,
           payload: payload
         }) do
      {:ok, message} -> {:ok, "Delivered (message #{message.id})."}
      {:error, error} -> {:error, "delivery failed: #{Exception.message(error)}"}
    end
  end

  defp start_agent(session, harness, instructions, name, cwd) do
    max = Application.get_env(:legend, :max_running_sessions, 10)

    cond do
      Harness.Registry.fetch(harness) == :error ->
        {:error, "unknown harness: #{harness}. Known: #{known_harnesses()}"}

      running_count() >= max ->
        {:error, "session cap reached (#{max} running) — stop a session first"}

      true ->
        case Agents.start_session(%{
               harness_id: harness,
               name: name,
               cwd: cwd || session.cwd,
               spawned_by_session_id: session.id,
               instructions: instructions
             }) do
          {:ok, %{status: :failed} = failed} ->
            {:error, "agent failed to start: #{failed.error}"}

          {:ok, new_session} ->
            audit(session.id, new_session.id, :system, "started with instructions:\n#{instructions}")

            {:ok,
             "Started session #{new_session.id} (#{harness}). It was told to report back " <>
               "to you; you will also get a system message when it exits."}

          {:error, error} ->
            {:error, "could not start agent: #{Exception.message(error)}"}
        end
    end
  end

  defp handoff_spawn(session, harness, summary) do
    instructions =
      "You are taking over work handed off by another agent. Handoff summary:\n\n" <> summary

    with {:ok, text} <- start_agent(session, harness, instructions, nil, nil) do
      {:ok, "Handed off. " <> text}
    end
  end

  # Timeline audit record for content delivered out of band (at launch):
  # created already-read so it never nudges.
  defp audit(from_id, to_id, kind, payload) do
    Signals.send_message(%{
      from_session_id: from_id,
      to_session_id: to_id,
      kind: kind,
      payload: payload,
      read_at: DateTime.utc_now()
    })

    :ok
  end

  defp running_count do
    Enum.count(Agents.list_sessions!(), &(&1.status in [:starting, :running]))
  end

  defp known_harnesses do
    Enum.map_join(Harness.Registry.list(), ", ", & &1.id)
  end

  defp format_message(message) do
    summary = Signals.Notifications.summary(message)

    "[#{message.inserted_at} | #{message.kind} | from #{summary.from_label} " <>
      "(#{message.from_session_id || "human"})] #{message.payload}"
  end
end
```

- [ ] **Step 5: Run tests**

Run: `cd backend && mix test test/legend/core/signals/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: messaging primer and MCP tool dispatch"
```

---

### Task 5: MCP endpoint (`POST /api/mcp`)

**Files:**
- Create: `backend/lib/legend_web/controllers/mcp_controller.ex`
- Modify: `backend/lib/legend_web/router.ex` (first scope)
- Test: `backend/test/legend_web/controllers/mcp_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LegendWeb.MCPControllerTest do
  use LegendWeb.ConnCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals

  setup %{conn: conn} do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    authed =
      conn
      |> put_req_header("authorization", "Bearer " <> session.mcp_token)
      |> put_req_header("content-type", "application/json")

    %{conn: authed, raw_conn: put_req_header(conn, "content-type", "application/json"), session: session}
  end

  defp rpc(conn, method, params \\ nil, id \\ 1) do
    body = %{jsonrpc: "2.0", id: id, method: method}
    body = if params, do: Map.put(body, :params, params), else: body
    post(conn, "/api/mcp", Jason.encode!(body))
  end

  test "rejects a missing or bad token", %{raw_conn: raw_conn} do
    conn = rpc(raw_conn, "tools/list")
    assert json_response(conn, 401)

    conn =
      raw_conn
      |> put_req_header("authorization", "Bearer wrong")
      |> rpc("tools/list")

    assert json_response(conn, 401)
  end

  test "initialize returns protocol version and tool capability", %{conn: conn} do
    response = json_response(rpc(conn, "initialize", %{"protocolVersion" => "2025-03-26"}), 200)

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 1
    assert response["result"]["protocolVersion"] == "2025-03-26"
    assert response["result"]["capabilities"]["tools"] == %{}
    assert response["result"]["serverInfo"]["name"] == "legend"
  end

  test "notifications get 202 with no body", %{conn: conn} do
    conn =
      post(conn, "/api/mcp", Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"}))

    assert response(conn, 202)
  end

  test "tools/list returns the five tools", %{conn: conn} do
    response = json_response(rpc(conn, "tools/list"), 200)
    names = Enum.map(response["result"]["tools"], & &1["name"])
    assert "send_message" in names
    assert length(names) == 5
  end

  test "tools/call dispatches with the token's session as caller", %{conn: conn, session: session} do
    target = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})

    response =
      json_response(
        rpc(conn, "tools/call", %{
          "name" => "send_message",
          "arguments" => %{"to" => target.id, "content" => "ping"}
        }),
        200
      )

    assert response["result"]["isError"] == false
    assert [%{type: "text", text: text}] = response["result"]["content"] |> Enum.map(&%{type: &1["type"], text: &1["text"]})
    assert text =~ "Delivered"

    assert [%{from_session_id: from, payload: "ping"}] = Signals.unread_messages!(target.id)
    assert from == session.id
  end

  test "tool errors come back as isError, not JSON-RPC errors", %{conn: conn} do
    response =
      json_response(
        rpc(conn, "tools/call", %{
          "name" => "send_message",
          "arguments" => %{"to" => Ash.UUID.generate(), "content" => "x"}
        }),
        200
      )

    assert response["result"]["isError"] == true
  end

  test "unknown method returns -32601", %{conn: conn} do
    response = json_response(rpc(conn, "wat"), 200)
    assert response["error"]["code"] == -32601
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/controllers/mcp_controller_test.exs`
Expected: FAIL — route/controller missing (404s).

- [ ] **Step 3: Create the controller**

`backend/lib/legend_web/controllers/mcp_controller.ex`:

```elixir
defmodule LegendWeb.MCPController do
  @moduledoc """
  Minimal MCP server over streamable HTTP (plain-JSON responses, no SSE): the
  agent-facing twin of the JSON:API surface. Hand-rolled — the protocol surface
  Legend needs is five JSON-RPC methods. Auth: per-session bearer token, which
  also identifies the calling session (agents never assert their own identity).
  """

  use LegendWeb, :controller

  alias Legend.Core.Agents
  alias Legend.Core.Signals.Tools

  @protocol_versions ~w(2025-06-18 2025-03-26 2024-11-05)
  @default_protocol_version "2025-03-26"

  plug :authenticate

  # Requests without an id are JSON-RPC notifications: accept and discard.
  def handle(conn, %{"method" => _} = params) when not is_map_key(params, "id") do
    send_resp(conn, 202, "")
  end

  def handle(conn, %{"method" => method, "id" => id} = params) do
    json(conn, rpc_response(id, dispatch(method, params["params"] || %{}, conn.assigns.mcp_session)))
  end

  def handle(conn, _params) do
    json(conn, rpc_response(nil, {:error, %{code: -32600, message: "invalid request"}}))
  end

  defp dispatch("initialize", params, _session) do
    version =
      if params["protocolVersion"] in @protocol_versions,
        do: params["protocolVersion"],
        else: @default_protocol_version

    {:ok,
     %{
       protocolVersion: version,
       capabilities: %{tools: %{}},
       serverInfo: %{name: "legend", version: to_string(Application.spec(:legend, :vsn))}
     }}
  end

  defp dispatch("ping", _params, _session), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _session), do: {:ok, %{tools: Tools.list()}}

  defp dispatch("tools/call", %{"name" => name} = params, session) do
    case Tools.dispatch(session, name, params["arguments"] || %{}) do
      {:ok, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: false}}
      {:error, text} -> {:ok, %{content: [%{type: "text", text: text}], isError: true}}
    end
  end

  defp dispatch(method, _params, _session) do
    {:error, %{code: -32601, message: "method not found: #{method}"}}
  end

  defp rpc_response(id, {:ok, result}), do: %{jsonrpc: "2.0", id: id, result: result}
  defp rpc_response(id, {:error, error}), do: %{jsonrpc: "2.0", id: id, error: error}

  defp authenticate(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, session} <- Agents.get_session_by_token(token) do
      assign(conn, :mcp_session, session)
    else
      _ ->
        conn
        |> put_status(401)
        |> json(%{error: "invalid or missing token"})
        |> halt()
    end
  end
end
```

- [ ] **Step 4: Add the route** — in `backend/lib/legend_web/router.ex`, first scope, after the harnesses route:

```elixir
    post "/mcp", MCPController, :handle
```

- [ ] **Step 5: Run tests**

Run: `cd backend && mix test test/legend_web/controllers/mcp_controller_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: MCP endpoint with per-session token auth"
```

---

### Task 6: Terminal contract + harness wiring (MCP config, primers, instructions, nudge line)

**Files:**
- Modify: `backend/lib/legend/core/harness/terminal.ex`
- Modify: `backend/lib/legend/harnesses/claude_code.ex`
- Modify: `backend/lib/legend/harnesses/hermes.ex`
- Test: `backend/test/legend/harnesses_test.exs` (append)

- [ ] **Step 1: Write the failing tests** — append a describe block to `backend/test/legend/harnesses_test.exs` (match the file's existing aliasing; `ClaudeCode`/`Hermes` below refer to `Legend.Harnesses.*`):

```elixir
  describe "messaging wiring" do
    @opts %{
      library: %{path: "/lib", primer: "LIB PRIMER"},
      mcp: %{url: "http://localhost:4100/api/mcp", token: "tok123"},
      messaging: %{primer: "MSG PRIMER", instructions: nil}
    }

    test "claude_code registers the MCP server and allows its tools" do
      spec = Legend.Harnesses.ClaudeCode.build_command(@opts)

      mcp_index = Enum.find_index(spec.args, &(&1 == "--mcp-config"))
      assert mcp_index
      config = Jason.decode!(Enum.at(spec.args, mcp_index + 1))
      assert config["mcpServers"]["legend"]["url"] == "http://localhost:4100/api/mcp"
      assert config["mcpServers"]["legend"]["headers"]["Authorization"] == "Bearer tok123"

      allowed_index = Enum.find_index(spec.args, &(&1 == "--allowed-tools"))
      assert Enum.at(spec.args, allowed_index + 1) == "mcp__legend"
    end

    test "claude_code joins library and messaging primers in one system prompt" do
      spec = Legend.Harnesses.ClaudeCode.build_command(@opts)
      index = Enum.find_index(spec.args, &(&1 == "--append-system-prompt"))
      prompt = Enum.at(spec.args, index + 1)
      assert prompt =~ "LIB PRIMER"
      assert prompt =~ "MSG PRIMER"
    end

    test "claude_code passes instructions as the trailing positional prompt" do
      opts = put_in(@opts, [:messaging, :instructions], "do the thing")
      spec = Legend.Harnesses.ClaudeCode.build_command(opts)
      assert List.last(spec.args) == "do the thing"

      # Without instructions there is no trailing prompt.
      spec = Legend.Harnesses.ClaudeCode.build_command(@opts)
      refute List.last(spec.args) == "do the thing"
    end

    test "hermes passes instructions positionally and ignores mcp opts (env-only fallback)" do
      opts = put_in(@opts, [:messaging, :instructions], "take over")
      spec = Legend.Harnesses.Hermes.build_command(opts)
      assert List.last(spec.args) == "take over"
      refute "--mcp-config" in spec.args
    end

    test "default nudge line names the sender and read_messages" do
      line = Legend.Core.Harness.Terminal.nudge_line(Legend.Harnesses.ClaudeCode, 2, "hermes")
      assert line =~ "2 unread"
      assert line =~ "hermes"
      assert line =~ "read_messages"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/harnesses_test.exs`
Expected: FAIL — no `--mcp-config` arg, `nudge_line/3` undefined.

- [ ] **Step 3: Extend the Terminal contract** — replace `backend/lib/legend/core/harness/terminal.ex` with:

```elixir
defmodule Legend.Core.Harness.Terminal do
  @moduledoc """
  Contract for `:terminal`-kind harnesses: build the CLI invocation.

  ## Library primer contract

  When opts contain `:library`, the harness SHOULD deliver `library.primer`
  through its CLI's native context mechanism (e.g. a system-prompt flag) and
  MUST NOT inject it as fake user input (no PTY injection). A harness whose
  CLI has no such mechanism delivers nothing — the platform-injected
  `LEGEND_LIBRARY` env var still applies. Plugin harnesses implement their own
  delivery against this contract.

  ## Messaging contract

  When opts contain `:mcp`, the harness SHOULD register Legend's MCP server
  (`mcp.url`, bearer `mcp.token`) through its CLI's native MCP mechanism; the
  platform-injected `LEGEND_MCP_URL`/`LEGEND_SESSION_TOKEN` env vars are the
  universal fallback. When opts contain `:messaging`, `messaging.primer` joins
  the library primer through the same context mechanism, and a non-nil
  `messaging.instructions` is delivered as the CLI's initial prompt. None of
  these are ever PTY-injected; the only runtime injection is the one-line
  nudge, whose format a harness may override via the optional `nudge_line/2`.
  """

  @type library :: %{path: String.t(), primer: String.t()}
  @type mcp :: %{url: String.t(), token: String.t()}
  @type messaging :: %{primer: String.t(), instructions: String.t() | nil}
  @type opts :: %{
          optional(:env) => %{String.t() => String.t()},
          optional(:library) => library(),
          optional(:mcp) => mcp(),
          optional(:messaging) => messaging()
        }

  @callback build_command(opts()) :: Legend.Core.Runtime.CommandSpec.t()
  @callback nudge_line(count :: pos_integer(), from :: String.t()) :: String.t()
  @optional_callbacks nudge_line: 2

  @doc "Resolves the nudge line via the harness override or the default."
  def nudge_line(harness, count, from) do
    if function_exported?(harness, :nudge_line, 2) do
      harness.nudge_line(count, from)
    else
      default_nudge_line(count, from)
    end
  end

  @doc false
  def default_nudge_line(count, from) do
    "[legend] #{count} unread message(s) from #{from} — call read_messages to view"
  end

  @doc "Joins the library and messaging primers for single-flag delivery."
  def primers(opts) do
    [get_in(opts, [:library, :primer]), get_in(opts, [:messaging, :primer])]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  @doc "The initial-prompt text, or nil."
  def instructions(opts) do
    case get_in(opts, [:messaging, :instructions]) do
      text when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end
end
```

- [ ] **Step 4: Update the Claude Code harness** — in `backend/lib/legend/harnesses/claude_code.ex`, replace `build_command/1` and `primer_args/1` with:

```elixir
  alias Legend.Core.Harness.Terminal

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:claude_code, "claude")

    %CommandSpec{
      cmd: cmd,
      args: args ++ primer_args(opts) ++ mcp_args(opts) ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  defp primer_args(opts) do
    case Terminal.primers(opts) do
      [] -> []
      primers -> ["--append-system-prompt", Enum.join(primers, "\n\n")]
    end
  end

  defp mcp_args(%{mcp: %{url: url, token: token}}) do
    config =
      Jason.encode!(%{
        mcpServers: %{
          legend: %{type: "http", url: url, headers: %{Authorization: "Bearer #{token}"}}
        }
      })

    # "mcp__legend" is a server-level allow rule: every tool from this server.
    ["--mcp-config", config, "--allowed-tools", "mcp__legend"]
  end

  defp mcp_args(_opts), do: []

  # Trailing positional arg = initial prompt in Claude Code's interactive mode.
  defp instruction_args(opts) do
    case Terminal.instructions(opts) do
      nil -> []
      text -> [text]
    end
  end
```

(Keep `definition/0` and `configured_command/2` as they are.)

- [ ] **Step 5: Update the Hermes harness** — in `backend/lib/legend/harnesses/hermes.ex`, replace `build_command/1` and `primer_args/1` with (keep the rest):

```elixir
  alias Legend.Core.Harness.Terminal

  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:hermes, "hermes")

    %CommandSpec{
      cmd: cmd,
      args: args ++ primer_args(opts) ++ instruction_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  # Hermes' CLI primer mechanism is unknown; deliver only when the operator
  # configures a flag template (HARNESS_HERMES_PRIMER_FLAG), per the contract.
  # MCP registration likewise rides the env-var fallback (LEGEND_MCP_URL /
  # LEGEND_SESSION_TOKEN) rather than CLI flags.
  defp primer_args(opts) do
    primers = Terminal.primers(opts)

    with [_ | _] <- primers,
         flag when is_binary(flag) and flag != "" <-
           Application.get_env(:legend, :harness_commands, [])[:hermes_primer_flag] do
      [flag, Enum.join(primers, "\n\n")]
    else
      _ -> []
    end
  end

  defp instruction_args(opts) do
    case Terminal.instructions(opts) do
      nil -> []
      text -> [text]
    end
  end
```

- [ ] **Step 6: Run tests**

Run: `cd backend && mix test test/legend/harnesses_test.exs`
Expected: PASS (existing + new tests — the existing primer tests must still pass).

- [ ] **Step 7: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: harness MCP/messaging wiring per Terminal contract"
```

---

### Task 7: SessionServer — env injection, opts threading, debounced nudge, exit report

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex`
- Modify: `backend/config/test.exs` (fast debounce)
- Test: `backend/test/legend/core/agents/session_server_test.exs` (append)

- [ ] **Step 1: Add test config** — append to `backend/config/test.exs`:

```elixir
# Fast nudge debounce so messaging tests don't sleep.
config :legend, nudge_debounce_ms: 25
```

- [ ] **Step 2: Write the failing tests** — append to `backend/test/legend/core/agents/session_server_test.exs` (inside the module; it already has `boot!/1`, `eventually/2`, and the `%{session: session}` setup):

```elixir
  test "sessions get MCP env vars and harness opts", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, spec, _opts}

    assert spec.env["LEGEND_SESSION_ID"] == session.id
    assert spec.env["LEGEND_SESSION_TOKEN"] == session.mcp_token
    assert String.ends_with?(spec.env["LEGEND_MCP_URL"], "/api/mcp")
    # claude_code turns the mcp opts into --mcp-config args — proof build_command got them.
    assert "--mcp-config" in spec.args
  end

  test "an inbox message produces one debounced nudge write", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, _spec, _opts}

    sender = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp", name: "researcher"})

    Legend.Core.Signals.send_message!(%{
      from_session_id: sender.id,
      to_session_id: session.id,
      payload: "one"
    })

    Legend.Core.Signals.send_message!(%{
      from_session_id: sender.id,
      to_session_id: session.id,
      payload: "two"
    })

    assert_receive {:test_runtime, :write, line}, 500
    assert line =~ "2 unread message(s)"
    assert line =~ "researcher"
    assert line =~ "read_messages"
    assert String.ends_with?(line, "\r")

    # Debounce: both messages coalesced into a single write.
    refute_receive {:test_runtime, :write, _}, 200
  end

  test "no nudge after exit", %{session: session} do
    pid = boot!(session)
    assert_receive {:test_runtime, :start, _spec, _opts}
    send(pid, {:runtime_exit, 0})
    eventually(fn -> Agents.get_session!(session.id).status == :exited end)

    Legend.Core.Signals.send_message!(%{to_session_id: session.id, payload: "anyone home?"})
    refute_receive {:test_runtime, :write, _}, 200
  end

  test "exit posts a system message to the spawner", %{session: session} do
    child =
      Agents.start_session!(%{
        harness_id: "hermes",
        runtime_id: "test",
        cwd: "/tmp",
        spawned_by_session_id: session.id
      })

    SessionServer.ensure_stopped(child.id)
    pid = boot!(child)
    send(pid, {:runtime_exit, 0})

    eventually(fn ->
      Enum.any?(
        Legend.Core.Signals.unread_messages!(session.id),
        &(&1.kind == :system and &1.payload =~ "exited with code 0")
      )
    end)
  end
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd backend && mix test test/legend/core/agents/session_server_test.exs`
Expected: new tests FAIL (no MCP env, no nudge writes, no system message).

- [ ] **Step 4: Implement in SessionServer**

In `backend/lib/legend/core/agents/session_server.ex`:

Add aliases at the top:

```elixir
  alias Legend.Core.Harness.Terminal
  alias Legend.Core.Signals
```

Add the module attribute after the aliases:

```elixir
  @nudge_debounce_ms Application.compile_env(:legend, :nudge_debounce_ms, 2_000)
```

Replace the `with` block in `init/1` so opts are threaded and the inbox is subscribed (the harness module is kept in state for nudge formatting):

```elixir
    with {:ok, harness} <- fetch_registered(Legend.Core.Harness.Registry, session.harness_id),
         {:ok, runtime} <- fetch_registered(Legend.Core.Runtime.Registry, session.runtime_id),
         spec = harness.build_command(build_opts(session)),
         spec = %{spec | env: Map.merge(spec.env, platform_env(session))},
         {:ok, handle} <- runtime.start(spec, %{owner: self(), cwd: session.cwd}) do
      try do
        session = Agents.mark_session_running!(session)
        Phoenix.PubSub.subscribe(Legend.PubSub, Signals.Notifications.inbox_topic(session.id))
        broadcast(session.id, {:session_status, :running})
        Notifications.sessions_changed()

        {:ok,
         %{
           session: session,
           harness: harness,
           runtime: runtime,
           handle: handle,
           scrollback: Scrollback.new(),
           offset: 0,
           exited?: false,
           nudge_count: 0,
           nudge_froms: MapSet.new(),
           nudge_timer: nil
         }}
```

(The `rescue`/`else` clauses stay exactly as they are.)

Add the private helpers near `fetch_registered/2`:

```elixir
  defp build_opts(session) do
    base = %{
      library: %{path: Legend.Core.Library.root(), primer: Legend.Core.Library.primer()},
      messaging: %{
        primer: Signals.messaging_primer(session),
        instructions: session.instructions
      }
    }

    case session.mcp_token do
      nil -> base
      token -> Map.put(base, :mcp, %{url: mcp_url(), token: token})
    end
  end

  # The endpoint knows the reachable base URL in every mode (dev :4100,
  # web/sidecar :4807, test :4002).
  defp mcp_url, do: LegendWeb.Endpoint.url() <> "/api/mcp"

  defp platform_env(session) do
    %{"LEGEND_LIBRARY" => Legend.Core.Library.root(), "LEGEND_SESSION_ID" => session.id}
    |> maybe_put("LEGEND_MCP_URL", session.mcp_token && mcp_url())
    |> maybe_put("LEGEND_SESSION_TOKEN", session.mcp_token)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
```

Add the nudge handlers, directly above the `{:runtime_exit, ...}` clauses:

```elixir
  def handle_info({:new_message, _summary}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:new_message, summary}, state) do
    timer = state.nudge_timer || Process.send_after(self(), :nudge_flush, @nudge_debounce_ms)

    {:noreply,
     %{
       state
       | nudge_count: state.nudge_count + 1,
         nudge_froms: MapSet.put(state.nudge_froms, summary.from_label),
         nudge_timer: timer
     }}
  end

  def handle_info(:nudge_flush, %{exited?: true} = state), do: {:noreply, reset_nudge(state)}
  def handle_info(:nudge_flush, %{nudge_count: 0} = state), do: {:noreply, reset_nudge(state)}

  def handle_info(:nudge_flush, state) do
    from = state.nudge_froms |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")
    line = Terminal.nudge_line(state.harness, state.nudge_count, from)
    state.runtime.write(state.handle, line <> "\r")
    {:noreply, reset_nudge(state)}
  end

  defp reset_nudge(state) do
    %{state | nudge_count: 0, nudge_froms: MapSet.new(), nudge_timer: nil}
  end
```

Extend the live `{:runtime_exit, code}` clause to report to the spawner — add one line before `broadcast`:

```elixir
  def handle_info({:runtime_exit, code}, state) do
    session = Agents.finish_session!(state.session, %{exit_code: code})
    notify_spawner_of_exit(session, code)
    broadcast(session.id, {:session_exit, code})
    Notifications.sessions_changed()
    {:noreply, %{state | session: session, exited?: true}}
  end
```

And add the helper:

```elixir
  defp notify_spawner_of_exit(%{spawned_by_session_id: nil}, _code), do: :ok

  defp notify_spawner_of_exit(session, code) do
    # Best effort: a failed system message must not break exit handling.
    Signals.send_message(%{
      from_session_id: session.id,
      to_session_id: session.spawned_by_session_id,
      kind: :system,
      payload:
        "Session #{session.name || session.harness_id} (#{session.id}) exited with code #{inspect(code)}."
    })

    :ok
  end
```

- [ ] **Step 5: Run the full backend suite** (this task touches the core path)

Run: `cd backend && mix test`
Expected: PASS — including the pre-existing `LEGEND_LIBRARY` env test (the env merge must keep it).

- [ ] **Step 6: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: SessionServer MCP env, debounced PTY nudge, exit reports"
```

---

### Task 8: `signals:timeline` channel

**Files:**
- Create: `backend/lib/legend_web/channels/signals_channel.ex`
- Modify: `backend/lib/legend_web/channels/user_socket.ex`
- Test: `backend/test/legend_web/channels/signals_channel_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LegendWeb.SignalsChannelTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Core.Agents
  alias Legend.Core.Signals

  setup do
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    a = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
    b = Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    %{a: a, b: b}
  end

  test "join replays recent messages oldest-first", %{a: a, b: b} do
    Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "old"})
    Signals.send_message!(%{from_session_id: b.id, to_session_id: a.id, payload: "new"})

    {:ok, %{messages: [first, second]}, _socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SignalsChannel, "signals:timeline")

    assert first.payload == "old"
    assert second.payload == "new"
    assert first.from_label == "claude_code"
  end

  test "new messages and read events are pushed live", %{a: a, b: b} do
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SignalsChannel, "signals:timeline")

    message = Signals.send_message!(%{from_session_id: a.id, to_session_id: b.id, payload: "live"})
    assert_push "message", %{payload: "live", kind: :message}

    Signals.read_inbox!(b.id)
    assert_push "read", %{session_id: session_id, ids: ids}
    assert session_id == b.id
    assert ids == [message.id]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/channels/signals_channel_test.exs`
Expected: FAIL — channel module undefined.

- [ ] **Step 3: Create the channel**

`backend/lib/legend_web/channels/signals_channel.ex`:

```elixir
defmodule LegendWeb.SignalsChannel do
  @moduledoc """
  Live message timeline for the UI. Join replies with the recent window
  (oldest-first); `message` pushes each new envelope, `read` pushes read ids
  so unread badges stay accurate.
  """

  use LegendWeb, :channel

  alias Legend.Core.Signals
  alias Legend.Core.Signals.Notifications

  @impl true
  def join("signals:timeline", _payload, socket) do
    Phoenix.PubSub.subscribe(Legend.PubSub, Notifications.timeline_topic())

    messages =
      Signals.list_messages!()
      |> Enum.reverse()
      |> Enum.map(&Notifications.summary/1)

    {:ok, %{messages: messages}, socket}
  end

  @impl true
  def handle_info({:signal, summary}, socket) do
    push(socket, "message", summary)
    {:noreply, socket}
  end

  def handle_info({:signals_read, payload}, socket) do
    push(socket, "read", payload)
    {:noreply, socket}
  end
end
```

- [ ] **Step 4: Register it** — in `backend/lib/legend_web/channels/user_socket.ex`, after the `sessions:lobby` line:

```elixir
  channel "signals:timeline", LegendWeb.SignalsChannel
```

- [ ] **Step 5: Run tests**

Run: `cd backend && mix test test/legend_web/channels/signals_channel_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: signals:timeline channel"
```

---

### Task 9: frontend messaging foundation (`messages.ts`, store, Session type)

**Files:**
- Create: `frontend/src/lib/messages.ts`
- Create: `frontend/src/lib/stores/messages.svelte.ts`
- Modify: `frontend/src/lib/sessions.ts` (Session interface)

- [ ] **Step 1: Create `frontend/src/lib/messages.ts`**

```typescript
import { apiBase } from './api';

export type MessageKind = 'message' | 'handoff' | 'system';

export interface Message {
	id: string;
	from_session_id: string | null;
	from_label: string;
	to_session_id: string;
	kind: MessageKind;
	payload: string;
	read_at: string | null;
	inserted_at: string;
}

const JSONAPI = 'application/vnd.api+json';

/** Human composer: POSTs the send_as_human action (sender is always the human). */
export async function sendMessage(to_session_id: string, payload: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/messages`, {
		method: 'POST',
		headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
		body: JSON.stringify({ data: { type: 'message', attributes: { to_session_id, payload } } })
	});
	if (!res.ok) {
		let detail = `${res.status}`;
		try {
			const body = await res.json();
			detail = body?.errors?.[0]?.detail ?? body?.errors?.[0]?.title ?? detail;
		} catch {
			// keep status code
		}
		throw new Error(`sending message failed: ${detail}`);
	}
}
```

- [ ] **Step 2: Create `frontend/src/lib/stores/messages.svelte.ts`** (mirrors `sessions.svelte.ts`; the timeline channel is the data source — no REST fetch needed):

```typescript
import type { Message } from '$lib/messages';
import { getSocket } from '$lib/socket';
import type { Channel } from 'phoenix';

class MessagesStore {
	messages = $state<Message[]>([]);
	loaded = $state(false);
	#channel: Channel | undefined;

	/** Joins the timeline once; the join reply replaces the list, pushes append. */
	connect(): void {
		if (this.#channel) return;
		this.#channel = getSocket().channel('signals:timeline');
		this.#channel.on('message', (m: Message) => {
			this.messages = [...this.messages, m];
		});
		this.#channel.on('read', ({ ids }: { session_id: string; ids: string[] }) => {
			const read = new Set(ids);
			this.messages = this.messages.map((m) =>
				read.has(m.id) ? { ...m, read_at: m.read_at ?? new Date().toISOString() } : m
			);
		});
		// 'ok' fires on every (re)join, replacing the list — a backend restart
		// resyncs whatever we missed.
		this.#channel.join().receive('ok', (reply: { messages: Message[] }) => {
			this.messages = reply.messages;
			this.loaded = true;
		});
	}

	unreadCount(sessionId: string): number {
		return this.messages.filter((m) => m.to_session_id === sessionId && !m.read_at).length;
	}

	forSession(sessionId: string): Message[] {
		return this.messages.filter(
			(m) => m.from_session_id === sessionId || m.to_session_id === sessionId
		);
	}
}

export const messagesStore = new MessagesStore();
```

- [ ] **Step 3: Extend the Session interface** — in `frontend/src/lib/sessions.ts`, add to `interface Session` after `cwd`:

```typescript
	spawned_by_session_id: string | null;
```

- [ ] **Step 4: Verify**

Run: `cd frontend && bun run check`
Expected: 0 errors.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib && git commit -m "feat: frontend messages API + timeline store"
```

---

### Task 10: global timeline page (`/messages`) + nav link

**Files:**
- Create: `frontend/src/routes/messages/+page.svelte`
- Create: `frontend/src/lib/components/MessageComposer.svelte`
- Modify: `frontend/src/lib/components/SessionSidebar.svelte` (nav link)

- [ ] **Step 1: Create the composer component** (shared by the timeline page and Task 11's panel)

`frontend/src/lib/components/MessageComposer.svelte`:

```svelte
<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import { sendMessage } from '$lib/messages';
	import { sessionsStore } from '$lib/stores/sessions.svelte';

	// Fixed target (per-session panel) or undefined (timeline picker).
	let { target }: { target?: string } = $props();

	let selected = $state('');
	let draft = $state('');
	let error = $state<string | null>(null);
	let sending = $state(false);

	const sessions = $derived(
		sessionsStore.sessions.filter((s) => s.status === 'running' || s.status === 'starting')
	);
	const to = $derived(target ?? selected);

	async function send() {
		if (!to || !draft.trim() || sending) return;
		sending = true;
		error = null;
		try {
			await sendMessage(to, draft.trim());
			draft = '';
		} catch (e) {
			error = e instanceof Error ? e.message : 'sending failed';
		} finally {
			sending = false;
		}
	}
</script>

<div class="flex flex-col gap-2 border-t pt-2">
	{#if error}
		<p class="text-sm text-destructive">{error}</p>
	{/if}
	<div class="flex gap-2">
		{#if !target}
			<select bind:value={selected} class="h-9 rounded-md border bg-background px-2 text-sm">
				<option value="" disabled>To session…</option>
				{#each sessions as s (s.id)}
					<option value={s.id}>{s.name || s.harness_id}</option>
				{/each}
			</select>
		{/if}
		<input
			bind:value={draft}
			placeholder="Message as human…"
			class="h-9 min-w-0 flex-1 rounded-md border bg-background px-2 text-sm"
			onkeydown={(e) => e.key === 'Enter' && send()}
		/>
		<Button size="sm" onclick={send} disabled={!to || !draft.trim() || sending}>Send</Button>
	</div>
</div>
```

- [ ] **Step 2: Create the timeline page**

`frontend/src/routes/messages/+page.svelte`:

```svelte
<script lang="ts">
	import MessageComposer from '$lib/components/MessageComposer.svelte';
	import type { Message } from '$lib/messages';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';

	$effect(() => {
		messagesStore.connect();
		sessionsStore.connect();
	});

	const byId = $derived(new Map(sessionsStore.sessions.map((s) => [s.id, s])));

	// Delegation chain root: walk spawned_by links (cycle-safe).
	function rootOf(id: string): string {
		let current = id;
		const seen = new Set<string>();
		while (!seen.has(current)) {
			seen.add(current);
			const parent = byId.get(current)?.spawned_by_session_id;
			if (!parent) break;
			current = parent;
		}
		return current;
	}

	function sessionLabel(id: string | null): string {
		if (!id) return 'human';
		const s = byId.get(id);
		return s ? s.name || s.harness_id : `${id.slice(0, 8)}…`;
	}

	interface Group {
		root: string;
		messages: Message[];
	}

	const groups = $derived.by((): Group[] => {
		const map = new Map<string, Message[]>();
		for (const m of messagesStore.messages) {
			const key = rootOf(m.from_session_id ?? m.to_session_id);
			map.set(key, [...(map.get(key) ?? []), m]);
		}
		return [...map.entries()]
			.map(([root, messages]) => ({ root, messages }))
			.sort((a, b) =>
				b.messages[b.messages.length - 1].inserted_at.localeCompare(
					a.messages[a.messages.length - 1].inserted_at
				)
			);
	});

	const kindBadge: Record<string, string> = {
		message: 'bg-accent text-accent-foreground',
		handoff: 'bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200',
		system: 'bg-muted text-muted-foreground'
	};
</script>

<div class="flex h-full flex-col gap-3 p-4">
	<h1 class="text-lg font-semibold">Messages</h1>

	<div class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto">
		{#each groups as group (group.root)}
			<section class="rounded-lg border">
				<header class="border-b px-3 py-2 text-sm font-medium">
					{sessionLabel(group.root)} — thread
				</header>
				<ul class="flex flex-col gap-2 p-3">
					{#each group.messages as m (m.id)}
						<li class="flex items-baseline gap-2 text-sm">
							<span class="rounded px-1.5 py-0.5 text-xs {kindBadge[m.kind]}">{m.kind}</span>
							<span class="shrink-0 font-medium">{m.from_label}</span>
							<span class="shrink-0 text-muted-foreground">→ {sessionLabel(m.to_session_id)}</span>
							<span class="min-w-0 whitespace-pre-wrap break-words">{m.payload}</span>
							{#if !m.read_at}
								<span class="ml-auto shrink-0 text-xs text-amber-600">unread</span>
							{/if}
						</li>
					{/each}
				</ul>
			</section>
		{:else}
			{#if messagesStore.loaded}
				<p class="text-sm text-muted-foreground">No messages yet. Agents (and you) can talk here.</p>
			{/if}
		{/each}
	</div>

	<MessageComposer />
</div>
```

- [ ] **Step 3: Add the nav link** — in `frontend/src/lib/components/SessionSidebar.svelte`, replace the bottom nav with a three-way version:

```svelte
	<nav class="flex shrink-0 gap-1 border-t pt-2 text-sm">
		<a
			href="/"
			class="flex-1 rounded-md px-2 py-1.5 text-center hover:bg-accent
				{!page.url.pathname.startsWith('/library') && !page.url.pathname.startsWith('/messages') ? 'bg-accent' : ''}">Sessions</a
		>
		<a
			href="/messages"
			class="flex-1 rounded-md px-2 py-1.5 text-center hover:bg-accent
				{page.url.pathname.startsWith('/messages') ? 'bg-accent' : ''}">Messages</a
		>
		<a
			href="/library"
			class="flex-1 rounded-md px-2 py-1.5 text-center hover:bg-accent
				{page.url.pathname.startsWith('/library') ? 'bg-accent' : ''}">Library</a
		>
	</nav>
```

- [ ] **Step 4: Verify**

Run: `cd frontend && bun run check`
Expected: 0 errors. Then a quick manual smoke: `just dev`, open http://localhost:5173/messages, send a message to a running session from the composer, and watch it appear in the timeline.

- [ ] **Step 5: Commit**

```bash
git add frontend/src && git commit -m "feat: global message timeline page with human composer"
```

---

### Task 11: per-session messages panel + sidebar unread badges

**Files:**
- Create: `frontend/src/lib/components/MessagesPanel.svelte`
- Modify: `frontend/src/routes/sessions/[id]/+page.svelte`
- Modify: `frontend/src/lib/components/SessionSidebar.svelte` (badges)

- [ ] **Step 1: Create the panel**

`frontend/src/lib/components/MessagesPanel.svelte`:

```svelte
<script lang="ts">
	import MessageComposer from '$lib/components/MessageComposer.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';

	let { sessionId }: { sessionId: string } = $props();

	$effect(() => {
		messagesStore.connect();
	});

	const messages = $derived(messagesStore.forSession(sessionId));
</script>

<div class="flex h-full w-80 shrink-0 flex-col border-l">
	<header class="border-b px-3 py-2 text-sm font-medium">Messages</header>
	<ul class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-3">
		{#each messages as m (m.id)}
			<li class="text-sm">
				<div class="flex items-baseline gap-2">
					<span class="font-medium">{m.from_label}</span>
					<span class="text-xs text-muted-foreground">{m.kind}</span>
					{#if m.to_session_id !== sessionId}
						<span class="text-xs text-muted-foreground">→ out</span>
					{:else if !m.read_at}
						<span class="ml-auto text-xs text-amber-600">unread</span>
					{/if}
				</div>
				<p class="whitespace-pre-wrap break-words">{m.payload}</p>
			</li>
		{:else}
			<li class="text-sm text-muted-foreground">No messages for this session.</li>
		{/each}
	</ul>
	<div class="p-3 pt-0">
		<MessageComposer target={sessionId} />
	</div>
</div>
```

- [ ] **Step 2: Mount it collapsibly in the session page** — in `frontend/src/routes/sessions/[id]/+page.svelte`:

Add to the script block:

```typescript
	import MessagesPanel from '$lib/components/MessagesPanel.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';

	let showMessages = $state(false);
	const unread = $derived(messagesStore.unreadCount(sessionId));
```

Add a toggle button inside the `ml-auto` button group, before the Stop/Delete button:

```svelte
				<Button variant="outline" size="sm" onclick={() => (showMessages = !showMessages)}>
					Messages{#if unread > 0}&nbsp;({unread}){/if}
				</Button>
```

Replace the terminal container div at the bottom with a row that hosts both:

```svelte
	<div class="flex min-h-0 flex-1">
		<div class="min-h-0 min-w-0 flex-1">
			{#key sessionId}
				<Terminal bind:this={terminal} {sessionId} onstatus={handleStatus} />
			{/key}
		</div>
		{#if showMessages}
			<MessagesPanel {sessionId} />
		{/if}
	</div>
```

- [ ] **Step 3: Sidebar unread badges** — in `frontend/src/lib/components/SessionSidebar.svelte`:

Add to the script block:

```typescript
	import { messagesStore } from '$lib/stores/messages.svelte';
```

And extend the existing `$effect` to also connect the messages store:

```typescript
	$effect(() => {
		sessionsStore.connect();
		messagesStore.connect();
	});
```

In the session list item, insert a badge between the name span and the harness span:

```svelte
				{#if messagesStore.unreadCount(session.id) > 0}
					<span class="shrink-0 rounded-full bg-amber-500 px-1.5 text-xs text-white">
						{messagesStore.unreadCount(session.id)}
					</span>
				{/if}
```

- [ ] **Step 4: Verify**

Run: `cd frontend && bun run check`
Expected: 0 errors.

- [ ] **Step 5: Commit**

```bash
git add frontend/src && git commit -m "feat: per-session messages panel and unread badges"
```

---

### Task 12: full verification + acceptance demo

- [ ] **Step 1: Backend precommit**

Run: `cd backend && mix precommit`
Expected: compiles with no warnings, format clean, all tests pass.

- [ ] **Step 2: Frontend check + build**

Run: `cd frontend && bun run check && bun run build`
Expected: 0 errors, build succeeds.

- [ ] **Step 3: Manual acceptance demo** (requires a real `claude` CLI on PATH)

1. `just dev`, open http://localhost:5173.
2. Start a Claude Code session.
3. In its terminal, type: *"Use your legend MCP tools: start_agent with harness `claude_code`, name `helper`, instructions 'Reply to your requester with the single word PONG via send_message, then exit.' Then wait for its reply and tell me what it said."*
4. Observe, in order: the helper session appears in the sidebar (spawned); the `/messages` timeline shows the `system` spawn record; the helper calls `send_message` (timeline shows it); the first session's terminal receives the `[legend] 1 unread message(s) from helper…` nudge; it calls `read_messages` and reports "PONG"; when the helper exits, the timeline shows the exit `system` message.
5. From `/messages`, send a human message to the running session and confirm the nudge + `read_messages` round-trip.
6. Note for the demo: `--allowed-tools mcp__legend` pre-allows the tools, so no permission prompts should appear. If Claude Code still prompts, approve and file the flag form for follow-up.

- [ ] **Step 4: Final commit (if the demo surfaced fixes)**

```bash
git add -A && git commit -m "fix: acceptance-demo polish for agent messaging"
```

---

## Self-review notes (spec → plan coverage)

- Message resource w/ unread-rows inbox → Task 1. `spawned_by`/`instructions`/token → Task 2. Broadcasts + `read_inbox!` → Task 3. Five tools + primer + cap + audit records → Task 4. MCP endpoint + token auth → Task 5. Terminal contract (`mcp`/`messaging` opts, `nudge_line`), Claude Code `--mcp-config`/`--allowed-tools`/positional prompt, Hermes env-fallback → Task 6. Env injection, debounced nudge, no-nudge-after-exit, exit→system message → Task 7. Timeline channel (replay + live + read events) → Task 8. Frontend store/API → Task 9, timeline page + composer + nav → Task 10, panel + badges → Task 11, verification + demo → Task 12.
- Spec items deliberately *not* tasked: rooms, baton enforcement, ACP/native adapters (non-goals); GET /api/mcp SSE listening (spec'd as plain-JSON streamable HTTP; Claude Code tolerates 4xx on its optional GET).
