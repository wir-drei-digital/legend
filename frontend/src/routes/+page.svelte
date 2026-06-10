<script lang="ts">
	import { onMount } from 'svelte';
	import { Button } from '$lib/components/ui/button';
	import { getHealth } from '$lib/api';
	import { getSocket } from '$lib/socket';

	let health = $state('checking…');
	let channelStatus = $state('connecting…');

	function recheckHealth() {
		health = 'checking…';
		getHealth()
			.then((h) => (health = h.status))
			.catch((e) => (health = `error: ${e.message}`));
	}

	onMount(() => {
		recheckHealth();

		const channel = getSocket().channel('chat:lobby');
		channel
			.join()
			.receive('ok', () => (channelStatus = 'joined chat:lobby'))
			.receive('error', () => (channelStatus = 'join failed'));

		return () => {
			channel.leave();
		};
	});
</script>

<main class="mx-auto flex max-w-md flex-col gap-4 p-8">
	<h1 class="text-2xl font-semibold">legend</h1>
	<p class="text-muted-foreground">API health: {health}</p>
	<p class="text-muted-foreground">Channel: {channelStatus}</p>
	<Button onclick={recheckHealth}>Recheck health</Button>
</main>
