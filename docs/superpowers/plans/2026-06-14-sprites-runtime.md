# Sprites Terminal Runtime + Provisioning (Spec 2a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second runtime that runs the agent in a sprites.dev cloud sandbox — provisioned (harness installs its CLI), interactive PTY over the sprites WSS exec, reattach-to-live on resume, destroyed on session delete — selectable from the new-session dialog.

**Architecture:** The `Legend.Core.Runtime` behaviour grows four *optional* callbacks (`capabilities/0`, `exec/2`, `attach/2`, `teardown/1`); LocalPty exports none and is untouched. `Legend.Runtimes.Sprites` implements them against `Legend.Sprites.Client` (Spec 1) plus a new interactive WSS-exec client. `SessionServer` becomes capability-aware: it provisions (harness `provision/0`), shows a `:provisioning` status, injects library/MCP env only for `:path` runtimes (sprites' `:api` gets none in 2a — that's Spec 2b), persists a `runtime_ref` for reattach, and `attach`es on resume. This spec is **tunnel-free** (control plane only).

**Tech Stack:** Elixir/Phoenix/Ash, `Mint.WebSocket` (interactive sprites exec), the Spec-1 `Legend.Sprites.Client`. `SPRITES_TOKEN` is in `backend/.env` (live tests runnable). No Rust/musl needed for 2a.

**Spec:** `docs/superpowers/specs/2026-06-14-sprites-runtime-design.md`. Spec 2b (library/messaging over the tunnel) is separate and out of scope.

---

## File structure

