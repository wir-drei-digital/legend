# legend Scaffold Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scaffold the legend monorepo — Phoenix/Ash/SQLite backend, SvelteKit/Bun SPA frontend, Tauri v2 desktop shell with the backend bundled as a Burrito sidecar binary.

**Architecture:** Three apps in one repo. `backend/` exposes a JSON:API (`/api`, AshJsonApi), a health endpoint, and Phoenix Channels (`/socket`); config comes from `.env` via dotenvy. `frontend/` is a static SPA (adapter-static, `ssr = false`) that the web deploy serves from Phoenix `priv/static` and the desktop loads from Tauri; in dev, Vite proxies `/api` and `/socket` to Phoenix on :4000. `desktop/` is a Tauri v2 app that, in release builds, spawns the Burrito-packaged backend as a sidecar on port 4807 and shows its window once the port accepts connections.

**Tech Stack:** Elixir 1.20.1-otp-27 / Erlang 27.3.4.6 (asdf), Phoenix 1.8, Ash 3, AshJsonApi, AshSqlite (ecto_sqlite3), dotenvy, Burrito (+ zig), SvelteKit 2 + TypeScript + Bun, phoenix.js, Tauri 2 (+ tauri-plugin-shell), just.

**Spec:** `docs/superpowers/specs/2026-06-10-legend-scaffold-design.md`

**Environment facts (verified 2026-06-10):**
- Repo root: `/Users/daniel/Development/legend` (empty except `.git`, `.claude`, `docs/`)
- asdf manages elixir (1.19.4 active) and erlang (27.3.4.6)
- `1.20.1-otp-27` is available in `asdf list all elixir`
- bun 1.3.3, cargo 1.92.0, host triple `aarch64-apple-darwin`
- `zig` and `just` are NOT installed (Task 1 installs them)
- mix archives present on 1.19.4: phx_new 1.8.3, igniter_new 0.5.33 (must be reinstalled for 1.20.1 — archives are per-Elixir-version)

**Conventions for all tasks:** All paths are relative to the repo root. Commit after every task. If a generator's output differs slightly from what a step shows, make the end state match the step.

---

### Task 1: Toolchain — Elixir 1.20.1, just, zig

**Files:**
- Create: `.tool-versions`
- Create: `.gitignore`

- [ ] **Step 1: Install Elixir 1.20.1-otp-27**

```bash
asdf install elixir 1.20.1-otp-27
```

Expected: download + install completes (may take a minute). Erlang 27.3.4.6 is already installed.

- [ ] **Step 2: Pin versions at repo root**

Create `.tool-versions`:

```
elixir 1.20.1-otp-27
erlang 27.3.4.6
```

- [ ] **Step 3: Verify the pinned toolchain is active**

```bash
elixir --version
```

Expected output contains: `Elixir 1.20.1` and `Erlang/OTP 27`.

- [ ] **Step 4: Reinstall mix archives for the new Elixir version**

Archives live per Elixir version; 1.20.1 starts with none.

```bash
mix local.hex --force && mix archive.install hex igniter_new --force && mix archive.install hex phx_new 1.8.3 --force
```

Expected: three success messages ending with `* creating ...phx_new-1.8.3.ez`.

- [ ] **Step 5: Install just and zig via Homebrew**

```bash
brew install just zig
```

Expected: both formulae install. Verify: `just --version` and `zig version` both print a version.

- [ ] **Step 6: Create root .gitignore**

Create `.gitignore`:

```
.DS_Store
```

- [ ] **Step 7: Commit**

```bash
git add .tool-versions .gitignore
git commit -m "chore: pin Elixir 1.20.1-otp-27 / Erlang 27.3.4.6"
```

---

### Task 2: Generate the Phoenix + Ash backend

**Files:**
- Create: `backend/` (entire generated app, mix project name `legend`)

- [ ] **Step 1: Generate the app with igniter (Phoenix + SQLite + Ash suite)**

From the repo root:

```bash
mix igniter.new legend \
  --with phx.new \
  --with-args "--database sqlite3 --no-html --no-assets --no-mailer --no-dashboard --no-gettext" \
  --install ash,ash_phoenix,ash_sqlite,ash_json_api \
  --yes
```

Expected: creates `./legend`, fetches deps, runs the Ash installers (converts `Legend.Repo` to `use AshSqlite.Repo`, adds `config :legend, ash_domains: []`, creates `LegendWeb.AshJsonApiRouter`). Takes a few minutes.

Note: `--no-html` means no LiveView/layouts — the frontend is SvelteKit. JSON controllers still work.

