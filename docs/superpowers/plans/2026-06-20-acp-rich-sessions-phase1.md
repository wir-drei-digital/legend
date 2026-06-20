# ACP Rich Sessions — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run an ACP (Agent Client Protocol) Claude Code session on the local runtime with a rich structured UI, switchable live with the existing terminal transport.

**Architecture:** Generalize the session spine — `Definition.kind` becomes `transports`, the session gains `transport` + `conversation_id`, the byte scrollback becomes one `Transcript` implementation alongside an `AcpTimeline`. An in-process `Legend.Core.Acp.Connection` codec speaks newline-delimited JSON-RPC 2.0 over the runtime's `:pipes` byte stream, reducing ACP `session/update` notifications into render-ready timeline items and round-tripping permission requests. The frontend `SessionPane` renders `AcpConversation` vs `Terminal` by `session.transport`.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 / AshSqlite, erlexec (PTY + pipes), Phoenix Channels; SvelteKit 2 / Svelte 5 runes / Tailwind v4 + shadcn-svelte; `claude-code-acp` adapter (Node).

## Global Constraints

- **Registry ids are strings end-to-end** — never `String.to_atom` on user input (atom-exhaustion DoS).
- **No new MCP/ACP library** — hand-roll JSON-RPC (matches the existing hand-rolled MCP decision).
- **Clean over compat** — replace `Definition.kind` outright and migrate every reader; no compat shims (early-stage project).
- **SQLite has no atomic updates** — every custom update action needs `require_atomic? false`.
- **No PTY injection for ACP** — input flows as `session/prompt`, never as fake keystrokes.
- **Token discipline (frontend)** — Legend tokens (`text-ink-*`, `bg-app/shell/panel`, `text-micro…title`) + shell primitives; raw shadcn neutral classes / ad-hoc hex / ad-hoc `text-[Npx]` only inside `src/lib/components/ui/`.
- **Run before finishing backend work:** `cd backend && mix precommit`. **Frontend:** `cd frontend && bun run check`.
- **Phase 1 does NOT advertise client-side `fs`/`terminal` ACP capabilities** — the agent uses its native tools; we render the resulting tool calls.
- **Approved UI mockups** (port markup/CSS from these, wire real data): `.superpowers/brainstorm/27163-1781950254/content/acp-surface-v4.html`.

---

## File structure

**Backend (create):**
- `backend/lib/legend/core/harness/acp.ex` — the `Acp` sub-behaviour (`acp_command/1`).
- `backend/lib/legend/core/agents/transcript.ex` — `Transcript` protocol + `ByteScrollback` + `AcpTimeline`.
- `backend/lib/legend/core/acp/connection.ex` — JSON-RPC codec + ACP→item reduction.

**Backend (modify):**
- `backend/lib/legend/core/harness.ex` — `Definition`: `kind` → `transports`.
- `backend/lib/legend/harnesses/claude_code.ex` — `transports`, `acp_command/1`.
- `backend/lib/legend/harnesses/hermes.ex` — `transports: [:terminal]`.
- `backend/lib/legend_web/controllers/harness_controller.ex` — emit `transports`.
- `backend/lib/legend/core/agents/session.ex` — `transport`/`conversation_id` attrs + `set_conversation_id`/`set_transport` actions + `:start` transport default.
- `backend/lib/legend/core/agents.ex` — code interfaces for the new actions + json_api route for `set_transport`.
- `backend/lib/legend/runtimes/local_pty.ex` — `:pipes` mode.
- `backend/lib/legend/core/agents/session_server.ex` — transport branching (launch, IO, lifecycle).
- `backend/lib/legend_web/channels/session_channel.ex` — ACP join snapshot + inbound/outbound.

**Frontend (create):**
- `frontend/src/lib/shell/acpSession.svelte.ts` — ACP channel client + reducer store.
- `frontend/src/lib/components/sessions/AcpConversation.svelte` — the rich surface.
- `frontend/src/lib/components/sessions/acp-parts/` — `ToolCall.svelte`, `PermissionCard.svelte`, `PlanBar.svelte`, `Queue.svelte`, `Composer.svelte`.

**Frontend (modify):**
- `frontend/src/lib/sessions.ts` — types + `setTransport`.
- `frontend/src/lib/components/sessions/SessionPane.svelte` — pick renderer by transport + toggle.

---

## Task 1: Harness `transports` replaces `kind`

**Files:**
- Modify: `backend/lib/legend/core/harness.ex:13-24`
- Modify: `backend/lib/legend/harnesses/claude_code.ex:12-20`
- Modify: `backend/lib/legend/harnesses/hermes.ex` (definition)
- Modify: `backend/lib/legend_web/controllers/harness_controller.ex:12`
- Test: `backend/test/legend/core/harness_test.exs` (create if absent), `backend/test/legend_web/controllers/harness_controller_test.exs`

**Interfaces:**
- Produces: `%Legend.Core.Harness.Definition{transports: [:terminal | :acp | :native]}` (first entry = default). `ClaudeCode` → `[:acp, :terminal]`; `Hermes` → `[:terminal]`. `GET /api/harnesses` items carry `transports` (list of strings) instead of `kind`.

- [ ] **Step 1: Write the failing test** — `backend/test/legend/core/harness_test.exs`:

```elixir
defmodule Legend.Core.HarnessTest do
  use ExUnit.Case, async: true

  test "ClaudeCode advertises acp + terminal, acp first" do
    assert Legend.Harnesses.ClaudeCode.definition().transports == [:acp, :terminal]
  end

  test "Hermes is terminal-only" do
    assert Legend.Harnesses.Hermes.definition().transports == [:terminal]
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `cd backend && mix test test/legend/core/harness_test.exs`
Expected: FAIL (`key :transports not found` / `kind` still present).

- [ ] **Step 3: Edit `Definition`** in `harness.ex`:

```elixir
defmodule Definition do
  @enforce_keys [:id, :name]
  defstruct [:id, :name, description: "", resumable: false, transports: [:terminal]]

  @type transport :: :terminal | :acp | :native
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t(),
          resumable: boolean(),
          transports: [transport()]
        }
end
```

Update the moduledoc line that mentions `kind` to describe `transports` (the first entry is the default transport; a session's active transport lives on the session record).

- [ ] **Step 4: Update `ClaudeCode.definition/0`** (`claude_code.ex`): remove `kind: :terminal`, add `transports: [:acp, :terminal]`. Update `Hermes.definition/0`: remove `kind:`, add `transports: [:terminal]`.

- [ ] **Step 5: Update `HarnessController.index/2`** — replace `kind: d.kind,` with `transports: d.transports,`.

- [ ] **Step 6: Fix existing references** — `cd backend && grep -rn "\.kind" lib test | grep -i harness`. Update any test asserting `kind`. (The HarnessController test should assert `transports`.)

- [ ] **Step 7: Run tests**

Run: `cd backend && mix test test/legend/core/harness_test.exs test/legend_web/controllers/harness_controller_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/lib/legend/core/harness.ex backend/lib/legend/harnesses backend/lib/legend_web/controllers/harness_controller.ex backend/test
git commit -m "feat(harness): replace Definition.kind with transports"
```

---

## Task 2: `Legend.Core.Harness.Acp` behaviour + `ClaudeCode.acp_command/1`

**Files:**
- Create: `backend/lib/legend/core/harness/acp.ex`
- Modify: `backend/lib/legend/harnesses/claude_code.ex`
- Test: `backend/test/legend/harnesses/claude_code_test.exs`

**Interfaces:**
- Produces: `Legend.Core.Harness.Acp.acp_command(opts) :: %CommandSpec{io: :pipes}` where `opts :: %{optional(:env) => %{String.t => String.t}}`. `ClaudeCode` implements it: `cmd` from config key `:claude_code_acp` (default `"claude-code-acp"`), `env` merged with `opts.env`. `ClaudeCode` keeps `build_command/1` (terminal) unchanged.

- [ ] **Step 1: Write the failing test** — add to `claude_code_test.exs`:

```elixir
test "acp_command returns a :pipes spec for the adapter" do
  spec = Legend.Harnesses.ClaudeCode.acp_command(%{env: %{"FOO" => "bar"}})
  assert spec.io == :pipes
  assert spec.cmd == "claude-code-acp"
  assert spec.env["FOO"] == "bar"
end
```

- [ ] **Step 2: Run, expect failure**

Run: `cd backend && mix test test/legend/harnesses/claude_code_test.exs -k acp_command`
Expected: FAIL (`function acp_command/1 undefined`).

- [ ] **Step 3: Create the behaviour** — `harness/acp.ex`:

```elixir
defmodule Legend.Core.Harness.Acp do
  @moduledoc """
  Contract for harnesses driven over the Agent Client Protocol. The harness only
  describes how to SPAWN its adapter subprocess (`io: :pipes`). The ACP wiring —
  cwd, mcpServers, instructions, session/new vs session/load — is standard
  protocol and is driven generically by the SessionServer + Acp.Connection, not
  per-harness.
  """

  @type opts :: %{optional(:env) => %{String.t() => String.t()}}
  @callback acp_command(opts()) :: Legend.Core.Runtime.CommandSpec.t()
