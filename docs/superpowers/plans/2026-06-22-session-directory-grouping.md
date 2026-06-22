# Session grouping by working directory — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Group the session list into collapsible per-directory groups (key = `cwd`) and upgrade the create modal's working-directory field into a picker that steers sessions into coherent groups.

**Architecture:** Grouping is a pure client-side helper (`sessionGroups.ts`) over the existing session `Row` view-model — no new backend entity. The backend adds one runtime-aware `cwd` normalization step on `:start` so near-miss paths collapse into one group. The modal gains a typeahead over existing dirs, a non-blocking home-dir caution, and (final, isolated slice) a native folder picker via `tauri-plugin-dialog`.

**Tech Stack:** Elixir 1.20 / Ash 3 (backend); SvelteKit 2 / Svelte 5 runes / Tailwind v4 + shadcn-svelte (frontend); Tauri v2 (desktop); Vitest (frontend tests), ExUnit (backend tests).

**Spec:** `docs/superpowers/specs/2026-06-22-session-directory-grouping-design.md`

## Global Constraints

- **Branch:** work on `session-directory-grouping` (already created; the spec is committed there).
- **Frontend token discipline:** feature code uses Legend tokens only (`text-ink-*`, `bg-shell/app/panel`, `text-micro/ui/meta/title`, `border-hair`, `var(--amber)`, `var(--hover-tint)`) + shell primitives. No raw shadcn neutral classes, no ad-hoc hex, no ad-hoc `text-[Npx]`. shadcn semantic classes appear only in `src/lib/components/ui/`.
- **Frontend gates:** `cd frontend && bun run check` must report **0 errors / 0 warnings**; `bun run test` (vitest) green; `bun run build` succeeds.
- **Backend gate:** `cd backend && mix precommit` (compile --warnings-as-errors + format + test) before finishing backend work.
- **Commits:** conventional messages, frequent, each ending with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- **No SSR / no `window.confirm|alert|prompt`** (Tauri webview no-ops); guard Tauri-only code with `'__TAURI_INTERNALS__' in window`.

---

### Task 1: Backend — runtime-aware `cwd` normalization on `:start`

Normalize the working directory so grouping keys are stable: local paths get `~` expanded, `.`/`..` collapsed, and a trailing slash stripped; remote (sandbox) paths stay opaque (trailing-slash strip only — host-home expansion would be wrong for a sandbox).

**Files:**
- Modify: `backend/lib/legend/core/agents/session.ex` (add public `normalize_cwd/2` + private helpers near the other module functions ~line 304–329; add a `change` inside the `:start` action before the transport-default change ~line 64)
- Test: `backend/test/legend/core/agents/session_cwd_test.exs` (create)

**Interfaces:**
- Produces: `Legend.Core.Agents.Session.normalize_cwd(cwd :: String.t() | nil, runtime_id :: String.t() | nil) :: String.t() | nil`

- [ ] **Step 1: Write the failing test**

Create `backend/test/legend/core/agents/session_cwd_test.exs`:

```elixir
defmodule Legend.Core.Agents.SessionCwdTest do
  use ExUnit.Case, async: true

  alias Legend.Core.Agents.Session

  describe "normalize_cwd/2 — local runtime" do
    test "expands a leading ~/" do
      assert Session.normalize_cwd("~/proj", "local_pty") ==
               Path.join(System.user_home!(), "proj")
    end

    test "expands a bare ~" do
      assert Session.normalize_cwd("~", "local_pty") == System.user_home!()
    end

    test "strips a trailing slash" do
      assert Session.normalize_cwd("/Users/x/proj/", "local_pty") == "/Users/x/proj"
    end

    test "collapses . and .. in absolute paths" do
      assert Session.normalize_cwd("/a/b/../c", "local_pty") == "/a/c"
    end

    test "trims surrounding whitespace" do
      assert Session.normalize_cwd("  /a/b  ", "local_pty") == "/a/b"
    end
  end

  describe "normalize_cwd/2 — remote runtime" do
    test "keeps a sandbox path opaque, stripping only the trailing slash" do
      assert Session.normalize_cwd("/root/work/", "sprites") == "/root/work"
    end

    test "does not host-expand ~ for remote" do
      assert Session.normalize_cwd("~/work", "sprites") == "~/work"
    end
  end

  describe "normalize_cwd/2 — blank" do
    test "nil stays nil" do
      assert Session.normalize_cwd(nil, "local_pty") == nil
    end

    test "whitespace-only becomes nil" do
      assert Session.normalize_cwd("   ", "local_pty") == nil
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd backend && mix test test/legend/core/agents/session_cwd_test.exs`
Expected: FAIL — `function Legend.Core.Agents.Session.normalize_cwd/2 is undefined or private`.

