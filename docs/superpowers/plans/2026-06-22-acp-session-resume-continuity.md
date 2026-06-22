# ACP session/resume continuity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an ACP agent advertises `sessionCapabilities.resume`, resume the conversation via `session/resume` (restoring the agent's full context) instead of degrading to a fresh `session/new`, with an honest "history not shown" notice in the rich pane.

**Architecture:** Extend the existing capability gate in `Acp.Connection.handle_response(:initialize)` into a three-rung ladder (`loadSession` → `session/load`; `sessionCapabilities.resume` → `session/resume`; neither → `session/new`). Add a `:session_resume` response handler mirroring `:session_load` that keeps `conversation_id` and emits a `notice` timeline item. `SessionServer` logs which rung fired; the Svelte rich surface renders the `notice` item.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 (backend, pure-function ACP codec + GenServer), ExUnit, SvelteKit 2 / Svelte 5 runes (frontend), Tailwind v4 + Legend design tokens.

**Spec:** [docs/superpowers/specs/2026-06-22-acp-session-resume-continuity-design.md](../specs/2026-06-22-acp-session-resume-continuity-design.md)

## Global Constraints

- Backend: run `cd backend && mix precommit` (compile `--warnings-as-errors` + format + test) before finishing backend work; it must pass.
- Frontend: run `cd frontend && bun run check` (svelte-check) before finishing frontend work; it must pass.
- `Acp.Connection` is a **pure** module — no IO, no `Logger` in the hot path beyond the existing dropped-frame warning. Side effects flow out as effect tuples the `SessionServer` applies.
- Capability detection is **runtime-authoritative**: only ever send a method the agent advertised at `initialize`.
- `session/resume` and `session/load` responses carry **no `sessionId`** — keep `state.launch[:conversation_id]`; never emit `{:conversation_id, …}` for these (it must stay stable across resumes).
- Frontend token discipline: Legend tokens only (`text-meta`, `text-ink-3`), no raw shadcn neutral classes / hex / ad-hoc `text-[Npx]`.
- Notice item is exact: `id: "resume-notice"`, `type: "notice"`, `text: "Resumed — earlier messages aren't shown here, but the agent has the full conversation."`
- Non-goal: do NOT parse Claude Code JSONL or otherwise repaint visible history.

---

### Task 1: Capability ladder + `session/resume` handler in `Acp.Connection`

**Files:**
- Modify: `backend/lib/legend/core/acp/connection.ex` (`handle_response(:initialize)` ~280-317; error-tag `cond` ~258-268; add `handle_response(:session_resume, …)` after ~336; add `resume_capable?/1` helper)
- Test: `backend/test/legend/core/acp/connection_test.exs` (rewrite the existing degrade test ~91-122; add three tests)

**Interfaces:**
- Consumes: `Connection.new/1` launch map `%{cwd, mcp_servers, mode, conversation_id}`; `Connection.handle_bytes/2` → `{state, items, replies, effects}`; private `request/4`, `config_items/1`, `error_message/1`.
- Produces: wire method `session/resume` with params `%{"sessionId", "cwd", "mcpServers"}` tagged `:session_resume`; effect `{:resume_strategy, :load | :resume | :new}` (emitted only on `:load` launches); `notice` item `%{"id" => "resume-notice", "type" => "notice", "text" => …}`; `resume_capable?/1 :: (map) -> boolean`.

- [ ] **Step 1: Rewrite the existing degrade test and add three new tests**

In `backend/test/legend/core/acp/connection_test.exs`, **replace** the test currently titled `"initialize in :load mode degrades to session/new when loadSession is unadvertised"` (the whole `test … do … end` block) with the following four tests:

