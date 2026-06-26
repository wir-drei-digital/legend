<script lang="ts">
	import { onMount } from 'svelte';
	import * as Dialog from '$lib/components/ui/dialog';
	import { shell } from '$lib/shell/shell.svelte';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';
	import RemoteAccessSection from '$lib/components/shell/RemoteAccessSection.svelte';
	import {
		getLibraryPath,
		putLibraryPath,
		resetLibraryPath,
		type LibraryPathInfo
	} from '$lib/settings';
	import { applyHarnessSetup, listHarnesses, type Harness } from '$lib/sessions';

	let info = $state<LibraryPathInfo | null>(null);
	let path = $state('');
	let error = $state('');
	let saved = $state(false);
	let confirmingReset = $state(false);

	let harnesses = $state<Harness[]>([]);
	let harnessError = $state('');
	let applyingId = $state('');
	let appliedMsg = $state<Record<string, string>>({});

	const withSetup = $derived(harnesses.filter((h) => h.setup.status !== 'not_applicable'));

	async function loadHarnesses() {
		harnessError = '';
		try {
			harnesses = await listHarnesses();
		} catch (e) {
			harnessError = e instanceof Error ? e.message : 'failed to load harnesses';
		}
	}

	async function applyFor(harness: Harness) {
		if (applyingId) return;
		applyingId = harness.id;
		harnessError = '';
		try {
			await applyHarnessSetup(harness.id);
			await loadHarnesses();
			const updated = harnesses.find((h) => h.id === harness.id);
			if (updated?.setup.status === 'ok') {
				appliedMsg = {
					...appliedMsg,
					[harness.id]: updated.setup.restart_hint
						? `Applied — restart existing ${harness.name} sessions to pick this up.`
						: 'Applied.'
				};
			} else {
				harnessError = updated?.setup.detail ?? updated?.setup.summary ?? 'setup did not complete';
			}
		} catch (e) {
			harnessError = e instanceof Error ? e.message : 'setup failed';
		} finally {
			applyingId = '';
		}
	}

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

	onMount(() => {
		void load();
		void loadHarnesses();
	});
</script>

<Dialog.Root bind:open={shell.settingsOpen}>
	<Dialog.Content class="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
		<Dialog.Header>
			<Dialog.Title>Settings</Dialog.Title>
			<Dialog.Description>Workspace & harness integrations</Dialog.Description>
		</Dialog.Header>

		<section class="flex flex-col gap-3">
			<SectionLabel>Library</SectionLabel>

			{#if info}
				{#if envLocked}
					<p class="text-ui text-ink-2">
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
					<p class="text-ui text-ok">Saved.</p>
				{/if}
			{/if}

			{#if error}
				<p class="text-ui text-bad">{error}</p>
			{/if}
		</section>

		<RemoteAccessSection />

		{#if withSetup.length > 0 || harnessError}
			<section class="flex flex-col gap-3">
				<SectionLabel>Harness integrations</SectionLabel>

				{#each withSetup as harness (harness.id)}
					<div class="flex flex-col gap-2 rounded-[10px] border border-hair p-3">
						<div class="flex items-center gap-2">
							<span class="text-ui font-medium text-ink-1">{harness.name}</span>
							{#if harness.setup.status === 'ok'}
								<span class="text-meta text-ok">✓ configured</span>
							{:else if harness.setup.status === 'missing'}
								<span class="text-meta text-ink-3">not configured</span>
							{:else}
								<span class="text-meta text-bad">configuration error</span>
							{/if}
						</div>

						<p class="text-ui text-ink-2">{harness.setup.summary}</p>

						{#if harness.setup.status === 'missing'}
							<div>
								<Button
									size="sm"
									onclick={() => applyFor(harness)}
									disabled={applyingId === harness.id}
								>
									{applyingId === harness.id ? 'Applying…' : 'Apply'}
								</Button>
							</div>
						{/if}

						{#if harness.setup.status === 'error' && harness.setup.detail}
							<pre
								class="overflow-x-auto rounded bg-inset p-2 font-mono text-meta text-ink-2">{harness
									.setup.detail}</pre>
						{/if}

						{#if appliedMsg[harness.id]}
							<p class="text-ui text-ok">{appliedMsg[harness.id]}</p>
						{/if}
					</div>
				{/each}

				{#if harnessError}
					<p class="text-ui text-bad">{harnessError}</p>
				{/if}
			</section>
		{/if}
	</Dialog.Content>
</Dialog.Root>
