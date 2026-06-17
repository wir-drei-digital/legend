<script lang="ts">
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import { watchSet } from '$lib/shell/watchset.svelte';

	// The single-session route is now a deep link into the multiplex: focus the
	// session in the watch-set grid and hand off to the Sessions view.
	$effect(() => {
		const id = page.params.id;
		if (id) {
			watchSet.focus(id);
			void goto('/', { replaceState: true });
		}
	});
</script>

<div class="flex h-full items-center justify-center">
	<p class="text-body text-ink-3">Opening session…</p>
</div>
