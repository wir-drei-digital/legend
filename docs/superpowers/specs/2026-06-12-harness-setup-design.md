# Harness Setup Seam (first implementation: Hermes MCP registration) — Design

**Date:** 2026-06-12
**Status:** Approved
**Builds on:** agent messaging (`2026-06-12-agent-messaging-design.md`)

## Problem

Hermes has no per-launch MCP flag, so connecting it to Legend's signal-bus tools requires a one-time entry in `~/.hermes/config.yaml` (env-placeholder URL + bearer token that Hermes interpolates from the per-session environment Legend injects). Today that's a manual operator step nobody discovers: Hermes sessions silently run tool-blind. Other harness kinds (ACP, native) will have analogous one-time host-machine setup needs.

Legend should detect missing setup, explain it, and apply it — **only with explicit user consent**, since it writes a file in the user's `$HOME` that Legend does not own.

## Decision: a generic, self-describing setup seam

Not a Hermes-specific endpoint. The `Legend.Core.Harness` behaviour gains two **optional** callbacks (same pattern as `nudge_line`); harnesses that don't export them are implicitly `not_applicable` and invisible in the UI:

```elixir
@callback setup() :: Legend.Core.Harness.Setup.t()
@callback apply_setup() :: :ok | {:error, String.t()}

%Legend.Core.Harness.Setup{
  status: :ok | :missing | :error | :not_applicable,
  summary: String.t(),     # what Apply will do — rendered on the prompt/card
  detail: String.t() | nil,# error explanation / manual-fix snippet (copyable), shown on :error
  restart_hint: boolean()  # running sessions of this harness need restart to pick the setup up
}
```

The UI renders only harness-provided fields — zero harness-specific strings in the frontend. One setup unit per harness (deliberate YAGNI: no multi-step lists, no parameterized forms; a harness with several needs composes them behind its own `setup/0`).

## First implementation: `Legend.Harnesses.Hermes.McpSetup`

The Hermes harness module delegates its `setup/0` / `apply_setup/0` to this sibling module.

- **Locate:** Hermes home = `HERMES_HOME` env > `~/.hermes`. Directory absent → `:not_applicable` (Hermes isn't installed; never prompt).
- **Check:** parse `config.yaml` with yaml_elixir. `mcp_servers.legend` key present → `:ok`. Key absent, or file missing while the home dir exists → `:missing`. Unparseable YAML → `:error` with the manual snippet in `detail` — **never write into a file we can't read**.
- **Apply (YAML round-trip — accepted tradeoff):** read → set
  `mcp_servers.legend = %{"url" => "${LEGEND_MCP_URL}", "headers" => %{"Authorization" => "Bearer ${LEGEND_SESSION_TOKEN}"}}`
  → serialize with ymlr → write atomically (tmp file in the same dir + rename). Before the first byte is written, copy the original to `config.yaml.legend-backup` (overwritten on each apply). Re-serialization drops comments/key order — the same thing Hermes' own `hermes mcp add` does to the file; the backup is the escape hatch. Missing file with existing home dir → create it containing only the `mcp_servers` block. Applying over an existing `legend` entry is idempotent (normalizes it to the canonical shape).
- The `${VAR}` placeholders are literal strings in the config; Hermes interpolates them from each spawned process's environment (verified live: `hermes mcp test legend` discovers all five tools with a session token). Standalone Hermes runs leave them unresolved — that server fails to connect with a logged warning, by design.
- **New deps:** `yaml_elixir` (read) + `ymlr` (write). Pure-hex, fine inside the Burrito sidecar.

## API

- `GET /api/harnesses` (existing endpoint, first router scope): each harness object gains a `setup` field carrying the whole struct — `{"status", "summary", "detail", "restart_hint"}`.
- `POST /api/harnesses/:id/setup` (new, first router scope, plain controller): calls `apply_setup/0`, re-checks, returns the fresh setup object. `404` unknown harness id (string-compared, never `String.to_atom`); `422` with the uniform `{"error": msg}` envelope when the harness has no setup callbacks or apply fails.
- **Consent model:** the POST only ever happens from an explicit button click. No auto-write at boot, session start, or anywhere else.
- **Posture:** the endpoint writes a file in `$HOME` on behalf of the UI — acceptable under the loopback single-user posture; inherits the recorded "auth before any remote exposure" caveat.

## Frontend (two surfaces, one data source)

The existing harnesses fetch carries `setup` along; both surfaces render the same fields.

- **New-session form:** when the selected harness's `setup.status === 'missing'` and the per-harness dismissal flag is unset, show an inline notice — *"{harness.name}: {setup.summary}"* — with **Apply** and **Dismiss** buttons (in-UI buttons only; `window.confirm` is a no-op in Tauri). Apply → POST → refresh harnesses → if `restart_hint`, show "restart existing {name} sessions to pick this up". Dismiss → persists `legend:harness-setup-dismissed:<harness_id>` in `localStorage` (plan-time amendment: the settings API deliberately has no generic key-value CRUD, and a nag-dismissal is per-UI preference, not server state — the settings card remains the durable affordance); the prompt never nags again for that harness in that browser/app.
- **`/settings` — "Harness integrations" section:** lists every harness whose `setup.status ≠ 'not_applicable'` with status badge; **Apply** button on `missing` (available regardless of dismissal — the permanent home for the affordance); on `error`, render `detail` as a copyable manual-fix snippet.

## Error handling

- Hermes home dir missing → `not_applicable`, no UI anywhere.
- Config unparseable → `error` + manual snippet; apply refuses (422), file untouched.
- Write failure (permissions, disk) → `422 {"error": msg}`; original file intact (atomic tmp+rename; backup taken first).
- Unknown/setup-less harness id on POST → 404 / 422.
- Dismissal flag corrupt/absent → treated as not dismissed (prompt shows; worst case is one extra prompt).

## Testing

- `McpSetup` unit tests against tmp dirs (pin `HERMES_HOME` per test — never the real one): no dir → not_applicable; dir without file → missing, apply creates file with the entry; config with other `mcp_servers` → apply preserves them and writes the backup; existing legend entry → ok, apply idempotent; malformed YAML → error, apply refuses, file byte-identical.
- Harness contract: a harness module without the callbacks reports `not_applicable` (registry-level helper test).
- ConnCase: `GET /api/harnesses` includes the setup object; `POST /api/harnesses/hermes/setup` flips status missing → ok (tmp `HERMES_HOME` via test config); 404 unknown id; 422 for a harness without setup.
- Frontend: `bun run check` + `bun run build`. Manual acceptance: move `config.yaml` aside → new-session form prompts on Hermes → Apply → `hermes mcp list` shows `legend` → settings card shows ✓; Dismiss path stays quiet; restore real config.

## Decisions log

| Decision | Rationale |
|---|---|
| Generic seam, not a Hermes endpoint | ACP/native harnesses will have analogous host-setup needs; UI and API stay untouched for the next one |
| Self-describing `Setup` struct | UI renders harness-provided copy — no harness strings in the frontend |
| Optional callbacks (like `nudge_line`) | Harnesses without setup needs stay two-callback simple |
| YAML round-trip (user choice) | Handles any file shape; comment/order loss matches Hermes' own tooling; `.legend-backup` + atomic write as escape hatch |
| Consent = the button click | Never write a `$HOME` file Legend doesn't own without an explicit action |
| Per-harness dismissal in `localStorage` | Prompt must not nag; it's UI preference (no generic settings CRUD exists, by design); settings card remains the permanent affordance |
| One setup unit per harness | YAGNI — no multi-step/parameterized setup framework |