- [ ] **Step 3: Implement `normalize_cwd/2` + helpers**

In `backend/lib/legend/core/agents/session.ex`, add near the other public helpers (just after `def default_cwd, do: System.user_home!()`):

```elixir
  @doc """
  Normalizes a session working directory so grouping keys are stable.

  Local runtime (`"local_pty"`): expands a leading `~`, absolutizes (collapsing
  `.`/`..`), and strips a trailing slash. Remote runtimes: treats the path as
  opaque — strips only a trailing slash; the path lives in a sandbox, not on this
  host, so host-home expansion would be wrong. Blank/`nil` → `nil` (the attribute
  default applies).
  """
  @spec normalize_cwd(String.t() | nil, String.t() | nil) :: String.t() | nil
  def normalize_cwd(nil, _runtime_id), do: nil

  def normalize_cwd(cwd, runtime_id) when is_binary(cwd) do
    case String.trim(cwd) do
      "" -> nil
      trimmed when runtime_id == "local_pty" -> trimmed |> expand_local() |> strip_trailing_slash()
      trimmed -> strip_trailing_slash(trimmed)
    end
  end

  defp expand_local("~"), do: System.user_home!()
  defp expand_local("~/" <> rest), do: System.user_home!() |> Path.join(rest) |> Path.expand()
  defp expand_local("/" <> _ = abs), do: Path.expand(abs)
  defp expand_local(other), do: other

  defp strip_trailing_slash("/"), do: "/"

  defp strip_trailing_slash(path) do
    case String.replace_trailing(path, "/", "") do
      "" -> "/"
      stripped -> stripped
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd backend && mix test test/legend/core/agents/session_cwd_test.exs`
Expected: PASS (9 tests).

- [ ] **Step 5: Wire normalization into the `:start` action**

In `backend/lib/legend/core/agents/session.ex`, inside `create :start do`, add this `change` immediately **before** the existing transport-default `change fn changeset, _context ->` block (i.e. right after the `validate string_length(:name, max: 120)` block):

```elixir
      # Normalize cwd up front so grouping keys are stable across sessions
      # ("~/p" and "/Users/x/p/" collapse to one). Runtime-aware — see
      # normalize_cwd/2 (remote sandbox paths stay opaque).
      change fn changeset, _context ->
        cwd = Ash.Changeset.get_attribute(changeset, :cwd)
        rid = Ash.Changeset.get_attribute(changeset, :runtime_id)

        case __MODULE__.normalize_cwd(cwd, rid) do
          nil -> changeset
          normalized -> Ash.Changeset.force_change_attribute(changeset, :cwd, normalized)
        end
      end
```

- [ ] **Step 6: Run precommit (compile/format/test)**

Run: `cd backend && mix precommit`
Expected: compiles with no warnings, formatted, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add backend/lib/legend/core/agents/session.ex backend/test/legend/core/agents/session_cwd_test.exs
git commit -m "$(printf 'feat(sessions): normalize cwd on :start for stable grouping keys\n\nRuntime-aware: local paths expand ~ + absolutize + strip trailing slash;\nremote sandbox paths stay opaque (trailing-slash strip only).\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 2: Frontend — `sessionGroups.ts` pure grouping helper + tests

The single chokepoint for the grouping rule. Pure (no runes/stores) so it's unit-testable; the list UI passes its existing `Row` view-model in and renders the returned groups.

**Files:**
- Create: `frontend/src/lib/shell/sessionGroups.ts`
- Test: `frontend/src/lib/shell/sessionGroups.test.ts`

