<script lang="ts">
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import MobileSessionList from './MobileSessionList.svelte';
	import MobileSession from './MobileSession.svelte';

	// Connect the live stores exactly as LegendShell does.
	$effect(() => {
		sessionsStore.connect();
		messagesStore.connect();
	});

	let selectedId = $state<string | null>(null);

	// If the selected session vanishes (stopped/removed), fall back to the list.
	$effect(() => {
		if (selectedId && !sessionsStore.sessions.some((s) => s.id === selectedId)) {
			selectedId = null;
		}
	});
</script>

<div class="flex h-dvh w-full flex-col overflow-hidden bg-app">
	{#if selectedId}
		<MobileSession sessionId={selectedId} onBack={() => (selectedId = null)} />
	{:else}
		<MobileSessionList onOpen={(id) => (selectedId = id)} />
	{/if}
</div>
