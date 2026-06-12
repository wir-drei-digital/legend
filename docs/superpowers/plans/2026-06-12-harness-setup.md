# Harness Setup Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A generic, consent-gated harness setup seam — optional `setup/0` + `apply_setup/0` harness callbacks surfaced through `/api/harnesses` — with Hermes MCP registration (`~/.hermes/config.yaml` entry) as the first implementation.

**Architecture:** `Legend.Core.Harness` gains a self-describing `Setup` struct and two optional callbacks (same pattern as `nudge_line`). `Legend.Harnesses.Hermes.McpSetup` does the real work: detect/write the `mcp_servers.legend` entry via a YAML round-trip with backup + atomic write. The existing `GET /api/harnesses` carries each harness's setup object; a new `POST /api/harnesses/:id/setup` applies it. Frontend renders only harness-provided fields in two surfaces: an inline notice in the new-session dialog (localStorage dismissal) and a "Harness integrations" section at `/settings`.

**Tech Stack:** Elixir 1.20 / Phoenix 1.8 (plain controller, first router scope), `yaml_elixir` (read) + `ymlr` (write), SvelteKit 2 / Svelte 5 runes / shadcn-svelte.

**Spec:** `docs/superpowers/specs/2026-06-12-harness-setup-design.md` — read it first.

**Worth knowing before you start:**
- Run all backend commands from `backend/`, frontend from `frontend/` (Bun, not npm).
- `mix precommit` = compile --warnings-as-errors + format + test. Run before finishing any backend task.
- Registry ids are string-compared, never `String.to_atom` (security rule).
- The first `/api` router scope is load-bearing: new plain endpoints go there, never after the AshJsonApi forward.
- `window.confirm` is a no-op in Tauri — in-UI buttons only.
- Test config must guarantee tests never read/write the real `~/.hermes` (the `library_default_root` precedent).
- The `${LEGEND_MCP_URL}`/`${LEGEND_SESSION_TOKEN}` strings are **literal placeholders** — Hermes interpolates them from each spawned process's env at connect time. Never "fix" them into real values.

---

## File structure

| File | Responsibility |
|---|---|
| `backend/mix.exs` (modify) | add `yaml_elixir`, `ymlr` deps |
| `backend/lib/legend/core/harness.ex` (modify) | `Setup` struct, optional callbacks, `setup_for/1` |
| `backend/lib/legend/core/harness/registry.ex` (modify) | `entries/0` ({module, definition} pairs) |
| `backend/lib/legend/harnesses/hermes/mcp_setup.ex` (create) | detect/apply the config.yaml entry |
| `backend/lib/legend/harnesses/hermes.ex` (modify) | export the two callbacks (delegate to McpSetup) |
| `backend/lib/legend_web/controllers/harness_controller.ex` (modify) | `setup` field in index; `apply_setup` action |
| `backend/lib/legend_web/router.ex` (modify) | `post "/harnesses/:id/setup"` in first scope |
| `backend/config/test.exs` (modify) | pin `:hermes_home` to a nonexistent path |
| `backend/test/legend/harnesses/hermes_mcp_setup_test.exs` (create) | McpSetup unit tests (tmp dirs) |
| `backend/test/legend/harnesses_test.exs` (modify) | `setup_for/1` contract tests |
| `backend/test/legend_web/controllers/harness_controller_test.exs` (modify) | setup field + POST round-trip |
| `frontend/src/lib/sessions.ts` (modify) | `HarnessSetup` type, `setup` field, `applyHarnessSetup`, dismissal helpers |
| `frontend/src/lib/components/NewSessionDialog.svelte` (modify) | inline setup notice |
| `frontend/src/routes/settings/+page.svelte` (modify) | Harness integrations section |
| `docs/ARCHITECTURE.md`, `CLAUDE.md` (modify) | record the seam |

---

### Task 1: Setup struct, optional callbacks, registry entries

**Files:**
- Modify: `backend/mix.exs` (deps, around line 62)
- Modify: `backend/lib/legend/core/harness.ex`
- Modify: `backend/lib/legend/core/harness/registry.ex`
- Test: `backend/test/legend/harnesses_test.exs` (append a describe block)

- [ ] **Step 1: Add the YAML deps**

In `backend/mix.exs`, inside `defp deps do`, after the `{:corsica, "~> 2.1"},` line add:

```elixir
      {:yaml_elixir, "~> 2.11"},
      {:ymlr, "~> 5.0"},
```

Run: `cd backend && mix deps.get`
Expected: both deps resolve and lock.

- [ ] **Step 2: Write the failing contract tests**

