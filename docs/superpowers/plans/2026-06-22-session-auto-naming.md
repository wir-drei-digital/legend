# Session Auto-Naming + Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-fill a blank session name from the first prompt (launch `instructions` or the first ACP prompt), and let users rename a session afterward.

**Architecture:** A pure deriver (`Legend.Core.Agents.SessionName.derive/1`) turns prompt text into a clean title. Two trigger sites use it: the `:start` action fills the name atomically from `instructions`; the `SessionServer` fills it from the first ACP prompt and persists via a new shared `update :rename` action. `:rename` also powers a manual rename (JSON:API route + inline-edit UI). The open pane updates through the existing `sessions:lobby` refetch → prop path — no new broadcast.

**Tech Stack:** Elixir 1.20 / Ash 3 / AshSqlite, Phoenix channels + PubSub, SvelteKit 2 / Svelte 5 runes / Tailwind v4.

## Global Constraints

- Backend: run `mix precommit` (compile `--warnings-as-errors` + format + test) before finishing backend work. Run from `backend/`.
- The session `name` flows into the PTY nudge label (`Terminal.nudge_line/3`) — it MUST stay free of control characters. The deriver strips them; the `:start` and `:rename` validations reject them (`~r/\A[^[:cntrl:]]*\z/u`, max 120 chars).
- AshSqlite has no atomic bulk update — every `update` action sets `require_atomic? false` (existing convention in `session.ex`).
- Frontend: use Legend design tokens + shell primitives only (`text-ink-*`, `bg-app`, `text-ui`, `border-hair*`, `MenuItem`, `IconButton`) — never raw shadcn neutrals, ad-hoc hex, or ad-hoc `text-[Npx]`. Verify with `bun run check` from `frontend/`.
- Auto-naming only ever fills a **blank** name (a user-provided name always wins) and derives **once** per session.

---

## File Structure

- `backend/lib/legend/core/agents/session_name.ex` — **new**, pure deriver. One responsibility: prompt text → clean title or `nil`.
- `backend/test/legend/core/agents/session_name_test.exs` — **new**, deriver unit table.
- `backend/lib/legend/core/agents/session.ex` — **modify**, add `:start` name-fill change + `update :rename` action.
- `backend/lib/legend/core/agents.ex` — **modify**, add `/:id/rename` JSON:API route + `rename_session` code interface.
- `backend/test/legend/core/agents/session_auto_name_test.exs` — **new**, `:start` auto-fill + `:rename` action tests.
- `backend/lib/legend/core/agents/session_server.ex` — **modify**, `auto_named?` state + first-ACP-prompt trigger.
- `backend/test/legend/core/agents/session_server_acp_test.exs` — **modify**, ACP auto-name tests.
- `frontend/src/lib/sessions.ts` — **modify**, `renameSession`.
- `frontend/src/lib/components/sessions/SessionPane.svelte` — **modify**, Rename menu item + inline-edit header.

---

## Task 1: `SessionName` pure deriver

**Files:**
- Create: `backend/lib/legend/core/agents/session_name.ex`
- Test: `backend/test/legend/core/agents/session_name_test.exs`

