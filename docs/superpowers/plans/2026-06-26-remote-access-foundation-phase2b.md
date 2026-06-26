# Remote Access Foundation — Phase 2b (Frontend Remote UX) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a Legend instance usable from a paired remote browser — pair a device, drive sessions from a phone-sized viewport, and manage devices from the desktop — completing federation Slice 1.

**Architecture:** The backend auth + reachability are already done (Phases 1–2a). Phase 2b adds the frontend: a `localStorage` device token threaded into the API (`Authorization: Bearer`) and socket (`token` param) clients; a standalone shell-less `/pair` redeem route; a root-layout viewport branch that gives phones a lean `MobileShell` (session list → single-session view, reusing the existing `AcpConversation`/`Terminal` bodies) instead of the desktop tiling cockpit; and a desktop-only "Remote access" Settings section (toggle, paired-device list + revoke, pairing-code → QR, audit trail). The only backend change is one new read endpoint, `GET /api/devices/audit`.

**Tech Stack:** Elixir/Phoenix (backend controller + router), SvelteKit 2 / Svelte 5 runes / Bun / Tailwind v4 + shadcn-svelte (frontend), vitest (frontend logic unit tests), `qrcode` (new frontend dep for the pairing QR).

## Global Constraints

- Backend: run all `mix` commands from `backend/`. `mix precommit` (compile `--warnings-as-errors` + format + test) MUST pass before a backend task is done.
- DB-touching ExUnit test modules MUST be `async: false` (SQLite write-lock — established project lesson).
- New device-gated HTTP routes go in the **device-gated** router scope (`pipe_through [:api, :device_auth]`); the `forward "/", LegendWeb.AshJsonApiRouter` MUST stay last under `/api`; `/api/health`, `/api/mcp`, `/api/pair` stay in the public scope.
- Frontend: run all `bun` commands from `frontend/`. `bun run check` (svelte-check) MUST pass before a frontend task is done; `bun run test` (vitest) runs logic unit tests (`src/**/*.test.ts`, node env).
- Auth contract is fixed by Phase 1: socket credential is the `token` connect param; HTTP credential is the `Authorization: Bearer <token>` header. Loopback (desktop webview / local browser) sends neither and stays trusted — never send a token on loopback.
- Token discipline: feature code uses Legend tokens (`text-ink-*`, `bg-shell/app/panel/raised`, `text-micro|meta|ui|body|title`, `border-hair|hair-strong`) + shell primitives (`Icon`, `IconButton`, `StatusDot`, `ConfirmButton`). shadcn semantic classes appear ONLY under `src/lib/components/ui/`.
- NEVER use `window.confirm`/`alert`/`prompt` (no-ops in the Tauri webview). Use in-UI confirmation (`ConfirmButton` or two-step buttons).
- The `Icon` set is fixed (see `src/lib/components/shell/Icon.svelte`): there is **no `chevron-left`** — use `chevron-right` with `class="rotate-180"` for "back"; the gear glyph is `gear`.
- Commit messages end with: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: Backend — `GET /api/devices/audit` endpoint

**Files:**
- Modify: `backend/lib/legend_web/router.ex` (add one route in the device-gated scope)
- Modify: `backend/lib/legend_web/controllers/device_controller.ex` (add `audit/2` + `audit_view/1`)
- Test: `backend/test/legend_web/controllers/device_controller_test.exs` (append one test)

**Interfaces:**
- Consumes: `Legend.Core.Devices.list_audit!/0` (returns `[%AuditEvent{}]` sorted `inserted_at: :desc`); `Devices.audit!/1` (already used elsewhere).
- Produces: `GET /api/devices/audit` → `200 %{"data" => [%{"id","device_id","session_id","action","at"}]}` (device-gated; loopback-trusted in practice). The frontend `listAudit()` (Task 6) consumes this.

- [ ] **Step 1: Write the failing test**

Append to `backend/test/legend_web/controllers/device_controller_test.exs`, inside the module (before the final `end`):

```elixir
  test "audit trail returns recorded events with the view shape", %{conn: conn} do
    Devices.audit!(%{device_id: nil, session_id: nil, action: "pair"})

    list = json_response(get(conn, "/api/devices/audit"), 200)
    assert is_list(list["data"])

    event = Enum.find(list["data"], &(&1["action"] == "pair"))
    assert event
    assert Map.has_key?(event, "device_id")
    assert Map.has_key?(event, "session_id")
    assert Map.has_key?(event, "at")
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd backend && mix test test/legend_web/controllers/device_controller_test.exs`
Expected: FAIL — the route doesn't exist yet (Phoenix `no route found` / 404, so `json_response(..., 200)` raises).

- [ ] **Step 3: Add the route**

In `backend/lib/legend_web/router.ex`, in the device-gated scope, add the audit route directly after the existing devices routes:

```elixir
    get "/devices", DeviceController, :index
    post "/devices/pair-code", DeviceController, :create_pair_code
    delete "/devices/:id", DeviceController, :revoke
    get "/devices/audit", DeviceController, :audit
```

- [ ] **Step 4: Add the controller action**

In `backend/lib/legend_web/controllers/device_controller.ex`, add the `audit/2` action (after `revoke/2`) and the `audit_view/1` private helper (next to `device_view/1`):

```elixir
  def audit(conn, _params) do
    json(conn, %{data: Enum.map(Devices.list_audit!(), &audit_view/1)})
  end
```

```elixir
  defp audit_view(e) do
    %{
      id: e.id,
      device_id: e.device_id,
      session_id: e.session_id,
      action: e.action,
      at: e.inserted_at
    }
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd backend && mix test test/legend_web/controllers/device_controller_test.exs`
Expected: PASS (all tests in the file, including the new one).

- [ ] **Step 6: Full precommit**

Run: `cd backend && mix precommit`
Expected: compiles with no warnings, format clean, full suite green.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend_web/router.ex backend/lib/legend_web/controllers/device_controller.ex backend/test/legend_web/controllers/device_controller_test.exs
git commit -m "feat(devices): GET /api/devices/audit read endpoint

Surfaces the control-action audit trail (Devices.list_audit!/0) for the
Phase 2b Remote-access settings section. Device-gated; view shape
{id, device_id, session_id, action, at}.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Frontend — device-token store + auth-aware `apiFetch` + migrate REST callsites

