<script lang="ts">
	import { goto } from '$app/navigation';
	import Icon from './Icon.svelte';
	import VDiv from './VDiv.svelte';
	import NotifChip from './NotifChip.svelte';
	import StatusDot from './StatusDot.svelte';
	import BudgetMeter from './BudgetMeter.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { counts, liveState } from '$lib/shell/sessionState';
	import { watchSet } from '$lib/shell/watchset.svelte';

	const c = $derived(counts(sessionsStore.sessions));

	// Most urgent off-grid attention items become notif chips.
	const notifs = $derived(
		sessionsStore.sessions
			.map((s) => ({ s, st: liveState(s) }))
			.filter(({ st }) => st.attention)
			.slice(0, 2)
	);
	const moreNotifs = $derived(
		sessionsStore.sessions.filter((s) => liveState(s).attention).length - notifs.length
	);

	const unreadMsgs = $derived(messagesStore.messages.filter((m) => !m.read_at).length);
	const hasBell = $derived(c.needsYou > 0 || unreadMsgs > 0);
	const connected = $derived(sessionsStore.loaded);
</script>

<footer
	class="flex h-[46px] shrink-0 items-center gap-3 border-t border-hair bg-shell px-3.5 font-mono text-[11.5px]"
>
	<!-- LEFT — global state -->
	<div class="flex shrink-0 items-center gap-2.5">
		<span class="flex items-center gap-1.5" style:color="var(--green)">
			<StatusDot color="var(--green)" pulse={c.running > 0} />
			{c.running} running
		</span>
		{#if c.needsYou > 0}
			<span style:color="var(--amber)">{c.needsYou} need you</span>
		{/if}
		{#if c.error > 0}
			<span style:color="var(--red)">{c.error} error</span>
		{/if}
	</div>

	<VDiv />

	<!-- MIDDLE — live notifications -->
	<div class="flex min-w-0 flex-1 items-center gap-2">
		<button type="button" class="relative shrink-0 p-1 text-ink-2 hover:text-ink-1" title="Notifications">
			<Icon name="bell" size={15} />
			{#if hasBell}
				<span class="absolute right-0.5 top-0.5 size-[5px] rounded-full" style:background="var(--red)"></span>
			{/if}
		</button>
		{#each notifs as { s, st } (s.id)}
			<NotifChip
				harnessId={s.harness_id}
				label={s.name || s.harness_id}
				detail={st.label}
				flag={st.flag ?? 'ASK'}
				onclick={() => watchSet.promote(s.id)}
			/>
		{/each}
		{#if moreNotifs > 0}
			<span class="shrink-0 text-ink-3">+{moreNotifs}</span>
		{/if}
	</div>

	<!-- RIGHT — account / system -->
	<div class="flex shrink-0 items-center gap-3">
		<span class="flex items-center gap-1.5" style:color={connected ? 'var(--text-2)' : 'var(--text-3)'}>
			<Icon name="desktop" size={14} />
			{connected ? 'running locally' : 'connecting…'}
		</span>

		<!-- Cost tracking not wired yet: renders nothing until given spent/total. -->
		<BudgetMeter />

		<VDiv />

		<button
			type="button"
			onclick={() => goto('/settings')}
			class="p-1 text-ink-3 transition-colors hover:text-ink-1"
			title="Settings"
		>
			<Icon name="gear" size={15} />
		</button>
	</div>
</footer>