**Interfaces:**
- Produces: `Legend.Core.Agents.SessionName.derive(text :: String.t() | nil) :: String.t() | nil` — a cleaned title of at most ~51 graphemes (50 + `…`), or `nil` when nothing usable remains.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/core/agents/session_name_test.exs`:

```elixir
defmodule Legend.Core.Agents.SessionNameTest do
  use ExUnit.Case, async: true

  alias Legend.Core.Agents.SessionName

  describe "derive/1 — blank input" do
    test "nil is nil", do: assert(SessionName.derive(nil) == nil)
    test "empty string is nil", do: assert(SessionName.derive("") == nil)
    test "whitespace only is nil", do: assert(SessionName.derive("   \n\t  ") == nil)
    test "punctuation/markers only is nil", do: assert(SessionName.derive("###") == nil)
    test "non-binary is nil", do: assert(SessionName.derive(%{}) == nil)
  end

  describe "derive/1 — plain text" do
    test "short prose is kept verbatim" do
      assert SessionName.derive("Fix the login bug") == "Fix the login bug"
    end

    test "only the first line is used" do
      assert SessionName.derive("Fix the login bug\nand also the logout one") ==
               "Fix the login bug"
    end

    test "internal whitespace runs collapse" do
      assert SessionName.derive("Fix    the\tlogin   bug") == "Fix the login bug"
    end
  end

  describe "derive/1 — markdown" do
    test "strips a heading marker" do
      assert SessionName.derive("# Refactor the auth module") == "Refactor the auth module"
    end

    test "strips a list marker" do
      assert SessionName.derive("- do the thing") == "do the thing"
    end

    test "strips a numbered marker" do
      assert SessionName.derive("1. first step") == "first step"
    end

    test "strips blockquote marker" do
      assert SessionName.derive("> quoted task") == "quoted task"
    end

    test "unwraps a markdown link to its text" do
      assert SessionName.derive("See [the issue](https://example.com/123)") ==
               "See the issue"
    end

    test "strips inline code and emphasis" do
      assert SessionName.derive("Update `config` and **rebuild**") == "Update config and rebuild"
    end
  end

  describe "derive/1 — code fences" do
    test "skips a leading fenced block to the first prose line" do
      assert SessionName.derive("```elixir\ndef foo, do: :ok\n```\nWire up the endpoint") ==
               "Wire up the endpoint"
    end

    test "an input that is only a fenced block is nil" do
      assert SessionName.derive("```\nsome code\n```") == nil
    end
  end

  describe "derive/1 — control chars" do
    test "strips embedded control characters" do
      assert SessionName.derive("Fix the bug") == "Fix the bug"
    end
  end

  describe "derive/1 — length" do
    test "long text is ellipsized on a word boundary within ~51 graphemes" do
      result = SessionName.derive(String.duplicate("word ", 40))
      assert String.length(result) <= 51
      assert String.ends_with?(result, "…")
      refute String.ends_with?(result, " …")
    end

    test "a single over-long word is hard-cut with an ellipsis" do
      result = SessionName.derive(String.duplicate("a", 80))
      assert String.length(result) == 51
      assert String.ends_with?(result, "…")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_name_test.exs`
Expected: FAIL — `module Legend.Core.Agents.SessionName is not available` / `function derive/1 is undefined`.

- [ ] **Step 3: Write minimal implementation**

Create `backend/lib/legend/core/agents/session_name.ex`:

```elixir
defmodule Legend.Core.Agents.SessionName do
  @moduledoc """
  Derives a human-readable session name from prompt text — the launch
  `instructions` (Session.:start) or the first ACP prompt (SessionServer).

  Pure and side-effect free: text in, a clean title of at most ~50 graphemes
  out (plus a trailing ellipsis when truncated), or `nil` when nothing usable
  remains. Control characters are stripped so the result is safe to render in
  the PTY nudge label.
  """

  @target 50

  @doc "Derive a session name from prompt text; `nil` for blank/unusable input."
  @spec derive(String.t() | nil) :: String.t() | nil
  def derive(text) when is_binary(text) do
    text
    |> first_prose_line()
    |> strip_markdown()
    |> strip_control()
    |> collapse_whitespace()
    |> ellipsize(@target)
    |> nilify_blank()
  end

  def derive(_), do: nil

  # First non-blank line that is neither a code-fence marker nor inside a fence.
  defp first_prose_line(text) do
    text
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> drop_until_prose(false)
  end

  defp drop_until_prose([], _in_fence), do: ""

  defp drop_until_prose([line | rest], in_fence) do
    cond do
      fence?(line) -> drop_until_prose(rest, not in_fence)
      in_fence -> drop_until_prose(rest, in_fence)
      line == "" -> drop_until_prose(rest, in_fence)
      true -> line
    end
  end

  defp fence?(line), do: String.starts_with?(line, "```") or String.starts_with?(line, "~~~")

  defp strip_markdown(line) do
    line
    # leading heading / blockquote / list markers (possibly repeated, e.g. "> - ")
    |> String.replace(~r/^\s*(?:[#>]+\s*|[-*+]\s+|\d+[.)]\s+)+/u, "")
    # markdown links/images: [text](url) / ![alt](url) -> text/alt
    |> String.replace(~r/!?\[([^\]]*)\]\([^)]*\)/u, "\\1")
    # inline code backticks
    |> String.replace("`", "")
    # bold/italic/strikethrough emphasis markers
    |> String.replace(~r/(\*\*|\*|__|_|~~)/u, "")
    |> String.trim()
  end

  defp strip_control(s), do: String.replace(s, ~r/[[:cntrl:]]/u, "")

  defp collapse_whitespace(s), do: s |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Truncate to `target` graphemes, backing off to the last word boundary; append
  # an ellipsis when the text was cut. A single over-long word is hard-cut.
  defp ellipsize(s, target) do
    if String.length(s) <= target do
      s
    else
      head = String.slice(s, 0, target)

      cut =
        case String.split(head, " ") do
          parts when length(parts) > 1 -> parts |> Enum.drop(-1) |> Enum.join(" ")
          _ -> head
        end

      String.trim_trailing(cut) <> "…"
    end
  end

  defp nilify_blank(""), do: nil
  defp nilify_blank("…"), do: nil
  defp nilify_blank(s), do: s
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_name_test.exs`
Expected: PASS (all tests green).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/agents/session_name.ex backend/test/legend/core/agents/session_name_test.exs
git commit -m "feat(sessions): pure SessionName.derive/1 for auto-naming

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Auto-fill name from `instructions` in `:start`

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex` (inside `create :start`, after the transport-default change at `:80-93`, before the `after_transaction` at `:95`)
- Test: `backend/test/legend/core/agents/session_auto_name_test.exs` (new)

**Interfaces:**
- Consumes: `Legend.Core.Agents.SessionName.derive/1` (Task 1).
- Produces: a session created with blank name + non-blank `instructions` comes back with `name` set to `derive(instructions)`.

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/core/agents/session_auto_name_test.exs`:

```elixir
defmodule Legend.Core.Agents.SessionAutoNameTest do
  use Legend.DataCase, async: false
  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()

    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)
      Application.delete_env(:legend, :test_runtime_detect)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  describe ":start auto-name from instructions" do
    test "fills a blank name from the instructions" do
      {:ok, s} =
        Agents.start_session(%{
          harness_id: "claude_code",
          runtime_id: "test",
          transport: :terminal,
          instructions: "Fix the login redirect bug"
        })

      assert s.name == "Fix the login redirect bug"
    end

    test "does not override a user-provided name" do
      {:ok, s} =
        Agents.start_session(%{
          harness_id: "claude_code",
          runtime_id: "test",
          transport: :terminal,
          name: "My session",
          instructions: "Fix the login redirect bug"
        })

      assert s.name == "My session"
    end

    test "leaves name nil when there are no instructions" do
      {:ok, s} =
        Agents.start_session(%{
          harness_id: "claude_code",
          runtime_id: "test",
          transport: :terminal
        })

      assert s.name == nil
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_auto_name_test.exs:21`
Expected: FAIL — the first test asserts `s.name == "Fix the login redirect bug"` but `name` is `nil`.

- [ ] **Step 3: Write minimal implementation**

In `backend/lib/legend/core/agents/session.ex`, inside `create :start`, add this change immediately after the transport-default `change fn ... end` block (the one ending at line ~93) and before the `# after_transaction` comment at line ~95:

```elixir
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_auto_name_test.exs`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/test/legend/core/agents/session_auto_name_test.exs
git commit -m "feat(sessions): auto-name from instructions at :start

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: `update :rename` action + route + code interface

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex` (add `update :rename` among the update actions, e.g. after `update :set_transport` near `:202-205`)
- Modify: `backend/lib/legend/core/agents.ex` (add route in the `base_route` block; add `define :rename_session`)
- Test: `backend/test/legend/core/agents/session_auto_name_test.exs` (append a describe block)

**Interfaces:**
- Consumes: `Legend.Core.Agents.Notifications.sessions_changed/0` (existing).
- Produces:
  - Action `:rename` accepting `%{name: String.t() | nil}`; trims, stores `nil` when blank, validates control chars + length ≤ 120, emits `sessions_changed` after commit.
  - Code interface `Agents.rename_session(record_or_id, params \\ %{}, opts \\ [])` (and the auto-generated `rename_session!/3`).
  - JSON:API route `PATCH /api/sessions/:id/rename`.

- [ ] **Step 1: Write the failing test**

Append to `backend/test/legend/core/agents/session_auto_name_test.exs` (inside the module, after the existing describe block):

```elixir
  describe ":rename action" do
    setup do
      {:ok, s} =
        Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :terminal})

      %{session: s}
    end

    test "renames and broadcasts a list change", %{session: s} do
      Phoenix.PubSub.subscribe(Legend.PubSub, Legend.Core.Agents.Notifications.topic())

      {:ok, renamed} = Agents.rename_session(s, %{name: "Polished name"})

      assert renamed.name == "Polished name"
      assert_receive :sessions_changed, 1_000
    end

    test "a blank name resets to nil", %{session: s} do
      {:ok, named} = Agents.rename_session(s, %{name: "Temp"})
      {:ok, cleared} = Agents.rename_session(named, %{name: "   "})
      assert cleared.name == nil
    end

    test "rejects control characters", %{session: s} do
      assert {:error, _} = Agents.rename_session(s, %{name: "badname"})
    end

    test "rejects a name over 120 chars", %{session: s} do
      assert {:error, _} = Agents.rename_session(s, %{name: String.duplicate("x", 121)})
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_auto_name_test.exs`
Expected: FAIL — `function Legend.Core.Agents.rename_session/2 is undefined`.

- [ ] **Step 3a: Add the `:rename` action**

In `backend/lib/legend/core/agents/session.ex`, add after the `update :set_transport do ... end` action (around line 205):

```elixir
    # Manual rename + the auto-namer's deferred write share this action. It
    # accepts any name (the "only-if-blank" guard lives at the auto-name call
    # site). After commit it nudges the session list to refetch; the open pane
    # picks the new name up via that refetch → its `session` prop (no per-session
    # broadcast needed).
    update :rename do
      require_atomic? false
      accept [:name]

      # Trim; an all-blank name resets to nil so the UI falls back to harness_id.
      change fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :name) do
          nil ->
            changeset

          name ->
            trimmed = String.trim(name)
            Ash.Changeset.force_change_attribute(
              changeset,
              :name,
              if(trimmed == "", do: nil, else: trimmed)
            )
        end
      end

      validate match(:name, ~r/\A[^[:cntrl:]]*\z/u) do
        message "must not contain control characters"
        where present(:name)
      end

      validate string_length(:name, max: 120) do
        where present(:name)
      end

      change after_transaction(fn
               _changeset, {:ok, session}, _context ->
                 Legend.Core.Agents.Notifications.sessions_changed()
                 {:ok, session}

               _changeset, {:error, _} = error, _context ->
                 error
             end)
    end