Append to `backend/test/legend/harnesses_test.exs` (inside the top-level module, after existing describes; match the file's existing aliasing style):

```elixir
  describe "setup seam" do
    test "setup_for/1 on a harness without the callbacks is not_applicable" do
      assert %Legend.Core.Harness.Setup{status: :not_applicable} =
               Legend.Core.Harness.setup_for(Legend.Harnesses.ClaudeCode)
    end

    test "setup_for/1 on a harness exporting setup/0 calls through" do
      defmodule WithSetup do
        @behaviour Legend.Core.Harness

        @impl Legend.Core.Harness
        def definition,
          do: %Legend.Core.Harness.Definition{id: "with_setup", name: "With Setup", kind: :terminal}

        @impl Legend.Core.Harness
        def setup,
          do: %Legend.Core.Harness.Setup{status: :missing, summary: "do the thing"}
      end

      assert %Legend.Core.Harness.Setup{status: :missing, summary: "do the thing"} =
               Legend.Core.Harness.setup_for(WithSetup)
    end

    test "registry entries pair modules with definitions" do
      entries = Legend.Core.Harness.Registry.entries()
      assert {Legend.Harnesses.ClaudeCode, %Legend.Core.Harness.Definition{id: "claude_code"}} =
               Enum.find(entries, fn {mod, _} -> mod == Legend.Harnesses.ClaudeCode end)
    end
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `cd backend && mix test test/legend/harnesses_test.exs`
Expected: FAIL — `Legend.Core.Harness.Setup.__struct__/1 is undefined` (and/or `setup_for/1` undefined).

- [ ] **Step 4: Implement struct, callbacks, helper, registry entries**

Replace the full contents of `backend/lib/legend/core/harness.ex` with:

```elixir
defmodule Legend.Core.Harness do
  @moduledoc """
  An agent type Legend can run. `kind` determines the transport and UI:
  `:terminal` (PTY + xterm, implemented), `:acp` and `:native` (reserved).
  Terminal harnesses additionally implement `Legend.Core.Harness.Terminal`.

  Harnesses may export the optional setup callbacks when they need one-time
  host-machine configuration (e.g. Hermes' MCP registration). `setup/0` is
  self-describing — the UI renders only what the harness reports — and
  `apply_setup/0` is only ever invoked from an explicit user action (consent).
  """

  defmodule Definition do
    @enforce_keys [:id, :name, :kind]
    defstruct [:id, :name, :kind, description: "", resumable: false]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t(),
            description: String.t(),
            kind: :terminal | :acp | :native,
            resumable: boolean()
          }
  end

  defmodule Setup do
    @moduledoc """
    Self-describing setup state. `summary` says what Apply will do;
    `detail` carries an error explanation or manual-fix snippet;
    `restart_hint` tells the UI that running sessions need a restart
    to pick the setup up.
    """
    @derive Jason.Encoder
    defstruct status: :not_applicable, summary: "", detail: nil, restart_hint: false

    @type t :: %__MODULE__{
            status: :ok | :missing | :error | :not_applicable,
            summary: String.t(),
            detail: String.t() | nil,
            restart_hint: boolean()
          }
  end

  @callback definition() :: Definition.t()
  @callback setup() :: Setup.t()
  @callback apply_setup() :: :ok | {:error, String.t()}
  @optional_callbacks setup: 0, apply_setup: 0

  @doc "The harness's setup state; harnesses without the callback are not_applicable."
  @spec setup_for(module()) :: Setup.t()
  def setup_for(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :setup, 0) do
      module.setup()
    else
      %Setup{}
    end
  end
end
```

In `backend/lib/legend/core/harness/registry.ex`, add below `list/0`:

```elixir
  @spec entries() :: [{module(), Definition.t()}]
  def entries, do: Enum.map(modules(), &{&1, &1.definition()})
