# Shared Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A global Legend-managed library (knowledge/skills/artifacts) every session can read/write, with env+primer agent onboarding and a /library browse/edit UI — built on a storage adapter seam, after restructuring `lib/legend` into `Legend.Core.*` vs top-level adapters.

**Architecture:** `Legend.Core.Library` is the containment chokepoint over the `Legend.Core.Library.Storage` behaviour (`Legend.Storage.LocalDisk` is the only adapter now). The platform injects `LEGEND_LIBRARY` into every session env; harnesses deliver a primer via their CLI's native mechanism per the amended `Legend.Core.Harness.Terminal` contract. Plain controllers serve the UI; agents touch the filesystem directly.

**Tech Stack:** Elixir/Phoenix 1.8 (plain controllers, no Ash for files), SvelteKit 2/Svelte 5 runes, existing shadcn components.

**Spec:** `docs/superpowers/specs/2026-06-11-shared-library-design.md`.

**Branch:** `feature/shared-library` off `main`, in the main checkout (no worktree — per user instruction).

**Conventions:** backend commands from `backend/`; frontend from `frontend/` with bun. `mix format` before each backend commit. The PostToolUse security hook prints Iron-Law reminders on writes — informational. Never write the literal string `MIX_ENV=prod mix` in any command. Current suite: 61 backend tests, svelte-check clean.

---

## File structure

```
backend/lib/legend/
  core/                          ← Task 1 moves existing modules here (full rename)
    agents.ex, agents/…          Legend.Core.Agents.*
    harness.ex, harness/…        Legend.Core.Harness.*
    runtime.ex, runtime/…        Legend.Core.Runtime.*
    library.ex                   Legend.Core.Library (Task 3)
    library/storage.ex           Legend.Core.Library.Storage behaviour (Task 2)
    library/seeder.ex            boot seeding Task (Task 3)
  harnesses/                     (unchanged location; primer args in Task 4)
  runtimes/                      (unchanged location)
  storage/local_disk.ex          Legend.Storage.LocalDisk (Task 2)
backend/lib/legend_web/controllers/library_controller.ex   (Task 5)
backend/test/support/runtimes/test.ex                      Legend.Runtimes.Test (Task 1 rename)
frontend/src/lib/library.ts                                 (Task 6)
frontend/src/lib/components/LibraryTree.svelte              (Task 6)
frontend/src/routes/library/+page.svelte                    (Task 6)
```

---

### Task 1: Restructure into Legend.Core.* (mechanical rename)

No behavior change. External contracts (routes, channel topics, tables, snapshots) unaffected. The rename is done with `git mv` + targeted `perl` replacements (NOT plain sed — `Legend.Harness` is a prefix of `Legend.Harnesses`, and `Legend.Runtime` of `Legend.Runtimes`; negative lookaheads protect the adapter namespaces).