```

- [ ] **Step 3b: Add the route + code interface**

In `backend/lib/legend/core/agents.ex`, add the route inside the `base_route "/sessions", ... do` block (after `patch :set_transport, route: "/:id/transport"`, line 16):

```elixir
        patch :rename, route: "/:id/rename"
```

And add the code interface inside `resource Legend.Core.Agents.Session do` (after `define :set_session_transport, ...`, line 35):

```elixir
      define :rename_session, action: :rename
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_auto_name_test.exs`
Expected: PASS (all `:rename` tests + the Task 2 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/lib/legend/core/agents.ex backend/test/legend/core/agents/session_auto_name_test.exs
git commit -m "feat(sessions): :rename action, route, and code interface

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: First-ACP-prompt auto-name trigger

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex` (state init `:173-184`; the `handle_cast({:acp_prompt, content}, %{transport: :acp})` clause `:525-527`; add `maybe_auto_name/2` near `prompt_text/1` `:832-843`)
- Test: `backend/test/legend/core/agents/session_server_acp_test.exs` (append tests)

**Interfaces:**
- Consumes: `Legend.Core.Agents.SessionName.derive/1` (Task 1); `Agents.rename_session/2` (Task 3); the existing private `prompt_text/1`.
- Produces: a blank-named ACP session is renamed (persisted) from its first prompt; the in-memory `state.session` is updated and `auto_named?` set so it fires once.

- [ ] **Step 1: Write the failing test**

Append to `backend/test/legend/core/agents/session_server_acp_test.exs` (inside the module, before the private helpers at the bottom):

```elixir
  test "acp session: the first prompt auto-names a blank session" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    drive_to_live(s.id)
    drain_test_runtime_writes()

    Agents.SessionServer.acp_prompt(s.id, "Refactor the auth module")

    assert eventually(fn -> Agents.get_session!(s.id).name == "Refactor the auth module" end)
  end

  test "acp session: the first prompt does not overwrite a user-provided name" do
    {:ok, s} =
      Agents.start_session(%{
        harness_id: "claude_code",
        runtime_id: "test",
        transport: :acp,
        name: "My session"
      })

    drive_to_live(s.id)
    drain_test_runtime_writes()

    Agents.SessionServer.acp_prompt(s.id, "Refactor the auth module")
    # Let the cast finish processing before reading the record.
    _ = :sys.get_state(Agents.SessionServer.whereis(s.id))

    assert Agents.get_session!(s.id).name == "My session"
  end

  test "acp session: only the first prompt names the session" do
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    drive_to_live(s.id)
    drain_test_runtime_writes()

    Agents.SessionServer.acp_prompt(s.id, "First task here")
    assert eventually(fn -> Agents.get_session!(s.id).name == "First task here" end)

    # A later prompt (queued behind the in-flight first turn) must NOT re-derive.
    Agents.SessionServer.acp_prompt(s.id, "A completely different second task")
    _ = :sys.get_state(Agents.SessionServer.whereis(s.id))

    assert Agents.get_session!(s.id).name == "First task here"
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs -k "auto-names a blank"`
Expected: FAIL — `eventually(...)` returns `false`; the session name stays `nil`.

