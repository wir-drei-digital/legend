<script lang="ts">
	import TileGrid from '$lib/components/shell/TileGrid.svelte';
	import SessionPane from '$lib/components/sessions/SessionPane.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { shell } from '$lib/shell/shell.svelte';

	const byId = $derived(new Map(sessionsStore.sessions.map((s) => [s.id, s])));

	// Candidate order for auto-filling empty grid slots: attention → running → idle.
	const candidates = $derived.by(() => {
		const rank = (st: { attention: boolean; kind: string }) =>
			st.attention ? 0 : st.kind === 'running' ? 1 : 2;
		return [...sessionsStore.sessions]
			.map((s) => ({ s, st: liveState(s) }))
			.sort((a, b) => rank(a.st) - rank(b.st))
			.map((x) => x.s.id);
	});

	$effect(() => {
		sessionsLayout.reconcile(candidates);
	});

	function onKeydown(e: KeyboardEvent) {
		const el = e.target as HTMLElement | null;
		if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
		if (shell.spacesOpen) return;
		if (e.key === 'Escape') {
			sessionsLayout.restore();
			return;
		}
		const num = Number(e.key);
		if (num >= 1 && num <= 9) {
			const id = sessionsLayout.watching[num - 1];
			if (id) sessionsLayout.setActive(id);
		}
	}

	const label = (id: string) =>
		byId.get(id)?.name || byId.get(id)?.harness_id || 'session';
</script>

<svelte:window onkeydown={onKeydown} />

<TileGrid layout={sessionsLayout.layout} dragLabel={label}>
	{#snippet tile(id, grab)}
		{@const s = byId.get(id)}
		{#if s}
			<SessionPane session={s} {grab} />
		{/if}
	{/snippet}
	{#snippet empty()}
		<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
			<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3">
				<Icon name="sessions" size={22} />
			</div>
			{#if sessionsStore.sessions.length === 0}
				<p class="text-title text-ink-2">No sessions running.</p>
				<p class="max-w-[260px] text-ui text-ink-3">
					Use <span class="text-ink-2">New session</span> in the toolbar to launch an agent, or
					<kbd class="rounded border border-hair bg-inset px-1 font-mono text-meta">⌘K</kbd> to jump to another view.
				</p>
			{:else}
				<p class="text-title text-ink-2">No tiles in the grid.</p>
				<p class="max-w-[260px] text-ui text-ink-3">Promote a session from the bench on the left to watch it here.</p>
			{/if}
		</div>
	{/snippet}
</TileGrid>
