/** Compact relative time, e.g. "now", "3m", "2h", "4d". */
export function relativeTime(iso: string | null | undefined): string {
	if (!iso) return '';
	const then = new Date(iso).getTime();
	if (Number.isNaN(then)) return '';
	const secs = Math.max(0, Math.floor((Date.now() - then) / 1000));
	if (secs < 5) return 'now';
	if (secs < 60) return `${secs}s`;
	const mins = Math.floor(secs / 60);
	if (mins < 60) return `${mins}m`;
	const hrs = Math.floor(mins / 60);
	if (hrs < 24) return `${hrs}h`;
	return `${Math.floor(hrs / 24)}d`;
}

/** The most recent of several ISO timestamps (ignores blanks/invalid). */
export function mostRecentIso(...isos: (string | null | undefined)[]): string | undefined {
	let best: string | undefined;
	let bestMs = -Infinity;
	for (const iso of isos) {
		if (!iso) continue;
		const ms = new Date(iso).getTime();
		if (!Number.isNaN(ms) && ms > bestMs) {
			bestMs = ms;
			best = iso;
		}
	}
	return best;
}

/** Last path segment of a working directory, for terse task summaries. */
export function basename(path: string | null | undefined): string {
	if (!path) return '';
	const parts = path.replace(/\/+$/, '').split('/');
	return parts[parts.length - 1] || path;
}

/** Compact byte size, e.g. "0 B", "4 KB", "1.6 MB". */
export function formatBytes(n: number): string {
	if (!Number.isFinite(n) || n <= 0) return '0 B';
	const units = ['B', 'KB', 'MB', 'GB', 'TB'];
	const i = Math.min(units.length - 1, Math.floor(Math.log(n) / Math.log(1024)));
	const v = n / 1024 ** i;
	const s = i === 0 ? String(v) : String(Math.round(v * 10) / 10);
	return `${s} ${units[i]}`;
}
