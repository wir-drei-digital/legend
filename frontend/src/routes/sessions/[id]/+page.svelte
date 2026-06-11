<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import Terminal from '$lib/components/Terminal.svelte';
	import { Button } from '$lib/components/ui/button';
	import { deleteSession, type SessionStatus } from '$lib/sessions';

	const sessionId = $derived(page.params.id!);

	let status = $state<SessionStatus | null>(null);
	let exitCode = $state<number | null>(null);
	let error = $state<string | null>(null);
	let terminal = $state<ReturnType<typeof Terminal> | null>(null);

	// When the route changes (re-navigating to another session) the `{#key}` block
	// recreates the Terminal, but these locals keep their previous values until the
	// new join reply arrives — reset them so we never show a stale status.
	$effect(() => {
		sessionId;
		status = null;
		exitCode = null;
		error = null;
	});

	function handleStatus(s: SessionStatus, code: number | null, err: string | null) {
		status = s;
		exitCode = code;
		error = err;
	}

	async function remove() {
		await deleteSession(sessionId);
		await goto('/');
	}
</script>

<div class="flex h-full flex-col">
	<div class="flex items-center gap-2 border-b px-3 py-2">
		<span class="text-sm text-muted-foreground">
			{status ?? 'connecting…'}{#if status === 'exited' && exitCode !== null}&nbsp;(exit {exitCode}){/if}
		</span>
		{#if error}
			<span class="truncate text-sm text-destructive">{error}</span>
		{/if}
		<div class="ml-auto flex gap-2">
			{#if status === 'running' || status === 'starting'}
				<Button variant="outline" size="sm" onclick={() => terminal?.requestStop()}>Stop</Button>
			{:else}
				<Button variant="destructive" size="sm" onclick={remove}>Delete</Button>
			{/if}
		</div>
	</div>

	<div class="min-h-0 flex-1">
		{#key sessionId}
			<Terminal bind:this={terminal} {sessionId} onstatus={handleStatus} />
		{/key}
	</div>
</div>
