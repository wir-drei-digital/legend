<script lang="ts">
	import { libraryStore } from '$lib/stores/library.svelte';
	import { Button } from '$lib/components/ui/button';
	import Icon from '$lib/components/shell/Icon.svelte';
	import Popover from '$lib/components/shell/Popover.svelte';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';

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

	<Popover bind:open class="right-0 top-[36px] w-[280px]">
		<div class="p-2.5">
			<SectionLabel class="mb-1.5 block">New file path</SectionLabel>
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
				class="w-full rounded-[7px] border border-hair-strong bg-inset px-2 py-1.5 text-ui text-ink-1 placeholder:text-ink-3 focus:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] focus:outline-none"
			/>
			<div class="mt-2 flex justify-end gap-2">
				<Button
					size="sm"
					variant="outline"
					class="h-7 px-2.5 text-meta"
					onclick={() => (open = false)}
				>
					Cancel
				</Button>
				<Button size="sm" class="h-7 px-2.5 text-meta" onclick={create} disabled={!path.trim()}>
					Create
				</Button>
			</div>
		</div>
	</Popover>
</div>