**Interfaces:**
- Produces:
  - `groupKey(session: { cwd: string | null }): string`
  - `groupLabel(key: string, home?: string): string`
  - `groupSessions<T extends GroupableRow>(rows: T[]): Group<T>[]`
  - `interface GroupableRow { session: { cwd: string | null }; state: { attention: boolean; kind: string }; lastActive: string | undefined }`
  - `interface Group<T> { key: string; label: string; fullPath: string | null; rows: T[]; hasAttention: boolean; lastActive: number }`

- [ ] **Step 1: Write the failing tests**

Create `frontend/src/lib/shell/sessionGroups.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { groupKey, groupLabel, groupSessions, type GroupableRow } from './sessionGroups';

function row(
	cwd: string | null,
	opts: Partial<{ attention: boolean; kind: string; lastActive: string }> = {}
): GroupableRow {
	return {
		session: { cwd },
		state: { attention: opts.attention ?? false, kind: opts.kind ?? 'idle' },
		lastActive: opts.lastActive
	};
}

describe('groupKey', () => {
	it('uses the cwd as the key', () => {
		expect(groupKey({ cwd: '/Users/x/proj' })).toBe('/Users/x/proj');
	});
	it('maps null and blank to the same sentinel', () => {
		expect(groupKey({ cwd: null })).toBe(groupKey({ cwd: '   ' }));
	});
});

describe('groupLabel', () => {
	it('shows the basename', () => {
		expect(groupLabel('/Users/x/my-proj')).toBe('my-proj');
	});
	it('labels home when the home path is supplied', () => {
		expect(groupLabel('/Users/x', '/Users/x')).toBe('Home');
	});
	it('labels the no-directory bucket', () => {
		expect(groupLabel(groupKey({ cwd: null }))).toBe('No directory');
	});
});

describe('groupSessions', () => {
	it('buckets rows by directory', () => {
		const groups = groupSessions([row('/a'), row('/b'), row('/a')]);
		expect(groups.map((g) => g.key).sort()).toEqual(['/a', '/b']);
		expect(groups.find((g) => g.key === '/a')!.rows).toHaveLength(2);
	});

	it('orders attention groups first, then by recency', () => {
		const groups = groupSessions([
			row('/old', { lastActive: '2020-01-01T00:00:00Z' }),
			row('/recent', { lastActive: '2026-01-01T00:00:00Z' }),
			row('/urgent', { attention: true, lastActive: '2019-01-01T00:00:00Z' })
		]);
		expect(groups.map((g) => g.key)).toEqual(['/urgent', '/recent', '/old']);
	});

	it('sorts within a group: attention, then running, then idle', () => {
		const g = groupSessions([
			row('/a', { kind: 'idle', lastActive: '2026-01-03T00:00:00Z' }),
			row('/a', { kind: 'running', lastActive: '2026-01-02T00:00:00Z' }),
			row('/a', { attention: true, lastActive: '2026-01-01T00:00:00Z' })
		])[0];
		expect(g.rows.map((r) => (r.state.attention ? 'attn' : r.state.kind))).toEqual([
			'attn',
			'running',
			'idle'
		]);
	});

	it('sets fullPath null and the No directory label for the sentinel bucket', () => {
		const g = groupSessions([row(null)])[0];
		expect(g.fullPath).toBeNull();
		expect(g.label).toBe('No directory');
	});
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd frontend && bun run test src/lib/shell/sessionGroups.test.ts`
Expected: FAIL — cannot resolve `./sessionGroups`.

- [ ] **Step 3: Implement the helper**

Create `frontend/src/lib/shell/sessionGroups.ts`:

