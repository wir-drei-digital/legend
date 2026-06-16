<script lang="ts">
	import SessionPane from './SessionPane.svelte';
	import Icon from '$lib/components/shell/Icon.svelte';
	import { watchSet, type DropSide } from '$lib/shell/watchset.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';

	const byId = $derived(new Map(sessionsStore.sessions.map((s) => [s.id, s])));
	const columns = $derived(watchSet.columns);
	const tileCount = $derived(watchSet.tileCount);
	const focusedSession = $derived(
		watchSet.focusedId ? (byId.get(watchSet.focusedId) ?? null) : null
	);

	let gridEl = $state<HTMLDivElement>();
	let ghost = $state<{ x: number; y: number; label: string } | null>(null);
	let drop = $state<{ id: string; side: DropSide } | null>(null);

	// ---- pane drag → re-tile (mouse-driven, i3-style directional split) ----
	function beginDrag(id: string, e: PointerEvent) {
		if (e.button !== 0) return;
		const startX = e.clientX;
		const startY = e.clientY;
		const label = byId.get(id)?.name || byId.get(id)?.harness_id || 'session';
		let active = false;

		const move = (ev: PointerEvent) => {
			if (!active) {
				if (Math.hypot(ev.clientX - startX, ev.clientY - startY) < 5) return;
				active = true;
				watchSet.startDrag(id);
				document.body.style.userSelect = 'none';
			}
			ghost = { x: ev.clientX, y: ev.clientY, label };
			drop = hitTest(ev.clientX, ev.clientY, id);
		};
		const up = () => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			window.removeEventListener('pointercancel', up);
			document.body.style.userSelect = '';
			if (active) {
				if (drop) watchSet.dropRelative(id, drop.id, drop.side);
				else watchSet.endDrag();
			}
			ghost = null;
			drop = null;
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
		window.addEventListener('pointercancel', up);
	}

	function hitTest(x: number, y: number, draggedId: string): { id: string; side: DropSide } | null {
		if (!gridEl) return null;
		for (const el of gridEl.querySelectorAll<HTMLElement>('[data-pane-id]')) {
			const tid = el.dataset.paneId!;
			if (tid === draggedId) continue;
			const r = el.getBoundingClientRect();
			if (x < r.left || x > r.right || y < r.top || y > r.bottom) continue;
			const rx = (x - r.left) / r.width - 0.5;
			const ry = (y - r.top) / r.height - 0.5;
			const side: DropSide =
				Math.abs(rx) > Math.abs(ry) ? (rx < 0 ? 'left' : 'right') : ry < 0 ? 'top' : 'bottom';
			return { id: tid, side };
		}
		return null;
	}

	// ---- resize seams ----
	function beginColResize(ci: number, e: PointerEvent) {
		if (e.button !== 0 || !gridEl) return;
		e.preventDefault();
		const widths = [...gridEl.querySelectorAll<HTMLElement>('[data-col]')].map(
			(el) => el.getBoundingClientRect().width
		);
		watchSet.setColSizes([...widths]);
		const startX = e.clientX;
		const a = widths[ci];
		const b = widths[ci + 1];
		const MIN = 160;
		const move = (ev: PointerEvent) => {
			const dx = Math.max(-(a - MIN), Math.min(b - MIN, ev.clientX - startX));
			const next = [...widths];
			next[ci] = a + dx;
			next[ci + 1] = b - dx;
			watchSet.setColSizes(next);
		};
		endResize(move);
	}

	function beginRowResize(ci: number, ri: number, e: PointerEvent) {
		if (e.button !== 0 || !gridEl) return;
		e.preventDefault();
		const colEl = gridEl.querySelector<HTMLElement>(`[data-col="${ci}"]`);
		if (!colEl) return;
		const heights = [...colEl.querySelectorAll<HTMLElement>('[data-pane-id]')].map(
			(el) => el.getBoundingClientRect().height
		);
		watchSet.setRowSizes(ci, [...heights]);
		const startY = e.clientY;
		const a = heights[ri];
		const b = heights[ri + 1];
		const MIN = 90;
		const move = (ev: PointerEvent) => {
			const dy = Math.max(-(a - MIN), Math.min(b - MIN, ev.clientY - startY));
			const next = [...heights];
			next[ri] = a + dy;
			next[ri + 1] = b - dy;
			watchSet.setRowSizes(ci, next);
		};
		endResize(move);
	}

	function endResize(move: (ev: PointerEvent) => void) {
		document.body.style.userSelect = 'none';
		const up = () => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			document.body.style.userSelect = '';
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
	}

	const sideClass: Record<DropSide, string> = {
		left: 'left-0 top-0 bottom-0 w-1/2',
		right: 'right-0 top-0 bottom-0 w-1/2',
		top: 'left-0 right-0 top-0 h-1/2',
		bottom: 'left-0 right-0 bottom-0 h-1/2'
	};
