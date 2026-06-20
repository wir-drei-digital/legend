<script lang="ts">
	import type { AcpItem } from '$lib/shell/acpSession.svelte';

	let { item }: { item: AcpItem } = $props();

	// Narrow the loosely-typed AcpItem into the fields a tool call carries.
	const kind = $derived(typeof item.kind === 'string' ? item.kind : '');
	const title = $derived(typeof item.title === 'string' ? item.title : '');
	const status = $derived(typeof item.status === 'string' ? item.status : '');
	const output = $derived(typeof item.output === 'string' ? item.output : '');

	type Diff = { path?: string; oldText?: string; newText?: string };
	const diff = $derived(
		item.diff && typeof item.diff === 'object' ? (item.diff as Diff) : undefined
	);
	const diffPath = $derived(diff && typeof diff.path === 'string' ? diff.path : '');
	const oldLines = $derived(
		diff && typeof diff.oldText === 'string' && diff.oldText.length
			? diff.oldText.replace(/\n$/, '').split('\n')
			: []
	);
	const newLines = $derived(
		diff && typeof diff.newText === 'string' && diff.newText.length
			? diff.newText.replace(/\n$/, '').split('\n')
			: []
	);
</script>

<div class="overflow-hidden rounded-md border border-hair-strong bg-panel">
	<!-- title row: kind label · name · status glyph -->
	<div class="flex items-center gap-2 px-2.5 py-1.5">
		<span class="font-mono text-micro font-bold uppercase tracking-[0.05em] text-ink-3">{kind}</span>
		<span class="min-w-0 flex-1 truncate font-mono text-ui font-medium text-ink-1">{title}</span>
		<span class="ml-auto flex shrink-0 items-center gap-1.5 text-meta">
			{#if status === 'completed'}
				<span class="text-ok">✓</span>
			{:else if status === 'in_progress'}
				<span
					class="inline-block size-2.5 animate-spin rounded-full border-2 border-warn border-r-transparent"
					aria-label="in progress"
				></span>
			{:else if status === 'failed'}
				<span class="text-bad">✗</span>
			{:else if status}
				<span class="text-ink-3">{status}</span>
			{/if}
		</span>
	</div>

	{#if diff}
		<div class="border-t border-hair font-mono text-meta leading-relaxed">
			{#if diffPath}
				<div class="px-2.5 py-0.5 text-ink-3">{diffPath}</div>
			{/if}
			{#each oldLines as line, i (`-${i}`)}
				<div class="bg-bad/10 px-2.5 py-px text-bad">-&nbsp;{line}</div>
			{/each}
			{#each newLines as line, i (`+${i}`)}
				<div class="bg-ok/10 px-2.5 py-px text-ok">+&nbsp;{line}</div>
			{/each}
		</div>
	{/if}

	{#if output}
		<div
			class="border-t border-hair whitespace-pre-wrap break-words px-2.5 py-1.5 font-mono text-meta text-ink-2"
		>
			{output}
		</div>
	{/if}
</div>