```ts
// Groups session rows by working directory for the session list. Pure (no runes,
// no stores) so it is unit-testable; `SessionsSource` passes its existing `Row`
// view-model in and renders the returned groups. The single place the
// "what is a project group" rule lives — a future workspace label or shared-
// sandbox id slots in behind groupKey/groupLabel without touching the list UI.

// Sentinel for sessions with no cwd (legacy rows predating the home default):
// keeps them in one deterministic bucket instead of one group each.
const NO_DIR = ' nodir';

export interface GroupableRow {
	session: { cwd: string | null };
	state: { attention: boolean; kind: string };
	lastActive: string | undefined;
}

export interface Group<T> {
	key: string;
	label: string;
	/** full path for the header tooltip; null for the no-directory bucket */
	fullPath: string | null;
	rows: T[];
	hasAttention: boolean;
	/** epoch ms of the most-recent row activity; 0 when none */
	lastActive: number;
}

export function groupKey(session: { cwd: string | null }): string {
	const c = session.cwd?.trim();
	return c ? c : NO_DIR;
}

export function groupLabel(key: string, home?: string): string {
	if (key === NO_DIR) return 'No directory';
	if (home && key === home) return 'Home';
	const seg = key.replace(/\/+$/, '').split('/').pop();
	return seg || key;
}

// Within-group order mirrors the old flat list: attention first, then running,
// then idle; recency breaks ties.
function rank(r: GroupableRow): number {
	return r.state.attention ? 0 : r.state.kind === 'running' ? 1 : 2;
}

function ms(iso: string | undefined): number {
	return iso ? new Date(iso).getTime() : 0;
}

export function groupSessions<T extends GroupableRow>(rows: T[]): Group<T>[] {
	const buckets = new Map<string, T[]>();
	for (const r of rows) {
		const k = groupKey(r.session);
		const list = buckets.get(k);
		if (list) list.push(r);
		else buckets.set(k, [r]);
	}

	const groups: Group<T>[] = [];
	for (const [key, list] of buckets) {
		list.sort((a, b) => rank(a) - rank(b) || ms(b.lastActive) - ms(a.lastActive));
		groups.push({
			key,
			label: groupLabel(key),
			fullPath: key === NO_DIR ? null : key,
			rows: list,
			hasAttention: list.some((r) => r.state.attention),
			lastActive: list.reduce((max, r) => Math.max(max, ms(r.lastActive)), 0)
		});
	}

	// Group order: any group needing attention first, then most-recently-active.
	groups.sort(
		(a, b) => Number(b.hasAttention) - Number(a.hasAttention) || b.lastActive - a.lastActive
	);
	return groups;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd frontend && bun run test src/lib/shell/sessionGroups.test.ts`
Expected: PASS (all describe blocks green).

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/shell/sessionGroups.ts frontend/src/lib/shell/sessionGroups.test.ts
git commit -m "$(printf 'feat(sessions): pure sessionGroups helper (group/label by cwd)\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 3: Frontend — grouped, collapsible session list

Render the session list as collapsible per-directory groups (header = folder name + count), with per-group open/closed persisted to localStorage, and a cloud glyph on remote rows.

**Files:**
- Modify: `frontend/src/lib/components/shell/sources/SessionsSource.svelte`

**Interfaces:**
- Consumes: `groupSessions` from `$lib/shell/sessionGroups` (Task 2); existing `rows` (`Row[]`), `Icon`, `benchRow` snippet.

- [ ] **Step 1: Add the import, group state, and derived groups**

In `SessionsSource.svelte`, after the existing imports (the `import type { Session }` line), add:

```ts
	import { groupSessions } from '$lib/shell/sessionGroups';
```

Then, immediately after the `const rows = $derived.by(...)` block (closing at the line `	});`), add:

```ts
	const groups = $derived(groupSessions(rows));

	// Per-directory collapse state (default open). Separate localStorage namespace
	// from the Dock's per-source `legend:dock`.
	const GROUPS_KEY = 'legend:sessions:groups';
	let groupOpen = $state<Record<string, boolean>>(loadGroupOpen());

	function loadGroupOpen(): Record<string, boolean> {
		try {
			return JSON.parse(localStorage.getItem(GROUPS_KEY) || '{}');
		} catch {
			return {};
		}
	}

	const isGroupOpen = (key: string) => groupOpen[key] !== false;

	function toggleGroup(key: string) {
		groupOpen[key] = !isGroupOpen(key);
		try {
			localStorage.setItem(GROUPS_KEY, JSON.stringify(groupOpen));
		} catch {
			/* localStorage unavailable — non-fatal */
		}
	}
```