end
```

- [ ] **Step 4: Implement in `ClaudeCode`** — add `@behaviour Legend.Core.Harness.Acp` and:

```elixir
@impl Legend.Core.Harness.Acp
def acp_command(opts) do
  [cmd | args] = configured_command(:claude_code_acp, "claude-code-acp")
  %CommandSpec{cmd: cmd, args: args, env: opts[:env] || %{}, io: :pipes}
end
```

(`configured_command/2` already exists in the module.)

- [ ] **Step 5: Run, expect PASS**

Run: `cd backend && mix test test/legend/harnesses/claude_code_test.exs`

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/core/harness/acp.ex backend/lib/legend/harnesses/claude_code.ex backend/test/legend/harnesses/claude_code_test.exs
git commit -m "feat(harness): add Acp behaviour + ClaudeCode.acp_command/1"
```

---

## Task 3: Session `transport` + `conversation_id` (attributes, actions, defaults)

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex`
- Modify: `backend/lib/legend/core/agents.ex`
- Test: `backend/test/legend/core/agents/session_test.exs` (or existing sessions test)

**Interfaces:**
- Produces: `session.transport :: :terminal | :acp` (default = first of the harness's `transports`), `session.conversation_id :: String.t | nil`. New code interfaces `Legend.Core.Agents.set_session_conversation_id(session, %{conversation_id: id})` and `Legend.Core.Agents.set_session_transport(session, %{transport: t})`.

- [ ] **Step 1: Write the failing test**:

```elixir
test "start defaults transport from the harness (claude_code → :acp)" do
  {:ok, s} = Legend.Core.Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
  assert s.transport == :acp
end

test "set_session_conversation_id persists the agent handle" do
  {:ok, s} = Legend.Core.Agents.start_session(%{harness_id: "claude_code", runtime_id: "test"})
  s = Legend.Core.Agents.set_session_conversation_id(s, %{conversation_id: "abc-123"})
  assert s.conversation_id == "abc-123"
end
```

- [ ] **Step 2: Run, expect failure**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: FAIL (`transport` unknown).

- [ ] **Step 3: Add attributes** in `session.ex` `attributes do` block (after `runtime_ref`):

```elixir
attribute :transport, :atom,
  allow_nil?: false,
  default: :terminal,
  public?: true,
  constraints: [one_of: [:terminal, :acp]]

# The agent's durable conversation handle. Pinned to the session id for terminal
# (--session-id), captured from the adapter for ACP (session/new). nil until the
# first launch resolves it.
attribute :conversation_id, :string, public?: true
```

- [ ] **Step 4: Default transport in `:start`** — add a change inside the `create :start` block (after the validations):

```elixir
change fn changeset, _context ->
  case Ash.Changeset.get_attribute(changeset, :transport) do
    nil ->
      hid = Ash.Changeset.get_attribute(changeset, :harness_id)
      Ash.Changeset.force_change_attribute(changeset, :transport, default_transport(hid))

    _ ->
      changeset
  end
end
```

Accept `:transport` so the picker can override the default: add `:transport` to the `accept [...]` list in `:start`. Add the helper at the bottom of the module:

```elixir
@doc false
def default_transport(harness_id) do
  with {:ok, mod} <- Legend.Core.Harness.Registry.fetch(harness_id),
       [first | _] <- mod.definition().transports do
    first
  else
    _ -> :terminal
  end
end
```

- [ ] **Step 5: Add update actions** in `actions do`:

```elixir
update :set_conversation_id do
  require_atomic? false
  accept [:conversation_id]
end

update :set_transport do
  require_atomic? false
  accept [:transport]

  # Relaunch into the same conversation under the new transport, if live.
  change before_action(fn changeset, _context ->
           Legend.Core.Agents.SessionServer.ensure_stopped(changeset.data.id)
           changeset
         end)

  change after_transaction(fn
           _changeset, {:ok, session}, _context ->
             case Legend.Core.Agents.SessionServer.start_session(session, :resume) do
               {:ok, _pid} -> {:ok, Legend.Core.Agents.get_session!(session.id)}
               :ignore -> {:ok, Legend.Core.Agents.get_session!(session.id)}
               {:error, {:already_started, _}} -> {:ok, Legend.Core.Agents.get_session!(session.id)}
               {:error, reason} -> {:ok, Legend.Core.Agents.fail_session!(session, %{error: inspect(reason)})}
             end

           _changeset, {:error, _} = error, _context ->
             error
         end)
end
```

- [ ] **Step 6: Add code interfaces + route** in `agents.ex`:

In `resources do … resource Session do`:
```elixir
define :set_session_conversation_id, action: :set_conversation_id
define :set_session_transport, action: :set_transport
```
In `json_api do … base_route` (next to the resume route):
```elixir
patch :set_transport, route: "/:id/transport"
```

- [ ] **Step 7: Generate the migration**

Run: `cd backend && mix ash.codegen acp_session_fields`
Then: `mix ecto.migrate`
Expected: migration adds `transport` (default 'terminal') + `conversation_id`.

- [ ] **Step 8: Run tests**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add backend/lib/legend/core/agents backend/priv/repo/migrations backend/test
git commit -m "feat(session): add transport + conversation_id with set_transport action"
```

---

## Task 4: `Transcript` protocol — `ByteScrollback` + `AcpTimeline`

**Files:**
- Create: `backend/lib/legend/core/agents/transcript.ex`
- Modify: `backend/lib/legend/core/agents/scrollback.ex` (implement the protocol)
- Test: `backend/test/legend/core/agents/transcript_test.exs`

**Interfaces:**
- Produces:
  - `Legend.Core.Agents.Transcript.append(t, item) :: {t, [upsert]}` and `Legend.Core.Agents.Transcript.snapshot(t) :: {payload, cursor}`.
  - `ByteScrollback` (wraps the existing `Scrollback`): `append/2` takes a binary, returns `{t, [{offset, binary}]}`; `snapshot/1` returns `{binary, byte_offset}`.
  - `AcpTimeline.new/0`; `append/2` takes a normalized **item map** `%{"id" => String.t(), ...}`, upserts by `"id"`, assigns a monotonic `seq`, returns `{t, [item_with_seq]}`; `snapshot/1` returns `{[items], max_seq}`. Bounded to 5000 items (drop oldest).

- [ ] **Step 1: Write the failing test**:

```elixir
defmodule Legend.Core.Agents.TranscriptTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Agents.{AcpTimeline, Transcript}

  test "AcpTimeline upserts by id and bumps seq" do
    t = AcpTimeline.new()
    {t, [a]} = Transcript.append(t, %{"id" => "msg-1", "type" => "message", "text" => "hi"})
    assert a["seq"] == 1
    {t, [b]} = Transcript.append(t, %{"id" => "msg-1", "type" => "message", "text" => "hi there"})
    assert b["seq"] == 2
    {items, cursor} = Transcript.snapshot(t)
    assert cursor == 2
    assert [%{"id" => "msg-1", "text" => "hi there"}] = items
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `cd backend && mix test test/legend/core/agents/transcript_test.exs`
Expected: FAIL (modules undefined).

- [ ] **Step 3: Define the protocol + `AcpTimeline`** — `transcript.ex`:

```elixir
defprotocol Legend.Core.Agents.Transcript do
  @moduledoc """
  Polymorphic session content store. `append/2` records new content and returns
  the items to broadcast (each carrying a monotonic cursor); `snapshot/1` returns
  the full replay payload plus the cursor at which live items resume. Reattach
  drops broadcast items whose cursor <= the snapshot cursor.
  """
  @spec append(t, term()) :: {t, [term()]}
  def append(transcript, item)

  @spec snapshot(t) :: {term(), non_neg_integer()}
  def snapshot(transcript)
end

defmodule Legend.Core.Agents.AcpTimeline do
  @moduledoc "Ordered, id-keyed timeline of reduced ACP render items."
  @max_items 5_000
  defstruct order: [], items: %{}, seq: 0

  def new, do: %__MODULE__{}
end

defimpl Legend.Core.Agents.Transcript, for: Legend.Core.Agents.AcpTimeline do
  alias Legend.Core.Agents.AcpTimeline

  def append(%AcpTimeline{} = t, %{"id" => id} = item) do
    seq = t.seq + 1
    item = Map.put(item, "seq", seq)
    order = if Map.has_key?(t.items, id), do: t.order, else: t.order ++ [id]
    t = %{t | items: Map.put(t.items, id, item), order: order, seq: seq} |> trim()
    {t, [item]}
  end

  def snapshot(%AcpTimeline{} = t) do
    {Enum.map(t.order, &Map.fetch!(t.items, &1)), t.seq}
  end

  defp trim(%AcpTimeline{order: order} = t) when length(order) <= 5_000, do: t

  defp trim(%AcpTimeline{order: [drop | rest]} = t),
    do: %{t | order: rest, items: Map.delete(t.items, drop)}
