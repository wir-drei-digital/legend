# Rich composer config controls — design

Date: 2026-06-22
Status: approved (design); pending implementation plan

## Goal

Add to the rich-mode (ACP) chat composer four controls the user asked for:

1. **Permission mode** selector
2. **Model** selector
3. **Thinking strength** selector
4. **Context indicators**

## Feasibility grounding (installed adapter)

Evidence gathered from the *installed* adapter
`@zed-industries/claude-code-acp@0.13.1` (dep `@agentclientprotocol/sdk@0.13.0`,
`@anthropic-ai/claude-agent-sdk@0.2.7`) at
`~/.nvm/versions/node/v25.4.0/lib/node_modules/@zed-industries/claude-code-acp/dist/acp-agent.js`,
corroborated against the ACP spec (agentclientprotocol.com).

| Control | Adapter support | Mechanism |
| --- | --- | --- |
| Permission modes | ✅ full | `session/new` result `modes.{availableModes, currentModeId}` (5 modes: `default`, `acceptEdits`, `plan`, `dontAsk`, `bypassPermissions`); `session/set_mode` RPC; `current_mode_update` notification. `set_mode` is already wired end-to-end in Legend. |
| Models | ✅ yes | `session/new` result `models.{availableModels, currentModelId}` (from the Agent SDK's `supportedModels()`); a model-set RPC (`setSessionModel` handler; marked `unstable` in the SDK). No model-update notification is emitted. |
| Thinking strength | ⚠️ no runtime control | Adapter only reads `MAX_THINKING_TOKENS` **at launch**; there is no mid-session ACP method and it does not implement the spec's `thought_level` config option. |
| Context / token usage | ❌ none | Adapter emits **no** `usage_update` and no token/context fields anywhere over ACP. No real meter is possible. |

The protocol's newer "Session Config Options" API (`session/set_config_option` +
`config_option_update`, unifying mode/model/thought_level) is **not implemented**
by this adapter, so we build against the standalone `modes`/`models` +
`set_mode`/`set_model` surface it actually speaks. (Clean-over-compat: target the
installed adapter; revisit if/when it adopts config options.)

## Product decisions

- **Thinking strength → per-message keyword.** A sticky composer selector
  `{off · think · think harder · ultrathink}`; on send, the keyword is appended
  to the prompt text (Claude Code reads it to scale the thinking budget). It is
  visible in the sent user bubble — acceptable, since it is literally what is sent.
- **Context indicators → honest counters only.** Show concrete facts the UI
  already has (turn count, tool-call count). No fabricated token/percent numbers,
  since the adapter exposes none. (cwd already shows in the pane header; current
  model/mode live in their own chips.)

## Architecture

### A. Backend — surface adapter config to the timeline

`backend/lib/legend/core/acp/connection.ex`:

- `handle_response(:session_new, result)` (and `:session_load`) — extract
  `result["modes"]` and `result["models"]` and emit two singleton render items
  via the returned items list (these flow through `SessionServer.append_acp_item`
  exactly like the existing `mode`/`commands` singletons):
  - `%{"id" => "mode", "type" => "mode", "current" => currentModeId,
       "available" => [%{"id","name","description"}]}`
  - `%{"id" => "model", "type" => "model", "current" => currentModelId,
       "available" => [%{"id","name","description"}]}`
  - Guard on presence: omit an item if the result lacks that object.
  - Factor a small helper to build these from a result map (DRY across new/load).
- `reduce_update(_, u, "current_mode_update")` — set only `"current"`; the
  `AcpTimeline` merge-by-id preserves `available` from the handshake item. (Field
  renamed from `"mode"` to `"current"`; the frontend is updated in lockstep.)
- Add `set_model/2` mirroring `set_mode/2`. Wire method **`session/set_model`**
  with params `%{"sessionId" => ..., "modelId" => model_id}` — confirmed from the
  SDK's `AGENT_METHODS` table (`@agentclientprotocol/sdk@0.13.0`
  `dist/schema/index.js`: `session_set_model: "session/set_model"`). The adapter's
  `unstable_` prefix is only on its TS method name, not the wire method.

`backend/lib/legend/core/agents/session_server.ex`:

- `acp_set_model(id, model)` client fn + `handle_cast({:acp_set_model, model},
  %{transport: :acp})` → write `Connection.set_model` frames, then optimistically
  `append_acp_item` an updated `%{"id" => "model", "current" => model}` (no
  model-update notification exists, so the timeline stays authoritative for
  reattach). No-op clauses for exited/terminal sessions mirror the other casts.

