<script lang="ts">
	import { goto } from '$app/navigation';
	import * as Dialog from '$lib/components/ui/dialog';
	import * as Select from '$lib/components/ui/select';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { watchSet } from '$lib/shell/watchset.svelte';
	import {
		applyHarnessSetup,
		createSession,
		dismissSetup,
		isSetupDismissed,
		listHarnesses,
		listRuntimes,
		type Harness,
		type Runtime
	} from '$lib/sessions';

	// `open` can be driven externally (the shell's "Add tile" button). `trigger`
	// controls whether this renders its own button.
	let { open = $bindable(false), trigger = true }: { open?: boolean; trigger?: boolean } = $props();

	let harnesses = $state<Harness[]>([]);
	let harnessId = $state('');
	let runtimes = $state<Runtime[]>([]);
	let runtimeId = $state('');
	let name = $state('');
	let cwd = $state('');
	let error = $state('');
	let creating = $state(false);

	const selectedHarness = $derived(harnesses.find((h) => h.id === harnessId));
	const selectedRuntime = $derived(runtimes.find((r) => r.id === runtimeId));

	const incompatible = $derived(
		!!selectedRuntime?.capabilities?.provisions &&
			!!selectedHarness &&
			!selectedHarness.provisionable
	);

	let dismissed = $state<Record<string, boolean>>({});
	let applyingSetup = $state(false);
	let setupError = $state('');
	let setupApplied = $state('');

	const setupNeeded = $derived(
		!!selectedHarness &&
			selectedHarness.setup.status === 'missing' &&
			!dismissed[selectedHarness.id]
	);

	// Selection change invalidates any setup messages from the previous harness.
	$effect(() => {
		harnessId;
		setupError = '';
		setupApplied = '';
	});

	async function applySetup() {
		if (!selectedHarness || applyingSetup) return;
		const harness = selectedHarness;
		applyingSetup = true;
		setupError = '';
		try {
			await applyHarnessSetup(harness.id);
			harnesses = await listHarnesses();
			const updated = harnesses.find((h) => h.id === harness.id);
			if (updated?.setup.status === 'ok') {
				setupApplied = updated.setup.restart_hint
					? `Applied — restart existing ${harness.name} sessions to pick this up.`
					: 'Applied.';
			} else {
				setupError = updated?.setup.detail ?? updated?.setup.summary ?? 'setup did not complete';
			}
		} catch (e) {
			setupError = e instanceof Error ? e.message : 'setup failed';
		} finally {
			applyingSetup = false;
		}
	}

	function runtimeLabel(id: string): string {
		return id.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
	}

	function dismiss() {
		if (!selectedHarness) return;
		dismissSetup(selectedHarness.id);
		dismissed = { ...dismissed, [selectedHarness.id]: true };
	}

	async function load() {
		error = '';
		try {
			harnesses = await listHarnesses();
			harnessId = harnesses[0]?.id ?? '';
			setupApplied = '';
			setupError = '';
			dismissed = Object.fromEntries(harnesses.map((h) => [h.id, isSetupDismissed(h.id)]));
			runtimes = await listRuntimes();
			runtimeId = runtimes.find((r) => r.id === 'local_pty')?.id ?? runtimes[0]?.id ?? '';
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load harnesses';
		}
	}

	// Load harness/runtime options whenever the dialog opens (however it's opened).
	let wasOpen = false;
	$effect(() => {
		if (open && !wasOpen) void load();
		wasOpen = open;
	});

	async function create() {
		if (!harnessId) return;
		creating = true;
		error = '';
		try {
			const session = await createSession({
				harness_id: harnessId,
				...(runtimeId ? { runtime_id: runtimeId } : {}),
				...(name.trim() ? { name: name.trim() } : {}),
				...(cwd.trim() ? { cwd: cwd.trim() } : {})
			});
			open = false;
			name = '';
			cwd = '';
			// Surface the fresh session straight into the watch-set grid.
			watchSet.promote(session.id);
			await goto('/');
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to create session';
		} finally {
			creating = false;
		}
	}
</script>

{#if trigger}
	<Button class="w-full" onclick={() => (open = true)}>New session</Button>
{/if}

<Dialog.Root bind:open>
	<Dialog.Content class="sm:max-w-md">
		<Dialog.Header>
			<Dialog.Title>New session</Dialog.Title>
			<Dialog.Description>Launch an agent in a fresh terminal session.</Dialog.Description>
		</Dialog.Header>

		<div class="flex flex-col gap-4">
			<div class="flex flex-col gap-2">
				<Label for="harness">Harness</Label>
				<Select.Root type="single" bind:value={harnessId}>
					<Select.Trigger id="harness" class="w-full">
						{selectedHarness?.name ?? 'Pick a harness'}
					</Select.Trigger>
					<Select.Content>
						{#each harnesses as harness (harness.id)}
							<Select.Item value={harness.id} label={harness.name} />
						{/each}
					</Select.Content>
				</Select.Root>
			</div>

			<div class="flex flex-col gap-2">
				<Label for="runtime">Runtime</Label>
				<Select.Root type="single" bind:value={runtimeId}>
					<Select.Trigger id="runtime" class="w-full">
						{selectedRuntime ? runtimeLabel(selectedRuntime.id) : 'Pick a runtime'}
					</Select.Trigger>
					<Select.Content>
						{#each runtimes as runtime (runtime.id)}
							<Select.Item value={runtime.id} label={runtimeLabel(runtime.id)} />
						{/each}
					</Select.Content>
				</Select.Root>
			</div>

			{#if setupNeeded && selectedHarness}
				<div class="flex flex-col gap-2 rounded-md border bg-muted/40 p-3 text-sm">
					<p>{selectedHarness.name}: {selectedHarness.setup.summary}</p>
					{#if setupError}
						<p class="text-destructive">{setupError}</p>
					{/if}
					<div class="flex gap-2">
						<Button size="sm" onclick={applySetup} disabled={applyingSetup}>
							{applyingSetup ? 'Applying…' : 'Apply'}
						</Button>
						<Button size="sm" variant="outline" onclick={dismiss}>Dismiss</Button>
					</div>
				</div>
			{:else if setupApplied}
				<p class="text-sm text-emerald-600">{setupApplied}</p>
			{/if}

			<div class="flex flex-col gap-2">
				<Label for="name">Name (optional)</Label>
				<Input id="name" bind:value={name} placeholder="e.g. refactor sprint" />
			</div>

			<div class="flex flex-col gap-2">
				<Label for="cwd">Working directory</Label>
				<Input
					id="cwd"
					bind:value={cwd}
					placeholder={selectedRuntime && selectedRuntime.id !== 'local_pty'
						? 'sprite working directory (e.g. /root)'
						: 'defaults to your home directory'}
				/>
			</div>

			{#if incompatible && selectedHarness && selectedRuntime}
				<p class="text-sm text-destructive">
					{selectedHarness.name} can't be auto-installed on {runtimeLabel(selectedRuntime.id)} —
					pick a different harness or runtime.
				</p>
			{/if}

			{#if error}
				<p class="text-sm text-destructive">{error}</p>
			{/if}
		</div>

		<Dialog.Footer>
			<Button onclick={create} disabled={creating || !harnessId || incompatible}>
				{creating ? 'Starting…' : 'Start session'}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
