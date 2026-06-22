// Groups session rows by working directory for the session list. Pure (no runes,
// no stores) so it is unit-testable; `SessionsSource` passes its existing `Row`
// view-model in and renders the returned groups. The single place the
// "what is a project group" rule lives — a future workspace label or shared-
// sandbox id slots in behind groupKey/groupLabel without touching the list UI.

// Sentinel for sessions with no cwd (legacy rows predating the home default):
// keeps them in one deterministic bucket instead of one group each.
const NO_DIR = '__no_dir__';

export interface GroupableRow {
	session: { cwd: string | null };
	state: { attention: boolean; kind: string };
	lastActive: string | undefined;
}

export interface Group<T> {
	key: string;
	label: string;
	/** full path for the header tooltip; null for the no-directory bucket */
	fullPath: string | null;
	rows: T[];
	hasAttention: boolean;
	/** epoch ms of the most-recent row activity; 0 when none */
	lastActive: number;
}

export function groupKey(session: { cwd: string | null }): string {
	const c = session.cwd?.trim();
	return c ? c : NO_DIR;
}

export function groupLabel(key: string, home?: string): string {
	if (key === NO_DIR) return 'No directory';
	if (home && key === home) return 'Home';
	const seg = key.replace(/\/+$/, '').split('/').pop();
	return seg || key;
}

// Within-group order mirrors the old flat list: attention first, then running,
// then idle; recency breaks ties.
function rank(r: GroupableRow): number {
	return r.state.attention ? 0 : r.state.kind === 'running' ? 1 : 2;
}

function ms(iso: string | undefined): number {
	return iso ? new Date(iso).getTime() : 0;
}

export function groupSessions<T extends GroupableRow>(rows: T[]): Group<T>[] {
	const buckets = new Map<string, T[]>();
	for (const r of rows) {
		const k = groupKey(r.session);
		const list = buckets.get(k);
		if (list) list.push(r);
		else buckets.set(k, [r]);
	}

	const groups: Group<T>[] = [];
	for (const [key, list] of buckets) {
		list.sort((a, b) => rank(a) - rank(b) || ms(b.lastActive) - ms(a.lastActive));
		groups.push({
			key,
			label: groupLabel(key),
			fullPath: key === NO_DIR ? null : key,
			rows: list,
			hasAttention: list.some((r) => r.state.attention),
			lastActive: list.reduce((max, r) => Math.max(max, ms(r.lastActive)), 0)
		});
	}

	// Group order: any group needing attention first, then most-recently-active.
	groups.sort(
		(a, b) => Number(b.hasAttention) - Number(a.hasAttention) || b.lastActive - a.lastActive
	);
	return groups;
}