`backend/lib/legend_web/channels/session_channel.ex`:

- `handle_in("set_model", %{"model" => model}, socket) when is_binary(model)` →
  `SessionServer.acp_set_model(...)`.

### B. Frontend — store

`frontend/src/lib/shell/acpSession.svelte.ts`:

- `setModel: (model) => chan.push('set_model', { model })`.
- (Existing `setMode` unchanged.)

`frontend/src/lib/components/sessions/AcpConversation.svelte`:

- Derive `mode` and `model` as `{current, available}` from the `mode`/`model`
  singleton items; pass both (+ `onSetMode`, `onSetModel`) to the composer.

### C. Frontend — composer controls

`frontend/src/lib/components/sessions/acp-parts/Composer.svelte`. Button row:
`[＠ Add context] —spacer— [model ▾] [mode ▾] [think ▾] [send/stop/queue]`,
`flex-wrap` on narrow widths, all chips in the established style
(`rounded-sm border border-hair-strong bg-panel px-2 py-1 text-meta text-ink-2
hover:bg-raised`).

- **Mode** ▾ — dropdown of `available` modes (name; description as tooltip);
  current one checked; select → `onSetMode(id)`. Replaces the no-op cycle chip.
- **Model** ▾ — dropdown of `available` models; select → `onSetModel(id)`
  (optimistic; backend also appends the updated `model` item).
- **Think** ▾ — client-only sticky `{off, think, think harder, ultrathink}`.
  On `submit`, when not `off`, append the keyword to the trimmed prompt text
  before `onPrompt`/enqueue. State is local to the composer (lift to a
  SessionPane-owned object later only if cross-remount persistence is wanted —
  YAGNI for v1).
- Dropdowns open **upward** (composer sits at the bottom of the pane). Use the
  existing menu/popover primitive used elsewhere in the shell; verify it is not
  clipped by an `overflow` ancestor (the dock is a separate flex child from the
  scrolling stream, so it should be safe; confirm in-browser).

### D. Frontend — context counters

A compact, right-aligned segment on the existing composer footer row (next to the
`⏎ send · ⇧⏎ newline` hint): **`{turns} turns · {tools} tools`**, derived live
from `acp.items` — `turns` = count of `type === "turn"` items, `tools` = count of
`type === "tool"` items. `text-meta text-ink-3`. No token/percent values.

## Data flow

```
session/new result ──▶ connection.ex extracts modes+models
                       └─▶ emits {id:"mode"|"model", current, available} items
                           └─▶ SessionServer.append_acp_item ─▶ broadcast {:session_event}
                               └─▶ store upsert ─▶ AcpConversation derives {current, available}
                                   └─▶ Composer renders Mode/Model dropdowns

Composer select mode  ─▶ onSetMode  ─▶ chan "set_mode"  ─▶ Connection.set_mode  ─▶ agent
                                                          (agent ─▶ current_mode_update ─▶ updates "mode".current)
Composer select model ─▶ onSetModel ─▶ chan "set_model" ─▶ Connection.set_model ─▶ agent
                                                          (+ optimistic "model".current append)
Composer think level  ─▶ (client only) append keyword to prompt text on send
Composer counters     ─▶ derived from acp.items (turn/tool counts)
```

## Testing

Backend (TDD, `test/legend/core/agents/session_server_acp_test.exs` +
`test/legend/core/acp/connection_test.exs`):

- `session/new` result carrying `modes`/`models` broadcasts `mode` and `model`
  items with `current` + `available`.
- `current_mode_update` updates `mode.current` while preserving `available`.
- `acp_set_model` writes the correct model-set frame and appends an optimistic
  `model` item with the new `current`.
- Channel `set_model` push routes to `acp_set_model`.

Frontend: `bun run check` (svelte-check) clean; live browser pass on a fresh
session — mode/model dropdowns populate from the handshake, switching works,
counters increment as turns/tools arrive, the thinking keyword is appended to the
sent message.

## Non-goals / accepted caveats

- No Session Config Options (`session/set_config_option`) — unimplemented by the
  adapter.
- No real token/context meter — no data over ACP from this adapter.
- No launch-time `MAX_THINKING_TOKENS` wiring — thinking is per-message keyword.