end
```

- [ ] **Step 4: Implement the protocol for `Scrollback`** — append to `scrollback.ex` (a `ByteScrollback` view is unnecessary; implement on the existing struct):

```elixir
defimpl Legend.Core.Agents.Transcript, for: Legend.Core.Agents.Scrollback do
  alias Legend.Core.Agents.Scrollback

  # Bytes carry their pre-append offset as the cursor (the SessionServer already
  # tracks the running offset, but the protocol form keeps both transports uniform).
  def append(%Scrollback{} = sb, data) when is_binary(data) do
    offset = sb.bytes
    {Scrollback.append(sb, data), [{offset, data}]}
  end

  def snapshot(%Scrollback{} = sb), do: {Scrollback.to_binary(sb), sb.bytes}
end
```

Note: `Scrollback.bytes` already counts total appended bytes — but `trim/1` decrements it. For a correct monotonic byte cursor, track the offset in the SessionServer (Task 9 keeps the existing `offset` field for terminal); this `defimpl` is used only by `AcpTimeline` consumers in practice. Terminal continues to use the existing `{:session_output, offset, data}` path unchanged. Keep this `defimpl` minimal; the SessionServer owns the byte cursor for terminal.

- [ ] **Step 5: Run, expect PASS**

Run: `cd backend && mix test test/legend/core/agents/transcript_test.exs`

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/core/agents/transcript.ex backend/lib/legend/core/agents/scrollback.ex backend/test/legend/core/agents/transcript_test.exs
git commit -m "feat(agents): Transcript protocol + AcpTimeline"
```

---

## Task 5: `Acp.Connection` — framing + handshake

**Files:**
- Create: `backend/lib/legend/core/acp/connection.ex`
- Test: `backend/test/legend/core/acp/connection_test.exs`

**Interfaces:**
- Produces:
  - `Acp.Connection.new(%{cwd, mcp_servers, mode: :new | :load, conversation_id, instructions}) :: {state, [frame_binary]}` — returns the initial state and the bytes to write to the agent (the `initialize` request). Subsequent launch frames are sent reactively as responses arrive.
  - `Acp.Connection.handle_bytes(state, binary) :: {state, [upsert_item], [reply_binary], [effect]}` where `effect` ∈ `{:conversation_id, id}` | `{:load_capable, bool}` | `{:turn, stop_reason}`.
  - Frames are newline-delimited JSON; requests carry incrementing integer ids.

- [ ] **Step 1: Write the failing test** (handshake order):

```elixir
defmodule Legend.Core.Acp.ConnectionTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Acp.Connection

  defp decode_lines(frames), do: Enum.map(frames, &Jason.decode!/1)

  test "new emits initialize; initialize response triggers session/new" do
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    assert %{"method" => "initialize", "id" => init_id} = Jason.decode!(init)

    resp = Jason.encode!(%{"jsonrpc" => "2.0", "id" => init_id,
             "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}}) <> "\n"
    {_state, _items, replies, effects} = Connection.handle_bytes(state, resp)

    assert [%{"method" => "session/new", "params" => %{"cwd" => "/tmp"}}] = decode_lines(replies)
    assert {:load_capable, true} in effects
  end

  test "session/new response captures the conversation id" do
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    init_id = Jason.decode!(init)["id"]
    {state, _, _, _} = Connection.handle_bytes(state,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => init_id, "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}}) <> "\n")
    # the session/new request id is the next integer
    {_state, _items, _replies, effects} = Connection.handle_bytes(state,
      Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{"sessionId" => "sess-xyz"}}) <> "\n")
    assert {:conversation_id, "sess-xyz"} in effects
  end

  test "partial frames buffer until newline" do
    {state, [init]} = Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :new})
    init_id = Jason.decode!(init)["id"]
    full = Jason.encode!(%{"jsonrpc" => "2.0", "id" => init_id, "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}}) <> "\n"
    {a, b} = String.split_at(full, 10)
    {state, _, replies1, _} = Connection.handle_bytes(state, a)
    assert replies1 == []
    {_state, _, replies2, _} = Connection.handle_bytes(state, b)
    assert [%{"method" => "session/new"}] = decode_lines(replies2)
  end
end
```

- [ ] **Step 2: Run, expect failure**

Run: `cd backend && mix test test/legend/core/acp/connection_test.exs`
Expected: FAIL (module undefined).

- [ ] **Step 3: Implement framing + handshake** — `connection.ex`:

```elixir
defmodule Legend.Core.Acp.Connection do
  @moduledoc """
  In-process Agent Client Protocol codec. Holds JSON-RPC framing state (line
  buffer, request-id correlation, per-turn reduction state) for one ACP session.
  Pure functions: the SessionServer owns the process and the runtime IO.
  """

  @protocol_version 1

  defstruct buf: "",
            next_id: 1,
            pending: %{},
            launch: nil,
            turn: 0,
            reduce: %{}

  @type t :: %__MODULE__{}

  @spec new(map()) :: {t(), [binary()]}
  def new(launch) do
    state = %__MODULE__{launch: launch}
    {state, frame} = request(state, "initialize", %{
      "protocolVersion" => @protocol_version,
      # Phase 1: no client-side fs/terminal capabilities.
      "clientCapabilities" => %{}
    }, :initialize)

    {state, [frame]}
  end

  @spec handle_bytes(t(), binary()) :: {t(), [map()], [binary()], [tuple()]}
  def handle_bytes(state, bytes) do
    {lines, buf} = split_lines(state.buf <> bytes)
    state = %{state | buf: buf}

    Enum.reduce(lines, {state, [], [], []}, fn line, {st, items, replies, effects} ->
      case Jason.decode(line) do
        {:ok, msg} ->
          {st, i, r, e} = dispatch(st, msg)
          {st, items ++ i, replies ++ r, effects ++ e}

        {:error, _} ->
          # Malformed frame: skip, never crash the session.
          {st, items, replies, effects}
      end
    end)
  end

  # --- framing helpers ---

  defp split_lines(buf) do
    parts = String.split(buf, "\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {complete |> Enum.reject(&(&1 == "")), rest}
  end

  defp request(state, method, params, tag) do
    id = state.next_id
    frame = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}) <> "\n"
    {%{state | next_id: id + 1, pending: Map.put(state.pending, id, tag)}, frame}
  end

  defp notify(method, params),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "method" => method, "params" => params}) <> "\n"

  defp response(id, result),
    do: Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n"

  # --- dispatch: responses to our requests ---

  defp dispatch(state, %{"id" => id, "result" => result}) when is_map_key(state.pending, id) do
    {tag, pending} = Map.pop(state.pending, id)
    handle_response(%{state | pending: pending}, tag, result)
  end

  defp dispatch(state, %{"id" => id, "error" => err}) when is_map_key(state.pending, id) do
    {_tag, pending} = Map.pop(state.pending, id)
    # Surface as a soft error item; do not crash.
    item = %{"id" => "error-#{id}", "type" => "error", "text" => inspect(err)}
    {%{state | pending: pending}, [item], [], []}
  end

  # session/update notifications + agent->client requests handled in Tasks 6 & 7.
  defp dispatch(state, msg), do: dispatch_incoming(state, msg)

  defp handle_response(state, :initialize, result) do
    caps = result["agentCapabilities"] || %{}
    load? = caps["loadSession"] == true
    launch = state.launch
    mcp = launch[:mcp_servers] || []

    {state, frame} =
      case launch[:mode] do
        :load ->
          request(state, "session/load",
            %{"sessionId" => launch[:conversation_id], "cwd" => launch[:cwd], "mcpServers" => mcp},
            :session_load)

        _ ->
          request(state, "session/new",
            %{"cwd" => launch[:cwd], "mcpServers" => mcp}, :session_new)
      end

    {state, [], [frame], [{:load_capable, load?}]}
  end

  defp handle_response(state, :session_new, result) do
    cid = result["sessionId"]
    {state, replies, effects} = maybe_initial_prompt(state)
    {state, [], replies, [{:conversation_id, cid} | effects]}
  end

  defp handle_response(state, :session_load, _result) do
    # History replays as session/update notifications (handled in Task 6).
    {state, [], [], []}
  end

  defp handle_response(state, :prompt, result) do
    {state, [], [], [{:turn, result["stopReason"]}]}
  end

  defp handle_response(state, _tag, _result), do: {state, [], [], []}

  # Send the instructions as the first prompt on a fresh session only.
  defp maybe_initial_prompt(%{launch: %{mode: :new, instructions: text}} = state)
       when is_binary(text) and text != "" do
    {state, replies, _items} = do_prompt(state, text)
    {state, replies, []}
  end

  defp maybe_initial_prompt(state), do: {state, [], []}

  # do_prompt/dispatch_incoming defined in Tasks 6 & 7; stub for now:
  defp do_prompt(state, _text), do: {state, [], []}
  defp dispatch_incoming(state, _msg), do: {state, [], [], []}
end
```

- [ ] **Step 4: Run, expect PASS**