- [ ] **Step 2: Rename the directory to backend/**

```bash
mv legend backend
```

- [ ] **Step 3: Verify generated state**

Check these (fix to match if the installer produced something different):

- `backend/lib/legend/repo.ex` contains `use AshSqlite.Repo, otp_app: :legend`
- `backend/config/config.exs` contains `config :legend, ash_domains: []` (an empty list is correct — no domains yet)
- `backend/lib/legend_web/ash_json_api_router.ex` exists, shaped like:

```elixir
defmodule LegendWeb.AshJsonApiRouter do
  use AshJsonApi.Router,
    domains: Application.compile_env(:legend, :ash_domains, []),
    open_api: "/open_api"
end
```

If the installer wrote `domains:` as a literal list or didn't add `open_api:`, edit the file to match the shape above.

- `backend/lib/legend_web/router.ex` — the installer typically adds a forward to the JSON:API router. Whatever it generated, make the router's API section exactly:

```elixir
  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", LegendWeb do
    pipe_through :api
  end

  scope "/api" do
    pipe_through :api
    forward "/", LegendWeb.AshJsonApiRouter
  end
```

(The empty `LegendWeb`-scoped block gets the health route in Task 4. The `forward "/"` must come AFTER it in file order — Phoenix matches routes top-down and the forward swallows everything under `/api`.)

- [ ] **Step 4: Run the test suite**

```bash
cd backend && mix test
```

Expected: all tests pass (the generated suite is small), no compile warnings about missing modules.

- [ ] **Step 5: Commit**

```bash
git add backend
git commit -m "feat: generate Phoenix 1.8 + Ash 3 backend with SQLite"
```

---

### Task 3: Backend .env support (dotenvy)

**Files:**
- Modify: `backend/mix.exs` (deps)
- Modify: `backend/config/runtime.exs` (full rewrite)
- Create: `backend/.env.example`
- Create: `backend/.env`
- Modify: `backend/.gitignore`

- [ ] **Step 1: Add the dotenvy dependency**

In `backend/mix.exs`, add to `deps/0`:

```elixir
{:dotenvy, "~> 1.0"},
```

Run:

```bash
cd backend && mix deps.get
```

- [ ] **Step 2: Rewrite config/runtime.exs**

Replace the entire contents of `backend/config/runtime.exs` with:

```elixir
import Config
import Dotenvy

# In a release (incl. the Burrito sidecar) RELEASE_ROOT is set; in dev/test we
# read backend/.env. Real environment variables always win over .env values.
env_dir = System.get_env("RELEASE_ROOT") || Path.expand(".")

source!([
  Path.join(env_dir, ".env"),
  System.get_env()
])

if System.get_env("PHX_SERVER") do
  config :legend, LegendWeb.Endpoint, server: true
end

if config_env() == :dev do
  config :legend, LegendWeb.Endpoint, http: [port: env!("PORT", :integer, 4000)]
end

# Allow .env to point the database somewhere else in any env except test
# (test must keep its sandbox database).
if config_env() != :test do
  case env!("DATABASE_PATH", :string, nil) do
    path when path in [nil, ""] -> :ok
    path -> config :legend, Legend.Repo, database: path
  end
end

if config_env() == :prod do
  host = env!("PHX_HOST", :string, "localhost")
  port = env!("PORT", :integer, 4807)

  config :legend, Legend.Repo,
    database: env!("DATABASE_PATH", :string),
    pool_size: 5

  config :legend, LegendWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    # Bound to loopback: right for the desktop sidecar. For a public web
    # deploy, change ip to {0, 0, 0, 0} and front it with TLS.
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: [
      "//localhost",
      "tauri://localhost",
      "http://tauri.localhost",
      "https://tauri.localhost"
    ],
    secret_key_base: env!("SECRET_KEY_BASE", :string)

  # The sidecar runs migrations on boot (no mix available in a release).
  config :legend, auto_migrate: env!("AUTO_MIGRATE", :boolean, true)
end
```

Delete any duplicated prod endpoint/repo config that phx.new generated in `runtime.exs` — the block above replaces all of it. Leave `config/prod.exs`, `config/dev.exs`, `config/test.exs` untouched.

- [ ] **Step 3: Create .env.example and .env**

Create `backend/.env.example`:

```
# HTTP port Phoenix listens on (dev default 4000, prod/sidecar default 4807)
PORT=4000

# Host used for generated URLs
PHX_HOST=localhost

# Absolute path to the SQLite database file.
# Leave blank to use the per-env default from config/.
DATABASE_PATH=

# Required in prod. Generate with: mix phx.gen.secret
SECRET_KEY_BASE=

# Prod only: run pending migrations on boot (the desktop sidecar relies on this)
AUTO_MIGRATE=true
```

Then:

```bash
cd backend && cp .env.example .env
```

- [ ] **Step 4: Gitignore .env**

Append to `backend/.gitignore`:

```
# Local environment variables
.env
```

- [ ] **Step 5: Verify tests still pass**

```bash
cd backend && mix test
```

Expected: PASS.

- [ ] **Step 6: Verify .env actually drives the port**

```bash
cd backend && PORT=4123 mix phx.server &
sleep 8
curl -s -o /dev/null -w '%{http_code}' http://localhost:4123/
kill %1
```

Expected: curl prints a 3-digit status (404 is fine — no routes at `/` yet). The point is that the server answered on 4123.

- [ ] **Step 7: Commit**

```bash
git add backend/mix.exs backend/mix.lock backend/config/runtime.exs backend/.env.example backend/.gitignore
git commit -m "feat: load backend config from .env via dotenvy"
```

---

### Task 4: Health endpoint (TDD)

**Files:**
- Test: `backend/test/legend_web/controllers/health_controller_test.exs`
- Create: `backend/lib/legend_web/controllers/health_controller.ex`
- Modify: `backend/lib/legend_web/router.ex`

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend_web/controllers/health_controller_test.exs`:

```elixir
defmodule LegendWeb.HealthControllerTest do
  use LegendWeb.ConnCase, async: true

  test "GET /api/health returns ok", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd backend && mix test test/legend_web/controllers/health_controller_test.exs
```

Expected: FAIL (no route / no verified route `/api/health`). A compile error about the unknown `~p"/api/health"` route counts as the expected failure.

- [ ] **Step 3: Implement controller and route**

Create `backend/lib/legend_web/controllers/health_controller.ex`:

```elixir
defmodule LegendWeb.HealthController do
  use LegendWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
```

In `backend/lib/legend_web/router.ex`, add the route inside the existing `scope "/api", LegendWeb` block (BEFORE the scope containing the AshJsonApiRouter forward):

```elixir
  scope "/api", LegendWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd backend && mix test test/legend_web/controllers/health_controller_test.exs
```

Expected: 1 test, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend_web/controllers/health_controller.ex backend/test/legend_web/controllers/health_controller_test.exs backend/lib/legend_web/router.ex
git commit -m "feat: add /api/health endpoint"
```

---

### Task 5: Channels skeleton + cross-origin config

**Files:**
- Create (generated): `backend/lib/legend_web/channels/user_socket.ex`
- Create (generated): `backend/lib/legend_web/channels/chat_channel.ex`
- Create (generated): `backend/test/legend_web/channels/chat_channel_test.exs`
- Create (generated): `backend/test/support/channel_case.ex`
- Modify: `backend/lib/legend_web/endpoint.ex`
- Modify: `backend/mix.exs` (corsica dep)

- [ ] **Step 1: Generate the socket**

```bash
cd backend && mix phx.gen.socket User
```

Expected: creates `lib/legend_web/channels/user_socket.ex` and a JS asset note (ignore the JS — frontend is separate).

- [ ] **Step 2: Mount the socket in the endpoint**

In `backend/lib/legend_web/endpoint.ex`, add directly below `use Phoenix.Endpoint, otp_app: :legend`:

```elixir
  socket "/socket", LegendWeb.UserSocket,
    websocket: true,
    longpoll: false
```

- [ ] **Step 3: Generate the chat channel**

```bash
cd backend && mix phx.gen.channel Chat
```

Expected: creates `chat_channel.ex`, `chat_channel_test.exs`, and `test/support/channel_case.ex`. If it prompts about creating a socket, answer `n` (we already have one).

- [ ] **Step 4: Register the channel on the socket**

In `backend/lib/legend_web/channels/user_socket.ex`, make sure the channel route is present (add if the generator only printed instructions):

```elixir
  channel "chat:*", LegendWeb.ChatChannel
```

- [ ] **Step 5: Run the channel tests**

```bash
cd backend && mix test test/legend_web/channels/chat_channel_test.exs
```

Expected: all generated tests pass (join `chat:lobby`, ping/shout broadcasts).

- [ ] **Step 6: Add CORS for the desktop origin**

The Tauri webview loads the frontend from `tauri://localhost` (macOS) / `http://tauri.localhost` (Windows) and calls the sidecar at `http://localhost:4807` — that's cross-origin, so the API needs CORS. In `backend/mix.exs` deps add:

```elixir
{:corsica, "~> 2.1"},
```

Run `mix deps.get`. In `backend/lib/legend_web/endpoint.ex`, immediately above `plug LegendWeb.Router`, add:

```elixir
  plug Corsica,
    origins: ["tauri://localhost", "http://tauri.localhost", "https://tauri.localhost"],
    allow_headers: :all,
    allow_methods: :all
```

(Websocket origins are handled separately by `check_origin` in `runtime.exs`, already set in Task 3.)

- [ ] **Step 7: Full backend test run**

```bash
cd backend && mix test
```

Expected: PASS, no warnings.

- [ ] **Step 8: Commit**

```bash
git add backend
git commit -m "feat: add UserSocket + chat channel skeleton and desktop CORS"
```

---

### Task 6: SvelteKit frontend

**Files:**
- Create: `frontend/` (generated by `sv create`)
- Modify: `frontend/svelte.config.js`
- Create: `frontend/src/routes/+layout.ts`
- Modify: `frontend/vite.config.ts`
- Create: `frontend/src/lib/api.ts`
- Create: `frontend/src/lib/socket.ts`
- Modify: `frontend/src/routes/+page.svelte`
- Create: `frontend/.env.example`, `frontend/.env`
- Modify: `frontend/.gitignore`

- [ ] **Step 1: Generate the SvelteKit app**

From the repo root:

```bash
bunx sv create frontend --template minimal --types ts --no-add-ons --install bun
```

Expected: creates `frontend/` with TypeScript SvelteKit and runs `bun install`. (If the CLI prompts anyway, choose: minimal template, TypeScript, no add-ons, bun.)

- [ ] **Step 2: Switch to adapter-static in SPA mode**

```bash
cd frontend && bun add -D @sveltejs/adapter-static && bun remove @sveltejs/adapter-auto
```

Replace the contents of `frontend/svelte.config.js` with:

```js
import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		// SPA mode: every unknown path falls back to index.html (Tauri + Phoenix
		// catch-all both rely on this).
		adapter: adapter({ fallback: 'index.html' })
	}
};

export default config;
```

Create `frontend/src/routes/+layout.ts`:

```ts
// Static SPA: no server-side rendering, no prerendering of dynamic routes.
export const ssr = false;
export const prerender = false;
```

- [ ] **Step 3: Proxy /api and /socket to Phoenix in dev**

Replace the contents of `frontend/vite.config.ts` with:

```ts
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [sveltekit()],
	server: {
		proxy: {
			'/api': 'http://localhost:4000',
			'/socket': { target: 'ws://localhost:4000', ws: true }
		}
	}
});
```

- [ ] **Step 4: Environment variables**

Create `frontend/.env.example`:

```
# Base URL of the backend API. Blank = same origin (web deploy / dev proxy).
# The desktop build bakes in http://localhost:4807 (see desktop/src-tauri/tauri.conf.json).
PUBLIC_API_URL=

# Websocket URL for Phoenix channels. Blank = /socket on the same origin.
PUBLIC_WS_URL=
```

```bash
cd frontend && cp .env.example .env
```

Check `frontend/.gitignore` — the SvelteKit template usually ignores `.env` already; if not, append:

```
.env
```

- [ ] **Step 5: Phoenix channels client + API helper**

```bash
cd frontend && bun add phoenix && bun add -D @types/phoenix
```

Create `frontend/src/lib/api.ts`:

```ts
import { PUBLIC_API_URL } from '$env/static/public';

export const apiBase = PUBLIC_API_URL || '';

export async function getHealth(): Promise<{ status: string }> {
	const res = await fetch(`${apiBase}/api/health`);
	if (!res.ok) throw new Error(`health check failed: ${res.status}`);
	return res.json();
}
```

Create `frontend/src/lib/socket.ts`:

```ts
import { Socket } from 'phoenix';
import { PUBLIC_WS_URL } from '$env/static/public';

let socket: Socket | undefined;

/** Lazily-connected singleton Phoenix socket. */
export function getSocket(): Socket {
	if (!socket) {
		socket = new Socket(PUBLIC_WS_URL || '/socket');
		socket.connect();
	}
	return socket;
}
```

- [ ] **Step 6: Smoke-test page**

Replace the contents of `frontend/src/routes/+page.svelte` with:

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import { getHealth } from '$lib/api';
	import { getSocket } from '$lib/socket';

	let health = $state('checking…');
	let channelStatus = $state('connecting…');

	onMount(() => {
		getHealth()
			.then((h) => (health = h.status))
			.catch((e) => (health = `error: ${e.message}`));

		const channel = getSocket().channel('chat:lobby');
		channel
			.join()
			.receive('ok', () => (channelStatus = 'joined chat:lobby'))
			.receive('error', () => (channelStatus = 'join failed'));

		return () => {
			channel.leave();
		};
	});
</script>

<h1>legend</h1>
<p>API health: {health}</p>
<p>Channel: {channelStatus}</p>
```

