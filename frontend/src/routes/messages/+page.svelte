<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { workspaceStore } from '$lib/shell/workspace.svelte';

	// Navigation lives in the workspace now: open the messages surface and
	// normalize the URL.
	onMount(() => {
		workspaceStore.openSurface('messages', {});
		void goto('/');
	});
</script>