- [ ] **Step 2: Drop the now-redundant flat sort + `rank` from `rows`**

Ordering (within and across groups) now lives entirely in `groupSessions`, so the old flat sort and its `rank` helper in `SessionsSource.svelte` become dead, duplicated logic. Remove them. Replace this block (the `rank` comment + const + the `rows` derived, ~lines 28–61):

```ts
	// One flat list. The row's status dot encodes the live state (needs you /
	// running / idle); the harness tag + last-active time ride along on the right.
	// Sort: attention first, then running, then idle — recency breaks ties.
	const rank = (r: Row) => (r.state.attention ? 0 : r.state.kind === 'running' ? 1 : 2);

	const rows = $derived.by((): Row[] => {
		const q = query.trim().toLowerCase();
		const list = sessionsStore.sessions
			.filter((s) => !q || (s.name || s.harness_id).toLowerCase().includes(q))
			.map((s): Row => {
				const thread = messagesStore.forSession(s.id);
				return {
					session: s,
					placed: workspaceStore.isSessionVisible(s.id),
					state: liveState(s),
					identity: identityFor(s.harness_id),
					unread: messagesStore.unreadCount(s.id),
					lastActive: mostRecentIso(
						thread[thread.length - 1]?.inserted_at,
						s.ended_at,
						s.started_at,
						s.updated_at,
						s.inserted_at
					)
				};
			});
		return list.sort((a, b) => {
			const d = rank(a) - rank(b);
			if (d) return d;
			const ta = a.lastActive ? new Date(a.lastActive).getTime() : 0;
			const tb = b.lastActive ? new Date(b.lastActive).getTime() : 0;
			return tb - ta;
		});
	});
```

with (build the rows unsorted; `groupSessions` owns ordering):

```ts
	// Rows for the list; all ordering (within and across groups) lives in groupSessions.
	const rows = $derived.by((): Row[] =>
		sessionsStore.sessions
			.filter((s) => {
				const q = query.trim().toLowerCase();
				return !q || (s.name || s.harness_id).toLowerCase().includes(q);
			})
			.map((s): Row => {
				const thread = messagesStore.forSession(s.id);
				return {
					session: s,
					placed: workspaceStore.isSessionVisible(s.id),
					state: liveState(s),
					identity: identityFor(s.harness_id),
					unread: messagesStore.unreadCount(s.id),
					lastActive: mostRecentIso(
						thread[thread.length - 1]?.inserted_at,
						s.ended_at,
						s.started_at,
						s.updated_at,
						s.inserted_at
					)
				};
			})
	);
```

- [ ] **Step 3: Replace the flat list render with grouped render**

Replace this block (the `<!-- single list -->` div, ~lines 106–115):

```svelte
		<!-- single list -->
		<div class="flex min-h-0 flex-1 flex-col overflow-y-auto py-1.5">
			{#each rows as row (row.session.id)}
				{@render benchRow(row)}
			{:else}
				<p class="px-3 text-meta text-ink-3">
					{sessionsStore.loaded ? 'No sessions match.' : 'Connecting…'}
				</p>
			{/each}
		</div>
```

with:

```svelte
		<!-- grouped by working directory -->
		<div class="flex min-h-0 flex-1 flex-col overflow-y-auto py-1">
			{#each groups as group (group.key)}
				<div class="flex flex-col">
					<button
						type="button"
						onclick={() => toggleGroup(group.key)}
						class="flex h-[var(--h-row)] w-full items-center gap-1.5 pl-2 pr-2 text-left text-ink-3 transition-colors hover:bg-[var(--hover-tint)]"
						title={group.fullPath ?? undefined}
						aria-expanded={isGroupOpen(group.key)}
					>
						<Icon
							name={isGroupOpen(group.key) ? 'chevron-down' : 'chevron-right'}
							size={11}
							class="shrink-0"
						/>
						<Icon name="folder" size={12} class="shrink-0" />
						<span class="min-w-0 flex-1 truncate text-micro font-semibold uppercase tracking-[0.08em]">
							{group.label}
						</span>
						<span class="shrink-0 font-mono text-micro tabular-nums">{group.rows.length}</span>
					</button>
					{#if isGroupOpen(group.key)}
						{#each group.rows as row (row.session.id)}
							{@render benchRow(row)}
						{/each}
					{/if}
				</div>
			{:else}
				<p class="px-3 py-1.5 text-meta text-ink-3">
					{sessionsStore.loaded ? 'No sessions match.' : 'Connecting…'}
				</p>
			{/each}
		</div>
```