Run: `cd backend && mix test test/legend/core/acp/connection_test.exs`

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/acp/connection.ex backend/test/legend/core/acp/connection_test.exs
git commit -m "feat(acp): Connection framing + handshake (initialize/session_new/load)"
```

---

## Task 6: `Acp.Connection` — `session/update` → render items

**Files:**
- Modify: `backend/lib/legend/core/acp/connection.ex`
- Test: `backend/test/legend/core/acp/connection_test.exs`

**Interfaces:**
- Produces: `dispatch_incoming/2` handles `{"method" => "session/update", "params" => %{"sessionId", "update" => u}}`, reducing each `u["sessionUpdate"]` variant into one item upsert map with a stable `"id"` and `"type"`:
  - `agent_message_chunk` → `%{"id" => "msg-<turn>", "type" => "message", "role" => "assistant", "text" => <accumulated>}`
  - `agent_thought_chunk` → `%{"id" => "thought-<turn>", "type" => "thought", "text" => <accumulated>}`
  - `user_message_chunk` → `%{"id" => "user-<turn>-<n>", "type" => "message", "role" => "user", "text" => ...}` (used during `session/load` replay)
  - `tool_call` / `tool_call_update` → `%{"id" => toolCallId, "type" => "tool", "kind", "title", "status", "content" => [...], "diff" => %{...} | nil}` (merged by id)
  - `plan` → `%{"id" => "plan", "type" => "plan", "entries" => [%{"text", "status"}]}`
  - `available_commands_update` → `%{"id" => "commands", "type" => "commands", "commands" => [...]}`
  - `current_mode_update` → `%{"id" => "mode", "type" => "mode", "mode" => modeId}`

- [ ] **Step 1: Write the failing test** (chunk accumulation + tool merge):

```elixir
test "message chunks accumulate into one item" do
  state = connected_state()  # helper: run new/1 + initialize + session/new responses
  {state, [i1], _, _} = Connection.handle_bytes(state, update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "Hel"}}))
  {_state, [i2], _, _} = Connection.handle_bytes(state, update("agent_message_chunk", %{"content" => %{"type" => "text", "text" => "lo"}}))
  assert i1["type"] == "message" and i1["text"] == "Hel"
  assert i2["id"] == i1["id"] and i2["text"] == "Hello"
end

test "tool_call then tool_call_update merge by id with a diff" do
  state = connected_state()
  {state, [t1], _, _} = Connection.handle_bytes(state, update("tool_call", %{"toolCallId" => "tc1", "title" => "Edit auth.ex", "kind" => "edit", "status" => "in_progress"}))
  {_state, [t2], _, _} = Connection.handle_bytes(state, update("tool_call_update", %{"toolCallId" => "tc1", "status" => "completed", "content" => [%{"type" => "diff", "path" => "auth.ex", "oldText" => "a", "newText" => "b"}]}))
  assert t1["id"] == "tc1" and t1["status"] == "in_progress"
  assert t2["id"] == "tc1" and t2["status"] == "completed"
  assert t2["diff"]["newText"] == "b"
end
```

Add test helpers `connected_state/0` and `update/2` to the test file:

```elixir
defp update(kind, fields) do
  Jason.encode!(%{"jsonrpc" => "2.0", "method" => "session/update",
    "params" => %{"sessionId" => "s", "update" => Map.put(fields, "sessionUpdate", kind)}}) <> "\n"
end
```

- [ ] **Step 2: Run, expect failure** (`dispatch_incoming` is a stub).

- [ ] **Step 3: Implement reduction** — replace the `dispatch_incoming/2` stub. The per-turn accumulation lives in `state.reduce` (a map keyed by item id):

```elixir
defp dispatch_incoming(state, %{"method" => "session/update", "params" => %{"update" => u}}) do
  {state, item} = reduce_update(state, u, u["sessionUpdate"])
  if item, do: {state, [item], [], []}, else: {state, [], [], []}
end

defp dispatch_incoming(state, _msg), do: {state, [], [], []}

defp reduce_update(state, u, "agent_message_chunk"),
  do: accumulate(state, "msg-#{state.turn}", "message", %{"role" => "assistant"}, text(u))

defp reduce_update(state, u, "agent_thought_chunk"),
  do: accumulate(state, "thought-#{state.turn}", "thought", %{}, text(u))

defp reduce_update(state, u, "user_message_chunk"),
  do: accumulate(state, "user-#{state.turn}", "message", %{"role" => "user"}, text(u))

defp reduce_update(state, u, kind) when kind in ["tool_call", "tool_call_update"] do
  id = u["toolCallId"]
  prev = Map.get(state.reduce, id, %{"id" => id, "type" => "tool"})
  item =
    prev
    |> merge_present(u, "title")
    |> merge_present(u, "kind")
    |> merge_present(u, "status")
    |> put_tool_content(u["content"])
  {%{state | reduce: Map.put(state.reduce, id, item)}, item}
end

defp reduce_update(state, u, "plan"),
  do: {state, %{"id" => "plan", "type" => "plan", "entries" => plan_entries(u["entries"])}}

defp reduce_update(state, u, "available_commands_update"),
  do: {state, %{"id" => "commands", "type" => "commands", "commands" => u["availableCommands"] || []}}

defp reduce_update(state, u, "current_mode_update"),
  do: {state, %{"id" => "mode", "type" => "mode", "mode" => u["currentModeId"]}}

defp reduce_update(state, _u, _other), do: {state, nil}

defp accumulate(state, id, type, base, chunk) do
  prev = Map.get(state.reduce, id, Map.merge(%{"id" => id, "type" => type, "text" => ""}, base))
  item = %{prev | "text" => prev["text"] <> chunk}
  {%{state | reduce: Map.put(state.reduce, id, item)}, item}
end

defp text(%{"content" => %{"text" => t}}) when is_binary(t), do: t
defp text(_), do: ""

defp merge_present(item, u, key) do
  case u[key] do
    nil -> item
    v -> Map.put(item, key, v)
  end
end

defp put_tool_content(item, nil), do: item
defp put_tool_content(item, content) when is_list(content) do
  diff = Enum.find(content, &(&1["type"] == "diff"))
  text = content |> Enum.filter(&(&1["type"] in ["content", "text"])) |> Enum.map_join("", &(get_in(&1, ["content", "text"]) || &1["text"] || ""))
  item
  |> Map.put("diff", diff && Map.take(diff, ["path", "oldText", "newText"]))
  |> Map.update("output", text, &(&1 <> text))
end

defp plan_entries(nil), do: []
defp plan_entries(entries), do: Enum.map(entries, &%{"text" => &1["content"] || &1["title"], "status" => &1["status"]})
```

When a new turn starts (a `session/prompt` is sent, Task 7), reset the per-turn message/thought accumulation by bumping `state.turn` and clearing those ids from `state.reduce` (tool calls keep their own ids). This keeps each assistant turn a distinct message item.

- [ ] **Step 4: Run, expect PASS**

Run: `cd backend && mix test test/legend/core/acp/connection_test.exs`

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/acp/connection.ex backend/test/legend/core/acp/connection_test.exs
git commit -m "feat(acp): reduce session/update notifications into render items"
```

---

## Task 7: `Acp.Connection` — prompt / cancel / set_mode + permission round-trip

**Files:**
- Modify: `backend/lib/legend/core/acp/connection.ex`
- Test: `backend/test/legend/core/acp/connection_test.exs`

**Interfaces:**
- Produces:
  - `Acp.Connection.prompt(state, content) :: {state, [reply_binary]}` — content is a string or a list of ACP content blocks; bumps the turn, sends `session/prompt`.
  - `Acp.Connection.cancel(state) :: {state, [reply_binary]}` — sends the `session/cancel` notification.
  - `Acp.Connection.set_mode(state, mode_id) :: {state, [reply_binary]}`.
  - `Acp.Connection.answer_permission(state, request_id, option_id) :: {state, [reply_binary]}` — responds to a pending `session/request_permission`.
  - `dispatch_incoming/2` handles inbound `session/request_permission` (a request needing a response): emits a `%{"id" => requestId, "type" => "permission", "title", "command"?, "options" => [...], "resolved" => false}` item and records the JSON-RPC id as pending-from-agent. Answering emits a resolution item (`"resolved" => true, "chosen" => optionId`).
  - The `session/new`/`load` params carry the agent `sessionId` returned at handshake; `prompt`/`cancel`/`set_mode` must include it. Store it as `state.session_id` (the ACP-level id) when captured.

- [ ] **Step 1: Write the failing test**:

```elixir
test "prompt sends session/prompt with the agent session id and bumps the turn" do
  state = connected_state()  # captures sessionId "sess-xyz"
  {state, [frame]} = Connection.prompt(state, "do the thing")
  msg = Jason.decode!(frame)
  assert msg["method"] == "session/prompt"
  assert msg["params"]["sessionId"] == "sess-xyz"
  assert [%{"type" => "text", "text" => "do the thing"}] = msg["params"]["prompt"]
end

test "permission request becomes an item; answer responds to the agent" do
  state = connected_state()
  req = Jason.encode!(%{"jsonrpc" => "2.0", "id" => 99, "method" => "session/request_permission",
    "params" => %{"sessionId" => "sess-xyz", "toolCall" => %{"title" => "rm -rf"}, "options" => [%{"optionId" => "allow", "name" => "Allow"}]}}) <> "\n"
  {state, [item], _replies, _e} = Connection.handle_bytes(state, req)
  assert item["type"] == "permission" and item["resolved"] == false
  {_state, [reply]} = Connection.answer_permission(state, item["id"], "allow")
  decoded = Jason.decode!(reply)
  assert decoded["id"] == 99
  assert decoded["result"]["outcome"]["outcome"] == "selected"
  assert decoded["result"]["outcome"]["optionId"] == "allow"
end
```