**Backend — new:**
- `backend/lib/legend/runtimes/sprites.ex` — `Legend.Runtimes.Sprites`: the runtime adapter.
- `backend/lib/legend/sprites/exec.ex` — `Legend.Sprites.Exec`: interactive PTY over the sprites WSS exec (parallel to Spec-1's `proxy.ex`).
- `backend/lib/legend_web/controllers/runtime_controller.ex` — `GET /api/runtimes`.

**Backend — modified:**
- `backend/lib/legend/core/runtime.ex` — optional callbacks + `capabilities/1` resolver.
- `backend/lib/legend/core/harness.ex` — optional `provision/0` + `provision_for/1` resolver.
- `backend/lib/legend/harnesses/claude_code.ex` — `provision/0`.
- `backend/lib/legend/core/agents/session.ex` — `runtime_ref` attribute, `:provisioning` status, `mark_provisioning` + `runtime_ref` on `mark_running`.
- `backend/lib/legend/core/agents.ex` — `mark_session_provisioning` code interface.
- `backend/lib/legend/core/agents/session_server.ex` — capability-aware init/provisioning/env, reattach, runtime_ref persistence.
- `backend/lib/legend/core/agents/janitor.ex` — include `:provisioning` in the boot interrupt filter.
- `backend/lib/legend/sprites/client.ex` — add exec-session list/attach helpers (if the live probe shows they're needed).
- `backend/config/config.exs` — register `Legend.Runtimes.Sprites` in `:runtimes`.
- `backend/test/support/runtimes/test.ex` — extend with `capabilities/0`, `exec/2`, `attach/2`, `teardown/1` (observable).

**Frontend — modified:**
- `frontend/src/lib/sessions.ts` — `listRuntimes()`, `runtime_id` in `CreateSessionParams`, `'provisioning'` in `SessionStatus`.
- `frontend/src/lib/components/NewSessionDialog.svelte` — runtime `Select`; send `runtime_id`; cwd helper.
- `frontend/src/lib/components/SessionSidebar.svelte` — `provisioning` status dot color.

---

### Task 1: Runtime contract extensions + capability resolver

**Files:**
- Modify: `backend/lib/legend/core/runtime.ex`
- Test: `backend/test/legend/core/runtime_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.RuntimeTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Runtime

  test "capabilities/1 returns defaults for a runtime that doesn't export capabilities/0" do
    assert Runtime.capabilities(Legend.Runtimes.LocalPty) ==
             %{provisions?: false, library: :path, tunnel: nil}
  end

  defmodule CapRuntime do
    @behaviour Legend.Core.Runtime
    def id, do: "cap"
    def start(_s, _o), do: {:ok, %{}}
    def write(_h, _d), do: :ok
    def resize(_h, _c, _r), do: :ok
    def stop(_h), do: :ok
    def capabilities, do: %{provisions?: true, library: :api, tunnel: "sprite_proxy"}
  end

  test "capabilities/1 merges a runtime's declared capabilities over the defaults" do
    assert Runtime.capabilities(CapRuntime) ==
             %{provisions?: true, library: :api, tunnel: "sprite_proxy"}
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/runtime_test.exs`
Expected: FAIL — `Runtime.capabilities/1` undefined.

- [ ] **Step 3: Add the optional callbacks + resolver to `backend/lib/legend/core/runtime.ex`**

Add to the module (keep the existing `@callback`s for id/start/write/resize/stop):

```elixir
  @type reattach_ref :: term()

  @callback capabilities() :: %{
              optional(:provisions?) => boolean(),
              optional(:library) => :path | :api,
              optional(:tunnel) => String.t() | nil
            }
  @callback exec(handle(), CommandSpec.t()) ::
              {:ok, %{stdout: binary(), status: integer()}} | {:error, String.t()}
  @callback attach(reattach_ref(), start_opts()) :: {:ok, handle()} | {:error, String.t()}
  @callback teardown(handle() | reattach_ref()) :: :ok
  @optional_callbacks capabilities: 0, exec: 2, attach: 2, teardown: 1

  @default_capabilities %{provisions?: false, library: :path, tunnel: nil}

  @doc "A runtime's capabilities, with defaults for runtimes that don't declare them."
  @spec capabilities(module()) :: %{provisions?: boolean(), library: :path | :api, tunnel: String.t() | nil}
  def capabilities(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :capabilities, 0) do
      Map.merge(@default_capabilities, module.capabilities())
    else
      @default_capabilities
    end
  end
```

- [ ] **Step 4: Run, verify it passes**

Run: `cd backend && mix test test/legend/core/runtime_test.exs` → PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/runtime.ex backend/test/legend/core/runtime_test.exs
git commit -m "feat(runtime): optional capabilities/exec/attach/teardown + capability resolver"
```

---

### Task 2: Harness `provision/0` contract + Claude Code installer

**Files:**
- Modify: `backend/lib/legend/core/harness.ex`, `backend/lib/legend/harnesses/claude_code.ex`
- Test: `backend/test/legend/core/harness_provision_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.HarnessProvisionTest do
  use ExUnit.Case, async: true
  alias Legend.Core.Harness
  alias Legend.Core.Runtime.CommandSpec

  test "provision_for/1 returns nil for a harness without provision/0" do
    defmodule Bare do
      @behaviour Legend.Core.Harness
      def definition, do: %Legend.Core.Harness.Definition{id: "bare", name: "Bare", kind: :terminal}
    end

    assert Harness.provision_for(Bare) == nil
  end

  test "Claude Code declares a detect + install provision spec" do
    assert %{detect: %CommandSpec{} = detect, install: %CommandSpec{}} =
             Harness.provision_for(Legend.Harnesses.ClaudeCode)

    assert detect.cmd == "claude"
    assert "--version" in detect.args
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/harness_provision_test.exs` → FAIL.

- [ ] **Step 3: Add the optional callback + resolver to `backend/lib/legend/core/harness.ex`**

Add (alongside the existing `setup/0`/`apply_setup/0` optional callbacks):

```elixir
  @callback provision() :: %{detect: Legend.Core.Runtime.CommandSpec.t(), install: Legend.Core.Runtime.CommandSpec.t()} | nil
  @optional_callbacks setup: 0, apply_setup: 0, provision: 0
```

(Replace the existing `@optional_callbacks setup: 0, apply_setup: 0` line with the one above — keep `setup`/`apply_setup` optional too.)

Add the resolver function:

```elixir
  @doc "The harness's provision spec, or nil if it has no installer."
  @spec provision_for(module()) :: %{detect: Legend.Core.Runtime.CommandSpec.t(), install: Legend.Core.Runtime.CommandSpec.t()} | nil
  def provision_for(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :provision, 0) do
      module.provision()
    else
      nil
    end
  end
```

- [ ] **Step 4: Add `provision/0` to `backend/lib/legend/harnesses/claude_code.ex`**

Add the behaviour impl (the install command is the official Claude Code installer; `sh -lc` so the install script runs in a shell):

```elixir
  @impl Legend.Core.Harness
  def provision do
    %{
      detect: %CommandSpec{cmd: "claude", args: ["--version"], io: :pipes},
      install: %CommandSpec{cmd: "sh", args: ["-lc", "curl -fsSL https://claude.ai/install.sh | sh"], io: :pipes}
    }
  end
```

(Add `@impl Legend.Core.Harness` above it; `CommandSpec` is already aliased in this module. **Verify the install URL/command** against Claude Code's current install docs during Task 10's live run — pin it then if it differs.)

- [ ] **Step 5: Run, verify it passes**

Run: `cd backend && mix test test/legend/core/harness_provision_test.exs` → PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/core/harness.ex backend/lib/legend/harnesses/claude_code.ex backend/test/legend/core/harness_provision_test.exs
git commit -m "feat(harness): optional provision/0 (detect+install) + Claude Code installer"
```

---

### Task 3: Session `runtime_ref` + `:provisioning` status + actions + migration

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex`, `backend/lib/legend/core/agents.ex`, `backend/lib/legend/core/agents/janitor.ex`
- Test: `backend/test/legend/core/agents/session_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.Agents.SessionTest do
  use Legend.DataCase, async: true
  alias Legend.Core.Agents

  test "a session can be marked provisioning then running with a runtime_ref" do
    {:ok, s} = Ash.create(Agents.Session, %{harness_id: "claude_code", runtime_id: "test"}, action: :start_only_record())
    s = Agents.mark_session_provisioning!(s)
    assert s.status == :provisioning
    s = Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => "abc", "exec_id" => "e1"}})
    assert s.status == :running
    assert s.runtime_ref == %{"sprite" => "abc", "exec_id" => "e1"}
  end
end
```

> NOTE: `:start` runs the full SessionServer lifecycle. For a pure-record test, add a tiny `:create_record` action OR build the record with `Ash.Seed.seed!/2`. Use whichever the codebase already favors (check `test/support`); if neither, `Ash.Seed.seed!(Agents.Session, %{harness_id: "claude_code", runtime_id: "test", status: :starting})` is simplest. Replace `action: :start_only_record()` accordingly.

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs` → FAIL (`:provisioning` not allowed / `mark_session_provisioning` undefined / `runtime_ref` missing).

