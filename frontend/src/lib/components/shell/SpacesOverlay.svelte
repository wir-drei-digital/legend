<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import Icon from './Icon.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { VIEWS, viewById, sectionForPath, type ViewDef } from '$lib/shell/views';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';

	let query = $state('');
	let input = $state<HTMLInputElement | null>(null);

	const section = $derived(sectionForPath(page.url.pathname));

	function countFor(id: string): number | undefined {
		if (id === 'sessions') return sessionsStore.sessions.length || undefined;
		if (id === 'messages') {
			const n = messagesStore.messages.filter((m) => !m.read_at).length;
			return n || undefined;
		}
		return undefined;
	}

	const q = $derived(query.trim().toLowerCase());
	const match = (v: ViewDef) => !q || v.label.toLowerCase().includes(q);

	const pinned = $derived(
		shell.pinned.map((id) => viewById(id)).filter((v): v is ViewDef => !!v && match(v))
	);
	const others = $derived(VIEWS.filter((v) => !shell.isPinned(v.id) && match(v)));

	// Autofocus the search/command row when the overlay opens (⌘K lands here).
	$effect(() => {
		if (input) input.focus();
	});

	function choose(v: ViewDef) {
		if (v.soon || !v.href) return;
		shell.closeSpaces();
		void goto(v.href);
	}

	function onKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.preventDefault();
			shell.closeSpaces();
		} else if (e.key === 'Enter') {
			const first = pinned[0] ?? others[0];
			if (first) choose(first);
		}
	}
</script>

<!-- backdrop: click-away closes -->
<div
	class="absolute inset-0 z-40"
	role="presentation"
	onclick={() => shell.closeSpaces()}
></div>

<div
	class="absolute left-3.5 top-[50px] z-50 w-[296px] overflow-hidden rounded-[14px] border border-hair-strong bg-panel shadow-[0_24px_60px_-12px_rgba(0,0,0,0.7)]"
	style:animation="lg-rise 0.13s ease-out"
	role="dialog"
	aria-label="Spaces"
>
	<!-- search / command row -->
	<div class="flex h-10 items-center gap-2 border-b border-hair px-3">
		<Icon name="search" size={14} class="shrink-0 text-ink-3" />
		<input
			bind:this={input}
			bind:value={query}
			onkeydown={onKeydown}
			placeholder="Jump to a view or run a command…"
			class="min-w-0 flex-1 bg-transparent text-[12.5px] text-ink-1 placeholder:text-ink-3 focus:outline-none"
		/>
		<kbd class="shrink-0 rounded-[5px] border border-hair bg-inset px-1.5 py-0.5 font-mono text-[9.5px] text-ink-3">⌘K</kbd>
	</div>

	<div class="max-h-[60vh] overflow-y-auto py-1.5">
		{#if pinned.length}
			<p class="px-3 pb-1 pt-1.5 font-mono text-[9px] uppercase tracking-[0.12em] text-ink-3">Pinned</p>
			{#each pinned as v (v.id)}
				{@render row(v)}
			{/each}
		{/if}

		{#if others.length}
			<p class="px-3 pb-1 pt-2.5 font-mono text-[9px] uppercase tracking-[0.12em] text-ink-3">All views</p>
			{#each others as v (v.id)}
				{@render row(v)}
			{/each}
		{/if}

		{#if !pinned.length && !others.length}
			<p class="px-3 py-3 text-[12px] text-ink-3">No views match "{query}".</p>
		{/if}
	</div>
</div>

{#snippet row(v: ViewDef)}
	{@const active = v.id === section}
	{@const count = countFor(v.id)}
	<div
		class="group/row mx-1.5 flex items-center gap-2.5 rounded-[9px] px-2 py-[7px] transition-colors hover:bg-[var(--hover-tint)]"
		class:cursor-pointer={!v.soon}
		style:background={active ? 'var(--accent-soft)' : undefined}
		role="button"
		tabindex="0"
		onclick={() => choose(v)}
		onkeydown={(e) => e.key === 'Enter' && choose(v)}
	>
		<Icon
			name={v.icon}
			size={15}
			class={active ? 'text-brand-hi' : 'text-ink-2'}
		/>
		<span class="flex-1 truncate text-[12.5px] {active ? 'font-semibold text-ink-1' : 'text-ink-2'}">
			{v.label}
		</span>
		{#if v.soon}
			<span class="font-mono text-[9px] uppercase tracking-[0.1em] text-ink-3">soon</span>
		{:else if count}
			<span class="font-mono text-[10.5px] text-ink-3">{count}</span>
		{/if}
		<button
			type="button"
			title={shell.isPinned(v.id) ? 'Unpin' : 'Pin'}
			onclick={(e) => {
				e.stopPropagation();
				shell.togglePin(v.id);
			}}
			class="shrink-0 rounded p-0.5 opacity-0 transition-opacity group-hover/row:opacity-100
				{shell.isPinned(v.id) ? '!opacity-100' : ''}"
		>
			<Icon
				name="star"
				size={13}
				fill={shell.isPinned(v.id)}
				class={shell.isPinned(v.id) ? 'text-brand-hi' : 'text-ink-3'}
			/>
		</button>
	</div>
{/snippet}