- [ ] **Step 4: Add the remote cloud glyph to `benchRow`**

In the `{#snippet benchRow(row: Row)}` block, immediately **before** the `<!-- harness kind -->` span, add:

```svelte
		{#if row.session.runtime_id !== 'local_pty'}
			<Icon name="cloud" size={11} class="shrink-0 text-ink-3" />
		{/if}
```

- [ ] **Step 5: Verify check passes**

Run: `cd frontend && bun run check`
Expected: 0 errors, 0 warnings.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/components/shell/sources/SessionsSource.svelte
git commit -m "$(printf 'feat(sessions): group the session list by working directory\n\nCollapsible per-directory groups (header = folder name + count, persisted\nopen state); cloud glyph on remote rows.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 4: Frontend — modal directory picker (typeahead + home caution)

Make the create modal's working-directory field a picker: a typeahead list of existing project directories (so picking the same folder is trivial and groups cohere) plus a non-blocking caution when the field is empty on a local runtime (would fall back to `~`). The native Browse button is added separately in Task 5.

**Files:**
- Modify: `frontend/src/lib/components/NewSessionDialog.svelte`

**Interfaces:**
- Consumes: `sessionsStore` from `$lib/stores/sessions.svelte`; `Icon` from `$lib/components/shell/Icon.svelte`; existing `cwd` state, `selectedRuntime` derived.

- [ ] **Step 1: Add imports and derived values**

In `NewSessionDialog.svelte`, add to the imports:

```ts
	import Icon from '$lib/components/shell/Icon.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
```

After the existing `const selectedRuntime = $derived(...)` line, add:

```ts
	// Existing project dirs, distinct, filtered by what's typed — picking one
	// makes the new session join that directory's group instead of a near-miss.
	const dirSuggestions = $derived.by(() => {
		const typed = cwd.trim().toLowerCase();
		const seen = new Set<string>();
		const out: string[] = [];
		for (const s of sessionsStore.sessions) {
			const d = s.cwd?.trim();
			if (!d || seen.has(d)) continue;
			seen.add(d);
			if (!typed || d.toLowerCase().includes(typed)) out.push(d);
		}
		return out.slice(0, 6);
	});

	const localRuntime = $derived(!selectedRuntime || selectedRuntime.id === 'local_pty');
	// Empty dir on a local runtime falls back to the home dir — the footgun we nudge against.
	const cautionHome = $derived(localRuntime && cwd.trim() === '');
```

- [ ] **Step 2: Replace the working-directory field markup**

Replace this block (~lines 234–244):

```svelte
			<div class="flex flex-col gap-2">
				<SectionLabel><label for="cwd">Working directory</label></SectionLabel>
				<Input
					id="cwd"
					bind:value={cwd}
					placeholder={selectedRuntime && selectedRuntime.id !== 'local_pty'
						? 'sprite working directory (e.g. /root)'
						: 'defaults to your home directory'}
				/>
			</div>
```

with:

```svelte
			<div class="flex flex-col gap-2">
				<SectionLabel><label for="cwd">Working directory</label></SectionLabel>
				<Input
					id="cwd"
					bind:value={cwd}
					placeholder={localRuntime
						? 'pick or type a project folder'
						: 'sprite working directory (e.g. /root)'}
				/>

				{#if dirSuggestions.length}
					<div class="flex flex-col overflow-hidden rounded-md border border-hair">
						{#each dirSuggestions as dir (dir)}
							<button
								type="button"
								onclick={() => (cwd = dir)}
								class="flex items-center gap-1.5 px-2 py-1 text-left transition-colors hover:bg-[var(--hover-tint)]"
							>
								<Icon name="folder" size={12} class="shrink-0 text-ink-3" />
								<span class="shrink-0 text-ui text-ink-2">
									{dir.replace(/\/+$/, '').split('/').pop()}
								</span>
								<span class="min-w-0 flex-1 truncate text-meta text-ink-3">{dir}</span>
							</button>
						{/each}
					</div>
				{/if}

				{#if cautionHome}
					<p class="text-meta" style:color="var(--amber)">
						Agents here can read everything in your home folder. Pick or create a project folder.
					</p>
				{/if}
			</div>
```

