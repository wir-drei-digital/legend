<script lang="ts">
	import type { AcpItem } from '$lib/shell/acpSession.svelte';

	let { items }: { items: AcpItem[] } = $props();

	// The reducer emits at most one `plan` singleton; derive it from the stream.
	const plan = $derived(items.find((it) => it.type === 'plan'));

	type Entry = { text: string; status: string };
	const entries = $derived(
		plan && Array.isArray(plan.entries)
			? (plan.entries as unknown[]).flatMap((e) =>
					e && typeof e === 'object'
						? [
								{
									text: typeof (e as Entry).text === 'string' ? (e as Entry).text : '',
									status: typeof (e as Entry).status === 'string' ? (e as Entry).status : ''
								}
							]
						: []
				)
			: ([] as Entry[])
	);

	const total = $derived(entries.length);
	const done = $derived(entries.filter((e) => e.status === 'completed' || e.status === 'done').length);
	// The "current" step: first in_progress, else first not-done.
	const current = $derived(
		entries.find((e) => e.status === 'in_progress') ??
			entries.find((e) => e.status !== 'completed' && e.status !== 'done')
	);

	let expanded = $state(false);
</script>

{#if plan && total}
	<div class="border-b border-hair px-3 py-2">
		<!-- one-line summary; click to expand the full checklist -->
		<button
			type="button"
			onclick={() => (expanded = !expanded)}
			class="flex w-full items-center gap-2 text-left"
		>
			<h5 class="m-0 text-micro uppercase tracking-[0.06em] text-ink-3">Plan</h5>
			<span
				class="rounded-sm border border-hair-strong bg-panel px-1.5 py-px font-mono text-micro font-bold text-ink-2"
			>
				{done} / {total}
			</span>
			{#if current}
				<span class="min-w-0 flex-1 truncate text-meta text-ink-1">
					▸ <b class="font-semibold text-warn">{current.text}</b>
				</span>
			{:else}
				<span class="min-w-0 flex-1 truncate text-meta text-ink-3">all steps complete</span>
			{/if}
			<span class="ml-auto shrink-0 text-ink-3">{expanded ? '⌃' : '⌄'}</span>
		</button>

		{#if expanded}
			<ul class="mt-2 flex list-none flex-col gap-px p-0">
				{#each entries as entry, i (i)}
					{@const isDone = entry.status === 'completed' || entry.status === 'done'}
					{@const isNow = entry.status === 'in_progress'}
					<li
						class="flex items-center gap-2 py-0.5 text-ui"
						class:text-ink-3={isDone}
						class:line-through={isDone}
						class:text-ink-1={isNow}
						class:text-ink-2={!isDone && !isNow}
					>
						<span class="w-3.5 shrink-0 text-center">{isDone ? '✓' : isNow ? '▸' : '○'}</span>
						<span class="min-w-0 flex-1 truncate">{entry.text}</span>
					</li>
				{/each}
			</ul>
		{/if}
	</div>
{/if}
