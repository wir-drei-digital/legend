<script lang="ts">
	import { onMount } from 'svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import Terminal from '$lib/components/Terminal.svelte';
	import AcpConversation from '$lib/components/sessions/AcpConversation.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { listHarnesses, resumeSession, setTransport, type Harness } from '$lib/sessions';

	let { sessionId, onBack }: { sessionId: string; onBack: () => void } = $props();

	const session = $derived(sessionsStore.sessions.find((s) => s.id === sessionId) ?? null);
	const live = $derived(session ? liveState(session) : null);
	const identity = $derived(session ? identityFor(session.harness_id) : null);
	const running = $derived(
		session
			? session.status === 'running' ||
					session.status === 'starting' ||
					session.status === 'provisioning'
			: false
	);

	// queueState lives here (no {#key} remount on mobile) and threads to AcpConversation.
	const queueState = $state<{ items: string[] }>({ items: [] });

	let harness = $state<Harness>();
	onMount(async () => {
		try {
			const hs = await listHarnesses();
			harness = hs.find((h) => h.id === session?.harness_id);
		} catch {
			// no toggle if the harness list can't be fetched
		}
	});
	const canSwitch = $derived((harness?.transports?.length ?? 0) > 1);

	let switching = $state(false);
	async function switchTransport(t: 'terminal' | 'acp') {
		if (!session || t === session.transport || switching) return;
		switching = true;
		try {
			await setTransport(session.id, t);
		} catch {
			// stays put; the lobby refetch reflects the truth
		} finally {
			switching = false;
		}
	}

	let resuming = $state(false);
	async function resume() {
		if (!session || resuming) return;
		resuming = true;
		try {
			await resumeSession(session.id);
		} catch {
			// stays stopped
		} finally {
			resuming = false;
		}
	}
</script>

<header class="flex h-[52px] shrink-0 items-center gap-2 border-b border-hair px-2">
	<button
		type="button"
		onclick={onBack}
		title="Back"
		class="grid h-8 w-8 shrink-0 place-items-center rounded-[7px] text-ink-2 active:bg-[var(--hover-tint)]"
	>
		<Icon name="chevron-right" size={20} class="rotate-180" />
	</button>

	{#if session && live && identity}
		<StatusDot color={live.dotColor} pulse={live.pulse} size={7} />
		<span class="min-w-0 flex-1 truncate text-ui font-semibold text-ink-1">
			{session.name || session.harness_id}
		</span>
		<span class="shrink-0 font-mono text-micro font-bold" style:color="var({identity.colorVar})">
			{identity.tag}
		</span>
		{#if canSwitch}
			<div class="flex shrink-0 overflow-hidden rounded-[7px] border border-hair-strong text-micro">
				<button
					type="button"
					disabled={switching}
					class="px-2 py-1 font-bold disabled:opacity-50 {session.transport === 'acp'
						? 'bg-brand text-app'
						: 'text-ink-2'}"
					onclick={() => switchTransport('acp')}
				>
					rich
				</button>
				<button
					type="button"
					disabled={switching}
					class="px-2 py-1 font-bold disabled:opacity-50 {session.transport === 'terminal'
						? 'bg-brand text-app'
						: 'text-ink-2'}"
					onclick={() => switchTransport('terminal')}
				>
					term
				</button>
			</div>
		{/if}
	{:else}
		<span class="flex-1 text-ui text-ink-3">Session unavailable</span>
	{/if}
</header>

<div class="relative min-h-0 flex-1 overflow-hidden">
	{#if session}
		{#if session.transport === 'acp'}
			<AcpConversation sessionId={session.id} {queueState} />
		{:else}
			<Terminal sessionId={session.id} fontSize={13} background="#100d1a" />
		{/if}

		{#if !running}
			<div
				class="absolute inset-0 flex flex-col items-center justify-center gap-3 px-6 text-center"
				style:background="color-mix(in oklab, var(--bg-app) 82%, transparent)"
			>
				<span class="font-mono text-meta uppercase tracking-[0.1em]" style:color={live?.dotColor}>
					{live?.label}
				</span>
				<button
					type="button"
					onclick={resume}
					disabled={resuming}
					class="flex items-center gap-1.5 rounded-[9px] border border-hair-strong bg-raised px-4 py-2 text-ui font-medium text-ink-1 disabled:opacity-50"
				>
					<Icon name="refresh" size={14} />
					{resuming ? 'Resuming…' : session.status === 'interrupted' ? 'Resume' : 'Restart'}
				</button>
			</div>
		{/if}
	{/if}
</div>
