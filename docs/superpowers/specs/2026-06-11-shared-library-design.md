# Shared Library — Design

**Date:** 2026-06-11
**Status:** Approved
**Builds on:** agent sessions PoC (`2026-06-11-agent-sessions-poc-design.md`); first half of the orchestration-and-resource-sharing phase (second half: rooms/multi-agent, separate spec)

## Vision context

Agents can't build on each other's work without common storage: a script Claude Code writes must be retrievable by Hermes. The shared library is that store — one global, Legend-managed tree for knowledge, skills, and artifacts, readable and writable by every session and by the human through the UI. It is deliberately the *first* half of the orchestration phase: rooms (next spec) hand off work through it.

## Goals

1. One global library on disk that every session can reach via its normal file tools, with `knowledge/`, `skills/`, `artifacts/` conventions seeded and self-documented.
2. Agents learn the library exists without per-user wiring: env var injected by the platform, primer delivered by the harness.
3. A `/library` UI: browse the tree, view/edit/create/delete text files.
4. Storage behind an adapter seam (`Legend.Core.Library.Storage`) so a cloud/synced backend later is a new module, not a rework.
5. Restructure `backend/lib/legend` so core logic and adapters are visibly separate (see Code structure) — executed first, before the library lands in the new layout.

## Code structure (restructure, part of this cycle)

Core logic moves under a `Legend.Core` namespace; implementations/adapters stay top-level siblings, one directory per plugin axis:

```
backend/lib/legend/
  core/
    agents.ex + agents/      Legend.Core.Agents (Ash domain), .Session, .SessionServer,
                             .Supervisor, .Janitor, .Notifications, .Scrollback, .Validations.*
    harness.ex + harness/    Legend.Core.Harness (+ .Definition), .Terminal, .Registry
    runtime.ex + runtime/    Legend.Core.Runtime, .CommandSpec, .Registry
    library.ex + library/    Legend.Core.Library (chokepoint), .Storage (behaviour)
  harnesses/                 Legend.Harnesses.ClaudeCode, Legend.Harnesses.Hermes
  runtimes/                  Legend.Runtimes.LocalPty
  storage/                   Legend.Storage.LocalDisk
  application.ex / repo.ex / release.ex   (unchanged names)
```

Full module renames (path matches module everywhere): `Legend.Agents` → `Legend.Core.Agents` etc.; `Legend.TestRuntime` → `Legend.Runtimes.Test` (test/support) for symmetry. `LegendWeb` is untouched structurally; its references update. Config updates: `ash_domains: [Legend.Core.Agents]`, registries reference the renamed modules. External contracts (JSON:API routes, channel topics, DB tables, snapshots) are unaffected by module names; the refactor must produce no new migration (verified with codegen --check) and a green suite.

## Non-goals (recorded as extension architecture)

- Cloud/synced storage backends and sandbox materialization (seam prepared, not built).
- Metadata indexing, tags, attribution, search, semantic retrieval — its own later project.
- Per-room workspaces (rooms spec builds them on this same seam).
- Locking/CRDTs for concurrent writes (last-write-wins per file, accepted).
- Versioning/history of library files.

## Architecture

```
UI (/library)            agents (file tools)
      │                          │
GET/PUT/DELETE /api/library/*    │  direct FS access via $LEGEND_LIBRARY
      │                          │
Legend.Core.Library  ─────────────  (containment chokepoint: safe_path/1)
      │
Legend.Core.Library.Storage (behaviour)      ← adapter seam
      │
Legend.Storage.LocalDisk (PoC)   [later: S3/synced adapter + runtime materialization]
```

