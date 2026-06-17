<script lang="ts">
	import Icon, { type IconName } from './Icon.svelte';
	import Surface from './Surface.svelte';
	import SectionLabel from './SectionLabel.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { workspaceStore, type Space } from '$lib/shell/workspace.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';

	let query = $state('');
	let input = $state<HTMLInputElement | null>(null);

	// Inline-rename state for custom spaces.
	let renamingId = $state<string | null>(null);
	let renameValue = $state('');
	// Two-step delete: which custom space is currently armed for deletion.
	let armedDeleteId = $state<string | null>(null);

	const q = $derived(query.trim().toLowerCase());
	const matchText = (s: string) => !q || s.toLowerCase().includes(q);

	const isCustom = (s: Space) => !s.auto && s.id !== 'library';

	const spaces = $derived(workspaceStore.spaces.filter((s) => matchText(s.name)));
	const sessions = $derived(sessionsStore.sessions.filter((s) => matchText(s.name || s.harness_id)));

	// Static "Open" rows — filtered by label like everything else.
	interface OpenRow {
		id: string;
		label: string;
		icon: IconName;
		run: () => void;
	}
	const openRows: OpenRow[] = [
		{ id: 'new-session', label: 'New session', icon: 'plus', run: () => shell.openNewSession() },
		{
			id: 'open-file',
			label: 'Open file',
			icon: 'folder',
			run: () => {
				workspaceStore.switchSpace('library');
				shell.closeSpaces();
			}
		},
		{
			id: 'messages',
			label: 'Messages',
			icon: 'message',
			run: () => {
				workspaceStore.openSurface('messages', {});
				shell.closeSpaces();
			}
		}
	];
	const openRowsFiltered = $derived(openRows.filter((r) => matchText(r.label)));

	const settingsVisible = $derived(matchText('Settings'));

	// Autofocus the search/command row when the launcher opens (⌘K lands here).
	$effect(() => {
		if (input) input.focus();
	});

	function chooseSpace(s: Space) {
		workspaceStore.switchSpace(s.id);
		shell.closeSpaces();
	}

	// Custom spaces support double-click rename, so a single click must wait long
	// enough to know a second click isn't coming before it switches+closes.
	let clickTimer: ReturnType<typeof setTimeout> | null = null;
	function rowClick(s: Space) {
		if (renamingId === s.id) return;
		if (!isCustom(s)) {
			chooseSpace(s);
			return;
		}
		if (clickTimer) clearTimeout(clickTimer);
		clickTimer = setTimeout(() => {
			clickTimer = null;
			chooseSpace(s);
		}, 220);
	}
	function rowDblClick(s: Space) {
		if (clickTimer) {
			clearTimeout(clickTimer);
			clickTimer = null;
		}
		startRename(s);
	}

	function newSpace() {
		workspaceStore.createSpace();
		shell.closeSpaces();
	}

	function openSession(s: { id: string; name: string | null; harness_id: string }) {
		workspaceStore.openSurface('session', { sessionId: s.id, name: s.name || s.harness_id });
		shell.closeSpaces();
	}

	// ---- inline rename ----------------------------------------------------
	function startRename(s: Space) {
		if (!isCustom(s)) return;
		renamingId = s.id;
		renameValue = s.name;
		armedDeleteId = null;
	}
	function commitRename() {
		if (renamingId) {
			const name = renameValue.trim();
			if (name) workspaceStore.renameSpace(renamingId, name);
		}
		renamingId = null;
	}
	function cancelRename() {
		renamingId = null;
	}

	// ---- two-step delete --------------------------------------------------
	function armDelete(id: string) {
		armedDeleteId = id;
	}
	function confirmDelete(id: string) {
		workspaceStore.deleteSpace(id);
		armedDeleteId = null;
	}

	function onKeydown(e: KeyboardEvent) {
		if (e.key === 'Escape') {
			e.preventDefault();
			shell.closeSpaces();
		}
	}
</script>

<!-- backdrop: click-away closes -->
<div class="absolute inset-0 z-40" role="presentation" onclick={() => shell.closeSpaces()}></div>

<div
	class="absolute left-3.5 top-[50px] z-50 w-[296px]"
	style:animation="lg-rise 0.13s ease-out"
	role="dialog"
	aria-label="Launcher"
