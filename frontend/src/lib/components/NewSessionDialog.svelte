<script lang="ts">
	import { goto } from '$app/navigation';
	import * as Dialog from '$lib/components/ui/dialog';
	import * as Select from '$lib/components/ui/select';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import { createSession, listHarnesses, type Harness } from '$lib/sessions';

	let open = $state(false);
	let harnesses = $state<Harness[]>([]);
	let harnessId = $state('');
	let name = $state('');
	let cwd = $state('');
	let error = $state('');
	let creating = $state(false);

	const selectedHarness = $derived(harnesses.find((h) => h.id === harnessId));

	async function openDialog() {
		error = '';
		open = true;
		try {
			harnesses = await listHarnesses();
			harnessId = harnesses[0]?.id ?? '';
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load harnesses';
		}
	}

	async function create() {
		if (!harnessId) return;
		creating = true;
		error = '';
		try {
			const session = await createSession({
				harness_id: harnessId,
				...(name.trim() ? { name: name.trim() } : {}),
				...(cwd.trim() ? { cwd: cwd.trim() } : {})
			});
			open = false;
			name = '';
			cwd = '';
			await goto(`/sessions/${session.id}`);
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to create session';
		} finally {
			creating = false;
		}
	}
</script>

<Button class="w-full" onclick={openDialog}>New session</Button>

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
				<Label for="name">Name (optional)</Label>
				<Input id="name" bind:value={name} placeholder="e.g. refactor sprint" />
			</div>

			<div class="flex flex-col gap-2">
				<Label for="cwd">Working directory</Label>
				<Input id="cwd" bind:value={cwd} placeholder="defaults to your home directory" />
			</div>

			{#if error}
				<p class="text-sm text-destructive">{error}</p>
			{/if}
		</div>

		<Dialog.Footer>
			<Button onclick={create} disabled={creating || !harnessId}>
				{creating ? 'Starting…' : 'Start session'}
			</Button>
		</Dialog.Footer>
	</Dialog.Content>
</Dialog.Root>
