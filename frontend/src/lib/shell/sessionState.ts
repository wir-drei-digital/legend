// Maps the backend session lifecycle onto the design system's five live states
// (Running / Needs input / Error / Idle / Done) plus a "needs you" attention bit
// that drives auto-surfacing in the bench and the status bar.

import type { Session } from '$lib/sessions';

export type LiveKind = 'running' | 'needs' | 'error' | 'idle' | 'done';

export interface LiveState {
	kind: LiveKind;
	/** surfaces to the "Needs you" bench group + status-bar notif feed */
	attention: boolean;
	/** tiny right-aligned pane badge */
	flag: 'ASK' | 'ERR' | null;
	/** CSS color for the status dot */
	dotColor: string;
	/** dot pulses for live/transitional states */
	pulse: boolean;
	/** short human label for the pane header / bench tooltip */
	label: string;
}

export function liveState(s: Session): LiveState {
	switch (s.status) {
		case 'failed':
			return mk('error', true, 'ERR', 'var(--red)', false, s.error ? truncate(s.error) : 'error');
		case 'exited':
			return s.exit_code && s.exit_code !== 0
				? mk('error', true, 'ERR', 'var(--red)', false, `exit ${s.exit_code}`)
				: mk('done', false, null, 'var(--text-3)', false, 'done');
		case 'interrupted':
			// Backend restarted under it — it needs you to resume.
			return mk('needs', true, 'ASK', 'var(--amber)', true, 'needs resume');
		case 'starting':
			return mk('running', false, null, 'var(--amber)', true, 'starting');
		case 'provisioning':
			return mk('running', false, null, 'var(--amber)', true, 'provisioning');
		case 'running':
		default:
			return mk('running', false, null, 'var(--green)', true, 'running');
	}
}

function mk(
	kind: LiveKind,
	attention: boolean,
	flag: 'ASK' | 'ERR' | null,
	dotColor: string,
	pulse: boolean,
	label: string
): LiveState {
	return { kind, attention, flag, dotColor, pulse, label };
}

function truncate(s: string, n = 48): string {
	return s.length > n ? s.slice(0, n - 1) + '…' : s;
}

export interface Counts {
	running: number;
	needsYou: number;
	error: number;
	done: number;
}

export function counts(sessions: Session[]): Counts {
	const c: Counts = { running: 0, needsYou: 0, error: 0, done: 0 };
	for (const s of sessions) {
		const st = liveState(s);
		if (st.kind === 'running') c.running++;
		if (st.kind === 'error') c.error++;
		if (st.kind === 'done') c.done++;
		if (st.attention) c.needsYou++;
	}
	return c;
}

export function isRunningLike(s: Session): boolean {
	return s.status === 'running' || s.status === 'starting' || s.status === 'provisioning';
}