```

- [ ] **Step 5: Run tests, verify pass**

Run: `cd backend && mix test test/legend/harnesses_test.exs`
Expected: PASS (all, including pre-existing).

- [ ] **Step 6: Commit**

```bash
git add backend/mix.exs backend/mix.lock backend/lib/legend/core/harness.ex backend/lib/legend/core/harness/registry.ex backend/test/legend/harnesses_test.exs
git commit -m "feat: optional harness setup callbacks + self-describing Setup struct"
```

---

### Task 2: Hermes McpSetup module

**Files:**
- Create: `backend/lib/legend/harnesses/hermes/mcp_setup.ex`
- Test: `backend/test/legend/harnesses/hermes_mcp_setup_test.exs` (create; also create the `test/legend/harnesses/` dir)

All functions take an explicit `home` argument so tests use tmp dirs without env/config mutation (async-safe). The no-arg heads used by the harness callbacks resolve the default.

- [ ] **Step 1: Write the failing tests**

Create `backend/test/legend/harnesses/hermes_mcp_setup_test.exs`:

```elixir
defmodule Legend.Harnesses.Hermes.McpSetupTest do
  use ExUnit.Case, async: true

  alias Legend.Core.Harness.Setup
  alias Legend.Harnesses.Hermes.McpSetup

  @entry %{
    "url" => "${LEGEND_MCP_URL}",
    "headers" => %{"Authorization" => "Bearer ${LEGEND_SESSION_TOKEN}"}
  }

  defp config_path(home), do: Path.join(home, "config.yaml")

  test "nonexistent home dir is not_applicable", %{} do
    assert %Setup{status: :not_applicable} = McpSetup.setup("/nonexistent/hermes-home")
  end

  @tag :tmp_dir
  test "home dir without config.yaml is missing; apply creates the file", %{tmp_dir: home} do
    assert %Setup{status: :missing, summary: summary, restart_hint: true} = McpSetup.setup(home)
    assert summary =~ "config.yaml"

    assert :ok = McpSetup.apply_setup(home)
    assert %Setup{status: :ok} = McpSetup.setup(home)

    {:ok, config} = YamlElixir.read_from_file(config_path(home))
    assert config["mcp_servers"]["legend"] == @entry
  end

  @tag :tmp_dir
  test "apply preserves unrelated config and writes a backup", %{tmp_dir: home} do
    File.write!(config_path(home), """
    default_model: anthropic/claude-sonnet-4
    mcp_servers:
      time:
        command: uvx
        args: ["mcp-server-time"]
    """)

    assert %Setup{status: :missing} = McpSetup.setup(home)
    assert :ok = McpSetup.apply_setup(home)

    {:ok, config} = YamlElixir.read_from_file(config_path(home))
    assert config["default_model"] == "anthropic/claude-sonnet-4"
    assert config["mcp_servers"]["time"]["command"] == "uvx"
    assert config["mcp_servers"]["legend"] == @entry

    backup = config_path(home) <> ".legend-backup"
    assert File.read!(backup) =~ "default_model: anthropic/claude-sonnet-4"
    refute File.read!(backup) =~ "legend"
  end

  @tag :tmp_dir
  test "existing legend entry is ok; apply is idempotent", %{tmp_dir: home} do
    File.write!(config_path(home), """
    mcp_servers:
      legend:
        url: ${LEGEND_MCP_URL}
        headers:
          Authorization: Bearer ${LEGEND_SESSION_TOKEN}
    """)

    assert %Setup{status: :ok} = McpSetup.setup(home)
    assert :ok = McpSetup.apply_setup(home)
    assert %Setup{status: :ok} = McpSetup.setup(home)

    {:ok, config} = YamlElixir.read_from_file(config_path(home))
    assert config["mcp_servers"]["legend"] == @entry
  end

  @tag :tmp_dir
  test "malformed yaml is error with manual snippet; apply refuses and leaves the file alone",
       %{tmp_dir: home} do
    File.write!(config_path(home), "mcp_servers: [unclosed\n  bad: {indent")
    original = File.read!(config_path(home))

    assert %Setup{status: :error, detail: detail} = McpSetup.setup(home)
    assert detail =~ "mcp_servers:"
    assert detail =~ "${LEGEND_MCP_URL}"

    assert {:error, _reason} = McpSetup.apply_setup(home)
    assert File.read!(config_path(home)) == original
    refute File.exists?(config_path(home) <> ".legend-backup")
  end

  @tag :tmp_dir
  test "config that parses to a non-map is error", %{tmp_dir: home} do
    File.write!(config_path(home), "- just\n- a\n- list\n")
    assert %Setup{status: :error} = McpSetup.setup(home)
    assert {:error, _} = McpSetup.apply_setup(home)
  end

  @tag :tmp_dir
  test "apply on a nonexistent home errors", %{tmp_dir: home} do
    missing = Path.join(home, "nope")
    assert {:error, reason} = McpSetup.apply_setup(missing)
    assert reason =~ "not found"
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd backend && mix test test/legend/harnesses/hermes_mcp_setup_test.exs`
Expected: FAIL — `Legend.Harnesses.Hermes.McpSetup` is undefined.

- [ ] **Step 3: Implement McpSetup**

Create `backend/lib/legend/harnesses/hermes/mcp_setup.ex`:

```elixir
defmodule Legend.Harnesses.Hermes.McpSetup do
  @moduledoc """
  One-time Legend MCP registration in Hermes' config (`$HERMES_HOME/config.yaml`,
  default `~/.hermes`). Hermes has no per-launch MCP flag; it resolves `${VAR}`
  placeholders from each spawned process's environment, so a single static
  entry serves every session with its own per-session identity token. The
  placeholders below are LITERAL — never substitute real values into the file.

  Apply does a YAML round-trip (accepted tradeoff: comments/key order are lost,
  same as Hermes' own `hermes mcp add`), with `config.yaml.legend-backup`
  written first and an atomic tmp+rename write.
  """

  alias Legend.Core.Harness.Setup

  @entry %{
    "url" => "${LEGEND_MCP_URL}",
    "headers" => %{"Authorization" => "Bearer ${LEGEND_SESSION_TOKEN}"}
  }

  @manual_snippet """
  mcp_servers:
    legend:
      url: ${LEGEND_MCP_URL}
      headers:
        Authorization: Bearer ${LEGEND_SESSION_TOKEN}
  """

  @spec setup(Path.t()) :: Setup.t()
  def setup(home \\ home()) do
    cond do
      not File.dir?(home) ->
        %Setup{status: :not_applicable}

      not File.exists?(config_path(home)) ->
        %Setup{status: :missing, summary: summary(home), restart_hint: true}

      true ->
        case read_config(home) do
          {:ok, config} ->
            status = if get_in(config, ["mcp_servers", "legend"]), do: :ok, else: :missing
            %Setup{status: status, summary: summary(home), restart_hint: true}

          {:error, reason} ->
            %Setup{
              status: :error,
              summary: summary(home),
              detail: error_detail(home, reason),
              restart_hint: true
            }
        end
    end
  end

  # Backup comes after put_entry: a refused apply must leave no backup file.
  @spec apply_setup(Path.t()) :: :ok | {:error, String.t()}
  def apply_setup(home \\ home()) do
    path = config_path(home)

    with :ok <- ensure_home(home),
         {:ok, config} <- read_config_or_empty(home),
         {:ok, updated} <- put_entry(config),
         :ok <- backup(path),
         :ok <- write_atomically(path, Ymlr.document!(updated)) do
      :ok
    end
  end

  defp home do
    Application.get_env(:legend, :hermes_home) ||
      System.get_env("HERMES_HOME") ||
      Path.expand("~/.hermes")
  end

  defp config_path(home), do: Path.join(home, "config.yaml")

  defp summary(home),
    do: "Register Legend's agent tools (MCP) in #{config_path(home)}"

  defp ensure_home(home) do
    if File.dir?(home), do: :ok, else: {:error, "Hermes home not found at #{home}"}
  end

  defp read_config(home) do
    case YamlElixir.read_from_file(config_path(home)) do
      {:ok, nil} -> {:ok, %{}}
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _other} -> {:error, "config.yaml is not a YAML mapping"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp read_config_or_empty(home) do
    if File.exists?(config_path(home)), do: read_config(home), else: {:ok, %{}}
  end

  # A parseable config can still have a non-map mcp_servers (e.g. a string) —
  # refuse rather than raise.
  defp put_entry(config) do
    case Map.get(config, "mcp_servers") do
      servers when is_map(servers) ->
        {:ok, Map.put(config, "mcp_servers", Map.put(servers, "legend", @entry))}

      nil ->
        {:ok, Map.put(config, "mcp_servers", %{"legend" => @entry})}

      _other ->
        {:error, "mcp_servers in config.yaml is not a mapping"}
    end
  end

  defp backup(path) do
    if File.exists?(path) do
      case File.copy(path, path <> ".legend-backup") do
        {:ok, _} -> :ok
        {:error, posix} -> {:error, "backup failed: #{posix}"}
      end
    else
      :ok
    end
  end

  # Same-dir tmp file + rename: readers never observe a half-written config.
  defp write_atomically(path, contents) do
    tmp = path <> ".legend-tmp"

    with :ok <- file_result(File.write(tmp, contents), "write failed"),
         :ok <- file_result(File.rename(tmp, path), "rename failed") do
      :ok
    end
  end

  defp file_result(:ok, _label), do: :ok
  defp file_result({:error, posix}, label), do: {:error, "#{label}: #{posix}"}

  defp error_detail(home, reason) do
    """
    Could not parse #{config_path(home)} (#{reason}).
    Add this entry manually:

    #{@manual_snippet}
    """
  end
end
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd backend && mix test test/legend/harnesses/hermes_mcp_setup_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend/harnesses/hermes/mcp_setup.ex backend/test/legend/harnesses/hermes_mcp_setup_test.exs
git commit -m "feat: Hermes MCP registration setup (yaml round-trip, backup, atomic write)"
```

---

### Task 3: Wire Hermes callbacks + API endpoint

**Files:**
- Modify: `backend/lib/legend/harnesses/hermes.ex`
- Modify: `backend/lib/legend_web/controllers/harness_controller.ex`
- Modify: `backend/lib/legend_web/router.ex` (first `/api` scope)
- Modify: `backend/config/test.exs`
- Test: `backend/test/legend_web/controllers/harness_controller_test.exs`

- [ ] **Step 1: Pin hermes_home in test config**

In `backend/config/test.exs`, alongside the existing `:legend` config, add:

```elixir
# Tests must never read or write the real ~/.hermes. Controller tests that
# need a real dir override this per-test with Application.put_env/3.
config :legend, hermes_home: "/nonexistent/hermes-home-test"
```

- [ ] **Step 2: Write the failing controller tests**

Replace the full contents of `backend/test/legend_web/controllers/harness_controller_test.exs` with (note `async: false` — the new tests mutate the `:hermes_home` app env):

```elixir
defmodule LegendWeb.HarnessControllerTest do
  use LegendWeb.ConnCase, async: false

  test "GET /api/harnesses lists registered harness definitions", %{conn: conn} do
    conn = get(conn, "/api/harnesses")

    assert %{"data" => harnesses} = json_response(conn, 200)
    ids = Enum.map(harnesses, & &1["id"]) |> Enum.sort()
    assert ids == ["claude_code", "hermes"]

    claude = Enum.find(harnesses, &(&1["id"] == "claude_code"))
    assert claude["name"] == "Claude Code"
    assert claude["kind"] == "terminal"
  end

  test "harness payload includes resumable", %{conn: conn} do
    data = json_response(get(conn, ~p"/api/harnesses"), 200)["data"]
    claude = Enum.find(data, &(&1["id"] == "claude_code"))
    hermes = Enum.find(data, &(&1["id"] == "hermes"))
    assert claude["resumable"] == true
    assert hermes["resumable"] == false
  end

  describe "setup" do
    setup do
      home = Path.join(System.tmp_dir!(), "legend-hermes-home-#{System.unique_integer([:positive])}")
      File.mkdir_p!(home)
      previous = Application.get_env(:legend, :hermes_home)
      Application.put_env(:legend, :hermes_home, home)

      on_exit(fn ->
        Application.put_env(:legend, :hermes_home, previous)
        File.rm_rf!(home)
      end)

      %{home: home}
    end

    test "GET /api/harnesses carries the setup object", %{conn: conn} do
      data = json_response(get(conn, ~p"/api/harnesses"), 200)["data"]

      hermes = Enum.find(data, &(&1["id"] == "hermes"))
      assert hermes["setup"]["status"] == "missing"
      assert hermes["setup"]["summary"] =~ "config.yaml"
      assert hermes["setup"]["restart_hint"] == true

      claude = Enum.find(data, &(&1["id"] == "claude_code"))
      assert claude["setup"]["status"] == "not_applicable"
    end

    test "POST /api/harnesses/hermes/setup applies and returns fresh status", %{conn: conn, home: home} do
      conn = post(conn, ~p"/api/harnesses/hermes/setup")
      assert %{"data" => %{"status" => "ok"}} = json_response(conn, 200)
      assert File.exists?(Path.join(home, "config.yaml"))

      data = json_response(get(build_conn(), ~p"/api/harnesses"), 200)["data"]
      hermes = Enum.find(data, &(&1["id"] == "hermes"))
      assert hermes["setup"]["status"] == "ok"
    end

    test "POST for an unknown harness is 404", %{conn: conn} do
      conn = post(conn, ~p"/api/harnesses/nope/setup")
      assert %{"error" => _} = json_response(conn, 404)
    end

    test "POST for a harness without setup is 422", %{conn: conn} do
      conn = post(conn, ~p"/api/harnesses/claude_code/setup")
      assert %{"error" => _} = json_response(conn, 422)
    end

    test "POST surfaces apply failure as 422", %{conn: conn, home: home} do
      File.write!(Path.join(home, "config.yaml"), "mcp_servers: \"not a mapping\"")
      conn = post(conn, ~p"/api/harnesses/hermes/setup")
      assert %{"error" => error} = json_response(conn, 422)
      assert error =~ "mapping"
    end
  end
end
```

- [ ] **Step 3: Run to verify failure**

Run: `cd backend && mix test test/legend_web/controllers/harness_controller_test.exs`
Expected: FAIL — setup field absent (`nil`), and no route for `POST /api/harnesses/:id/setup`.

- [ ] **Step 4: Implement**

In `backend/lib/legend/harnesses/hermes.ex`: add the alias and the two callbacks. After the existing aliases add `alias Legend.Harnesses.Hermes.McpSetup`, and after `definition/0` add:

```elixir
  @impl Legend.Core.Harness
  def setup, do: McpSetup.setup()

  @impl Legend.Core.Harness
  def apply_setup, do: McpSetup.apply_setup()
```

Replace the full contents of `backend/lib/legend_web/controllers/harness_controller.ex` with:

```elixir
defmodule LegendWeb.HarnessController do
  use LegendWeb, :controller

  alias Legend.Core.Harness
  alias Legend.Core.Harness.Registry

  def index(conn, _params) do
    data =
      for {mod, d} <- Registry.entries() do
        %{
          id: d.id,
          name: d.name,
          description: d.description,
          kind: d.kind,
          resumable: d.resumable,
          setup: Harness.setup_for(mod)
        }
      end

    json(conn, %{data: data})
  end

  def apply_setup(conn, %{"id" => id}) do
    with {:ok, mod} <- Registry.fetch(id),
         :ok <- ensure_setup_capable(mod),
         :ok <- mod.apply_setup() do
      json(conn, %{data: Harness.setup_for(mod)})
    else
      :error ->
        conn |> put_status(404) |> json(%{error: "unknown harness: #{id}"})

      {:error, message} ->
        conn |> put_status(422) |> json(%{error: message})
    end
  end

  defp ensure_setup_capable(mod) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :apply_setup, 0) do
      :ok
    else
      {:error, "harness has no setup"}
    end
  end
