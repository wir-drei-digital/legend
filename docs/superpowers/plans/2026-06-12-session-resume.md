# Session Resume on Restart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a backend restart, sessions show as `:interrupted` (not failed) and a manual Resume relaunches a fresh agent process into the same conversation (Claude Code `--session-id`/`--resume`); messages queued during downtime get nudged on resume.

**Architecture:** Suspend/resume, not true survival (spec: `docs/superpowers/specs/2026-06-12-session-resume-design.md`). New `:interrupted` status + `:resume` update action on the Session resource (same record/process lockstep pattern as `:start`); the boot janitor interrupts instead of failing; the `Terminal` contract gains `mode: :fresh | :resume` + `session_id` opts that ClaudeCode maps to `--session-id`/`--resume`; SessionServer threads the mode and fires a catch-up nudge for unread messages on any (re)start.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 / Ash 3 (AshSqlite, AshJsonApi), SvelteKit 2 / Svelte 5 runes.

**Conventions for every task:**
- Backend commands from `backend/`: `mix test [path]`, `mix format` before each commit. Final task runs `mix precommit`.
- Tests that boot sessions use `runtime_id: "test"` (in-memory `Legend.Runtimes.Test`) and sweep SessionServers:
  ```elixir
  on_exit(fn ->
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Core.Agents.SessionSupervisor) do
      DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
    end
  end)
  ```
- Current suite baseline: **162 passed**. Frontend: `cd frontend && bun run check`.

---

### Task 1: Harness layer — `Definition.resumable`, `mode`/`session_id` opts, ClaudeCode mapping

**Files:**
- Modify: `backend/lib/legend/core/harness.ex` (Definition struct)
- Modify: `backend/lib/legend/core/harness/terminal.ex` (opts type only)
- Modify: `backend/lib/legend/harnesses/claude_code.ex`
- Modify: `backend/lib/legend_web/controllers/harness_controller.ex`
- Test: `backend/test/legend/harnesses_test.exs` (append), `backend/test/legend_web/controllers/harness_controller_test.exs` (append)

- [ ] **Step 1: Write the failing tests** — append to `backend/test/legend/harnesses_test.exs` (new describe block; match existing file style):

```elixir
  describe "resume wiring" do
    @resume_opts %{
      library: %{path: "/lib", primer: ""},
      messaging: %{primer: "", instructions: "do the thing"},
      session_id: "11111111-2222-3333-4444-555555555555"
    }

    test "claude_code is resumable, hermes is not" do
      assert Legend.Harnesses.ClaudeCode.definition().resumable == true
      assert Legend.Harnesses.Hermes.definition().resumable == false
    end

    test "claude_code pins the conversation id on fresh launch" do
      spec = Legend.Harnesses.ClaudeCode.build_command(Map.put(@resume_opts, :mode, :fresh))
      index = Enum.find_index(spec.args, &(&1 == "--session-id"))
      assert index
      assert Enum.at(spec.args, index + 1) == "11111111-2222-3333-4444-555555555555"
      # Instructions still delivered on fresh launch.
      assert List.last(spec.args) == "do the thing"
    end

    test "claude_code mode defaults to fresh when absent" do
      spec = Legend.Harnesses.ClaudeCode.build_command(@resume_opts)
      assert "--session-id" in spec.args
      refute "--resume" in spec.args
    end

    test "claude_code resumes the conversation and omits instructions" do
      spec = Legend.Harnesses.ClaudeCode.build_command(Map.put(@resume_opts, :mode, :resume))
      index = Enum.find_index(spec.args, &(&1 == "--resume"))
      assert index
      assert Enum.at(spec.args, index + 1) == "11111111-2222-3333-4444-555555555555"
      refute "--session-id" in spec.args
      # The conversation already contains the instructions — never re-send.
      refute "do the thing" in spec.args
    end

    test "claude_code without a session_id emits no session flags" do
      spec = Legend.Harnesses.ClaudeCode.build_command(Map.delete(@resume_opts, :session_id))
      refute "--session-id" in spec.args
      refute "--resume" in spec.args
    end

    test "hermes ignores mode (resume degrades to fresh)" do
      fresh = Legend.Harnesses.Hermes.build_command(Map.put(@resume_opts, :mode, :fresh))
      resumed = Legend.Harnesses.Hermes.build_command(Map.put(@resume_opts, :mode, :resume))
      assert fresh.args == resumed.args
      refute "--resume" in resumed.args
    end
  end
```