</script>

{#if tileCount === 0}
	<div class="flex h-full flex-col items-center justify-center gap-3 px-6 text-center">
		<div class="grid size-12 place-items-center rounded-2xl border border-hair bg-panel text-ink-3">
			<Icon name="sessions" size={22} />
		</div>
		{#if sessionsStore.sessions.length === 0}
			<p class="text-[13px] text-ink-2">No sessions running.</p>
			<p class="max-w-[260px] text-[11.5px] text-ink-3">
				Use <span class="text-ink-2">New session</span> in the toolbar to launch an agent, or
				<kbd class="rounded border border-hair bg-inset px-1 font-mono text-[10px]">⌘K</kbd> to jump
				to another view.
			</p>
		{:else}
			<p class="text-[13px] text-ink-2">No tiles in the grid.</p>
			<p class="max-w-[260px] text-[11.5px] text-ink-3">
				Promote a session from the bench on the left to watch it here.
			</p>
		{/if}
	</div>
{:else if focusedSession}
	<div class="h-full w-full overflow-hidden">
		<SessionPane session={focusedSession} grab={(e) => beginDrag(focusedSession.id, e)} />
	</div>
{:else}
	<div bind:this={gridEl} class="relative h-full w-full overflow-hidden bg-app">
		<div class="flex h-full w-full">
			{#each columns as col, ci (col[0])}
				<div data-col={ci} class="relative flex min-w-0 flex-col bg-app" style:flex="{watchSet.colFlex(ci)} 1 0">
					{#each col as id, ri (id)}
						{@const s = byId.get(id)}
						{#if s}
							<div data-pane-id={id} class="relative min-h-0 min-w-0 overflow-hidden" style:flex="{watchSet.rowFlex(ci, ri)} 1 0">
								<SessionPane session={s} grab={(e) => beginDrag(id, e)} />
								{#if drop && drop.id === id}
									<div
										class="pointer-events-none absolute z-30 {sideClass[drop.side]}"
										style:background="var(--accent-soft)"
										style:outline="2px solid var(--accent)"
										style:outline-offset="-2px"
									></div>
								{/if}
							</div>
							{#if ri < col.length - 1}
								<!-- row resize seam -->
								<div class="relative z-20 h-px shrink-0 bg-hair">
									<div
										class="absolute inset-x-0 -inset-y-[3px] cursor-ns-resize"
										role="separator"
										aria-orientation="horizontal"
										tabindex="-1"
										onpointerdown={(e) => beginRowResize(ci, ri, e)}
									></div>
								</div>
							{/if}
						{/if}
					{/each}
				</div>
				{#if ci < columns.length - 1}
					<!-- column resize seam -->
					<div class="relative z-20 w-px shrink-0 bg-hair">
						<div
							class="absolute inset-y-0 -inset-x-[3px] cursor-ew-resize"
							role="separator"
							aria-orientation="vertical"
							tabindex="-1"
							onpointerdown={(e) => beginColResize(ci, e)}
						></div>
					</div>
				{/if}
			{/each}
		</div>

		{#if watchSet.draggingId && ghost}
			<div
				class="pointer-events-none fixed z-[100] flex -translate-x-1/2 -translate-y-[150%] items-center gap-1.5 rounded-[8px] border border-hair-strong bg-raised px-2.5 py-1 text-[11.5px] text-ink-1 shadow-[0_12px_30px_-8px_rgba(0,0,0,0.7)]"
				style:left="{ghost.x}px"
				style:top="{ghost.y}px"
			>
				<Icon name="sessions" size={12} class="text-brand-hi" />
				{ghost.label}
			</div>
		{/if}
	</div>
{/if}
