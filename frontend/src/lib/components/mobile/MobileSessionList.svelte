<script lang="ts">
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { relativeTime, mostRecentIso } from '$lib/shell/format';
	import { getDeviceToken, clearDeviceToken } from '$lib/remote/deviceToken';

	let { onOpen }: { onOpen: (id: string) => void } = $props();

	let menuOpen = $state(false);
	const paired = getDeviceToken() !== null;

	function unpair() {
		clearDeviceToken();
		window.location.reload();
	}

	const rows = $derived(
		sessionsStore.sessions.map((s) => ({
			session: s,
			state: liveState(s),
			identity: identityFor(s.harness_id),
			unread: messagesStore.unreadCount(s.id),
			lastActive: mostRecentIso(
				messagesStore.forSession(s.id).at(-1)?.inserted_at,
				s.ended_at,
				s.started_at,
				s.updated_at,
				s.inserted_at
			)
		}))
	);
</script>

<header class="flex h-[52px] shrink-0 items-center justify-between border-b border-hair px-4">
	<span class="text-title font-semibold text-ink-1">Legend</span>
	{#if paired}
		<div class="relative">
			<IconButton icon="gear" size={18} title="Device" active={menuOpen} onclick={() => (menuOpen = !menuOpen)} />
			{#if menuOpen}
				<div class="absolute right-0 top-[36px] z-10 w-[200px] rounded-[10px] border border-hair bg-panel p-1 shadow-lg">
					<button
						type="button"
						onclick={unpair}
						class="w-full rounded-[7px] px-3 py-2 text-left text-ui text-ink-1 active:bg-[var(--hover-tint)]"
					>
						Unpair this device
					</button>
				</div>
			{/if}
		</div>
	{/if}
</header>

<div class="min-h-0 flex-1 overflow-y-auto">
	{#each rows as row (row.session.id)}
		{@const time = relativeTime(row.lastActive)}
		<button
			type="button"
			onclick={() => onOpen(row.session.id)}
			class="flex w-full items-center gap-3 border-b border-hair px-4 py-3 text-left active:bg-[var(--hover-tint)]"
		>
			<StatusDot color={row.state.dotColor} pulse={row.state.pulse} size={7} />
			<div class="flex min-w-0 flex-1 flex-col gap-0.5">
				<div class="flex items-center gap-2">
					<span class="min-w-0 flex-1 truncate text-ui font-medium text-ink-1">
						{row.session.name || row.session.harness_id}
					</span>
					<span
						class="shrink-0 font-mono text-micro font-bold tracking-[0.04em]"
						style:color="var({row.identity.colorVar})"
					>
						{row.identity.tag}
					</span>
				</div>
				<div class="flex items-center gap-2 text-meta text-ink-3">
					<span class="truncate">{row.state.label}</span>
					{#if row.unread > 0}
						<span
							class="shrink-0 rounded-full px-1.5 font-bold"
							style:background="var(--accent)"
							style:color="var(--accent-contrast)"
						>
							{row.unread}
						</span>
					{/if}
					{#if row.state.flag}
						<span
							class="shrink-0 font-mono font-bold"
							style:color={row.state.flag === 'ERR' ? 'var(--red)' : 'var(--amber)'}
						>
							{row.state.flag}
						</span>
					{/if}
					{#if time}<span class="ml-auto shrink-0 font-mono tabular-nums">{time}</span>{/if}
				</div>
			</div>
			<Icon name="chevron-right" size={16} class="shrink-0 text-ink-3" />
		</button>
	{:else}
		<p class="px-4 py-6 text-ui text-ink-3">
			{sessionsStore.loaded ? 'No sessions.' : 'Connecting…'}
		</p>
	{/each}
</div>
