<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { shell } from '$lib/shell/shell.svelte';

	// Navigation lives in the workspace now: open the settings modal and
	// normalize the URL.
	onMount(() => {
		shell.openSettings();
		void goto('/');
	});
</script>
