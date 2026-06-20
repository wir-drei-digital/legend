<script lang="ts">
	import type { AcpItem } from '$lib/shell/acpSession.svelte';

	let { item, onAnswer }: { item: AcpItem; onAnswer: (requestId: string, optionId: string) => void } =
		$props();

	// Permission items carry: title, command, options:[{optionId,name,kind}], resolved.
	// The item's `id` IS the request key — onAnswer(item.id, option.optionId).
	const title = $derived(typeof item.title === 'string' ? item.title : 'Permission request');
	const command = $derived(typeof item.command === 'string' ? item.command : '');

	type Option = { optionId: string; name: string; kind?: string };
	const options = $derived(
		Array.isArray(item.options)
			? (item.options as unknown[]).flatMap((o) =>
					o && typeof o === 'object' && typeof (o as Option).optionId === 'string'
						? [
								{
									optionId: (o as Option).optionId,
									name: typeof (o as Option).name === 'string' ? (o as Option).name : (o as Option).optionId,
									kind: typeof (o as Option).kind === 'string' ? (o as Option).kind : ''
								}
							]
						: []
				)
			: ([] as Option[])
	);

	const resolved = $derived(item.resolved === true);
	// Surface the chosen option's label when resolved (if the reducer recorded it).
	const chosenId = $derived(typeof item.selectedOptionId === 'string' ? item.selectedOptionId : '');
	const chosen = $derived(options.find((o) => o.optionId === chosenId));

	// "reject"/"deny" style options get a danger tone; the rest read as the default.
	const isDanger = (kind: string) => kind === 'reject' || kind === 'reject_once' || kind === 'reject_always';
	const optionClass = (kind: string) =>
		isDanger(kind)
			? 'border-bad/40 text-bad hover:bg-bad/10'
			: 'border-hair-strong bg-panel text-ink-1 hover:bg-raised';
</script>

<div class="overflow-hidden rounded-md border border-warn/40 bg-warn/5">
	<div class="flex items-center gap-2 px-3 py-2">
		<span class="text-warn">⚠</span>
		<span class="min-w-0 flex-1 truncate text-ui font-medium text-ink-1">{title}</span>
	</div>

	{#if command}
		<div class="border-t border-warn/20 px-3 py-1.5 font-mono text-meta text-ink-2">{command}</div>
	{/if}

	<div class="flex flex-wrap items-center gap-2 border-t border-warn/20 px-3 py-2">
		{#if resolved}
			<span class="text-meta text-ink-3">
				{#if chosen}
					Resolved — {chosen.name}
				{:else}
					Resolved
				{/if}
			</span>
		{:else}
			{#each options as option (option.optionId)}
				<button
					type="button"
					onclick={() => onAnswer(item.id, option.optionId)}
					class="rounded-sm border px-2.5 py-1 text-meta transition-colors {optionClass(
						option.kind ?? ''
					)}"
				>
					{option.name}
				</button>
			{/each}
		{/if}
	</div>
</div>
