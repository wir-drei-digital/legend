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

		<!-- harness kind -->
		<span
			class="shrink-0 font-mono text-micro font-bold tracking-[0.04em]"
			style:color="var({row.identity.colorVar})"
		>
			{row.identity.tag}
		</span>

		{#if row.unread > 0}
			<span
				class="grid h-[15px] min-w-[15px] shrink-0 place-items-center rounded-full px-1 text-micro font-bold leading-none text-white"
				style:background="var(--accent)"
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
