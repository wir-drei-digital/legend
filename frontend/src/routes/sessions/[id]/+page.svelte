<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { sessionsLayout } from '$lib/shell/sessions-layout.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';

	// The single-session route is now a deep link into the multiplex: promote
	// the session into the watch-set grid, switch to the Sessions space, and
	// normalize the URL.
	onMount(() => {
		const id = page.params.id;
		if (id) {
			sessionsLayout.promote(id);
			workspaceStore.switchSpace('sessions');
		}
		void goto('/');
	});
</script>