end
```

In `backend/lib/legend_web/router.ex`, in the **first** `/api` scope, directly under `get "/harnesses", HarnessController, :index`, add:

```elixir
    post "/harnesses/:id/setup", HarnessController, :apply_setup
```

- [ ] **Step 5: Run controller tests, then the full suite**

Run: `cd backend && mix test test/legend_web/controllers/harness_controller_test.exs`
Expected: PASS (7 tests).

Run: `cd backend && mix precommit`
Expected: clean compile, formatted, all tests pass.

- [ ] **Step 6: Commit**

```bash
git add backend/lib/legend/harnesses/hermes.ex backend/lib/legend_web/controllers/harness_controller.ex backend/lib/legend_web/router.ex backend/config/test.exs backend/test/legend_web/controllers/harness_controller_test.exs
git commit -m "feat: harness setup over the API (GET setup field, POST /api/harnesses/:id/setup)"
```

---

### Task 4: Frontend — types, API client, new-session notice

**Files:**
- Modify: `frontend/src/lib/sessions.ts`
- Modify: `frontend/src/lib/components/NewSessionDialog.svelte`

- [ ] **Step 1: Extend sessions.ts**

In `frontend/src/lib/sessions.ts`, replace the `Harness` interface with:

```ts
export interface HarnessSetup {
	status: 'ok' | 'missing' | 'error' | 'not_applicable';
	summary: string;
	detail: string | null;
	restart_hint: boolean;
}