Update `connected_state/0` to capture the agent session id (store it in `state.session_id` via the `session/new` response handler).

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Implement.** Add `session_id: nil` and `perms: %{}` to the struct defaults. In `handle_response(:session_new …)` and `(:session_load …)`, set `state.session_id` from the result (`session/load` has no sessionId in the result — keep the launch `conversation_id`). Then:

```elixir
@spec prompt(t(), String.t() | [map()]) :: {t(), [binary()]}
def prompt(state, content) do
  blocks = to_blocks(content)
  turn = state.turn + 1
  reduce = Map.drop(state.reduce, ["msg-#{state.turn}", "thought-#{state.turn}"])
  state = %{state | turn: turn, reduce: reduce}
  frame = notify_or_request_prompt(state, blocks)
  {%{state | next_id: state.next_id + 1, pending: Map.put(state.pending, state.next_id, :prompt)},
   [frame]}
end

defp notify_or_request_prompt(state, blocks) do
  Jason.encode!(%{"jsonrpc" => "2.0", "id" => state.next_id, "method" => "session/prompt",
    "params" => %{"sessionId" => state.session_id, "prompt" => blocks}}) <> "\n"
end

defp to_blocks(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
defp to_blocks(blocks) when is_list(blocks), do: blocks

@spec cancel(t()) :: {t(), [binary()]}
def cancel(state), do: {state, [notify("session/cancel", %{"sessionId" => state.session_id})]}

@spec set_mode(t(), String.t()) :: {t(), [binary()]}
def set_mode(state, mode_id) do
  {state, frame} = request(state, "session/set_mode", %{"sessionId" => state.session_id, "modeId" => mode_id}, :set_mode)
  {state, [frame]}
end

@spec answer_permission(t(), String.t(), String.t()) :: {t(), [binary()]}
def answer_permission(state, request_id, option_id) do
  case Map.pop(state.perms, request_id) do
    {nil, _} -> {state, []}
    {jsonrpc_id, perms} ->
      reply = response(jsonrpc_id, %{"outcome" => %{"outcome" => "selected", "optionId" => option_id}})
      {%{state | perms: perms}, [reply]}
  end
end
```

Add the inbound permission clause to `dispatch_incoming/2` (before the catch-all):

```elixir
defp dispatch_incoming(state, %{"id" => id, "method" => "session/request_permission", "params" => p}) do
  item = %{
    "id" => "perm-#{id}",
    "type" => "permission",
    "title" => get_in(p, ["toolCall", "title"]) || "Permission request",
    "command" => get_in(p, ["toolCall", "rawInput", "command"]),
    "options" => p["options"] || [],
    "resolved" => false
  }
  {%{state | perms: Map.put(state.perms, "perm-#{id}", id)}, [item], [], []}
end
```

(`fix do_prompt` from Task 5: `defp do_prompt(state, text), do: {state2, frames} = prompt(state, text); {state2, frames, []}` — i.e. `maybe_initial_prompt` now calls `prompt/2`.)

- [ ] **Step 4: Run, expect PASS.**

Run: `cd backend && mix test test/legend/core/acp/connection_test.exs`

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/acp/connection.ex backend/test/legend/core/acp/connection_test.exs
git commit -m "feat(acp): prompt/cancel/set_mode + permission round-trip"
```

---

## Task 8: `LocalPty` `:pipes` mode

**Files:**
- Modify: `backend/lib/legend/runtimes/local_pty.ex`
- Test: `backend/test/legend/runtimes/local_pty_test.exs`

**Interfaces:**
- Consumes: `CommandSpec.io` (`:pty | :pipes`).
- Produces: `LocalPty.start/2` honors `io: :pipes` — runs the command with stdin/stdout pipes (no PTY), same `{:runtime_output, bytes}` / `{:runtime_exit, code}` owner messages and `write/2`/`stop/1` behavior. `resize/2` is a no-op for pipes.

- [ ] **Step 1: Write the failing test** (pipe echo round-trip with `cat`):

```elixir
test "pipes mode echoes stdin to stdout without a PTY" do
  spec = %Legend.Core.Runtime.CommandSpec{cmd: "cat", io: :pipes}
  {:ok, handle} = Legend.Runtimes.LocalPty.start(spec, %{owner: self()})
  :ok = Legend.Runtimes.LocalPty.write(handle, "hello\n")
  assert_receive {:runtime_output, "hello\n"}, 2_000
  Legend.Runtimes.LocalPty.stop(handle)
  assert_receive {:runtime_exit, _}, 2_000
end
```

- [ ] **Step 2: Run, expect failure** (the run opts always include `:pty`).

- [ ] **Step 3: Branch the run opts on `spec.io`.** In `run_and_relay/6`, replace the fixed opts list with a base + io-specific list:

```elixir
defp run_and_relay(caller, ref, owner, argv, spec, opts) do
  io_opts =
    case spec.io do
      :pipes -> [:stdin, {:stdout, self()}, :stderr]
      _ -> [:stdin, :pty, :pty_echo, {:stdout, self()}]
    end

  run_opts =
    io_opts ++
      [
        :monitor,
        {:env, Map.to_list(spec.env)},
        {:winsz, {opts[:rows] || 24, opts[:cols] || 80}},
        {:kill_timeout, 5}
      ] ++ cd_opt(opts)

  # … unchanged :exec.run + relay …
end
```

For `:pipes`, `:stderr` is delivered separately by erlexec; extend `relay_loop/2` to forward stderr as output too:

```elixir
defp relay_loop(owner, os_pid) do
  receive do
    {:stdout, ^os_pid, data} -> send(owner, {:runtime_output, data}); relay_loop(owner, os_pid)
    {:stderr, ^os_pid, data} -> send(owner, {:runtime_output, data}); relay_loop(owner, os_pid)
    {:DOWN, ^os_pid, :process, _pid, reason} -> send(owner, {:runtime_exit, decode_exit(reason)})
  end
end
```

Make `resize/2` tolerant: erlexec `:winsz` on a non-PTY process errors; guard it:

```elixir
def resize(%{os_pid: os_pid}, cols, rows) do
  try do
    :exec.winsz(os_pid, rows, cols)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
  :ok
end
```

- [ ] **Step 4: Run, expect PASS** (keep the existing PTY tests green too).

Run: `cd backend && mix test test/legend/runtimes/local_pty_test.exs`

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/runtimes/local_pty.ex backend/test/legend/runtimes/local_pty_test.exs
git commit -m "feat(runtime): LocalPty :pipes mode for ACP stdio"
```

---