```elixir
  test "initialize in :load mode degrades to session/new when neither load nor resume advertised" do
    # The final fallback rung: an adapter that advertises neither loadSession nor
    # sessionCapabilities.resume can only be opened fresh. Degrade to session/new
    # rather than send a method it would reject with -32601.
    {state, [init]} =
      Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :load, conversation_id: "sess-resumed"})

    init_id = Jason.decode!(init)["id"]

    {_state, _items, replies, effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "result" => %{"protocolVersion" => 1, "agentCapabilities" => %{}}
        }) <> "\n"
      )

    assert [%{"method" => "session/new", "params" => %{"cwd" => "/tmp"}}] = decode_lines(replies)
    assert {:load_capable, false} in effects
    assert {:resume_strategy, :new} in effects
  end

  test "initialize in :load mode sends session/resume when sessionCapabilities.resume advertised" do
    # claude-code-acp 0.13: no loadSession, but sessionCapabilities.resume. Resume
    # the conversation (continuity) instead of starting fresh, and surface the
    # empty-pane notice (resume does NOT replay history).
    {state, [init]} =
      Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :load, conversation_id: "sess-resumed"})

    init_id = Jason.decode!(init)["id"]

    # NOTE: bind the UPDATED state (not _state) — the id-2 resume request is now
    # pending on it, and the id-2 response below must dispatch against it.
    {state, items, replies, effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "result" => %{
            "protocolVersion" => 1,
            "agentCapabilities" => %{"sessionCapabilities" => %{"resume" => %{}}}
          }
        }) <> "\n"
      )

    assert [%{"method" => "session/resume", "params" => %{"sessionId" => "sess-resumed"}}] =
             decode_lines(replies)

    assert {:resume_strategy, :resume} in effects
    # initialize itself emits no timeline items.
    assert items == []

    # The resume handshake response (id 2) emits the notice item.
    {_state, items2, _replies2, ready_effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => 2, "result" => %{}}) <> "\n"
      )

    assert Enum.any?(items2, &(&1["id"] == "resume-notice" and &1["type"] == "notice"))
    assert {:session_ready} in ready_effects
  end

  test "initialize in :load mode prefers session/load when BOTH loadSession and resume advertised" do
    {state, [init]} =
      Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :load, conversation_id: "sess-resumed"})

    init_id = Jason.decode!(init)["id"]

    {_state, _items, replies, effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "result" => %{
            "protocolVersion" => 1,
            "agentCapabilities" => %{
              "loadSession" => true,
              "sessionCapabilities" => %{"resume" => %{}}
            }
          }
        }) <> "\n"
      )

    assert [%{"method" => "session/load"}] = decode_lines(replies)
    assert {:resume_strategy, :load} in effects
  end

  test "an error response to session/resume fails the handshake" do
    {state, [init]} =
      Connection.new(%{cwd: "/tmp", mcp_servers: [], mode: :load, conversation_id: "sess-resumed"})

    init_id = Jason.decode!(init)["id"]

    {state, _i, _r, _e} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => init_id,
          "result" => %{
            "protocolVersion" => 1,
            "agentCapabilities" => %{"sessionCapabilities" => %{"resume" => %{}}}
          }
        }) <> "\n"
      )

    {_state, [item], _replies, effects} =
      Connection.handle_bytes(
        state,
        Jason.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 2,
          "error" => %{"code" => -32_000, "message" => "resume boom"}
        }) <> "\n"
      )

    assert item["type"] == "error"
    assert Enum.any?(effects, &match?({:handshake_failed, _}, &1))
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd backend && mix test test/legend/core/acp/connection_test.exs --seed 0`
Expected: FAIL — the resume test still sees `session/new` (no ladder yet); the priority/error/`:resume_strategy` assertions fail.

- [ ] **Step 3: Replace `handle_response(:initialize)` with the capability ladder**

In `backend/lib/legend/core/acp/connection.ex`, replace the entire `handle_response(state, :initialize, result)` function (currently ~280-317) with:

