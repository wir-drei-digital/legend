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
| **Harness** — *which agent* | `Legend.Core.Harness` (`definition/0`, kind enum, `resumable`; optional `setup/0`+`apply_setup/0`, `provision/0` → detect+install `CommandSpec`s) + `Legend.Core.Harness.Terminal` (`build_command/1` over `library`/`mcp`/`messaging`/`mode` opts; optional `nudge_line/2`) | `:terminal`: ClaudeCode, Hermes | `:acp` (JSON-RPC subprocess, rich UI), `:native` (in-BEAM, e.g. Jido) |
| **Runtime** — *where it executes* | `Legend.Core.Runtime` (`start/write/resize/stop` + `{:runtime_output,_}`/`{:runtime_exit,_}` owner messages; optional `capabilities/0` → `provisions?`/`library: :path\|:api`/`tunnel`, plus `exec/2`, `attach/2`, `teardown/1`) | `LocalPty` (erlexec, true PTY), **Sprites** (sprites.dev cloud sandbox: PTY over WSS exec, reattach-to-live, teardown) | Docker / other hosted sandboxes |
| **Tunnel** — *data plane for remote runtimes* | `Legend.Core.Tunnel` (`config :legend, :tunnels`; stream-mux reverse tunnel over a runtime's own proxy, so "compute remote, data local") | `SpriteProxy` (sprites `/proxy` WSS carrier with reconnect-on-drop; carries the MCP signal bus + `library_*` tools into `:api` sandboxes — Spec 2b) | per-runtime tunnels (WireGuard/direct); auto-paired federation |
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
- **Restart = suspend/resume, not death.** Agent processes still die with the backend (local PTYs are children of the BEAM), but the boot janitor marks orphans **`:interrupted`**, and a manual `:resume` action (allowed from `:interrupted` and `:exited`; never automatic — the human conducts) relaunches a fresh process into the *same conversation*: the `Terminal` contract's `mode: :fresh | :resume` maps to Claude Code's `--session-id <legend-id>` / `--resume <legend-id>` (our session id *is* the agent's conversation id; instructions omitted on resume). Non-resumable harnesses degrade to a fresh restart in the same cwd (`Definition.resumable` lets the UI say Resume vs Restart). Accepted: in-flight work dies at restart (the conversation resumes, not the interrupted turn) and pre-restart scrollback is gone (the agent redraws). On any (re)start, an unread inbox fires a catch-up nudge — the signal bus buffers across the outage.
- Frontend reconnect: phoenix.js re-fires join hooks on rejoin — the scrollback snapshot is written exactly once (guard in `Terminal.svelte`).
- **Capability-aware launch (cloud runtimes).** `SessionServer.init` resolves `Runtime.capabilities/0` and adapts: a `provisions?` runtime runs the harness's `provision/0` (detect → install, surfacing a **`:provisioning`** status while installing) before launch; a `library: :api` runtime opens its declared **Tunnel** (`capabilities.tunnel`) and is wired to reach the library + MCP signal bus over the loopback `base_url` (`LEGEND_MCP_URL` = `base_url <> "/api/mcp"`, an `:api` library primer pointing at the `library_*` MCP tools, no `LEGEND_LIBRARY` filesystem — Spec 2b); `:path` runtimes like LocalPty keep the filesystem library + endpoint MCP URL, unchanged. The runtime's opaque reattach handle is persisted as `Session.runtime_ref` (string-keyed, e.g. `%{"sprite","exec_id"}`); on `:resume` the server `attach`es to the still-live remote process instead of restarting (falling back to a fresh start if attach fails) and re-opens the tunnel, and on destroy it `teardown`s the remote (deletes the sprite) and closes the tunnel. The boot janitor sweeps `:provisioning` alongside `:starting`/`:running`.
- **Tunnel boundary (hardened, Spec 3).** Each cloud session's `SpriteProxy.Server` owns a **dedicated loopback Bandit listener on an OS-assigned ephemeral port** (no new config). `LegendWeb.TunnelPlug` mounts *only* `POST /api/mcp` (authenticated and session-bound via `LegendWeb.TunnelAuth` — wrong-session token → 403) and `GET /api/health`; every other route returns 404. The main Phoenix endpoint is unreachable through any tunnel. MCP dispatch is shared by both surfaces via `Legend.Core.MCP` (local sessions through `MCPController`, cloud sessions through the tunnel listener). The tunnel closes on `{:runtime_exit, _}` (not only on session delete): after `finish_session!`, `SessionServer` calls `maybe_close_tunnel` and nils `state.tunnel`, so the network path dies with the agent. `SpriteProxy.open/1` blocks until the carrier `{"status":"connected"}` ack arrives (`@ready_timeout_ms` = 15 s), so a session never launches against a not-yet-usable MCP URL. The bridge binary is content-addressed at `/tmp/legend-bridge-<sha8>` (first 8 hex chars of the SHA-256 of the binary the backend is delivering); a stale bridge from a prior version is detected and killed before the new one is launched.
- **Spawn policy.** `start_agent` inherits the caller's runtime by default (no `runtime` arg = same runtime as the caller). A remote caller (runtime with `tunnel != nil`) may not spawn a host runtime (`tunnel: nil, library: :path`, e.g. `local_pty`) — the check is capability-based, not id-based — unless `config :legend, :allow_remote_host_spawn` is set (default `false`, read at runtime). Local→cloud and same-runtime spawns remain open. `handoff` inherits the same path.
- **Mux limits (lockstep Elixir + Rust).** 1 MiB frame cap (`Mux.max_frame_payload/0` in `mux.ex`, `MAX_FRAME_PAYLOAD` in `bridge/src/mux.rs`); oversized frame → drop the carrier. 256 concurrent streams per tunnel (`@max_streams`); over-cap OPEN → CLOSE reply, no dial. 120 s per-stream idle timeout, swept every 30 s; Elixir side uses `active: :once` backpressure and re-arms after each `{:tcp, …}` delivery. Limits are identical on both sides of the wire by design.

## Shared library

One global tree (`knowledge/`, `skills/`, `artifacts/`, self-documented by seeded READMEs) shared by every session and the UI — the substrate for multi-agent handoffs.

- **Root resolution precedence:** `LIBRARY_PATH` env (ops override, renders read-only in the UI) > `Legend.Core.Settings` `"library_path"` > OS user-data default. Read-through on every call; editable live at `/settings`.
- **`Legend.Core.Library` is the single containment chokepoint** (lexical `Path.expand` check, validated *after* expansion so `~` can't escape). Agents access files directly via the filesystem (`$LEGEND_LIBRARY`, injected by the platform after `build_command`); the primer is delivered per-harness via the CLI's native context mechanism — **never PTY injection**.
- Filesystem is the only source of truth (no DB index); search/metadata is a future project.
- Accepted caveats (single-user loopback PoC): symlink escape, FS error atoms in API error bodies. Both must be revisited before any network-exposed deployment.

## Agent messaging & delegation (the signal bus)

Agents message each other, delegate, and hand off through Legend-provided MCP tools — the first realized slice of the vision's agent-to-agent story (`Legend.Core.Signals`).

- **Pairwise, no rooms (deliberate).** Every `Message` has exactly one recipient; a session's inbox is simply its unread rows (`read_at IS NULL`); `from_session_id: nil` is the human. Rooms/membership arrive later as a grouping layer — the envelope gains a `room_id` then; nothing here is thrown away. The human conducts on the *same bus* (`send_as_human` accepts only target + payload — sender/kind/read-state unforgeable) via the `/messages` timeline UI.
- **MCP endpoint, hand-rolled:** `POST /api/mcp` (first router scope, served by `MCPController`) speaks the five JSON-RPC methods agents need — no MCP library by decision (the surface is tiny; `hermes_mcp` would also collide naming-wise with the Hermes harness). **The per-session bearer token (`Session.mcp_token`) is the caller's identity** — agents never assert who they are. Tool errors return as `isError` results with Ash internals stripped (never echo payloads/stack traces into an agent's context). JSON-RPC dispatch lives in `Legend.Core.MCP` and is shared by both the main endpoint (local sessions via `MCPController`) and the per-session tunnel listeners (cloud sessions via `LegendWeb.TunnelPlug`).
- **Five tools** (`Legend.Core.Signals.Tools`): `send_message` (`"requester"` resolves the spawner), `read_messages` (drain inbox), `start_agent` (delegate — spawns with `spawned_by_session_id` lineage + `instructions` as the CLI's initial prompt; the child auto-reports its exit to the spawner as a `:system` message), `handoff` (advisory baton — existing session, or a harness id to spawn with the summary as launch context), `list_agents`. `max_running_sessions` (default 10) bounds runaway delegation chains (check-then-spawn TOCTOU accepted).
- **Notify + pull delivery.** A message *into* a running terminal agent is one debounced nudge line written to its PTY ("N unread message(s) from X — call read_messages"), with the submit CR written as a separate delayed keypress (`:nudge_submit_delay_ms`, default 150 — ink TUIs like Claude Code treat text+CR in one chunk as a paste and never submit it); bodies never transit the TUI. This is the **only runtime PTY injection in the system**, and the label is sanitized (control chars stripped) at the `Terminal.nudge_line/3` chokepoint because session names are agent-controllable — anything new reaching `runtime.write/2` needs the same treatment. Scrollback parsing for output stays rejected. ACP/native harnesses later swap only this delivery adapter; the inbox semantics don't change.
- **Persist-then-broadcast:** message creation broadcasts on `inbox:<session_id>` (drives the nudge) and the global `signals` topic (drives the `signals:timeline` channel + unread badges); recipients never need to be alive at send time. Audit records created pre-read (e.g. handoff delivered at launch) hit the timeline but skip the inbox.
- **Per-harness MCP registration.** Claude Code gets the server per launch (`--mcp-config` inline JSON + `--allowed-tools mcp__legend`). Hermes has no per-launch MCP flag — registration is a one-time entry in `$HERMES_HOME/config.yaml` (`mcp_servers.legend` with literal `${LEGEND_MCP_URL}` / `Bearer ${LEGEND_SESSION_TOKEN}` placeholders; Hermes interpolates `${VAR}` from the process env, and Legend injects exactly those vars into every spawned session). Standalone Hermes runs leave the placeholders unresolved and that server just fails to connect — a harmless logged warning. Legend applies this entry itself through the **harness setup seam** (below); without it, Hermes sessions run fine but can't see the signal-bus tools (the documented terminal-fallback posture).
- **Harness setup seam.** Harnesses with one-time host-machine setup needs export two *optional* callbacks (the `nudge_line` pattern): `setup/0` returning a self-describing `Legend.Core.Harness.Setup` struct (`status` ok/missing/error/not_applicable, `summary` of what Apply will do, `detail` error/manual snippet, `restart_hint`) and `apply_setup/0`. The UI renders only harness-provided fields — zero harness strings in the frontend. `GET /api/harnesses` carries the setup object; `POST /api/harnesses/:id/setup` applies it, and **only ever fires from an explicit button click** (consent — it writes a file in `$HOME` Legend doesn't own). Surfaces: inline notice in the new-session dialog (dismissal in `localStorage`, per-harness) + a Harness integrations card at `/settings` (the durable affordance). First implementer: `Legend.Harnesses.Hermes.McpSetup` — YAML round-trip via yaml_elixir/ymlr (comment/key-order loss accepted; matches Hermes' own tooling) with `config.yaml.legend-backup` + atomic tmp/rename write; never writes into a file it can't parse. One setup unit per harness (no multi-step framework — YAGNI). Spec: `superpowers/specs/2026-06-12-harness-setup-design.md`.

## Settings

`Legend.Core.Settings`: SQLite key-value, **not** on the JSON:API — settings with side effects (the library path seeds its tree on change) get dedicated plain controllers (`/api/settings/*`) with bespoke validation. `get_setting` fails loud on anything but NotFound (a broken settings store must not silently fall back to defaults).

## Web layer rules

- **Router order is load-bearing:** first `/api` scope (health, harnesses, library, settings, mcp) → `forward "/" → AshJsonApiRouter` (swallows the rest of `/api`) → SPA catch-all. New plain endpoints go in the first scope, never after the forward.
- Ash JSON:API serves resource CRUD (sessions, messages); plain controllers serve everything with bespoke semantics. Plain endpoints use a uniform `{"error": msg}` envelope.
- **Every domain in `ash_domains` must use the `AshJsonApi.Domain` extension, even with zero routes** — the router probes each domain's `json_api_match_route/2` in order, and one domain without it 500s every route owned by a *later* domain (this shipped once via Settings).
- Channels ride one unauthenticated `UserSocket` — acceptable only under the loopback single-user posture; **auth is mandatory before federation/any remote exposure** (recorded in the specs).

### Design system

- **Token layer** (`frontend/src/routes/layout.css`): the raw `--bg-*` / `--text-*` / `--accent*` tokens are the source of truth; shadcn's semantic vars (`--background`, `--primary`, …) are **mapped onto them** so every shadcn component inherits the dark palette for free. Type scale (`text-micro…title`), elevation (`shadow-pop/overlay/drag`) and control heights (`--h-bar`/`--h-row`) are `@theme` utilities.
- **Primitive layer** (`frontend/src/lib/components/shell/`): small Svelte 5 components baking those tokens into recurring shapes (`IconButton`, `Surface`, `Popover`, `MenuItem`, `ConfirmButton`, `SectionLabel`, `SidePane`(+Section/Field), `WorkbenchLayout`, …). Feature code composes these, never raw classes.
- **The shadcn semantic mapping is the seam:** re-theming is swapping `--accent`; `src/lib/components/ui/` is the only place shadcn semantic classes appear. Dark only, no runtime switcher.
- **Canonical reference:** [DESIGN_SYSTEM.md](DESIGN_SYSTEM.md) — keep it in sync when either layer changes.

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
- **Cloud runtimes** → **built (Sprites, Spec 2a):** the optional `Runtime` callbacks (`capabilities`/`exec`/`attach`/`teardown`) + harness `provision/0` carry "spin up an agent in a cloud sandbox with one click" — provisioned, PTY over the sprites WSS exec, reattach-to-live on resume, destroy-on-delete. **Built (Spec 2b):** the reverse Tunnel carries the MCP signal bus + the `library_*` MCP tools into the sandbox over a loopback `base_url`, with carrier reconnect across sprite hibernation — so a cloud agent messages other agents and reads/writes the shared library exactly like a local one. The default sprite image already ships Claude Code, so provisioning is usually a no-op detect. **Built (Spec 3 / tunnel hardening):** the tunnel surface is narrowed to a per-session loopback listener (MCP + health only, auth + session binding), closed on agent exit, spawn-policy-gated (remote→host denied by default), mux-bounded, and launch is gated on carrier readiness — see the Sessions section for details.
- **Rooms / group chat:** the built signal bus is pairwise; rooms add membership + a shared timeline as a grouping layer on top (`room:<id>` topics, envelope gains `room_id`). Humans stay first-class members. Into agents, only the delivery adapter varies: native → direct, ACP → prompt request, terminal → the existing nudge. Out of agents: native > ACP > the existing MCP tools > human relay.
- **Fully detached sessions (true survival):** today's resume model is suspend/resume — in-flight work dies at restart. The upgrade is a detacher owning the PTY *outside* the BEAM (tmux `legend-<id>` sessions for dev; a bundled dtach/abduco for the self-contained desktop, with scrollback self-persisted to disk so detachers stay interchangeable), letting agents keep working while the backend is down; the boot pass then *reattaches* instead of marking interrupted. ACP harnesses answer the same "can this session come back?" question with `session/load` (a pipe-holding relay would be their true-survival analog). `:interrupted` + `:resume` remain the fallback when the detached session is gone.
- **Federation:** local + cloud instances; the local instance pairs outbound (reverse tunnel) and registers its sessions; auth arrives here at the latest.

## Spec index (full reasoning per feature)

- `docs/superpowers/specs/2026-06-11-agent-sessions-poc-design.md` — sessions, harness/runtime seams, kinds, communication model
- `docs/superpowers/specs/2026-06-11-shared-library-design.md` — library, storage seam, env/primer split, containment
- `docs/superpowers/specs/2026-06-12-settings-design.md` — settings store, root precedence, boot reordering
- `docs/superpowers/specs/2026-06-12-agent-messaging-design.md` — signal bus, MCP tools/endpoint, delegation/handoff, nudge delivery
- `docs/superpowers/specs/2026-06-12-harness-setup-design.md` — harness setup seam, Hermes MCP config writer, consent-gated apply
- `docs/superpowers/specs/2026-06-12-session-resume-design.md` — interrupted status, resume action, suspend/resume vs detacher
- `docs/superpowers/specs/2026-06-13-sprites-reverse-tunnel-design.md` — Tunnel seam, stream-mux reverse tunnel over sprites' `/proxy` (Spec 1 of the cloud-runtime work)
- `docs/superpowers/specs/2026-06-14-sprites-runtime-design.md` — Sprites runtime, Runtime optional callbacks, harness provisioning, `:provisioning`/`runtime_ref`, reattach-to-live (Spec 2a)
- `docs/superpowers/specs/2026-06-14-sprites-library-messaging-over-tunnel-design.md` — tunnel bring-up, `library_*` MCP tools, SessionServer tunnel wiring + `base_url` MCP rewrite (Spec 2b)
- `docs/superpowers/specs/2026-06-15-cloud-tunnel-hardening-design.md` — tunnel boundary narrowing (per-session listener, TunnelPlug/TunnelAuth, Legend.Core.MCP), close-on-exit, spawn policy, mux limits, carrier readiness gate, bridge versioning, UI compatibility guard (Spec 3)
- `docs/superpowers/plans/2026-06-15-cloud-tunnel-hardening.md` — implementation plan for Spec 3 (12 tasks, 3 phases)
- `docs/superpowers/specs/2026-06-10-legend-scaffold-design.md` — original stack/scaffold decisions