## Task 9: `SessionServer` ACP launch + IO + lifecycle

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex`
- Test: `backend/test/legend/core/agents/session_server_acp_test.exs`

**Interfaces:**
- Consumes: `Harness.Acp.acp_command/1`, `Acp.Connection.{new,handle_bytes,prompt,cancel,set_mode,answer_permission}`, `AcpTimeline`, `Agents.set_session_conversation_id/2`.
- Produces: an ACP-transport SessionServer that holds `acp` (the `Acp.Connection` state) + `timeline` (`AcpTimeline`); broadcasts `{:session_event, seq, item}` on `session:<id>`; accepts casts `{:acp_prompt, content}`, `:acp_cancel`, `{:acp_set_mode, mode}`, `{:acp_permission, request_id, option_id}`; `attach` reply for ACP returns `%{status, transport: :acp, items, cursor}`.

- [ ] **Step 1: Write the failing test** (fresh ACP launch → handshake → message item broadcast). Use the `Test` runtime; drive ACP frames by sending `{:runtime_output, json}` to the server and asserting it writes frames via the Test runtime listener:

```elixir
defmodule Legend.Core.Agents.SessionServerAcpTest do
  use Legend.DataCase, async: false
  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()
    :ok
  end

  test "acp session: handshake, conversation id capture, message broadcast" do
    {:ok, s} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})
    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")

    # Server wrote the initialize request:
    assert_receive {:test_runtime, :write, init}, 1_000
    init_id = Jason.decode!(init)["id"]

    # Reply initialize → server writes session/new
    send_output(s.id, %{"jsonrpc" => "2.0", "id" => init_id, "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}})
    assert_receive {:test_runtime, :write, new_req}, 1_000
    assert Jason.decode!(new_req)["method"] == "session/new"

    # Reply session/new → conversation id persisted
    new_id = Jason.decode!(new_req)["id"]
    send_output(s.id, %{"jsonrpc" => "2.0", "id" => new_id, "result" => %{"sessionId" => "sess-xyz"}})

    # A message chunk broadcasts an item
    send_output(s.id, %{"jsonrpc" => "2.0", "method" => "session/update",
      "params" => %{"sessionId" => "sess-xyz", "update" => %{"sessionUpdate" => "agent_message_chunk", "content" => %{"type" => "text", "text" => "hi"}}}})
    assert_receive {:session_event, _seq, %{"type" => "message", "text" => "hi"}}, 1_000

    assert Agents.get_session!(s.id).conversation_id == "sess-xyz"
  end

  defp send_output(id, msg) do
    pid = Legend.Core.Agents.SessionServer.whereis(id)
    send(pid, {:runtime_output, Jason.encode!(msg) <> "\n"})
  end
end
```

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Branch `launch/7` on transport.** Add a transport-aware command build + connection setup. After resolving `harness`/`runtime`/`caps`, compute `transport = session.transport`. For `:acp`:

```elixir
defp build_spec(session, _mode, harness, %{transport: :acp} = _ctx, base_url, caps) do
  env = platform_env(session, caps, base_url)
  harness.acp_command(%{env: env})
end
```

(For `:terminal`, keep the existing `harness.build_command(build_opts(...))` path.) The cleanest structure: a `case session.transport do :terminal -> …; :acp -> … end` in `launch/7` that produces `{spec, extra_state}` where `extra_state` for ACP includes the initialized `Acp.Connection` and the launch frames to write after start.

- [ ] **Step 4: ACP launch sequence.** After `start_or_attach` succeeds for an ACP session:

```elixir
mode = if session.conversation_id, do: :load, else: :new
{acp, frames} = Legend.Core.Acp.Connection.new(%{
  cwd: session.cwd,
  mcp_servers: acp_mcp_servers(session, caps, base_url),
  mode: mode,
  conversation_id: session.conversation_id,
  instructions: (if mode == :new, do: session.instructions)
})
Enum.each(frames, &runtime.write(handle, &1))
```

`acp_mcp_servers/3` builds the ACP `mcpServers` entry from the same data terminal uses for CLI flags (Phase 1 local = loopback):

```elixir
defp acp_mcp_servers(%{mcp_token: nil}, _caps, _base), do: []
defp acp_mcp_servers(session, _caps, _base_url) do
  [%{"name" => "legend", "type" => "http", "url" => mcp_url(),
     "headers" => %{"Authorization" => "Bearer #{session.mcp_token}"}}]
end
```

Store in state: `acp: acp, timeline: Legend.Core.Agents.AcpTimeline.new(), transport: :acp`.

- [ ] **Step 5: ACP runtime output → items.** Add a transport-aware `handle_info({:runtime_output, data}, …)`:

```elixir
def handle_info({:runtime_output, data}, %{transport: :acp} = state) do
  {acp, items, replies, effects} = Legend.Core.Acp.Connection.handle_bytes(state.acp, data)
  Enum.each(replies, &state.runtime.write(state.handle, &1))
  state = Enum.reduce(effects, %{state | acp: acp}, &apply_effect/2)

  state =
    Enum.reduce(items, state, fn item, st ->
      {timeline, [item_with_seq]} = Legend.Core.Agents.Transcript.append(st.timeline, item)
      broadcast(st.session.id, {:session_event, item_with_seq["seq"], item_with_seq})
      %{st | timeline: timeline}
    end)

  {:noreply, state}
end
```

`apply_effect/2`:

```elixir
defp apply_effect({:conversation_id, cid}, state) do
  session = Agents.set_session_conversation_id(state.session, %{conversation_id: cid})
  %{state | session: session}
end
defp apply_effect({:load_capable, _}, state), do: state
defp apply_effect({:turn, _stop}, state), do: state
```

Keep the existing terminal `handle_info({:runtime_output, data}, state)` clause (it now only matches terminal state since the ACP clause is guarded).

- [ ] **Step 6: ACP inbound casts.** Add client API + casts:

```elixir
def acp_prompt(id, content), do: cast(id, {:acp_prompt, content})
def acp_cancel(id), do: cast(id, :acp_cancel)
def acp_set_mode(id, mode), do: cast(id, {:acp_set_mode, mode})
def acp_permission(id, req, opt), do: cast(id, {:acp_permission, req, opt})

def handle_cast({:acp_prompt, content}, %{transport: :acp, exited?: false} = state) do
  {acp, frames} = Legend.Core.Acp.Connection.prompt(state.acp, content)
  Enum.each(frames, &state.runtime.write(state.handle, &1))
  {:noreply, %{state | acp: acp}}
end
# analogous casts for :acp_cancel, {:acp_set_mode, mode}, {:acp_permission, req, opt}
# (permission also broadcasts a resolution item via the timeline)
```

- [ ] **Step 7: ACP attach reply.** Branch `handle_call(:attach, …)` on transport:

```elixir
def handle_call(:attach, _from, %{transport: :acp} = state) do
  {items, cursor} = Legend.Core.Agents.Transcript.snapshot(state.timeline)
  {:reply, {:ok, %{status: state.session.status, transport: :acp, items: items, cursor: cursor}}, state}
end
```

(Keep the terminal clause returning `%{status, buffer, offset}` and add `transport: :terminal` to it.)

- [ ] **Step 8: Initialize transport in launch state.** In the success branch of `launch/7`, add `transport: session.transport` and (for terminal) `timeline: nil`, (for acp) `scrollback: nil`, so both clauses have a consistent state shape. Guard the terminal `:write`/`:resize` casts with `transport: :terminal` where they'd conflict.

- [ ] **Step 9: Run, expect PASS** (and the existing terminal SessionServer tests stay green).

Run: `cd backend && mix test test/legend/core/agents/`

- [ ] **Step 10: Commit**

```bash
git add backend/lib/legend/core/agents/session_server.ex backend/test/legend/core/agents/session_server_acp_test.exs
git commit -m "feat(session): SessionServer ACP transport (launch, IO, casts, attach)"
```

---

## Task 10: `SessionChannel` ACP support

**Files:**
- Modify: `backend/lib/legend_web/channels/session_channel.ex`
- Test: `backend/test/legend_web/channels/session_channel_acp_test.exs`

**Interfaces:**
- Produces: join reply includes `transport`; for ACP it is `%{status, transport: "acp", items: [...], cursor: seq}`. Inbound: `prompt {content}`, `cancel`, `set_mode {mode}`, `permission {request_id, option_id}`. Outbound: `event {seq, item}`. Terminal frames unchanged.

- [ ] **Step 1: Write the failing test**:

```elixir
test "acp join replies with items + cursor and forwards prompts" do
  {:ok, s} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})
  # … drive handshake so the server is :running …
  {:ok, reply, socket} = subscribe_and_join(socket(LegendWeb.UserSocket), LegendWeb.SessionChannel, "session:#{s.id}")
  assert reply.transport == "acp"
  assert is_list(reply.items)
  push(socket, "prompt", %{"content" => "hello"})
  assert_receive {:test_runtime, :write, frame}
  assert Jason.decode!(frame)["method"] == "session/prompt"
end
```

- [ ] **Step 2: Run, expect failure.**

- [ ] **Step 3: Update `attach_reply/1`** to pass through `transport` and branch on it:

```elixir
defp attach_reply(session) do
  case SessionServer.attach(session.id) do
    {:ok, %{transport: :acp, items: items, cursor: cursor, status: status}} ->
      {%{status: to_string(status), transport: "acp", items: items, cursor: cursor,
         exit_code: session.exit_code, error: session.error}, cursor}

    {:ok, %{status: status, buffer: buffer, offset: offset}} ->
      {%{status: to_string(status), transport: "terminal", buffer: Base.encode64(buffer),
         exit_code: session.exit_code, error: session.error}, offset}

    {:error, :not_running} ->
      {%{status: to_string(session.status), transport: to_string(session.transport),
         buffer: "", items: [], cursor: 0, exit_code: session.exit_code, error: session.error}, 0}
  end
end
```

- [ ] **Step 4: Add ACP inbound handlers** and the event push:

```elixir
def handle_in("prompt", %{"content" => content}, socket) do
  SessionServer.acp_prompt(socket.assigns.session_id, content)
  {:noreply, socket}
end

def handle_in("cancel", _payload, socket) do
  SessionServer.acp_cancel(socket.assigns.session_id)
  {:noreply, socket}
end

def handle_in("set_mode", %{"mode" => mode}, socket) when is_binary(mode) do
  SessionServer.acp_set_mode(socket.assigns.session_id, mode)
  {:noreply, socket}
end

def handle_in("permission", %{"request_id" => req, "option_id" => opt}, socket)
    when is_binary(req) and is_binary(opt) do
  SessionServer.acp_permission(socket.assigns.session_id, req, opt)
  {:noreply, socket}
end

def handle_info({:session_event, seq, item}, socket) do
  if seq >= socket.assigns.offset do
    push(socket, "event", %{seq: seq, item: item})
    {:noreply, assign(socket, :offset, seq)}
  else
    {:noreply, socket}
  end
end
```

(The existing `{:session_output, …}` handler stays for terminal; the `offset` assign is reused as the ACP `seq` cursor.)

- [ ] **Step 5: Run, expect PASS.**

Run: `cd backend && mix test test/legend_web/channels/`

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend_web/channels/session_channel.ex backend/test/legend_web/channels/session_channel_acp_test.exs
git commit -m "feat(channel): ACP join snapshot + prompt/cancel/permission/set_mode + event push"
```

---

