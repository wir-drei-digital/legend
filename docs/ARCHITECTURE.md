# Legend — Architecture

**Status:** living document — **update it in the same PR/feature cycle as any change that alters an architectural decision recorded here.** Specs in `docs/superpowers/specs/` capture the full reasoning per feature; this file is the always-current condensed map. Product direction lives in [VISION.md](VISION.md).

## System shape

One application, two delivery targets, three serving modes:

```
                  SvelteKit static SPA (Svelte 5 runes, no SSR — ever)
                 /            |                        \
   Dev: Vite :5173     Web prod: served by      Desktop: Tauri webview,
   proxies /api+/socket  Phoenix from           backend runs INSIDE the app
   to Phoenix :4100      priv/static            as a Burrito sidecar :4807
                 \            |                        /
                  Phoenix backend (Elixir 1.20 / Phoenix 1.8 / Ash 3 / SQLite)
                  API + channels only — no HTML/LiveView layer
```

Decisions:
- **No SSR, never.** Tauri and the Phoenix catch-all both depend on the static build (`adapter-static`, `fallback: index.html`).
- **Dev port 4100** (not Phoenix's usual 4000) so legend coexists with other Phoenix apps; **desktop port 4807 is fixed** because a static frontend can't learn a runtime port without Tauri IPC.
- Backend binds **loopback** by default (sidecar-first design); public web deploys must change the bind and add TLS in front.

## Plugin architecture (the central decision)

Legend is an orchestrator whose capabilities arrive as plugins. Extension points are **Elixir behaviours with config-listed registries** (`config :legend, :harnesses / :runtimes / :library_storage`) — real seams at PoC cost; a public plugin packaging story layers on later without rework. Three axes, deliberately orthogonal:

| Seam | Contract | Implemented | Reserved |
|---|---|---|---|
| **Harness** — *which agent* | `Legend.Core.Harness` (`definition/0`, kind enum) + `Legend.Core.Harness.Terminal` (`build_command/1` over `library`/`mcp`/`messaging` opts; optional `nudge_line/2`) | `:terminal`: ClaudeCode, Hermes | `:acp` (JSON-RPC subprocess, rich UI), `:native` (in-BEAM, e.g. Jido) |
| **Runtime** — *where it executes* | `Legend.Core.Runtime` (`start/write/resize/stop` + `{:runtime_output,_}`/`{:runtime_exit,_}` owner messages) | `LocalPty` (erlexec, true PTY) | Docker / Fly / hosted sandbox / reverse tunnel |
| **Library storage** — *where shared files live* | `Legend.Core.Library.Storage` (`list_tree/read/write/delete`, relative paths) | `LocalDisk` | S3/synced adapter + runtime-side materialization |

Supporting decisions:
- **Code structure mirrors the seams:** contracts + domains under `lib/legend/core/` (`Legend.Core.*`); implementations are top-level siblings (`harnesses/`, `runtimes/`, `storage/`). Plugins never live in core.
- **`CommandSpec.io: :pty | :pipes`** keeps "where it runs" orthogonal to "how it talks" — ACP needs clean pipes, terminals need a PTY.
- **Registry ids are strings end-to-end.** User input is never converted to atoms (atom-exhaustion DoS).
- The test double (`Legend.Runtimes.Test`) is a real second runtime implementation — the seam is proven, and the whole session layer tests without PTYs or tokens.

## Sessions (the spine)

A session composes one harness with one runtime. The record (`Legend.Core.Agents.Session`, Ash/SQLite) and the process (`SessionServer` GenServer under a DynamicSupervisor, via-Registry by session id) are kept in **lockstep by construction**: the create action starts the process in an `after_transaction` hook (process start must stay outside the DB transaction — SQLite single writer); destroy stops it in `before_action`; runtime exit updates the record. No path lets them disagree.

- **Scrollback + offset protocol:** the server owns a bounded ring buffer (~256 KB, never drops the newest chunk) and broadcasts `{:session_output, chunk_offset, data}` with a monotonic byte offset. Channels subscribe *before* snapshotting and drop chunks below the snapshot offset — provably loss- and duplication-free reattach.
- **Channel surface:** `session:<id>` (join = status + base64 scrollback replay; in: input/resize/stop; out: output/exit/status), `sessions:lobby` ("changed" → clients refetch). Terminal bytes are base64 in JSON frames.
- **Exit ≠ deletion:** after the CLI exits the server stays alive in `:exited` so scrollback remains viewable until the session is deleted.
- **Sessions die with the backend** (accepted): a boot janitor marks orphaned `:starting/:running` records as failed so the UI never shows phantoms.
- Frontend reconnect: phoenix.js re-fires join hooks on rejoin — the scrollback snapshot is written exactly once (guard in `Terminal.svelte`).

## Shared library

One global tree (`knowledge/`, `skills/`, `artifacts/`, self-documented by seeded READMEs) shared by every session and the UI — the substrate for multi-agent handoffs.

- **Root resolution precedence:** `LIBRARY_PATH` env (ops override, renders read-only in the UI) > `Legend.Core.Settings` `"library_path"` > OS user-data default. Read-through on every call; editable live at `/settings`.
- **`Legend.Core.Library` is the single containment chokepoint** (lexical `Path.expand` check, validated *after* expansion so `~` can't escape). Agents access files directly via the filesystem (`$LEGEND_LIBRARY`, injected by the platform after `build_command`); the primer is delivered per-harness via the CLI's native context mechanism — **never PTY injection**.
- Filesystem is the only source of truth (no DB index); search/metadata is a future project.
- Accepted caveats (single-user loopback PoC): symlink escape, FS error atoms in API error bodies. Both must be revisited before any network-exposed deployment.

## Agent messaging & delegation (the signal bus)

Agents message each other, delegate, and hand off through Legend-provided MCP tools — the first realized slice of the vision's agent-to-agent story (`Legend.Core.Signals`).

- **Pairwise, no rooms (deliberate).** Every `Message` has exactly one recipient; a session's inbox is simply its unread rows (`read_at IS NULL`); `from_session_id: nil` is the human. Rooms/membership arrive later as a grouping layer — the envelope gains a `room_id` then; nothing here is thrown away. The human conducts on the *same bus* (`send_as_human` accepts only target + payload — sender/kind/read-state unforgeable) via the `/messages` timeline UI.
- **MCP endpoint, hand-rolled:** `POST /api/mcp` (first router scope) speaks the five JSON-RPC methods agents need — no MCP library by decision (the surface is tiny; `hermes_mcp` would also collide naming-wise with the Hermes harness). **The per-session bearer token (`Session.mcp_token`) is the caller's identity** — agents never assert who they are. Tool errors return as `isError` results with Ash internals stripped (never echo payloads/stack traces into an agent's context).
- **Five tools** (`Legend.Core.Signals.Tools`): `send_message` (`"requester"` resolves the spawner), `read_messages` (drain inbox), `start_agent` (delegate — spawns with `spawned_by_session_id` lineage + `instructions` as the CLI's initial prompt; the child auto-reports its exit to the spawner as a `:system` message), `handoff` (advisory baton — existing session, or a harness id to spawn with the summary as launch context), `list_agents`. `max_running_sessions` (default 10) bounds runaway delegation chains (check-then-spawn TOCTOU accepted).
- **Notify + pull delivery.** A message *into* a running terminal agent is one debounced nudge line written to its PTY ("N unread message(s) from X — call read_messages"); bodies never transit the TUI. This is the **only runtime PTY injection in the system**, and the label is sanitized (control chars stripped) at the `Terminal.nudge_line/3` chokepoint because session names are agent-controllable — anything new reaching `runtime.write/2` needs the same treatment. Scrollback parsing for output stays rejected. ACP/native harnesses later swap only this delivery adapter; the inbox semantics don't change.
- **Persist-then-broadcast:** message creation broadcasts on `inbox:<session_id>` (drives the nudge) and the global `signals` topic (drives the `signals:timeline` channel + unread badges); recipients never need to be alive at send time. Audit records created pre-read (e.g. handoff delivered at launch) hit the timeline but skip the inbox.

## Settings

`Legend.Core.Settings`: SQLite key-value, **not** on the JSON:API — settings with side effects (the library path seeds its tree on change) get dedicated plain controllers (`/api/settings/*`) with bespoke validation. `get_setting` fails loud on anything but NotFound (a broken settings store must not silently fall back to defaults).

## Web layer rules

- **Router order is load-bearing:** first `/api` scope (health, harnesses, library, settings, mcp) → `forward "/" → AshJsonApiRouter` (swallows the rest of `/api`) → SPA catch-all. New plain endpoints go in the first scope, never after the forward.
- Ash JSON:API serves resource CRUD (sessions, messages); plain controllers serve everything with bespoke semantics. Plain endpoints use a uniform `{"error": msg}` envelope.
- **Every domain in `ash_domains` must use the `AshJsonApi.Domain` extension, even with zero routes** — the router probes each domain's `json_api_match_route/2` in order, and one domain without it 500s every route owned by a *later* domain (this shipped once via Settings).
- Channels ride one unauthenticated `UserSocket` — acceptable only under the loopback single-user posture; **auth is mandatory before federation/any remote exposure** (recorded in the specs).

## Data & boot

- SQLite via AshSqlite; **no atomic updates** — every custom update action needs `require_atomic? false`.
- Boot order: Repo → Migrator → **library Seeder** (sync in `start_link`, returns `:ignore`; a raise aborts boot loudly — a bad library root must not boot a degraded app) → PubSub → Agents supervisor (registry, dynamic supervisor, janitor) → Endpoint.
- **Migrations run on boot in releases, detected by the absence of Mix** — not `RELEASE_NAME`, which the Burrito launcher doesn't set (this bug shipped once). Dev/test use `mix ecto.setup`. Gated by `AUTO_MIGRATE`.
- Config flow: dotenvy in `runtime.exs`; `backend/.env` (gitignored) in dev, real env always wins.

## Desktop (Tauri v2)

- `main.rs` owns the sidecar lifecycle: spawn `legend-server` with env (port 4807, DB path + persisted secret in the OS app-data dir), poll the port, show the window, kill the child on exit. Dev builds skip the sidecar (`just dev-desktop` uses the dev Phoenix).
- **Burrito caches extracted releases by app version and never invalidates** — rebuilding at an unchanged version silently runs stale code. Clear via the binary's `maintenance uninstall` or bump the version.
- Webview constraints: `window.confirm/alert/prompt` are no-ops (build in-UI confirmation); drag regions need the explicit `core:window:allow-start-dragging` capability (`core:default` doesn't include it).
- Release builds only via `backend/scripts/build-release.sh` (hook-enforced; also pins zig 0.15.2 for Burrito).

## Extension architecture (decided, not yet built)

Recorded in the specs so today's contracts don't need rework:
- **ACP harnesses** (`:acp` + `io: :pipes`) → rich structured UI for Claude Code/Gemini CLI.
- **Native harnesses** (`:native`) → in-BEAM agents (Jido candidate), no subprocess.
- **Cloud runtimes** → same `Runtime` behaviour; library materialization (mount/sync) is the runtime's job; `$LEGEND_LIBRARY` stays the location-transparent contract.
- **Rooms / group chat:** the built signal bus is pairwise; rooms add membership + a shared timeline as a grouping layer on top (`room:<id>` topics, envelope gains `room_id`). Humans stay first-class members. Into agents, only the delivery adapter varies: native → direct, ACP → prompt request, terminal → the existing nudge. Out of agents: native > ACP > the existing MCP tools > human relay.
- **Federation:** local + cloud instances; the local instance pairs outbound (reverse tunnel) and registers its sessions; auth arrives here at the latest.

## Spec index (full reasoning per feature)

- `docs/superpowers/specs/2026-06-11-agent-sessions-poc-design.md` — sessions, harness/runtime seams, kinds, communication model
- `docs/superpowers/specs/2026-06-11-shared-library-design.md` — library, storage seam, env/primer split, containment
- `docs/superpowers/specs/2026-06-12-settings-design.md` — settings store, root precedence, boot reordering
- `docs/superpowers/specs/2026-06-12-agent-messaging-design.md` — signal bus, MCP tools/endpoint, delegation/handoff, nudge delivery
- `docs/superpowers/specs/2026-06-10-legend-scaffold-design.md` — original stack/scaffold decisions
