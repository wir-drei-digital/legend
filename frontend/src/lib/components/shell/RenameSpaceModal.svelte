<script lang="ts">
	import * as Dialog from '$lib/components/ui/dialog';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { shell } from '$lib/shell/shell.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';

	// Two-way bound to bits-ui (like SettingsModal) so the dialog mounts/unmounts
	// cleanly; shell.renameSpaceId is the source of truth that drives `open`.
	let open = $state(false);
	let value = $state('');
	let seededId: string | null = null;

	$effect(() => {
		const id = shell.renameSpaceId;
		if (id) {
			if (id !== seededId) {
				value = workspaceStore.spaces.find((s) => s.id === id)?.name ?? '';
				seededId = id;
			}
			open = true;
		} else {
			open = false;
			seededId = null;
		}
	});

	function commit() {
		const id = shell.renameSpaceId;
		const name = value.trim();
		if (id && name) workspaceStore.renameSpace(id, name);
		shell.closeSpaceRename();
	}
</script>

<Dialog.Root
	bind:open
	onOpenChange={(o) => {
		// Esc / backdrop / X close routes back through the shell.
		if (!o) shell.closeSpaceRename();
	}}
>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title>Rename space</Dialog.Title>
		</Dialog.Header>
		<form
			class="flex flex-col gap-4"
			onsubmit={(e) => {
				e.preventDefault();
				commit();
			}}
		>
			<div class="flex flex-col gap-2">
				<Label for="space-name">Name</Label>
				<!-- svelte-ignore a11y_autofocus -->
				<Input id="space-name" bind:value autofocus />
			</div>
			<Dialog.Footer>
				<Button type="button" variant="outline" size="sm" onclick={() => shell.closeSpaceRename()}>
					Cancel
				</Button>
				<Button type="submit" size="sm" disabled={!value.trim()}>Save</Button>
			</Dialog.Footer>
		</form>
	</Dialog.Content>
</Dialog.Root>