- [ ] **Step 3: Edit `backend/lib/legend/core/agents/session.ex`**

(a) Add `:provisioning` to the status constraint:
```elixir
    attribute :status, :atom,
      allow_nil?: false,
      default: :starting,
      public?: true,
      constraints: [one_of: [:starting, :provisioning, :running, :exited, :failed, :interrupted]]
```

(b) Add the attribute (a map keeps the ref opaque/runtime-specific):
```elixir
    # Opaque, runtime-specific handle for reattaching after a backend restart
    # (e.g. %{"sprite" => name, "exec_id" => id}). nil for runtimes that don't reattach.
    attribute :runtime_ref, :map, public?: true
```

(c) Add a `mark_provisioning` action and accept `runtime_ref` on `mark_running`:
```elixir
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
```
(Replace the existing `mark_running` block with the one above — it now accepts `runtime_ref`.)

- [ ] **Step 4: Add the code interface in `backend/lib/legend/core/agents.ex`**

In the `resource Legend.Core.Agents.Session do ... end` block, add:
```elixir
      define :mark_session_provisioning, action: :mark_provisioning
```

- [ ] **Step 5: Add `:provisioning` to the boot janitor filter** in `backend/lib/legend/core/agents/janitor.ex`:
```elixir
    |> Ash.Query.filter(status in [:starting, :provisioning, :running])
```

- [ ] **Step 6: Generate + run the migration**

Run:
```bash
cd backend && mix ash.codegen add_runtime_ref_and_provisioning && mix ecto.migrate
```
Expected: a new migration under `priv/repo/migrations/` adding the `runtime_ref` column; migrate succeeds. (Ash snapshots the resource change; the `:provisioning` status is an app-level atom constraint, not a DB enum, so the column addition is just `runtime_ref`.)

- [ ] **Step 7: Run the test, verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_test.exs` → PASS.

- [ ] **Step 8: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/lib/legend/core/agents.ex backend/lib/legend/core/agents/janitor.ex backend/priv/repo/migrations backend/priv/resource_snapshots backend/test/legend/core/agents/session_test.exs
git commit -m "feat(session): runtime_ref + :provisioning status + mark_provisioning + migration"
```

---

### Task 4: Extend the test runtime with the new callbacks

**Files:**
- Modify: `backend/test/support/runtimes/test.ex`

- [ ] **Step 1: Add the optional callbacks (observable via the existing `notify/1`)**

Append to `Legend.Runtimes.Test` (it already implements id/start/write/resize/stop and a `notify/1` that sends to the listener pid):

```elixir
  @impl true
  def capabilities, do: Application.get_env(:legend, :test_runtime_capabilities, %{provisions?: false, library: :path, tunnel: nil})

  @impl true
  def exec(_handle, %Legend.Core.Runtime.CommandSpec{cmd: "claude", args: ["--version"]}) do
    notify({:test_runtime, :exec, :detect})
    # default: harness "not installed" so SessionServer runs install; override per test below
    Application.get_env(:legend, :test_runtime_detect, {:ok, %{stdout: "", status: 1}})
  end

  def exec(_handle, spec) do
    notify({:test_runtime, :exec, spec})
    {:ok, %{stdout: "", status: 0}}
  end

  @impl true
  def attach(ref, opts) do
    notify({:test_runtime, :attach, ref})
    {:ok, %{owner: Map.fetch!(opts, :owner), ref: ref}}
  end

  @impl true
  def teardown(ref) do
    notify({:test_runtime, :teardown, ref})
    :ok
  end
```

Add a helper to set capabilities per test:
```elixir
  def set_capabilities(caps), do: Application.put_env(:legend, :test_runtime_capabilities, caps)
  def set_detect(result), do: Application.put_env(:legend, :test_runtime_detect, result)
```

- [ ] **Step 2: Compile the test env**

Run: `cd backend && MIX_ENV=test mix compile` → clean.

- [ ] **Step 3: Commit**

```bash
git add backend/test/support/runtimes/test.ex
git commit -m "test: extend Test runtime with capabilities/exec/attach/teardown"
```

---

### Task 5: SessionServer — provisioning + capability-aware env + runtime_ref persistence

This is the core change. Read `backend/lib/legend/core/agents/session_server.ex` first — you are editing `init/1`, `build_opts/2`, and `platform_env/1`.

**Files:**
- Modify: `backend/lib/legend/core/agents/session_server.ex`
- Test: `backend/test/legend/core/agents/session_provisioning_test.exs`

- [ ] **Step 1: Write the failing test** (uses the extended Test runtime + listener)

