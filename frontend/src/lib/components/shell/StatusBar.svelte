<script lang="ts">
	import { onMount } from 'svelte';
	import { shell } from '$lib/shell/shell.svelte';
	import Icon from './Icon.svelte';
	import VDiv from './VDiv.svelte';
	import Popover from './Popover.svelte';
	import NotifChip from './NotifChip.svelte';
	import StatusDot from './StatusDot.svelte';
	import BudgetMeter from './BudgetMeter.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';
	import { workspaceStore } from '$lib/shell/workspace.svelte';
	import { counts, liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';

	const c = $derived(counts(sessionsStore.sessions));
	const connected = $derived(sessionsStore.loaded);

	// Notifications now only surface sessions that need you AND aren't already
	// on-screen in the active space — no point nagging about what you can see.
	const notifs = $derived(
		sessionsStore.sessions
			.map((s) => ({ s, st: liveState(s) }))
			.filter(({ s, st }) => st.attention && !workspaceStore.isSessionVisible(s.id))
	);
	const hasBell = $derived(notifs.length > 0);

	let notifOpen = $state(false);

	// Open the session into the ACTIVE space (like the dock) so it becomes visible
	// right where you are — which also clears it from this notif list.
	function openNotif(s: { id: string; name: string | null; harness_id: string }) {
		workspaceStore.openSurface('session', { sessionId: s.id, name: s.name || s.harness_id });
		notifOpen = false;
	}

	// ---- OS (desktop) notifications --------------------------------------
	// Opt-in + permission-gated. We fire once per attention episode for sessions
	// that aren't visible; leaving attention re-arms a session for next time.
	let osPermission = $state<NotificationPermission | 'unsupported'>('unsupported');
	let osEnabled = $state(false);
	const osSupported = $derived(osPermission !== 'unsupported');

	onMount(() => {
		if (typeof Notification !== 'undefined') {
			osPermission = Notification.permission;
			try {
				osEnabled = localStorage.getItem('legend:os-notify') === 'true';
			} catch {
				/* localStorage unavailable */
			}
		}
	});

	function persistOsEnabled() {
		try {
			localStorage.setItem('legend:os-notify', String(osEnabled));
		} catch {
			/* non-fatal */
		}
	}

	async function enableOsNotify() {
		if (typeof Notification === 'undefined') return;
		const p = await Notification.requestPermission();
		osPermission = p;
		if (p === 'granted') {
			osEnabled = true;
			persistOsEnabled();
		}
	}

	function toggleOsNotify() {
		osEnabled = !osEnabled;
		persistOsEnabled();
	}

	// Track which sessions we've already fired for this episode. Primed on first
	// run so pre-existing attention sessions don't burst-notify on page load.
	const fired = new Set<string>();
	let primed = false;
	$effect(() => {
		const enabled = osEnabled;
		const perm = osPermission;
		const list = notifs;
		const live = new Set(list.map((n) => n.s.id));
		for (const id of [...fired]) if (!live.has(id)) fired.delete(id);
		if (!primed) {
			primed = true;
			for (const n of list) fired.add(n.s.id);
			return;
		}
		if (!enabled || perm !== 'granted' || typeof Notification === 'undefined') return;
		for (const { s, st } of list) {
			if (fired.has(s.id)) continue;
			fired.add(s.id);
			try {
				const n = new Notification(s.name || identityFor(s.harness_id).label, {
					body: st.label,
					tag: `legend-session-${s.id}`
				});
				n.onclick = () => {
					window.focus();
					openNotif(s);
				};
			} catch {
				/* notification construction can throw in some webviews */
			}
		}
	});
</script>

<footer
	class="flex h-[28px] shrink-0 items-center gap-2.5 border-t border-hair bg-shell px-3 font-mono text-ui"
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

	<div class="min-w-0 flex-1"></div>

	<!-- RIGHT — account / system -->
	<div class="flex shrink-0 items-center gap-3">
		<span
			class="flex items-center gap-1.5"
			style:color={connected ? 'var(--text-2)' : 'var(--text-3)'}
		>
			<Icon name="desktop" size={14} />
			{connected ? 'running locally' : 'connecting…'}
		</span>

		<!-- Cost tracking not wired yet: renders nothing until given spent/total. -->
		<BudgetMeter />

		<VDiv height={14} />

		<!-- Notifications: bell + popover, sat right next to Settings -->
		<div class="relative">
			<button
				type="button"
				onclick={() => (notifOpen = !notifOpen)}
				class="relative grid size-[22px] place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-1"
				style:color={notifOpen ? 'var(--text-1)' : undefined}
				title="Notifications"
				aria-expanded={notifOpen}
			>
				<Icon name="bell" size={15} />
				{#if hasBell}
					<span
						class="absolute right-1 top-1 size-[5px] rounded-full"
						style:background="var(--red)"
					></span>
				{/if}
			</button>

			<Popover bind:open={notifOpen} class="bottom-[32px] right-0 w-[268px]">
				<div class="flex items-center justify-between border-b border-hair px-3 py-2">
					<span class="text-ui font-semibold text-ink-1">Notifications</span>
					{#if notifs.length}
						<span class="font-mono text-micro text-ink-3">{notifs.length}</span>
					{/if}
				</div>

				<div class="max-h-[40vh] overflow-y-auto p-2">
					{#if notifs.length}
						<div class="flex flex-col gap-1.5">
							{#each notifs as { s, st } (s.id)}
								<NotifChip
									harnessId={s.harness_id}
									label={s.name || s.harness_id}
									detail={st.label}
									flag={st.flag ?? 'ASK'}
									onclick={() => openNotif(s)}
								/>
							{/each}
						</div>
					{:else}
						<p class="px-1 py-3 text-center text-meta text-ink-3">You're all caught up.</p>
					{/if}
				</div>

				<!-- Desktop notifications opt-in -->
				{#if osSupported}
					<div class="border-t border-hair px-3 py-2">
						{#if osPermission === 'granted'}
							<label class="flex cursor-pointer items-center justify-between gap-2">
								<span class="text-meta text-ink-2">Desktop notifications</span>
								<input
									type="checkbox"
									checked={osEnabled}
									onchange={toggleOsNotify}
									class="size-3.5 accent-[var(--accent)]"
								/>
							</label>
						{:else if osPermission === 'denied'}
							<p class="text-micro text-ink-3">
								Desktop notifications are blocked in your browser settings.
							</p>
						{:else}
							<button
								type="button"
								onclick={enableOsNotify}
								class="text-meta text-brand-hi hover:underline"
							>
								Enable desktop notifications
							</button>
						{/if}
					</div>
				{/if}
			</Popover>
		</div>

		<button
			type="button"
			onclick={() => shell.openSettings()}
			class="grid size-[22px] place-items-center rounded-md text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-1"
			title="Settings"
		>
			<Icon name="gear" size={15} />
		</button>
	</div>
</footer>