And append to `backend/test/legend_web/controllers/harness_controller_test.exs` (inside the existing module, matching its conventions):

```elixir
  test "harness payload includes resumable", %{conn: conn} do
    data = json_response(get(conn, ~p"/api/harnesses"), 200)["data"]
    claude = Enum.find(data, &(&1["id"] == "claude_code"))
    hermes = Enum.find(data, &(&1["id"] == "hermes"))
    assert claude["resumable"] == true
    assert hermes["resumable"] == false
  end
```

(If the existing file doesn't take `%{conn: conn}` from ConnCase setup, match however its other tests build conns.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd backend && mix test test/legend/harnesses_test.exs test/legend_web/controllers/harness_controller_test.exs`
Expected: FAIL — `resumable` key missing from Definition, no `--session-id` in args.

- [ ] **Step 3: Extend the Definition struct** — in `backend/lib/legend/core/harness.ex`, the nested `Definition` module currently has:

```elixir
    defstruct [:id, :name, :kind, description: "", resumable: false]
```

(i.e. add `resumable: false` to the existing `defstruct [:id, :name, :kind, description: ""]`; update the struct's `@type` if one exists to include `resumable: boolean()`.)

- [ ] **Step 4: Extend the Terminal opts type** — in `backend/lib/legend/core/harness/terminal.ex`, add to the `opts` type:

```elixir
          optional(:mode) => :fresh | :resume,
          optional(:session_id) => String.t(),
```

And append to the moduledoc's Messaging contract section:

```
  ## Resume contract

  When opts contain `:session_id`, a resumable harness SHOULD pin the agent's
  conversation id to it at fresh launch and reopen that conversation when
  `mode: :resume` (omitting `messaging.instructions` — the conversation already
  contains them). Harnesses without a resume mechanism ignore `:mode`; resume
  degrades to a fresh process. Declare support via `Definition.resumable`.
```

- [ ] **Step 5: ClaudeCode mapping** — in `backend/lib/legend/harnesses/claude_code.ex`:

Set `resumable: true` in `definition/0`:

```elixir
    %Definition{
      id: "claude_code",
      name: "Claude Code",
      description: "Anthropic's agentic coding CLI",
      kind: :terminal,
      resumable: true
    }
```

Change `build_command/1`'s args line to:

```elixir
      args: args ++ primer_args(opts) ++ mcp_args(opts) ++ session_args(opts) ++ instruction_args(opts),
```

Add `session_args/1` and a resume-mode head on `instruction_args/1` (keep the existing `instruction_args` clauses below the new head):

```elixir
  # Our session id IS the agent's conversation id: pinned at fresh launch,
  # reopened on resume (per the Terminal resume contract).
  defp session_args(%{session_id: id, mode: :resume}) when is_binary(id), do: ["--resume", id]
  defp session_args(%{session_id: id}) when is_binary(id), do: ["--session-id", id]
  defp session_args(_opts), do: []

  # The resumed conversation already contains the instructions — never re-send.
  defp instruction_args(%{mode: :resume}), do: []
```

- [ ] **Step 6: HarnessController** — in `backend/lib/legend_web/controllers/harness_controller.ex`, add `resumable` to the serialized map:

```elixir
        %{id: d.id, name: d.name, description: d.description, kind: d.kind, resumable: d.resumable}
```

- [ ] **Step 7: Run tests**

Run: `cd backend && mix test test/legend/harnesses_test.exs test/legend_web/controllers/harness_controller_test.exs`
Expected: PASS (all existing + 7 new). Then full `mix test` → 169 passed.

- [ ] **Step 8: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: harness resume contract (mode/session_id, Definition.resumable)"
```

---

### Task 2: SessionServer — mode threading + catch-up nudge

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex`
- Test: `backend/test/legend/core/agents/session_server_test.exs` (append)

- [ ] **Step 1: Write the failing tests** — append inside the module (it has `boot!/1`, `eventually/2`, setup providing `%{session: session}` with `@valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}`):

```elixir
  test "fresh start passes session_id and fresh mode to the harness", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, spec, _opts}

    index = Enum.find_index(spec.args, &(&1 == "--session-id"))
    assert index
    assert Enum.at(spec.args, index + 1) == session.id
    refute "--resume" in spec.args
  end

  test "resume start passes resume mode to the harness", %{session: session} do
    {:ok, _pid} = SessionServer.start_session(session, :resume)
    assert_receive {:test_runtime, :start, spec, _opts}

    index = Enum.find_index(spec.args, &(&1 == "--resume"))
    assert index
    assert Enum.at(spec.args, index + 1) == session.id
    refute "--session-id" in spec.args
  end

  test "unread messages at start fire a catch-up nudge", %{session: session} do
    sender =
      Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp", name: "queued"})

    # Message lands while the target session has no live server (it was
    # ensure_stopped in setup) — simulating downtime.
    Legend.Core.Signals.send_message!(%{
      from_session_id: sender.id,
      to_session_id: session.id,
      payload: "sent while you were away"
    })

    boot!(session)
    assert_receive {:test_runtime, :write, line}, 500
    assert line =~ "1 unread message(s)"
    assert line =~ "queued"
  end

  test "no catch-up nudge when the inbox is empty", %{session: session} do
    boot!(session)
    assert_receive {:test_runtime, :start, _spec, _opts}
    refute_receive {:test_runtime, :write, _}, 200
  end
```

- [ ] **Step 2: Run** `cd backend && mix test test/legend/core/agents/session_server_test.exs`
Expected: new tests FAIL (`start_session/2` undefined; no `--session-id` arg; no catch-up write).

- [ ] **Step 3: Implement** — in `backend/lib/legend/core/agents/session_server.ex`:

Replace the client API start functions:

```elixir
  def start_session(%Agents.Session{} = session, mode \\ :fresh) do
    DynamicSupervisor.start_child(
      Legend.Core.Agents.SessionSupervisor,
      {__MODULE__, {session, mode}}
    )
  end

  def start_link({session, mode}) do
    GenServer.start_link(__MODULE__, {session, mode}, name: via(session.id))
  end
```

Change `init/1`'s head and the two lines that use mode/session_id:

```elixir
  def init({session, mode}) do
    Process.flag(:trap_exit, true)

    with {:ok, harness} <- fetch_registered(Legend.Core.Harness.Registry, session.harness_id),
         {:ok, runtime} <- fetch_registered(Legend.Core.Runtime.Registry, session.runtime_id),
         spec = harness.build_command(build_opts(session, mode)),
```

(everything else in the `with` and the success/rescue/else branches stays exactly as it is.)

In the success branch, directly after the existing `Phoenix.PubSub.subscribe(...inbox_topic...)` line, add:

```elixir
        # Catch-up: messages that arrived while this session had no live server
        # (downtime, or sent during :starting) are sitting unread — re-feed them
        # through the normal debounced-nudge path so the agent gets one knock.
        for message <- Signals.unread_messages!(session.id) do
          send(self(), {:new_message, Signals.Notifications.summary(message)})
        end
```

Change `build_opts/1` to `build_opts/2`:

```elixir
  defp build_opts(session, mode) do
    base = %{
      library: %{path: Legend.Core.Library.root(), primer: Legend.Core.Library.primer()},
      messaging: %{
        primer: Signals.messaging_primer(session),
        instructions: session.instructions
      },
      mode: mode,
      session_id: session.id
    }

    case session.mcp_token do
      nil -> base
      token -> Map.put(base, :mcp, %{url: mcp_url(), token: token})
    end
  end
```

- [ ] **Step 4: Run the full suite** (`mix test`) — the changed child-spec/start_link shape must not break any existing test. Pre-existing tests call `SessionServer.start_session(session)` (1-arity still works via the default) and `boot!/1`. Expected: 173 passed (169 + 4).

Note: the pre-existing test `"sessions get MCP env vars and harness opts"` asserts `"--mcp-config" in spec.args` — unaffected. If any test asserted an exact full args list, adapt it minimally for the new `--session-id <id>` pair and say so in the commit body.

- [ ] **Step 5: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: SessionServer resume mode threading + catch-up nudge"
```

---

### Task 3: Resource lifecycle — `:interrupted` status, `:resume` action, janitor, API route

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex`
- Create: `backend/lib/legend/core/agents/validations/resumable_status.ex`
- Modify: `backend/lib/legend/core/agents.ex`
- Modify: `backend/lib/legend/core/agents/janitor.ex`
- Test: `backend/test/legend/core/agents/session_test.exs` (append), `backend/test/legend/core/agents/session_server_test.exs` (modify janitor test), `backend/test/legend_web/controllers/session_api_test.exs` (append)

- [ ] **Step 1: Write the failing tests**

Append to `backend/test/legend/core/agents/session_test.exs` (new describe; reuse the file's aliases and SessionServer sweep conventions):

```elixir
  describe "resume" do
    test "resume from :interrupted restarts the process and clears the run fields" do
      session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
      Legend.Core.Agents.SessionServer.ensure_stopped(session.id)
      session = Agents.interrupt_session!(Agents.get_session!(session.id))
      assert session.status == :interrupted
      assert session.ended_at

      resumed = Agents.resume_session!(session)

      assert resumed.status == :running
      assert resumed.ended_at == nil
      assert resumed.error == nil
      assert resumed.exit_code == nil
      assert Legend.Core.Agents.SessionServer.whereis(resumed.id)
    end

    test "resume from :exited works (continue a finished conversation)" do
      session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
      pid = Legend.Core.Agents.SessionServer.whereis(session.id)
      send(pid, {:runtime_exit, 0})

      eventually(fn -> Agents.get_session!(session.id).status == :exited end)
      # The exited server stays alive holding scrollback — stop it so resume
      # can register a fresh one under the same id.
      Legend.Core.Agents.SessionServer.ensure_stopped(session.id)

      resumed = Agents.resume_session!(Agents.get_session!(session.id))
      assert resumed.status == :running
      assert resumed.exit_code == nil
    end

    test "resume is rejected while running" do
      session = Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})
      assert {:error, %Ash.Error.Invalid{}} = Agents.resume_session(session)
    end

    defp eventually(fun, attempts \\ 50) do
      cond do
        fun.() -> :ok
        attempts == 0 -> flunk("condition never became true")
        true ->
          Process.sleep(20)
          eventually(fun, attempts - 1)
      end
    end
  end
```

(If the file already defines an `eventually` helper at module level, use it instead of redefining.)

In `backend/test/legend/core/agents/session_server_test.exs`, **replace** the janitor test:

```elixir
  test "janitor marks orphaned running sessions as interrupted", %{session: session} do
    pid = boot!(session)
    assert Agents.get_session!(session.id).status == :running

    # Simulate a backend restart: the process dies, the record stays :running.
    DynamicSupervisor.terminate_child(Legend.Core.Agents.SessionSupervisor, pid)
    assert Agents.get_session!(session.id).status == :running

    Legend.Core.Agents.Janitor.run()

    record = Agents.get_session!(session.id)
    assert record.status == :interrupted
    assert record.error == nil
    assert record.ended_at
  end
```

Append to `backend/test/legend_web/controllers/session_api_test.exs` (match its conn/header conventions; it uses `application/vnd.api+json`):

```elixir
  test "PATCH /api/sessions/:id/resume resumes an interrupted session", %{conn: conn} do
    session =
      Legend.Core.Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    Legend.Core.Agents.SessionServer.ensure_stopped(session.id)
    Legend.Core.Agents.interrupt_session!(Legend.Core.Agents.get_session!(session.id))

    response =
      conn
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> patch(
        "/api/sessions/#{session.id}/resume",
        Jason.encode!(%{data: %{type: "session", id: session.id, attributes: %{}}})
      )
      |> json_response(200)

    assert response["data"]["attributes"]["status"] == "running"
  end

  test "PATCH /api/sessions/:id/resume on a running session is rejected", %{conn: conn} do
    session =
      Legend.Core.Agents.start_session!(%{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"})

    conn =
      conn
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> patch(
        "/api/sessions/#{session.id}/resume",
        Jason.encode!(%{data: %{type: "session", id: session.id, attributes: %{}}})
      )

    assert conn.status == 400
  end
```

(Make sure this test file has the SessionServer sweep in setup; add it if missing.)

- [ ] **Step 2: Run the three test files** — expected FAIL (`:interrupted` not in enum, `interrupt_session!`/`resume_session!` undefined, route 404).

- [ ] **Step 3: Create the validation** — `backend/lib/legend/core/agents/validations/resumable_status.ex`:

```elixir
defmodule Legend.Core.Agents.Validations.ResumableStatus do
  @moduledoc """
  Resume is only valid from a stopped-but-resumable state. Reads the RECORD's
  current status (changeset.data) — the action itself rewrites :status, so the
  changeset value is useless here.
  """

  use Ash.Resource.Validation

  @resumable [:interrupted, :exited]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if changeset.data.status in @resumable do
      :ok
    else
      {:error, field: :status, message: "can only resume an interrupted or exited session"}
    end
  end
end
```

- [ ] **Step 4: Extend the Session resource** — in `backend/lib/legend/core/agents/session.ex`:

Status enum gains `:interrupted`:

```elixir
      constraints: [one_of: [:starting, :running, :exited, :failed, :interrupted]]
```

Add two update actions after `:fail`:

```elixir
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
```

- [ ] **Step 5: Domain + route** — in `backend/lib/legend/core/agents.ex`:

Code interface additions inside the `resource` block:

```elixir
      define :interrupt_session, action: :interrupt
      define :resume_session, action: :resume
```

JSON:API member route inside the `base_route "/sessions"` block:

```elixir
        patch :resume, route: "/:id/resume"
```

**Verify this compiles and routes** (the route DSL form). If AshJsonApi rejects the `route:` option or the test 404s, FALL BACK to a plain controller instead — create `backend/lib/legend_web/controllers/session_resume_controller.ex`:

```elixir
defmodule LegendWeb.SessionResumeController do
  @moduledoc "Plain fallback for the resume member action (AshJsonApi route DSL workaround)."

  use LegendWeb, :controller

  alias Legend.Core.Agents

  def resume(conn, %{"id" => id}) do
    with {:ok, session} <- Agents.get_session(id),
         {:ok, resumed} <- Agents.resume_session(session) do
      json(conn, %{data: %{id: resumed.id, status: resumed.status}})
    else
      {:error, %Ash.Error.Invalid{}} ->
        conn |> put_status(400) |> json(%{error: "can only resume an interrupted or exited session"})

      {:error, _} ->
        conn |> put_status(404) |> json(%{error: "not found"})
    end
  end
end
```

with `patch "/sessions/:id/resume", SessionResumeController, :resume` in the FIRST router scope of `backend/lib/legend_web/router.ex` — and adapt the two API tests' request/assertions to the plain envelope. Report which variant landed.

- [ ] **Step 6: Janitor** — in `backend/lib/legend/core/agents/janitor.ex`, replace the `Enum.each` line and update the moduledoc:

```elixir
defmodule Legend.Core.Agents.Janitor do
  @moduledoc """
  Boot pass: sessions recorded :starting/:running belong to a previous backend
  run (their PTYs died with it) — mark them :interrupted so the UI offers
  Resume instead of showing phantom live sessions. Disabled in test
  (config :legend, run_session_janitor).
  """

  use Task, restart: :temporary

  require Ash.Query

  def start_link(_arg), do: Task.start_link(&run/0)

  def run do
    Legend.Core.Agents.Session
    |> Ash.Query.filter(status in [:starting, :running])
    |> Ash.read!()
    |> Enum.each(&Legend.Core.Agents.interrupt_session!/1)
  end
end
```

- [ ] **Step 7: Codegen check** — the status constraint is app-level (column is text), but run `mix ash.codegen session_interrupted_status` anyway; commit whatever snapshot/migration it generates (possibly nothing). Then `mix ash.setup`.

- [ ] **Step 8: Run the full suite**

Run: `cd backend && mix test`
Expected: **178 passed** (173 + 3 resume action + 2 API; the janitor test was replaced, not added). If the count differs because the API fallback variant changed assertions, report actuals.

- [ ] **Step 9: Commit**

```bash
cd backend && mix format && git add -A && git commit -m "feat: interrupted status + resume action + janitor interrupt"
```

---

### Task 4: Frontend — interrupted status, Resume/Restart button, sidebar color

**Files:**
- Modify: `frontend/src/lib/sessions.ts`
- Modify: `frontend/src/lib/components/SessionSidebar.svelte`
- Modify: `frontend/src/routes/sessions/[id]/+page.svelte`
- Check: `frontend/src/lib/components/Terminal.svelte` (read; verify 'interrupted' flows through `onstatus` without special-casing)

- [ ] **Step 1: `sessions.ts`** — three changes:

```typescript
export type SessionStatus = 'starting' | 'running' | 'exited' | 'failed' | 'interrupted';
```

Add `resumable` to the Harness interface:

```typescript
export interface Harness {
	id: string;
	name: string;
	description: string;
	kind: 'terminal' | 'acp' | 'native';
	resumable: boolean;
}
```

Add the resume call (JSON:API member route variant; if Task 3 landed the plain-controller fallback, use the same `fetch` with headers `{ 'Content-Type': 'application/json' }`, no body, and keep the error extraction on `body.error`):

```typescript
export async function resumeSession(id: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/sessions/${id}/resume`, {
		method: 'PATCH',
		headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
		body: JSON.stringify({ data: { type: 'session', id, attributes: {} } })
	});
	if (!res.ok) throw new Error(await errorMessage(res, 'resuming session failed'));
}
```

- [ ] **Step 2: Sidebar dot color** — in `SessionSidebar.svelte`'s `dotClass` record, add:

```typescript
		interrupted: 'bg-sky-500'
```

- [ ] **Step 3: Session page** — in `frontend/src/routes/sessions/[id]/+page.svelte`:

Script additions (keep all existing code):

```typescript
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { listHarnesses, resumeSession, type Harness } from '$lib/sessions';

	let harnesses = $state<Harness[]>([]);
	let resuming = $state(false);
	let resumeKey = $state(0);

	$effect(() => {
		sessionsStore.connect();
		void listHarnesses().then((h) => (harnesses = h));
	});

	const session = $derived(sessionsStore.sessions.find((s) => s.id === sessionId));
	const resumable = $derived(
		harnesses.find((h) => h.id === session?.harness_id)?.resumable ?? false
	);

	async function resume() {
		if (resuming) return;
		resuming = true;
		error = null;
		try {
			await resumeSession(sessionId);
			// Re-key the Terminal so it re-joins and repaints against the fresh server.
			resumeKey += 1;
			status = 'starting';
			exitCode = null;
		} catch (e) {
			error = e instanceof Error ? e.message : 'resume failed';
		} finally {
			resuming = false;
		}
	}
```

Update the `deleteSession` import line to include the new pieces (it becomes `import { deleteSession, listHarnesses, resumeSession, type Harness, type SessionStatus } from '$lib/sessions';`).

Status line: extend the existing `<span>` so interrupted explains itself:

```svelte
			{status ?? 'connecting…'}{#if status === 'exited' && exitCode !== null}&nbsp;(exit {exitCode}){/if}{#if status === 'interrupted'}&nbsp;— backend restarted{/if}
```

Button group: inside the existing `ml-auto` div, add a Resume button before the Stop/Delete pair:

```svelte
				{#if status === 'interrupted' || status === 'exited'}
					<Button size="sm" onclick={resume} disabled={resuming}>
						{resumable ? 'Resume' : 'Restart'}
					</Button>
				{/if}
```

(The existing `{#if status === 'running' || status === 'starting'}…Stop…{:else}…Delete…{/if}` stays — interrupted/exited sessions then show Resume + Delete side by side, per the spec.)

Terminal re-key — change the `{#key}` expression:

```svelte
			{#key `${sessionId}:${resumeKey}`}
				<Terminal bind:this={terminal} {sessionId} onstatus={handleStatus} />
			{/key}
```

- [ ] **Step 4: Terminal.svelte sanity check** — read it. It receives status via the channel join reply / status pushes and reports through `onstatus`; `'interrupted'` must flow like `'failed'` (no exhaustive match to extend beyond the `SessionStatus` union — svelte-check will catch any). If it special-cases statuses (e.g. an exit banner), make `'interrupted'` take the same non-running path as `'failed'`; report what you found.

- [ ] **Step 5: Verify**

Run: `cd frontend && bun run check && bun run build`
Expected: 0 errors; build succeeds.

- [ ] **Step 6: Commit**

```bash
git add frontend/src && git commit -m "feat: interrupted session state with Resume/Restart"
```

---

### Task 5: Full verification + restart-cycle smoke

- [ ] **Step 1:** `cd backend && mix precommit` — clean, **178 passed** (or Task 3's reported actual).

- [ ] **Step 2:** `cd frontend && bun run check && bun run build` — clean.

- [ ] **Step 3: Claude CLI flag verification** (machine has `claude` installed):

```bash
claude --help 2>/dev/null | grep -E "session-id|--resume"
```
Expected: both flags listed. Optionally prove composition end-to-end (cheap, non-interactive):

```bash
SID=$(uuidgen | tr 'A-Z' 'a-z')
claude --session-id "$SID" -p "Reply with exactly: alpha" --allowed-tools "" 2>&1 | tail -2
claude --resume "$SID" -p "What word did you just reply with?" 2>&1 | tail -2
```
Expected: second call shows the model remembers "alpha" — `--session-id`/`--resume` round-trip works. (Costs two tiny API calls; skip if offline and note it.)

- [ ] **Step 4: Headless restart-cycle smoke** (hermes harness with `cat` as stand-in; from repo root):

```bash
cd backend
PORT=4197 HARNESS_HERMES_CMD=cat mix phx.server &  # note the PID
sleep 6
curl -s -X POST http://localhost:4197/api/sessions -H 'Content-Type: application/vnd.api+json' -H 'Accept: application/vnd.api+json' \
  -d '{"data":{"type":"session","attributes":{"harness_id":"hermes","name":"resume-smoke","cwd":"/tmp"}}}'
# kill the server (simulated app restart), then boot again:
kill %1 && sleep 2
PORT=4197 HARNESS_HERMES_CMD=cat mix phx.server &
sleep 6
# status must be "interrupted":
curl -s http://localhost:4197/api/sessions -H 'Accept: application/vnd.api+json' | grep -o '"status":"[a-z]*"'
# resume it (id from the create response):
curl -s -X PATCH http://localhost:4197/api/sessions/<ID>/resume -H 'Content-Type: application/vnd.api+json' -H 'Accept: application/vnd.api+json' \
  -d '{"data":{"type":"session","id":"<ID>","attributes":{}}}'
# status must be "running"; then clean up:
curl -s -X DELETE http://localhost:4197/api/sessions/<ID> -H 'Accept: application/vnd.api+json'
kill %1
```
Expected: interrupted after restart → running after resume. Also send a message to the session between the two boots (POST `/api/messages` with `to_session_id`) and confirm after resume the TestRuntime-equivalent isn't observable here — instead verify via `GET /api/messages` that the message exists and (after resume) is marked read once the agent would drain it; the catch-up *nudge* itself is covered by the Task 2 unit test.

- [ ] **Step 5: Manual UI acceptance** (requires the user or a browser-capable check): create a Claude Code session, converse, restart the backend, confirm the sidebar shows the sky-blue interrupted dot, click **Resume**, confirm the conversation continues and a message sent during downtime nudges after resume.

- [ ] **Step 6: Update docs if reality diverged** — ARCHITECTURE.md and the spec already describe this feature; if any plan-time verification forced a deviation (route fallback, flag differences), update both in the same commit:

```bash
git add -A && git commit -m "fix: session-resume verification follow-ups"
```

---

## Self-review notes (spec → plan coverage)

- `:interrupted` status + janitor change → Task 3. `:resume` action (from `:interrupted` AND `:exited`, clears run fields, after_transaction lockstep, rejected while running) → Task 3. JSON:API member route + plain-controller fallback → Task 3. `mode`/`session_id` on Terminal contract, ClaudeCode `--session-id`/`--resume` + omitted instructions, Hermes degradation, `Definition.resumable` + controller exposure → Task 1. SessionServer mode threading + catch-up nudge (incl. empty-inbox negative) → Task 2. Frontend status/type/button/dot/re-key → Task 4. Plan-time verifications (route DSL, CLI flags incl. live round-trip) + restart-cycle smoke → Tasks 3/5. Cap-not-applied-to-resume needs no code (the cap lives in `Tools.start_agent` only) — by construction.
- Type consistency: `start_session/2` (Task 2) is what Task 3's `:resume` after_transaction calls; `build_opts/2` keys (`mode`, `session_id`) match Task 1's Terminal opts; `interrupt_session!`/`resume_session!` defined in Task 3 and used in its tests; frontend `resumable` matches Task 1's controller field.
- Task ordering note for executors: Tasks must run 1 → 2 → 3 (Task 3's action calls `start_session/2` introduced in Task 2; Task 2's tests assert `--session-id` args introduced in Task 1).