```elixir
defmodule Legend.Core.Agents.SessionProvisioningTest do
  use Legend.DataCase
  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()
    on_exit(fn ->
      Application.delete_env(:legend, :test_runtime_capabilities)
      Application.delete_env(:legend, :test_runtime_detect)
    end)
    :ok
  end

  test "a provisioning runtime runs detect, installs when missing, and reaches running" do
    TestRuntime.set_capabilities(%{provisions?: true, library: :api, tunnel: "sprite_proxy"})
    TestRuntime.set_detect({:ok, %{stdout: "", status: 1}})  # not installed

    {:ok, session} = Agents.start_session(%{name: "p", harness_id: "claude_code", runtime_id: "test"})

    assert_receive {:test_runtime, :exec, :detect}, 1000
    # install is an exec of a non-detect spec
    assert_receive {:test_runtime, :exec, %Legend.Core.Runtime.CommandSpec{}}, 1000
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    session = Agents.get_session!(session.id)
    assert session.status == :running
  end

  test "an :api runtime gets NO library/mcp env injected in 2a" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "sprite_proxy"})
    {:ok, _} = Agents.start_session(%{name: "a", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_runtime, :start, spec, _opts}, 1000
    refute Map.has_key?(spec.env, "LEGEND_LIBRARY")
    refute Map.has_key?(spec.env, "LEGEND_MCP_URL")
  end

  test "a :path runtime still gets library env (unchanged behavior)" do
    TestRuntime.set_capabilities(%{provisions?: false, library: :path, tunnel: nil})
    {:ok, _} = Agents.start_session(%{name: "l", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_runtime, :start, spec, _opts}, 1000
    assert Map.has_key?(spec.env, "LEGEND_LIBRARY")
  end
end
```

> `Agents.start_session/1` here is the Ash `:start` create (record + SessionServer). If the existing test suite starts sessions differently (e.g. via `Ash.create`), match that pattern — see `test/legend/core/agents/session_server_test.exs`.

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_provisioning_test.exs` → FAIL (no provisioning; `:api` still injects env).

- [ ] **Step 3: Edit `SessionServer.init/1`** — add provisioning + capability-aware env. Replace the `with` head that resolves harness/runtime/spec/handle with this expanded flow:

```elixir
    with {:ok, harness} <- fetch_registered(Legend.Core.Harness.Registry, session.harness_id),
         {:ok, runtime} <- fetch_registered(Legend.Core.Runtime.Registry, session.runtime_id),
         caps = Legend.Core.Runtime.capabilities(runtime),
         :ok <- maybe_provision(session, harness, runtime, caps),
         spec = harness.build_command(build_opts(session, mode, caps)),
         spec = %{spec | env: Map.merge(spec.env, platform_env(session, caps))},
         {:ok, handle, ref} <- start_or_attach(runtime, spec, session, mode) do
      try do
        session = Agents.mark_session_running!(session, %{runtime_ref: ref})
        # ... (rest of the existing success body unchanged: broadcast :running, Notifications,
        #      subscribe inbox, catch-up messages, build state map — but ALSO store `runtime: runtime`,
        #      `handle: handle` as today)
```

Add these private helpers (complete):

```elixir
  # Provisioning runs BEFORE the PTY exists, so exec targets the sprite via a
  # lightweight handle carrying the session id. Sprites.exec/2 ensures the sprite
  # (idempotent create keyed by session id) so exec works pre-start; the Test
  # runtime ignores the handle. Only reached when the runtime declares provisions?.
  defp maybe_provision(session, harness, runtime, %{provisions?: true}) do
    case Legend.Core.Harness.provision_for(harness) do
      nil ->
        {:error, "harness #{harness.definition().id} has no installer for this runtime"}

      %{detect: detect, install: install} ->
        handle = %{session_id: session.id}

        case runtime.exec(handle, detect) do
          {:ok, %{status: 0}} ->
            :ok

          {:ok, _missing} ->
            Agents.mark_session_provisioning!(session)
            broadcast(session.id, {:session_status, :provisioning})
            Notifications.sessions_changed()

            case runtime.exec(handle, install) do
              {:ok, %{status: 0}} -> :ok
              {:ok, %{stdout: out, status: s}} -> {:error, "install failed (#{s}): #{out}"}
              {:error, reason} -> {:error, "install failed: #{reason}"}
            end

          {:error, reason} ->
            {:error, "provision detect failed: #{reason}"}
        end
    end
  end

  defp maybe_provision(_session, _harness, _runtime, _caps), do: :ok
```

Add `start_or_attach/4`:
```elixir
  defp start_or_attach(runtime, spec, session, :resume) do
    caps = Legend.Core.Runtime.capabilities(runtime)
    cond do
      caps != nil and function_exported?(runtime, :attach, 2) and not is_nil(session.runtime_ref) ->
        case runtime.attach(session.runtime_ref, %{owner: self(), cwd: session.cwd}) do
          {:ok, handle} -> {:ok, handle, session.runtime_ref}
          {:error, _} -> do_start(runtime, spec, session)   # fall back to fresh
        end
      true ->
        do_start(runtime, spec, session)
    end
  end

  defp start_or_attach(runtime, spec, session, _fresh), do: do_start(runtime, spec, session)

  defp do_start(runtime, spec, session) do
    case runtime.start(spec, %{owner: self(), cwd: session.cwd}) do
      {:ok, handle} -> {:ok, handle, runtime_ref_from(handle)}
      {:error, _} = err -> err
    end
  end

  # The handle a runtime returns may carry its reattach ref (sprites: %{sprite, exec_id});
  # LocalPty/Test return handles without one -> nil ref persisted.
  defp runtime_ref_from(%{sprite: s, exec_id: e}), do: %{"sprite" => s, "exec_id" => e}
  defp runtime_ref_from(_), do: nil