- [ ] **Step 7: Type-check and build**

```bash
cd frontend && bun run check && bun run build
```

Expected: `svelte-check` 0 errors; build outputs to `frontend/build/` containing `index.html` and `_app/`.

- [ ] **Step 8: End-to-end dev smoke test**

```bash
cd backend && mix phx.server &
cd frontend && bun run dev &
sleep 10
curl -s http://localhost:5173/api/health
kill %1 %2
```

Expected: curl prints `{"status":"ok"}` — i.e. the Vite proxy reaches Phoenix.

- [ ] **Step 9: Commit**

```bash
git add frontend
git commit -m "feat: scaffold SvelteKit SPA with channels client and dev proxy"
```

---

### Task 7: Phoenix serves the SPA (web production mode)

**Files:**
- Test: `backend/test/legend_web/controllers/spa_controller_test.exs`
- Create: `backend/lib/legend_web/controllers/spa_controller.ex`
- Modify: `backend/lib/legend_web/router.ex`
- Modify: `backend/lib/legend_web.ex` (static_paths)

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend_web/controllers/spa_controller_test.exs`:

```elixir
defmodule LegendWeb.SPAControllerTest do
  use LegendWeb.ConnCase, async: false

  setup do
    static_dir = Application.app_dir(:legend, "priv/static")
    index = Path.join(static_dir, "index.html")
    File.mkdir_p!(static_dir)
    File.write!(index, "<html><body>legend spa</body></html>")
    on_exit(fn -> File.rm(index) end)
    :ok
  end

  test "GET / serves the SPA index", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "legend spa"
  end

  test "unknown paths fall back to the SPA index", %{conn: conn} do
    conn = get(conn, "/some/client/route")
    assert html_response(conn, 200) =~ "legend spa"
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