**Files:** moves + global reference updates across `backend/lib`, `backend/test`, `backend/config`, plus `CLAUDE.md`.

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feature/shared-library main
```

- [ ] **Step 2: Move files (from `backend/`)**

```bash
mkdir -p lib/legend/core test/legend/core test/support/runtimes test/legend/runtimes
git mv lib/legend/agents.ex lib/legend/core/agents.ex
git mv lib/legend/agents lib/legend/core/agents
git mv lib/legend/harness.ex lib/legend/core/harness.ex
git mv lib/legend/harness lib/legend/core/harness
git mv lib/legend/runtime.ex lib/legend/core/runtime.ex
git mv lib/legend/runtime lib/legend/core/runtime
git mv test/legend/agents test/legend/core/agents
git mv test/legend/registry_test.exs test/legend/core/registry_test.exs
git mv test/support/test_runtime.ex test/support/runtimes/test.ex
git mv test/legend/test_runtime_test.exs test/legend/runtimes/test_test.exs
```

(`test/legend/harnesses_test.exs` and `test/legend/runtimes/local_pty_test.exs` stay where they are — already adapter-side paths.)

- [ ] **Step 3: Rename module references (from `backend/`)**

Order matters — most-specific first; lookaheads protect `Legend.Harnesses`/`Legend.Runtimes`:

```bash
FILES=$(git ls-files lib test config | grep -E '\.(ex|exs)$')
perl -pi -e 's/Legend\.TestRuntime/Legend.Runtimes.Test/g' $FILES
perl -pi -e 's/Legend\.Agents/Legend.Core.Agents/g' $FILES
perl -pi -e 's/Legend\.Harness(?!es)/Legend.Core.Harness/g' $FILES
perl -pi -e 's/Legend\.Runtime(?!s)/Legend.Core.Runtime/g' $FILES
```

This renames everything including process registry names (`Legend.Core.Agents.SessionRegistry`, `Legend.Core.Agents.SessionSupervisor`), the Ash domain in `config :legend, ash_domains:`, the test registry list in `config/test.exs` (now `[Legend.Runtimes.Test, Legend.Runtimes.LocalPty]`), and test module names (`Legend.TestRuntimeTest` becomes `Legend.Runtimes.TestTest` automatically).

- [ ] **Step 4: Verify nothing stale remains**

```bash
grep -rnE 'Legend\.(Agents|TestRuntime)|Legend\.Harness[^e]|Legend\.Runtime[^s]' lib test config | grep -v 'Legend\.Core' || echo CLEAN
```

Expected: `CLEAN` (manually eyeball any hits — `Legend.Harnesses`/`Legend.Runtimes` are fine and excluded by the pattern).

- [ ] **Step 5: Compile, format, test, route/migration invariance**

```bash
mix compile --warnings-as-errors
mix format
mix test                       # expect: 61 passed
mix phx.routes | grep -E 'api' # same routes as before the rename
mix ash_sqlite.generate_migrations --check   # expect: no changes needed
```

If `--check` wants a migration, STOP — the resource rename leaked into snapshots; report rather than generating one.

- [ ] **Step 6: Update CLAUDE.md**

In the Ash bullet, replace `Legend.Agents` with `Legend.Core.Agents`, and append to the Architecture/Backend section:

```markdown
- **Code structure:** core logic lives under `lib/legend/core/` (`Legend.Core.*` — Ash domains, harness/runtime/library contracts + registries); implementations/adapters are top-level siblings: `lib/legend/harnesses/`, `lib/legend/runtimes/`, `lib/legend/storage/`. New plugin implementations go in the sibling dirs, never in core.
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: split core (Legend.Core.*) from adapter implementations"
```

---

### Task 2: Storage behaviour + LocalDisk adapter

**Files:**
- Create: `backend/lib/legend/core/library/storage.ex`
- Create: `backend/lib/legend/storage/local_disk.ex`
- Test: `backend/test/legend/storage/local_disk_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Storage.LocalDiskTest do
  use ExUnit.Case, async: true

  alias Legend.Storage.LocalDisk

  @moduletag :tmp_dir

  test "write creates parent dirs; read round-trips", %{tmp_dir: root} do
    assert :ok = LocalDisk.write(root, "skills/git/bisect.md", "# Bisect")
    assert {:ok, "# Bisect"} = LocalDisk.read(root, "skills/git/bisect.md")
  end

  test "read of a missing file returns an error", %{tmp_dir: root} do
    assert {:error, :enoent} = LocalDisk.read(root, "nope.md")
  end

  test "list_tree returns files and dirs with metadata, sorted by path", %{tmp_dir: root} do
    :ok = LocalDisk.write(root, "knowledge/elixir.md", "x")
    :ok = LocalDisk.write(root, "artifacts/a.txt", "y")

    assert {:ok, entries} = LocalDisk.list_tree(root)
    assert Enum.map(entries, & &1.path) == [
             "artifacts",
             "artifacts/a.txt",
             "knowledge",
             "knowledge/elixir.md"
           ]

    file = Enum.find(entries, &(&1.path == "knowledge/elixir.md"))
    assert file.type == :file
    assert file.size == 1
    assert %DateTime{} = file.mtime

    dir = Enum.find(entries, &(&1.path == "artifacts"))
    assert dir.type == :dir
  end

  test "delete removes files but refuses directories", %{tmp_dir: root} do
    :ok = LocalDisk.write(root, "artifacts/tmp.txt", "x")
    assert :ok = LocalDisk.delete(root, "artifacts/tmp.txt")
    assert {:error, :enoent} = LocalDisk.read(root, "artifacts/tmp.txt")
    assert {:error, _} = LocalDisk.delete(root, "artifacts")
  end

  test "list_tree of an empty root is empty", %{tmp_dir: root} do
    assert {:ok, []} = LocalDisk.list_tree(root)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/storage/local_disk_test.exs`
Expected: FAIL — `Legend.Storage.LocalDisk` undefined.

- [ ] **Step 3: Implement behaviour + adapter**

`backend/lib/legend/core/library/storage.ex`:

```elixir
defmodule Legend.Core.Library.Storage do
  @moduledoc """
  Adapter seam for library storage. Exactly one adapter is active, selected by
  `config :legend, :library_storage`. Paths are RELATIVE to the library root —
  containment is the chokepoint's (`Legend.Core.Library`) job, not the adapter's.
  `Legend.Storage.LocalDisk` is the local implementation; a cloud/synced
  adapter later implements the same callbacks.
  """

  @type entry :: %{
          path: String.t(),
          type: :file | :dir,
          size: non_neg_integer(),
          mtime: DateTime.t()
        }

  @callback list_tree(root :: String.t()) :: {:ok, [entry()]} | {:error, term()}
  @callback read(root :: String.t(), rel_path :: String.t()) ::
              {:ok, binary()} | {:error, term()}
  @callback write(root :: String.t(), rel_path :: String.t(), content :: binary()) ::
              :ok | {:error, term()}
  @callback delete(root :: String.t(), rel_path :: String.t()) :: :ok | {:error, term()}
