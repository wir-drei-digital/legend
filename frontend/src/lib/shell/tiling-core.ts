// Pure windowing-tree logic. No runes, no DOM, no Svelte — fully unit-testable.
// `columns` is left→right; each column is a top→bottom stack of opaque tile ids.

export type DropSide = 'left' | 'right' | 'top' | 'bottom';

export interface Rect {
	left: number;
	top: number;
	width: number;
	height: number;
}

export interface LayoutSnapshot {
	columns: string[][];
	colSizes: number[];
	rowSizes: number[][];
	focusedId: string | null;
	activeId: string | null;
}

export function cloneColumns(cols: string[][]): string[][] {
	return cols.map((c) => [...c]);
}

/** Append `id` as a new right-hand column. */
export function addColumn(cols: string[][], id: string): string[][] {
	return [...cloneColumns(cols), [id]];
}

/** Remove `id` everywhere; drop any column left empty. */
export function removeFrom(cols: string[][], id: string): string[][] {
	return cols.map((c) => c.filter((x) => x !== id)).filter((c) => c.length > 0);
}

/**
 * Re-tile `id` relative to `targetId`. left/right insert a new column beside the
 * target's column; top/bottom split the target's column above/below the target.
 * Reference-based: remove `id` first, then locate the target so removal can't
 * shift it out from under us.
 */
export function dropRelative(
	cols: string[][],
	id: string,
	targetId: string,
	side: DropSide
): string[][] {
	if (id === targetId) return cloneColumns(cols);
	const next = removeFrom(cols, id);
	const ci = next.findIndex((c) => c.includes(targetId));
	if (ci < 0) {
		next.push([id]);
	} else if (side === 'left' || side === 'right') {
		next.splice(side === 'left' ? ci : ci + 1, 0, [id]);
	} else {
		const col = next[ci];
		const ri = col.indexOf(targetId);
		col.splice(side === 'top' ? ri : ri + 1, 0, id);
	}
	return next.filter((c) => c.length > 0);
}

/**
 * Reconcile the column tree against live `candidates`: keep tiles still live (in
 * place), drop tiles no longer live, then append new candidates (in order) up to
 * `max`, skipping any `dismissed` id.
 */
export function reconcileColumns(
	cols: string[][],
	candidates: string[],
	dismissed: Set<string>,
	max: number
): string[][] {
	const live = new Set(candidates);
	const kept = cols.map((c) => c.filter((id) => live.has(id))).filter((c) => c.length > 0);
	const present = new Set(kept.flat());
	let count = present.size;
	for (const id of candidates) {
		if (count >= max) break;
		if (present.has(id) || dismissed.has(id)) continue;
		kept.push([id]);
		present.add(id);
		count++;
	}
	return kept;
}

/**
 * Map each tile id to its pixel rect. Distributes `width` across columns by their
 * flex weight (`colSizes[ci] ?? 1`) minus inter-column seams, then each column's
 * `height` across its rows by weight (`rowSizes[ci][ri] ?? 1`) minus row seams.
 */
export function computeRects(
	columns: string[][],
	colSizes: number[],
	rowSizes: number[][],
	width: number,
	height: number,
	seam: number
): Map<string, Rect> {
	const out = new Map<string, Rect>();
	const nCols = columns.length;
	if (nCols === 0) return out;

	const colWeights = columns.map((_, ci) => colSizes[ci] ?? 1);
	const colWeightSum = colWeights.reduce((a, b) => a + b, 0) || 1;
	const availW = width - seam * (nCols - 1);

	let x = 0;
	columns.forEach((col, ci) => {
		const colW = (availW * colWeights[ci]) / colWeightSum;
		const nRows = col.length;
		const rowWeights = col.map((_, ri) => rowSizes[ci]?.[ri] ?? 1);
		const rowWeightSum = rowWeights.reduce((a, b) => a + b, 0) || 1;
		const availH = height - seam * (nRows - 1);

		let y = 0;
		col.forEach((id, ri) => {
			const rowH = (availH * rowWeights[ri]) / rowWeightSum;
			out.set(id, { left: x, top: y, width: colW, height: rowH });
			y += rowH + seam;
		});
		x += colW + seam;
	});
	return out;
}