export interface Harness {
	id: string;
	name: string;
	description: string;
	kind: 'terminal' | 'acp' | 'native';
	resumable: boolean;
	setup: HarnessSetup;
}
```

And append at the end of the file:

```ts
export async function applyHarnessSetup(id: string): Promise<HarnessSetup> {
	const res = await fetch(`${apiBase}/api/harnesses/${id}/setup`, { method: 'POST' });
	if (!res.ok) {
		let detail = `${res.status}`;
		try {
			detail = (await res.json()).error ?? detail;
		} catch {
			// keep status code
		}
		throw new Error(`harness setup failed: ${detail}`);
	}
	return (await res.json()).data;
}

// Nag-dismissal is per-UI preference, not server state (spec amendment).
const dismissKey = (id: string) => `legend:harness-setup-dismissed:${id}`;

export function isSetupDismissed(id: string): boolean {
	try {
		return localStorage.getItem(dismissKey(id)) === 'true';
	} catch {
		return false;
	}
}

export function dismissSetup(id: string): void {
	try {
		localStorage.setItem(dismissKey(id), 'true');
	} catch {
		// localStorage unavailable — the settings card remains the affordance
	}
}
```

- [ ] **Step 2: Add the inline notice to NewSessionDialog**

In `frontend/src/lib/components/NewSessionDialog.svelte`:

Extend the import from `$lib/sessions`:

```ts
	import {
		applyHarnessSetup,
		createSession,
		dismissSetup,
		isSetupDismissed,
		listHarnesses,
		type Harness
	} from '$lib/sessions';
