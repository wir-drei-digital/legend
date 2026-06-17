<script lang="ts">
	import { Button } from '$lib/components/ui/button';
	import { sendMessage } from '$lib/messages';
	import { sessionsStore } from '$lib/stores/sessions.svelte';

	// Fixed target (per-session panel) or undefined (timeline picker).
	let { target }: { target?: string } = $props();

	let selected = $state('');
	let draft = $state('');
	let error = $state<string | null>(null);
	let sending = $state(false);

	const sessions = $derived(
		sessionsStore.sessions.filter((s) => s.status === 'running' || s.status === 'starting')
	);
	const to = $derived(target ?? selected);

	async function send() {
		if (!to || !draft.trim() || sending) return;
		sending = true;
		error = null;
		try {
			await sendMessage(to, draft.trim());
			draft = '';
		} catch (e) {
			error = e instanceof Error ? e.message : 'sending failed';
		} finally {
			sending = false;
		}
	}
</script>

<div class="flex flex-col gap-2 border-t border-hair pt-2">
	{#if error}
		<p class="text-meta text-[var(--red)]">{error}</p>
	{/if}
	<div class="flex gap-2">
		{#if !target}
			<select
				bind:value={selected}
				class="h-9 rounded-md border border-hair-strong bg-inset px-2 text-ui text-ink-1 focus:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] focus:outline-none"
			>
				<option value="" disabled>To session…</option>
				{#each sessions as s (s.id)}
					<option value={s.id}>{s.name || s.harness_id}</option>
				{/each}
			</select>
		{/if}
		<input
			bind:value={draft}
			placeholder="Message as human…"
			class="h-9 min-w-0 flex-1 rounded-md border border-hair-strong bg-inset px-2 text-ui text-ink-1 placeholder:text-ink-3 focus:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] focus:outline-none"
			onkeydown={(e) => e.key === 'Enter' && send()}
		/>
		<Button size="sm" onclick={send} disabled={!to || !draft.trim() || sending}>Send</Button>
	</div>
</div>
