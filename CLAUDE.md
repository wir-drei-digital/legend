# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

One app, two delivery targets: a web app and a Tauri desktop app sharing the same backend and frontend. The SvelteKit SPA is served three ways:

1. **Dev:** Vite dev server (:5173) proxies `/api` and `/socket` (ws) to Phoenix (:4000).
2. **Web prod:** the SPA build is copied into `backend/priv/static` and served by Phoenix from the `legend` release.
3. **Desktop:** Tauri loads the static build; the backend ships *inside the app* as a Burrito-packaged sidecar binary listening on `127.0.0.1:4807`.

## Commands

```bash
just setup            # all deps (mix setup + bun install x2)
just dev              # Phoenix :4000 + Vite :5173 (open :5173)
just dev-desktop      # Phoenix + Tauri window (Tauri runs Vite itself)
just test             # mix test + svelte-check
just build            # SPA → priv/static → prod web release
just package-backend  # Burrito sidecar binary → desktop/src-tauri/binaries/
just desktop-bundle   # full tauri build (depends on package-backend)
```

Per-app:

- Backend: `cd backend && mix test [test/path_test.exs:LINE]`; `mix precommit` (compile --warnings-as-errors + format + test) before finishing backend work.
- Frontend: `cd frontend && bun run check` (svelte-check), `bun run build`. Add UI components: `bunx shadcn-svelte@latest add <component>` (registry preset id `b37aFvsmY` → style "nova", zinc, hugeicons — the id is not stored in components.json).
- Desktop: `cd desktop/src-tauri && cargo check`. This FAILS on a fresh clone until a sidecar binary exists (tauri-build validates `externalBin`) — run `just package-backend` once first.

Release builds must go through `backend/scripts/build-release.sh [legend|legend_desktop]` — a Claude Code hook blocks raw `MIX_ENV=prod mix` command strings, and the script also auto-provisions the zig 0.15.2 that Burrito 1.5 requires (installed zig 0.16 is too new).

## Architecture

### Backend (`backend/`, Elixir 1.20 / Phoenix 1.8 / Ash 3 / SQLite)

- **No HTML/LiveView layer** — API + channels only. `backend/AGENTS.md` has generated Elixir guidelines; its LiveView/Layouts/core_components sections don't apply here.
- **Router order is load-bearing** (`lib/legend_web/router.ex`): `/api/health` first, then `forward "/", LegendWeb.AshJsonApiRouter` (swallows everything else under `/api`), then the `/*path` SPA catch-all last. New JSON endpoints go in the first scope or as Ash resources, never after the forward.
- **Ash:** `config :legend, ash_domains: []` is the registry; `LegendWeb.AshJsonApiRouter` exposes domains at `/api` with OpenAPI at `/api/open_api`. There are no domains yet — new features start by creating an Ash domain + resource (AshSqlite data layer) and adding it to `ash_domains`.
- **Channels:** `UserSocket` at `/socket` (unauthenticated), `chat:*` → `ChatChannel` (ping/shout skeleton for future multiplayer chat).
- **Config flow:** `config/runtime.exs` uses dotenvy — `backend/.env` (gitignored, create from `.env.example`) is read in dev; real env vars always win. Prod (`config_env() == :prod`) requires `DATABASE_PATH` + `SECRET_KEY_BASE`, defaults to port 4807, binds loopback (sidecar-first design; change ip for public web deploys), and sets `check_origin` for the `tauri://localhost` origins. Test env deliberately ignores `DATABASE_PATH`.
- **CORS:** Corsica in `endpoint.ex` allows only the Tauri webview origins (desktop → localhost:4807 is cross-origin).
- **Migrations in releases:** the supervised `Ecto.Migrator` child runs them only when `RELEASE_NAME` is set, gated by `AUTO_MIGRATE` (default true). Don't add a second migration path — a duplicate `Release.migrate()` boot call was already removed once. `Legend.Release.migrate/0` exists for manual `bin/legend eval`.
- **Two releases** in `mix.exs`: `legend` (plain, web) and `legend_desktop` (Burrito-wrapped single binary, output `burrito_out/legend_desktop_macos_arm`).

### Frontend (`frontend/`, SvelteKit 2 / Svelte 5 runes / Bun / Tailwind v4 + shadcn-svelte)

- Static SPA only: `adapter-static` with `fallback: 'index.html'`, `ssr = false` in `src/routes/+layout.ts`. Never reintroduce SSR — Tauri and the Phoenix catch-all both depend on the static build.
- `src/lib/api.ts` (`PUBLIC_API_URL || ''` base) and `src/lib/socket.ts` (singleton Phoenix socket, `PUBLIC_WS_URL || '/socket'`). Blank `PUBLIC_*` vars = same-origin (correct for dev + web); the desktop build bakes `http://localhost:4807` in via `beforeBuildCommand` in `tauri.conf.json`.
- `+layout.svelte` renders a `data-tauri-drag-region` header strip only inside Tauri (`__TAURI_INTERNALS__` check) — the window uses macOS `titleBarStyle: Overlay` with inline traffic lights.
- Global CSS + shadcn theme tokens live in `src/routes/layout.css` (not app.css).

### Desktop (`desktop/`, Tauri v2)

- `src-tauri/src/main.rs` owns the sidecar lifecycle: release builds spawn `binaries/legend-server-<triple>` with `PHX_SERVER/PORT=4807/DATABASE_PATH/SECRET_KEY_BASE` (secret generated once, persisted in the OS app-data dir next to `legend.db`), poll the port, then show the (initially hidden) window, and kill the child on exit. Dev builds skip the sidecar entirely — `just dev-desktop` provides Phoenix.
- Sidecar permissions live in `src-tauri/capabilities/default.json`; the binary name `legend-server` must stay in sync across `externalBin`, `.sidecar("legend-server")`, capabilities, and the `package-backend` copy step.
- Port 4807 is fixed by design (static frontend can't learn a runtime port without Tauri IPC).

## Gotchas

- `static_paths/0` in `lib/legend_web.ex` whitelists what Plug.Static serves — new top-level files in the SPA build output must be added there (`index.html` is intentionally absent; the SPA controller owns it).
- `backend/priv/static/{_app,index.html,robots.txt}` are build artifacts (gitignored); `just build` copies them in.
- `.env` files are gitignored in both apps; `.env.example` files are the documented templates.
- Design/plan docs for the scaffold live in `docs/superpowers/specs/` and `docs/superpowers/plans/`.
