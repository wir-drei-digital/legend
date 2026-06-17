<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { workspaceStore } from '$lib/shell/workspace.svelte';

	// Navigation lives in the workspace now: switch to the library space and
	// normalize the URL.
	onMount(() => {
		workspaceStore.switchSpace('library');
		void goto('/');
	});
</script>
