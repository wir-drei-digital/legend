<script lang="ts">
	// Renders the sticky queued-messages list. The queue state itself lives in
	// `Composer` (a $state<string[]>); this part is purely presentational + emits
	// row actions back up. `onEdit(i)` pulls the row back into the composer input.
	let {
		queue,
		onSendNow,
		onRemove,
		onEdit
	}: {
		queue: string[];
		onSendNow: (index: number) => void;
		onRemove: (index: number) => void;
		onEdit: (index: number) => void;
	} = $props();
</script>

{#if queue.length}
	<div class="border-b border-hair px-3 py-2">
		<div class="mb-1.5 flex items-center gap-1.5 text-micro uppercase tracking-[0.06em] text-ink-3">
			<span class="font-bold text-warn">{queue.length}</span> Queued
		</div>
		{#each queue as text, i (i)}
			<div
				class="mb-1 flex items-center gap-2 rounded-sm border border-hair-strong bg-app py-1 pl-2.5 pr-1.5 text-ui text-ink-1"
			>
				<span class="font-mono text-micro font-bold text-ink-3">{i + 1}</span>
				<span class="min-w-0 flex-1 truncate">{text}</span>
				<span class="flex items-center gap-0.5">
					<button
						type="button"
						title="Send now (jump the queue)"
						onclick={() => onSendNow(i)}
						class="grid size-[22px] place-items-center rounded-sm border border-transparent text-brand-hi hover:border-brand"
					>
						▶
					</button>
					<button
						type="button"
						title="Edit"
						onclick={() => onEdit(i)}
						class="grid size-[22px] place-items-center rounded-sm border border-transparent text-ink-3 hover:border-hair-strong hover:bg-panel hover:text-ink-1"
					>
						✎
					</button>
					<button
						type="button"
						title="Remove"
						onclick={() => onRemove(i)}
						class="grid size-[22px] place-items-center rounded-sm border border-transparent text-ink-3 hover:border-hair-strong hover:bg-panel hover:text-ink-1"
					>
						✕
					</button>
				</span>
			</div>
		{/each}
	</div>
{/if}
