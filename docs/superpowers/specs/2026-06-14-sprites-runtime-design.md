# Sprites Terminal Runtime + Provisioning (Spec 2a) — Design

**Date:** 2026-06-14
**Status:** Draft
**Builds on:** agent sessions PoC (`2026-06-11-agent-sessions-poc-design.md`), harness setup seam (`2026-06-12-harness-setup-design.md`), sprites reverse tunnel (`2026-06-13-sprites-reverse-tunnel-design.md`)
**Part of:** the cloud-runtime effort. This is **Spec 2a**. **Spec 2b** — *library + messaging over the tunnel* (the new MCP library tools, runtime-aware `:path`/`:api` injection, wiring the Spec-1 tunnel into `SessionServer`) — is a separate spec and is **out of scope here**.

## Problem

Today every session runs under `Legend.Runtimes.LocalPty` — a true PTY on the machine the backend runs on. We want a **second runtime** that runs the agent in a [sprites.dev](https://sprites.dev) cloud sandbox: pressed from the same new-session dialog, the agent boots in a persistent Firecracker microVM, streams into the embedded terminal, **keeps running when the laptop closes**, reattaches on return, and is destroyed when the session is deleted.

A fresh sprite has neither the agent CLI nor credentials. So this spec also introduces **provisioning** (the harness installs its own CLI into the runtime) and relies on **interactive first-run auth** persisted in the sprite.

This spec uses **only the control plane** — create/exec/PTY against `api.sprites.dev`, all outbound from the backend. It does **not** use the Spec-1 reverse tunnel; a 2a cloud agent runs but is **not yet connected** to the shared library or agent-to-agent messaging (that is Spec 2b). Keeping 2a tunnel-free makes it independently buildable and testable.

## Scope

**In 2a:** the `Runtime` behaviour extensions; `Legend.Runtimes.Sprites` (create/wake, PTY over WSS exec, `exec` for provisioning, `attach` for reattach-to-live, hibernate, `teardown`); the harness `provision/0` install contract + a Claude Code installer; the `SessionServer` launch flow (`:provisioning` status, capability-aware env) and reattach-on-resume; sprite-per-session lifecycle incl. teardown-on-delete; the new-session UI (a new `/api/runtimes` endpoint + runtime dropdown, sprite-side `cwd`, provisioning indicator, clean incompat failure).

**Deferred to 2b:** the MCP **library tools**; runtime-aware `:path` vs `:api` library/messaging **injection**; wiring the Spec-1 tunnel into `SessionServer`; the library primer reframe. In 2a a `:api`-library runtime simply gets **no** library/MCP env injected (the localhost URLs LocalPty uses are unreachable from a sprite; wiring the tunnel is 2b's job).

**Out of scope entirely (later):** agent-*spawned* cloud sessions (no human present to complete first-run auth — needs injected credentials, a future option); custom/prebuilt sprite images; non–Claude-Code harnesses in the cloud (each needs its own `provision/0`).

## Decisions

### 1. `Legend.Core.Runtime` grows four optional callbacks (LocalPty opts out of all)

```elixir
@callback capabilities() :: %{
            optional(:provisions?) => boolean(),     # can run install commands
            optional(:library) => :path | :api,      # how the library is exposed (2b consumes)
            optional(:tunnel) => String.t() | nil     # tunnel id this runtime needs (2b consumes)
          }
@callback exec(handle(), CommandSpec.t()) :: {:ok, %{stdout: binary(), status: integer()}} | {:error, String.t()}
@callback attach(reattach_ref(), start_opts()) :: {:ok, handle()} | {:error, String.t()}
@callback teardown(handle() | reattach_ref()) :: :ok
@optional_callbacks capabilities: 0, exec: 2, attach: 2, teardown: 1
```

A `Legend.Core.Runtime.capabilities/1` resolver returns sane defaults for runtimes that don't export it: `%{provisions?: false, library: :path, tunnel: nil}`. **LocalPty exports none of these** — it is `:path`, non-provisioning, no tunnel, no remote exec/attach/teardown. So LocalPty is untouched by this spec.

### 2. `Legend.Runtimes.Sprites`

Built on the `Legend.Sprites.Client` from Spec 1 (extended with the interactive WSS exec).

- **`start(spec, opts)`** — `create_sprite` (idempotent: name = session id; if it already exists, wake it) → open an **interactive PTY over the WSS exec** endpoint running `spec.cmd spec.args` with `spec.env`, `cwd`, and a PTY sized to `opts.rows/cols`. A relay process forwards exec-session stdout to the owner as `{:runtime_output, data}` and the session's end as `{:runtime_exit, code}` — the **exact same contract LocalPty uses**, so `SessionServer` is transport-agnostic. Returns a handle `%{sprite: name, exec_id: id, relay: pid}`.
- **`write/2`, `resize/3`, `stop/1`** — map to the exec session (stdin, resize, terminate) over the WSS.
- **`exec(handle, spec)`** — non-interactive HTTP POST exec; returns stdout + exit status. Used for provisioning detect/install.
- **`attach(ref, opts)`** — reconnect to the **live** exec session of an existing sprite (sprites' "attach to exec session"); same relay/owner contract. Used on resume.
- **`teardown(ref)`** — `delete_sprite`. Idempotent (already-gone is `:ok`).
- **`capabilities/0`** — `%{provisions?: true, library: :api, tunnel: "sprite_proxy"}`.

### 3. Provisioning — harness installs its own CLI

`Legend.Core.Harness` gains one **optional** callback, in the style of the existing `setup/0`:

```elixir
@callback provision() :: %{detect: CommandSpec.t(), install: CommandSpec.t()} | nil
@optional_callbacks provision: 0
```

`Legend.Harnesses.ClaudeCode.provision/0` returns `detect: claude --version`, `install:` the official Claude Code installer (exact command pinned in the plan). A harness without `provision/0` simply **cannot run on a provisioning runtime** → clean failure (see §6).

**Default image + install-on-first-boot:** we rely on sprites' default image and install the CLI at first boot. The persistent filesystem means a sprite installs once; later wakes/reattaches skip it.

### 4. Auth (option B — interactive, persisted; baseline = `setup-token` paste)

The agent authenticates **in the PTY, by the human, on first open**, and credentials persist in the sprite's filesystem (`~/.claude`) across hibernation — Legend stores **no** model credential. Naïve browser-OAuth is dead in a headless sprite: the callback listener is on the *sprite's* `localhost` but the browser redirect resolves on the *user's laptop* ([claude-code #42965](https://github.com/anthropics/claude-code/issues/42965)).

- **2a baseline — `claude setup-token` (paste-code, headless-friendly):** the human runs token setup in the PTY; it prints a URL, the human opens it in their laptop browser, and pastes the resulting token back into the PTY (no localhost callback involved). The token is saved to `~/.claude` in the sprite and survives hibernation → one-time per sprite.
- **Verify during live bring-up:** the callback OAuth was reportedly fixed in Claude Code ≥ 2.1.126; if native `claude` login actually works in a sprite PTY on the shipped version, prefer it (simpler for the user). Also pin the exact first-launch UX — whether the runtime drops the human into a **shell** (to run `claude setup-token`) or `claude`'s own first-run offers the paste path.
- **Fast-follow (not in 2a) — forwarded OAuth for one-click native login:** Claude Code's callback port is fixed at `localhost:54545`, and Spec 1's `…/proxy` client can forward laptop `:54545` → sprite `:54545`, so a small callback-forwarder would let the normal browser login complete transparently. Deferred to keep 2a simple and **tunnel-free**; enabled later by the existing proxy primitive.
- **Agent-*spawned* cloud sessions remain out of scope** (no human to complete first-run auth); harness-declared injected credentials (option A) are the later addition for those, and don't disturb B.

### 5. `SessionServer` launch + reattach flow

`init({session, mode})` becomes runtime-capability-aware:

1. Resolve harness + runtime + `capabilities`.
2. **Provision** (only if `capabilities.provisions?` *and* harness exports `provision/0`): `runtime.exec(detect)`; on non-zero, broadcast a new **`:provisioning`** status (UI shows "Installing Claude Code…") and `runtime.exec(install)`. If the harness has no `provision/0` on a provisioning runtime → fail cleanly.
3. Build the command. **Capability-aware env:** `:path` runtimes get today's library/MCP injection (`LEGEND_LIBRARY` path, localhost `LEGEND_MCP_URL`, etc.). **`:api` runtimes get NONE of that in 2a** — `build_opts` omits `:library`/`:mcp`, and `platform_env` skips the localhost URLs. (2b fills this in via the tunnel.)
4. `mode == :fresh` → `runtime.start`. `mode == :resume` → if the runtime exports `attach/2` and a `runtime_ref` is present, `runtime.attach(ref, …)` to reconnect to the **live** exec session; otherwise fall back to `runtime.start` (fresh process in the persisted sprite — workspace/auth intact, conversation via `claude --resume`).
5. On `start`/`attach` success, persist the handle's reattach ref to the session record (new nullable **`runtime_ref`** attribute — opaque, e.g. `%{sprite, exec_id}`), so a backend restart can reattach.

Auth (B) needs no special handling here: it's just the human typing into the PTY on first open.

### 6. Lifecycle

- **1 session : 1 sprite**, named by session id (deterministic → reattach finds it).
- Disconnect/backend-restart: the sprite + its exec session keep running in the cloud. The boot **janitor** marks the orphaned session `:interrupted` (existing behavior); **resume** reattaches to the live exec session.
- **Session `destroy`** → after stopping the server, call `runtime.teardown(ref)` to **DELETE the sprite** (idempotent). LocalPty has no `teardown` → no-op. This is the one place a session delete now reaches into external infrastructure.
- Idle sprites **hibernate** (sprites-managed; ~0 compute). The session list is the management surface — deleting a session is the only cleanup needed.

### 7. UI (minimal for 2a)

The new-session dialog currently has a **harness** selector but **no runtime selector** (runtime defaults to `local_pty` server-side), and there is no runtime-listing API. So 2a **adds** a `GET /api/runtimes` endpoint (mirroring `/api/harnesses`) and a runtime dropdown. Additions:

- `cwd` for a sprite session is a **sprite-side path** (default to a workspace dir like `/root` or `~`), not the host directory picker — the field's helper/validation adapts when a non-`:path` runtime is selected.
- A **`:provisioning`** status badge/line ("Installing Claude Code…") between `:starting` and `:running`.
- **Incompatible harness×runtime** (a harness with no `provision/0` selected on a provisioning runtime, or otherwise unrunnable) fails cleanly: the session goes `:failed` with a clear message (the existing start flow already renders `:failed` + error), not a hang.

## Data flow

**Fresh launch (human-initiated, sprites + Claude Code):**
```
new session → SessionServer.init
  → Sprites.start: create_sprite(name=session_id)
  → capabilities.provisions? + ClaudeCode.provision/0:
       exec "claude --version"  → not found
       status :provisioning      (UI: "Installing Claude Code…")
       exec <install claude>
  → Sprites.start opens WSS exec PTY running `claude <args>`  → status :running
  → human completes first-run auth in the embedded terminal   (persists in sprite ~/.claude)
  → agent runs in the cloud
```

**Resume (after disconnect / backend restart):**
```
janitor marked it :interrupted; sprite + agent still running in the cloud
resume → SessionServer.init(mode: :resume)
  → Sprites.attach(runtime_ref) → reconnect stdin/stdout to the LIVE exec session
  → status :running; you see output from the reattach point forward
```
**Reattach scrollback caveat (accepted):** on reattach you see the exec session's output from the reconnect point onward; full scrollback-since-disconnect is not guaranteed (the TUI typically redraws on attach/resize).

## Error handling

- **No `provision/0` on a provisioning runtime** → `:failed`, message "harness X has no installer for runtime Y".
- **Install fails** (`exec` non-zero) → `:failed` with the install stderr in `error`; sprite left for inspection (teardown only on explicit delete).
- **Sprite create/exec API errors** (bad `SPRITES_TOKEN`, quota, network) → `:failed` with the client's `{:error, msg}`.
- **Reattach to a dead/absent exec session** → fall back to a fresh `start` in the (still-persistent) sprite; if the sprite itself is gone, `:failed`.
- **`teardown` on an already-deleted sprite** → `:ok` (idempotent); a teardown failure is logged but does not block session-record deletion.
- **Auth not completed** by the human → the agent CLI sits at its prompt; benign (no Legend-side error).

## Testing

- **Runtime contract / capability resolver** (unit): `Legend.Core.Runtime.capabilities/1` returns defaults for a runtime without the callback; LocalPty resolves to `%{provisions?: false, library: :path, tunnel: nil}`.
- **Provisioning dispatch** (unit, fake runtime + fake harness): detect-found → no install; detect-missing → install runs and `:provisioning` is broadcast; harness without `provision/0` on a provisioning runtime → `:failed` with the right message. Driven through `SessionServer` with a `Legend.Runtimes.Test`-style fake exposing `exec`/`capabilities` (extend the existing test runtime).
- **Capability-aware env** (unit): a `:path` runtime gets `LEGEND_LIBRARY`/localhost MCP injected (today's behavior, unchanged); a `:api` runtime gets neither in 2a.
- **Reattach selection** (unit): `mode: :resume` with a `runtime_ref` + an `attach/2`-capable runtime calls `attach`; without `attach/2` or `runtime_ref`, calls `start`.
- **`Sprites` client/runtime** (gated on `SPRITES_TOKEN`, opt-in): create → start a trivial PTY command → see output → `exec` a detect → `teardown`. Live PTY-over-WSS + attach are verified here.
- **Manual acceptance** (needs token + the Spec-1 musl bridge is NOT required for 2a): pick *sprites + Claude Code* in the UI → watch `:provisioning` → terminal shows Claude Code → complete auth → run a task; close the laptop/stop the backend → reopen → resume reattaches to the live agent; delete the session → sprite is destroyed (`get_sprite` 404).
- `mix precommit` green.

## Open questions (resolved in planning, not left vague)

- **Sprites WSS interactive-exec + attach protocol** — exact frames for stdin/stdout/resize and how to obtain + reattach an exec-session id. Probe live with `SPRITES_TOKEN` (now available) and pin in the plan; extends `Legend.Sprites.Client`.
- **Claude Code installer + headless auth** — the exact install command; whether first launch drops into a shell or runs `claude` directly (per §4); whether native callback OAuth works on the shipped Claude Code (≥ 2.1.126) inside a sprite PTY (prefer it if so) or we use the `setup-token` paste baseline. Verify live with `SPRITES_TOKEN`.
- **`cwd` default** for sprite sessions and the workspace path the agent starts in.
- **`runtime_ref` shape** — persisted attribute carrying enough to reattach (sprite name is derivable from session id; the exec-session id is the part worth storing).

## Decisions log

| Decision | Rationale |
|---|---|
| 2a is tunnel-free (control plane only); library/messaging is 2b | A cloud agent that merely *runs* is independently buildable/testable; connecting it to the orchestration fabric is the separable, higher-value second layer |
| Runtime callbacks optional; LocalPty exports none | Zero change to the working local runtime; the cloud runtime opts into provisioning/exec/attach/teardown |
| Same `{:runtime_output}`/`{:runtime_exit}` contract for the WSS PTY | `SessionServer` stays transport-agnostic — a sprite PTY and a local PTY look identical to it |
| Provisioning = harness `provision/0` (detect+install), like `setup/0` | The runtime is "just a place"; the harness knows how to make itself exist there. Agnostic and consistent with the existing setup seam |
| Default image + install-on-first-boot | No image to maintain; sprite persistence makes install a one-time cost; matches the agnostic model |
| Auth = interactive in PTY, persisted (option B); baseline `claude setup-token` paste | Keeps "human completes auth, Legend stores nothing"; sprite persistence makes it one-time. Native callback OAuth (fixed if Claude Code ≥ 2.1.126) preferred if it works live; forwarded-OAuth via the Spec-1 proxy is a fast-follow. Injected creds (A) deferred until agent-spawned cloud sessions need them |
| Reattach-to-live on resume (`attach/2`) | Core to "always-on": reconnects to the agent that kept running; avoids orphaning or killing in-flight work. Scrollback-from-reattach-point accepted |
| Capability-aware `SessionServer` env; `:api` gets no library/MCP in 2a | The seam where 2b plugs the tunnel in; keeps 2a honest (no broken localhost URLs in the sprite) |
| `teardown` only on session delete; idle = hibernate | Session list is the management surface; hibernation is ~0 compute; delete is the single explicit cleanup |
| New nullable `runtime_ref` on the session | Reattach must survive a backend restart, so the reattach handle is persisted, not held only in `SessionServer` state |