```elixir
  defp handle_response(state, :initialize, result) do
    caps = result["agentCapabilities"] || %{}
    load? = caps["loadSession"] == true
    resume? = resume_capable?(caps)
    launch = state.launch
    mcp = launch[:mcp_servers] || []

    # Capability ladder (design: 2026-06-22-acp-session-resume-continuity). For a
    # :load launch (resume / desktop restart / transport switch) pick the richest
    # method the agent advertised at initialize (runtime-authoritative):
    #   * loadSession                  -> session/load    (replays history; best)
    #   * sessionCapabilities.resume   -> session/resume  (continuity, NO replay)
    #   * neither                      -> session/new     (fresh; continuity lost)
    # A :new launch always opens session/new. We never send a method the adapter
    # didn't advertise, since an unimplemented method returns a fatal -32601 that
    # fails the whole handshake.
    {state, frame, strategy} =
      cond do
        launch[:mode] == :load and load? ->
          {state, frame} =
            request(
              state,
              "session/load",
              %{
                "sessionId" => launch[:conversation_id],
                "cwd" => launch[:cwd],
                "mcpServers" => mcp
              },
              :session_load
            )

          {state, frame, :load}

        launch[:mode] == :load and resume? ->
          {state, frame} =
            request(
              state,
              "session/resume",
              %{
                "sessionId" => launch[:conversation_id],
                "cwd" => launch[:cwd],
                "mcpServers" => mcp
              },
              :session_resume
            )

          {state, frame, :resume}

        true ->
          {state, frame} =
            request(
              state,
              "session/new",
              %{"cwd" => launch[:cwd], "mcpServers" => mcp},
              :session_new
            )

          {state, frame, :new}
      end

    # {:resume_strategy} is diagnostic and only meaningful for a :load launch — do
    # not emit it on fresh :new launches (it would be noise on every new session).
    effects =
      if launch[:mode] == :load,
        do: [{:load_capable, load?}, {:resume_strategy, strategy}],
        else: [{:load_capable, load?}]

    {state, [], [frame], effects}
  end

  # Presence of the (possibly empty) sessionCapabilities.resume object means the
  # agent supports ACP session/resume (newer adapters, e.g. claude-code-acp 0.13).
  defp resume_capable?(caps), do: is_map(get_in(caps, ["sessionCapabilities", "resume"]))
```

- [ ] **Step 4: Add the `:session_resume` response handler**

In the same file, immediately after `handle_response(state, :session_load, result)` (ends ~336), add:

```elixir
  defp handle_response(state, :session_resume, result) do
    # session/resume restores the agent's conversation context but, by contract,
    # does NOT replay history (no session/update notifications), so the timeline
    # starts empty. Like session/load the response carries no sessionId — keep the
    # launch conversation_id. Surface a notice so the empty pane is legible, and
    # pass through any mode/model config the resume result carries.
    notice = %{
      "id" => "resume-notice",
      "type" => "notice",
      "text" =>
        "Resumed — earlier messages aren't shown here, but the agent has the full conversation."
    }

    {%{state | session_id: state.launch[:conversation_id]}, [notice | config_items(result)], [],
     [{:session_ready}]}
  end
```

- [ ] **Step 5: Add `:session_resume` to the fatal-handshake error tags**

In the error `dispatch/2` clause, change the handshake `cond` branch (~263) from:

```elixir
        tag in [:initialize, :session_new, :session_load] ->
```

to:

```elixir
        tag in [:initialize, :session_new, :session_load, :session_resume] ->
```

- [ ] **Step 6: Run the connection tests to verify they pass**

Run: `cd backend && mix test test/legend/core/acp/connection_test.exs --seed 0`
Expected: PASS (all, including the four from Step 1 and the pre-existing `session/load`/degrade/I4/I9 tests).

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend/core/acp/connection.ex backend/test/legend/core/acp/connection_test.exs
git commit -m "feat(acp): resume via session/resume when the agent advertises it

