<script lang="ts">
	import MessageComposer from '$lib/components/MessageComposer.svelte';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';

	let { sessionId }: { sessionId: string } = $props();

	$effect(() => {
		messagesStore.connect();
	});

	const messages = $derived(messagesStore.forSession(sessionId));
</script>

<div class="flex h-full w-80 shrink-0 flex-col border-l border-hair">
	<header class="border-b border-hair px-3 py-2">
		<SectionLabel>Messages</SectionLabel>
	</header>
	<ul class="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-3">
		{#each messages as m (m.id)}
			<li class="text-ui">
				<div class="flex items-baseline gap-2">
					<span class="font-medium text-ink-1">{m.from_label}</span>
					<span class="text-meta text-ink-3">{m.kind}</span>
					{#if m.to_session_id !== sessionId}
						<span class="text-meta text-ink-3">→ out</span>
					{:else if !m.read_at}
						<span class="ml-auto text-meta text-[var(--amber)]">unread</span>
					{/if}
				</div>
				<p class="whitespace-pre-wrap break-words text-ink-1">{m.payload}</p>
			</li>
		{:else}
			<li class="text-ui text-ink-3">No messages for this session.</li>
		{/each}
	</ul>
	<div class="p-3 pt-0">
		<MessageComposer target={sessionId} />
	</div>
</div>
