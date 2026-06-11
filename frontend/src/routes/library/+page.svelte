<script lang="ts">
	import { onMount } from 'svelte';
	import LibraryTree from '$lib/components/LibraryTree.svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import {
		buildTree,
		deleteFile,
		listTree,
		readFile,
		writeFile,
		type TreeNode
	} from '$lib/library';

	let tree = $state<TreeNode[]>([]);
	let selected = $state<string | null>(null);
	let content = $state('');
	let savedContent = $state('');
	let newPath = $state('');
	let error = $state('');

	const dirty = $derived(content !== savedContent);

	async function refresh() {
		try {
			tree = buildTree(await listTree());
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load library';
		}
	}

	// window.confirm/alert/prompt are no-ops in the Tauri webview (wry returns
	// false), so all confirmations here are in-UI two-step interactions.
	let confirmingDelete = $state(false);
	let pendingOpen = $state<string | null>(null);

	async function open(path: string) {
		if (dirty && pendingOpen !== path) {
			pendingOpen = path;
			error = 'Unsaved changes — click the file again to discard them.';
			return;
		}
		pendingOpen = null;
		confirmingDelete = false;
		error = '';
		try {
			content = await readFile(path);
			savedContent = content;
			selected = path;
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to read file';
		}
	}

	async function save() {
		if (!selected) return;
		error = '';
		try {
			await writeFile(selected, content);
			savedContent = content;
			await refresh();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to save';
		}
	}

	async function createFile() {
		const path = newPath.trim();
		if (!path) return;
		error = '';
		try {
			await writeFile(path, '');
			newPath = '';
			await refresh();
			await open(path);
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to create file';
		}
	}

	async function removeSelected() {
		if (!selected) return;
		error = '';
		try {
			await deleteFile(selected);
			selected = null;
			content = '';
			savedContent = '';
			confirmingDelete = false;
			await refresh();
		} catch (e) {
			confirmingDelete = false;
			error = e instanceof Error ? e.message : 'failed to delete';
		}
	}

	onMount(() => void refresh());
</script>

<div class="flex h-full">
	<aside class="flex w-72 shrink-0 flex-col gap-2 overflow-y-auto border-r p-3">
		<div class="flex gap-2">
			<Input bind:value={newPath} placeholder="skills/my-skill.md" />
			<Button size="sm" variant="outline" onclick={createFile}>New</Button>
		</div>
		<LibraryTree nodes={tree} {selected} onselect={open} />
	</aside>

	<main class="flex min-w-0 flex-1 flex-col">
		<div class="flex items-center gap-2 border-b px-3 py-2">
			<span class="truncate text-sm text-muted-foreground">
				{selected ?? 'Select a file'}{dirty ? ' •' : ''}
			</span>
			{#if error}
				<span class="truncate text-sm text-destructive">{error}</span>
			{/if}
			<div class="ml-auto flex gap-2">
				{#if selected}
					<Button size="sm" onclick={save} disabled={!dirty}>Save</Button>
					{#if confirmingDelete}
						<Button size="sm" variant="destructive" onclick={removeSelected}>
							Confirm delete
						</Button>
						<Button size="sm" variant="outline" onclick={() => (confirmingDelete = false)}>
							Cancel
						</Button>
					{:else}
						<Button size="sm" variant="destructive" onclick={() => (confirmingDelete = true)}>
							Delete
						</Button>
					{/if}
				{/if}
			</div>
		</div>
		{#if selected}
			<textarea
				bind:value={content}
				onkeydown={(e) => {
					if ((e.metaKey || e.ctrlKey) && e.key === 's') {
						e.preventDefault();
						void save();
					}
				}}
				class="min-h-0 flex-1 resize-none bg-background p-3 font-mono text-sm outline-none"
				spellcheck="false"
			></textarea>
		{:else}
			<div class="flex flex-1 items-center justify-center">
				<p class="text-muted-foreground">Select or create a file.</p>
			</div>
		{/if}
	</main>
</div>
