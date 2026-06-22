<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { dockDrag } from '$lib/shell/dock-drag.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { relativeTime, mostRecentIso } from '$lib/shell/format';
	import type { Session } from '$lib/sessions';
	import { groupSessions } from '$lib/shell/sessionGroups';

	let { open, ontoggle }: { open: boolean; ontoggle: () => void } = $props();

	let searching = $state(false);
	let query = $state('');

	interface Row {
		session: Session;
		placed: boolean;
		state: ReturnType<typeof liveState>;
		identity: ReturnType<typeof identityFor>;
		unread: number;
		lastActive: string | undefined;
	}

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
</script>

<div class="flex h-full min-h-0 flex-col">
	<!-- title bar: chevron + icon + label + count + spacer + actions -->
	<div class="flex h-[var(--h-bar)] shrink-0 items-center gap-1.5 border-b border-hair pl-2 pr-1.5">
		<button
			type="button"
			onclick={ontoggle}
			class="flex min-w-0 flex-1 items-center gap-1.5 text-left"
			aria-expanded={open}
		>
			<Icon name={open ? 'chevron-down' : 'chevron-right'} size={12} class="shrink-0 text-ink-3" />
			<Icon name="sessions" size={13} class="shrink-0 text-ink-3" />
			<span class="text-ui font-semibold text-ink-2">Sessions</span>
			<span class="font-mono text-micro text-ink-3">{sessionsStore.sessions.length}</span>
		</button>
		<IconButton
			icon={searching ? 'close' : 'search'}
			size={13}
			title="Filter sessions"
			active={searching}
			onclick={() => {
				searching = !searching;
				if (!searching) query = '';
			}}
		/>
	</div>

	{#if open}
		{#if searching}
			<div class="flex h-[var(--h-row)] shrink-0 items-center border-b border-hair pl-3 pr-1.5">
				<!-- svelte-ignore a11y_autofocus -->
				<input
					autofocus
					bind:value={query}
					onblur={() => {
						if (!query) searching = false;
					}}
					placeholder="Filter…"
					class="min-w-0 flex-1 bg-transparent text-ui text-ink-1 placeholder:text-ink-3 focus:outline-none"
				/>
			</div>
		{/if}

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
	{/if}
</div>

{#snippet benchRow(row: Row)}
	{@const time = relativeTime(row.lastActive)}
	<button
		type="button"
		onclick={() =>
			workspaceStore.openSurface('session', {
				sessionId: row.session.id,
				name: row.session.name || row.session.harness_id
			})}
		onpointerdown={(e) =>
			dockDrag.start(e, {
				kind: 'session',
				params: { sessionId: row.session.id, name: row.session.name || row.session.harness_id },
				label: row.session.name || row.session.harness_id
			})}
		class="group/row flex h-[var(--h-row)] w-full items-center gap-2 pl-3 pr-2 text-left transition-colors hover:bg-[var(--hover-tint)]"
		style:background={row.placed ? 'var(--accent-soft)' : undefined}
		title={`${row.identity.label} · ${row.state.label}`}
	>
		<!-- placed = iris wash + bold weight; attention = dot color + flag. No side-stripe. -->
		<!-- state: the dot color/pulse IS the live-state indicator -->
		<StatusDot color={row.state.dotColor} pulse={row.state.pulse} size={6} />

		<span
			class="min-w-0 flex-1 truncate text-ui"
			style:color={row.placed ? 'var(--text-1)' : 'var(--text-2)'}
			style:font-weight={row.placed ? 600 : 500}
		>
			{row.session.name || row.session.harness_id}
		</span>

		{#if row.session.runtime_id !== 'local_pty'}
			<Icon name="cloud" size={11} class="shrink-0 text-ink-3" />
		{/if}

		<!-- harness kind -->
		<span
			class="shrink-0 font-mono text-micro font-bold tracking-[0.04em]"
			style:color="var({row.identity.colorVar})"
		>
			{row.identity.tag}
		</span>

		{#if row.unread > 0}
			<span
				class="grid h-[15px] min-w-[15px] shrink-0 place-items-center rounded-full px-1 text-micro font-bold leading-none"
				style:background="var(--accent)"
				style:color="var(--accent-contrast)"
			>
				{row.unread}
			</span>
		{/if}

		<!-- urgent flag (attention rows only) -->
		{#if row.state.flag}
			<span
				class="shrink-0 font-mono text-micro font-bold tracking-[0.06em]"
				style:color={row.state.flag === 'ERR' ? 'var(--red)' : 'var(--amber)'}
			>
				{row.state.flag}
			</span>
		{/if}

		<!-- last active -->
		{#if time}
			<span class="shrink-0 font-mono text-micro tabular-nums text-ink-3">{time}</span>
		{/if}
	</button>
{/snippet}