```bash
cd backend && mix test test/legend_web/controllers/spa_controller_test.exs
```

Expected: FAIL (no route for `/`).

- [ ] **Step 3: Implement the SPA controller and catch-all route**

Create `backend/lib/legend_web/controllers/spa_controller.ex`:

```elixir
defmodule LegendWeb.SPAController do
  use LegendWeb, :controller

  def index(conn, _params) do
    index = Application.app_dir(:legend, "priv/static/index.html")

    if File.exists?(index) do
      conn
      |> put_resp_content_type("text/html")
      |> send_file(200, index)
    else
      send_resp(conn, 404, "Frontend not built. Run `just build` first.")
    end
  end
end
```

In `backend/lib/legend_web/router.ex`, add as the LAST scope in the module (after all `/api` scopes):

```elixir
  # SPA catch-all: anything that isn't /api or a static asset gets index.html.
  scope "/", LegendWeb do
    get "/*path", SPAController, :index
  end
```

In `backend/lib/legend_web.ex`, update `static_paths/0` so Plug.Static serves the SvelteKit build output:

```elixir
  def static_paths, do: ~w(_app assets fonts images favicon.ico favicon.png favicon.svg robots.txt)
```

(Keep whatever entries already exist; the important addition is `_app`.)

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd backend && mix test
```

Expected: full suite passes, including both SPA tests.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/legend_web/controllers/spa_controller.ex backend/test/legend_web/controllers/spa_controller_test.exs backend/lib/legend_web/router.ex backend/lib/legend_web.ex
git commit -m "feat: serve the built SPA from Phoenix with index.html fallback"
```

