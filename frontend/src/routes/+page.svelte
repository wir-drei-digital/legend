<script lang="ts">
	import { onMount } from 'svelte';
	import { getHealth } from '$lib/api';
	import { getSocket } from '$lib/socket';

	let health = $state('checking…');
	let channelStatus = $state('connecting…');

	onMount(() => {
		getHealth()
			.then((h) => (health = h.status))
			.catch((e) => (health = `error: ${e.message}`));

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

<h1>legend</h1>
<p>API health: {health}</p>
<p>Channel: {channelStatus}</p>
