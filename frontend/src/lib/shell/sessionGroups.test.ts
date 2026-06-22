import { describe, it, expect } from 'vitest';
import { groupKey, groupLabel, groupSessions, type GroupableRow } from './sessionGroups';

function row(
	cwd: string | null,
	opts: Partial<{ attention: boolean; kind: string; lastActive: string }> = {}
): GroupableRow {
	return {
		session: { cwd },
		state: { attention: opts.attention ?? false, kind: opts.kind ?? 'idle' },
		lastActive: opts.lastActive
	};
}

describe('groupKey', () => {
	it('uses the cwd as the key', () => {
		expect(groupKey({ cwd: '/Users/x/proj' })).toBe('/Users/x/proj');
	});
	it('maps null and blank to the same sentinel', () => {
		expect(groupKey({ cwd: null })).toBe(groupKey({ cwd: '   ' }));
	});
});

describe('groupLabel', () => {
	it('shows the basename', () => {
		expect(groupLabel('/Users/x/my-proj')).toBe('my-proj');
	});
	it('labels home when the home path is supplied', () => {
		expect(groupLabel('/Users/x', '/Users/x')).toBe('Home');
	});
	it('labels the no-directory bucket', () => {
		expect(groupLabel(groupKey({ cwd: null }))).toBe('No directory');
	});
});

describe('groupSessions', () => {
	it('buckets rows by directory', () => {
		const groups = groupSessions([row('/a'), row('/b'), row('/a')]);
		expect(groups.map((g) => g.key).sort()).toEqual(['/a', '/b']);
		expect(groups.find((g) => g.key === '/a')!.rows).toHaveLength(2);
	});

	it('orders attention groups first, then by recency', () => {
		const groups = groupSessions([
			row('/old', { lastActive: '2020-01-01T00:00:00Z' }),
			row('/recent', { lastActive: '2026-01-01T00:00:00Z' }),
			row('/urgent', { attention: true, lastActive: '2019-01-01T00:00:00Z' })
		]);
		expect(groups.map((g) => g.key)).toEqual(['/urgent', '/recent', '/old']);
	});

	it('sorts within a group: attention, then running, then idle', () => {
		const g = groupSessions([
			row('/a', { kind: 'idle', lastActive: '2026-01-03T00:00:00Z' }),
			row('/a', { kind: 'running', lastActive: '2026-01-02T00:00:00Z' }),
			row('/a', { attention: true, lastActive: '2026-01-01T00:00:00Z' })
		])[0];
		expect(g.rows.map((r) => (r.state.attention ? 'attn' : r.state.kind))).toEqual([
			'attn',
			'running',
			'idle'
		]);
	});

	it('sets fullPath null and the No directory label for the sentinel bucket', () => {
		const g = groupSessions([row(null)])[0];
		expect(g.fullPath).toBeNull();
		expect(g.label).toBe('No directory');
	});
});
