# legend — Project Scaffold Design

**Date:** 2026-06-10
**Status:** Approved design, pending implementation plan

## Goal

Scaffold a web application named **legend** that runs both in the browser and as a
desktop app. One backend, one frontend, two delivery targets.

- **Backend:** Elixir 1.20.1 / OTP 27, Phoenix 1.8, Ash 3, SQLite
- **Frontend:** SvelteKit (TypeScript) built and managed with Bun
- **Desktop:** Tauri v2 wrapping the frontend, with the backend bundled as a sidecar binary

Out of scope for the scaffold: actual chat domain modeling (only the channel
skeleton), CI, and desktop release signing/notarization.

## Repository Layout

```
legend/
├── backend/        # Phoenix + Ash app (mix project "legend")
├── frontend/       # SvelteKit + Bun, adapter-static, SPA mode
├── desktop/        # Tauri v2 app (contains src-tauri/)
├── docs/
├── .tool-versions  # elixir 1.20.1, erlang 27.x
├── Justfile        # dev/build orchestration
└── README.md
```

## Backend (`backend/`)

Generated with `mix igniter.new legend --with phx.new` plus installers for
`ash`, `ash_phoenix`, `ash_json_api`, `ash_sqlite`. No LiveView UI, no
Phoenix-managed assets — the frontend is SvelteKit.

- **Data layer:** AshSqlite on `ecto_sqlite3`. The database file path comes from
  the `DATABASE_PATH` env var so the desktop sidecar can point it at the OS
  app-data directory.
- **API:** AshJsonApi mounted at `/api`, with an OpenAPI spec endpoint. A
  minimal health endpoint (`GET /api/health`) for sidecar readiness checks.
- **Realtime:** `LegendWeb.UserSocket` at `/socket` with a sample `chat:*`
  channel as the skeleton for multiplayer chat streaming.
- **Static serving:** in web production mode, Phoenix serves the built SPA from
  `priv/static` with a catch-all route that falls back to `index.html`.

### Environment variables (.env)

- Uses the `dotenvy` hex package, sourced in `config/runtime.exs`.
- `backend/.env` (gitignored) holds local values; `backend/.env.example`
  (committed) documents every variable.
- Variables: `DATABASE_PATH`, `SECRET_KEY_BASE`, `PORT`, `PHX_HOST`.
- Precedence: real environment variables override `.env` file values.
- The packaged sidecar runs without a `.env` file: runtime config falls back to
  sane desktop defaults (app-data DB path, random free port passed by Tauri).

## Frontend (`frontend/`)

SvelteKit created and run with Bun, TypeScript, `adapter-static` with
`ssr = false` (SPA). The same static build is served by Phoenix on the web and
loaded by Tauri on desktop.

- **Dev server:** Vite proxies `/api` (http) and `/socket` (ws) to Phoenix on
  `localhost:4000`, so browser and desktop dev share one workflow.
- **Channels client:** the `phoenix` npm package with a small connection module
  (`src/lib/socket.ts`) wired to `/socket`.
- **Environment variables (.env):** native Vite/SvelteKit support.
  `frontend/.env` (gitignored) + `frontend/.env.example` (committed).
  Client-exposed vars use the `PUBLIC_` prefix via `$env/static/public`:
  `PUBLIC_API_URL`, `PUBLIC_WS_URL`. Empty/relative defaults mean "same origin"
  (web); the desktop build points them at the sidecar's local port.

## Desktop (`desktop/`)

Tauri v2 app.

- `devUrl` → Vite dev server (`http://localhost:5173`);
  `frontendDist` → `../frontend/build`.
- **Sidecar:** the Phoenix app is packaged into a self-contained binary with
  **Burrito** (requires `zig`), placed at
  `desktop/src-tauri/binaries/legend-server-<target-triple>` and registered as
  a Tauri sidecar. On launch, Rust spawns the sidecar with `DATABASE_PATH` and
  `PORT` env vars, polls `GET /api/health` until ready, then shows the window.
- Scaffold includes the packaging config and build scripts; producing the
  sidecar binary is an explicit step (`just package-backend`).

## Dev & Build Workflow (Justfile)

| Command | Action |
|---|---|
| `just dev` | Phoenix server + Vite dev server (web dev) |
| `just dev-desktop` | the above + `tauri dev` |
| `just build` | frontend build → copy into `backend/priv/static` → `mix release` |
| `just package-backend` | Burrito-package the backend sidecar binary |
| `just desktop-bundle` | full desktop build (`tauri build` with sidecar) |

## Testing & Verification

- `mix test` passes in `backend/`.
- `bun run check` (svelte-check) passes in `frontend/`.
- `cargo check` passes in `desktop/src-tauri/`.
- Smoke test: `GET /api/health` returns 200; a channel join on `chat:lobby`
  succeeds from the frontend dev server.

## Risks / Notes

- **Burrito requires zig** for packaging; the scaffold ships config + scripts,
  and the README documents the zig prerequisite.
- Elixir 1.20.1 will be installed via asdf (1.19.4 currently active); the repo
  pins it in `.tool-versions`.
- SQLite means single-node writes; fine for desktop-local and small web
  deployments, revisit if the web target needs horizontal scaling.