---

### Task 8: Tauri desktop shell

**Files:**
- Create: `desktop/package.json`
- Create: `desktop/src-tauri/` (via `tauri init`, then modified)
- Modify: `desktop/src-tauri/tauri.conf.json`
- Modify: `desktop/src-tauri/Cargo.toml`
- Modify: `desktop/src-tauri/src/main.rs`
- Modify: `desktop/src-tauri/capabilities/default.json`
- Modify: `desktop/src-tauri/.gitignore`

- [ ] **Step 1: Create the desktop package and install the Tauri CLI**

Create `desktop/package.json`:

```json
{
	"name": "legend-desktop",
	"private": true,
	"scripts": {
		"tauri": "tauri"
	},
	"devDependencies": {
		"@tauri-apps/cli": "^2"
	}
}
```

```bash
cd desktop && bun install
```

- [ ] **Step 2: Initialize Tauri**

```bash
cd desktop && bun tauri init --ci \
  --app-name legend \
  --window-title legend \
  --frontend-dist ../../frontend/build \
  --dev-url http://localhost:5173 \
  --before-dev-command "" \
  --before-build-command ""
```

Expected: creates `desktop/src-tauri/` with `Cargo.toml`, `tauri.conf.json`, `src/main.rs`, `capabilities/`, `icons/`.

- [ ] **Step 3: Configure tauri.conf.json**

Edit `desktop/src-tauri/tauri.conf.json` so the `build`, `bundle`, and window sections read (keep generated fields not mentioned here, e.g. `icon` list and `identifier` — but set `identifier` to `dev.danielmilenkovic.legend` if it still has the placeholder):