- [ ] **Step 3: Verify check passes**

Run: `cd frontend && bun run check`
Expected: 0 errors, 0 warnings.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/components/NewSessionDialog.svelte
git commit -m "$(printf 'feat(sessions): directory picker in the new-session modal\n\nTypeahead over existing project dirs + non-blocking home-dir caution when\nan empty cwd would fall back to ~ on a local runtime.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 5: Desktop — native folder picker (`tauri-plugin-dialog`) + Browse button

Final, isolated slice: add the dialog plugin and a desktop-only "Browse…" button that opens the native macOS folder picker (its built-in "New Folder" is the create-a-workdir path). Cut this task and the picker still works (typeahead + free text).

**Files:**
- Modify: `desktop/src-tauri/Cargo.toml`
- Modify: `desktop/src-tauri/src/main.rs`
- Modify: `desktop/src-tauri/capabilities/default.json`
- Modify: `frontend/package.json` (via `bun add`)
- Modify: `frontend/src/lib/components/NewSessionDialog.svelte`

**Interfaces:**
- Consumes: Task 4's working-directory field (adds the Browse button beside the `Input`).

- [ ] **Step 1: Add the Rust plugin dependency**

In `desktop/src-tauri/Cargo.toml`, under `[dependencies]`, add after the `tauri-plugin-shell = "2"` line:

```toml
tauri-plugin-dialog = "2"
```

- [ ] **Step 2: Register the plugin**

In `desktop/src-tauri/src/main.rs`, add the dialog plugin right after the shell plugin line:

```rust
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
```

- [ ] **Step 3: Grant the capability**

In `desktop/src-tauri/capabilities/default.json`, add `"dialog:allow-open"` to the `permissions` array (after `"core:window:allow-start-dragging"`):

```json
		"core:default",
		"core:window:allow-start-dragging",
		"dialog:allow-open",
```

- [ ] **Step 4: Add the JS plugin dependency**

Run: `cd frontend && bun add @tauri-apps/plugin-dialog`
Expected: adds `@tauri-apps/plugin-dialog` to `frontend/package.json` dependencies.

- [ ] **Step 5: Add the Browse button + handler**

In `NewSessionDialog.svelte`, add to the script (after the `cautionHome` derived from Task 4):

```ts
	const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

	async function browseDir() {
		// Dynamic import: the web build never loads the Tauri-only plugin.
		const { open } = await import('@tauri-apps/plugin-dialog');
		const picked = await open({ directory: true, multiple: false });
		if (typeof picked === 'string') cwd = picked;
	}
```

Then wrap the `Input` from Task 4 so the Browse button sits beside it. Replace:

```svelte
				<Input
					id="cwd"
					bind:value={cwd}
					placeholder={localRuntime
						? 'pick or type a project folder'
						: 'sprite working directory (e.g. /root)'}
				/>
```

with:

```svelte
				<div class="flex items-center gap-2">
					<Input
						id="cwd"
						bind:value={cwd}
						class="flex-1"
						placeholder={localRuntime
							? 'pick or type a project folder'
							: 'sprite working directory (e.g. /root)'}
					/>
					{#if isTauri && localRuntime}
						<Button variant="outline" size="sm" onclick={browseDir}>Browse…</Button>
					{/if}
				</div>
```

(`Button` is already imported in this file.)

- [ ] **Step 6: Verify frontend check + build**

Run: `cd frontend && bun run check && bun run build`
Expected: 0 errors; build succeeds (the dynamic import resolves; web bundle never loads it).

- [ ] **Step 7: Verify the desktop crate compiles**

