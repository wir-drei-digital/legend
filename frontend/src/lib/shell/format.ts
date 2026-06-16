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

/** Last path segment of a working directory, for terse task summaries. */
export function basename(path: string | null | undefined): string {
	if (!path) return '';
	const parts = path.replace(/\/+$/, '').split('/');
	return parts[parts.length - 1] || path;
}