```json
{
	"build": {
		"frontendDist": "../../frontend/build",
		"devUrl": "http://localhost:5173",
		"beforeDevCommand": "cd ../frontend && bun run dev",
		"beforeBuildCommand": "cd ../frontend && PUBLIC_API_URL=http://localhost:4807 PUBLIC_WS_URL=ws://localhost:4807/socket bun run build"
	},
	"bundle": {
		"active": true,
		"targets": "all",
		"externalBin": ["binaries/legend-server"]
	},
	"app": {
		"windows": [
			{
				"title": "legend",
				"width": 1100,
				"height": 750,
				"visible": false
			}
		]
	}
}
```

`visible: false` because release builds show the window only after the sidecar is reachable; dev shows it immediately from Rust. `beforeDevCommand`/`beforeBuildCommand` run with CWD = `desktop/`, hence `cd ../frontend`.

- [ ] **Step 4: Rust dependencies**

In `desktop/src-tauri/Cargo.toml` ensure `[dependencies]` contains:

```toml
[dependencies]
tauri = { version = "2", features = [] }
tauri-plugin-shell = "2"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
rand = "0.9"
```

- [ ] **Step 5: Sidecar lifecycle in main.rs**

Replace the contents of `desktop/src-tauri/src/main.rs` with:

```rust
// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::TcpStream;
use std::sync::Mutex;
use std::time::Duration;
use tauri::Manager;
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;

const BACKEND_PORT: u16 = 4807;

/// Holds the sidecar process so it can be killed on exit.
struct Backend(Mutex<Option<CommandChild>>);

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(Backend(Mutex::new(None)))
        .setup(|app| {
            if cfg!(debug_assertions) {
                // Dev: the backend runs via `just dev-desktop` / `mix phx.server`,
                // and the frontend talks to it through the Vite proxy.
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                }
            } else {
                start_sidecar(app.handle())?;
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) {
                if let Some(child) = app.state::<Backend>().0.lock().unwrap().take() {
                    let _ = child.kill();
                }
            }
        });
}

fn start_sidecar(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let data_dir = app.path().app_data_dir()?;
    std::fs::create_dir_all(&data_dir)?;

    let secret = read_or_create_secret(&data_dir.join("secret_key_base"))?;
    let db_path = data_dir.join("legend.db");

    let (_rx, child) = app
        .shell()
        .sidecar("legend-server")?
        .env("PHX_SERVER", "true")
        .env("PORT", BACKEND_PORT.to_string())
        .env("PHX_HOST", "localhost")
        .env("DATABASE_PATH", db_path.to_string_lossy().to_string())
        .env("SECRET_KEY_BASE", secret)
        .spawn()?;

    app.state::<Backend>().0.lock().unwrap().replace(child);

    // Show the window once the backend accepts connections (max ~20s).
    let handle = app.clone();
    std::thread::spawn(move || {
        let addr = std::net::SocketAddr::from(([127, 0, 0, 1], BACKEND_PORT));
        for _ in 0..100 {
            if TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        if let Some(window) = handle.get_webview_window("main") {
            let _ = window.show();
        }
    });

    Ok(())
}

/// The desktop app owns its own SECRET_KEY_BASE: generated once per install,
/// persisted in the app data dir.
fn read_or_create_secret(path: &std::path::Path) -> std::io::Result<String> {
    use rand::distr::{Alphanumeric, SampleString};

    if path.exists() {
        std::fs::read_to_string(path)
    } else {
        let secret = Alphanumeric.sample_string(&mut rand::rng(), 64);
        std::fs::write(path, &secret)?;
        Ok(secret)
    }
}
```

If `tauri init` generated a `src/lib.rs` + thin `main.rs` pair instead, put the code above in `main.rs` and delete `lib.rs` plus any `[lib]` section in `Cargo.toml` — this app has no mobile target.

- [ ] **Step 6: Sidecar permission**

Replace the contents of `desktop/src-tauri/capabilities/default.json` with:

```json
{
	"$schema": "../gen/schemas/desktop-schema.json",
	"identifier": "default",
	"description": "Default capability for the main window",
	"windows": ["main"],
	"permissions": [
		"core:default",
		{
			"identifier": "shell:allow-execute",
			"allow": [{ "name": "binaries/legend-server", "sidecar": true }]
		},
		{
			"identifier": "shell:allow-spawn",
			"allow": [{ "name": "binaries/legend-server", "sidecar": true }]
		}
	]
}
```

- [ ] **Step 7: Gitignore the sidecar binaries**

Append to `desktop/src-tauri/.gitignore` (create if missing — `tauri init` usually writes one with `/target`):

```
# Burrito-packaged backend sidecar (built by `just package-backend`)
/binaries
```

