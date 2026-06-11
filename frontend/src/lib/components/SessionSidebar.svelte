<script lang="ts">
	import { page } from '$app/state';
	import NewSessionDialog from '$lib/components/NewSessionDialog.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import type { SessionStatus } from '$lib/sessions';

	// One-shot: connect() is idempotent and the lobby channel lives for the app's
	// lifetime, so no teardown is needed if the sidebar ever remounts.
	$effect(() => {
		sessionsStore.connect();
	});

	const dotClass: Record<SessionStatus, string> = {
		starting: 'bg-amber-500',
		running: 'bg-emerald-500',
		exited: 'bg-zinc-400',
		failed: 'bg-red-500'
	};
</script>

<aside class="flex w-64 shrink-0 flex-col gap-3 border-r p-3">
	<NewSessionDialog />

	<nav class="flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto">
		{#each sessionsStore.sessions as session (session.id)}
			<a
				href={`/sessions/${session.id}`}
				class="flex items-center gap-2 rounded-md px-2 py-1.5 text-sm hover:bg-accent
					{page.params.id === session.id ? 'bg-accent' : ''}"
			>
				<span title={session.status} class="size-2 shrink-0 rounded-full {dotClass[session.status]}"></span>
				<span class="truncate">{session.name || session.harness_id}</span>
				<span class="ml-auto shrink-0 text-xs text-muted-foreground">{session.harness_id}</span>
			</a>
		{:else}
			{#if sessionsStore.loaded}
				<p class="px-2 py-1.5 text-sm text-muted-foreground">No sessions yet.</p>
			{/if}
		{/each}
	</nav>

	<nav class="flex shrink-0 gap-1 border-t pt-2 text-sm">
		<a
			href="/"
			class="flex-1 rounded-md px-2 py-1.5 text-center hover:bg-accent
				{page.url.pathname.startsWith('/library') ? '' : 'bg-accent'}">Sessions</a
		>
		<a
			href="/library"
			class="flex-1 rounded-md px-2 py-1.5 text-center hover:bg-accent
				{page.url.pathname.startsWith('/library') ? 'bg-accent' : ''}">Library</a
		>
	</nav>
</aside>