Two access paths by design: the HTTP API serves the UI; agents touch the filesystem directly (that's the point — normal file tools, no SDK). Both converge on the same tree.

### `Legend.Core.Library` (chokepoint)

- `root/0` — resolves the library root: `LIBRARY_PATH` from `.env` (dotenvy) when set, else the OS user-data dir (`:filename.basedir(:user_data, "legend")` + `/library` — on macOS `~/Library/Application Support/legend/library`). Dev backend and desktop sidecar therefore share one library per machine, deliberately. Test env configures an isolated tmp directory.
- `ensure_seeded/0` — idempotent boot step (supervised Task, after the repo, before the endpoint): creates root, `knowledge/`, `skills/`, `artifacts/`, each with a `README.md` stating its convention. Fails loudly at boot with the offending path if the root is unusable.
- `list_tree/0`, `read/1`, `write/2`, `delete/1` — every path argument passes `safe_path/1` first: expand relative to root, reject anything resolving outside it (`../`, absolute paths, `a/../../b`). Lexical containment; the symlink-escape caveat is accepted and documented for the single-user local PoC.
- `primer/0` — the one canonical primer text (lives in `Legend.Core.Library`): the library exists at `$LEGEND_LIBRARY`, its layout, "read before reinventing, write back what's reusable," pointer to the READMEs.
- Containment is enforced server-side only; the UI is not trusted.

### `Legend.Core.Library.Storage` (adapter seam)

Behaviour over **relative** paths (the chokepoint owns absolutization and containment):

- `list_tree(root)` → `{:ok, [%{path, type: :file | :dir, size, mtime}]}`
- `read(root, rel_path)` → `{:ok, binary}` | `{:error, reason}`
- `write(root, rel_path, content)` → `:ok` | `{:error, reason}` (creates parent dirs)
- `delete(root, rel_path)` → `:ok` | `{:error, reason}` (files only)

Selected by `config :legend, :library_storage, Legend.Storage.LocalDisk` — a single configured module (exactly one backend active), unlike the list registries for harnesses/runtimes. `LocalDisk` is the PoC adapter; a cloud adapter later implements the same callbacks, plus runtime-side materialization (below).

## Session integration

Split deliberately in two:

- **Env is platform-injected.** SessionServer merges `LEGEND_LIBRARY=<root>` into the command env *after* `build_command/1` — every terminal session gets it regardless of harness cooperation.
- **Primer is harness-delivered.** `build_command/1` opts gain optional `library: %{path: String.t(), primer: String.t()}`. The `Legend.Harness.Terminal` contract documents the predefined behaviour: a harness SHOULD deliver the primer through its CLI's native context mechanism and MUST NOT inject it as fake user input (no PTY injection). Each harness plugin implements its own delivery:
  - `ClaudeCode`: appends `--append-system-prompt <primer>`.
  - `Hermes`: optional `HARNESS_HERMES_PRIMER_FLAG` in `.env` (e.g. `--system-prompt`); when set, appends `<flag> <primer>`; otherwise delivers nothing (env var only).
  - Future plugins (e.g. OpenClaw) implement their variant against the same contract.

Session `cwd` semantics are unchanged. Sessions snapshot the env at launch; the root never changes at runtime.

### Cloud-sandbox story (recorded, not built)

The contract is location-transparent: the harness builds the primer and the platform sets `LEGEND_LIBRARY`; *what that path points at* is the runtime's job. LocalPty points at the real directory. A future sandbox runtime materializes the library inside its execution environment (volume mount, or sync-down on start / push-back on change against the shared cloud adapter) and sets the env var to the materialized path. The primer is identical; the agent cannot tell the difference. Sync conflicts: last-write-wins per file at this maturity.

## HTTP API

Plain controllers in the **first** router scope (before the AshJsonApi forward), like `/api/harnesses`:

| Route | Behavior |
|---|---|
| `GET /api/library/tree` | Full recursive tree: `{data: [%{path, type, size, mtime}]}`. No pagination (PoC scale). |
| `GET /api/library/file?path=<rel>` | `{data: %{path, content}}` for UTF-8 text; binary content → clean error ("unsupported"), not garbage. |
| `PUT /api/library/file` | Body `{path, content}`; writes, creating parent directories. |
| `DELETE /api/library/file?path=<rel>` | Files only. |

Containment violations and invalid paths → 400. Body size: Plug defaults (~8 MB), no special handling.

## Frontend

- Sidebar gains a compact bottom nav: **Sessions** / **Library**.
- `/library` route, two panes: left, collapsible directory tree (`GET /api/library/tree`); right, viewer/editor for the selected file — monospace textarea (real code editor is a later upgrade), Save (PUT) with dirty-state indicator, New file (relative-path input, e.g. `skills/git-bisect.md`), Delete with confirm. Binary files show an "unsupported" notice.
- `src/lib/library.ts` wraps the four endpoints.
- No live updates: the tree refetches after save/create/delete and on manual refresh; concurrent agent writes appear on next refetch.

## Error handling & limits

- Path containment server-side, 400 on violation, traversal cases tested explicitly.
- Concurrent writes: last-write-wins per file.
- Mis-set `LIBRARY_PATH`: seeding fails loudly at boot with the path in the error.
- Deleting a file an agent has open: normal POSIX semantics, no coordination.
- Viewer/editor handles UTF-8 text only.

## Testing

- Restructure verification: full suite green after the rename, `phx.routes` unchanged, no new migration generated (codegen check).
- `Legend.Core.Library` unit tests: containment (`../`, absolute, `a/../../b`), read/write/delete round-trips, idempotent seeding, binary-read rejection.
- Controller tests over a tmp library root, including traversal rejection and parent-dir-creating writes.
- Harness tests: ClaudeCode emits `--append-system-prompt <primer>` when library opts present, nothing when absent; Hermes honors the flag template and stays silent without it.
- SessionServer (via TestRuntime): captured CommandSpec env contains `LEGEND_LIBRARY`; `build_command` received library opts.
- Frontend: svelte-check + build; manual smoke — create a skill file in the UI, start a session, ask the agent to read it.
- The storage seam ships with one adapter; its second implementation (cloud) arrives with the cloud project. Accepted: the seam is proven structurally (behaviour + config selection), not by a second impl as with TestRuntime.

## Decisions log

| Decision | Rationale |
|---|---|
| `Legend.Core.*` namespace for core, top-level dirs for adapters | Core-vs-plugin split visible in the tree; path matches module name (full rename, not dirs-only) |
| Filesystem is the only source of truth (no DB index) | Zero index/disk drift; agents grep with their own tools; search/metadata is a later project |
| Storage behind a behaviour, single configured module | Cloud adapter is a drop-in later; exactly one backend active (unlike harness/runtime list registries) |
| Env var injected by platform, primer delivered by harness | Env needs no harness cooperation; context injection is inherently CLI-specific and belongs in the plugin contract |
| No PTY injection for the primer | Fake user input is intrusive and corrupts the agent's conversation |
| Default root in OS user-data dir, shared by dev and sidecar | One library per machine is the product intent ("institutional memory") |
| Lexical containment, symlink caveat accepted | Single-user local PoC; the chokepoint is in place to harden later |
| Plain controllers, not Ash | A live filesystem gains nothing from Ash's data layer |
| Last-write-wins on concurrent writes | Locking/CRDTs deferred until multi-writer pressure is real |