- [ ] **Step 8: Verify the Rust code compiles**

```bash
cd desktop/src-tauri && cargo check
```

Expected: `Finished` with no errors (first run downloads crates; takes a few minutes). `cargo check` does not require the sidecar binary to exist — only `tauri build` does.

- [ ] **Step 9: Commit**

```bash
git add desktop
git commit -m "feat: add Tauri v2 desktop shell with backend sidecar lifecycle"
```

---

### Task 9: Burrito packaging + release migrations

**Files:**
- Modify: `backend/mix.exs` (burrito dep + releases)
- Create: `backend/lib/legend/release.ex`
- Modify: `backend/lib/legend/application.ex`
- Modify: `backend/.gitignore`

- [ ] **Step 1: Add Burrito and the release definitions**

In `backend/mix.exs` deps add:

```elixir
{:burrito, "~> 1.0", runtime: false},
```

In the `project/0` keyword list add `releases: releases(),` and define:

```elixir
  defp releases do
    [
      # Plain release for web deployment
      legend: [
        include_executables_for: [:unix]
      ],
      # Self-contained sidecar binary for the desktop app (requires zig)
      legend_desktop: [
        include_executables_for: [:unix],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm: [os: :darwin, cpu: :aarch64]
          ]
        ]
      ]
    ]
  end
```

Run `cd backend && mix deps.get`.

- [ ] **Step 2: Release migration module**

Create `backend/lib/legend/release.ex`:

```elixir
defmodule Legend.Release do
  @moduledoc """
  Release tasks. Inside a release (e.g. the desktop sidecar) there is no Mix,
  so migrations run through Ecto.Migrator directly.
  """
  @app :legend

  def migrate do
    Application.ensure_loaded(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end
end
```

- [ ] **Step 3: Auto-migrate on boot**

In `backend/lib/legend/application.ex`, at the top of `start/2` (before the `children` list):

```elixir
    if Application.get_env(:legend, :auto_migrate, false) do
      Legend.Release.migrate()
    end
```

(`auto_migrate` is only set in prod via `AUTO_MIGRATE`, default true — see runtime.exs from Task 3. Dev/test keep using `mix ecto.setup`.)

- [ ] **Step 4: Gitignore burrito output**

Append to `backend/.gitignore`:

```
# Burrito build output
burrito_out/
```

- [ ] **Step 5: Run tests**

```bash
cd backend && mix test
```

Expected: PASS (auto_migrate is false in test, so nothing changes there).

- [ ] **Step 6: Build the sidecar binary**

```bash
cd backend && MIX_ENV=prod mix release legend_desktop --overwrite
```

Expected: assembles the release, then Burrito wraps it with zig. SLOW on first run (downloads ERTS/zig artifacts). Output: `backend/burrito_out/legend_desktop_macos_arm`.

- [ ] **Step 7: Smoke-test the binary**

```bash
SECRET=$(cd backend && mix phx.gen.secret)
DATABASE_PATH=/tmp/legend-smoke.db SECRET_KEY_BASE=$SECRET PHX_SERVER=true PORT=4807 \
  ./backend/burrito_out/legend_desktop_macos_arm &
sleep 8
curl -s http://localhost:4807/api/health
kill %1
rm -f /tmp/legend-smoke.db
```

Expected: curl prints `{"status":"ok"}` — proving the packaged release boots, migrates the SQLite db at `DATABASE_PATH`, and serves the API.

- [ ] **Step 8: Commit**

```bash
git add backend/mix.exs backend/mix.lock backend/lib/legend/release.ex backend/lib/legend/application.ex backend/.gitignore
git commit -m "feat: Burrito sidecar release with boot-time migrations"
```

---

### Task 10: Justfile, README, final verification

**Files:**
- Create: `Justfile`
- Create: `README.md`

- [ ] **Step 1: Create the Justfile**

Create `Justfile` at the repo root:

```just
# legend — dev & build orchestration

default:
    @just --list

# Install all dependencies
setup:
    cd backend && mix setup
    cd frontend && bun install
    cd desktop && bun install

# Backend + frontend dev servers (web dev: http://localhost:5173)
dev:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'kill 0' EXIT
    (cd backend && mix phx.server) &
    (cd frontend && bun run dev) &
    wait

# Backend + Tauri dev shell (Tauri starts the frontend dev server itself)
dev-desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'kill 0' EXIT
    (cd backend && mix phx.server) &
    (cd desktop && bun tauri dev) &
    wait

# Build the SPA, bake it into Phoenix, assemble the web release
build:
    cd frontend && bun run build
    rm -rf backend/priv/static/_app
    cp -R frontend/build/. backend/priv/static/
    cd backend && MIX_ENV=prod mix release legend --overwrite

# Package the backend as the desktop sidecar binary (requires zig)
package-backend:
    #!/usr/bin/env bash
    set -euo pipefail
    cd backend && MIX_ENV=prod mix release legend_desktop --overwrite
    cd ..
    triple=$(rustc -vV | sed -n 's/host: //p')
    mkdir -p desktop/src-tauri/binaries
    cp backend/burrito_out/legend_desktop_macos_arm "desktop/src-tauri/binaries/legend-server-${triple}"

# Full desktop bundle
desktop-bundle: package-backend
    cd desktop && bun tauri build

# Run all checks
test:
    cd backend && mix test
    cd frontend && bun run check
```

