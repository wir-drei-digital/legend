<script lang="ts">
	import Popover from '$lib/components/shell/Popover.svelte';

	// A compact composer chip that opens an upward dropdown of options. Used for
	// the permission-mode, model, and thinking selectors — each just supplies its
	// option list and an onSelect. Options are the uniform {id, name?, description?}
	// shape the backend normalizes mode/model config into.
	export type ConfigOption = { id: string; name?: string; description?: string };

	let {
		value,
		options,
		onSelect,
		title,
		label,
		active = false,
		placeholder = '—'
	}: {
		/** currently-selected option id */
		value: string | null;
		options: ConfigOption[];
		onSelect: (id: string) => void;
		/** native tooltip on the chip */
		title?: string;
		/** dim prefix shown before the value (e.g. "think") */
		label?: string;
		/** tint the value with the brand accent (e.g. thinking is engaged) */
		active?: boolean;
		placeholder?: string;
	} = $props();

	let open = $state(false);
	const current = $derived(options.find((o) => o.id === value));
	const display = $derived(current?.name ?? value ?? placeholder);

	function choose(id: string) {
		open = false;
		if (id !== value) onSelect(id);
	}
</script>

<div class="relative">
	<button
		type="button"
		{title}
		onclick={() => (open = !open)}
		class="flex items-center gap-1 rounded-sm border border-hair-strong px-2 py-1 text-meta hover:bg-raised {open
			? 'bg-raised'
			: 'bg-panel'}"
	>
		{#if label}<span class="text-ink-3">{label}</span>{/if}
		<span class="max-w-[14ch] truncate {active ? 'text-brand-hi' : 'text-ink-2'}">{display}</span>
		<span class="text-ink-3">▾</span>
	</button>

	<!-- opens upward: the composer sits at the bottom of the pane -->
	<Popover bind:open class="bottom-full right-0 mb-1 w-[230px]">
		<div class="flex flex-col py-1">
			{#each options as opt (opt.id)}
				{@const selected = opt.id === value}
				<button
					type="button"
					onclick={() => choose(opt.id)}
					class="flex w-full flex-col gap-0.5 px-2.5 py-1.5 text-left transition-colors hover:bg-[var(--hover-tint)]"
				>
					<span class="flex items-center gap-2 text-ui {selected ? 'text-ink-1' : 'text-ink-2'}">
						<span class="min-w-0 flex-1 truncate">{opt.name ?? opt.id}</span>
						{#if selected}<span class="text-brand-hi">✓</span>{/if}
					</span>
					{#if opt.description}
						<span class="text-meta text-ink-3">{opt.description}</span>
					{/if}
				</button>
			{/each}
		</div>
	</Popover>
</div>