```

Make `build_opts/2` → `build_opts/3` and `platform_env/1` → `platform_env/2`, capability-gated:
```elixir
  # :api runtimes (sprites) get NO library/messaging wiring in 2a — Spec 2b adds the tunnel.
  defp build_opts(session, mode, %{library: :api}), do: %{mode: mode, session_id: session.id}

  defp build_opts(session, mode, %{library: :path}) do
    # ... the existing build_opts body (library/messaging/mcp), unchanged ...
  end

  defp platform_env(_session, %{library: :api}), do: %{}

  defp platform_env(session, %{library: :path}) do
    # ... the existing platform_env body (LEGEND_LIBRARY, LEGEND_SESSION_ID, MCP) ...
  end
```

- [ ] **Step 4: Run, verify the three tests pass**

Run: `cd backend && mix test test/legend/core/agents/session_provisioning_test.exs` → PASS (3 tests). Also run the existing `mix test test/legend/core/agents/` to confirm no regressions in the LocalPty/Test paths.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/agents/session_server.ex backend/test/legend/core/agents/session_provisioning_test.exs
git commit -m "feat(session): capability-aware provisioning + env + runtime_ref/attach wiring"
```

---

### Task 6: Reattach selection on resume (unit)

The reattach logic landed in Task 5 (`start_or_attach`). This task adds a focused regression test.

**Files:**
- Test: `backend/test/legend/core/agents/session_reattach_test.exs`

- [ ] **Step 1: Write the test**

```elixir
defmodule Legend.Core.Agents.SessionReattachTest do
  use Legend.DataCase
  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "sprite_proxy"})
    on_exit(fn -> Application.delete_env(:legend, :test_runtime_capabilities) end)
    :ok
  end

  test "resume with a runtime_ref calls attach; fresh start does not" do
    {:ok, s} = Agents.start_session(%{name: "r", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000

    # simulate a persisted runtime_ref + an interrupted session, then resume
    s = Agents.get_session!(s.id)
    Agents.mark_session_running!(s, %{runtime_ref: %{"sprite" => s.id, "exec_id" => "e1"}})
    Legend.Core.Agents.SessionServer.ensure_stopped(s.id)
    {:ok, _} = Agents.interrupt_session(Agents.get_session!(s.id))

    {:ok, _} = Agents.resume_session(Agents.get_session!(s.id))
    assert_receive {:test_runtime, :attach, %{"sprite" => _, "exec_id" => "e1"}}, 1000
  end
end
```

- [ ] **Step 2: Run, verify it passes** (logic exists from Task 5)

Run: `cd backend && mix test test/legend/core/agents/session_reattach_test.exs` → PASS. If it fails, fix `start_or_attach/4` in Task 5's file until green.

- [ ] **Step 3: Commit**

```bash
git add backend/test/legend/core/agents/session_reattach_test.exs
git commit -m "test(session): resume reattaches via attach/2 when a runtime_ref exists"
```

---

### Task 7: Teardown the sprite on session delete

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex` (the `destroy` action)
- Test: `backend/test/legend/core/agents/session_teardown_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.Agents.SessionTeardownTest do
  use Legend.DataCase
  alias Legend.Core.Agents
  alias Legend.Runtimes.Test, as: TestRuntime

  setup do
    TestRuntime.subscribe()
    TestRuntime.set_capabilities(%{provisions?: false, library: :api, tunnel: "sprite_proxy"})
    on_exit(fn -> Application.delete_env(:legend, :test_runtime_capabilities) end)
    :ok
  end

  test "destroying a session with a runtime_ref tears down the runtime" do
    {:ok, s} = Agents.start_session(%{name: "t", harness_id: "claude_code", runtime_id: "test"})
    assert_receive {:test_runtime, :start, _spec, _opts}, 1000
    Agents.mark_session_running!(Agents.get_session!(s.id), %{runtime_ref: %{"sprite" => s.id, "exec_id" => "e1"}})

    :ok = Agents.destroy_session(Agents.get_session!(s.id))
    assert_receive {:test_runtime, :teardown, %{"sprite" => _, "exec_id" => "e1"}}, 1000
  end
end
```

- [ ] **Step 2: Run, verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_teardown_test.exs` → FAIL (no teardown call).

- [ ] **Step 3: Edit the `destroy` action in `session.ex`** — add teardown in `before_action` (after `ensure_stopped`):

```elixir
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
```

Add the private helper at the bottom of the module:
```elixir
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
```

- [ ] **Step 4: Run, verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_teardown_test.exs` → PASS. Re-run `mix test test/legend/core/agents/` to confirm LocalPty destroys still work (LocalPty has no teardown / sessions have nil runtime_ref → helper is a no-op).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/test/legend/core/agents/session_teardown_test.exs
git commit -m "feat(session): teardown the runtime (delete the sprite) on session destroy"
```

---

### Task 8: `GET /api/runtimes` endpoint

Mirrors the existing `GET /api/harnesses` (`HarnessController`/router first scope).

**Files:**
- Create: `backend/lib/legend_web/controllers/runtime_controller.ex`
- Modify: `backend/lib/legend_web/router.ex`
- Test: `backend/test/legend_web/controllers/runtime_api_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LegendWeb.RuntimeApiTest do
  use LegendWeb.ConnCase, async: true

  test "GET /api/runtimes lists registered runtimes with capabilities", %{conn: conn} do
    body = conn |> get("/api/runtimes") |> json_response(200)
    ids = Enum.map(body["data"], & &1["id"])
    assert "local_pty" in ids
    local = Enum.find(body["data"], &(&1["id"] == "local_pty"))
    assert local["capabilities"]["library"] == "path"
    assert local["capabilities"]["provisions?"] == false
  end
end
```

