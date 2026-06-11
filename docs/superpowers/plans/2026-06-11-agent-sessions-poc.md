# Agent Sessions PoC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Start, use, stop, list, and reattach to agent CLI sessions (Claude Code + Hermes) through Legend's web/desktop UI via an embedded terminal.

**Architecture:** Two behaviour-based plugin seams — `Legend.Harness` (which agent) and `Legend.Runtime` (where it runs) — with config-listed registries. A per-session GenServer (`SessionServer`) composes one harness with one runtime, owns a scrollback buffer, and broadcasts output over PubSub to a per-session Phoenix Channel rendered by xterm.js. Session metadata is an Ash resource (`Legend.Agents.Session`) whose lifecycle actions keep record and process in lockstep.

**Tech Stack:** Elixir/Phoenix 1.8, Ash 3 + AshSqlite + AshJsonApi, erlexec ~> 2.3 (PTY), Phoenix Channels, SvelteKit 2/Svelte 5 runes, @xterm/xterm + @xterm/addon-fit, shadcn-svelte.

**Spec:** `docs/superpowers/specs/2026-06-11-agent-sessions-poc-design.md`. One recorded refinement vs. the spec: **`stop` is exposed on the session channel** (the live control plane) instead of a JSON:API route; the record's transition to `:exited` flows through the SessionServer exit path, preserving the spec's record/process invariant.

**Branch:** execute on `feature/agent-sessions-poc` (branched from `main`).

**Conventions for every task:** run backend commands from `backend/`. The test alias runs `ash.setup` automatically. Before the final commit of any backend task, `mix format`. The PostToolUse security hook prints Iron Law reminders on some file writes — they are reminders, not errors; the relevant one (no `String.to_atom` on user input) is satisfied by design (registries compare strings).

---

## File structure

```
backend/lib/legend/
  harness.ex                      # Legend.Harness behaviour + Definition struct
  harness/terminal.ex             # Legend.Harness.Terminal sub-behaviour (build_command/1)
  harness/registry.ex             # list/0, fetch/1 over config :legend, :harnesses
  harnesses/claude_code.ex        # built-in harness
  harnesses/hermes.ex             # built-in harness
  runtime.ex                      # Legend.Runtime behaviour (start/write/resize/stop)
  runtime/command_spec.ex         # %CommandSpec{cmd, args, env, io}
  runtime/registry.ex             # list/0, fetch/1 over config :legend, :runtimes
  runtimes/local_pty.ex           # erlexec-based PTY runtime
  agents.ex                       # Ash domain (json_api routes + code interface)
  agents/session.ex               # Ash resource
  agents/validations/known_registry_id.ex
  agents/scrollback.ex            # bounded byte ring buffer (pure)
  agents/session_server.ex        # per-session GenServer
  agents/supervisor.ex            # Registry + DynamicSupervisor + Janitor
  agents/janitor.ex               # boot pass: stale running -> failed
  agents/notifications.ex         # sessions_changed/0 PubSub helper
backend/lib/legend_web/
  channels/session_channel.ex
  channels/sessions_lobby_channel.ex
  controllers/harness_controller.ex
backend/test/support/test_runtime.ex
frontend/src/lib/
  sessions.ts                     # JSON:API client + types
  stores/sessions.svelte.ts       # reactive session list (lobby-driven)
  components/SessionSidebar.svelte
  components/NewSessionDialog.svelte
  components/Terminal.svelte
frontend/src/routes/
  +layout.svelte                  # app shell (modify)
  +page.svelte                    # empty state (rewrite)
  sessions/[id]/+page.svelte      # terminal page
```

---

### Task 1: Harness & runtime contracts + registries

