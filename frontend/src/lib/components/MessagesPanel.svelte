<script lang="ts">
	import MessageComposer from '$lib/components/MessageComposer.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';

	let { sessionId }: { sessionId: string } = $props();

	$effect(() => {
		messagesStore.connect();
	});

	const messages = $derived(messagesStore.forSession(sessionId));
</script>

<div class="flex h-full w-80 shrink-0 flex-col border-l">
	<header class="border-b px-3 py-2 text-sm font-medium">Messages</header>
	<ul class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-3">
		{#each messages as m (m.id)}
			<li class="text-sm">
				<div class="flex items-baseline gap-2">
					<span class="font-medium">{m.from_label}</span>
					<span class="text-xs text-muted-foreground">{m.kind}</span>
					{#if m.to_session_id !== sessionId}
						<span class="text-xs text-muted-foreground">→ out</span>
					{:else if !m.read_at}
						<span class="ml-auto text-xs text-amber-600">unread</span>
					{/if}
				</div>
				<p class="whitespace-pre-wrap break-words">{m.payload}</p>
			</li>
		{:else}
			<li class="text-sm text-muted-foreground">No messages for this session.</li>
		{/each}
	</ul>
	<div class="p-3 pt-0">
		<MessageComposer target={sessionId} />
	</div>
</div>