- [ ] **Step 2: Run, verify it fails** → 404 / no route.

- [ ] **Step 3: Create `backend/lib/legend_web/controllers/runtime_controller.ex`**

```elixir
defmodule LegendWeb.RuntimeController do
  use LegendWeb, :controller

  alias Legend.Core.Runtime

  def index(conn, _params) do
    data =
      Runtime.Registry.list()
      |> Enum.map(fn mod ->
        caps = Runtime.capabilities(mod)
        %{id: mod.id(), capabilities: caps}
      end)

    json(conn, %{data: data})
  end
end
```

> If runtimes need a human `name`, add a `name/0` to the behaviour later; for 2a the id (`local_pty`, `sprites`) is sufficient and the UI can title-case it. Keep YAGNI.

- [ ] **Step 4: Add the route** in the FIRST scope of `backend/lib/legend_web/router.ex` (next to `get "/harnesses", ...`):
```elixir
    get "/runtimes", RuntimeController, :index
```

- [ ] **Step 5: Run, verify it passes** → PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend_web/controllers/runtime_controller.ex backend/lib/legend_web/router.ex backend/test/legend_web/controllers/runtime_api_test.exs
git commit -m "feat(api): GET /api/runtimes lists runtimes + capabilities"
```

---

### Task 9: `Legend.Sprites.Exec` — interactive PTY over WSS exec (live-probed)

The interactive exec wire shape isn't in public docs — **probe it live first** (the token is in `.env`). Parallels Spec-1's `proxy.ex`.

**Files:**
- Create: `backend/lib/legend/sprites/exec.ex`
- Modify: `backend/lib/legend/sprites/client.ex` (add `list_exec_sessions/1` + whatever the probe shows attach needs)
- Test: `backend/test/legend/sprites/exec_test.exs` (pure helpers; the WSS loop is live-verified in Task 10)

- [ ] **Step 1: Probe the live interactive-exec + attach API**

With `export SPRITES_TOKEN=$(grep SPRITES_TOKEN backend/.env | cut -d= -f2)`, create a sprite and inspect the **WSS exec** endpoint: how a command is launched with a TTY, how stdin/stdout/resize frames are encoded (JSON control frames vs raw binary), how an exec **session id** is returned, and how **List Exec Sessions** + **Attach to Exec Session** work. Use a WS client (`wscat`, or a short `Mint.WebSocket` script). **Record the exact frames as a comment block at the top of `exec.ex`** ("Verified <date>:"). These shapes are the source of truth for Steps 3–4.

```bash
BASE=https://api.sprites.dev/v1 ; AUTH="Authorization: Bearer $SPRITES_TOKEN"
curl -sS -X POST $BASE/sprites -H "$AUTH" -H 'content-type: application/json' -d '{"name":"legend-exec-probe","url_settings":{"auth":"sprite"}}'
# then connect the WSS exec endpoint (path from the Spec-1 API notes) running e.g. `bash -i`,
# observe stdin/stdout/resize framing + the exec session id; then list/attach; then:
curl -sS -X DELETE $BASE/sprites/legend-exec-probe -H "$AUTH"
```

- [ ] **Step 2: Pure-helper test** `backend/test/legend/sprites/exec_test.exs`

```elixir
defmodule Legend.Sprites.ExecTest do
  use ExUnit.Case, async: true
  alias Legend.Sprites.Exec

  test "builds the exec WSS url for a sprite" do
    assert Exec.exec_url("s1") =~ "wss://api.sprites.dev/v1/sprites/s1/exec"
  end
end
```
(Adjust the asserted path to whatever the probe in Step 1 confirms.)

- [ ] **Step 3: Run, verify it fails** → `Exec` undefined.

- [ ] **Step 4: Implement `backend/lib/legend/sprites/exec.ex`**

A GenServer wrapping `Mint.WebSocket` (reuse the structure/patterns from Spec-1's `Legend.Sprites.Proxy` — connect → upgrade → frame loop), specialized to the interactive exec contract verified in Step 1:
- `start(name, command, opts)` → connect the WSS exec, launch `command` with a TTY (`rows`/`cols`), forward stdout to `opts.owner` as `{:runtime_output, data}` and exit as `{:runtime_exit, code}`. Capture and expose the **exec session id** (for the runtime's reattach ref).
- `write(pid, data)`, `resize(pid, cols, rows)`, `stop(pid)` → the exec control/stdin frames.
- `attach(name, exec_id, opts)` → connect + attach to an existing exec session, same owner contract.
Set the moduledoc to "Verified <date>: <frame summary from Step 1>".

> Like Spec-1's `proxy.ex`, the Mint.WebSocket frame loop is mechanical boilerplate from the `mint_web_socket` hexdocs — adapt it to the exec frames recorded in Step 1. It is verified live in Task 10, not unit-tested.

- [ ] **Step 5: Run the helper test, verify it passes.**

Run: `cd backend && mix test test/legend/sprites/exec_test.exs` → PASS.

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/sprites/exec.ex backend/lib/legend/sprites/client.ex backend/test/legend/sprites/exec_test.exs
git commit -m "feat(sprites): interactive WSS exec client (shapes verified against live API)"
```

---

### Task 10: `Legend.Runtimes.Sprites` + live acceptance