Run: `cd desktop/src-tauri && cargo check`
Expected: compiles. (If this is a fresh clone with no sidecar binary, `tauri-build` fails validating `externalBin` — run `just package-backend` once first, per CLAUDE.md.)

- [ ] **Step 8: Commit**

```bash
git add desktop/src-tauri/Cargo.toml desktop/src-tauri/Cargo.lock desktop/src-tauri/src/main.rs desktop/src-tauri/capabilities/default.json frontend/package.json frontend/bun.lock frontend/src/lib/components/NewSessionDialog.svelte
git commit -m "$(printf 'feat(sessions): native folder picker (Browse) on desktop\n\ntauri-plugin-dialog + desktop-only Browse button; macOS picker New Folder\ncovers creating a workdir.\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

### Task 6: Documentation

Record the new grouping in the canonical docs (required by the spec).

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/DESIGN_SYSTEM.md`

- [ ] **Step 1: Update ARCHITECTURE.md**

Find the frontend section that describes the session list / source dock (search for `SessionsSource` or "Dock"). Add a short subsection:

```markdown
### Session grouping by working directory

The session list groups sessions by their `cwd`. `frontend/src/lib/shell/sessionGroups.ts`
is the single chokepoint — `groupKey`/`groupLabel`/`groupSessions` (pure, unit-tested)
bucket the existing `Row` view-model; `SessionsSource.svelte` renders collapsible
per-directory groups (per-group open state in `localStorage` key
`legend:sessions:groups`, distinct from the Dock's `legend:dock`). Group order:
attention-first, then most-recently-active. Backend `Session.:start` normalizes
`cwd` (runtime-aware: local expands `~` + absolutizes + strips trailing slash;
remote sandbox paths stay opaque) so near-miss paths collapse into one group.

Deferred (extension points behind the same helper): a first-class Project/Workspace
entity, an optional `workspace` label that defaults to the folder basename, and
sprite-based remote grouping (today each Sprites session is its own sprite, so
there is nothing to group by). Remote sessions group by `cwd` with a cloud marker.
```

- [ ] **Step 2: Update DESIGN_SYSTEM.md**

Find the Dock / session list area (search for "Dock" or "SessionsSource"). Add:

```markdown
**In-list group headers** — a second-level collapse *inside* a Dock source (the
session list groups by working directory). The header is a `--h-row` button:
chevron + `folder` icon + uppercase `text-micro` label (`tracking-[0.08em]`,
`text-ink-3`) + a `font-mono text-micro` count, with the full path as the `title`.
Remote rows carry a `cloud` glyph before the harness tag.
```

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md docs/DESIGN_SYSTEM.md
git commit -m "$(printf 'docs: session grouping by working directory\n\nCo-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>')"
```

---

## Final verification (after all tasks)

- [ ] `cd backend && mix precommit` — green.
- [ ] `cd frontend && bun run check` (0/0), `bun run test`, `bun run build` — all green.
- [ ] **Live (CDP) click-through** (`just dev`, drive Chrome over CDP per the user's live-verification preference):
  - Create two sessions in dir A and one in dir B → two groups with correct labels + counts.
  - Collapse a group → state persists across reload.
  - Start a session in a new dir → a new group appears, ordered by recency; an attention session floats its group to the top.
  - A remote (sprites) session shows the cloud glyph.
  - Filter narrows groups and hides empty ones.
  - In the modal: typing filters the suggestion list; clicking a suggestion fills the field; leaving the dir empty on a local runtime shows the amber caution while **Start stays enabled**; on desktop, Browse opens the native picker and sets the field.

## Notes / accepted simplifications

- **"Home" label not wired:** `groupLabel` accepts an optional `home` path but the
  frontend doesn't currently know the backend's home dir, so the home bucket shows
  the basename (e.g. the username). Wiring a real "Home" label is a trivial future
  step if the backend surfaces its home dir; not worth the plumbing now.
- **Caution trigger is "empty cwd + local runtime"** (the silent-`~`-fallback
  case) — it deliberately does not try to detect a *typed* home path, which would
  require knowing the home dir.