Capability ladder in handle_response(:initialize): loadSession -> session/load,
sessionCapabilities.resume -> session/resume (continuity, no replay), else
session/new. New :session_resume handler keeps conversation_id and emits a
resume notice; resume errors fail the handshake. Emits {:resume_strategy, _}.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `SessionServer` logs the resume strategy + integration test

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex` (add `apply_effect({:resume_strategy, …})` near ~795; add `resume_method/1` helper)
- Test: `backend/test/legend/core/agents/session_server_acp_test.exs` (rewrite the test added in the prior commit, `"resume degrades to session/new (no failure) when the adapter lacks loadSession"`, ~492)

**Interfaces:**
- Consumes: effect `{:resume_strategy, :load | :resume | :new}` from `Acp.Connection`; existing `apply_effect/2` reduce in `handle_info({:runtime_output, …})`.
- Produces: one `Logger.info` line per `:load` launch. No new outward API.

- [ ] **Step 1: Rewrite the integration test to assert `session/resume`**

In `backend/test/legend/core/agents/session_server_acp_test.exs`, **replace** the test titled `"resume degrades to session/new (no failure) when the adapter lacks loadSession"` (whole block) with:

```elixir
  test "resume sends session/resume and stays healthy when the adapter advertises resume" do
    # claude-code-acp 0.13 advertises sessionCapabilities.resume (no loadSession).
    # A :load relaunch must send session/resume — restoring the agent's context —
    # not session/new (which abandons the conversation) and not session/load
    # (which the adapter rejects with -32601). The session stays healthy, a resume
    # notice is surfaced, and the conversation id is unchanged.
    {:ok, s} =
      Agents.start_session(%{harness_id: "claude_code", runtime_id: "test", transport: :acp})

    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{s.id}")

    drive_to_live(s.id)
    assert eventually(fn -> Agents.get_session!(s.id).conversation_id == "sess-xyz" end)

    Agents.finish_session!(Agents.get_session!(s.id), %{exit_code: 0})
    drain_test_runtime_writes()
    {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))

    assert_receive {:test_runtime, :write, init2}, 1_000
    init2_id = Jason.decode!(init2)["id"]

    send_output(s.id, %{
      "jsonrpc" => "2.0",
      "id" => init2_id,
      "result" => %{
        "protocolVersion" => 1,
        "agentCapabilities" => %{"sessionCapabilities" => %{"resume" => %{}}}
      }
    })

    assert_receive {:test_runtime, :write, req}, 1_000
    decoded = Jason.decode!(req)
    assert decoded["method"] == "session/resume"
    assert decoded["params"]["sessionId"] == "sess-xyz"

    # The resume response carries no sessionId; reply to drive the notice item.
    resume_id = decoded["id"]
    send_output(s.id, %{"jsonrpc" => "2.0", "id" => resume_id, "result" => %{}})

    assert_receive {:session_event, _seq, %{"id" => "resume-notice", "type" => "notice"}}, 1_000
    refute_receive {:session_status, :failed}, 200
    assert Agents.get_session!(s.id).conversation_id == "sess-xyz"
  end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs --seed 0`
Expected: FAIL — the server currently emits `session/new` for this input (Task 1 fixed the codec, but this test now asserts `session/resume` and the notice item, which is the new behavior; it should pass once Task 1 is in place — if Task 1 is already committed this fails only on the `Logger`/handshake plumbing being absent... it should PASS on the assertions already). If it PASSES here, that is acceptable — proceed to Step 3 to add the diagnostic log.

> Note: with Task 1 committed, the codec already produces `session/resume` + the notice, so this test may pass immediately. The remaining change (Step 3) adds observability and is verified by the full suite, not a dedicated assertion.

- [ ] **Step 3: Add the `:resume_strategy` log effect and helper**

In `backend/lib/legend/core/agents/session_server.ex`, replace the line (~795):

```elixir
  defp apply_effect({:load_capable, _}, state), do: state
