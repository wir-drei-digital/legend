import { describe, expect, it } from 'vitest';
import {
	addColumn,
	removeFrom,
	dropRelative,
	reconcileColumns,
	computeRects,
	unplacedRunning
} from './tiling-core';

describe('addColumn', () => {
	it('appends a new right-hand column', () => {
		expect(addColumn([['a']], 'b')).toEqual([['a'], ['b']]);
	});
});

describe('removeFrom', () => {
	it('drops the id and collapses empty columns', () => {
		expect(removeFrom([['a'], ['b']], 'b')).toEqual([['a']]);
		expect(removeFrom([['a', 'b']], 'a')).toEqual([['b']]);
	});
});

describe('dropRelative', () => {
	const cols = () => [['a'], ['b']];
	it('left inserts a new column before the target column', () => {
		expect(dropRelative(cols(), 'a', 'b', 'left')).toEqual([['a'], ['b']]);
	});
	it('right inserts a new column after the target column', () => {
		expect(dropRelative([['a'], ['b'], ['c']], 'a', 'b', 'right')).toEqual([['b'], ['a'], ['c']]);
	});
	it('top stacks above the target within its column', () => {
		expect(dropRelative([['a'], ['b']], 'a', 'b', 'top')).toEqual([['a', 'b']]);
	});
	it('bottom stacks below the target within its column', () => {
		expect(dropRelative([['a'], ['b']], 'a', 'b', 'bottom')).toEqual([['b', 'a']]);
	});
	it('is a no-op when id === targetId', () => {
		expect(dropRelative([['a']], 'a', 'a', 'left')).toEqual([['a']]);
	});
});

describe('reconcileColumns', () => {
	it('keeps live tiles, drops dead ones, fills empties up to max', () => {
		const out = reconcileColumns([['a'], ['dead']], ['a', 'b', 'c'], new Set(), 6);
		expect(out.flat()).toEqual(['a', 'b', 'c']);
	});
	it('never refills a dismissed id', () => {
		const out = reconcileColumns([], ['a', 'b'], new Set(['b']), 6);
		expect(out.flat()).toEqual(['a']);
	});
	it('respects the max tile cap', () => {
		const out = reconcileColumns([], ['a', 'b', 'c'], new Set(), 2);
		expect(out.flat().length).toBe(2);
	});
});

describe('computeRects', () => {
	it('splits width across two equal columns minus the seam', () => {
		const r = computeRects([['a'], ['b']], [], [], 201, 100, 1);
		expect(r.get('a')).toEqual({ left: 0, top: 0, width: 100, height: 100 });
		expect(r.get('b')).toEqual({ left: 101, top: 0, width: 100, height: 100 });
	});
	it('splits a column height across stacked rows minus the seam', () => {
		const r = computeRects([['a', 'b']], [], [], 100, 201, 1);
		expect(r.get('a')).toEqual({ left: 0, top: 0, width: 100, height: 100 });
		expect(r.get('b')).toEqual({ left: 0, top: 101, width: 100, height: 100 });
	});
	it('honors flex weights', () => {
		const r = computeRects([['a'], ['b']], [3, 1], [], 100, 100, 0);
		expect(r.get('a')!.width).toBe(75);
		expect(r.get('b')!.width).toBe(25);
	});
});

describe('unplacedRunning', () => {
	it('returns running ids not already placed, preserving running order', () => {
		expect(unplacedRunning(['a'], ['a', 'b', 'c'])).toEqual(['b', 'c']);
	});
	it('returns empty when all running are placed', () => {
		expect(unplacedRunning(['a', 'b'], ['a', 'b'])).toEqual([]);
	});
	it('ignores placed ids that are not running', () => {
		expect(unplacedRunning(['x', 'y'], ['a'])).toEqual(['a']);
	});
});