- [ ] **Step 3a: Add `auto_named?` to the initial state**

In `backend/lib/legend/core/agents/session_server.ex`, in the `Map.merge(transport_state, %{...})` at lines 173–184, add `auto_named?: false` (after `exited?: false`):

```elixir
           Map.merge(transport_state, %{
             session: session,
             harness: harness,
             runtime: runtime,
             handle: handle,
             tunnel: tunnel,
             exited?: false,
             auto_named?: false,
             nudge_count: 0,
             nudge_froms: MapSet.new(),
             nudge_timer: nil
           })}
```

- [ ] **Step 3b: Hook the trigger into the prompt cast**

Replace the `handle_cast({:acp_prompt, content}, %{transport: :acp} = state)` clause (lines 525–527) with:

```elixir
  def handle_cast({:acp_prompt, content}, %{transport: :acp} = state) do
    state = maybe_auto_name(state, content)
    {:noreply, send_or_queue_prompt(state, content)}
  end
```

- [ ] **Step 3c: Add `maybe_auto_name/2`**

Add these private functions next to `prompt_text/1` (after line 843):

```elixir
  # Best-effort: name a still-unnamed ACP session from its first prompt. Fires at
  # most once (auto_named? guard), only when the user left the name blank, and
  # never blocks the prompt — a rename failure is logged and the turn proceeds.
  defp maybe_auto_name(%{auto_named?: true} = state, _content), do: state

  defp maybe_auto_name(state, content) do
    cond do
      not blank_name?(state.session.name) ->
        %{state | auto_named?: true}

      true ->
        case Legend.Core.Agents.SessionName.derive(prompt_text(content)) do
          nil ->
            state

          name ->
            case Agents.rename_session(state.session, %{name: name}) do
              {:ok, session} ->
                %{state | session: session, auto_named?: true}

              {:error, reason} ->
                Logger.warning("[acp #{state.session.id}] auto-name failed: #{inspect(reason)}")
                %{state | auto_named?: true}
            end
        end
    end
  end

  defp blank_name?(nil), do: true
  defp blank_name?(name) when is_binary(name), do: String.trim(name) == ""
```

