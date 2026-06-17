<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { watchSet } from '$lib/shell/watchset.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import type { Session } from '$lib/sessions';

	let searching = $state(false);
	let query = $state('');

	interface Row {
		session: Session;
		watching: boolean;
		state: ReturnType<typeof liveState>;
		unread: number;
	}

	const rows = $derived.by((): Row[] => {
		const q = query.trim().toLowerCase();
		return sessionsStore.sessions
			.filter((s) => !q || (s.name || s.harness_id).toLowerCase().includes(q))
			.map((s) => ({
				session: s,
				watching: watchSet.isWatching(s.id),
				state: liveState(s),
				unread: messagesStore.unreadCount(s.id)
			}));
	});

	interface Group {
		key: string;
		label: string;
		amber?: boolean;
		rows: Row[];
	}

	const groups = $derived.by((): Group[] => {
		const needs = rows.filter((r) => r.state.attention && !r.watching);
		// preserve grid order for the watching group
		const watching = watchSet.watching
			.map((id) => rows.find((r) => r.session.id === id))
			.filter((r): r is Row => !!r);
		const running = rows.filter(
			(r) => r.state.kind === 'running' && !r.state.attention && !r.watching
		);
		const idle = rows.filter(
			(r) => (r.state.kind === 'idle' || r.state.kind === 'done') && !r.state.attention && !r.watching
		);
		return [
			{ key: 'needs', label: 'Needs you', amber: true, rows: needs },
			{ key: 'watching', label: 'Watching', rows: watching },
			{ key: 'running', label: 'Running', rows: running },
			{ key: 'idle', label: 'Idle', rows: idle }
		].filter((g) => g.rows.length > 0);
	});
</script>

<aside class="flex w-[178px] shrink-0 flex-col border-r border-hair bg-shell">
	<!-- header -->
	<div class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair pl-3 pr-1.5">
		{#if searching}
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
		{:else}
			<span class="text-ui font-semibold text-ink-2">Sessions</span>
			<span class="font-mono text-meta text-ink-3">{sessionsStore.sessions.length}</span>
			<div class="flex-1"></div>
		{/if}
		<IconButton
			icon={searching ? 'close' : 'search'}
			size={13}
			title="Filter sessions"
			onclick={() => {
				searching = !searching;
				if (!searching) query = '';
			}}
		/>
	</div>

	<!-- groups -->
	<div class="flex min-h-0 flex-1 flex-col gap-2.5 overflow-y-auto py-2.5">
		{#each groups as group (group.key)}
			<div class="flex flex-col">
				<div class="flex items-center justify-between px-3 pb-1">
					<span
						class="font-mono text-micro font-semibold uppercase tracking-[0.14em]"
						style:color={group.amber ? 'var(--amber)' : 'var(--text-3)'}
					>
						{group.label}
					</span>
					<span class="font-mono text-micro text-ink-3">{group.rows.length}</span>
				</div>
				{#each group.rows as row (row.session.id)}
					{@render benchRow(row)}
				{/each}
			</div>
		{:else}
			<p class="px-3 text-meta text-ink-3">
				{sessionsStore.loaded ? 'No sessions match.' : 'Connecting…'}
			</p>
		{/each}
	</div>
</aside>

{#snippet benchRow(row: Row)}
	{@const surfaced = row.state.attention}
	<button
		type="button"
		onclick={() => watchSet.promote(row.session.id)}
		class="group/row relative flex h-[var(--h-row)] w-full items-center gap-2 pl-3 pr-2 text-left transition-colors hover:bg-[var(--hover-tint)]"
		style:background={row.watching ? 'var(--accent-soft)' : undefined}
		title={row.state.label}
	>
		<!-- left spine -->
		<span
			class="absolute left-0 top-0 h-full w-[2px]"
			style:background={row.watching ? 'var(--accent)' : surfaced ? 'var(--amber)' : 'transparent'}
		></span>

		<StatusDot color={row.state.dotColor} pulse={row.state.pulse} size={6} />

		<span
			class="min-w-0 flex-1 truncate text-ui"
			style:color={row.watching ? 'var(--text-1)' : 'var(--text-2)'}
			style:font-weight={row.watching ? 600 : 500}
		>
			{row.session.name || row.session.harness_id}
		</span>

		{#if row.unread > 0}
			<span
				class="grid h-[15px] min-w-[15px] shrink-0 place-items-center rounded-full px-1 text-micro font-bold leading-none text-white"
				style:background="var(--accent)"
			>
				{row.unread}
			</span>
		{/if}

		{#if row.state.flag}
			<span
				class="shrink-0 font-mono text-micro font-bold tracking-[0.06em]"
				style:color={row.state.flag === 'ERR' ? 'var(--red)' : 'var(--amber)'}
			>
				{row.state.flag}
			</span>
		{:else if !row.watching}
			<!-- hover-reveal promote affordance -->
			<Icon
				name="plus"
				size={12}
				class="shrink-0 text-ink-3 opacity-0 transition-opacity group-hover/row:opacity-100"
			/>
		{/if}
	</button>
{/snippet}
