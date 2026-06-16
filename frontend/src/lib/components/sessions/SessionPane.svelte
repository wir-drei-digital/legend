<script lang="ts">
	import Terminal from '$lib/components/Terminal.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import StatusDot from '$lib/components/shell/StatusDot.svelte';
	import StateBadge from '$lib/components/shell/StateBadge.svelte';
	import { watchSet } from '$lib/shell/watchset.svelte';
	import { liveState } from '$lib/shell/sessionState';
	import { identityFor } from '$lib/shell/identities';
	import { relativeTime, basename } from '$lib/shell/format';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { deleteSession, resumeSession, type Session } from '$lib/sessions';

	// `grab` is the grid's pointer-drag starter — fired when the header is pressed.
	let { session, grab }: { session: Session; grab?: (e: PointerEvent) => void } = $props();

	const live = $derived(liveState(session));
	const identity = $derived(identityFor(session.harness_id));
	const active = $derived(watchSet.activeId === session.id);
	const focusedMode = $derived(watchSet.focusedId === session.id);
	const dragging = $derived(watchSet.draggingId === session.id);

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
	let confirmingDelete = $state(false);

	function closeMenu() {
		menuOpen = false;
		confirmingDelete = false;
	}

	/** Suspend: terminate the agent process; the session becomes resumable. */
	function suspend() {
		terminal?.requestStop();
		closeMenu();
	}

	/** Delete: destroy the session entirely and drop its tile. */
	async function remove() {
		closeMenu();
		try {
			await deleteSession(session.id);
		} finally {
			watchSet.evict(session.id);
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
		if (focusedMode) watchSet.restore();
		else watchSet.focus(session.id);
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
	class="flex h-full min-h-0 flex-col bg-app transition-opacity"
	style:opacity={dragging ? 0.45 : 1}
	onpointerdown={() => watchSet.setActive(session.id)}
>
	<!-- header (29px) -->
	<div
		class="flex h-[29px] shrink-0 items-center gap-2 border-b border-hair px-2.5"
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
			<span class="shrink-0 text-[11.5px] font-semibold text-ink-1">
				{session.name || session.harness_id}
			</span>
			<span
				class="shrink-0 font-mono text-[9px] font-bold tracking-[0.04em]"
				style:color="var({identity.colorVar})"
			>
				{identity.tag}
			</span>
			<span class="min-w-0 flex-1 truncate text-[10px] text-ink-3">{summary}</span>
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
			<span class="shrink-0 font-mono text-[9.5px] text-ink-3">{time}</span>
		{/if}

		<!-- per-pane actions menu -->
		<div class="relative shrink-0">
			<button
				type="button"
				onclick={() => (menuOpen = !menuOpen)}
				aria-expanded={menuOpen}
				title="More actions"
				class="grid size-5 place-items-center rounded text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-1"
				class:text-ink-1={menuOpen}
			>
				<Icon name="more" size={14} />
			</button>

			{#if menuOpen}
				<button
					type="button"
					class="fixed inset-0 z-40 cursor-default"
					aria-label="Close menu"
					onclick={closeMenu}
				></button>
				<div
					class="absolute right-0 top-[26px] z-50 w-[150px] overflow-hidden rounded-[10px] border border-hair-strong bg-panel py-1 shadow-[0_18px_44px_-12px_rgba(0,0,0,0.7)]"
					style:animation="lg-rise 0.12s ease-out"
				>
					{#if isLive}
						<button
							type="button"
							onclick={suspend}
							class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] text-ink-2 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-1"
						>
							<Icon name="pause" size={13} class="text-ink-3" />
							Suspend
						</button>
					{:else}
						<button
							type="button"
							onclick={() => {
								void resume();
								closeMenu();
							}}
							class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] text-ink-2 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-1"
						>
							<Icon name="refresh" size={13} class="text-ink-3" />
							{resumeLabel}
						</button>
					{/if}

					<div class="my-1 h-px bg-hair"></div>

					{#if confirmingDelete}
						<button
							type="button"
							onclick={remove}
							class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] font-medium transition-colors hover:bg-[color-mix(in_oklab,var(--red)_16%,transparent)]"
							style:color="var(--red)"
						>
							<Icon name="trash" size={13} />
							Confirm delete
						</button>
					{:else}
						<button
							type="button"
							onclick={() => (confirmingDelete = true)}
							class="flex w-full items-center gap-2 px-2.5 py-[7px] text-left text-[11.5px] transition-colors hover:bg-[color-mix(in_oklab,var(--red)_12%,transparent)]"
							style:color="var(--red)"
						>
							<Icon name="trash" size={13} />
							Delete session
						</button>
					{/if}
				</div>
			{/if}
		</div>

		<button
			type="button"
			onclick={toggleFocus}
			title={focusedMode ? 'Restore grid' : 'Focus pane'}
			class="grid size-5 shrink-0 place-items-center rounded text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-1"
			class:text-brand-hi={focusedMode}
		>
			<Icon name="eye" size={14} />
		</button>
		<button
			type="button"
			onclick={() => watchSet.evict(session.id)}
			title="Close pane"
			class="grid size-5 shrink-0 place-items-center rounded text-ink-3 transition-colors hover:bg-[var(--hover-tint)] hover:text-ink-1"
		>
			<Icon name="close" size={14} />
		</button>
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
				<span class="font-mono text-[10.5px] uppercase tracking-[0.1em]" style:color={live.dotColor}>
					{live.label}
				</span>
				{#if session.error}
					<p class="max-w-[260px] font-mono text-[11px] text-ink-2">{session.error}</p>
				{/if}
				{#if resumeError}
					<p class="max-w-[260px] text-[11px]" style:color="var(--red)">{resumeError}</p>
				{/if}
				<button
					type="button"
					onclick={resume}
					disabled={resuming}
					class="flex items-center gap-1.5 rounded-[9px] border border-hair-strong bg-raised px-3 py-1.5 text-[11.5px] font-medium text-ink-1 transition-colors hover:border-[color-mix(in_oklab,var(--accent-hi)_40%,var(--border-strong))] disabled:opacity-50"
				>
					<Icon name="refresh" size={13} />
					{resuming ? 'Resuming…' : resumeLabel}
				</button>
			</div>
		{/if}
	</div>

</div>