end
```

`backend/lib/legend/storage/local_disk.ex`:

```elixir
defmodule Legend.Storage.LocalDisk do
  @moduledoc "Library storage on the local filesystem — the PoC adapter."

  @behaviour Legend.Core.Library.Storage

  @impl true
  def list_tree(root) do
    if File.dir?(root) do
      {:ok, root |> walk("") |> Enum.sort_by(& &1.path)}
    else
      {:ok, []}
    end
  end

  @impl true
  def read(root, rel_path), do: File.read(Path.join(root, rel_path))

  @impl true
  def write(root, rel_path, content) do
    abs = Path.join(root, rel_path)

    with :ok <- File.mkdir_p(Path.dirname(abs)) do
      File.write(abs, content)
    end
  end

  @impl true
  def delete(root, rel_path) do
    # File.rm/1 refuses directories — exactly the files-only contract.
    File.rm(Path.join(root, rel_path))
  end

  defp walk(root, rel) do
    abs = Path.join(root, rel)

    abs
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      child_rel = if rel == "", do: name, else: rel <> "/" <> name
      child_abs = Path.join(root, child_rel)
      stat = File.stat!(child_abs, time: :posix)

      entry = %{
        path: child_rel,
        type: if(stat.type == :directory, do: :dir, else: :file),
        size: stat.size,
        mtime: DateTime.from_unix!(stat.mtime)
      }

      case stat.type do
        :directory -> [entry | walk(root, child_rel)]
        _ -> [entry]
      end
    end)
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend/storage/local_disk_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Format, full suite, commit**

`mix format`, `mix test` (expect 66 passed).

```bash
git add lib/legend/core/library/storage.ex lib/legend/storage/ test/legend/storage/
git commit -m "feat: library storage behaviour with LocalDisk adapter"
```

---

### Task 3: Library chokepoint, config, seeding

**Files:**
- Create: `backend/lib/legend/core/library.ex`
- Create: `backend/lib/legend/core/library/seeder.ex`
- Modify: `backend/config/config.exs` (storage adapter), `backend/config/runtime.exs` (LIBRARY_PATH), `backend/config/test.exs` (isolated path), `backend/lib/legend/application.ex` (seeder child), `backend/.env.example`, `backend/.gitignore`
- Test: `backend/test/legend/core/library_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Legend.Core.LibraryTest do
  use ExUnit.Case, async: false

  alias Legend.Core.Library

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:legend, :library_path)
    Application.put_env(:legend, :library_path, tmp)
    on_exit(fn -> Application.put_env(:legend, :library_path, original) end)
    :ok
  end

  test "root comes from config", %{tmp_dir: tmp} do
    assert Library.root() == tmp
  end

  test "ensure_seeded! creates conventions idempotently", %{tmp_dir: tmp} do
    assert :ok = Library.ensure_seeded!()
    assert :ok = Library.ensure_seeded!()

    for dir <- ~w(knowledge skills artifacts) do
      assert File.dir?(Path.join(tmp, dir))
      assert File.exists?(Path.join([tmp, dir, "README.md"]))
    end
  end

  test "write/read/delete round-trip through the chokepoint" do
    assert :ok = Library.write("skills/test.md", "# Test")
    assert {:ok, "# Test"} = Library.read("skills/test.md")
    assert {:ok, entries} = Library.list_tree()
    assert Enum.any?(entries, &(&1.path == "skills/test.md"))
    assert :ok = Library.delete("skills/test.md")
    assert {:error, :enoent} = Library.read("skills/test.md")
  end

  test "containment rejects escaping paths" do
    for bad <- ["../outside.txt", "/etc/passwd", "a/../../b", "skills/../../x"] do
      assert {:error, :unsafe_path} = Library.read(bad), "expected rejection: #{bad}"
      assert {:error, :unsafe_path} = Library.write(bad, "x"), "expected rejection: #{bad}"
      assert {:error, :unsafe_path} = Library.delete(bad), "expected rejection: #{bad}"
    end

    # Interior ../ that stays inside the root is fine.
    assert :ok = Library.write("skills/a/../ok.md", "x")
    assert {:ok, "x"} = Library.read("skills/../skills/ok.md")
  end

  test "empty and root-pointing paths are rejected" do
    assert {:error, :unsafe_path} = Library.read("")
    assert {:error, :unsafe_path} = Library.read(".")
  end

  test "read rejects non-UTF-8 content as not text", %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "blob.bin"), <<0xFF, 0xFE, 0x00>>)
    assert {:error, :not_text} = Library.read("blob.bin")
  end

  test "primer mentions the env var and layout" do
    assert Library.primer() =~ "LEGEND_LIBRARY"
    assert Library.primer() =~ "skills/"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend/core/library_test.exs`
Expected: FAIL — `Legend.Core.Library` undefined.

- [ ] **Step 3: Implement chokepoint + seeder**

`backend/lib/legend/core/library.ex`:

