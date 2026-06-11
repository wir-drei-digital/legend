# Settings — Design

**Date:** 2026-06-12
**Status:** Approved (design discussed and accepted in session)
**Builds on:** shared library (`2026-06-11-shared-library-design.md`)

## Purpose

A persistent, UI-editable settings store. First setting: the shared library path for the local storage adapter — today it is only configurable via `LIBRARY_PATH` in `backend/.env`, which is invisible in the UI and meaningless in the packaged desktop app. The pattern must extend to future settings (harness commands, ports, …) without redesign.

## Goals

1. `Legend.Core.Settings` — key-value settings persisted in SQLite (Ash resource), readable cheaply from core code.
2. Library path resolution precedence: **`LIBRARY_PATH` env (ops override) > saved setting > OS default**.
3. `/settings` UI page: shows the *effective* library path and its **source** (`env` / `setting` / `default`); **when the default is active, the resolved default path is displayed** (user requirement — not just the word "default"); editing validates + applies immediately; env-override state renders the field read-only with an explanation.
4. Saving a new path seeds it (same `ensure_seeded!` semantics) before persisting — an unusable path is rejected with the reason and nothing changes.

## Non-goals

- Settings sync/export, per-user settings (single local user).
- Moving/copying existing library content to the new path (the old tree stays where it is; the new root is seeded fresh — stated in the UI).
- Harness command settings (next candidates, not built now).
- Auth on the settings API (inherits the loopback single-user posture).

## Backend design

### `Legend.Core.Settings` (Ash domain + resource)

- Resource `Legend.Core.Settings.Setting` (AshSqlite, table `settings`): `key` (string, primary key), `value` (string), timestamps. No JSON:API exposure — settings semantics are bespoke (validation + side effects), served by a plain controller.
- Domain registered in `ash_domains`. Code interface: `get_setting(key)` → value | nil, `put_setting(key, value)` (upsert), `delete_setting(key)`.

### Library root resolution

`Legend.Core.Library.root/0` becomes:

```
env override (Application.get_env(:legend, :library_path), set only from LIBRARY_PATH in runtime.exs)
|| DB setting "library_path"
|| default_root()  (OS user-data dir + /library, exposed as a public function)
```

Plus `root_info/0` → `%{effective, source: :env | :setting | :default, default: default_root()}` for the API. DB read-through on each call is accepted (SQLite point read; PoC scale).

**Boot-order change required:** seeding currently runs as the first line of `Application.start/2`, before the Repo — it can't read the DB setting there. It moves to a `Legend.Core.Library.Seeder` child placed **after** `Ecto.Migrator`, whose `start_link/1` runs `ensure_seeded!()` **synchronously in the caller** and returns `:ignore` — a raise still propagates and aborts boot loudly (the fail-loud invariant is preserved and must be re-verified), while running late enough to read the settings table. If the settings table is unreadable for any reason other than "no row", seeding fails loudly rather than guessing.

### HTTP API (first router scope)

- `GET /api/settings/library-path` → `{data: {effective, source, default, value}}` (`value` = the saved setting or null; `default` always included so the UI can show it).
- `PUT /api/settings/library-path` (`{path}`) → expand the input; attempt `ensure_seeded!` against it; on success persist the setting and return the new `root_info`; on failure 400 `{error}` with the reason, nothing persisted. Rejected with 409 `{error}` when the env override is active (the UI shouldn't offer editing, but the API must still refuse).
- `DELETE /api/settings/library-path` → removes the setting (reverts to default), reseeds the default root, returns the new `root_info`. Also 409 under env override.

### Effects of changing the path

- Library API/UI read the new root immediately (read-through `root/0`).
- New sessions get the new `LEGEND_LIBRARY`; running sessions keep their launch-time env (stated in the UI).
- Old content is not migrated (non-goal; stated in the UI next to Save).

## Frontend design

- Sidebar nav gains **Settings** (third entry).
- `/settings` page, "Library" section:
  - Effective path display with a source badge: `env` ("set by LIBRARY_PATH — read-only here"), `setting`, or `default`.
  - **When source is `default`, the resolved default path is shown as the effective value** (e.g. `~/Library/Application Support/legend/library`), not a placeholder word.
  - Edit field prefilled with the saved setting (empty when on default) + the default path as placeholder; Save (PUT, no confirmation — validated and reversible) and "Reset to default" (DELETE, only when a setting exists, two-step in-UI confirmation — no native dialogs, they're no-ops in Tauri).
  - Note text: running sessions keep the old path; existing files are not moved.
- `src/lib/settings.ts` client for the three endpoints.

## Error handling

- Unusable path on save → 400 with the seeding error message, setting unchanged.
- Env override active → field read-only; PUT/DELETE return 409.
- Settings DB row missing → default (not an error).

## Testing

- Resource: get/put (upsert)/delete round-trip.
- `root/0` precedence matrix: env set → env wins; setting only → setting; neither → default. `root_info/0` source/default fields.
- Seeder: boot still aborts on a bad effective path (start_link raises); seeds the *setting* path when one exists.
- Controller: GET shape (incl. `default` always present); PUT happy path (persists + seeds), unusable path 400, env-override 409; DELETE reverts + reseeds.
- Existing library/session tests must stay green (root resolution change is the riskiest edit).
- Frontend: svelte-check + build; manual smoke (change path, create file, see it under the new root; reset to default).

## Decisions log

| Decision | Rationale |
|---|---|
| Env var beats DB setting | Ops/dev override must always win and be visible as read-only in the UI |
| Plain controller, no JSON:API for settings | Save has validation + side effects (seeding); generic CRUD semantics don't fit |
| Seeding moves after the Migrator, sync in start_link returning :ignore | Must read the settings table; preserves the abort-on-failure invariant |
| No content migration on path change | Cheap, predictable; stated in the UI; revisit if users ask |
| `default` always in the API payload | UI must show the resolved default path when active (user requirement) |
