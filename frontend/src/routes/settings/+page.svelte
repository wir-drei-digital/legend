<script lang="ts">
	import { onMount } from 'svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import {
		getLibraryPath,
		putLibraryPath,
		resetLibraryPath,
		type LibraryPathInfo
	} from '$lib/settings';

	let info = $state<LibraryPathInfo | null>(null);
	let path = $state('');
	let error = $state('');
	let saved = $state(false);
	let confirmingReset = $state(false);

	const envLocked = $derived(info?.source === 'env');

	function apply(next: LibraryPathInfo) {
		info = next;
		// One field shows the truth: the effective path (the default when no
		// custom path is set).
		path = next.effective;
		confirmingReset = false;
	}

	async function load() {
		error = '';
		try {
			apply(await getLibraryPath());
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load settings';
		}
	}

	async function save() {
		const target = path.trim();
		if (!target) return;
		error = '';
		saved = false;
		try {
			apply(await putLibraryPath(target));
			saved = true;
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to save';
		}
	}

	// No native confirm() — it is a no-op in the Tauri webview.
	async function reset() {
		error = '';
		saved = false;
		try {
			apply(await resetLibraryPath());
			saved = true;
		} catch (e) {
			confirmingReset = false;
			error = e instanceof Error ? e.message : 'failed to reset';
		}
	}

	onMount(() => void load());
</script>

<div class="mx-auto flex max-w-2xl flex-col gap-6 p-8">
	<h1 class="text-xl font-semibold">Settings</h1>

	<section class="flex flex-col gap-3">
		<h2 class="text-sm font-medium">Library</h2>

		{#if info}
			{#if envLocked}
				<p class="text-sm text-muted-foreground">
					The library path is set by the <code>LIBRARY_PATH</code> environment variable to
					<code>{info.effective}</code> and can't be edited here. Unset it in
					<code>backend/.env</code> to manage it from this page.
				</p>
			{:else}
				<div class="flex flex-col gap-2">
					<Label for="library-path">Library path</Label>
					<Input id="library-path" bind:value={path} />
				</div>

				<div class="flex gap-2">
					<Button
						size="sm"
						onclick={save}
						disabled={!path.trim() || path.trim() === info.effective}
					>
						Save
					</Button>
					{#if info.value}
						{#if confirmingReset}
							<Button size="sm" variant="destructive" onclick={reset}>Confirm reset</Button>
							<Button size="sm" variant="outline" onclick={() => (confirmingReset = false)}>
								Cancel
							</Button>
						{:else}
							<Button size="sm" variant="outline" onclick={() => (confirmingReset = true)}>
								Reset to default
							</Button>
						{/if}
					{/if}
				</div>
			{/if}

			{#if saved}
				<p class="text-sm text-emerald-600">Saved.</p>
			{/if}
		{/if}

		{#if error}
			<p class="text-sm text-destructive">{error}</p>
		{/if}
	</section>
</div>