- [ ] **Step 2: Verify the just recipes parse and the test recipe passes**

```bash
just --list && just test
```

Expected: recipe list prints; backend tests + svelte-check pass.

- [ ] **Step 3: Verify `just build` produces a web release that serves the SPA**

```bash
just build
SECRET=$(cd backend && mix phx.gen.secret)
DATABASE_PATH=/tmp/legend-web-smoke.db SECRET_KEY_BASE=$SECRET PHX_SERVER=true PORT=4321 \
  ./backend/_build/prod/rel/legend/bin/legend start &
sleep 8
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4321/
curl -s http://localhost:4321/api/health
./backend/_build/prod/rel/legend/bin/legend stop
rm -f /tmp/legend-web-smoke.db
```

Expected: first curl prints `200` (SPA index served), second prints `{"status":"ok"}`.

- [ ] **Step 4: Write the README**

Create `README.md`:

````markdown
# legend

Web + desktop application.

- **Backend:** Elixir / Phoenix / Ash, SQLite — `backend/`
- **Frontend:** SvelteKit (TypeScript) + Bun, static SPA — `frontend/`
- **Desktop:** Tauri v2, backend bundled as a sidecar binary — `desktop/`

## Prerequisites

- [asdf](https://asdf-vm.com) with elixir + erlang plugins (versions pinned in `.tool-versions`)
- [Bun](https://bun.sh) ≥ 1.3
- [Rust](https://rustup.rs) (for Tauri)
- [just](https://github.com/casey/just)
- [zig](https://ziglang.org) (only for `just package-backend` — Burrito packaging)

## Quickstart

```bash
asdf install        # toolchain from .tool-versions
just setup          # all dependencies
just dev            # Phoenix :4000 + Vite :5173 (open http://localhost:5173)
```

Desktop dev: `just dev-desktop` (Phoenix + Tauri window; frontend served by Vite).

## Environment variables

Both apps read a local `.env` file (gitignored); the committed `.env.example`
files document every variable.

- `backend/.env` — loaded by [dotenvy](https://hexdocs.pm/dotenvy) in
  `config/runtime.exs`. Real environment variables override `.env`.
- `frontend/.env` — native Vite/SvelteKit support; client-visible vars use the
  `PUBLIC_` prefix.

```bash
cp backend/.env.example backend/.env
cp frontend/.env.example frontend/.env
```

## Builds

| Command | Output |
|---|---|
| `just build` | Web release (SPA baked into Phoenix) at `backend/_build/prod/rel/legend` |
| `just package-backend` | Sidecar binary at `desktop/src-tauri/binaries/` |
| `just desktop-bundle` | Desktop app bundle via `tauri build` |

The desktop app spawns the sidecar on port 4807, stores its SQLite database and
a generated `SECRET_KEY_BASE` in the OS app-data directory, and shows the
window once the backend is reachable.

## Tests

```bash
just test           # mix test + svelte-check
```
````

- [ ] **Step 5: Commit**

```bash
git add Justfile README.md
git commit -m "docs: add Justfile workflow and README"
```

---

## Deviations from the spec (intentional)

1. **Sidecar port is fixed (4807), not random.** The frontend is a static build, so the API URL is baked in at build time (`beforeBuildCommand`). A random port would require runtime injection via Tauri IPC — noted as a follow-up, not scaffold scope.
2. **Readiness check is TCP-connect, not HTTP GET /api/health.** Phoenix accepts connections only once the endpoint is up, so port-open is an equivalent readiness signal and avoids adding an HTTP client crate to the Rust side. The health endpoint still exists and is used by all CLI smoke tests.

## Verification checklist (end state)

- `elixir --version` → 1.20.1 / OTP 27
- `cd backend && mix test` → all pass
- `cd frontend && bun run check && bun run build` → 0 errors, `build/` produced
- `cd desktop/src-tauri && cargo check` → clean
- `just test` → green
- Packaged sidecar binary answers `{"status":"ok"}` on `/api/health`
- Web release serves the SPA at `/` and the API at `/api/health`