```elixir
defmodule Legend.Core.Library do
  @moduledoc """
  The shared library: one global tree (knowledge/skills/artifacts) readable and
  writable by every session and the UI. This module is the containment
  chokepoint — every path is validated against the root before touching the
  configured storage adapter. Containment is lexical (Path.expand); the
  symlink-escape caveat is accepted for the single-user local PoC.
  """

  @subdirs ~w(knowledge skills artifacts)

  @readme %{
    "knowledge" => "# Knowledge\n\nDurable notes, research, and reference material. Markdown preferred.\n",
    "skills" => "# Skills\n\nReusable how-tos and scripts agents can follow or execute. One skill per file or folder.\n",
    "artifacts" => "# Artifacts\n\nOutputs worth keeping: generated code, analyses, templates.\n"
  }

  def root do
    case Application.get_env(:legend, :library_path) do
      nil -> :user_data |> :filename.basedir("legend") |> List.to_string() |> Path.join("library")
      path -> path
    end
  end

  def primer do
    """
    A shared Legend library lives at $LEGEND_LIBRARY with knowledge/, skills/, and \
    artifacts/ directories (each has a README with its conventions). Before solving \
    a problem from scratch, check the library for existing knowledge or skills. When \
    you produce something reusable (a script, a how-to, a finding), save it there \
    with a descriptive kebab-case filename.
    """
  end

  def ensure_seeded! do
    File.mkdir_p!(root())

    for dir <- @subdirs do
      File.mkdir_p!(Path.join(root(), dir))
      readme = Path.join([root(), dir, "README.md"])
      unless File.exists?(readme), do: File.write!(readme, @readme[dir])
    end

    :ok
  rescue
    e in File.Error ->
      reraise "library root #{inspect(root())} is unusable: #{Exception.message(e)}",
              __STACKTRACE__
  end

  def list_tree, do: storage().list_tree(root())

  def read(rel_path) do
    with {:ok, safe} <- safe_path(rel_path),
         {:ok, content} <- storage().read(root(), safe) do
      if String.valid?(content), do: {:ok, content}, else: {:error, :not_text}
    end
  end

  def write(rel_path, content) when is_binary(content) do
    with {:ok, safe} <- safe_path(rel_path), do: storage().write(root(), safe, content)
  end

  def delete(rel_path) do
    with {:ok, safe} <- safe_path(rel_path), do: storage().delete(root(), safe)
  end

  # Lexical containment: the expanded path must be strictly inside the root.
  defp safe_path(rel_path) when is_binary(rel_path) do
    root = Path.expand(root())
    full = Path.expand(rel_path, root)

    if full != root and String.starts_with?(full, root <> "/") do
      {:ok, Path.relative_to(full, root)}
    else
      {:error, :unsafe_path}
    end
  end

  defp storage, do: Application.get_env(:legend, :library_storage, Legend.Storage.LocalDisk)
end
```

`backend/lib/legend/core/library/seeder.ex`:

```elixir
defmodule Legend.Core.Library.Seeder do
  @moduledoc "Boot task: create the library root and convention dirs (idempotent)."

  use Task, restart: :temporary

  def start_link(_arg), do: Task.start_link(&Legend.Core.Library.ensure_seeded!/0)
end
```

- [ ] **Step 4: Wire config and supervision**

`backend/config/config.exs` — extend the registries block:

```elixir
config :legend,
  harnesses: [Legend.Harnesses.ClaudeCode, Legend.Harnesses.Hermes],
  runtimes: [Legend.Runtimes.LocalPty],
  library_storage: Legend.Storage.LocalDisk
```

`backend/config/runtime.exs` — after the `:harness_commands` block:

```elixir
# Shared library root. Default: OS user-data dir (~/Library/Application
# Support/legend/library on macOS) — dev and the desktop sidecar share it.
case env!("LIBRARY_PATH", :string, nil) do
  path when path in [nil, ""] -> :ok
  path -> config :legend, library_path: path
end
```

`backend/config/test.exs` — append:

```elixir
# Isolated library for tests; individual tests override :library_path with a
# per-test tmp_dir on top of this.
config :legend, library_path: Path.expand("../tmp/test-library", __DIR__)
```

`backend/.gitignore` — add a line: `/tmp/`

`backend/lib/legend/application.ex` — children, directly after `Legend.Core.Agents.Supervisor`:

```elixir
      Legend.Core.Library.Seeder,
```

`backend/.env.example` — append:

```bash

# Shared library root (default: OS user-data dir, shared by dev and desktop).
LIBRARY_PATH=
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test test/legend/core/library_test.exs`
Expected: PASS (7 tests). Then `mix test` — expect 73 passed (boot seeding now also runs against `backend/tmp/test-library`; harmless and gitignored).

- [ ] **Step 6: Format + commit**

```bash
git add lib/legend/core/library.ex lib/legend/core/library/seeder.ex config/ lib/legend/application.ex .env.example .gitignore test/legend/core/library_test.exs
git commit -m "feat: shared library chokepoint with seeding and containment"
```

---

### Task 4: Session integration — env injection + harness primer delivery

**Files:**
- Modify: `backend/lib/legend/core/harness/terminal.ex` (opts type + contract doc)
- Modify: `backend/lib/legend/core/agents/session_server.ex` (init)
- Modify: `backend/lib/legend/harnesses/claude_code.ex`, `backend/lib/legend/harnesses/hermes.ex`
- Modify: `backend/config/runtime.exs` + `backend/.env.example` (Hermes primer flag)
- Test: extend `backend/test/legend/harnesses_test.exs` and `backend/test/legend/core/agents/session_server_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `backend/test/legend/harnesses_test.exs`:

```elixir
  describe "library primer delivery" do
    @library %{path: "/lib/root", primer: "Use the library."}

    test "claude_code appends --append-system-prompt when library opts present" do
      assert %CommandSpec{args: args} = Legend.Harnesses.ClaudeCode.build_command(%{library: @library})
      assert ["--append-system-prompt", "Use the library."] = Enum.take(args, -2)
    end

    test "claude_code emits no primer args without library opts" do
      assert %CommandSpec{args: []} = Legend.Harnesses.ClaudeCode.build_command(%{})
    end

    test "hermes delivers the primer only when a flag template is configured" do
      assert %CommandSpec{args: []} = Legend.Harnesses.Hermes.build_command(%{library: @library})

      Application.put_env(
        :legend,
        :harness_commands,
        hermes: "hermes", hermes_primer_flag: "--system-prompt"
      )

      assert %CommandSpec{args: args} = Legend.Harnesses.Hermes.build_command(%{library: @library})
      assert ["--system-prompt", "Use the library."] = Enum.take(args, -2)
    end
  end