## Task 11: Backend integration — resume via `session/load` + precommit

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex` (resume path)
- Test: `backend/test/legend/core/agents/session_server_acp_test.exs`

**Interfaces:**
- Consumes: `session.conversation_id` (set on fresh launch).
- Produces: resuming/switching an ACP session sends `session/load {conversation_id}` (mode `:load`) instead of `session/new`.

- [ ] **Step 1: Write the failing test**:

```elixir
test "resume of an acp session loads the conversation id" do
  {:ok, s} = Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})
  # drive handshake to capture conversation_id "sess-xyz", then stop:
  # … (handshake helper) …
  Agents.finish_session!(Agents.get_session!(s.id), %{exit_code: 0})
  {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))

  assert_receive {:test_runtime, :write, init}, 1_000
  init_id = Jason.decode!(init)["id"]
  send_output(s.id, %{"jsonrpc" => "2.0", "id" => init_id, "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{"loadSession" => true}}})
  assert_receive {:test_runtime, :write, load_req}, 1_000
  decoded = Jason.decode!(load_req)
  assert decoded["method"] == "session/load"
  assert decoded["params"]["sessionId"] == "sess-xyz"
end
```

- [ ] **Step 2: Run, expect failure** (resume currently always sends `session/new` because mode is derived from `conversation_id` presence — verify the launch wiring passes `mode: :load` when `conversation_id` is set, regardless of `:fresh`/`:resume`). Fix the `mode` computation in the ACP launch (Task 9 Step 4) to: `mode = if session.conversation_id, do: :load, else: :new` — this already handles both resume and switch correctly. The failing test surfaces any gap in capturing/persisting `conversation_id` across the stop/start.

- [ ] **Step 3: Implement / fix** as needed so the ACP resume path loads.

- [ ] **Step 4: Full backend gate**

Run: `cd backend && mix precommit`
Expected: compile (warnings-as-errors) + format + full test suite PASS.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "feat(session): ACP resume + switch via session/load"
```

---

## Task 12: Frontend types + API client

**Files:**
- Modify: `frontend/src/lib/sessions.ts`

**Interfaces:**
- Produces: `Session` gains `transport: 'terminal' | 'acp'` and `conversation_id: string | null`. `Harness` replaces `kind` with `transports: ('terminal'|'acp'|'native')[]`. New `setTransport(id, transport)` and `createSession` accepts `transport?`.

- [ ] **Step 1: Edit `Session`** — add `transport: 'terminal' | 'acp';` and `conversation_id: string | null;`.

- [ ] **Step 2: Edit `Harness`** — replace `kind: 'terminal' | 'acp' | 'native';` with `transports: ('terminal' | 'acp' | 'native')[];`.

- [ ] **Step 3: Add API calls**:

```ts
export async function setTransport(id: string, transport: 'terminal' | 'acp'): Promise<void> {
  const res = await fetch(`${apiBase}/api/sessions/${id}/transport`, {
    method: 'PATCH',
    headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
    body: JSON.stringify({ data: { type: 'session', id, attributes: { transport } } })
  });
  if (!res.ok) throw new Error(await errorMessage(res, 'switching transport failed'));
}
```

Add `transport?: 'terminal' | 'acp'` to the `createSession` attrs param.

- [ ] **Step 4: Update readers** — `cd frontend && grep -rn "\.kind" src` and fix any harness `.kind` reader (e.g. NewSessionDialog showing a transport badge) to use `transports`.

- [ ] **Step 5: Gate**

Run: `cd frontend && bun run check`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/sessions.ts frontend/src/lib/components
git commit -m "feat(fe): session transport/conversation_id + harness transports + setTransport"
```

---

## Task 13: ACP channel client store

**Files:**
- Create: `frontend/src/lib/shell/acpSession.svelte.ts`

**Interfaces:**
- Produces: `createAcpSession(sessionId)` returning a reactive object: `items` (array of render items keyed by `id`, upserted by `seq`), `status`, plus methods `prompt(content)`, `cancel()`, `setMode(mode)`, `answerPermission(requestId, optionId)`, `dispose()`. Mirrors `Terminal.svelte`'s channel lifecycle (join, rejoin-safe snapshot, leave on dispose).

- [ ] **Step 1: Write the store** (Svelte 5 runes; upsert items by id, drop `seq <= cursor`):

```ts
import { getSocket } from '$lib/socket';
import type { Channel } from 'phoenix';
import type { SessionStatus } from '$lib/sessions';

export interface AcpItem { id: string; seq: number; type: string; [k: string]: unknown; }

export function createAcpSession(sessionId: string) {
  let channel: Channel | undefined;
  const byId = new Map<string, AcpItem>();
  let cursor = 0;
  const state = $state({ items: [] as AcpItem[], status: 'starting' as SessionStatus, busy: false });

  function rebuild() { state.items = [...byId.values()].sort((a, b) => a.seq - b.seq); }
  function upsert(item: AcpItem) {
    if (item.seq <= cursor && byId.has(item.id)) return;
    byId.set(item.id, item);
    cursor = Math.max(cursor, item.seq);
    state.busy = item.type !== 'turn';
    if (item.type === 'turn') state.busy = false;
    rebuild();
  }

  const chan = getSocket().channel(`session:${sessionId}`);
  channel = chan;
  let joined = false;

  chan.on('event', ({ seq, item }: { seq: number; item: AcpItem }) => upsert({ ...item, seq }));
  chan.on('status', ({ status }: { status: SessionStatus }) => (state.status = status));
  chan.on('exit', () => (state.status = 'exited'));

  chan.join().receive('ok', (reply: { transport: string; items?: AcpItem[]; cursor?: number; status: SessionStatus }) => {
    state.status = reply.status;
    if (!joined && reply.items) {
      byId.clear();
      cursor = reply.cursor ?? 0;
      for (const it of reply.items) byId.set(it.id, it);
      rebuild();
    }
    joined = true;
  });

  return {
    get items() { return state.items; },
    get status() { return state.status; },
    get busy() { return state.busy; },
    prompt: (content: unknown) => chan.push('prompt', { content }),
    cancel: () => chan.push('cancel', {}),
    setMode: (mode: string) => chan.push('set_mode', { mode }),
    answerPermission: (request_id: string, option_id: string) => chan.push('permission', { request_id, option_id }),
    dispose: () => { chan.leave(); channel = undefined; }
  };
}
```

- [ ] **Step 2: Gate**

Run: `cd frontend && bun run check`

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/shell/acpSession.svelte.ts
git commit -m "feat(fe): ACP channel client store"
```

---

## Task 14: `AcpConversation` stream renderer

**Files:**
- Create: `frontend/src/lib/components/sessions/AcpConversation.svelte`
- Create: `frontend/src/lib/components/sessions/acp-parts/ToolCall.svelte`

**Interfaces:**
- Consumes: `createAcpSession` (`items`, `status`, methods).
- Produces: `AcpConversation` takes `{ sessionId }`, renders the reduced `items` as the scrolling thread (message bubbles, thoughts, tool calls + diffs). Plan/queue/composer/permissions arrive in Task 15.

- [ ] **Step 1: Build the stream.** Port the thread markup/CSS from the approved mockup `acp-surface-v4.html` (`.user`/`.asst`/`.think`/`.tool`/`.diff` blocks) into Svelte, replacing the static rows with `{#each acp.items as item (item.id)}` and a `{#if item.type === ...}` switch. Use Legend tokens (`text-ink-*`, `bg-app/panel`, `border-hair`) — translate the mockup's `--ink*`/`--hair*` to the existing token classes. Render markdown for `message`/`thought` text with the existing markdown approach used elsewhere in the app (check `MessagesPanel.svelte` for the renderer; reuse it).

```svelte
<script lang="ts">
  import { onDestroy } from 'svelte';
  import { createAcpSession } from '$lib/shell/acpSession.svelte';
  import ToolCall from './acp-parts/ToolCall.svelte';
  let { sessionId }: { sessionId: string } = $props();
  const acp = createAcpSession(sessionId);
  onDestroy(() => acp.dispose());
</script>

<div class="flex h-full min-h-0 flex-col bg-app">
  <div class="flex-1 overflow-auto px-4 py-4 flex flex-col gap-3.5">
    {#each acp.items as item (item.id)}
      {#if item.type === 'message' && item.role === 'user'}
        <div class="self-end max-w-[82%] rounded-[12px_12px_4px_12px] border border-hair-strong bg-panel px-3 py-2 text-ui text-ink-1">{item.text}</div>
      {:else if item.type === 'message'}
        <div class="text-ui text-ink-1 whitespace-pre-wrap">{item.text}</div>
      {:else if item.type === 'thought'}
        <div class="border-l-2 border-hair-strong pl-3 text-meta text-ink-3">{item.text}</div>
      {:else if item.type === 'tool'}
        <ToolCall {item} />
      {/if}
    {/each}
  </div>
</div>
```

- [ ] **Step 2: Build `ToolCall.svelte`** — port the `.tool`/`.diff`/`.toolout` markup from the mockup; props `{ item }`; render `kind` label, `title`, a status glyph (`status === 'completed'` ✓ / `in_progress` spinner / `failed` ✗), the `output` text, and the `diff` (old/new lines) when present.

- [ ] **Step 3: Gate**

Run: `cd frontend && bun run check`

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/components/sessions/AcpConversation.svelte frontend/src/lib/components/sessions/acp-parts/ToolCall.svelte
git commit -m "feat(fe): AcpConversation stream (messages, thoughts, tool calls, diffs)"
```

---

## Task 15: Sticky plan + queue + composer + permissions

**Files:**
- Create: `acp-parts/PlanBar.svelte`, `acp-parts/Queue.svelte`, `acp-parts/Composer.svelte`, `acp-parts/PermissionCard.svelte`
- Modify: `frontend/src/lib/components/sessions/AcpConversation.svelte`

**Interfaces:**
- Consumes: `acp.items` (the `plan`, `commands`, `mode`, `permission` items), `acp.busy`, `acp.prompt/cancel/setMode/answerPermission`.
- Produces: the sticky dock (plan above queue) + the context-aware composer; permission cards rendered inline in the stream; a client-side queue that flushes via `acp.prompt` on `busy → false`.

- [ ] **Step 1: `PlanBar.svelte`** — derive the `plan` item from `acp.items`; port the sticky collapsible plan markup from the mockup (one-line summary `done/total` + current step; expandable checklist). Hidden when there is no plan item.

- [ ] **Step 2: `PermissionCard.svelte`** — props `{ item, onAnswer }`; port the amber `.perm` card; render `item.options` as buttons calling `onAnswer(item.id, option.optionId)`; render resolved state when `item.resolved`. In `AcpConversation`, add `{:else if item.type === 'permission'}<PermissionCard {item} onAnswer={acp.answerPermission} />` to the stream switch.

- [ ] **Step 3: `Queue.svelte`** — local queue state (`$state<string[]>`), props for `onSendNow(text)` and `onRemove`/`onReorder`; port the sticky queue rows with the ▶ send-now / edit / remove buttons. The queue lives in `Composer` (below) and renders via this part.

- [ ] **Step 4: `Composer.svelte`** — port the composer markup from the mockup (textarea, context chips row with `＠ Add context`, mode chip, Stop/Send, context-info footer with slash commands from the `commands` item). Logic:

```ts
let text = $state('');
let queue = $state<string[]>([]);
let { busy, commands, mode, onPrompt, onCancel, onSetMode }:
  { busy: boolean; commands: string[]; mode: string | null;
    onPrompt: (t: string) => void; onCancel: () => void; onSetMode: (m: string) => void } = $props();

function submit() {
  if (!text.trim()) return;
  if (busy) { queue = [...queue, text]; } else { onPrompt(text); }
  text = '';
}
// flush queued prompts when the agent goes idle
$effect(() => { if (!busy && queue.length) { const [next, ...rest] = queue; queue = rest; onPrompt(next); } });
```

Send button shows `↑` when idle, `＋ Queue` when busy; Stop calls `onCancel`. Each queued row's ▶ send-now removes it from `queue` and calls `onPrompt` immediately (allowed even while busy — ACP queues server-side per turn; for Phase 1, treat send-now as enqueue-at-front + immediate flush attempt).

- [ ] **Step 5: Assemble in `AcpConversation`** — below the scroll, render `<PlanBar items={acp.items} />`, then the `Composer` (which contains the queue), wiring `busy={acp.busy}`, `commands`/`mode` derived from items, and the `acp` methods.

- [ ] **Step 6: Gate**

Run: `cd frontend && bun run check`

- [ ] **Step 7: Commit**

```bash
git add frontend/src/lib/components/sessions/acp-parts frontend/src/lib/components/sessions/AcpConversation.svelte
git commit -m "feat(fe): sticky plan + queue + context composer + permission cards"
```

---

## Task 16: `SessionPane` transport switch + toggle + surface wiring

**Files:**
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte`
- Modify: `frontend/src/lib/components/NewSessionDialog.svelte`

**Interfaces:**
- Consumes: `session.transport`, harness `transports`, `setTransport`.
- Produces: `SessionPane` renders `AcpConversation` when `session.transport === 'acp'` (and live), else `Terminal`; a header toggle (`rich ⇄ term`) shown only when the harness supports both transports, calling `setTransport`; the new-session dialog defaults transport from the harness and lets the user pick when >1.

- [ ] **Step 1: Switch the body in `SessionPane.svelte`.** Import `AcpConversation` and `setTransport`. Replace the `<Terminal …>` body with:

```svelte
{#key resumeKey}
  {#if session.transport === 'acp'}
    <AcpConversation sessionId={session.id} />
  {:else}
    <Terminal bind:this={terminal} sessionId={session.id} fontSize={11} background="#100d1a" />
  {/if}
{/key}
```

(Note: `requestStop`/suspend still target the terminal binding; for ACP, suspend = `setTransport` is not it — keep the existing Suspend menu item calling the channel `stop`. The ACP store has no `requestStop`; gate `suspend()` to push `stop` via a small channel ref or reuse the existing per-session stop API. Simplest: keep Suspend calling the session stop endpoint already used by the menu.)

- [ ] **Step 2: Add the transport toggle** to the header (only when the harness has both transports). Derive harness transports from the harnesses list (already fetched in the app; reuse `sessionsStore`/`listHarnesses` source). Render the `rich ⇄ term` pill (port from the mockup header) calling:

```ts
async function switchTransport(t: 'terminal' | 'acp') {
  if (t === session.transport) return;
  await setTransport(session.id, t);
  resumeKey += 1; // re-key so the body remounts against the new transport
}
```

- [ ] **Step 3: New-session dialog default.** When a harness with multiple `transports` is selected, show a small transport selector (default = `transports[0]`); pass `transport` to `createSession`. For single-transport harnesses, omit it (backend default applies).

- [ ] **Step 4: Gate**

Run: `cd frontend && bun run check`

- [ ] **Step 5: Manual smoke (real agent).** Requires `claude-code-acp` installed (`npm i -g @zed-industries/claude-code-acp`) and `claude` authenticated. `just dev`, create a Claude Code session (transport defaults to ACP), verify: streaming message, a tool call with a diff, a permission prompt round-trip, the plan bar, queueing a message while busy, and the `rich ⇄ term` toggle switching the same conversation.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/components/sessions/SessionPane.svelte frontend/src/lib/components/NewSessionDialog.svelte
git commit -m "feat(fe): SessionPane transport switch + toggle + new-session default"
```

---

## Self-review

**Spec coverage:**
- `transports` replaces `kind` → Task 1. ✅
- `Acp` harness behaviour + `ClaudeCode.acp_command` → Task 2. ✅
- `session.transport` + `conversation_id` + `set_transport` → Task 3. ✅
- `Transcript` abstraction + `AcpTimeline` → Task 4. ✅
- `Acp.Connection` (framing, handshake, `session/update` reduction, prompt/cancel/set_mode, permission round-trip) → Tasks 5–7. ✅
- `LocalPty :pipes` → Task 8. ✅
- SessionServer generalization (launch, IO, casts, attach, resume via `session/load`) → Tasks 9, 11. ✅
- Channel ACP join snapshot + inbound/outbound → Task 10. ✅
- MCP via `session/new mcpServers` (local) → Task 9 Step 4 (`acp_mcp_servers/3`). ✅
- Rich surface: seamless thread, tool calls + diffs, sticky plan, queue + send-now, context composer, interactive permissions, transport toggle → Tasks 13–16. ✅
- In-memory timeline + repaint via `session/load` → Tasks 4, 11; reattach replay → Tasks 9 (attach), 13 (store). ✅
- No client-side `fs`/`terminal` capabilities → Task 5 Step 3 (empty `clientCapabilities`). ✅
- Error handling: malformed frame skip (Task 5), error item on JSON-RPC error (Task 5), backend restart → `:interrupted` (existing janitor covers ACP statuses unchanged — no new task needed; verify in Task 11 precommit). ✅

**Deferred to later phases (out of this plan, per spec):** cloud `Sprites :pipes` + tunnel `mcpServers` rewrite (Phase 2); Codex/Gemini harnesses (Phase 3); Legend-side durable transcript; client-side `fs`/`terminal`.

**Placeholder scan:** the `do_prompt`/`dispatch_incoming` stubs in Task 5 are explicitly replaced in Tasks 6–7 (called out in each). No `TBD`/"handle edge cases"/uncoded steps remain.

**Type consistency:** item maps use string keys end-to-end (`"id"`, `"seq"`, `"type"`, `"text"`, `"status"`, `"diff"`); the channel pushes `{seq, item}`; the store upserts by `item.id`/`item.seq`. `Acp.Connection` function names (`new/1`, `handle_bytes/2`, `prompt/2`, `cancel/1`, `set_mode/2`, `answer_permission/3`) are consistent across Tasks 5–10. SessionServer casts (`acp_prompt`/`acp_cancel`/`acp_set_mode`/`acp_permission`) match the channel handlers in Task 10.

**Verify-at-plan-time (from the spec) to confirm during implementation:** whether `claude-code-acp` accepts a pinned session id at `session/new` (Task 9 captures by default); the exact ACP protocol version integer and `session/update`/content field shapes (Tasks 5–7 pin to what the installed adapter emits — adjust the decoders against a real capture in Task 16 smoke); the `claude-code-acp` binary name/launch (Task 2 config key).
