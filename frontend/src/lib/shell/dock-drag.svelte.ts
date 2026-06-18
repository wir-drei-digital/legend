// A drag that starts in the Dock and drops into the active TileGrid. The dock
// row calls start(); the grid registers a drop target and reads payload/x/y to
// render drop zones. Pointer-based to match TileGrid's intra-grid re-tiling.
export interface DockDragPayload {
	kind: string;
	params: Record<string, unknown>;
	label: string;
}

class DockDrag {
	payload = $state<DockDragPayload | null>(null);
	x = $state(0);
	y = $state(0);
	#drop: ((p: DockDragPayload, x: number, y: number) => void) | null = null;

	/** The active grid registers itself; returns an unregister fn. */
	setDropTarget(fn: (p: DockDragPayload, x: number, y: number) => void): () => void {
		this.#drop = fn;
		return () => {
			if (this.#drop === fn) this.#drop = null;
		};
	}

	start(e: PointerEvent, payload: DockDragPayload): void {
		if (e.button !== 0) return;
		const sx = e.clientX;
		const sy = e.clientY;
		let active = false;
		const move = (ev: PointerEvent) => {
			if (!active) {
				if (Math.hypot(ev.clientX - sx, ev.clientY - sy) < 5) return;
				active = true;
				document.body.style.userSelect = 'none';
				this.payload = payload;
			}
			this.x = ev.clientX;
			this.y = ev.clientY;
		};
		const up = (ev: PointerEvent) => {
			window.removeEventListener('pointermove', move);
			window.removeEventListener('pointerup', up);
			window.removeEventListener('pointercancel', up);
			document.body.style.userSelect = '';
			if (active && this.payload) this.#drop?.(this.payload, ev.clientX, ev.clientY);
			this.payload = null;
		};
		window.addEventListener('pointermove', move);
		window.addEventListener('pointerup', up);
		window.addEventListener('pointercancel', up);
	}
}

export const dockDrag = new DockDrag();
