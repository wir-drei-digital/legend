<script lang="ts">
	import Terminal from '$lib/components/Terminal.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import IconButton from '$lib/components/shell/IconButton.svelte';
	import Popover from '$lib/components/shell/Popover.svelte';
	import MenuItem from '$lib/components/shell/MenuItem.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import StateBadge from '$lib/components/shell/StateBadge.svelte';
	import type { TileLayout } from '$lib/shell/tiling.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { relativeTime, basename } from '$lib/shell/format';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { deleteSession, resumeSession, type Session } from '$lib/sessions';

	// `grab` is the grid's pointer-drag starter — fired when the header is pressed.
	let {
		session,
		grab,
		layout,
		onClose
	}: {
		session: Session;
		grab?: (e: PointerEvent) => void;
		layout: TileLayout;
		onClose: () => void;
	} = $props();

	const live = $derived(liveState(session));
	const identity = $derived(identityFor(session.harness_id));
	const active = $derived(layout.activeId === session.id);
	const focusedMode = $derived(layout.focusedId === session.id);
	const dragging = $derived(layout.draggingId === session.id);

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
	let menuOpen = $state(false);

	/** Suspend: terminate the agent process; the session becomes resumable. */
	function suspend() {
		terminal?.requestStop();
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
		else layout.focus(session.id);
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="flex h-full min-h-0 flex-col bg-app transition-opacity"
	style:opacity={dragging ? 0.45 : 1}
	onpointerdown={() => layout.setActive(session.id)}
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

		<!-- per-pane actions menu -->
		<div class="relative shrink-0">
			<IconButton
				icon="more"
				size={14}
				box={20}
				title="More actions"
				active={menuOpen}
				onclick={() => (menuOpen = !menuOpen)}
			/>

			<Popover bind:open={menuOpen} class="right-0 top-[26px] w-[150px]">
				{#if isLive}
					<MenuItem icon="pause" onclick={suspend}>Suspend</MenuItem>
				{:else}
					<MenuItem icon="refresh" onclick={() => { void resume(); menuOpen = false; }}>
						{resumeLabel}
					</MenuItem>
				{/if}
				<div class="my-1 h-px bg-hair"></div>
				<ConfirmButton idleLabel="Delete session" confirmLabel="Confirm delete" onconfirm={remove} />
			</Popover>
		</div>

		<IconButton
			icon="eye"
			size={14}
			box={20}
			title={focusedMode ? 'Restore grid' : 'Focus pane'}
			active={focusedMode}
			tone="accent"
			onclick={toggleFocus}
		/>
		<IconButton
			icon="close"
			size={14}
			box={20}
			title="Close pane"
			onclick={onClose}
		/>
	</div>

	<!-- stream (live terminal) -->
	<div class="relative min-h-0 flex-1 overflow-hidden">
		{#key resumeKey}
			<Terminal bind:this={terminal} sessionId={session.id} fontSize={11} background="#100d1a" />
		{/key}

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

</div>
