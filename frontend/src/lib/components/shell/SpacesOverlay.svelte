<script lang="ts">
	import Icon, { type IconName } from './Icon.svelte';
	import Surface from './Surface.svelte';
	import SectionLabel from './SectionLabel.svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import { workspaceStore, type Space } from '$lib/shell/workspace.svelte';

	let query = $state('');
	let input = $state<HTMLInputElement | null>(null);

	// Two-step delete: which custom space is currently armed for deletion.
	let armedDeleteId = $state<string | null>(null);

	const q = $derived(query.trim().toLowerCase());
	const matchText = (s: string) => !q || s.toLowerCase().includes(q);

	const isCustom = (s: Space) => !s.auto;

	const spaces = $derived(workspaceStore.spaces.filter((s) => matchText(s.name)));

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

	// Single click always switches immediately — custom spaces are renamed via the
	// hover-revealed pencil button (opens the rename modal).
	function rowClick(s: Space) {
		chooseSpace(s);
	}

	function newSpace() {
		workspaceStore.createSpace();
		shell.closeSpaces();
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
				{@render actionRow('new-space', 'plus', 'New space', newSpace)}
			{/if}

			<!-- Open --------------------------------------------------------- -->
			{#if openRowsFiltered.length}
				<SectionLabel class="block px-3 pb-1 pt-2.5 tracking-[0.12em]">Open</SectionLabel>
				{#each openRowsFiltered as r (r.id)}
					{@render actionRow(r.id, r.icon, r.label, r.run)}
				{/each}
			{/if}

			<!-- Settings ----------------------------------------------------- -->
			{#if settingsVisible}
				<SectionLabel class="block px-3 pb-1 pt-2.5 tracking-[0.12em]">Settings</SectionLabel>
				{@render actionRow('settings', 'gear', 'Settings', () => shell.openSettings())}
			{/if}

			{#if !spaces.length && !openRowsFiltered.length && !settingsVisible}
				<p class="px-3 py-3 text-body text-ink-3">No matches for "{query}".</p>
			{/if}
		</div>
	</Surface>
</div>

{#snippet spaceRow(s: Space)}
	{@const active = s.id === workspaceStore.activeId}
	{@const custom = isCustom(s)}
	<div
		class="group/row mx-1.5 flex cursor-pointer items-center gap-2.5 rounded-[9px] px-2 py-[7px] transition-colors hover:bg-[var(--hover-tint)]"
		style:background={active ? 'var(--accent-soft)' : undefined}
		role="button"
		tabindex="0"
		onclick={() => rowClick(s)}
		onkeydown={(e) => e.key === 'Enter' && chooseSpace(s)}
	>
		<Icon name="grid" size={15} class={active ? 'text-brand-hi' : 'text-ink-2'} />
		<span class="flex-1 truncate text-body {active ? 'font-semibold text-ink-1' : 'text-ink-2'}">
			{s.name}
		</span>
		{#if custom && armedDeleteId === s.id}
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
			<!-- Rename is available on every space, including the default Workspace. -->
			<button
				type="button"
				title="Rename space"
				onclick={(e) => {
					e.stopPropagation();
					shell.openSpaceRename(s.id);
				}}
				class="shrink-0 rounded p-0.5 text-ink-3 opacity-0 transition-opacity hover:text-ink-1 group-hover/row:opacity-100"
			>
				<Icon name="pencil" size={13} />
			</button>
			<!-- Delete only for custom spaces — the auto Sessions space is required. -->
			{#if custom}
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