```

with:

```elixir
  # Diagnostic: which post-initialize path a :load launch (resume / restart /
  # transport switch) took. Emitted only for :load launches, so it is not noisy
  # on fresh sessions. Makes silent continuity loss observable in the logs.
  defp apply_effect({:resume_strategy, strategy}, state) do
    Logger.info("[acp #{state.session.id}] resume → #{resume_method(strategy)}")
    state
  end

  defp apply_effect({:load_capable, _}, state), do: state

  defp resume_method(:load), do: "session/load (replays history)"
  defp resume_method(:resume), do: "session/resume (continuity, no replay)"
  defp resume_method(:new), do: "session/new (degraded — continuity lost)"
```

(`Logger` is already required at the top of the module.)

- [ ] **Step 4: Run the ACP server tests**

Run: `cd backend && mix test test/legend/core/agents/session_server_acp_test.exs --seed 0`
Expected: PASS (all).

- [ ] **Step 5: Run the full backend precommit**

Run: `cd backend && mix precommit`
Expected: PASS — compile `--warnings-as-errors`, format clean, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/core/agents/session_server.ex backend/test/legend/core/agents/session_server_acp_test.exs
git commit -m "feat(acp): log resume strategy; assert session/resume end-to-end

SessionServer logs which post-initialize path a :load launch took
(load/resume/new). Integration test: a resume-capable adapter drives
session/resume, surfaces the resume notice, stays healthy, conversation_id
unchanged.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Render the `notice` item in the rich surface

**Files:**
- Modify: `frontend/src/lib/components/sessions/AcpConversation.svelte` (item `{#each}` loop, after the `nudge` branch ~92-97, before `{/if}` ~98)

**Interfaces:**
- Consumes: timeline item `{id: "resume-notice", type: "notice", text: string}` from `acp.items`; existing `asText/1` helper in the component.
- Produces: a centered muted line in the stream. No new exports.

- [ ] **Step 1: Add the `notice` branch**

In `frontend/src/lib/components/sessions/AcpConversation.svelte`, inside the `{#each acp.items …}` block, immediately after the `{:else if item.type === 'nudge'}` branch's closing `</div>` and before the `{/if}`, add:

```svelte
			{:else if item.type === 'notice'}
				<!-- resume marker: the agent has full context; prior messages aren't replayed here -->
				<div class="self-center text-meta text-ink-3">{asText(item.text)}</div>
```

- [ ] **Step 2: Type-check the frontend**

Run: `cd frontend && bun run check`
Expected: PASS (0 errors).

- [ ] **Step 3: Commit**

```bash
git add frontend/src/lib/components/sessions/AcpConversation.svelte
git commit -m "feat(acp): render the resume notice item in the rich pane

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Manual verification (post-implementation, live)

Not automated — confirm at live bring-up (Test runtime can't exercise the real adapter):

1. With a Claude Code **terminal** session that has some conversation, click **rich**. Expect: the pane shows the resume notice, the composer is usable, and the agent answers the first new prompt with awareness of the prior terminal conversation. Backend log shows `resume → session/resume (continuity, no replay)`.
2. **Desktop restart** with a live ACP session, then **Resume** the interrupted session. Expect: same as above — empty pane + notice, full context on the next turn.
3. Confirm `conversation_id` is unchanged across several resume cycles (`session/resume` must not mint a new id).

## Self-review notes

- **Spec coverage:** ladder (Task 1), `:session_resume` handler + notice (Task 1), detection helper (Task 1), `{:resume_strategy}` + log (Tasks 1–2), frontend notice (Task 3), restart/resume path (covered by existing `start_transport` `:load` derivation — verified by Task 2 integration test + manual step 2). Non-goal (no JSONL repaint) respected.
- **Pre-committed tests changed:** the two tests added in the earlier `fix(acp)` commit that fed `sessionCapabilities.resume` and asserted `session/new` are superseded here (resume-capable → `session/resume`); the neither-capability degrade is retained with empty `agentCapabilities`.
- **Type consistency:** `:resume_strategy` atom values `:load | :resume | :new` match between `connection.ex` (emit) and `session_server.ex` `resume_method/1` (consume); notice keys (`"id"/"type"/"text"`) match between handler and Svelte branch.
