<script lang="ts">
	import SessionPane from '$lib/components/sessions/SessionPane.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';

	let { tileId, params, grab }: { tileId: string; params: Record<string, unknown>; grab?: (e: PointerEvent) => void } = $props();

	const sessionId = $derived(params.sessionId as string);
	const session = $derived(sessionsStore.sessions.find((s) => s.id === sessionId) ?? null);
	const layout = $derived(workspaceStore.active.layout);
</script>

{#if session}
	<SessionPane {session} {tileId} {grab} {layout} onClose={() => workspaceStore.closeTile(tileId)} />
{:else}
	<div class="flex h-full flex-col items-center justify-center gap-2 bg-app px-6 text-center">
		<Icon name="sessions" size={22} class="text-ink-3" />
		<p class="text-ui text-ink-2">Session unavailable</p>
		<p class="text-meta text-ink-3">It may have stopped or been removed.</p>
		<button type="button" class="mt-1 text-meta text-brand-hi" onclick={() => workspaceStore.closeTile(tileId)}>Close tile</button>
	</div>
{/if}