```

Add state + handlers after the existing `const selectedHarness = ...` line:

```ts
	let dismissed = $state<Record<string, boolean>>({});
	let applyingSetup = $state(false);
	let setupError = $state('');
	let setupApplied = $state('');

	const setupNeeded = $derived(
		selectedHarness?.setup.status === 'missing' && !dismissed[selectedHarness.id]
	);

	async function applySetup() {
		if (!selectedHarness || applyingSetup) return;
		const harness = selectedHarness;
		applyingSetup = true;
		setupError = '';
		try {
			await applyHarnessSetup(harness.id);
			harnesses = await listHarnesses();
			setupApplied = harness.setup.restart_hint
				? `Applied — restart existing ${harness.name} sessions to pick this up.`
				: 'Applied.';
		} catch (e) {
			setupError = e instanceof Error ? e.message : 'setup failed';
		} finally {
			applyingSetup = false;
		}
	}

	function dismiss() {
		if (!selectedHarness) return;
		dismissSetup(selectedHarness.id);
		dismissed = { ...dismissed, [selectedHarness.id]: true };
	}
```

In `openDialog()`, after `harnesses = await listHarnesses();` add:

```ts
			setupApplied = '';
			setupError = '';
			dismissed = Object.fromEntries(harnesses.map((h) => [h.id, isSetupDismissed(h.id)]));