**Files:**
- Create: `backend/lib/legend/runtimes/sprites.ex`
- Modify: `backend/config/config.exs` (register the runtime)
- Test: `backend/test/legend/runtimes/sprites_test.exs` (id/capabilities offline; boot/exec/teardown live-gated)

- [ ] **Step 1: Offline test (id + capabilities)**

```elixir
defmodule Legend.Runtimes.SpritesTest do
  use ExUnit.Case, async: true
  alias Legend.Runtimes.Sprites

  test "id and capabilities" do
    assert Sprites.id() == "sprites"
    assert Sprites.capabilities() == %{provisions?: true, library: :api, tunnel: "sprite_proxy"}
  end
end
```

- [ ] **Step 2: Run, verify it fails** → undefined.

- [ ] **Step 3: Implement `backend/lib/legend/runtimes/sprites.ex`**

```elixir
defmodule Legend.Runtimes.Sprites do
  @moduledoc "Runs an agent in a sprites.dev cloud sandbox: PTY over the WSS exec, reattach-to-live, teardown-on-delete."
  @behaviour Legend.Core.Runtime

  alias Legend.Sprites.{Client, Exec}

  @impl true
  def id, do: "sprites"

  @impl true
  def capabilities, do: %{provisions?: true, library: :api, tunnel: "sprite_proxy"}

  # exec/2 runs pre-PTY (provisioning): ensure the sprite exists (idempotent, keyed by session id),
  # then run a non-interactive command via the HTTP POST exec.
  @impl true
  def exec(%{session_id: sid}, spec) do
    with {:ok, _} <- ensure_sprite(sid),
         {:ok, body} <- Client.exec(sid, exec_body(spec)) do
      {:ok, %{stdout: body["stdout"] || "", status: body["exit_code"] || 0}}
    end
  end

  @impl true
  def start(spec, opts) do
    sid = session_id_from(opts) || raise "sprites runtime needs the session id in opts"
    with {:ok, _} <- ensure_sprite(sid),
         {:ok, pid, exec_id} <- Exec.start(sid, spec, opts) do
      {:ok, %{sprite: sid, exec_id: exec_id, relay: pid}}
    end
  end

  @impl true
  def attach(%{"sprite" => sid, "exec_id" => exec_id}, opts) do
    case Exec.attach(sid, exec_id, opts) do
      {:ok, pid} -> {:ok, %{sprite: sid, exec_id: exec_id, relay: pid}}
      err -> err
    end
  end

  @impl true
  def write(%{relay: pid}, data), do: Exec.write(pid, data)
  @impl true
  def resize(%{relay: pid}, cols, rows), do: Exec.resize(pid, cols, rows)
  @impl true
  def stop(%{relay: pid}), do: Exec.stop(pid)

  @impl true
  def teardown(%{"sprite" => sid}), do: teardown_sprite(sid)
  def teardown(%{sprite: sid}), do: teardown_sprite(sid)

  defp teardown_sprite(sid) do
    _ = Client.delete_sprite(sid)
    :ok
  end

  defp ensure_sprite(sid) do
    case Client.get_sprite(sid) do
      {:ok, _} -> {:ok, :exists}
      {:error, _} -> Client.create_sprite(sid)
    end
  end

  # The session id reaches start/2 via opts — SessionServer passes %{owner, cwd}. Extend
  # SessionServer to also pass :session_id in start opts (see note below), or derive the
  # sprite name another way. Pin in implementation: add `session_id: session.id` to the
  # opts map SessionServer builds for runtime.start/attach.
  defp session_id_from(opts), do: opts[:session_id]

  defp exec_body(%Legend.Core.Runtime.CommandSpec{cmd: cmd, args: args, env: env}),
    do: %{command: cmd, args: args, env: env}
end
```