> Note: leave `state` unchanged (no flag set) when `derive/1` returns `nil`, so a future prompt with usable text can still name the session. `Logger` and `Agents` are already aliased/required in this module.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs`
Expected: PASS (the three new tests + all existing ACP tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/agents/session_server.ex backend/test/legend/core/agents/session_server_acp_test.exs
git commit -m "feat(sessions): auto-name a blank ACP session from its first prompt

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: Backend gate**

Run: `cd backend && mix precommit`
Expected: compiles with no warnings, formatted, all tests pass. Fix anything it flags before moving on.

---

## Task 5: Frontend rename client + inline-edit header

**Files:**
- Modify: `frontend/src/lib/sessions.ts` (add `renameSession` after `setTransport`, line ~116)
- Modify: `frontend/src/lib/components/sessions/SessionPane.svelte` (import; rename state + handlers; header span → conditional input; Rename menu item)

**Interfaces:**
- Consumes: `PATCH /api/sessions/:id/rename` (Task 3).
- Produces: `renameSession(id: string, name: string): Promise<void>`; a Rename action in the pane's ⋯ menu that swaps the header title for an inline input (Enter commits, Esc/blur cancels-or-commits). The header re-renders from the `session` prop after the lobby refetch.

- [ ] **Step 1: Add the API client**

In `frontend/src/lib/sessions.ts`, add after `setTransport` (after line 116):

```ts
export async function renameSession(id: string, name: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/sessions/${id}/rename`, {
		method: 'PATCH',
		headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
		body: JSON.stringify({ data: { type: 'session', id, attributes: { name } } })
	});
	if (!res.ok) throw new Error(await errorMessage(res, 'renaming session failed'));
}
```

- [ ] **Step 2: Import it in SessionPane**

In `frontend/src/lib/components/sessions/SessionPane.svelte`, add `renameSession` to the existing `$lib/sessions` import (lines 21–28):

```ts
	import {
		deleteSession,
		listHarnesses,
		renameSession,
		resumeSession,
		setTransport,
		type Harness,
		type Session
	} from '$lib/sessions';
```

- [ ] **Step 3: Add rename state + handlers**

In the `<script>`, after the menu state declarations (after `let detailsOpen = $state(false);`, line ~125), add:

```ts
	// ---- inline rename (triggered from the ⋯ menu; edits the header title) ----
	let editingName = $state(false);
	let nameDraft = $state('');

	function startRename() {
		nameDraft = session.name ?? '';
		editingName = true;
		menuOpen = false;
	}

	async function commitRename() {
		if (!editingName) return;
		editingName = false;
		const next = nameDraft.trim();
		if (next === (session.name ?? '')) return;
		try {
			await renameSession(session.id, next);
			// The lobby 'changed' refetch updates session.name via the prop.
		} catch {
			// Keep the current name on failure; the header reflects session.name.
		}
	}

	// Focus + select the input the moment it mounts so the name is editable at once.
	function autofocus(node: HTMLInputElement) {
		node.focus();
		node.select();
	}
```

- [ ] **Step 4: Make the header title editable**

Replace the name `<span>` (lines 191–193) with:

```svelte
				{#if editingName}
					<!-- stopPropagation so typing/clicking doesn't start a header drag -->
					<input
						class="shrink-0 rounded-[5px] border border-hair-strong bg-app px-1 text-ui font-semibold text-ink-1 outline-none"
						bind:value={nameDraft}
						onpointerdown={(e) => e.stopPropagation()}
						onblur={commitRename}
						onkeydown={(e) => {
							if (e.key === 'Enter') {
								e.preventDefault();
								commitRename();
							} else if (e.key === 'Escape') {
								e.preventDefault();
								editingName = false;
							}
						}}
						use:autofocus
					/>
				{:else}
					<span class="shrink-0 text-ui font-semibold text-ink-1">
						{session.name || session.harness_id}
					</span>
				{/if}
```

- [ ] **Step 5: Add the Rename menu item**

In the actions `Popover` (lines 268–288), add a Rename item right after the suspend/resume `{#if isLive}...{/if}` block and before the `<div class="my-1 h-px bg-hair"></div>` divider:

```svelte
						<MenuItem icon="pencil" onclick={startRename}>Rename</MenuItem>
```

- [ ] **Step 6: Verify the frontend compiles + type-checks**

Run: `cd frontend && bun run check`
Expected: PASS — no svelte-check errors. (`pencil` is a valid `Icon` name; `renameSession` is exported.)

- [ ] **Step 7: Commit**

```bash
git add frontend/src/lib/sessions.ts frontend/src/lib/components/sessions/SessionPane.svelte
git commit -m "feat(sessions): rename a session inline from the pane header

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Manual verification (after all tasks)

1. `just dev`, open `:4173`.
2. New session, **leave name blank**, harness Claude Code, transport **rich (ACP)** → send a first prompt like "Refactor the auth module". The pane header + session list should update to "Refactor the auth module" within a moment (lobby refetch).
3. Open the pane's ⋯ menu → **Rename** → edit → Enter. The header and list reflect the new name. Esc mid-edit reverts.
4. New session **with** a typed name → first prompt does NOT overwrite it.
5. Terminal-only session with no instructions → stays `harness_id` until renamed (documented gap).

---

## Self-Review

**Spec coverage:** §1 deriver → Task 1. §2 instructions trigger → Task 2. §3 `:rename` action (validation, nil-on-blank, `sessions_changed`) → Task 3. §4 first-ACP-prompt trigger (`auto_named?`, best-effort, once-only) → Task 4. §5 route + client → Tasks 3 & 5. §6 inline-edit header (no channel change) → Task 5. Edge cases covered across the deriver table (Task 1) and ACP tests (Task 4). Out-of-scope items (PTY sniffing, LLM, re-derive) are not implemented — correct.

**Placeholder scan:** none — every code step shows full content.

**Type consistency:** `SessionName.derive/1` (Task 1) is used verbatim in Tasks 2 & 4. `Agents.rename_session/2` defined in Task 3, called in Task 4 and (as `renameSession`) Task 5. `auto_named?` introduced in Task 4 state and read in `maybe_auto_name/2`. `prompt_text/1` is the existing private helper reused in Task 4. JSON:API route `/:id/rename` (Task 3) matches the `renameSession` fetch path (Task 5).