```

Append to `backend/test/legend/core/agents/session_server_test.exs` (inside the module, before the private helpers):

```elixir
  test "sessions get LEGEND_LIBRARY env and the harness receives library opts", %{
    session: session
  } do
    boot!(session)
    assert_receive {:test_runtime, :start, spec, _opts}

    assert spec.env["LEGEND_LIBRARY"] == Legend.Core.Library.root()
    # claude_code delivers the primer as CLI args — proof build_command got library opts.
    assert "--append-system-prompt" in spec.args
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/legend/harnesses_test.exs test/legend/core/agents/session_server_test.exs`
Expected: the new tests FAIL (no primer args, no LEGEND_LIBRARY env); existing ones pass.

- [ ] **Step 3: Amend the Terminal contract**

Replace `backend/lib/legend/core/harness/terminal.ex` with:

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
  """

  @type library :: %{path: String.t(), primer: String.t()}
  @type opts :: %{
          optional(:env) => %{String.t() => String.t()},
          optional(:library) => library()
        }

  @callback build_command(opts()) :: Legend.Core.Runtime.CommandSpec.t()
end
```

- [ ] **Step 4: Implement primer delivery in both harnesses**

In `backend/lib/legend/harnesses/claude_code.ex`, change `build_command/1` and add the helper:

```elixir
  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:claude_code, "claude")

    %CommandSpec{
      cmd: cmd,
      args: args ++ primer_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  defp primer_args(%{library: %{primer: primer}}) when is_binary(primer) and primer != "" do
    ["--append-system-prompt", primer]
  end

  defp primer_args(_opts), do: []
```

In `backend/lib/legend/harnesses/hermes.ex`, likewise:

```elixir
  @impl Legend.Core.Harness.Terminal
  def build_command(opts) do
    [cmd | args] = configured_command(:hermes, "hermes")

    %CommandSpec{
      cmd: cmd,
      args: args ++ primer_args(opts),
      env: Map.merge(%{"TERM" => "xterm-256color"}, opts[:env] || %{}),
      io: :pty
    }
  end

  # Hermes' CLI primer mechanism is unknown; deliver only when the operator
  # configures a flag template (HARNESS_HERMES_PRIMER_FLAG), per the contract.
  defp primer_args(%{library: %{primer: primer}}) when is_binary(primer) and primer != "" do
    case Application.get_env(:legend, :harness_commands, [])[:hermes_primer_flag] do
      flag when is_binary(flag) and flag != "" -> [flag, primer]
      _ -> []
    end
  end

  defp primer_args(_opts), do: []
```

- [ ] **Step 5: SessionServer init — library opts in, env injected after**

In `backend/lib/legend/core/agents/session_server.ex` `init/1`, replace the two lines building the spec:

```elixir
         spec = harness.build_command(%{library: %{path: Legend.Core.Library.root(), primer: Legend.Core.Library.primer()}}),
         spec = %{spec | env: Map.put(spec.env, "LEGEND_LIBRARY", Legend.Core.Library.root())},
         {:ok, handle} <- runtime.start(spec, %{owner: self(), cwd: session.cwd}) do
```

(Platform env injection happens AFTER `build_command` so it wins regardless of harness behavior.)

- [ ] **Step 6: Config for the Hermes flag**

`backend/config/runtime.exs` — extend the `:harness_commands` block:

```elixir
config :legend, :harness_commands,
  claude_code: env!("HARNESS_CLAUDE_CMD", :string, "claude"),
  hermes: env!("HARNESS_HERMES_CMD", :string, "hermes"),
  hermes_primer_flag: env!("HARNESS_HERMES_PRIMER_FLAG", :string, nil)
```

`backend/.env.example` — append under the harness block:

```bash
# If the Hermes CLI supports a system-prompt flag, name it here to enable
# library primer delivery (e.g. --system-prompt). Empty = env var only.
HARNESS_HERMES_PRIMER_FLAG=
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `mix test test/legend/harnesses_test.exs test/legend/core/agents/session_server_test.exs`
Expected: PASS. Then `mix test` — expect 77 passed. (Note: the harnesses test setup saves/restores `:harness_commands`; the new hermes test mutates it inside that protection.)

- [ ] **Step 8: Format + commit**

```bash
git add lib/legend/core/harness/terminal.ex lib/legend/core/agents/session_server.ex lib/legend/harnesses/ config/runtime.exs .env.example test/
git commit -m "feat: sessions receive LEGEND_LIBRARY env and harness-delivered primer"
```

---

### Task 5: /api/library endpoints

**Files:**
- Create: `backend/lib/legend_web/controllers/library_controller.ex`
- Modify: `backend/lib/legend_web/router.ex` (first /api scope ONLY — before the Ash forward)
- Test: `backend/test/legend_web/controllers/library_controller_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule LegendWeb.LibraryControllerTest do
  use LegendWeb.ConnCase, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    original = Application.get_env(:legend, :library_path)
    Application.put_env(:legend, :library_path, tmp)
    on_exit(fn -> Application.put_env(:legend, :library_path, original) end)
    :ok
  end

  test "PUT then GET file round-trips, creating parents", %{conn: conn} do
    conn1 = put(conn, "/api/library/file", %{path: "skills/new/tip.md", content: "# Tip"})
    assert json_response(conn1, 200)

    conn2 = get(conn, "/api/library/file", path: "skills/new/tip.md")
    assert %{"data" => %{"path" => "skills/new/tip.md", "content" => "# Tip"}} =
             json_response(conn2, 200)
  end

  test "tree lists entries with metadata", %{conn: conn} do
    put(conn, "/api/library/file", %{path: "knowledge/a.md", content: "x"})
    conn = get(conn, "/api/library/tree")

    assert %{"data" => entries} = json_response(conn, 200)
    file = Enum.find(entries, &(&1["path"] == "knowledge/a.md"))
    assert file["type"] == "file"
    assert is_integer(file["size"])
    assert is_binary(file["mtime"])
  end

  test "DELETE removes a file", %{conn: conn} do
    put(conn, "/api/library/file", %{path: "artifacts/x.txt", content: "x"})
    conn1 = delete(conn, "/api/library/file", path: "artifacts/x.txt")
    assert json_response(conn1, 200)

    conn2 = get(conn, "/api/library/file", path: "artifacts/x.txt")
    assert json_response(conn2, 404)
  end

  test "traversal and invalid paths are rejected with 400", %{conn: conn} do
    for bad <- ["../secrets.txt", "/etc/passwd", "a/../../b"] do
      assert json_response(get(conn, "/api/library/file", path: bad), 400)
      assert json_response(put(conn, "/api/library/file", %{path: bad, content: "x"}), 400)
      assert json_response(delete(conn, "/api/library/file", path: bad), 400)
    end
  end

  test "missing file is 404; binary file is 415", %{conn: conn, tmp_dir: tmp} do
    assert json_response(get(conn, "/api/library/file", path: "nope.md"), 404)

    File.write!(Path.join(tmp, "blob.bin"), <<0xFF, 0xFE, 0x00>>)
    assert json_response(get(conn, "/api/library/file", path: "blob.bin"), 415)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/legend_web/controllers/library_controller_test.exs`
Expected: FAIL — 404s from the Ash forward (routes don't exist).

- [ ] **Step 3: Implement controller + routes**

`backend/lib/legend_web/controllers/library_controller.ex`:

```elixir
defmodule LegendWeb.LibraryController do
  use LegendWeb, :controller

  alias Legend.Core.Library

  def tree(conn, _params) do
    {:ok, entries} = Library.list_tree()

    json(conn, %{
      data:
        for e <- entries do
          %{path: e.path, type: e.type, size: e.size, mtime: DateTime.to_iso8601(e.mtime)}
        end
    })
  end

  def show(conn, %{"path" => path}) do
    case Library.read(path) do
      {:ok, content} -> json(conn, %{data: %{path: path, content: content}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, %{"path" => path, "content" => content}) when is_binary(content) do
    case Library.write(path, content) do
      :ok -> json(conn, %{data: %{path: path}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def delete(conn, %{"path" => path}) do
    case Library.delete(path) do
      :ok -> json(conn, %{data: %{path: path}})
      {:error, reason} -> error(conn, reason)
    end
  end

  defp error(conn, :unsafe_path), do: send_error(conn, 400, "path escapes the library root")
  defp error(conn, :not_text), do: send_error(conn, 415, "not a UTF-8 text file")
  defp error(conn, :enoent), do: send_error(conn, 404, "not found")
  defp error(conn, reason), do: send_error(conn, 400, "operation failed: #{inspect(reason)}")

  defp send_error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end
end
```

In `backend/lib/legend_web/router.ex`, first `/api` scope, below the harnesses route:

```elixir
    get "/library/tree", LibraryController, :tree
    get "/library/file", LibraryController, :show
    put "/library/file", LibraryController, :update
    delete "/library/file", LibraryController, :delete
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/legend_web/controllers/library_controller_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Format, precommit, commit**

`mix precommit` — expect 82 passed, clean.

```bash
git add lib/legend_web/controllers/library_controller.ex lib/legend_web/router.ex test/legend_web/controllers/library_controller_test.exs
git commit -m "feat: library file API (tree/read/write/delete) with containment errors"
```

---

### Task 6: Frontend — library client, tree, editor page

**Files:**
- Create: `frontend/src/lib/library.ts`
- Create: `frontend/src/lib/components/LibraryTree.svelte`
- Create: `frontend/src/routes/library/+page.svelte`
- Modify: `frontend/src/lib/components/SessionSidebar.svelte` (bottom nav)

- [ ] **Step 1: API client — `frontend/src/lib/library.ts`:**

```ts
import { apiBase } from './api';

export interface LibraryEntry {
	path: string;
	type: 'file' | 'dir';
	size: number;
	mtime: string;
}

async function fail(res: Response, fallback: string): Promise<never> {
	let detail = `${res.status}`;
	try {
		detail = (await res.json()).error ?? detail;
	} catch {
		// keep status code
	}
	throw new Error(`${fallback}: ${detail}`);
}

export async function listTree(): Promise<LibraryEntry[]> {
	const res = await fetch(`${apiBase}/api/library/tree`);
	if (!res.ok) await fail(res, 'listing library failed');
	return (await res.json()).data;
}

export async function readFile(path: string): Promise<string> {
	const res = await fetch(`${apiBase}/api/library/file?path=${encodeURIComponent(path)}`);
	if (!res.ok) await fail(res, 'reading file failed');
	return (await res.json()).data.content;
}

export async function writeFile(path: string, content: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/library/file`, {
		method: 'PUT',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ path, content })
	});
	if (!res.ok) await fail(res, 'saving file failed');
}

