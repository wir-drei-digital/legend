<script lang="ts">
	import WatchSetGrid from '$lib/components/sessions/WatchSetGrid.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { watchSet } from '$lib/shell/watchset.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { shell } from '$lib/shell/shell.svelte';

	// Candidate order for auto-filling empty grid slots: attention → running → idle.
	const candidates = $derived.by(() => {
		const rank = (kindAttention: { attention: boolean; kind: string }) =>
			kindAttention.attention ? 0 : kindAttention.kind === 'running' ? 1 : 2;
		return [...sessionsStore.sessions]
			.map((s) => ({ s, st: liveState(s) }))
			.sort((a, b) => rank(a.st) - rank(b.st))
			.map((x) => x.s.id);
	});

	// Keep the watch-set consistent with live sessions (drops dead, fills empties).
	$effect(() => {
		watchSet.reconcile(candidates);
	});

	// Power-user keys: 1–4 activate a pane, Esc leaves focus mode.
	function onKeydown(e: KeyboardEvent) {
		const el = e.target as HTMLElement | null;
		if (el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable)) return;
		if (shell.spacesOpen) return;
		if (e.key === 'Escape') {
			watchSet.restore();
			return;
		}
		const num = Number(e.key);
		if (num >= 1 && num <= 9) {
			const id = watchSet.watching[num - 1];
			if (id) watchSet.setActive(id);
		}
	}
</script>

<svelte:window onkeydown={onKeydown} />

<WatchSetGrid />