**Files:**
- Create: `frontend/src/lib/remote/deviceToken.ts`
- Create: `frontend/src/lib/remote/deviceToken.test.ts`
- Modify: `frontend/src/lib/api.ts` (add `authHeaders`, `apiFetch`; keep `apiBase`, `getHealth`)
- Create: `frontend/src/lib/api.test.ts`
- Modify: `frontend/src/lib/sessions.ts`, `frontend/src/lib/settings.ts`, `frontend/src/lib/messages.ts`, `frontend/src/lib/library.ts` (route every `/api/*` REST call through `apiFetch`)

**Interfaces:**
- Produces: `getDeviceToken(): string | null`, `setDeviceToken(token: string): void`, `clearDeviceToken(): void` (from `deviceToken.ts`). `authHeaders(): Record<string,string>` and `apiFetch(path: string, init?: RequestInit): Promise<Response>` (from `api.ts`). Consumed by Task 3 (socket), Task 4 (`/pair`), Task 5 (mobile unpair), Task 6 (devices API).
- Note: `apiBase` stays exported from `api.ts` (it's `PUBLIC_API_URL || ''`); after migration only `api.ts` itself references it.

- [ ] **Step 1: Write the failing test for the token store**

Create `frontend/src/lib/remote/deviceToken.test.ts`:

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { getDeviceToken, setDeviceToken, clearDeviceToken } from './deviceToken';

function memoryStorage(): Storage {
	const m = new Map<string, string>();
	return {
		length: 0,
		clear: () => m.clear(),
		key: () => null,
		getItem: (k: string) => (m.has(k) ? (m.get(k) as string) : null),
		setItem: (k: string, v: string) => void m.set(k, v),
		removeItem: (k: string) => void m.delete(k)
	} as Storage;
}

beforeEach(() => {
	vi.stubGlobal('localStorage', memoryStorage());
});

describe('deviceToken', () => {
	it('round-trips and clears a token', () => {
		expect(getDeviceToken()).toBeNull();
		setDeviceToken('abc');
		expect(getDeviceToken()).toBe('abc');
		clearDeviceToken();
		expect(getDeviceToken()).toBeNull();
	});
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd frontend && bun run test src/lib/remote/deviceToken.test.ts`
Expected: FAIL — `./deviceToken` does not exist (import error).

- [ ] **Step 3: Implement the token store**

Create `frontend/src/lib/remote/deviceToken.ts`:

```ts
// The remote device's bearer credential — a Phoenix.Token string minted by
// POST /api/pair. Persisted in localStorage. Loopback (desktop / local browser)
// never holds one; absence means "trusted by loopback or not yet paired".
const KEY = 'legend.device_token';

export function getDeviceToken(): string | null {
	try {
		return localStorage.getItem(KEY);
	} catch {
		return null;
	}
}

export function setDeviceToken(token: string): void {
	try {
		localStorage.setItem(KEY, token);
	} catch {
		// localStorage unavailable — pairing can't persist; the caller surfaces it.
	}
}

export function clearDeviceToken(): void {
	try {
		localStorage.removeItem(KEY);
	} catch {
		// non-fatal
	}
}
```

- [ ] **Step 4: Run the token-store test to verify it passes**

Run: `cd frontend && bun run test src/lib/remote/deviceToken.test.ts`
Expected: PASS.

- [ ] **Step 5: Write the failing test for `authHeaders` + `apiFetch`**

Create `frontend/src/lib/api.test.ts`:

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { authHeaders, apiFetch } from './api';
import { setDeviceToken } from './remote/deviceToken';

function memoryStorage(): Storage {
	const m = new Map<string, string>();
	return {
		length: 0,
		clear: () => m.clear(),
		key: () => null,
		getItem: (k: string) => (m.has(k) ? (m.get(k) as string) : null),
		setItem: (k: string, v: string) => void m.set(k, v),
		removeItem: (k: string) => void m.delete(k)
	} as Storage;
}

beforeEach(() => {
	vi.stubGlobal('localStorage', memoryStorage());
});

describe('authHeaders', () => {
	it('is empty without a token', () => {
		expect(authHeaders()).toEqual({});
	});

	it('carries the bearer token when set', () => {
		setDeviceToken('tok123');
		expect(authHeaders()).toEqual({ Authorization: 'Bearer tok123' });
	});
});

describe('apiFetch', () => {
	it('prepends the base and merges auth + caller headers', async () => {
		setDeviceToken('tok123');
		const calls: Array<[string, RequestInit]> = [];
		vi.stubGlobal('fetch', (url: string, init: RequestInit) => {
			calls.push([url, init]);
			return Promise.resolve(new Response('{}', { status: 200 }));
		});

		await apiFetch('/api/sessions', { headers: { Accept: 'application/json' } });

		const [url, init] = calls[0];
		expect(url).toBe('/api/sessions'); // apiBase is '' in tests
		expect(init.headers).toEqual({
			Authorization: 'Bearer tok123',
			Accept: 'application/json'
		});
	});
});
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd frontend && bun run test src/lib/api.test.ts`
Expected: FAIL — `authHeaders` / `apiFetch` are not exported yet.

- [ ] **Step 7: Implement `authHeaders` + `apiFetch` in `api.ts`**

Replace the entire contents of `frontend/src/lib/api.ts` with:

```ts
import { PUBLIC_API_URL } from '$env/static/public';
import { getDeviceToken, clearDeviceToken } from './remote/deviceToken';

export const apiBase = PUBLIC_API_URL || '';

/** Bearer header when a device token is present; empty on loopback (desktop/local). */
export function authHeaders(): Record<string, string> {
	const token = getDeviceToken();
	return token ? { Authorization: `Bearer ${token}` } : {};
}

/**
 * fetch wrapper for the device-gated REST API: prepends the base, attaches the
 * device bearer token, and on a 401 clears the now-invalid token and sends the
 * user to /pair to re-pair. Loopback never 401s, so the desktop path is
 * unaffected; the /pair page is exempt to avoid a redirect loop.
 */
export async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
	const res = await fetch(`${apiBase}${path}`, {
		...init,
		headers: { ...authHeaders(), ...(init.headers as Record<string, string> | undefined) }
	});

	if (res.status === 401 && typeof window !== 'undefined' && window.location.pathname !== '/pair') {
		clearDeviceToken();
		window.location.href = '/pair';
	}

	return res;
}

export async function getHealth(): Promise<{ status: string }> {
	const res = await fetch(`${apiBase}/api/health`);
	if (!res.ok) throw new Error(`health check failed: ${res.status}`);
	return res.json();
}
```

- [ ] **Step 8: Run the api test to verify it passes**

Run: `cd frontend && bun run test src/lib/api.test.ts`
Expected: PASS.

- [ ] **Step 9: Migrate `sessions.ts` callsites**

In `frontend/src/lib/sessions.ts`, change the import line `import { apiBase } from './api';` to `import { apiFetch } from './api';`, then replace each `fetch(\`${apiBase}…\`, …)` with `apiFetch('…', …)` (drop `${apiBase}`, the URL becomes a path string):

- `fetch(\`${apiBase}/api/harnesses\`)` → `apiFetch('/api/harnesses')`
- `fetch(\`${apiBase}/api/runtimes\`)` → `apiFetch('/api/runtimes')`
- `fetch(\`${apiBase}/api/sessions\`, { headers: { Accept: JSONAPI } })` → `apiFetch('/api/sessions', { headers: { Accept: JSONAPI } })`
- `fetch(\`${apiBase}/api/sessions\`, { method: 'POST', … })` → `apiFetch('/api/sessions', { method: 'POST', … })`
- `fetch(\`${apiBase}/api/sessions/${id}/resume\`, …)` → `apiFetch(\`/api/sessions/${id}/resume\`, …)`
- `fetch(\`${apiBase}/api/sessions/${id}/transport\`, …)` → `apiFetch(\`/api/sessions/${id}/transport\`, …)`
- `fetch(\`${apiBase}/api/sessions/${id}/rename\`, …)` → `apiFetch(\`/api/sessions/${id}/rename\`, …)`
- `fetch(\`${apiBase}/api/sessions/${id}\`, { method: 'DELETE', … })` → `apiFetch(\`/api/sessions/${id}\`, { method: 'DELETE', … })`
- `fetch(\`${apiBase}/api/harnesses/${id}/setup\`, { method: 'POST' })` → `apiFetch(\`/api/harnesses/${id}/setup\`, { method: 'POST' })`

(The `${id}` templated paths stay template literals; only `${apiBase}` is removed.)

- [ ] **Step 10: Migrate `settings.ts`, `messages.ts`, `library.ts` callsites**

In each file, change `import { apiBase } from './api';` to `import { apiFetch } from './api';` and replace `fetch(\`${apiBase}…\`, …)` with `apiFetch('…', …)`:

`frontend/src/lib/settings.ts`:
- `apiFetch('/api/settings/library-path')`
- `apiFetch('/api/settings/library-path', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: … })`
- `apiFetch('/api/settings/library-path', { method: 'DELETE' })`

`frontend/src/lib/messages.ts`:
- `apiFetch('/api/messages', { method: 'POST', headers: { 'Content-Type': JSONAPI, Accept: JSONAPI }, body: … })`

`frontend/src/lib/library.ts`:
- `apiFetch('/api/library/tree')`
- `apiFetch(\`/api/library/file?path=${encodeURIComponent(path)}\`)`
- `apiFetch('/api/library/file', { method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: … })`
- `apiFetch(\`/api/library/file?path=${encodeURIComponent(path)}\`, { method: 'DELETE' })`

- [ ] **Step 11: Typecheck + full test run**

Run: `cd frontend && bun run check && bun run test`
Expected: svelte-check 0 errors; all vitest tests pass (no remaining `apiBase` import errors in the migrated files).

- [ ] **Step 12: Commit**

```bash
git add frontend/src/lib/remote/deviceToken.ts frontend/src/lib/remote/deviceToken.test.ts frontend/src/lib/api.ts frontend/src/lib/api.test.ts frontend/src/lib/sessions.ts frontend/src/lib/settings.ts frontend/src/lib/messages.ts frontend/src/lib/library.ts
git commit -m "feat(remote): device-token store + auth-aware apiFetch

localStorage device token attached as Authorization: Bearer on every
/api/* call via a shared apiFetch; a 401 clears the token and routes to
/pair. Loopback sends no token and is unchanged. Migrate sessions /
settings / messages / library clients onto apiFetch.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Frontend — socket auth param

**Files:**
- Modify: `frontend/src/lib/socket.ts` (pass the device token as a connect param)
- Create: `frontend/src/lib/socket.test.ts`

**Interfaces:**
- Consumes: `getDeviceToken()` (Task 2).
- Produces: `getSocket()` now connects with `{ params: { token } }` when a token is present (loopback connects with no params, unchanged). The socket singleton reads the token once at first connect; pairing does a full-page navigation (Task 4) so a fresh load re-inits the socket with the token.

- [ ] **Step 1: Write the failing test**

Create `frontend/src/lib/socket.test.ts`:

```ts
import { describe, it, expect, beforeEach, vi } from 'vitest';

function memoryStorage(): Storage {
	const m = new Map<string, string>();
	return {
		length: 0,
		clear: () => m.clear(),
		key: () => null,
		getItem: (k: string) => (m.has(k) ? (m.get(k) as string) : null),
		setItem: (k: string, v: string) => void m.set(k, v),
		removeItem: (k: string) => void m.delete(k)
	} as Storage;
}

// Capture the params the phoenix Socket constructor is called with.
const ctorCalls: Array<{ url: string; opts: unknown }> = [];
vi.mock('phoenix', () => ({
	Socket: class {
		constructor(url: string, opts: unknown) {
			ctorCalls.push({ url, opts });
		}
		connect() {}
	}
}));

beforeEach(() => {
	ctorCalls.length = 0;
	vi.stubGlobal('localStorage', memoryStorage());
	vi.resetModules();
});

describe('getSocket', () => {
	it('passes the device token as a connect param when present', async () => {
		localStorage.setItem('legend.device_token', 'tok123');
		const { getSocket } = await import('./socket');
		getSocket();
		expect(ctorCalls[0].opts).toEqual({ params: { token: 'tok123' } });
	});

	it('connects with no params on loopback (no token)', async () => {
		const { getSocket } = await import('./socket');
		getSocket();
		expect(ctorCalls[0].opts).toEqual({});
	});
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd frontend && bun run test src/lib/socket.test.ts`
Expected: FAIL — current `getSocket` constructs `new Socket(url)` with no second argument, so `opts` is `undefined`, not `{}`/`{ params }`.

- [ ] **Step 3: Implement the token param**

Replace the entire contents of `frontend/src/lib/socket.ts` with:

```ts
import { Socket } from 'phoenix';
import { PUBLIC_WS_URL } from '$env/static/public';
import { getDeviceToken } from './remote/deviceToken';

let socket: Socket | undefined;

/**
 * Lazily-connected singleton Phoenix socket. When a device token exists it is
 * sent as the `token` connect param (verified by UserSocket.connect/3); loopback
 * has no token and connects anonymously, exactly as before. The token is read
 * once at first connect — pairing navigates the page so a fresh load re-inits.
 */
export function getSocket(): Socket {
	if (!socket) {
		const token = getDeviceToken();
		socket = new Socket(PUBLIC_WS_URL || '/socket', token ? { params: { token } } : {});
		socket.connect();
	}
	return socket;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd frontend && bun run test src/lib/socket.test.ts`
Expected: PASS (both cases).

- [ ] **Step 5: Typecheck**

Run: `cd frontend && bun run check`
Expected: 0 errors.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/socket.ts frontend/src/lib/socket.test.ts
git commit -m "feat(remote): send device token as socket connect param

getSocket() attaches { params: { token } } when a device token is
present; loopback connects anonymously as before.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Frontend — `/pair` redeem route + shell-less layout branch

**Files:**
- Create: `frontend/src/lib/remote/devices.ts` (the `redeemPairCode` client + shared types)
- Create: `frontend/src/routes/pair/+page.svelte`
- Modify: `frontend/src/routes/+layout.svelte` (render `/pair` bare — no shell)

**Interfaces:**
- Consumes: `apiFetch` (Task 2), `setDeviceToken` (Task 2), `page` from `$app/state`.
- Produces: `redeemPairCode(code: string, name?: string): Promise<{ token: string; device: { id: string; name: string | null } }>` (from `remote/devices.ts`); the `/pair` route; a `bare` branch in the root layout keyed on `page.route.id === '/pair'`. Task 6 extends `remote/devices.ts` with management calls.

- [ ] **Step 1: Create the pairing API client**

Create `frontend/src/lib/remote/devices.ts`:

```ts
import { apiFetch } from '$lib/api';

async function fail(res: Response, fallback: string): Promise<never> {
	let detail = `${res.status}`;
	try {
		detail = (await res.json()).error ?? detail;
	} catch {
		// keep status code
	}
	throw new Error(`${fallback}: ${detail}`);
}

export interface PairResult {
	token: string;
	device: { id: string; name: string | null };
}

/** Redeem a pairing code (public, pre-auth). The instance mints a device token. */
export async function redeemPairCode(code: string, name?: string): Promise<PairResult> {
	const res = await apiFetch('/api/pair', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ code, name })
	});
	if (!res.ok) await fail(res, 'pairing failed');
	return res.json();
}
```

- [ ] **Step 2: Create the `/pair` page**

Create `frontend/src/routes/pair/+page.svelte`:

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { redeemPairCode } from '$lib/remote/devices';
	import { setDeviceToken } from '$lib/remote/deviceToken';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';

	let code = $state('');
	let name = $state('');
	let status = $state<'idle' | 'pairing' | 'done' | 'error'>('idle');
	let error = $state('');

	async function pair() {
		const c = code.trim();
		if (!c || status === 'pairing') return;
		status = 'pairing';
		error = '';
		try {
			const { token } = await redeemPairCode(c, name.trim() || undefined);
			setDeviceToken(token);
			status = 'done';
			// Full navigation so the singleton socket/api clients re-init with the token.
			window.location.href = '/';
		} catch (e) {
			status = 'error';
			error = e instanceof Error ? e.message : 'pairing failed';
		}
	}

	onMount(() => {
		// A QR deep-link arrives as /pair?code=XXXX → prefill and auto-submit.
		const fromUrl = page.url.searchParams.get('code');
		if (fromUrl) {
			code = fromUrl;
			void pair();
		}
	});
</script>

<div class="flex min-h-dvh flex-col items-center justify-center bg-shell px-6">
	<div class="w-full max-w-[360px] rounded-[14px] border border-hair bg-panel p-6">
		<h1 class="text-title font-semibold text-ink-1">Pair this device</h1>
		<p class="mt-1 text-ui text-ink-3">Enter the pairing code shown in Legend on your computer.</p>

		<div class="mt-5 flex flex-col gap-3">
			<Input bind:value={code} placeholder="Pairing code" autocomplete="off" />
			<Input bind:value={name} placeholder="Device name (optional)" autocomplete="off" />
			<Button onclick={pair} disabled={!code.trim() || status === 'pairing'}>
				{status === 'pairing' ? 'Pairing…' : 'Pair'}
			</Button>
		</div>

		{#if status === 'error'}
			<p class="mt-3 text-ui text-bad">{error}</p>
		{/if}
		{#if status === 'done'}
			<p class="mt-3 text-ui text-ok">Paired. Opening Legend…</p>
		{/if}
	</div>
</div>
```

- [ ] **Step 3: Add the bare branch to the root layout**

Replace the entire contents of `frontend/src/routes/+layout.svelte` with:

```svelte
<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import { page } from '$app/state';
	import LegendShell from '$lib/components/shell/LegendShell.svelte';

	let { children } = $props();

	// /pair is a standalone, shell-less screen (pre-auth, phone-width).
	const bare = $derived(page.route.id === '/pair');
</script>

<svelte:head><link rel="icon" href={favicon} /></svelte:head>

{#if bare}
	{@render children()}
{:else}
	<LegendShell>
		{@render children()}
	</LegendShell>
{/if}
```

- [ ] **Step 4: Typecheck**

Run: `cd frontend && bun run check`
Expected: 0 errors.

- [ ] **Step 5: Manual verification**

Run the dev stack (`just dev` from the repo root) and open `http://localhost:4173/pair`.
Expected: a centered "Pair this device" card with **no** dock / tile grid / status bar around it. Submitting a bogus code shows the red "pairing failed" error. (Generating a real code is verified in Task 6; a quick check now: `curl -s -X POST http://localhost:4100/api/devices/pair-code` returns `{"code":"…"}` from loopback — pasting that code pairs and redirects to `/`.)

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/remote/devices.ts frontend/src/routes/pair/+page.svelte frontend/src/routes/+layout.svelte
git commit -m "feat(remote): /pair redeem route + shell-less layout branch

Standalone phone-width pairing screen: redeems a code via POST /api/pair,
stores the device token, and full-navigates into the app. Root layout
renders /pair without the desktop shell.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Frontend — viewport store + `MobileShell` (list → session)

**Files:**
- Create: `frontend/src/lib/remote/viewport.svelte.ts` (reactive `isMobile`)
- Create: `frontend/src/lib/components/mobile/MobileShell.svelte`
- Create: `frontend/src/lib/components/mobile/MobileSessionList.svelte`
- Create: `frontend/src/lib/components/mobile/MobileSession.svelte`
- Modify: `frontend/src/routes/+layout.svelte` (add the mobile branch)

**Interfaces:**
- Consumes: `sessionsStore` (`.sessions`, `.loaded`, `.connect()`), `messagesStore` (`.connect()`, `.unreadCount(id)`, `.forSession(id)`), `liveState`, `isRunningLike`, `identityFor`, `relativeTime`, `mostRecentIso`, `listHarnesses`, `setTransport`, `resumeSession`, `Terminal`, `AcpConversation`, `getDeviceToken`, `clearDeviceToken`.
- Produces: `isMobile` (`{ get current(): boolean }`) from `viewport.svelte.ts`; `MobileShell` (self-contained, takes no props — selects list vs session via internal state). The root layout renders `<MobileShell />` for phone viewports outside `/pair`.

- [ ] **Step 1: Create the viewport store**

Create `frontend/src/lib/remote/viewport.svelte.ts`:

```ts
// Reactive narrow-viewport flag: phones get MobileShell, desktops LegendShell.
// SSR is off, so window is available at first client render — no flash. A live
// matchMedia listener flips it when a desktop window is resized (also makes it
// trivially testable by narrowing the window).
const QUERY = '(max-width: 760px)';

function createIsMobile() {
	let matches = $state(false);
	if (typeof window !== 'undefined' && typeof window.matchMedia === 'function') {
		const mql = window.matchMedia(QUERY);
		matches = mql.matches;
		mql.addEventListener('change', (e) => {
			matches = e.matches;
		});
	}
	return {
		get current() {
			return matches;
		}
	};
}

export const isMobile = createIsMobile();
```

- [ ] **Step 2: Create the session list**

Create `frontend/src/lib/components/mobile/MobileSessionList.svelte`:

```svelte
<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { relativeTime, mostRecentIso } from '$lib/shell/format';
	import { getDeviceToken, clearDeviceToken } from '$lib/remote/deviceToken';

	let { onOpen }: { onOpen: (id: string) => void } = $props();

	let menuOpen = $state(false);
	const paired = getDeviceToken() !== null;

	function unpair() {
		clearDeviceToken();
		window.location.reload();
	}

	const rows = $derived(
		sessionsStore.sessions.map((s) => ({
			session: s,
			state: liveState(s),
			identity: identityFor(s.harness_id),
			unread: messagesStore.unreadCount(s.id),
			lastActive: mostRecentIso(
				messagesStore.forSession(s.id).at(-1)?.inserted_at,
				s.ended_at,
				s.started_at,
				s.updated_at,
				s.inserted_at
			)
		}))
	);
</script>

<header class="flex h-[52px] shrink-0 items-center justify-between border-b border-hair px-4">
	<span class="text-title font-semibold text-ink-1">Legend</span>
	{#if paired}
		<div class="relative">
			<IconButton icon="gear" size={18} title="Device" active={menuOpen} onclick={() => (menuOpen = !menuOpen)} />
			{#if menuOpen}
				<div class="absolute right-0 top-[36px] z-10 w-[200px] rounded-[10px] border border-hair bg-panel p-1 shadow-lg">
					<button
						type="button"
						onclick={unpair}
						class="w-full rounded-[7px] px-3 py-2 text-left text-ui text-ink-1 active:bg-[var(--hover-tint)]"
					>
						Unpair this device
					</button>
				</div>
			{/if}
		</div>
	{/if}
</header>

<div class="min-h-0 flex-1 overflow-y-auto">
	{#each rows as row (row.session.id)}
		{@const time = relativeTime(row.lastActive)}
		<button
			type="button"
			onclick={() => onOpen(row.session.id)}
			class="flex w-full items-center gap-3 border-b border-hair px-4 py-3 text-left active:bg-[var(--hover-tint)]"
		>
			<StatusDot color={row.state.dotColor} pulse={row.state.pulse} size={7} />
			<div class="flex min-w-0 flex-1 flex-col gap-0.5">
				<div class="flex items-center gap-2">
					<span class="min-w-0 flex-1 truncate text-ui font-medium text-ink-1">
						{row.session.name || row.session.harness_id}
					</span>
					<span
						class="shrink-0 font-mono text-micro font-bold tracking-[0.04em]"
						style:color="var({row.identity.colorVar})"
					>
						{row.identity.tag}
					</span>
				</div>
				<div class="flex items-center gap-2 text-meta text-ink-3">
					<span class="truncate">{row.state.label}</span>
					{#if row.unread > 0}
						<span
							class="shrink-0 rounded-full px-1.5 font-bold"
							style:background="var(--accent)"
							style:color="var(--accent-contrast)"
						>
							{row.unread}
						</span>
					{/if}
					{#if row.state.flag}
						<span
							class="shrink-0 font-mono font-bold"
							style:color={row.state.flag === 'ERR' ? 'var(--red)' : 'var(--amber)'}
						>
							{row.state.flag}
						</span>
					{/if}
					{#if time}<span class="ml-auto shrink-0 font-mono tabular-nums">{time}</span>{/if}
				</div>
			</div>
			<Icon name="chevron-right" size={16} class="shrink-0 text-ink-3" />
		</button>
	{:else}
		<p class="px-4 py-6 text-ui text-ink-3">
			{sessionsStore.loaded ? 'No sessions.' : 'Connecting…'}
		</p>
	{/each}
</div>
```

- [ ] **Step 3: Create the single-session view**

Create `frontend/src/lib/components/mobile/MobileSession.svelte`:

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import Terminal from '$lib/components/Terminal.svelte';
	import AcpConversation from '$lib/components/sessions/AcpConversation.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { listHarnesses, resumeSession, setTransport, type Harness } from '$lib/sessions';

	let { sessionId, onBack }: { sessionId: string; onBack: () => void } = $props();

	const session = $derived(sessionsStore.sessions.find((s) => s.id === sessionId) ?? null);
	const live = $derived(session ? liveState(session) : null);
	const identity = $derived(session ? identityFor(session.harness_id) : null);
	const running = $derived(
		session
			? session.status === 'running' ||
					session.status === 'starting' ||
					session.status === 'provisioning'
			: false
	);

	// queueState lives here (no {#key} remount on mobile) and threads to AcpConversation.
	const queueState = $state<{ items: string[] }>({ items: [] });

	let harness = $state<Harness>();
	onMount(async () => {
		try {
			const hs = await listHarnesses();
			harness = hs.find((h) => h.id === session?.harness_id);
		} catch {
			// no toggle if the harness list can't be fetched
		}
	});
	const canSwitch = $derived((harness?.transports?.length ?? 0) > 1);

	let switching = $state(false);
	async function switchTransport(t: 'terminal' | 'acp') {
		if (!session || t === session.transport || switching) return;
		switching = true;
		try {
			await setTransport(session.id, t);
		} catch {
			// stays put; the lobby refetch reflects the truth
		} finally {
			switching = false;
		}
	}

	let resuming = $state(false);
	async function resume() {
		if (!session || resuming) return;
		resuming = true;
		try {
			await resumeSession(session.id);
		} catch {
			// stays stopped
		} finally {
			resuming = false;
		}
	}
</script>

<header class="flex h-[52px] shrink-0 items-center gap-2 border-b border-hair px-2">
	<button
		type="button"
		onclick={onBack}
		title="Back"
		class="grid h-8 w-8 shrink-0 place-items-center rounded-[7px] text-ink-2 active:bg-[var(--hover-tint)]"
	>
		<Icon name="chevron-right" size={20} class="rotate-180" />
	</button>

	{#if session && live && identity}
		<StatusDot color={live.dotColor} pulse={live.pulse} size={7} />
		<span class="min-w-0 flex-1 truncate text-ui font-semibold text-ink-1">
			{session.name || session.harness_id}
		</span>
		<span class="shrink-0 font-mono text-micro font-bold" style:color="var({identity.colorVar})">
			{identity.tag}
		</span>
		{#if canSwitch}
			<div class="flex shrink-0 overflow-hidden rounded-[7px] border border-hair-strong text-micro">
				<button
					type="button"
					disabled={switching}
					class="px-2 py-1 font-bold disabled:opacity-50 {session.transport === 'acp'
						? 'bg-brand text-app'
						: 'text-ink-2'}"
					onclick={() => switchTransport('acp')}
				>
					rich
				</button>
				<button
					type="button"
					disabled={switching}
					class="px-2 py-1 font-bold disabled:opacity-50 {session.transport === 'terminal'
						? 'bg-brand text-app'
						: 'text-ink-2'}"
					onclick={() => switchTransport('terminal')}
				>
					term
				</button>
			</div>
		{/if}
	{:else}
		<span class="flex-1 text-ui text-ink-3">Session unavailable</span>
	{/if}
</header>

<div class="relative min-h-0 flex-1 overflow-hidden">
	{#if session}
		{#if session.transport === 'acp'}
			<AcpConversation sessionId={session.id} {queueState} />
		{:else}
			<Terminal sessionId={session.id} fontSize={13} background="#100d1a" />
		{/if}

		{#if !running}
			<div
				class="absolute inset-0 flex flex-col items-center justify-center gap-3 px-6 text-center"
				style:background="color-mix(in oklab, var(--bg-app) 82%, transparent)"
			>
				<span class="font-mono text-meta uppercase tracking-[0.1em]" style:color={live?.dotColor}>
					{live?.label}
				</span>
				<button
					type="button"
					onclick={resume}
					disabled={resuming}
					class="flex items-center gap-1.5 rounded-[9px] border border-hair-strong bg-raised px-4 py-2 text-ui font-medium text-ink-1 disabled:opacity-50"
				>
					<Icon name="refresh" size={14} />
					{resuming ? 'Resuming…' : session.status === 'interrupted' ? 'Resume' : 'Restart'}
				</button>
			</div>
		{/if}
	{/if}
</div>
```

- [ ] **Step 4: Create the mobile shell**

Create `frontend/src/lib/components/mobile/MobileShell.svelte`:

```svelte
<script lang="ts">
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import MobileSessionList from './MobileSessionList.svelte';
	import MobileSession from './MobileSession.svelte';

	// Connect the live stores exactly as LegendShell does.
	$effect(() => {
		sessionsStore.connect();
		messagesStore.connect();
	});

	let selectedId = $state<string | null>(null);

	// If the selected session vanishes (stopped/removed), fall back to the list.
	$effect(() => {
		if (selectedId && !sessionsStore.sessions.some((s) => s.id === selectedId)) {
			selectedId = null;
		}
	});
</script>

<div class="flex h-dvh w-full flex-col overflow-hidden bg-app">
	{#if selectedId}
		<MobileSession sessionId={selectedId} onBack={() => (selectedId = null)} />
	{:else}
		<MobileSessionList onOpen={(id) => (selectedId = id)} />
	{/if}
</div>
```

- [ ] **Step 5: Wire the mobile branch into the root layout**

In `frontend/src/routes/+layout.svelte`, add two imports and the mobile branch. The `<script>` becomes:

```svelte
<script lang="ts">
	import './layout.css';
	import favicon from '$lib/assets/favicon.svg';
	import { page } from '$app/state';
	import LegendShell from '$lib/components/shell/LegendShell.svelte';
	import MobileShell from '$lib/components/mobile/MobileShell.svelte';
	import { isMobile } from '$lib/remote/viewport.svelte';

	let { children } = $props();

	// /pair is a standalone, shell-less screen (pre-auth, phone-width).
	const bare = $derived(page.route.id === '/pair');
</script>
```

and the markup branch becomes:

```svelte
<svelte:head><link rel="icon" href={favicon} /></svelte:head>

{#if bare}
	{@render children()}
{:else if isMobile.current}
	<MobileShell />
{:else}
	<LegendShell>
		{@render children()}
	</LegendShell>
{/if}
```

(Note: on phone viewports the mobile shell ignores `children` and routes internally; deep-linking to a specific session on mobile is deferred — non-`/pair` routes show the mobile session list.)

- [ ] **Step 6: Typecheck**

Run: `cd frontend && bun run check`
Expected: 0 errors.

- [ ] **Step 7: Manual verification**

Run `just dev`, open `http://localhost:4173/`, and narrow the browser window below 760px (or use devtools device toolbar).
Expected: the tiling shell is replaced by the mobile list (header "Legend" + session rows with status dot, name, agent tag, state, time). Tapping a row opens the single-session view with a back chevron; rich sessions show the ACP conversation + composer, the rich/term toggle switches transport, and a stopped session shows the Resume/Restart overlay. Widen the window past 760px → the desktop tiling shell returns.

- [ ] **Step 8: Commit**

```bash
git add frontend/src/lib/remote/viewport.svelte.ts frontend/src/lib/components/mobile/ frontend/src/routes/+layout.svelte
git commit -m "feat(remote): lean MobileShell (list to session) + viewport branch

Phone viewports (<=760px) get a dedicated MobileShell — full-screen
session list and single-session view reusing AcpConversation/Terminal +
the live stores, with mobile chrome (back, rich/term toggle, resume,
unpair). Desktop tiling shell is untouched.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Frontend — desktop "Remote access" Settings section (toggle, devices, QR, audit)

**Files:**
- Modify: `frontend/src/lib/remote/devices.ts` (add management + remote-access API calls)
- Create: `frontend/src/lib/components/shell/RemoteAccessSection.svelte`
- Modify: `frontend/src/lib/components/shell/SettingsModal.svelte` (render the new section)
- Add dependency: `qrcode` (+ `@types/qrcode`)

**Interfaces:**
- Consumes: `apiFetch` (Task 2); the backend endpoints `GET/PUT/DELETE /api/settings/remote-access`, `GET /api/devices`, `POST /api/devices/pair-code`, `DELETE /api/devices/:id`, `GET /api/devices/audit` (Task 1); `ConfirmButton`, `Button`, `Input`, `Label`, `SectionLabel`, `relativeTime`; `qrcode`.
- Produces: a `RemoteAccessSection` component embedded in the Settings modal. Loopback-only in practice (it's the desktop settings UI).

- [ ] **Step 1: Add the QR dependency**

Run: `cd frontend && bun add qrcode && bun add -d @types/qrcode`
Expected: `qrcode` lands in `dependencies`, `@types/qrcode` in `devDependencies`.

- [ ] **Step 2: Extend the remote API client**

Append to `frontend/src/lib/remote/devices.ts` (the `fail` helper already exists from Task 4):

```ts
export interface RemoteAccess {
	enabled: boolean;
	host: string | null;
}

export interface Device {
	id: string;
	name: string | null;
	paired_at: string | null;
	last_seen_at: string | null;
	revoked_at: string | null;
}

export interface AuditEvent {
	id: string;
	device_id: string | null;
	session_id: string | null;
	action: string;
	at: string;
}

export async function getRemoteAccess(): Promise<RemoteAccess> {
	const res = await apiFetch('/api/settings/remote-access');
	if (!res.ok) await fail(res, 'loading remote access failed');
	return (await res.json()).data;
}

export async function setRemoteAccess(
	enabled: boolean,
	host: string | null
): Promise<{ data: RemoteAccess; restart_required?: boolean }> {
	const res = await apiFetch('/api/settings/remote-access', {
		method: 'PUT',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ enabled, host })
	});
	if (!res.ok) await fail(res, 'saving remote access failed');
	return res.json();
}

export async function listDevices(): Promise<Device[]> {
	const res = await apiFetch('/api/devices');
	if (!res.ok) await fail(res, 'listing devices failed');
	return (await res.json()).data;
}

export async function generatePairCode(): Promise<{ code: string; expires_at: string }> {
	const res = await apiFetch('/api/devices/pair-code', { method: 'POST' });
	if (!res.ok) await fail(res, 'generating pairing code failed');
	return res.json();
}

export async function revokeDevice(id: string): Promise<void> {
	const res = await apiFetch(`/api/devices/${id}`, { method: 'DELETE' });
	if (!res.ok) await fail(res, 'revoking device failed');
}

export async function listAudit(): Promise<AuditEvent[]> {
	const res = await apiFetch('/api/devices/audit');
	if (!res.ok) await fail(res, 'loading audit failed');
	return (await res.json()).data;
}
```

- [ ] **Step 3: Create the Remote-access section component**

Create `frontend/src/lib/components/shell/RemoteAccessSection.svelte`:

```svelte
<script lang="ts">
	import { onMount } from 'svelte';
	import QRCode from 'qrcode';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import { relativeTime } from '$lib/shell/format';
	import {
		getRemoteAccess,
		setRemoteAccess,
		listDevices,
		generatePairCode,
		revokeDevice,
		listAudit,
		type RemoteAccess,
		type Device,
		type AuditEvent
	} from '$lib/remote/devices';

	let remote = $state<RemoteAccess>({ enabled: false, host: null });
	let host = $state('');
	let saving = $state(false);
	let restartRequired = $state(false);
	let error = $state('');

	let devices = $state<Device[]>([]);
	let audit = $state<AuditEvent[]>([]);
	let auditOpen = $state(false);

	// Active pairing code + its QR data URL.
	let code = $state('');
	let qr = $state('');
	let codeExpires = $state('');

	const activeDevices = $derived(devices.filter((d) => !d.revoked_at));

	// The phone reaches the instance at the configured mesh host on the same port
	// the desktop browser is using (0.0.0.0 binds both). TLS is deferred → http.
	const pairUrl = $derived.by(() => {
		const h = (remote.host || host).trim();
		if (!h || !code) return '';
		const port = typeof window !== 'undefined' ? window.location.port : '';
		const authority = port ? `${h}:${port}` : h;
		return `http://${authority}/pair?code=${encodeURIComponent(code)}`;
	});

	$effect(() => {
		if (pairUrl) {
			void QRCode.toDataURL(pairUrl, { margin: 1, width: 220 }).then((url) => (qr = url));
		} else {
			qr = '';
		}
	});

	async function load() {
		error = '';
		try {
			remote = await getRemoteAccess();
			host = remote.host ?? '';
			devices = await listDevices();
			audit = await listAudit();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load remote access';
		}
	}

	async function toggle(next: boolean) {
		if (saving) return;
		saving = true;
		error = '';
		restartRequired = false;
		try {
			const result = await setRemoteAccess(next, host.trim() || null);
			remote = result.data;
			host = remote.host ?? '';
			restartRequired = !!result.restart_required;
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to save';
		} finally {
			saving = false;
		}
	}

	async function newCode() {
		error = '';
		try {
			const c = await generatePairCode();
			code = c.code;
			codeExpires = c.expires_at;
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to generate code';
		}
	}

	async function revoke(id: string) {
		try {
			await revokeDevice(id);
			devices = await listDevices();
			audit = await listAudit();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to revoke';
		}
	}

	onMount(load);
</script>

<section class="flex flex-col gap-3">
	<SectionLabel>Remote access</SectionLabel>

	<p class="text-ui text-ink-2">
		Reach this instance from a paired device over your mesh VPN. Off by default; enabling binds the
		network interface on the next restart.
	</p>

	<div class="flex flex-col gap-2">
		<Label for="remote-host">Mesh host (the name/IP this machine is reached at)</Label>
		<Input id="remote-host" bind:value={host} placeholder="laptop.tailnet.ts.net" />
	</div>

	<div class="flex items-center gap-2">
		{#if remote.enabled}
			<Button size="sm" variant="outline" onclick={() => toggle(false)} disabled={saving}>
				Disable remote access
			</Button>
			<span class="text-meta text-ok">Enabled · host {remote.host}</span>
		{:else}
			<Button size="sm" onclick={() => toggle(true)} disabled={saving || !host.trim()}>
				Enable remote access
			</Button>
		{/if}
	</div>

	{#if restartRequired}
		<p class="text-ui text-ink-2">Restart Legend to apply the new bind.</p>
	{/if}

	<!-- Pairing -->
	<div class="flex flex-col gap-2 rounded-[10px] border border-hair p-3">
		<div class="flex items-center justify-between">
			<span class="text-ui font-medium text-ink-1">Pair a device</span>
			<Button size="sm" variant="outline" onclick={newCode}>Generate code</Button>
		</div>

		{#if code}
			{#if qr}
				<img src={qr} alt="Pairing QR code" class="self-center rounded-[8px] bg-white p-2" width="180" height="180" />
			{/if}
			<p class="text-center font-mono text-body text-ink-1">{code}</p>
			<p class="text-center text-meta text-ink-3">
				Scan the QR or enter the code on the device. Expires {relativeTime(codeExpires)}.
			</p>
			{#if !remote.host && !host.trim()}
				<p class="text-center text-meta text-bad">Set the mesh host above so the QR points at the right address.</p>
			{/if}
		{/if}
	</div>

	<!-- Paired devices -->
	{#if activeDevices.length > 0}
		<div class="flex flex-col gap-1">
			<span class="text-meta text-ink-3">Paired devices</span>
			{#each activeDevices as d (d.id)}
				<div class="flex items-center gap-2 rounded-[8px] border border-hair px-3 py-2">
					<span class="min-w-0 flex-1 truncate text-ui text-ink-1">{d.name || 'unnamed device'}</span>
					<span class="shrink-0 text-meta text-ink-3">
						{d.last_seen_at ? `seen ${relativeTime(d.last_seen_at)}` : 'never seen'}
					</span>
					<ConfirmButton idleLabel="Revoke" confirmLabel="Confirm revoke" onconfirm={() => revoke(d.id)} />
				</div>
			{/each}
		</div>
	{/if}

	<!-- Audit trail -->
	<div class="flex flex-col gap-1">
		<button
			type="button"
			class="self-start text-meta text-ink-3 underline underline-offset-2 hover:text-ink-2"
			onclick={() => (auditOpen = !auditOpen)}
		>
			{auditOpen ? 'Hide' : 'Show'} audit trail ({audit.length})
		</button>
		{#if auditOpen}
			<div class="flex max-h-[180px] flex-col gap-0.5 overflow-y-auto rounded-[8px] border border-hair p-2">
				{#each audit as e (e.id)}
					<div class="flex items-center gap-2 font-mono text-micro text-ink-3">
						<span class="text-ink-2">{e.action}</span>
						<span class="truncate">{e.device_id ?? 'local'}</span>
						<span class="ml-auto shrink-0">{relativeTime(e.at)}</span>
					</div>
				{:else}
					<p class="text-micro text-ink-3">No events yet.</p>
				{/each}
			</div>
		{/if}
	</div>

	{#if error}
		<p class="text-ui text-bad">{error}</p>
	{/if}
</section>
```

- [ ] **Step 4: Render the section in the Settings modal**

In `frontend/src/lib/components/shell/SettingsModal.svelte`, add the import at the top of the `<script>` (with the other imports):

```ts
	import RemoteAccessSection from '$lib/components/shell/RemoteAccessSection.svelte';
```

Then render it inside `<Dialog.Content>`, directly after the closing `</section>` of the Library section (before the harness-integrations `{#if}` block):

```svelte
		<RemoteAccessSection />
```

- [ ] **Step 5: Typecheck**

Run: `cd frontend && bun run check`
Expected: 0 errors (`@types/qrcode` resolves the `qrcode` import).

- [ ] **Step 6: Manual verification**

Run `just dev`, open `http://localhost:4173/`, open Settings (the gear / settings entry in the desktop shell).
Expected: a "Remote access" section. Entering a host + "Enable remote access" returns the enabled state and a "Restart Legend to apply" note. "Generate code" shows a QR + the code + expiry; the QR encodes `http://<host>:<port>/pair?code=…`. A paired device (pair one via the QR/`/pair`) appears under "Paired devices" with a two-step Revoke; revoking removes it and adds a `revoke` row under the audit trail.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/lib/remote/devices.ts frontend/src/lib/components/shell/RemoteAccessSection.svelte frontend/src/lib/components/shell/SettingsModal.svelte frontend/package.json 'frontend/bun.lock*'
git commit -m "feat(remote): Remote-access settings section (toggle, QR, devices, audit)

Desktop Settings-modal section: remote_access toggle with mesh host +
restart note, pairing-code generation rendered as a QR (.../pair?code=),
paired-device list with two-step revoke, and the read-only audit trail.
Adds the qrcode dependency.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Final verification (after all tasks)

- [ ] `cd backend && mix precommit` — green.
- [ ] `cd frontend && bun run check && bun run test` — green.
- [ ] **Live acceptance (spec §Testing, gated/manual):** on a real mesh, enable remote access on the laptop (set host, restart), generate a code, scan the QR from a phone, and **drive** a live session — submit a prompt, answer an ACP permission, switch rich/term, resume a stopped session. Confirm a revoked device's socket drops and it can't reconnect.

## Notes / deferred (carried from the spec, out of scope here)

- Deep-linking to a specific session on mobile (notification → that session) — mobile shows the list; selection is internal state.
- TLS / PWA install / Web Push (secure-context features) — deferred; mesh encrypts http.
- Per-session message composer on the terminal transport — terminal input is the xterm itself; rich is the mobile default.
- The phone's settings stay minimal (unpair-self); full device management is loopback-only by design.
