<script lang="ts">
	import { libraryStore } from '$lib/stores/library.svelte';
	import { Button } from '$lib/components/ui/button';
	import Icon from '$lib/components/shell/Icon.svelte';

	let open = $state(false);
	let path = $state('');

	async function create() {
		const p = path.trim();
		if (!p) return;
		await libraryStore.create(p);
		path = '';
		open = false;
	}
</script>

<div class="relative">
	<Button size="sm" class="h-[30px] px-3" onclick={() => (open = !open)}>
		<Icon name="plus" size={14} class="mr-1" />
		New file
	</Button>

	{#if open}
		<button
			type="button"
			class="fixed inset-0 z-40 cursor-default"
			aria-label="Close"
			onclick={() => (open = false)}
		></button>
		<div
			class="absolute right-0 top-[36px] z-50 w-[280px] rounded-[10px] border border-hair-strong bg-panel p-2.5 shadow-[0_18px_44px_-12px_rgba(0,0,0,0.7)]"
			style:animation="lg-rise 0.12s ease-out"
		>
			<label
				for="new-file-path"
				class="mb-1.5 block font-mono text-[9px] font-semibold uppercase tracking-[0.14em] text-ink-3"
			>
				New file path
			</label>
			<!-- svelte-ignore a11y_autofocus -->
			<input
				id="new-file-path"
				autofocus
				bind:value={path}
				placeholder="skills/my-skill.md"
				onkeydown={(e) => {
					if (e.key === 'Enter') {
						e.preventDefault();
						void create();
					} else if (e.key === 'Escape') {
						open = false;
					}
				}}
				class="w-full rounded-[7px] border border-hair-strong bg-inset px-2 py-1.5 text-[11.5px] text-ink-1 placeholder:text-ink-3 focus:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] focus:outline-none"
			/>
			<div class="mt-2 flex justify-end gap-2">
				<Button
					size="sm"
					variant="outline"
					class="h-7 px-2.5 text-[11px]"
					onclick={() => (open = false)}
				>
					Cancel
				</Button>
				<Button size="sm" class="h-7 px-2.5 text-[11px]" onclick={create} disabled={!path.trim()}>
					Create
				</Button>
			</div>
		</div>
	{/if}
</div>