export async function deleteFile(path: string): Promise<void> {
	const res = await fetch(
		`${apiBase}/api/library/file?path=${encodeURIComponent(path)}`,
		{ method: 'DELETE' }
	);
	if (!res.ok) await fail(res, 'deleting file failed');
}

export interface TreeNode {
	name: string;
	path: string;
	type: 'file' | 'dir';
	children: TreeNode[];
}

/** Builds a nested tree from flat entries; dirs first, then files, alphabetical. */
export function buildTree(entries: LibraryEntry[]): TreeNode[] {
	const byPath = new Map<string, TreeNode>();
	const roots: TreeNode[] = [];

	for (const e of [...entries].sort((a, b) => a.path.localeCompare(b.path))) {
		const node: TreeNode = {
			name: e.path.split('/').at(-1) ?? e.path,
			path: e.path,
			type: e.type,
			children: []
		};
		byPath.set(e.path, node);
		const parent = byPath.get(e.path.split('/').slice(0, -1).join('/'));
		(parent ? parent.children : roots).push(node);
	}

	const order = (nodes: TreeNode[]) => {
		nodes.sort((a, b) =>
			a.type === b.type ? a.name.localeCompare(b.name) : a.type === 'dir' ? -1 : 1
		);
		nodes.forEach((n) => order(n.children));
	};
	order(roots);
	return roots;
}
```

- [ ] **Step 2: Tree component — `frontend/src/lib/components/LibraryTree.svelte`:**

```svelte
<script lang="ts">
	import type { TreeNode } from '$lib/library';

	let {
		nodes,
		selected,
		onselect
	}: {
		nodes: TreeNode[];
		selected: string | null;
		onselect: (path: string) => void;
	} = $props();

	let collapsed = $state<Record<string, boolean>>({});
</script>

