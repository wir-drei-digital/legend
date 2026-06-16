<script lang="ts">
	import AgentAvatar from './AgentAvatar.svelte';

	// A status-bar notification: agent avatar + label + the urgent flag.
	let {
		harnessId,
		label,
		detail,
		flag,
		onclick
	}: {
		harnessId: string;
		label: string;
		detail?: string;
		flag: 'ASK' | 'ERR';
		onclick?: () => void;
	} = $props();

	const flagColor = $derived(flag === 'ERR' ? 'var(--red)' : 'var(--amber)');
</script>

<button
	type="button"
	{onclick}
	class="group/notif flex h-[26px] shrink-0 items-center gap-1.5 rounded-full border border-hair bg-raised pl-1 pr-2 transition-colors hover:border-hair-strong"
>
	<AgentAvatar {harnessId} size={18} soft />
	<span class="font-mono text-[11px] text-ink-1">{label}</span>
	{#if detail}
		<span class="max-w-[120px] truncate font-mono text-[11px] text-ink-3">· {detail}</span>
	{/if}
	<span class="font-mono text-[9px] font-bold tracking-[0.08em]" style:color={flagColor}>{flag}</span>
</button>