**Files:**
- Create: `backend/lib/legend/runtime/command_spec.ex`
- Create: `backend/lib/legend/runtime.ex`
- Create: `backend/lib/legend/harness.ex`
- Create: `backend/lib/legend/harness/terminal.ex`
- Create: `backend/lib/legend/harness/registry.ex`
- Create: `backend/lib/legend/runtime/registry.ex`
- Test: `backend/test/legend/registry_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.RegistryTest do
  use ExUnit.Case, async: true

  defmodule FakeHarness do
    @behaviour Legend.Harness

    @impl true
    def definition do
      %Legend.Harness.Definition{
        id: "fake",
        name: "Fake",
        description: "test harness",
        kind: :terminal
      }
    end
  end

  defmodule FakeRuntime do
    @behaviour Legend.Runtime

    @impl true
    def id, do: "fake_rt"
    @impl true
    def start(_spec, _opts), do: {:error, "not a real runtime"}
    @impl true
    def write(_handle, _data), do: :ok
    @impl true
    def resize(_handle, _cols, _rows), do: :ok
    @impl true
    def stop(_handle), do: :ok
  end

  describe "Legend.Harness.Registry" do
    setup do
      original = Application.get_env(:legend, :harnesses, [])
      Application.put_env(:legend, :harnesses, [FakeHarness])
      on_exit(fn -> Application.put_env(:legend, :harnesses, original) end)
    end

    test "list/0 returns definitions" do
      assert [%Legend.Harness.Definition{id: "fake", kind: :terminal}] =
               Legend.Harness.Registry.list()
    end

    test "fetch/1 finds a module by string id" do
      assert {:ok, FakeHarness} = Legend.Harness.Registry.fetch("fake")
      assert :error = Legend.Harness.Registry.fetch("nope")
    end
  end

  describe "Legend.Runtime.Registry" do
    setup do
      original = Application.get_env(:legend, :runtimes, [])
      Application.put_env(:legend, :runtimes, [FakeRuntime])
      on_exit(fn -> Application.put_env(:legend, :runtimes, original) end)
    end

    test "fetch/1 finds a module by string id" do
      assert {:ok, FakeRuntime} = Legend.Runtime.Registry.fetch("fake_rt")
      assert :error = Legend.Runtime.Registry.fetch("nope")
    end
  end

  test "CommandSpec defaults" do
    spec = %Legend.Runtime.CommandSpec{cmd: "echo"}
    assert spec.args == []
    assert spec.env == %{}
    assert spec.io == :pty
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/registry_test.exs`
Expected: FAIL — `Legend.Harness.Definition.__struct__/1 is undefined` (modules don't exist yet).

- [ ] **Step 3: Implement the contracts**

`backend/lib/legend/runtime/command_spec.ex`:

```elixir
defmodule Legend.Runtime.CommandSpec do
  @moduledoc """
  How to invoke an agent process. Produced by a harness, consumed by a runtime.
  `io: :pty` runs under a pseudo-terminal (terminal harnesses); `:pipes` is
  reserved for ACP harnesses (plain stdio, JSON-RPC).
  """

  @enforce_keys [:cmd]
  defstruct cmd: nil, args: [], env: %{}, io: :pty

  @type t :: %__MODULE__{
          cmd: String.t(),
          args: [String.t()],
          env: %{String.t() => String.t()},
          io: :pty | :pipes
        }
end
```

`backend/lib/legend/runtime.ex`:

```elixir
defmodule Legend.Runtime do
  @moduledoc """
  Where and how an agent process executes. Implementations deliver output to
  the owner pid as `{:runtime_output, binary}` and termination as
  `{:runtime_exit, exit_code :: integer | nil}` (nil = killed by signal).
  """

  alias Legend.Runtime.CommandSpec

  @typedoc "Opaque, runtime-specific handle returned by start/2."
  @type handle :: term()

  @type start_opts :: %{
          required(:owner) => pid(),
          optional(:cwd) => String.t(),
          optional(:rows) => pos_integer(),
          optional(:cols) => pos_integer()
        }

  @callback id() :: String.t()
  @callback start(CommandSpec.t(), start_opts()) :: {:ok, handle()} | {:error, String.t()}
  @callback write(handle(), binary()) :: :ok
  @callback resize(handle(), cols :: pos_integer(), rows :: pos_integer()) :: :ok
  @callback stop(handle()) :: :ok
end
```

`backend/lib/legend/harness.ex`:

```elixir
defmodule Legend.Harness do
  @moduledoc """
  An agent type Legend can run. `kind` determines the transport and UI:
  `:terminal` (PTY + xterm, implemented), `:acp` and `:native` (reserved).
  Terminal harnesses additionally implement `Legend.Harness.Terminal`.
  """

  defmodule Definition do
    @enforce_keys [:id, :name, :kind]
    defstruct [:id, :name, :kind, description: ""]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            description: String.t(),
            kind: :terminal | :acp | :native
          }
  end

  @callback definition() :: Definition.t()
end
```

`backend/lib/legend/harness/terminal.ex`:

```elixir
defmodule Legend.Harness.Terminal do
  @moduledoc "Contract for `:terminal`-kind harnesses: build the CLI invocation."

  @type opts :: %{optional(:env) => %{String.t() => String.t()}}

  @callback build_command(opts()) :: Legend.Runtime.CommandSpec.t()
end
```

`backend/lib/legend/harness/registry.ex`:

```elixir
defmodule Legend.Harness.Registry do
  @moduledoc """
  Looks up harness modules from `config :legend, :harnesses`. Ids are compared
  as strings — user input never becomes an atom here.
  """

  alias Legend.Harness.Definition

  @spec list() :: [Definition.t()]
  def list, do: Enum.map(modules(), & &1.definition())

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    Enum.find_value(modules(), :error, fn mod ->
      if mod.definition().id == id, do: {:ok, mod}
    end)
  end

  defp modules, do: Application.get_env(:legend, :harnesses, [])
end
```

`backend/lib/legend/runtime/registry.ex`:

```elixir
defmodule Legend.Runtime.Registry do
  @moduledoc "Looks up runtime modules from `config :legend, :runtimes` by string id."

  @spec list() :: [module()]
  def list, do: modules()

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(id) when is_binary(id) do
    Enum.find_value(modules(), :error, fn mod ->
      if mod.id() == id, do: {:ok, mod}
    end)
  end

  defp modules, do: Application.get_env(:legend, :runtimes, [])
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend/registry_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/legend/harness.ex lib/legend/harness/ lib/legend/runtime.ex lib/legend/runtime/ test/legend/registry_test.exs
git commit -m "feat: harness and runtime plugin contracts with registries"
```

---

### Task 2: Built-in harnesses (Claude Code, Hermes) + config

**Files:**
- Create: `backend/lib/legend/harnesses/claude_code.ex`
- Create: `backend/lib/legend/harnesses/hermes.ex`
- Modify: `backend/config/config.exs` (the `config :legend` block at line 58)
- Modify: `backend/config/runtime.exs` (after the `source!` block)
- Modify: `backend/.env.example`
- Test: `backend/test/legend/harnesses_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.HarnessesTest do
  use ExUnit.Case, async: false

  alias Legend.Runtime.CommandSpec

  setup do
    original = Application.get_env(:legend, :harness_commands, [])
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)
    :ok
  end

  test "claude_code definition and default command" do
    assert %Legend.Harness.Definition{id: "claude_code", kind: :terminal} =
             Legend.Harnesses.ClaudeCode.definition()

    assert %CommandSpec{cmd: "claude", args: [], io: :pty, env: env} =
             Legend.Harnesses.ClaudeCode.build_command(%{})

    assert env["TERM"] == "xterm-256color"
  end

  test "hermes definition and default command" do
    assert %Legend.Harness.Definition{id: "hermes", kind: :terminal} =
             Legend.Harnesses.Hermes.definition()

    assert %CommandSpec{cmd: "hermes", args: []} = Legend.Harnesses.Hermes.build_command(%{})
  end

  test "configured command line is whitespace-split into cmd and args" do
    Application.put_env(:legend, :harness_commands, hermes: "hermes --profile work")

    assert %CommandSpec{cmd: "hermes", args: ["--profile", "work"]} =
             Legend.Harnesses.Hermes.build_command(%{})
  end

  test "caller env overrides are merged in" do
    assert %CommandSpec{env: %{"FOO" => "bar", "TERM" => "xterm-256color"}} =
             Legend.Harnesses.ClaudeCode.build_command(%{env: %{"FOO" => "bar"}})
  end

  test "both built-ins are registered" do
    ids = Legend.Harness.Registry.list() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["claude_code", "hermes"]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/harnesses_test.exs`
Expected: FAIL — `Legend.Harnesses.ClaudeCode` undefined.

- [ ] **Step 3: Implement the harnesses**

`backend/lib/legend/harnesses/claude_code.ex`:

```elixir
defmodule Legend.Harnesses.ClaudeCode do
  @moduledoc "Terminal harness for Anthropic's Claude Code CLI."

  @behaviour Legend.Harness
  @behaviour Legend.Harness.Terminal

  alias Legend.Harness.Definition
  alias Legend.Runtime.CommandSpec

  @impl Legend.Harness
  def definition do
    %Definition{
      id: "claude_code",
      name: "Claude Code",
      description: "Anthropic's agentic coding CLI",
      kind: :terminal
    }
  end

  @impl Legend.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:claude_code, "claude")

    %CommandSpec{
      cmd: cmd,
      args: args,
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
```

`backend/lib/legend/harnesses/hermes.ex`:

```elixir
defmodule Legend.Harnesses.Hermes do
  @moduledoc "Terminal harness for the Hermes agent CLI."

  @behaviour Legend.Harness
  @behaviour Legend.Harness.Terminal

  alias Legend.Harness.Definition
  alias Legend.Runtime.CommandSpec

  @impl Legend.Harness
  def definition do
    %Definition{
      id: "hermes",
      name: "Hermes",
      description: "Hermes agent CLI",
      kind: :terminal
    }
  end

  @impl Legend.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:hermes, "hermes")

    %CommandSpec{
      cmd: cmd,
      args: args,
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  defp configured_command(key, default) do
    :legend
    |> Application.get_env(:harness_commands, [])
    |> Keyword.get(key, default)
    |> String.split()
  end
end
```

- [ ] **Step 4: Wire the registries and env overrides**

In `backend/config/config.exs`, change the `config :legend` block to:

```elixir
config :legend,
  ecto_repos: [Legend.Repo],
  ash_domains: [],
  generators: [timestamp_type: :utc_datetime]

config :legend,
  harnesses: [Legend.Harnesses.ClaudeCode, Legend.Harnesses.Hermes],
  runtimes: [Legend.Runtimes.LocalPty]
```

(`Legend.Runtimes.LocalPty` doesn't exist yet — config holds atoms, nothing breaks until something fetches `"local_pty"`, which only happens after Task 8.)

In `backend/config/runtime.exs`, insert after the `source!([...])` block (line 11) and before the `PHX_SERVER` check:

```elixir
# Harness command lines (whitespace-split into cmd + args). Override per
# machine via .env, e.g. HARNESS_HERMES_CMD="hermes --profile work".
config :legend, :harness_commands,
  claude_code: env!("HARNESS_CLAUDE_CMD", :string, "claude"),
  hermes: env!("HARNESS_HERMES_CMD", :string, "hermes")
```

Append to `backend/.env.example`:

```bash

# Command lines used to launch agent harnesses (whitespace-split).
HARNESS_CLAUDE_CMD=claude
HARNESS_HERMES_CMD=hermes
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/legend/harnesses_test.exs test/legend/registry_test.exs`
Expected: PASS. (The registry test's setup swaps the `:harnesses` config, so the new global config doesn't break it.)

- [ ] **Step 6: Commit**

```bash
git add lib/legend/harnesses/ config/config.exs config/runtime.exs .env.example test/legend/harnesses_test.exs
git commit -m "feat: claude_code and hermes built-in harnesses with env-overridable commands"
```

---

### Task 3: TestRuntime (test double proving the runtime seam)

**Files:**
- Create: `backend/test/support/test_runtime.ex`
- Modify: `backend/config/test.exs`
- Test: `backend/test/legend/test_runtime_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.TestRuntimeTest do
  use ExUnit.Case, async: false

  alias Legend.Runtime.CommandSpec

  test "is registered in the test runtime registry" do
    assert {:ok, Legend.TestRuntime} = Legend.Runtime.Registry.fetch("test")
  end

  test "start notifies the subscribed test process and returns a handle" do
    Legend.TestRuntime.subscribe()
    spec = %CommandSpec{cmd: "claude"}

    assert {:ok, handle} = Legend.TestRuntime.start(spec, %{owner: self()})
    assert_receive {:test_runtime, :start, ^spec, %{owner: _}}

    assert :ok = Legend.TestRuntime.write(handle, "hello")
    assert_receive {:test_runtime, :write, "hello"}

    assert :ok = Legend.TestRuntime.resize(handle, 120, 40)
    assert_receive {:test_runtime, :resize, 120, 40}
  end

  test "start returns an error for the magic cmd \"fail\"" do
    assert {:error, "boom"} = Legend.TestRuntime.start(%CommandSpec{cmd: "fail"}, %{owner: self()})
  end

  test "stop delivers a runtime_exit to the owner" do
    {:ok, handle} = Legend.TestRuntime.start(%CommandSpec{cmd: "claude"}, %{owner: self()})
    assert :ok = Legend.TestRuntime.stop(handle)
    assert_receive {:runtime_exit, nil}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/test_runtime_test.exs`
Expected: FAIL — `Legend.TestRuntime` undefined.

- [ ] **Step 3: Implement TestRuntime**

`backend/test/support/test_runtime.ex`:

```elixir
defmodule Legend.TestRuntime do
  @moduledoc """
  In-memory `Legend.Runtime` for tests — the second runtime implementation that
  proves the seam. Tests observe calls by subscribing (`subscribe/0`) and drive
  output/exit by sending `{:runtime_output, data}` / `{:runtime_exit, code}`
  directly to the owning SessionServer pid.
  """

  @behaviour Legend.Runtime

  def subscribe, do: Application.put_env(:legend, :test_runtime_listener, self())

  @impl true
  def id, do: "test"

  @impl true
  def start(%Legend.Runtime.CommandSpec{cmd: "fail"}, _opts), do: {:error, "boom"}

  def start(spec, opts) do
    notify({:test_runtime, :start, spec, opts})
    {:ok, %{owner: Map.fetch!(opts, :owner)}}
  end

  @impl true
  def write(_handle, data) do
    notify({:test_runtime, :write, data})
    :ok
  end

  @impl true
  def resize(_handle, cols, rows) do
    notify({:test_runtime, :resize, cols, rows})
    :ok
  end

  @impl true
  def stop(%{owner: owner}) do
    notify({:test_runtime, :stop})
    send(owner, {:runtime_exit, nil})
    :ok
  end

  defp notify(msg) do
    case Application.get_env(:legend, :test_runtime_listener) do
      nil -> :ok
      pid -> send(pid, msg)
    end
  end
end
```

Append to `backend/config/test.exs`:

```elixir
# Sessions in tests run on the in-memory TestRuntime ("test").
config :legend, :runtimes, [Legend.Runtimes.LocalPty, Legend.TestRuntime]

# The janitor's boot pass conflicts with the SQL sandbox; tests call it directly.
config :legend, run_session_janitor: false
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend/test_runtime_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add test/support/test_runtime.ex config/test.exs test/legend/test_runtime_test.exs
git commit -m "test: in-memory TestRuntime as second runtime implementation"
```

---

### Task 4: Scrollback buffer

**Files:**
- Create: `backend/lib/legend/agents/scrollback.ex`
- Test: `backend/test/legend/agents/scrollback_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Agents.ScrollbackTest do
  use ExUnit.Case, async: true

  alias Legend.Agents.Scrollback

  test "appends and renders in order" do
    sb = Scrollback.new() |> Scrollback.append("hello ") |> Scrollback.append("world")
    assert Scrollback.to_binary(sb) == "hello world"
  end

  test "drops oldest chunks beyond max_bytes" do
    sb =
      Scrollback.new(10)
      |> Scrollback.append("aaaa")
      |> Scrollback.append("bbbb")
      |> Scrollback.append("cccc")

    assert Scrollback.to_binary(sb) == "bbbbcccc"
  end

  test "always keeps the newest chunk even if it alone exceeds max_bytes" do
    sb = Scrollback.new(4) |> Scrollback.append("aa") |> Scrollback.append("bbbbbbbb")
    assert Scrollback.to_binary(sb) == "bbbbbbbb"
  end

  test "empty buffer renders empty binary" do
    assert Scrollback.to_binary(Scrollback.new()) == ""
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/agents/scrollback_test.exs`
Expected: FAIL — `Legend.Agents.Scrollback` undefined.

- [ ] **Step 3: Implement**

`backend/lib/legend/agents/scrollback.ex`:

```elixir
defmodule Legend.Agents.Scrollback do
  @moduledoc """
  Bounded byte buffer holding the most recent terminal output for replay on
  (re)attach. Trims whole chunks from the oldest end, but never drops the
  newest chunk, so a single oversized burst is still replayable.
  """

  @default_max_bytes 262_144

  defstruct chunks: :queue.new(), bytes: 0, max_bytes: @default_max_bytes

  @type t :: %__MODULE__{}

  @spec new(pos_integer()) :: t()
  def new(max_bytes \\ @default_max_bytes), do: %__MODULE__{max_bytes: max_bytes}

  @spec append(t(), binary()) :: t()
  def append(%__MODULE__{} = sb, data) when is_binary(data) do
    trim(%{sb | chunks: :queue.in(data, sb.chunks), bytes: sb.bytes + byte_size(data)})
  end

  @spec to_binary(t()) :: binary()
  def to_binary(%__MODULE__{chunks: chunks}) do
    chunks |> :queue.to_list() |> IO.iodata_to_binary()
  end

  defp trim(%{bytes: bytes, max_bytes: max} = sb) when bytes <= max, do: sb

  defp trim(sb) do
    if :queue.len(sb.chunks) <= 1 do
      sb
    else
      {{:value, oldest}, rest} = :queue.out(sb.chunks)
      trim(%{sb | chunks: rest, bytes: sb.bytes - byte_size(oldest)})
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend/agents/scrollback_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/legend/agents/scrollback.ex test/legend/agents/scrollback_test.exs
git commit -m "feat: bounded scrollback buffer for session replay"
```

---

### Task 5: Session resource, Agents domain, migration

**Files:**
- Create: `backend/lib/legend/agents.ex`
- Create: `backend/lib/legend/agents/session.ex`
- Create: `backend/lib/legend/agents/validations/known_registry_id.ex`
- Modify: `backend/config/config.exs` (`ash_domains: []` → `ash_domains: [Legend.Agents]`)
- Generated: `backend/priv/repo/migrations/*_add_sessions.exs` + `backend/priv/resource_snapshots/`
- Test: `backend/test/legend/agents/session_test.exs`

The `:start` action here only creates the record — the process hook arrives in Task 7, after SessionServer exists.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Agents.SessionTest do
  use Legend.DataCase, async: false

  alias Legend.Agents

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp", name: "demo"}

  test "start creates a session in :starting" do
    session = Agents.start_session!(@valid)
    assert session.status == :starting
    assert session.harness_id == "claude_code"
    assert session.cwd == "/tmp"
  end

  test "cwd defaults to the user home" do
    session = Agents.start_session!(Map.delete(@valid, :cwd))
    assert session.cwd == System.user_home!()
  end

  test "runtime_id defaults to local_pty" do
    # Point the harness at a nonexistent binary so this stays safe after Task 7
    # wires the create hook (LocalPty would otherwise spawn a real `claude`).
    original = Application.get_env(:legend, :harness_commands, [])
    Application.put_env(:legend, :harness_commands, claude_code: "no-such-binary-xyz")
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)

    session = Agents.start_session!(Map.delete(@valid, :runtime_id))
    assert session.runtime_id == "local_pty"
  end

  test "rejects unknown harness and runtime ids" do
    assert {:error, %Ash.Error.Invalid{}} =
             Agents.start_session(%{@valid | harness_id: "nope"})

    assert {:error, %Ash.Error.Invalid{}} =
             Agents.start_session(%{@valid | runtime_id: "nope"})
  end

  test "status transitions: mark_running, finish, fail" do
    session = Agents.start_session!(@valid)

    running = Agents.mark_session_running!(session)
    assert running.status == :running
    assert running.started_at

    finished = Agents.finish_session!(running, %{exit_code: 0})
    assert finished.status == :exited
    assert finished.exit_code == 0
    assert finished.ended_at

    failed = Agents.fail_session!(Agents.start_session!(@valid), %{error: "spawn failed"})
    assert failed.status == :failed
    assert failed.error == "spawn failed"
  end

  test "list and get" do
    session = Agents.start_session!(@valid)
    assert Enum.any?(Agents.list_sessions!(), &(&1.id == session.id))
    assert Agents.get_session!(session.id).id == session.id
  end

  test "destroy removes the record" do
    session = Agents.start_session!(@valid)
    assert :ok = Agents.destroy_session!(session)
    assert {:error, %Ash.Error.Invalid{}} = Agents.get_session(session.id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/agents/session_test.exs`
Expected: FAIL — `Legend.Agents` undefined.

- [ ] **Step 3: Implement validation, resource, domain**

`backend/lib/legend/agents/validations/known_registry_id.ex`:

```elixir
defmodule Legend.Agents.Validations.KnownRegistryId do
  @moduledoc """
  Validates that a string attribute matches a registered plugin id. Ids stay
  strings throughout — user input is never converted to an atom.
  """

  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if Keyword.has_key?(opts, :attribute) and Keyword.has_key?(opts, :registry) do
      {:ok, opts}
    else
      {:error, "requires :attribute and :registry options"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, attribute) do
      nil ->
        :ok

      id ->
        case opts[:registry].fetch(id) do
          {:ok, _module} -> :ok
          :error -> {:error, field: attribute, message: "is not a registered id"}
        end
    end
  end
end
```

`backend/lib/legend/agents/session.ex`:

```elixir
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

  json_api do
    type "session"
  end

  sqlite do
    table "sessions"
    repo Legend.Repo
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
    end

    # require_atomic? false on all updates: AshSqlite has no atomic-update
    # support, and Ash 3 defaults to requiring it (config :ash,
    # default_actions_require_atomic?: true).
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

    timestamps(public?: true)
  end

  @doc false
  def default_cwd, do: System.user_home!()
end
```

`backend/lib/legend/agents.ex`:

```elixir
defmodule Legend.Agents do
  @moduledoc """
  Agent sessions domain: session records, their lifecycle actions, and the
  JSON:API surface at /api/sessions.
  """

  use Ash.Domain, otp_app: :legend, extensions: [AshJsonApi.Domain]

  json_api do
    routes do
      base_route "/sessions", Legend.Agents.Session do
        index :list
        get :read
        post :start
        delete :destroy
      end
    end
  end

  resources do
    resource Legend.Agents.Session do
      define :start_session, action: :start
      define :list_sessions, action: :list
      define :get_session, action: :read, get_by: [:id]
      define :mark_session_running, action: :mark_running
      define :finish_session, action: :finish
      define :fail_session, action: :fail
      define :destroy_session, action: :destroy
    end
  end
end
```

In `backend/config/config.exs` change `ash_domains: []` to:

```elixir
  ash_domains: [Legend.Agents],
```

- [ ] **Step 4: Generate and run the migration**

Run: `mix ash.codegen add_sessions`
Expected: creates `priv/resource_snapshots/repo/sessions/*.json` and `priv/repo/migrations/<timestamp>_add_sessions.exs`. Inspect the migration — it must create table `sessions` with all attributes from the resource.

Run: `mix ash.migrate`
Expected: migration runs, `== MIGRATED ==` output.

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/legend/agents/session_test.exs`
Expected: PASS (7 tests). (The test alias runs `ash.setup`, which applies the migration to the test DB.)

- [ ] **Step 6: Commit**

```bash
git add lib/legend/agents.ex lib/legend/agents/session.ex lib/legend/agents/validations/ config/config.exs priv/repo/migrations/ priv/resource_snapshots/ test/legend/agents/session_test.exs
git commit -m "feat: Legend.Agents domain with Session resource and JSON:API routes"
```

---

### Task 6: Supervision tree + SessionServer

**Files:**
- Create: `backend/lib/legend/agents/notifications.ex`
- Create: `backend/lib/legend/agents/session_server.ex`
- Create: `backend/lib/legend/agents/supervisor.ex`
- Create: `backend/lib/legend/agents/janitor.ex`
- Modify: `backend/lib/legend/application.ex` (children list)
- Test: `backend/test/legend/agents/session_server_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Agents.SessionServerTest do
  use Legend.DataCase, async: false

  alias Legend.Agents
  alias Legend.Agents.SessionServer

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}

  setup do
    Legend.TestRuntime.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
      end
    end)

    session = Agents.start_session!(@valid)
    # Forward-compat with Task 7: once the create action starts the server
    # itself, kill that instance so boot!/1 below can start its own cleanly.
    # Before Task 7 this is a no-op.
    SessionServer.ensure_stopped(session.id)
    %{session: session}
  end

  defp boot!(session) do
    {:ok, pid} = SessionServer.start_session(session)
    pid
  end

  test "starting runs the runtime and marks the record running", %{session: session} do
    pid = boot!(session)
    assert Process.alive?(pid)
    assert_receive {:test_runtime, :start, spec, %{cwd: "/tmp", owner: ^pid}}
    assert spec.cmd == "claude"
    assert Agents.get_session!(session.id).status == :running
  end

  test "output is buffered, broadcast with offsets, and replayed on attach", %{session: session} do
    pid = boot!(session)
    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{session.id}")

    send(pid, {:runtime_output, "hello "})
    send(pid, {:runtime_output, "world"})

    assert_receive {:session_output, 0, "hello "}
    assert_receive {:session_output, 6, "world"}

    assert {:ok, %{status: :running, buffer: "hello world", offset: 11}} =
             SessionServer.attach(session.id)
  end

  test "write and resize are forwarded to the runtime", %{session: session} do
    boot!(session)
    :ok = SessionServer.write(session.id, "ls\n")
    assert_receive {:test_runtime, :write, "ls\n"}

    :ok = SessionServer.resize(session.id, 120, 40)
    assert_receive {:test_runtime, :resize, 120, 40}
  end

  test "runtime exit marks record exited, broadcasts, and keeps the server alive", %{session: session} do
    pid = boot!(session)
    Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{session.id}")
    send(pid, {:runtime_output, "bye"})
    send(pid, {:runtime_exit, 0})

    assert_receive {:session_exit, 0}
    record = Agents.get_session!(session.id)
    assert record.status == :exited
    assert record.exit_code == 0

    # Scrollback still attachable after exit.
    assert {:ok, %{status: :exited, buffer: "bye"}} = SessionServer.attach(session.id)
    assert Process.alive?(pid)
  end

  test "stop asks the runtime to terminate", %{session: session} do
    boot!(session)
    :ok = SessionServer.stop(session.id)
    assert_receive {:test_runtime, :stop}
    # TestRuntime.stop sends {:runtime_exit, nil} to the owner.
    eventually(fn -> Agents.get_session!(session.id).status == :exited end)
  end

  test "spawn failure marks the record failed and starts no server", %{session: _} do
    original = Application.get_env(:legend, :harness_commands, [])
    Application.put_env(:legend, :harness_commands, claude_code: "fail")
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)

    session = Agents.start_session!(@valid)
    assert :ignore = SessionServer.start_session(session)

    record = Agents.get_session!(session.id)
    assert record.status == :failed
    assert record.error == "boom"
    assert {:error, :not_running} = SessionServer.attach(session.id)
  end

  test "ensure_stopped terminates a live server and is a no-op otherwise", %{session: session} do
    pid = boot!(session)
    assert :ok = SessionServer.ensure_stopped(session.id)
    refute Process.alive?(pid)
    assert :ok = SessionServer.ensure_stopped(session.id)
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

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/agents/session_server_test.exs`
Expected: FAIL — `Legend.Agents.SessionServer` undefined.

- [ ] **Step 3: Implement notifications, server, supervisor, janitor**

`backend/lib/legend/agents/notifications.ex`:

```elixir
defmodule Legend.Agents.Notifications do
  @moduledoc "PubSub fan-out for session list changes (consumed by the lobby channel)."

  @topic "sessions:changed"

  def topic, do: @topic

  def sessions_changed do
    Phoenix.PubSub.broadcast(Legend.PubSub, @topic, :sessions_changed)
  end
end
```

`backend/lib/legend/agents/session_server.ex`:

```elixir
defmodule Legend.Agents.SessionServer do
  @moduledoc """
  One process per live session. Resolves harness -> command spec -> runtime,
  owns the scrollback buffer, broadcasts output on PubSub topic
  `session:<id>` as `{:session_output, chunk_offset, data}`, and keeps the
  session record in sync. Stays alive after runtime exit (status :exited) so
  scrollback remains viewable until the session is deleted.
  """

  use GenServer, restart: :temporary

  alias Legend.Agents
  alias Legend.Agents.Notifications
  alias Legend.Agents.Scrollback

  ## Client API

  def start_session(%Agents.Session{} = session) do
    DynamicSupervisor.start_child(Legend.Agents.SessionSupervisor, {__MODULE__, session})
  end

  def start_link(session) do
    GenServer.start_link(__MODULE__, session, name: via(session.id))
  end

  @doc "Returns {:ok, %{status, buffer, offset}} or {:error, :not_running}."
  def attach(id), do: call(id, :attach)

  def write(id, data), do: cast(id, {:write, data})
  def resize(id, cols, rows), do: cast(id, {:resize, cols, rows})
  def stop(id), do: cast(id, :stop)

  @doc "Terminates the server (and its runtime) if alive. Used by destroy."
  def ensure_stopped(id) do
    case Registry.lookup(Legend.Agents.SessionRegistry, id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
        :ok

      [] ->
        :ok
    end
  end

  def whereis(id) do
    case Registry.lookup(Legend.Agents.SessionRegistry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(id), do: {:via, Registry, {Legend.Agents.SessionRegistry, id}}

  defp call(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, msg)
    end
  end

  defp cast(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.cast(pid, msg)
    end
  end

  ## Server

  @impl true
  def init(session) do
    Process.flag(:trap_exit, true)

    with {:ok, harness} <- fetch_registered(Legend.Harness.Registry, session.harness_id),
         {:ok, runtime} <- fetch_registered(Legend.Runtime.Registry, session.runtime_id),
         spec = harness.build_command(%{}),
         {:ok, handle} <- runtime.start(spec, %{owner: self(), cwd: session.cwd}) do
      session = Agents.mark_session_running!(session)
      broadcast(session.id, {:session_status, :running})
      Notifications.sessions_changed()

      {:ok,
       %{
         session: session,
         runtime: runtime,
         handle: handle,
         scrollback: Scrollback.new(),
         offset: 0,
         exited?: false
       }}
    else
      {:error, reason} ->
        Agents.fail_session!(session, %{error: to_string(reason)})
        Notifications.sessions_changed()
        :ignore
    end
  end

  defp fetch_registered(registry, id) do
    case registry.fetch(id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "not registered: #{id}"}
    end
  end

  @impl true
  def handle_call(:attach, _from, state) do
    reply = %{
      status: state.session.status,
      buffer: Scrollback.to_binary(state.scrollback),
      offset: state.offset
    }

    {:reply, {:ok, reply}, state}
  end

  @impl true
  def handle_cast({:write, _data}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:write, data}, state) do
    state.runtime.write(state.handle, data)
    {:noreply, state}
  end

  def handle_cast({:resize, _c, _r}, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast({:resize, cols, rows}, state) do
    state.runtime.resize(state.handle, cols, rows)
    {:noreply, state}
  end

  def handle_cast(:stop, %{exited?: true} = state), do: {:noreply, state}

  def handle_cast(:stop, state) do
    state.runtime.stop(state.handle)
    {:noreply, state}
  end

  @impl true
  def handle_info({:runtime_output, data}, state) do
    broadcast(state.session.id, {:session_output, state.offset, data})

    {:noreply,
     %{
       state
       | scrollback: Scrollback.append(state.scrollback, data),
         offset: state.offset + byte_size(data)
     }}
  end

  def handle_info({:runtime_exit, _code}, %{exited?: true} = state), do: {:noreply, state}

  def handle_info({:runtime_exit, code}, state) do
    session = Agents.finish_session!(state.session, %{exit_code: code})
    broadcast(session.id, {:session_exit, code})
    Notifications.sessions_changed()
    {:noreply, %{state | session: session, exited?: true}}
  end

  # Runtime helper processes exit normally after forwarding runtime_exit.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  # A crashed runtime process counts as an exit without a code.
  def handle_info({:EXIT, _pid, _reason}, %{exited?: false} = state) do
    handle_info({:runtime_exit, nil}, state)
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{exited?: false} = state) do
    state.runtime.stop(state.handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp broadcast(id, msg) do
    Phoenix.PubSub.broadcast(Legend.PubSub, "session:#{id}", msg)
  end
end
```

`backend/lib/legend/agents/janitor.ex`:

```elixir
defmodule Legend.Agents.Janitor do
  @moduledoc """
  Boot pass: sessions recorded :starting/:running belong to a previous backend
  run (their PTYs died with it) — mark them failed so the UI never shows
  phantom live sessions. Disabled in test (config :legend, run_session_janitor).
  """

  use Task, restart: :temporary

  require Ash.Query

  def start_link(_arg), do: Task.start_link(&run/0)

  def run do
    Legend.Agents.Session
    |> Ash.Query.filter(status in [:starting, :running])
    |> Ash.read!()
    |> Enum.each(&Legend.Agents.fail_session!(&1, %{error: "backend restarted"}))
  end
end
```

`backend/lib/legend/agents/supervisor.ex`:

```elixir
defmodule Legend.Agents.Supervisor do
  @moduledoc "Supervises session process infrastructure (registry, dynamic supervisor, janitor)."

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children =
      [
        {Registry, keys: :unique, name: Legend.Agents.SessionRegistry},
        {DynamicSupervisor, name: Legend.Agents.SessionSupervisor, strategy: :one_for_one}
      ] ++ janitor()

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp janitor do
    if Application.get_env(:legend, :run_session_janitor, true) do
      [Legend.Agents.Janitor]
    else
      []
    end
  end
end
```

In `backend/lib/legend/application.ex`, add `Legend.Agents.Supervisor` to the children list after the `Ecto.Migrator` entry and before `DNSCluster` — sessions need the repo (and, in releases, migrations) but must be up before the endpoint serves traffic:

```elixir
      {Ecto.Migrator,
       repos: Application.fetch_env!(:legend, :ecto_repos), skip: skip_migrations?()},
      Legend.Agents.Supervisor,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend/agents/session_server_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Add the janitor test**

Append to `backend/test/legend/agents/session_server_test.exs` (inside the module):

```elixir
  test "janitor marks orphaned running sessions as failed", %{session: session} do
    pid = boot!(session)
    assert Agents.get_session!(session.id).status == :running

    # Simulate a backend restart: the process dies, the record stays :running.
    DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
    assert Agents.get_session!(session.id).status == :running

    Legend.Agents.Janitor.run()

    record = Agents.get_session!(session.id)
    assert record.status == :failed
    assert record.error == "backend restarted"
  end
```

Wait — `terminate_child` triggers `terminate/2`, which calls `runtime.stop`, and TestRuntime's stop sends `{:runtime_exit, nil}` to a dying process (harmless), but the record is only updated by `handle_info`, which never runs because the process is terminating. So the record stays `:running`. That is exactly the orphan scenario. Run: `mix test test/legend/agents/session_server_test.exs`
Expected: PASS (8 tests).

- [ ] **Step 6: Run the full backend suite and commit**

Run: `mix test`
Expected: all green.

```bash
git add lib/legend/agents/ lib/legend/application.ex test/legend/agents/session_server_test.exs
git commit -m "feat: SessionServer with scrollback, PubSub broadcast, and supervision tree"
```

---

### Task 7: Lifecycle wiring — create starts process, destroy stops it, JSON:API round-trip

**Files:**
- Modify: `backend/lib/legend/agents/session.ex` (the `:start` and `:destroy` actions)
- Test: `backend/test/legend/agents/session_lifecycle_test.exs`
- Test: `backend/test/legend_web/controllers/session_api_test.exs`

- [ ] **Step 1: Write the failing lifecycle test**

```elixir
defmodule Legend.Agents.SessionLifecycleTest do
  use Legend.DataCase, async: false

  alias Legend.Agents
  alias Legend.Agents.SessionServer

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}

  setup do
    Legend.TestRuntime.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
      end
    end)

    :ok
  end

  test "start_session creates the record AND starts the server" do
    session = Agents.start_session!(@valid)
    assert_receive {:test_runtime, :start, _spec, _opts}
    assert SessionServer.whereis(session.id)
    assert Agents.get_session!(session.id).status == :running
  end

  test "start_session with a failing spawn returns a :failed record" do
    original = Application.get_env(:legend, :harness_commands, [])
    Application.put_env(:legend, :harness_commands, claude_code: "fail")
    on_exit(fn -> Application.put_env(:legend, :harness_commands, original) end)

    session = Agents.start_session!(@valid)
    assert session.status == :failed
    assert session.error == "boom"
    refute SessionServer.whereis(session.id)
  end

  test "destroy_session stops the live server and removes the record" do
    session = Agents.start_session!(@valid)
    pid = SessionServer.whereis(session.id)
    assert pid

    :ok = Agents.destroy_session!(Agents.get_session!(session.id))
    refute Process.alive?(pid)
    assert {:error, _} = Agents.get_session(session.id)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/agents/session_lifecycle_test.exs`
Expected: FAIL — first test: status is `:starting` and `whereis` returns nil (no hook yet).

- [ ] **Step 3: Add the hooks to the resource**

In `backend/lib/legend/agents/session.ex`, replace the `:start` and `:destroy` actions with:

```elixir
    create :start do
      accept [:name, :harness_id, :runtime_id, :cwd]

      validate {KnownRegistryId, attribute: :harness_id, registry: Legend.Harness.Registry}
      validate {KnownRegistryId, attribute: :runtime_id, registry: Legend.Runtime.Registry}

      change after_transaction(fn
               _changeset, {:ok, session} ->
                 case Legend.Agents.SessionServer.start_session(session) do
                   {:ok, _pid} ->
                     {:ok, Legend.Agents.get_session!(session.id)}

                   :ignore ->
                     # init marked the record :failed before returning :ignore
                     {:ok, Legend.Agents.get_session!(session.id)}

                   {:error, reason} ->
                     {:ok, Legend.Agents.fail_session!(session, %{error: inspect(reason)})}
                 end

               _changeset, {:error, _} = error ->
                 error
             end)
    end
```

```elixir
    destroy :destroy do
      primary? true
      require_atomic? false

      change before_action(fn changeset, _context ->
               Legend.Agents.SessionServer.ensure_stopped(changeset.data.id)
               changeset
             end)

      change after_transaction(fn
               _changeset, {:ok, _} = result ->
                 Legend.Agents.Notifications.sessions_changed()
                 result

               _changeset, other ->
                 other
             end)
    end
```

- [ ] **Step 4: Run lifecycle test to verify it passes**

Run: `mix test test/legend/agents/session_lifecycle_test.exs`
Expected: PASS (3 tests). Also re-run `mix test test/legend/agents/session_test.exs` — the Task 5 tests now start TestRuntime-backed servers as a side effect; they must still pass (they use `runtime_id: "test"` already; the two `rejects unknown` cases never reach the hook). If the `status == :starting` assertion in Task 5's first test now fails because the hook promotes it to `:running`, update that assertion to `assert session.status == :running` — the hook legitimately changed the contract.

- [ ] **Step 5: Write the JSON:API round-trip test**

`backend/test/legend_web/controllers/session_api_test.exs`:

```elixir
defmodule LegendWeb.SessionApiTest do
  use LegendWeb.ConnCase, async: false

  @jsonapi "application/vnd.api+json"

  setup %{conn: conn} do
    Legend.TestRuntime.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
      end
    end)

    conn =
      conn
      |> put_req_header("accept", @jsonapi)
      |> put_req_header("content-type", @jsonapi)

    %{conn: conn}
  end

  test "POST /api/sessions creates and starts a session", %{conn: conn} do
    body = %{data: %{type: "session", attributes: %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}}}
    conn = post(conn, "/api/sessions", Jason.encode!(body))

    assert %{"data" => %{"id" => id, "attributes" => attrs}} = json_response(conn, 201)
    assert attrs["status"] == "running"
    assert attrs["harness_id"] == "claude_code"
    assert_receive {:test_runtime, :start, _spec, _opts}
    assert Legend.Agents.SessionServer.whereis(id)
  end

  test "POST with unknown harness returns errors", %{conn: conn} do
    body = %{data: %{type: "session", attributes: %{harness_id: "nope", runtime_id: "test"}}}
    conn = post(conn, "/api/sessions", Jason.encode!(body))
    assert %{"errors" => [_ | _]} = json_response(conn, 400)
  end

  test "GET /api/sessions lists sessions", %{conn: conn} do
    Legend.Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    conn = get(conn, "/api/sessions")
    assert %{"data" => [%{"attributes" => %{"harness_id" => "hermes"}} | _]} = json_response(conn, 200)
  end

  test "DELETE /api/sessions/:id destroys", %{conn: conn} do
    session = Legend.Agents.start_session!(%{harness_id: "hermes", runtime_id: "test", cwd: "/tmp"})
    conn = delete(conn, "/api/sessions/#{session.id}")
    assert response(conn, 200)
    assert {:error, _} = Legend.Agents.get_session(session.id)
  end
end
```

- [ ] **Step 6: Run the API test**

Run: `mix test test/legend_web/controllers/session_api_test.exs`
Expected: PASS. If the DELETE assertion fails on the status code, check the actual code (AshJsonApi returns 200 with the deleted record by default) and adjust the assertion to match reality — the behavior that matters is the record being gone.

- [ ] **Step 7: Full suite + commit**

Run: `mix test`
Expected: all green.

```bash
git add lib/legend/agents/session.ex test/legend/agents/session_lifecycle_test.exs test/legend_web/controllers/session_api_test.exs
git commit -m "feat: session lifecycle actions start/stop the session process"
```

---

### Task 8: LocalPty runtime (erlexec)

**Files:**
- Modify: `backend/mix.exs` (add `{:erlexec, "~> 2.3"}`)
- Create: `backend/lib/legend/runtimes/local_pty.ex`
- Test: `backend/test/legend/runtimes/local_pty_test.exs`

- [ ] **Step 1: Add the dependency**

In `backend/mix.exs` deps, after `{:corsica, "~> 2.1"},` add:

```elixir
      {:erlexec, "~> 2.3"},
```

Run: `mix deps.get && mix deps.compile erlexec`
Expected: compiles the `exec-port` C++ binary into `_build/.../erlexec/priv`. (Needs a C++ toolchain — Xcode CLT is present on this machine.)

- [ ] **Step 2: Write the failing integration test**

```elixir
defmodule Legend.Runtimes.LocalPtyTest do
  use ExUnit.Case, async: false

  alias Legend.Runtime.CommandSpec
  alias Legend.Runtimes.LocalPty

  test "id" do
    assert LocalPty.id() == "local_pty"
  end

  test "spawns a real PTY process, round-trips IO, resizes, and exits" do
    spec = %CommandSpec{cmd: "cat", args: [], env: %{"TERM" => "xterm-256color"}}
    assert {:ok, handle} = LocalPty.start(spec, %{owner: self(), cwd: "/tmp", rows: 24, cols: 80})

    :ok = LocalPty.write(handle, "hello\n")
    assert collect_output() =~ "hello"

    # Resize must not crash the process.
    :ok = LocalPty.resize(handle, 120, 40)

    :ok = LocalPty.stop(handle)
    assert_receive {:runtime_exit, _code_or_nil}, 10_000
  end

  test "missing executable returns an error without spawning" do
    spec = %CommandSpec{cmd: "definitely-not-a-real-binary-xyz", args: []}
    assert {:error, message} = LocalPty.start(spec, %{owner: self()})
    assert message =~ "definitely-not-a-real-binary-xyz"
  end

  test "process exiting on its own delivers its exit code" do
    spec = %CommandSpec{cmd: "sh", args: ["-c", "exit 3"]}
    assert {:ok, _handle} = LocalPty.start(spec, %{owner: self()})
    assert_receive {:runtime_exit, 3}, 10_000
  end

  defp collect_output(acc \\ "") do
    receive do
      {:runtime_output, data} ->
        acc = acc <> data
        if acc =~ "hello", do: acc, else: collect_output(acc)
    after
      5_000 -> flunk("no output received, got so far: #{inspect(acc)}")
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/legend/runtimes/local_pty_test.exs`
Expected: FAIL — `Legend.Runtimes.LocalPty` undefined.

- [ ] **Step 4: Implement LocalPty**

`backend/lib/legend/runtimes/local_pty.ex`:

```elixir
defmodule Legend.Runtimes.LocalPty do
  @moduledoc """
  Runs an agent CLI under a true PTY on the machine the backend runs on,
  via erlexec. A small relay process receives erlexec's stdout/DOWN messages
  and forwards them to the owner in the `Legend.Runtime` message contract;
  write/resize/stop go straight to the OS process via its os_pid.
  """

  @behaviour Legend.Runtime

  alias Legend.Runtime.CommandSpec

  @start_timeout 5_000

  @impl true
  def id, do: "local_pty"

  @impl true
  def start(%CommandSpec{} = spec, opts) do
    owner = Map.fetch!(opts, :owner)

    case System.find_executable(spec.cmd) do
      nil ->
        {:error, "executable not found on PATH: #{spec.cmd}"}

      path ->
        ensure_exec_started()
        caller = self()
        ref = make_ref()

        relay =
          spawn_link(fn ->
            run_and_relay(caller, ref, owner, [path | spec.args], spec, opts)
          end)

        receive do
          {^ref, {:ok, os_pid}} -> {:ok, %{os_pid: os_pid, relay: relay}}
          {^ref, {:error, reason}} -> {:error, "failed to start #{spec.cmd}: #{inspect(reason)}"}
        after
          @start_timeout -> {:error, "timed out starting #{spec.cmd}"}
        end
    end
  end

  @impl true
  def write(%{os_pid: os_pid}, data) do
    :exec.send(os_pid, data)
    :ok
  end

  @impl true
  def resize(%{os_pid: os_pid}, cols, rows) do
    :exec.winsz(os_pid, rows, cols)
    :ok
  end

  @impl true
  def stop(%{os_pid: os_pid}) do
    # SIGTERM, then SIGKILL after erlexec's kill_timeout. Exit reaches the
    # owner through the relay's DOWN message.
    :exec.stop(os_pid)
    :ok
  end

  defp run_and_relay(caller, ref, owner, argv, spec, opts) do
    run_opts =
      [
        :pty,
        {:stdout, self()},
        :monitor,
        {:env, Map.to_list(spec.env)},
        {:winsz, {opts[:rows] || 24, opts[:cols] || 80}},
        {:kill_timeout, 5}
      ] ++ cd_opt(opts)

    case :exec.run(argv, run_opts) do
      {:ok, _pid, os_pid} ->
        send(caller, {ref, {:ok, os_pid}})
        relay_loop(owner, os_pid)

      {:error, reason} ->
        send(caller, {ref, {:error, reason}})
    end
  end

  defp cd_opt(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: [{:cd, cwd}]
  defp cd_opt(_), do: []

  defp relay_loop(owner, os_pid) do
    receive do
      {:stdout, ^os_pid, data} ->
        send(owner, {:runtime_output, data})
        relay_loop(owner, os_pid)

      {:DOWN, ^os_pid, :process, _pid, reason} ->
        send(owner, {:runtime_exit, decode_exit(reason)})
    end
  end

  defp decode_exit(:normal), do: 0
  defp decode_exit({:exit_status, status}), do: decode_status(status)
  defp decode_exit({:status, status}), do: decode_status(status)
  defp decode_exit(_other), do: nil

  defp decode_status(status) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, _signal, _core_dumped} -> nil
    end
  end

  defp ensure_exec_started do
    case :exec.start([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/legend/runtimes/local_pty_test.exs`
Expected: PASS (4 tests). Notes for debugging if not:
- No output from `cat`: the PTY echoes input in canonical mode, so "hello" appears even before cat replies — if nothing arrives at all, check that `{:stdout, self()}` points at the relay (it must be inside `run_and_relay`).
- `{:runtime_exit, nil}` instead of `3` in the exit-code test: print the raw DOWN `reason` and extend `decode_exit/1` for the actual shape erlexec sends on this version.

- [ ] **Step 6: Full suite + commit**

Run: `mix test`
Expected: all green.

```bash
git add mix.exs mix.lock lib/legend/runtimes/ test/legend/runtimes/
git commit -m "feat: LocalPty runtime running agent CLIs under a real PTY via erlexec"
```

---

### Task 9: Session + lobby channels

**Files:**
- Create: `backend/lib/legend_web/channels/session_channel.ex`
- Create: `backend/lib/legend_web/channels/sessions_lobby_channel.ex`
- Modify: `backend/lib/legend_web/channels/user_socket.ex` (add two `channel` lines)
- Test: `backend/test/legend_web/channels/session_channel_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LegendWeb.SessionChannelTest do
  use LegendWeb.ChannelCase, async: false

  alias Legend.Agents
  alias Legend.Agents.SessionServer

  @valid %{harness_id: "claude_code", runtime_id: "test", cwd: "/tmp"}

  setup do
    Legend.TestRuntime.subscribe()

    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(Legend.Agents.SessionSupervisor) do
        DynamicSupervisor.terminate_child(Legend.Agents.SessionSupervisor, pid)
      end
    end)

    session = Agents.start_session!(@valid)
    %{session: session, server: SessionServer.whereis(session.id)}
  end

  defp join!(session) do
    {:ok, reply, socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SessionChannel, "session:#{session.id}")

    {reply, socket}
  end

  test "join replies with status and scrollback replay", %{session: session, server: server} do
    send(server, {:runtime_output, "earlier output"})
    # Wait until the server has buffered it.
    assert {:ok, %{buffer: "earlier output"}} = await_buffer(session.id, "earlier output")

    {reply, _socket} = join!(session)
    assert reply.status == "running"
    assert Base.decode64!(reply.buffer) == "earlier output"
  end

  test "output after join is pushed base64-encoded", %{session: session, server: server} do
    {_reply, _socket} = join!(session)
    send(server, {:runtime_output, "live"})
    assert_push "output", %{data: data}
    assert Base.decode64!(data) == "live"
  end

  test "input and resize are forwarded to the runtime", %{session: session} do
    {_reply, socket} = join!(session)

    push(socket, "input", %{"data" => "ls\n"})
    assert_receive {:test_runtime, :write, "ls\n"}

    push(socket, "resize", %{"cols" => 100, "rows" => 30})
    assert_receive {:test_runtime, :resize, 100, 30}
  end

  test "stop triggers runtime stop and an exit push", %{session: session} do
    {_reply, socket} = join!(session)
    push(socket, "stop", %{})
    assert_receive {:test_runtime, :stop}
    assert_push "exit", %{exit_code: nil}
  end

  test "joining a dead session falls back to the record", %{session: session} do
    SessionServer.ensure_stopped(session.id)
    Legend.Agents.Janitor.run()

    {reply, _socket} = join!(session)
    assert reply.status == "failed"
    assert reply.buffer == ""
    assert reply.error == "backend restarted"
  end

  test "joining an unknown session is rejected" do
    assert {:error, %{reason: "not found"}} =
             LegendWeb.UserSocket
             |> socket()
             |> subscribe_and_join(
               LegendWeb.SessionChannel,
               "session:00000000-0000-0000-0000-000000000000"
             )
  end

  test "lobby broadcasts changed on session lifecycle events" do
    {:ok, _reply, _socket} =
      LegendWeb.UserSocket
      |> socket()
      |> subscribe_and_join(LegendWeb.SessionsLobbyChannel, "sessions:lobby")

    Agents.start_session!(@valid)
    assert_push "changed", %{}
  end

  defp await_buffer(id, expected, attempts \\ 50) do
    case SessionServer.attach(id) do
      {:ok, %{buffer: ^expected}} = ok -> ok
      _ when attempts > 0 ->
        Process.sleep(10)
        await_buffer(id, expected, attempts - 1)
      other -> other
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend_web/channels/session_channel_test.exs`
Expected: FAIL — `LegendWeb.SessionChannel` undefined.

- [ ] **Step 3: Implement the channels**

`backend/lib/legend_web/channels/session_channel.ex`:

```elixir
defmodule LegendWeb.SessionChannel do
  @moduledoc """
  Live IO for one session. Join replies with the current status and a base64
  scrollback replay; `output` events carry base64 chunks. The `offset` filter
  drops PubSub chunks that are already contained in the join-time snapshot.
  """

  use LegendWeb, :channel

  alias Legend.Agents
  alias Legend.Agents.SessionServer

  @impl true
  def join("session:" <> id, _payload, socket) do
    case Agents.get_session(id) do
      {:ok, session} ->
        Phoenix.PubSub.subscribe(Legend.PubSub, "session:#{id}")
        {reply, offset} = attach_reply(session)
        {:ok, reply, assign(socket, session_id: id, offset: offset)}

      {:error, _} ->
        {:error, %{reason: "not found"}}
    end
  end

  defp attach_reply(session) do
    case SessionServer.attach(session.id) do
      {:ok, %{status: status, buffer: buffer, offset: offset}} ->
        {%{
           status: to_string(status),
           buffer: Base.encode64(buffer),
           exit_code: session.exit_code,
           error: session.error
         }, offset}

      {:error, :not_running} ->
        {%{
           status: to_string(session.status),
           buffer: "",
           exit_code: session.exit_code,
           error: session.error
         }, 0}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    SessionServer.write(socket.assigns.session_id, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket)
      when is_integer(cols) and is_integer(rows) and cols > 0 and rows > 0 do
    SessionServer.resize(socket.assigns.session_id, cols, rows)
    {:noreply, socket}
  end

  def handle_in("stop", _payload, socket) do
    SessionServer.stop(socket.assigns.session_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_output, chunk_offset, data}, socket) do
    if chunk_offset >= socket.assigns.offset do
      push(socket, "output", %{data: Base.encode64(data)})
      {:noreply, assign(socket, :offset, chunk_offset + byte_size(data))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_exit, exit_code}, socket) do
    push(socket, "exit", %{exit_code: exit_code})
    {:noreply, socket}
  end

  def handle_info({:session_status, status}, socket) do
    push(socket, "status", %{status: to_string(status)})
    {:noreply, socket}
  end
end
```

`backend/lib/legend_web/channels/sessions_lobby_channel.ex`:

```elixir
defmodule LegendWeb.SessionsLobbyChannel do
  @moduledoc "Notifies clients that the session list changed (they refetch via REST)."

  use LegendWeb, :channel

  @impl true
  def join("sessions:lobby", _payload, socket) do
    Phoenix.PubSub.subscribe(Legend.PubSub, Legend.Agents.Notifications.topic())
    {:ok, socket}
  end

  @impl true
  def handle_info(:sessions_changed, socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end
end
```

In `backend/lib/legend_web/channels/user_socket.ex`, below the `channel "chat:*"` line add:

```elixir
  channel "session:*", LegendWeb.SessionChannel
  channel "sessions:lobby", LegendWeb.SessionsLobbyChannel
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend_web/channels/session_channel_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Full suite + commit**

Run: `mix test`
Expected: all green.

```bash
git add lib/legend_web/channels/ test/legend_web/channels/session_channel_test.exs
git commit -m "feat: session IO channel with scrollback replay and lobby notifications"
```

---

### Task 10: GET /api/harnesses

**Files:**
- Create: `backend/lib/legend_web/controllers/harness_controller.ex`
- Modify: `backend/lib/legend_web/router.ex` (first `/api` scope — NEVER after the AshJsonApi forward)
- Test: `backend/test/legend_web/controllers/harness_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LegendWeb.HarnessControllerTest do
  use LegendWeb.ConnCase, async: true

  test "GET /api/harnesses lists registered harness definitions", %{conn: conn} do
    conn = get(conn, "/api/harnesses")

    assert %{"data" => harnesses} = json_response(conn, 200)
    ids = Enum.map(harnesses, & &1["id"]) |> Enum.sort()
    assert ids == ["claude_code", "hermes"]

    claude = Enum.find(harnesses, &(&1["id"] == "claude_code"))
    assert claude["name"] == "Claude Code"
    assert claude["kind"] == "terminal"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend_web/controllers/harness_controller_test.exs`
Expected: FAIL — 404 (route falls through to the AshJsonApi forward, which has no /harnesses).

- [ ] **Step 3: Implement controller and route**

`backend/lib/legend_web/controllers/harness_controller.ex`:

```elixir
defmodule LegendWeb.HarnessController do
  use LegendWeb, :controller

  def index(conn, _params) do
    data =
      for d <- Legend.Harness.Registry.list() do
        %{id: d.id, name: d.name, description: d.description, kind: d.kind}
      end

    json(conn, %{data: data})
  end
end
```

In `backend/lib/legend_web/router.ex`, in the **first** `/api` scope (the one with `HealthController`):

```elixir
    get "/health", HealthController, :show
    get "/harnesses", HarnessController, :index
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend_web/controllers/harness_controller_test.exs`
Expected: PASS.

- [ ] **Step 5: Backend wrap-up: precommit + commit**

Run: `mix precommit`
Expected: compiles with no warnings, format clean, full suite green. Fix anything it flags before committing.

```bash
git add lib/legend_web/controllers/harness_controller.ex lib/legend_web/router.ex test/legend_web/controllers/harness_controller_test.exs
git commit -m "feat: expose harness registry at GET /api/harnesses"
```

---

### Task 11: Frontend data layer + app shell (sidebar, new-session dialog)

**Files:**
- Create: `frontend/src/lib/sessions.ts`
- Create: `frontend/src/lib/stores/sessions.svelte.ts`
- Create: `frontend/src/lib/components/SessionSidebar.svelte`
- Create: `frontend/src/lib/components/NewSessionDialog.svelte`
- Modify: `frontend/src/routes/+layout.svelte`
- Modify: `frontend/src/routes/+page.svelte` (rewrite)
- Generated: `frontend/src/lib/components/ui/{dialog,select,input,label}/`

All frontend commands run from `frontend/`.

- [ ] **Step 1: Add shadcn components**

Run: `bunx shadcn-svelte@latest add dialog select input label`
Expected: components appear under `src/lib/components/ui/`. (No preset flag needed — `components.json` already pins the style.)

- [ ] **Step 2: API client**

`frontend/src/lib/sessions.ts`:

```ts
import { apiBase } from './api';

export type SessionStatus = 'starting' | 'running' | 'exited' | 'failed';

export interface Session {
	id: string;
	name: string | null;
	harness_id: string;
	runtime_id: string;
	cwd: string | null;
	status: SessionStatus;
	exit_code: number | null;
	error: string | null;
}

export interface Harness {
	id: string;
	name: string;
	description: string;
	kind: 'terminal' | 'acp' | 'native';
}

const JSONAPI = 'application/vnd.api+json';

interface JsonApiResource {
	id: string;
	attributes: Record<string, unknown>;
}

function toSession(resource: JsonApiResource): Session {
	return { id: resource.id, ...(resource.attributes as Omit<Session, 'id'>) };
}

export async function listHarnesses(): Promise<Harness[]> {
	const res = await fetch(`${apiBase}/api/harnesses`);
	if (!res.ok) throw new Error(`listing harnesses failed: ${res.status}`);
	return (await res.json()).data;
}

export async function listSessions(): Promise<Session[]> {
	const res = await fetch(`${apiBase}/api/sessions`, { headers: { Accept: JSONAPI } });
	if (!res.ok) throw new Error(`listing sessions failed: ${res.status}`);
	return (await res.json()).data.map(toSession);
}

export async function createSession(attrs: {
	harness_id: string;
	name?: string;
	cwd?: string;
}): Promise<Session> {
	const res = await fetch(`${apiBase}/api/sessions`, {
		method: 'POST',
		headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
		body: JSON.stringify({ data: { type: 'session', attributes: attrs } })
	});
	if (!res.ok) throw new Error(`creating session failed: ${res.status}`);
	return toSession((await res.json()).data);
}

export async function deleteSession(id: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/sessions/${id}`, {
		method: 'DELETE',
		headers: { Accept: JSONAPI }
	});
	if (!res.ok && res.status !== 204) throw new Error(`deleting session failed: ${res.status}`);
}
```

- [ ] **Step 3: Reactive session store**

`frontend/src/lib/stores/sessions.svelte.ts`:

```ts
import { listSessions, type Session } from '$lib/sessions';
import { getSocket } from '$lib/socket';
import type { Channel } from 'phoenix';

class SessionsStore {
	sessions = $state<Session[]>([]);
	loaded = $state(false);
	#channel: Channel | undefined;

	async refresh(): Promise<void> {
		try {
			this.sessions = await listSessions();
			this.loaded = true;
		} catch {
			// Backend unreachable; sidebar shows the last known list.
		}
	}

	/** Joins the lobby once; refetches the list whenever the backend says it changed. */
	connect(): void {
		if (this.#channel) return;
		this.#channel = getSocket().channel('sessions:lobby');
		this.#channel.on('changed', () => void this.refresh());
		this.#channel.join();
		void this.refresh();
	}
}

export const sessionsStore = new SessionsStore();
```

- [ ] **Step 4: New-session dialog**

`frontend/src/lib/components/NewSessionDialog.svelte`:

```svelte
<script lang="ts">
	import { goto } from '$app/navigation';
	import * as Dialog from '$lib/components/ui/dialog';
	import * as Select from '$lib/components/ui/select';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { createSession, listHarnesses, type Harness } from '$lib/sessions';

	let open = $state(false);
	let harnesses = $state<Harness[]>([]);
	let harnessId = $state('');
	let name = $state('');
	let cwd = $state('');
	let error = $state('');
	let creating = $state(false);

	const selectedHarness = $derived(harnesses.find((h) => h.id === harnessId));

	async function openDialog() {
		error = '';
		open = true;
		try {
			harnesses = await listHarnesses();
			harnessId = harnesses[0]?.id ?? '';
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load harnesses';
		}
	}

	async function create() {
		if (!harnessId) return;
		creating = true;
		error = '';
		try {
			const session = await createSession({
				harness_id: harnessId,
				...(name.trim() ? { name: name.trim() } : {}),
				...(cwd.trim() ? { cwd: cwd.trim() } : {})
			});
			open = false;
			name = '';
			cwd = '';
			await goto(`/sessions/${session.id}`);
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to create session';
		} finally {
			creating = false;
		}
	}
</script>

<Button class="w-full" onclick={openDialog}>New session</Button>

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title>New session</Dialog.Title>
			<Dialog.Description>Launch an agent in a fresh terminal session.</Dialog.Description>
		</Dialog.Header>

		<div class="flex flex-col gap-4">
			<div class="flex flex-col gap-2">
				<Label for="harness">Harness</Label>
				<Select.Root type="single" bind:value={harnessId}>
					<Select.Trigger id="harness" class="w-full">
						{selectedHarness?.name ?? 'Pick a harness'}
					</Select.Trigger>
					<Select.Content>
						{#each harnesses as harness (harness.id)}
							<Select.Item value={harness.id} label={harness.name} />
						{/each}
					</Select.Content>
				</Select.Root>
			</div>

			<div class="flex flex-col gap-2">
				<Label for="name">Name (optional)</Label>
				<Input id="name" bind:value={name} placeholder="e.g. refactor sprint" />
			</div>

			<div class="flex flex-col gap-2">
				<Label for="cwd">Working directory</Label>
				<Input id="cwd" bind:value={cwd} placeholder="defaults to your home directory" />
			</div>

			{#if error}
				<p class="text-sm text-destructive">{error}</p>
			{/if}
		</div>

		<Dialog.Footer>
			<Button onclick={create} disabled={creating || !harnessId}>
				{creating ? 'Starting…' : 'Start session'}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
```

- [ ] **Step 5: Sidebar**

`frontend/src/lib/components/SessionSidebar.svelte`:

```svelte
<script lang="ts">
	import { page } from '$app/state';
	import NewSessionDialog from '$lib/components/NewSessionDialog.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import type { SessionStatus } from '$lib/sessions';

	$effect(() => {
		sessionsStore.connect();
	});

	const dotClass: Record<SessionStatus, string> = {
		starting: 'bg-amber-500',
		running: 'bg-emerald-500',
		exited: 'bg-zinc-400',
		failed: 'bg-red-500'
	};
</script>

<aside class="flex w-64 shrink-0 flex-col gap-3 border-r p-3">
	<NewSessionDialog />

	<nav class="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto">
		{#each sessionsStore.sessions as session (session.id)}
			<a
				href={`/sessions/${session.id}`}
				class="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-accent
					{page.params.id === session.id ? 'bg-accent' : ''}"
			>
				<span class="size-2 shrink-0 rounded-full {dotClass[session.status]}"></span>
				<span class="truncate">{session.name || session.harness_id}</span>
				<span class="ml-auto shrink-0 text-xs text-muted-foreground">{session.harness_id}</span>
			</a>
		{:else}
			{#if sessionsStore.loaded}
				<p class="px-2 py-1.5 text-sm text-muted-foreground">No sessions yet.</p>
			{/if}
		{/each}
	</nav>
</aside>
```

- [ ] **Step 6: App shell + home page**

Replace `frontend/src/routes/+layout.svelte` with:

```svelte
<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import SessionSidebar from '$lib/components/SessionSidebar.svelte';

	let { children } = $props();

	// True inside the Tauri webview (desktop app), false in the browser.
	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>

<div class="flex h-dvh flex-col">
	{#if isTauri}
		<!-- Title bar stand-in: the macOS traffic lights overlay this strip
		     (titleBarStyle: Overlay); it doubles as the window drag handle. -->
		<header data-tauri-drag-region class="h-10 w-full shrink-0 select-none"></header>
	{/if}
	<div class="flex min-h-0 flex-1">
		<SessionSidebar />
		<main class="min-w-0 flex-1">{@render children()}</main>
	</div>
</div>
```

Replace `frontend/src/routes/+page.svelte` with:

```svelte
<div class="flex h-full items-center justify-center">
	<p class="text-muted-foreground">Select a session or start a new one.</p>
</div>
```

(The scaffold's health/chat demo is superseded; `chat:*` stays available on the backend for future rooms.)

- [ ] **Step 7: Verify**

Run: `bun run check`
Expected: 0 errors, 0 warnings.

- [ ] **Step 8: Commit**

```bash
git add src/lib/sessions.ts src/lib/stores/ src/lib/components/ src/routes/+layout.svelte src/routes/+page.svelte package.json bun.lock
git commit -m "feat: session sidebar, store, and new-session dialog"
```

---

### Task 12: Terminal component + session page

**Files:**
- Create: `frontend/src/lib/components/Terminal.svelte`
- Create: `frontend/src/routes/sessions/[id]/+page.svelte`
- Modify: `frontend/package.json` (xterm deps)

- [ ] **Step 1: Add xterm**

Run (from `frontend/`): `bun add @xterm/xterm @xterm/addon-fit`

- [ ] **Step 2: Terminal component**

`frontend/src/lib/components/Terminal.svelte`:

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import { Terminal } from '@xterm/xterm';
	import { FitAddon } from '@xterm/addon-fit';
	import '@xterm/xterm/css/xterm.css';
	import { getSocket } from '$lib/socket';
	import type { Channel } from 'phoenix';
	import type { SessionStatus } from '$lib/sessions';

	interface JoinReply {
		status: SessionStatus;
		buffer: string;
		exit_code: number | null;
		error: string | null;
	}

	let {
		sessionId,
		onstatus
	}: {
		sessionId: string;
		onstatus?: (status: SessionStatus, exitCode: number | null, error: string | null) => void;
	} = $props();

	let container: HTMLDivElement;
	let channel: Channel | undefined;

	/** Ask the backend to terminate the agent process (graceful, then SIGKILL). */
	export function requestStop(): void {
		channel?.push('stop', {});
	}

	function b64ToBytes(b64: string): Uint8Array {
		const bin = atob(b64);
		const bytes = new Uint8Array(bin.length);
		for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
		return bytes;
	}

	onMount(() => {
		const term = new Terminal({
			cursorBlink: true,
			fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
			fontSize: 13,
			theme: { background: '#0a0a0a' }
		});
		const fit = new FitAddon();
		term.loadAddon(fit);
		term.open(container);
		fit.fit();

		const chan = getSocket().channel(`session:${sessionId}`);
		channel = chan;

		term.onData((data) => chan.push('input', { data }));
		term.onResize(({ cols, rows }) => chan.push('resize', { cols, rows }));

		chan.on('output', ({ data }: { data: string }) => term.write(b64ToBytes(data)));
		chan.on('exit', ({ exit_code }: { exit_code: number | null }) =>
			onstatus?.('exited', exit_code, null)
		);
		chan.on('status', ({ status }: { status: SessionStatus }) => onstatus?.(status, null, null));

		chan
			.join()
			.receive('ok', (reply: JoinReply) => {
				if (reply.buffer) term.write(b64ToBytes(reply.buffer));
				onstatus?.(reply.status, reply.exit_code, reply.error);
				chan.push('resize', { cols: term.cols, rows: term.rows });
				term.focus();
			})
			.receive('error', () => onstatus?.('failed', null, 'could not join session'));

		const observer = new ResizeObserver(() => fit.fit());
		observer.observe(container);

		return () => {
			observer.disconnect();
			chan.leave();
			term.dispose();
			channel = undefined;
		};
	});
</script>

<div bind:this={container} class="h-full w-full bg-[#0a0a0a]"></div>
```

- [ ] **Step 3: Session page**

`frontend/src/routes/sessions/[id]/+page.svelte`:

```svelte
<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import Terminal from '$lib/components/Terminal.svelte';
	import { Button } from '$lib/components/ui/button';
	import { deleteSession, type SessionStatus } from '$lib/sessions';

	const sessionId = $derived(page.params.id!);

	let status = $state<SessionStatus | null>(null);
	let exitCode = $state<number | null>(null);
	let error = $state<string | null>(null);
	let terminal = $state<ReturnType<typeof Terminal> | null>(null);

	function handleStatus(s: SessionStatus, code: number | null, err: string | null) {
		status = s;
		exitCode = code;
		error = err;
	}

	async function remove() {
		await deleteSession(sessionId);
		await goto('/');
	}
</script>

<div class="flex h-full flex-col">
	<div class="flex items-center gap-2 border-b px-3 py-2">
		<span class="text-sm text-muted-foreground">
			{status ?? 'connecting…'}{#if status === 'exited' && exitCode !== null}&nbsp;(exit {exitCode}){/if}
		</span>
		{#if error}
			<span class="truncate text-sm text-destructive">{error}</span>
		{/if}
		<div class="ml-auto flex gap-2">
			{#if status === 'running' || status === 'starting'}
				<Button variant="outline" size="sm" onclick={() => terminal?.requestStop()}>Stop</Button>
			{:else}
				<Button variant="destructive" size="sm" onclick={remove}>Delete</Button>
			{/if}
		</div>
	</div>

	<div class="min-h-0 flex-1">
		{#key sessionId}
			<Terminal bind:this={terminal} {sessionId} onstatus={handleStatus} />
		{/key}
	</div>
</div>
```

- [ ] **Step 4: Verify**

Run: `bun run check`
Expected: 0 errors, 0 warnings.

Manual smoke (two terminals):
1. `just dev` (repo root)
2. Open http://localhost:5173 → New session → harness "Claude Code" → Start. The terminal should show Claude Code's TUI; type into it.
3. Navigate to `/`, then back to the session — scrollback replays.
4. Reload the browser tab mid-session — the session is still in the sidebar as running; opening it reattaches.
5. Stop → status flips to exited with the frozen scrollback → Delete returns to `/`.

- [ ] **Step 5: Commit**

```bash
git add src/lib/components/Terminal.svelte src/routes/sessions/ package.json bun.lock
git commit -m "feat: xterm terminal component and session page with reattach"
```

---

### Task 13: Docs, full verification, smoke

**Files:**
- Modify: `CLAUDE.md` (Ash bullet under Architecture/Backend; commands stay accurate)
- Modify: `README.md` (env vars; brief agent-sessions blurb in the feature/overview area)

- [ ] **Step 1: Update CLAUDE.md**

In the Ash bullet, replace the sentence "There are no domains yet — new features start by creating an Ash domain + resource (AshSqlite data layer) and adding it to `ash_domains`." with:

```markdown
First domain: `Legend.Agents` (sessions at `/api/sessions`). New features add an Ash domain + resource (AshSqlite data layer) and register it in `ash_domains`. Agent sessions: harness/runtime plugin registries live in `config :legend, :harnesses / :runtimes`; live session IO flows over `session:<id>` channels (see `docs/superpowers/specs/2026-06-11-agent-sessions-poc-design.md`).
```

- [ ] **Step 2: Update README**

In the Setup section after the `.env` copy instructions, add:

```markdown
Agent harness commands are configurable in `backend/.env` (`HARNESS_CLAUDE_CMD`,
`HARNESS_HERMES_CMD`) — set these if `claude`/`hermes` aren't on your PATH or
need flags. Sessions spawn these CLIs under a PTY on the machine the backend
runs on.
```

- [ ] **Step 3: Full verification**

Run from repo root: `just test`
Expected: backend suite green, svelte-check 0 errors.

Run from `backend/`: `mix precommit`
Expected: clean.

- [ ] **Step 4: Desktop sanity (erlexec in the release)**

Run from repo root: `just package-backend`
Expected: Burrito build succeeds (erlexec's `exec-port` ships in priv). Then `just dev-desktop` and create one session to confirm the PTY spawns from the Tauri-context backend in dev mode.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: agent sessions usage and harness command configuration"
```
