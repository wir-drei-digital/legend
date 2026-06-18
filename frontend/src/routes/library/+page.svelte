<script lang="ts">
	import { onMount } from 'svelte';
	import { goto } from '$app/navigation';

	// The dedicated Library space is gone — files now open from the dock's Files
	// source into any space. This legacy route just normalizes the URL.
	onMount(() => {
		void goto('/');
	});
</script>