{#snippet node(n: TreeNode, depth: number)}
	<div style={`padding-left: ${depth * 0.75}rem`}>
		{#if n.type === 'dir'}
			<button
				class="flex w-full items-center gap-1 rounded px-1 py-0.5 text-sm hover:bg-accent"
				onclick={() => (collapsed[n.path] = !collapsed[n.path])}
			>
				<span class="text-muted-foreground">{collapsed[n.path] ? '▸' : '▾'}</span>
				<span class="truncate">{n.name}/</span>
			</button>
			{#if !collapsed[n.path]}
				{#each n.children as child (child.path)}
					{@render node(child, depth + 1)}
				{/each}
			{/if}
		{:else}
			<button
				class="block w-full truncate rounded px-1 py-0.5 text-left text-sm hover:bg-accent
					{selected === n.path ? 'bg-accent' : ''}"
				onclick={() => onselect(n.path)}
			>
				{n.name}
			</button>
		{/if}
	</div>
{/snippet}

{#each nodes as n (n.path)}
	{@render node(n, 0)}
{/each}
```

- [ ] **Step 3: Library page — `frontend/src/routes/library/+page.svelte`:**

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import LibraryTree from '$lib/components/LibraryTree.svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import {
		buildTree,
		deleteFile,
		listTree,
		readFile,
		writeFile,
		type TreeNode
	} from '$lib/library';

	let tree = $state<TreeNode[]>([]);
	let selected = $state<string | null>(null);
	let content = $state('');
	let savedContent = $state('');
	let newPath = $state('');
	let error = $state('');

	const dirty = $derived(content !== savedContent);

	async function refresh() {
		try {
			tree = buildTree(await listTree());
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load library';
		}
	}

	async function open(path: string) {
		error = '';
		try {
			content = await readFile(path);
			savedContent = content;
			selected = path;
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to read file';
		}
	}

	async function save() {
		if (!selected) return;
		error = '';
		try {
			await writeFile(selected, content);
			savedContent = content;
			await refresh();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to save';
		}
	}

	async function createFile() {
		const path = newPath.trim();
		if (!path) return;
		error = '';
		try {
			await writeFile(path, '');
			newPath = '';
			await refresh();
			await open(path);
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to create file';
		}
	}

	async function removeSelected() {
		if (!selected || !confirm(`Delete ${selected}?`)) return;
		error = '';
		try {
			await deleteFile(selected);
			selected = null;
			content = '';
			savedContent = '';
			await refresh();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to delete';
		}
	}

	onMount(() => void refresh());
</script>

<div class="flex h-full">
	<aside class="flex w-72 shrink-0 flex-col gap-2 overflow-y-auto border-r p-3">
		<div class="flex gap-2">
			<Input bind:value={newPath} placeholder="skills/my-skill.md" />
			<Button size="sm" variant="outline" onclick={createFile}>New</Button>
		</div>
		<LibraryTree nodes={tree} {selected} onselect={open} />
	</aside>

	<main class="flex min-w-0 flex-1 flex-col">
		<div class="flex items-center gap-2 border-b px-3 py-2">
			<span class="truncate text-sm text-muted-foreground">
				{selected ?? 'Select a file'}{dirty ? ' •' : ''}
			</span>
			{#if error}
				<span class="truncate text-sm text-destructive">{error}</span>
			{/if}
			<div class="ml-auto flex gap-2">
				{#if selected}
					<Button size="sm" onclick={save} disabled={!dirty}>Save</Button>
					<Button size="sm" variant="destructive" onclick={removeSelected}>Delete</Button>
				{/if}
			</div>
		</div>
		{#if selected}
			<textarea
				bind:value={content}
				class="min-h-0 flex-1 resize-none bg-background p-3 font-mono text-sm outline-none"
				spellcheck="false"
			></textarea>
		{:else}
			<div class="flex flex-1 items-center justify-center">
				<p class="text-muted-foreground">Select or create a file.</p>
			</div>
		{/if}
	</main>
</div>
```

- [ ] **Step 4: Sidebar nav**

In `frontend/src/lib/components/SessionSidebar.svelte`, after the closing `</nav>` and before `</aside>`, add:

```svelte
	<nav class="flex shrink-0 gap-1 border-t pt-2 text-sm">
		<a
			href="/"
			class="flex-1 rounded-md px-2 py-1.5 text-center hover:bg-accent
				{page.url.pathname.startsWith('/library') ? '' : 'bg-accent'}">Sessions</a
		>
		<a
			href="/library"
			class="flex-1 rounded-md px-2 py-1.5 text-center hover:bg-accent
				{page.url.pathname.startsWith('/library') ? 'bg-accent' : ''}">Library</a
		>
	</nav>
```

- [ ] **Step 5: Verify**

Run: `bun run check` — 0 errors, 0 warnings. Run: `bun run build` — succeeds.

- [ ] **Step 6: Commit**

```bash
git add src/lib/library.ts src/lib/components/LibraryTree.svelte src/routes/library/ src/lib/components/SessionSidebar.svelte
git commit -m "feat: library browser with tree, editor, create and delete"
```

---

### Task 7: Docs, verification, smoke

**Files:**
- Modify: `CLAUDE.md` (library bullet), `README.md` (library paragraph)

- [ ] **Step 1: CLAUDE.md** — in the Architecture/Backend section, after the code-structure bullet from Task 1, add:

```markdown
- **Shared library:** one global tree (default `~/Library/Application Support/legend/library`, `LIBRARY_PATH` overrides) with `knowledge/`, `skills/`, `artifacts/`. `Legend.Core.Library` is the containment chokepoint over the `Legend.Core.Library.Storage` adapter (`config :legend, :library_storage`; `Legend.Storage.LocalDisk` now). Sessions get `LEGEND_LIBRARY` injected; harnesses deliver the primer per the `Terminal` contract (never via PTY injection). UI at `/library`; API at `/api/library/*` (first router scope).
```

- [ ] **Step 2: README** — after the harness-commands paragraph in Setup, add:

```markdown
All sessions share a library (knowledge, skills, artifacts) at
`~/Library/Application Support/legend/library` by default (`LIBRARY_PATH` in
`backend/.env` overrides). Agents are pointed at it via `$LEGEND_LIBRARY` and
a primer; browse and edit it in the app under Library.
```

- [ ] **Step 3: Full verification**

From repo root: `just test` (expect 82 backend + svelte-check clean). From `backend/`: `mix precommit`.

- [ ] **Step 4: Live smoke (non-interactive)**

```bash
cd backend
LIBRARY_PATH=/tmp/legend-lib-smoke HARNESS_HERMES_CMD=cat PORT=4115 mix phx.server > /tmp/legend-lib-smoke.log 2>&1 &
```

Poll `curl -s localhost:4115/api/health`. Then:
1. `curl -s localhost:4115/api/library/tree` — seeded dirs + READMEs present.
2. `curl -s -X PUT localhost:4115/api/library/file -H 'Content-Type: application/json' -d '{"path":"skills/smoke.md","content":"# smoke"}'` → 200; GET it back → content matches.
3. `curl -s "localhost:4115/api/library/file?path=../etc/passwd"` → 400.
4. Sessions still work alongside the library: POST a hermes session (boot the server with `HARNESS_HERMES_CMD=cat` in step 0's env for this) via JSON:API → 201 with `"status":"running"`, then DELETE it → 200 and the `cat` process is gone (`pgrep -x cat` empty). The `LEGEND_LIBRARY` env injection itself is unit-tested; this confirms the full stack boots with seeding active.
5. Kill the server, verify the port is free, remove /tmp/legend-lib-smoke* artifacts.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "docs: shared library usage and configuration"
```