> **Cross-task consistency:** `start/2` needs the session id. Add `session_id: session.id` to the `start_opts`/`attach` opts map in `SessionServer` (Task 5's `do_start`/`start_or_attach` — extend `%{owner: self(), cwd: session.cwd}` to `%{owner: self(), cwd: session.cwd, session_id: session.id}`). The Test runtime ignores it; LocalPty ignores it. Make this edit when implementing Task 10 and re-run Task 5's tests.

- [ ] **Step 4: Register the runtime** in `backend/config/config.exs`:
```elixir
  runtimes: [Legend.Runtimes.LocalPty, Legend.Runtimes.Sprites],
```

- [ ] **Step 5: Run the offline test** → PASS. `mix compile --warnings-as-errors` clean.

- [ ] **Step 6: Live acceptance (gated on `SPRITES_TOKEN`, manual)**

Tag a `@tag :live` test (excluded by default — add `ExUnit.configure(exclude: [:live])` to `test/test_helper.exs` if not present) OR run in `iex -S mix`:
- `Sprites.exec(%{session_id: "legend-live"}, %CommandSpec{cmd: "echo", args: ["hi"], io: :pipes})` → `{:ok, %{stdout: "hi\n", status: 0}}`.
- `Sprites.start(%CommandSpec{cmd: "bash", args: ["-lc","echo ready; sleep 60"], env: %{}, io: :pty}, %{owner: self(), cwd: "/root", session_id: "legend-live"})` → receive `{:runtime_output, "ready\n"}`.
- `Sprites.teardown(%{sprite: "legend-live"})` → sprite gone (`Client.get_sprite` 404).

- [ ] **Step 7: Full live acceptance — Claude Code in a sprite (manual)**

With the backend running and `SPRITES_TOKEN` set: in the UI (after Task 11) pick *sprites + Claude Code* → watch `:provisioning` ("Installing Claude Code…") → terminal shows Claude Code → complete auth (`claude setup-token` paste per spec §4; **verify whether native OAuth works on the shipped version** and prefer it) → run a task → close the backend → reopen → resume reattaches to the live agent → delete the session → `Client.get_sprite` 404. Record what worked re: install command + auth in the `exec.ex`/`claude_code.ex` comments.

- [ ] **Step 8: Commit**

```bash
git add backend/lib/legend/runtimes/sprites.ex backend/config/config.exs backend/test/legend/runtimes/sprites_test.exs backend/test/test_helper.exs
git commit -m "feat(runtime): Legend.Runtimes.Sprites (PTY over WSS exec, attach, teardown)"
```

---

### Task 11: Frontend — runtime selector, provisioning status, cwd helper

**Files:**
- Modify: `frontend/src/lib/sessions.ts`, `frontend/src/lib/components/NewSessionDialog.svelte`, `frontend/src/lib/components/SessionSidebar.svelte`

- [ ] **Step 1: `sessions.ts` — types + `listRuntimes`**

Add `'provisioning'` to the `SessionStatus` union. Add `runtime_id?: string` to `CreateSessionParams`. Add:
```ts
export type Runtime = { id: string; capabilities: { provisions?: boolean; library: 'path' | 'api'; tunnel: string | null } };

export async function listRuntimes(): Promise<Runtime[]> {
  const res = await fetch(`${apiBase}/api/runtimes`);
  if (!res.ok) throw new Error(`listing runtimes failed: ${res.status}`);
  return (await res.json()).data;
}
```

- [ ] **Step 2: `NewSessionDialog.svelte` — runtime Select**

Mirror the existing harness `Select` block. Add state `let runtimes = $state<Runtime[]>([]); let runtimeId = $state('');`, import `listRuntimes, type Runtime`. In `openDialog`, `runtimes = await listRuntimes(); runtimeId = runtimes.find(r => r.id === 'local_pty')?.id ?? runtimes[0]?.id ?? '';`. Add a `Select` (between Harness and Name) titled "Runtime" listing `runtimes` by id (title-cased). In `create`, add `runtime_id: runtimeId` to the `createSession` params. Change the cwd `Input` placeholder when a non-`local_pty` runtime is selected to "sprite working directory (e.g. /root)".

- [ ] **Step 3: `SessionSidebar.svelte` — provisioning dot**

Add to the `dotClass` map: `provisioning: 'bg-violet-500'` (next to `starting`/`running`).

- [ ] **Step 4: Verify**

Run: `cd frontend && bun run check && bun run build` → clean.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/sessions.ts frontend/src/lib/components/NewSessionDialog.svelte frontend/src/lib/components/SessionSidebar.svelte
git commit -m "feat(ui): runtime selector + provisioning status + sprite cwd helper"
```

---

### Task 12: Final verification

- [ ] **Step 1: Backend**

Run: `cd backend && mix precommit` → compile (warnings-as-errors) + format + test green. Confirm `Legend.Core.Runtime.Registry.fetch("sprites")` resolves: `mix run -e 'IO.inspect Legend.Core.Runtime.Registry.fetch("sprites")'` → `{:ok, Legend.Runtimes.Sprites}`.

- [ ] **Step 2: Frontend**

Run: `cd frontend && bun run check && bun run build` → clean.

- [ ] **Step 3: Commit any fixups**

```bash
git add -A && git commit -m "chore(spec 2a): verification green" || echo "nothing to commit"
```

---

## Self-review notes (for the implementer)

- **Live-verifiable now:** unlike Spec 1, the `SPRITES_TOKEN` is in `.env` and 2a needs **no musl bridge** (tunnel-free), so Tasks 9–10's live probe + acceptance are runnable. Do them — don't leave the sprites adapter unverified.
- **Externally-dependent, isolated:** the sprites interactive-exec wire shapes live only in `Legend.Sprites.Exec` (Task 9, live-probed) and the Mint.WebSocket loop (delegated to hexdocs like Spec-1's `proxy.ex`). Everything else is plain, offline-tested Elixir.
- **Cross-task type consistency:** the runtime handle is `%{sprite, exec_id, relay}`; the persisted `runtime_ref` is `%{"sprite" => _, "exec_id" => _}` (string keys, since it round-trips through SQLite/JSON); `runtime_ref_from/1` (Task 5) and `Sprites.attach/teardown` (Task 10) and the destroy helper (Task 7) must all agree on those string keys. `start_opts` carries `:session_id` (added in Task 10, consumed by Sprites; ignored by LocalPty/Test).
- **`:provisioning`** flows end to end: status enum + `mark_provisioning` (Task 3) → broadcast in SessionServer (Task 5) → janitor filter (Task 3) → frontend union + dot (Task 11).
- **2a stays tunnel-free:** `:api` runtimes get no library/MCP env (Task 5). Spec 2b is where the tunnel + library tools wire in.
- **Spec correction:** the spec §7 implied a runtime selector already existed; it did not — Task 8 (`/api/runtimes`) + Task 11 add it.
```
