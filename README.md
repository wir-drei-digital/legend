# legend

Web + desktop application.

- **Backend:** Elixir / Phoenix / Ash, SQLite — `backend/`
- **Frontend:** SvelteKit (TypeScript) + Bun, Tailwind v4 + shadcn-svelte, static SPA — `frontend/`
- **Desktop:** Tauri v2, backend bundled as a Burrito sidecar binary — `desktop/`

## Prerequisites

- [asdf](https://asdf-vm.com) with elixir + erlang plugins (versions pinned in `.tool-versions`)
- [Bun](https://bun.sh) ≥ 1.3
- [Rust](https://rustup.rs) (for Tauri)
- [just](https://github.com/casey/just)

zig is NOT a prerequisite: `backend/scripts/build-release.sh` auto-provisions the pinned zig 0.15.2 (one-time download into `~/.local/zig`) when packaging the desktop sidecar.

## Setup

```bash
asdf install        # toolchain from .tool-versions
just setup          # backend deps + db, frontend deps, desktop deps
```

Create your local env files from the committed examples (both are gitignored):

```bash
cp backend/.env.example backend/.env
cp frontend/.env.example frontend/.env
```

- `backend/.env` — loaded by [dotenvy](https://hexdocs.pm/dotenvy) in `config/runtime.exs`; real environment variables override `.env` values. See the comments in `backend/.env.example` for each variable.
- `frontend/.env` — native Vite/SvelteKit env handling; client-visible variables use the `PUBLIC_` prefix. Blank values mean "same origin", which is correct for dev and web deploys.

Agent harness commands are configurable in `backend/.env` (`HARNESS_CLAUDE_CMD`,
`HARNESS_HERMES_CMD`) — set these if `claude`/`hermes` aren't on your PATH or
need flags. Sessions spawn these CLIs under a PTY on the machine the backend
runs on.

All sessions share a library (knowledge, skills, artifacts) at
`~/Library/Application Support/legend/library` by default (`LIBRARY_PATH` in
`backend/.env` overrides). Agents are pointed at it via `$LEGEND_LIBRARY` and
a primer; browse and edit it in the app under Library, and change its location under Settings.

## Development

```bash
just dev            # Phoenix :4100 + Vite :4173 → open http://localhost:4173
just dev-desktop    # Phoenix + Tauri window (Tauri runs the Vite dev server)
just test           # mix test + svelte-check
```

## Builds

| Command | Output |
|---|---|
| `just build` | Web release (SPA baked into Phoenix) at `backend/_build/prod/rel/legend` |
| `just package-backend` | Sidecar binary at `desktop/src-tauri/binaries/` |
| `just desktop-bundle` | Desktop app bundle via `tauri build` |

The desktop app spawns the sidecar on port 4807, stores its SQLite database and a generated `SECRET_KEY_BASE` in the OS app-data directory, and shows the window once the backend is reachable.

Note: `cargo check` in `desktop/src-tauri` requires the sidecar binary to exist (tauri-build validates `externalBin`) — run `just package-backend` once after a fresh clone.

## UI components

The frontend uses [shadcn-svelte](https://www.shadcn-svelte.com) (style preset: nova). Add components with:

```bash
cd frontend && bunx shadcn-svelte@latest add <component>
```