>
	<Surface elevation="overlay" class="w-full rounded-[14px]">
		<!-- search / command row -->
		<div class="flex h-10 items-center gap-2 border-b border-hair px-3">
			<Icon name="search" size={14} class="shrink-0 text-ink-3" />
			<input
				bind:this={input}
				bind:value={query}
				onkeydown={onKeydown}
				placeholder="Switch space, open a surface…"
				class="min-w-0 flex-1 bg-transparent text-body text-ink-1 placeholder:text-ink-3 focus:outline-none"
			/>
			<kbd
				class="shrink-0 rounded-[5px] border border-hair bg-inset px-1.5 py-0.5 font-mono text-micro text-ink-3"
				>⌘K</kbd
			>
		</div>

		<div class="max-h-[60vh] overflow-y-auto py-1.5">
			<!-- Spaces ------------------------------------------------------- -->
			{#if spaces.length}
				<SectionLabel class="block px-3 pb-1 pt-1.5 tracking-[0.12em]">Spaces</SectionLabel>
				{#each spaces as s (s.id)}
					{@render spaceRow(s)}
				{/each}
			{/if}
			{#if !q}
				{@render actionRow('new-space', 'plus', '+ New space', newSpace)}
			{/if}

			<!-- Open --------------------------------------------------------- -->
			{#if openRowsFiltered.length || sessions.length}
				<SectionLabel class="block px-3 pb-1 pt-2.5 tracking-[0.12em]">Open</SectionLabel>
				{#each openRowsFiltered as r (r.id)}
					{@render actionRow(r.id, r.icon, r.label, r.run)}
				{/each}
				{#if sessions.length}
					<SectionLabel class="block px-3 pb-1 pt-2 tracking-[0.12em] text-ink-3"
						>Running sessions</SectionLabel
					>
					{#each sessions as s (s.id)}
						{@render sessionRow(s)}
					{/each}
				{/if}
			{/if}

			<!-- Settings ----------------------------------------------------- -->
			{#if settingsVisible}
				<SectionLabel class="block px-3 pb-1 pt-2.5 tracking-[0.12em]">Settings</SectionLabel>
				{@render actionRow('settings', 'gear', 'Settings', () => shell.openSettings())}
			{/if}

			{#if !spaces.length && !openRowsFiltered.length && !sessions.length && !settingsVisible}
				<p class="px-3 py-3 text-body text-ink-3">No matches for "{query}".</p>
			{/if}
		</div>
	</Surface>
</div>

{#snippet spaceRow(s: Space)}
	{@const active = s.id === workspaceStore.activeId}
	{@const custom = isCustom(s)}
	<div
		class="group/row mx-1.5 flex items-center gap-2.5 rounded-[9px] px-2 py-[7px] transition-colors hover:bg-[var(--hover-tint)]"
		class:cursor-pointer={renamingId !== s.id}
		style:background={active ? 'var(--accent-soft)' : undefined}
		role="button"
		tabindex="0"
		title={custom ? 'Double-click to rename' : undefined}
		onclick={() => rowClick(s)}
		ondblclick={() => custom && rowDblClick(s)}
		onkeydown={(e) => e.key === 'Enter' && renamingId !== s.id && chooseSpace(s)}
	>
		<Icon name="grid" size={15} class={active ? 'text-brand-hi' : 'text-ink-2'} />
		{#if renamingId === s.id}
			<!-- svelte-ignore a11y_autofocus -->
			<input
				autofocus
				bind:value={renameValue}
				onclick={(e) => e.stopPropagation()}
				onblur={commitRename}
				onkeydown={(e) => {
					e.stopPropagation();
					if (e.key === 'Enter') commitRename();
					else if (e.key === 'Escape') cancelRename();
				}}
				class="min-w-0 flex-1 rounded-[5px] border border-hair bg-inset px-1.5 py-0.5 text-body text-ink-1 focus:outline-none"
			/>
		{:else}
			<span class="flex-1 truncate text-body {active ? 'font-semibold text-ink-1' : 'text-ink-2'}">
				{s.name}
			</span>
			{#if custom}
				{#if armedDeleteId === s.id}
					<button
						type="button"
						title="Confirm delete"
						onclick={(e) => {
							e.stopPropagation();
							confirmDelete(s.id);
						}}
						class="shrink-0 rounded p-0.5 text-bad"
					>
						<Icon name="trash" size={13} />
					</button>
				{:else}
					<button
						type="button"
						title="Delete space"
						onclick={(e) => {
							e.stopPropagation();
							armDelete(s.id);
						}}
						class="shrink-0 rounded p-0.5 text-ink-3 opacity-0 transition-opacity hover:text-bad group-hover/row:opacity-100"
					>
						<Icon name="trash" size={13} />
					</button>
				{/if}
			{/if}
		{/if}
	</div>
{/snippet}

{#snippet actionRow(id: string, icon: IconName, label: string, run: () => void)}
	<div
		class="group/row mx-1.5 flex cursor-pointer items-center gap-2.5 rounded-[9px] px-2 py-[7px] transition-colors hover:bg-[var(--hover-tint)]"
		role="button"
		tabindex="0"
		data-row-id={id}
		onclick={run}
		onkeydown={(e) => e.key === 'Enter' && run()}
	>
		<Icon name={icon} size={15} class="text-ink-2" />
		<span class="flex-1 truncate text-body text-ink-2">{label}</span>
	</div>
{/snippet}

{#snippet sessionRow(s: { id: string; name: string | null; harness_id: string })}
	<div
		class="group/row mx-1.5 flex cursor-pointer items-center gap-2.5 rounded-[9px] px-2 py-[7px] transition-colors hover:bg-[var(--hover-tint)]"
		role="button"
		tabindex="0"
		onclick={() => openSession(s)}
		onkeydown={(e) => e.key === 'Enter' && openSession(s)}
	>
		<Icon name="sessions" size={15} class="text-ink-2" />
		<span class="flex-1 truncate text-body text-ink-2">{s.name || s.harness_id}</span>
		{#if s.name}
			<span class="shrink-0 font-mono text-micro text-ink-3">{s.harness_id}</span>
		{/if}
	</div>
{/snippet}
