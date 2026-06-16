<script lang="ts">
	// The Sessions view's per-view toolbar. Layout is arranged by dragging tiles
	// (see WatchSetGrid), so there are no preset-layout buttons — just the
	// new-session action. Self-contained: owns its New Session dialog. The shell
	// renders whatever toolbar the active view declares.
	import NewSessionDialog from '$lib/components/NewSessionDialog.svelte';
	import { Button } from '$lib/components/ui/button';

	let newSessionOpen = $state(false);
</script>

<Button size="sm" class="h-[30px] px-3" onclick={() => (newSessionOpen = true)}>New session</Button>

<NewSessionDialog bind:open={newSessionOpen} trigger={false} />
