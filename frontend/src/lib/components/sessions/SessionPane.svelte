<script lang="ts">
	import { onMount } from 'svelte';
	import Terminal from '$lib/components/Terminal.svelte';
	import AcpConversation from '$lib/components/sessions/AcpConversation.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import Popover from '$lib/components/shell/Popover.svelte';
	import MenuItem from '$lib/components/shell/MenuItem.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import StateBadge from '$lib/components/shell/StateBadge.svelte';
	import VDiv from '$lib/components/shell/VDiv.svelte';
	import SidePane from '$lib/components/shell/SidePane.svelte';
	import SidePaneSection from '$lib/components/shell/SidePaneSection.svelte';
	import SidePaneField from '$lib/components/shell/SidePaneField.svelte';
	import type { TileLayout } from '$lib/shell/tiling.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { relativeTime, basename } from '$lib/shell/format';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import {
		deleteSession,
		listHarnesses,
		resumeSession,
		setTransport,
		type Harness,
		type Session
	} from '$lib/sessions';

	// `grab` is the grid's pointer-drag starter — fired when the header is pressed.
	// `tileId` is the grid tile this pane occupies — it equals session.id only in
	// the auto Sessions space; custom spaces mint a `tile-N` id, so all LAYOUT ops
	// (active/focus/drag) must key off tileId, never session.id.
	let {
		session,
		tileId,
		grab,
		layout,
		onClose
	}: {
		session: Session;
		tileId: string;
		grab?: (e: PointerEvent) => void;
		layout: TileLayout;
		onClose: () => void;
	} = $props();

	const live = $derived(liveState(session));
	const identity = $derived(identityFor(session.harness_id));
	const active = $derived(layout.activeId === tileId);
	const focusedMode = $derived(layout.focusedId === tileId);
	const dragging = $derived(layout.draggingId === tileId);

	// A session only has a live PTY while running/starting; otherwise the pane
	// shows a resume affordance so a stopped tile is still usable.
	const isLive = $derived(
		session.status === 'running' ||
			session.status === 'starting' ||
			session.status === 'provisioning'
	);
	const resumeLabel = $derived(session.status === 'interrupted' ? 'Resume' : 'Restart');

	let resumeKey = $state(0);
	let resuming = $state(false);
	let resumeError = $state('');
	let switching = $state(false);
	let switchError = $state('');

	// The Composer's queued prompts must outlive the `{#key resumeKey}` remount that a
	// resume or transport toggle triggers. Holding the queue HERE — outside the {#key} —
	// keeps a stable reference across remounts: the re-created Composer re-binds to the
	// same object, so queued prompts survive a transport switch / resume (CC#2).
	const queueState = $state<{ items: string[] }>({ items: [] });

	// There is no global harness store, so fetch the list once and find this
	// session's harness to learn its transports. The toggle only appears when
	// the harness speaks more than one transport.
	let harness = $state<Harness>();
	onMount(async () => {
		try {
			const harnesses = await listHarnesses();
			harness = harnesses.find((h) => h.id === session.harness_id);
		} catch {
			// No toggle if the harness list can't be fetched — the body still renders.
		}
	});
	const canSwitch = $derived((harness?.transports?.length ?? 0) > 1);

	async function switchTransport(t: 'terminal' | 'acp') {
		if (t === session.transport || switching) return;
		switching = true;
		switchError = '';
		try {
			await setTransport(session.id, t);
			// No resumeKey bump: when the switch lands, `session.transport` updates
			// (via the lobby refetch → the session prop) and the {#if} body-swap mounts
			// the new transport's component fresh. Bumping resumeKey here would remount
			// the OLD body (against the not-yet-updated transport) — a wrong-transport flash.
		} catch (e) {
			switchError = e instanceof Error ? e.message : 'switch failed';
		} finally {
			switching = false;
		}
	}

	async function resume() {
		if (resuming) return;
		resuming = true;
		resumeError = '';
		try {
			await resumeSession(session.id);
			// Re-key the terminal so it rejoins and repaints against the fresh PTY.
			resumeKey += 1;
		} catch (e) {
			resumeError = e instanceof Error ? e.message : 'resume failed';
		} finally {
			resuming = false;
		}
	}

	// ---- per-pane actions menu (⋯) ----
	let terminal = $state<ReturnType<typeof Terminal>>();
	let acpView = $state<ReturnType<typeof AcpConversation>>();
	let menuOpen = $state(false);
	let detailsOpen = $state(false);

	/** Suspend: terminate the agent process; the session becomes resumable. */
	function suspend() {
		if (session.transport === 'acp') acpView?.requestStop();
		else terminal?.requestStop();
		menuOpen = false;
	}

	/** Delete: destroy the session entirely and drop its tile. */
	async function remove() {
		menuOpen = false;
		try {
			await deleteSession(session.id);
		} finally {
			onClose();
		}
	}

	const thread = $derived(messagesStore.forSession(session.id));
	const lastMsg = $derived(thread[thread.length - 1]);
	const unread = $derived(messagesStore.unreadCount(session.id));

	// Task summary: latest message → working dir → harness id.
	const summary = $derived(
		lastMsg?.payload?.replace(/\s+/g, ' ').trim() || basename(session.cwd) || session.harness_id
	);
	const time = $derived(relativeTime(lastMsg?.inserted_at));

	// One badge, by priority: error → needs input → new output.
	const badge = $derived(
		live.flag === 'ERR'
			? ({ kind: 'err' } as const)
			: live.flag === 'ASK'
				? ({ kind: 'ask' } as const)
				: unread > 0
					? ({ kind: 'new', count: unread } as const)
					: null
	);

	function toggleFocus() {
		if (focusedMode) layout.restore();
		else layout.focus(tileId);
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="flex h-full min-h-0 flex-col bg-app transition-opacity"
	style:opacity={dragging ? 0.45 : 1}
	onpointerdown={() => layout.setActive(tileId)}
>
	<!-- header -->
	<div
		class="flex h-[var(--h-bar)] shrink-0 items-center gap-2 border-b border-hair px-2.5"
		style:background={active ? 'color-mix(in oklab, var(--accent) 7%, var(--bg-shell))' : 'var(--bg-shell)'}
	>
		<!-- drag handle: press + drag a tile by its header to re-tile the grid -->
		<div
			class="flex min-w-0 flex-1 items-center gap-2 {dragging ? 'cursor-grabbing' : 'cursor-grab'}"
			onpointerdown={(e) => grab?.(e)}
			role="button"
			tabindex="-1"
			title="Drag to re-tile"
		>
			<StatusDot color={live.dotColor} pulse={live.pulse} size={6} />
			<span class="shrink-0 text-ui font-semibold text-ink-1">
				{session.name || session.harness_id}
			</span>
			<span
				class="shrink-0 font-mono text-micro font-bold tracking-[0.04em]"
				style:color="var({identity.colorVar})"
			>
				{identity.tag}
			</span>
			<span class="min-w-0 flex-1 truncate text-meta text-ink-3">{summary}</span>
		</div>

		{#if badge}
			<span class="shrink-0">
				{#if badge.kind === 'new'}
					<StateBadge kind="new" count={badge.count} />
				{:else}
					<StateBadge kind={badge.kind} />
				{/if}
			</span>
		{/if}

		{#if time}
			<span class="shrink-0 font-mono text-micro text-ink-3">{time}</span>
		{/if}

		{#if canSwitch}
			<!-- transport toggle: only when the harness speaks both rich + term -->
			<div class="flex shrink-0 items-center gap-1.5">
				{#if switchError}
					<span class="text-micro" style:color="var(--red)" title={switchError}>
						{switchError}
					</span>
				{/if}
				<div
					class="flex overflow-hidden rounded-[7px] border border-hair-strong text-micro"
				>
					<button
						type="button"
						title="Rich (ACP) conversation"
						disabled={switching}
						class="px-2 py-0.5 font-bold disabled:opacity-50 {session.transport === 'acp'
							? 'bg-brand text-app'
							: 'text-ink-2'}"
						onclick={() => switchTransport('acp')}
					>
						rich
					</button>
					<button
						type="button"
						title="Terminal"
						disabled={switching}
						class="px-2 py-0.5 font-bold disabled:opacity-50 {session.transport === 'terminal'
							? 'bg-brand text-app'
							: 'text-ink-2'}"
						onclick={() => switchTransport('terminal')}
					>
						term
					</button>
				</div>
			</div>
		{/if}

		<VDiv height={18} />

		<!-- per-pane actions: grouped tightly so the cluster reads as one unit -->
		<div class="flex shrink-0 items-center gap-0.5">
			<div class="relative">
				<IconButton
					icon="more"
					size={14}
					box={24}
					title="More actions"
					active={menuOpen}
					onclick={() => (menuOpen = !menuOpen)}
				/>

				<Popover bind:open={menuOpen} class="right-0 top-[28px] w-[150px]">
					{#if isLive}
						<MenuItem icon="pause" onclick={suspend}>Suspend</MenuItem>
					{:else}
						<MenuItem
							icon="refresh"
							onclick={() => {
								void resume();
								menuOpen = false;
							}}
						>
							{resumeLabel}
						</MenuItem>
					{/if}
					<div class="my-1 h-px bg-hair"></div>
					<ConfirmButton
						idleLabel="Delete session"
						confirmLabel="Confirm delete"
						onconfirm={remove}
					/>
				</Popover>
			</div>

			<IconButton
				icon="panel-right"
				size={14}
				box={24}
				title="Details"
				active={detailsOpen}
				tone="accent"
				onclick={() => (detailsOpen = !detailsOpen)}
			/>
			<IconButton
				icon={focusedMode ? 'shrink' : 'expand'}
				size={14}
				box={24}
				title={focusedMode ? 'Restore grid' : 'Maximize pane'}
				active={focusedMode}
				tone="accent"
				onclick={toggleFocus}
			/>
			<IconButton icon="close" size={14} box={24} title="Close pane" onclick={onClose} />
		</div>
	</div>

	<!-- stream (live terminal) + optional in-tile Details -->
	<div class="flex min-h-0 flex-1">
		<div class="relative min-w-0 flex-1 overflow-hidden">
			{#key resumeKey}
				{#if session.transport === 'acp'}
					<AcpConversation bind:this={acpView} sessionId={session.id} {queueState} />
				{:else}
					<Terminal bind:this={terminal} sessionId={session.id} fontSize={11} background="#100d1a" />
				{/if}
			{/key}

			{#if session.transport === 'terminal' && harness?.transports?.includes('acp')}
				<div class="pointer-events-none absolute inset-x-0 bottom-0 flex items-center justify-center px-3 py-1.5">
					<p class="text-micro text-ink-3">
						Sign in to {harness?.name ?? 'the agent'} in the terminal, then
						<button
							type="button"
							class="pointer-events-auto text-micro text-ink-3 underline underline-offset-2 hover:text-ink-2"
							onclick={() => switchTransport('acp')}
						>
							switch to rich
						</button>
						for the structured view.
					</p>
				</div>
			{/if}

			{#if !isLive}
				<!-- Stopped session: keep the pane usable with a resume affordance. -->
				<div
					class="absolute inset-0 flex flex-col items-center justify-center gap-2.5 px-4 text-center"
					style:background="color-mix(in oklab, var(--bg-app) 82%, transparent)"
				>
					<span class="font-mono text-meta uppercase tracking-[0.1em]" style:color={live.dotColor}>
						{live.label}
					</span>
					{#if session.error}
						<p class="max-w-[260px] font-mono text-meta text-ink-2">{session.error}</p>
					{/if}
					{#if resumeError}
						<p class="max-w-[260px] text-meta" style:color="var(--red)">{resumeError}</p>
					{/if}
					<button
						type="button"
						onclick={resume}
						disabled={resuming}
						class="flex items-center gap-1.5 rounded-[9px] border border-hair-strong bg-raised px-3 py-1.5 text-ui font-medium text-ink-1 transition-colors hover:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] disabled:opacity-50"
					>
						<Icon name="refresh" size={13} />
						{resuming ? 'Resuming…' : resumeLabel}
					</button>
				</div>
			{/if}
		</div>

		{#if detailsOpen}
			<div class="w-[260px] shrink-0 border-l border-hair">
				<SidePane title="Details" icon="sessions" onClose={() => (detailsOpen = false)}>
					<SidePaneSection label="Session">
						<SidePaneField label="Name" value={session.name || '—'} />
						<SidePaneField label="Harness" value={session.harness_id} />
						<SidePaneField label="Runtime" value={session.runtime_id ?? 'local'} />
						<SidePaneField label="Directory" value={session.cwd || '—'} />
						<SidePaneField label="Status" value={live.label} />
						{#if session.spawned_by_session_id}
							<SidePaneField label="Spawned by" value={session.spawned_by_session_id} />
						{/if}
					</SidePaneSection>
				</SidePane>
			</div>
		{/if}
	</div>
</div>
