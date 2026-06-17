<script lang="ts">
	import { onMount } from 'svelte';
	import type { Snippet } from 'svelte';

	let {
		rail,
		primary,
		side,
		sideOpen = $bindable(true),
		sideWidth = $bindable(320),
		railWidth = 178,
		storageKey
	}: {
		rail: Snippet;
		primary: Snippet;
		side: Snippet;
		sideOpen?: boolean;
		sideWidth?: number;
		railWidth?: number;
		storageKey?: string;
	} = $props();

	const MIN = 240;
	let hydrated = $state(false);

	function clampWidth(w: number): number {
		const max = Math.round(window.innerWidth * 0.4);
		return Math.max(MIN, Math.min(max, w));
	}

	onMount(() => {
		if (storageKey) {
			const raw = localStorage.getItem(storageKey);
			if (raw) {
				try {
					const v = JSON.parse(raw);
					if (typeof v.width === 'number') sideWidth = clampWidth(v.width);
					if (typeof v.open === 'boolean') sideOpen = v.open;
				} catch {
					// ignore a corrupt persisted value
				}
			}
		}
		hydrated = true;
	});

	// Persist only after hydration so we never clobber storage with defaults.
	$effect(() => {
		if (!storageKey || !hydrated) return;
		localStorage.setItem(storageKey, JSON.stringify({ width: sideWidth, open: sideOpen }));
	});

	// Drag the seam (left edge of the side region): dragging left widens the side.
	function beginResize(e: PointerEvent) {
		if (e.button !== 0) return;
		e.preventDefault();
		const startX = e.clientX;
		const startW = sideWidth;
		document.body.style.userSelect = 'none';
		const move = (ev: PointerEvent) => {
			sideWidth = clampWidth(startW + (startX - ev.clientX));
		};
		const up = () => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			window.removeEventListener('pointercancel', up);
			document.body.style.userSelect = '';
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
		window.addEventListener('pointercancel', up);
	}
</script>

<div class="flex h-full w-full overflow-hidden">
	<!-- rail -->
	<div
		class="flex shrink-0 flex-col overflow-hidden border-r border-hair bg-shell"
		style:width="{railWidth}px"
	>
		{@render rail()}
	</div>

	<!-- primary -->
	<div class="flex min-w-0 flex-1 flex-col overflow-hidden bg-app">
		{@render primary()}
	</div>

	<!-- side (with resize seam) -->
	{#if sideOpen}
		<div class="relative z-20 w-px shrink-0 bg-hair">
			<div
				class="absolute inset-y-0 -inset-x-[3px] cursor-ew-resize"
				role="separator"
				aria-orientation="vertical"
				tabindex="-1"
				onpointerdown={beginResize}
			></div>
		</div>
		<div class="flex shrink-0 flex-col overflow-hidden bg-shell" style:width="{sideWidth}px">
			{@render side()}
		</div>
	{/if}
</div>
