<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import MessagesPanel from '$lib/components/MessagesPanel.svelte';
	import Terminal from '$lib/components/Terminal.svelte';
	import { Button } from '$lib/components/ui/button';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import {
		deleteSession,
		listHarnesses,
		resumeSession,
		type Harness,
		type SessionStatus
	} from '$lib/sessions';

	const sessionId = $derived(page.params.id!);

	let showMessages = $state(false);
	const unread = $derived(messagesStore.unreadCount(sessionId));

	let status = $state<SessionStatus | null>(null);
	let exitCode = $state<number | null>(null);
	let error = $state<string | null>(null);
	let terminal = $state<ReturnType<typeof Terminal> | null>(null);

	let harnesses = $state<Harness[]>([]);
	let resuming = $state(false);
	let resumeKey = $state(0);

	$effect(() => {
		sessionsStore.connect();
		void listHarnesses().then((h) => (harnesses = h));
	});

	const session = $derived(sessionsStore.sessions.find((s) => s.id === sessionId));
	const resumable = $derived(
		harnesses.find((h) => h.id === session?.harness_id)?.resumable ?? false
	);

	// When the route changes (re-navigating to another session) the `{#key}` block
	// recreates the Terminal, but these locals keep their previous values until the
	// new join reply arrives — reset them so we never show a stale status.
	$effect(() => {
		sessionId;
		status = null;
		exitCode = null;
		error = null;
	});

	async function resume() {
		if (resuming) return;
		resuming = true;
		error = null;
		try {
			await resumeSession(sessionId);
			// Re-key the Terminal so it re-joins and repaints against the fresh server.
			resumeKey += 1;
			status = 'starting';
			exitCode = null;
		} catch (e) {
			error = e instanceof Error ? e.message : 'resume failed';
		} finally {
			resuming = false;
		}
	}

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
			{status ?? 'connecting…'}{#if status === 'exited' && exitCode !== null}&nbsp;(exit {exitCode}){/if}{#if status === 'interrupted'}&nbsp;— backend restarted{/if}
		</span>
		{#if error}
			<span class="truncate text-sm text-destructive">{error}</span>
		{/if}
		<div class="ml-auto flex gap-2">
			<Button variant="outline" size="sm" onclick={() => (showMessages = !showMessages)}>
				Messages{#if unread > 0}&nbsp;({unread}){/if}
			</Button>
			{#if status === 'interrupted' || status === 'exited'}
				<Button size="sm" onclick={resume} disabled={resuming}>
					{resumable ? 'Resume' : 'Restart'}
				</Button>
			{/if}
			{#if status === 'running' || status === 'starting'}
				<Button variant="outline" size="sm" onclick={() => terminal?.requestStop()}>Stop</Button>
			{:else}
				<Button variant="destructive" size="sm" onclick={remove}>Delete</Button>
			{/if}
		</div>
	</div>

	<div class="flex min-h-0 flex-1">
		<div class="min-h-0 min-w-0 flex-1">
			{#key `${sessionId}:${resumeKey}`}
				<Terminal bind:this={terminal} {sessionId} onstatus={handleStatus} />
			{/key}
		</div>
		{#if showMessages}
			<MessagesPanel {sessionId} />
		{/if}
	</div>
</div>
