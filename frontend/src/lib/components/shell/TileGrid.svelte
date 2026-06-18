<script lang="ts">
	import type { Snippet } from 'svelte';
	import type { TileLayout } from '$lib/shell/tiling.svelte';
	import type { DropSide, Rect } from '$lib/shell/tiling-core';
	import { dockDrag } from '$lib/shell/dock-drag.svelte';

	let {
		layout,
		tile,
		empty,
		dragLabel = (id: string) => id,
		minColPx = 160,
		minRowPx = 90,
		onExternalDrop
	}: {
		layout: TileLayout;
		tile: Snippet<[string, (e: PointerEvent) => void]>;
		empty?: Snippet;
		dragLabel?: (id: string) => string;
		minColPx?: number;
		minRowPx?: number;
		onExternalDrop?: (
			payload: import('$lib/shell/dock-drag.svelte').DockDragPayload,
			placement?: { targetId: string; side: DropSide }
		) => void;
	} = $props();

	const SEAM = 1;

	let host = $state<HTMLDivElement>();
	let W = $state(0);
	let H = $state(0);

	// Measure the host so rects are pixel-exact (flex weights → px).
	$effect(() => {
		if (!host) return;
		const ro = new ResizeObserver((entries) => {
			const r = entries[0].contentRect;
			W = r.width;
			H = r.height;
		});
		ro.observe(host);
		return () => ro.disconnect();
	});

	const tiles = $derived(layout.tiles);
	const rects = $derived(W > 0 && H > 0 ? layout.rects(W, H, SEAM) : new Map<string, Rect>());

	const full: Rect = $derived({ left: 0, top: 0, width: W, height: H });
	function rectFor(id: string): Rect {
		if (layout.focusedId === id) return full;
		return rects.get(id) ?? { left: 0, top: 0, width: 0, height: 0 };
	}
	const isHidden = (id: string) => layout.focusedId !== null && layout.focusedId !== id;

	// ---- column / row resize seams (derived from rects + the column tree) ----
	interface Seam {
		kind: 'col' | 'row';
		ci: number;
		ri: number;
		rect: Rect;
	}
	const seams = $derived.by((): Seam[] => {
		const out: Seam[] = [];
		if (layout.focusedId || rects.size === 0) return out;
		layout.columns.forEach((col, ci) => {
			for (let ri = 0; ri < col.length - 1; ri++) {
				const r = rects.get(col[ri]);
				if (r) out.push({ kind: 'row', ci, ri, rect: { left: r.left, top: r.top + r.height, width: r.width, height: SEAM } });
			}
			if (ci < layout.columns.length - 1) {
				const r0 = rects.get(col[0]);
				if (r0) out.push({ kind: 'col', ci, ri: 0, rect: { left: r0.left + r0.width, top: 0, width: SEAM, height: H } });
			}
		});
		return out;
	});

	// ---- drag a tile by its grab handle → re-tile (i3-style directional split) ----
	let ghost = $state<{ x: number; y: number; label: string } | null>(null);
	let drop = $state<{ id: string; side: DropSide } | null>(null);

	function beginDrag(id: string, e: PointerEvent) {
		if (e.button !== 0) return;
		const startX = e.clientX;
		const startY = e.clientY;
		const label = dragLabel(id);
		let active = false;
		const move = (ev: PointerEvent) => {
			if (!active) {
				if (Math.hypot(ev.clientX - startX, ev.clientY - startY) < 5) return;
				active = true;
				layout.startDrag(id);
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
				if (drop) layout.dropRelative(id, drop.id, drop.side);
				else layout.endDrag();
			}
			ghost = null;
			drop = null;
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
		window.addEventListener('pointercancel', up);
	}

	function hitTest(x: number, y: number, draggedId: string): { id: string; side: DropSide } | null {
		if (!host) return null;
		for (const el of host.querySelectorAll<HTMLElement>('[data-tile-id]')) {
			const tid = el.dataset.tileId!;
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

	// External (dock) drag: highlight the i3 zone under the pointer; commit on drop.
	const extDrop = $derived(
		dockDrag.payload && host ? hitTestPoint(dockDrag.x, dockDrag.y) : null
	);
	function hitTestPoint(x: number, y: number): { id: string; side: DropSide } | null {
		return hitTest(x, y, '__none__');
	}
	$effect(() => {
		if (!onExternalDrop) return;
		return dockDrag.setDropTarget((payload, x, y) => {
			if (!host) return;
			const r = host.getBoundingClientRect();
			if (x < r.left || x > r.right || y < r.top || y > r.bottom) return; // dropped outside
			const t = hitTest(x, y, '__none__');
			onExternalDrop(payload, t ? { targetId: t.id, side: t.side } : undefined);
		});
	});

	// ---- resize (flex weights become px during a drag; ratios preserved) ----
	function beginColResize(ci: number, e: PointerEvent) {
		if (e.button !== 0) return;
		e.preventDefault();
		const widths = layout.columns.map((col) => rects.get(col[0])?.width ?? 0);
		layout.setColSizes([...widths]);
		const startX = e.clientX;
		const a = widths[ci];
		const b = widths[ci + 1];
		const move = (ev: PointerEvent) => {
			const dx = Math.max(-(a - minColPx), Math.min(b - minColPx, ev.clientX - startX));
			const next = [...widths];
			next[ci] = a + dx;
			next[ci + 1] = b - dx;
			layout.setColSizes(next);
		};
		endResize(move);
	}

	function beginRowResize(ci: number, ri: number, e: PointerEvent) {
		if (e.button !== 0) return;
		e.preventDefault();
		const heights = layout.columns[ci].map((id) => rects.get(id)?.height ?? 0);
		layout.setRowSizes(ci, [...heights]);
		const startY = e.clientY;
		const a = heights[ri];
		const b = heights[ri + 1];
		const move = (ev: PointerEvent) => {
			const dy = Math.max(-(a - minRowPx), Math.min(b - minRowPx, ev.clientY - startY));
			const next = [...heights];
			next[ri] = a + dy;
			next[ri + 1] = b - dy;
			layout.setRowSizes(ci, next);
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

<div bind:this={host} class="relative h-full w-full overflow-hidden bg-app">
	{#if tiles.length === 0}
		{#if empty}{@render empty()}{/if}
	{:else}
		{#each tiles as id (id)}
			{@const r = rectFor(id)}
			<div
				data-tile-id={id}
				class="absolute overflow-hidden {layout.draggingId
					? ''
					: 'transition-[transform,width,height] duration-150 ease-out'}"
				style:transform="translate({r.left}px, {r.top}px)"
				style:width="{r.width}px"
				style:height="{r.height}px"
				style:visibility={isHidden(id) ? 'hidden' : 'visible'}
				style:pointer-events={isHidden(id) ? 'none' : 'auto'}
				style:z-index={layout.focusedId === id ? 10 : 1}
			>
				{@render tile(id, (e) => beginDrag(id, e))}
				{#if drop && drop.id === id}
					<div
						class="pointer-events-none absolute z-30 {sideClass[drop.side]}"
						style:background="var(--accent-soft)"
						style:outline="2px solid var(--accent)"
						style:outline-offset="-2px"
					></div>
				{/if}
				{#if extDrop && extDrop.id === id}
					<div
						class="pointer-events-none absolute z-30 {sideClass[extDrop.side]}"
						style:background="var(--accent-soft)"
						style:outline="2px solid var(--accent)"
						style:outline-offset="-2px"
					></div>
				{/if}
			</div>
		{/each}

		<!-- resize seams (above tiles) -->
		{#each seams as s (s.kind + s.ci + '-' + s.ri)}
			<div
				class="absolute z-20 {s.kind === 'col' ? 'cursor-ew-resize' : 'cursor-ns-resize'}"
				style:left="{s.rect.left}px"
				style:top="{s.rect.top}px"
				style:width="{s.rect.width}px"
				style:height="{s.rect.height}px"
				role="separator"
				aria-orientation={s.kind === 'col' ? 'vertical' : 'horizontal'}
				tabindex="-1"
				onpointerdown={(e) =>
					s.kind === 'col' ? beginColResize(s.ci, e) : beginRowResize(s.ci, s.ri, e)}
			>
				<div
					class="absolute bg-hair {s.kind === 'col'
						? 'inset-y-0 left-1/2 w-px -translate-x-1/2'
						: 'inset-x-0 top-1/2 h-px -translate-y-1/2'}"
				></div>
				<div
					class="absolute {s.kind === 'col' ? 'inset-y-0 -inset-x-[3px]' : 'inset-x-0 -inset-y-[3px]'}"
				></div>
			</div>
		{/each}

		{#if layout.draggingId && ghost}
			<div
				class="pointer-events-none fixed z-[100] flex -translate-x-1/2 -translate-y-[150%] items-center gap-1.5 rounded-[8px] border border-hair-strong bg-raised px-2.5 py-1 text-ui text-ink-1 shadow-drag"
				style:left="{ghost.x}px"
				style:top="{ghost.y}px"
			>
				{ghost.label}
			</div>
		{/if}
	{/if}

	{#if dockDrag.payload}
		<div
			class="pointer-events-none fixed z-[100] flex -translate-x-1/2 -translate-y-[150%] items-center gap-1.5 rounded-[8px] border border-hair-strong bg-raised px-2.5 py-1 text-ui text-ink-1 shadow-drag"
			style:left="{dockDrag.x}px"
			style:top="{dockDrag.y}px"
		>
			{dockDrag.payload.label}
		</div>
	{/if}
</div>