```

In the template, directly after the harness `Select` block's closing `</div>` (before the Name field), add:

```svelte
				{#if setupNeeded && selectedHarness}
					<div class="flex flex-col gap-2 rounded-md border bg-muted/40 p-3 text-sm">
						<p>{selectedHarness.name}: {selectedHarness.setup.summary}</p>
						{#if setupError}
							<p class="text-destructive">{setupError}</p>
						{/if}
						<div class="flex gap-2">
							<Button size="sm" onclick={applySetup} disabled={applyingSetup}>
								{applyingSetup ? 'Applying…' : 'Apply'}
							</Button>
							<Button size="sm" variant="outline" onclick={dismiss}>Dismiss</Button>
						</div>
					</div>
				{:else if setupApplied}
					<p class="text-sm text-emerald-600">{setupApplied}</p>
				{/if}
```

- [ ] **Step 3: Type-check**

Run: `cd frontend && bun run check`
Expected: 0 errors. (Pre-existing warnings, if any, are not yours to fix.)

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/sessions.ts frontend/src/lib/components/NewSessionDialog.svelte
git commit -m "feat: harness setup notice in new-session dialog (apply/dismiss)"
```

---

### Task 5: Frontend — settings page integrations section

**Files:**
- Modify: `frontend/src/routes/settings/+page.svelte`

- [ ] **Step 1: Add the Harness integrations section**

In `frontend/src/routes/settings/+page.svelte`:

Extend the script imports:

```ts
	import { applyHarnessSetup, listHarnesses, type Harness } from '$lib/sessions';
```

Add state after the existing `let confirmingReset = $state(false);`:

```ts
	let harnesses = $state<Harness[]>([]);
	let harnessError = $state('');
	let applyingId = $state('');
	let appliedMsg = $state<Record<string, string>>({});

	const withSetup = $derived(harnesses.filter((h) => h.setup.status !== 'not_applicable'));

	async function loadHarnesses() {
		harnessError = '';
		try {
			harnesses = await listHarnesses();
		} catch (e) {
			harnessError = e instanceof Error ? e.message : 'failed to load harnesses';
		}
	}

	async function applyFor(harness: Harness) {
		if (applyingId) return;
		applyingId = harness.id;
		harnessError = '';
		try {
			await applyHarnessSetup(harness.id);
			appliedMsg = {
				...appliedMsg,
				[harness.id]: harness.setup.restart_hint
					? `Applied — restart existing ${harness.name} sessions to pick this up.`
					: 'Applied.'
			};
			await loadHarnesses();
		} catch (e) {
			harnessError = e instanceof Error ? e.message : 'setup failed';
		} finally {
			applyingId = '';
		}
	}
```

Change the `onMount` line to load both:

```ts
	onMount(() => {
		void load();
		void loadHarnesses();
	});
```

In the template, after the closing `</section>` of the Library section (still inside the outer `div`), add:

```svelte
	{#if withSetup.length > 0 || harnessError}
		<section class="flex flex-col gap-3">
			<h2 class="text-sm font-medium">Harness integrations</h2>

			{#each withSetup as harness (harness.id)}
				<div class="flex flex-col gap-2 rounded-md border p-3">
					<div class="flex items-center gap-2">
						<span class="text-sm font-medium">{harness.name}</span>
						{#if harness.setup.status === 'ok'}
							<span class="text-sm text-emerald-600">✓ configured</span>
						{:else if harness.setup.status === 'missing'}
							<span class="text-sm text-muted-foreground">not configured</span>
						{:else}
							<span class="text-sm text-destructive">configuration error</span>
						{/if}
					</div>

					<p class="text-sm text-muted-foreground">{harness.setup.summary}</p>

					{#if harness.setup.status === 'missing'}
						<div>
							<Button
								size="sm"
								onclick={() => applyFor(harness)}
								disabled={applyingId === harness.id}
							>
								{applyingId === harness.id ? 'Applying…' : 'Apply'}
							</Button>
						</div>
					{/if}

					{#if harness.setup.status === 'error' && harness.setup.detail}
						<pre class="overflow-x-auto rounded bg-muted p-2 text-xs">{harness.setup.detail}</pre>
					{/if}

					{#if appliedMsg[harness.id]}
						<p class="text-sm text-emerald-600">{appliedMsg[harness.id]}</p>
					{/if}
				</div>
			{/each}

			{#if harnessError}
				<p class="text-sm text-destructive">{harnessError}</p>
			{/if}
		</section>
	{/if}
```

- [ ] **Step 2: Type-check and build**

Run: `cd frontend && bun run check && bun run build`
Expected: 0 errors, build succeeds.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/routes/settings/+page.svelte
git commit -m "feat: harness integrations section in settings"
```

---

### Task 6: Docs + final verification

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update ARCHITECTURE.md**

In `docs/ARCHITECTURE.md`, find the bullet beginning `- **Per-harness MCP registration.**` (in the "Agent messaging & delegation" section) and replace it entirely with:

```markdown
- **Per-harness MCP registration.** Claude Code gets the server per launch (`--mcp-config` inline JSON + `--allowed-tools mcp__legend`). Hermes has no per-launch MCP flag — registration is a one-time entry in `$HERMES_HOME/config.yaml` (`mcp_servers.legend` with literal `${LEGEND_MCP_URL}` / `Bearer ${LEGEND_SESSION_TOKEN}` placeholders; Hermes interpolates `${VAR}` from the process env, and Legend injects exactly those vars into every spawned session). Standalone Hermes runs leave the placeholders unresolved and that server just fails to connect — a harmless logged warning. Legend applies this entry itself through the **harness setup seam** (below); without it, Hermes sessions run fine but can't see the signal-bus tools (the documented terminal-fallback posture).
- **Harness setup seam.** Harnesses with one-time host-machine setup needs export two *optional* callbacks (the `nudge_line` pattern): `setup/0` returning a self-describing `Legend.Core.Harness.Setup` struct (`status` ok/missing/error/not_applicable, `summary` of what Apply will do, `detail` error/manual snippet, `restart_hint`) and `apply_setup/0`. The UI renders only harness-provided fields — zero harness strings in the frontend. `GET /api/harnesses` carries the setup object; `POST /api/harnesses/:id/setup` applies it, and **only ever fires from an explicit button click** (consent — it writes a file in `$HOME` Legend doesn't own). Surfaces: inline notice in the new-session dialog (dismissal in `localStorage`, per-harness) + a Harness integrations card at `/settings` (the durable affordance). First implementer: `Legend.Harnesses.Hermes.McpSetup` — YAML round-trip via yaml_elixir/ymlr (comment/key-order loss accepted; matches Hermes' own tooling) with `config.yaml.legend-backup` + atomic tmp/rename write; never writes into a file it can't parse. One setup unit per harness (no multi-step framework — YAGNI). Spec: `superpowers/specs/2026-06-12-harness-setup-design.md`.
```

If the spec index/list at the bottom of ARCHITECTURE.md exists, add `2026-06-12-harness-setup-design.md` to it in date order.

- [ ] **Step 2: Update CLAUDE.md**

In `CLAUDE.md`, find the sentence in the signal-bus bullet that begins `MCP registration is per-harness:` and replace that sentence with:

```markdown
MCP registration is per-harness: Claude Code per launch (`--mcp-config` + `--allowed-tools mcp__legend`); Hermes via a one-time `mcp_servers.legend` entry in `~/.hermes/config.yaml` using `${LEGEND_MCP_URL}`/`${LEGEND_SESSION_TOKEN}` placeholders — applied consent-gated through the harness setup seam (optional `setup/0`/`apply_setup/0` callbacks, `GET /api/harnesses` setup field, `POST /api/harnesses/:id/setup`; UI in the new-session dialog + `/settings`).
```

- [ ] **Step 3: Full verification**

Run: `cd backend && mix precommit`
Expected: clean.

Run: `cd frontend && bun run check && bun run build`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add docs/ARCHITECTURE.md CLAUDE.md
git commit -m "docs: record the harness setup seam"
```

---

## Manual acceptance (human, post-merge)

1. Move the real config aside: `mv ~/.hermes/config.yaml ~/.hermes/config.yaml.orig`.
2. `just dev`, open the app → New session → pick Hermes → notice appears → **Apply** → success line with restart hint.
3. `hermes mcp list` → shows `legend`. `/settings` → Hermes shows ✓ configured.
4. Check `~/.hermes/config.yaml.legend-backup` exists (copy of the pre-apply file).
5. Restore: `mv ~/.hermes/config.yaml.orig ~/.hermes/config.yaml` (the real config already has the entry from the manual fix earlier today — the card should show ✓).
6. Dismiss path: clear the entry again in a scratch `HERMES_HOME` if desired, or trust the controller tests.
