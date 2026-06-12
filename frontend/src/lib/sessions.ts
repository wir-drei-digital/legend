import { apiBase } from './api';

export type SessionStatus = 'starting' | 'running' | 'exited' | 'failed' | 'interrupted';

export interface Session {
	id: string;
	name: string | null;
	harness_id: string;
	runtime_id: string;
	cwd: string | null;
	spawned_by_session_id: string | null;
	status: SessionStatus;
	exit_code: number | null;
	error: string | null;
}

export interface HarnessSetup {
	status: 'ok' | 'missing' | 'error' | 'not_applicable';
	summary: string;
	detail: string | null;
	restart_hint: boolean;
}

export interface Harness {
	id: string;
	name: string;
	description: string;
	kind: 'terminal' | 'acp' | 'native';
	resumable: boolean;
	setup: HarnessSetup;
}

const JSONAPI = 'application/vnd.api+json';

interface JsonApiResource {
	id: string;
	attributes: Record<string, unknown>;
}

function toSession(resource: JsonApiResource): Session {
	return { id: resource.id, ...(resource.attributes as Omit<Session, 'id'>) };
}

async function errorMessage(res: Response, fallback: string): Promise<string> {
	try {
		const body = await res.json();
		const detail = body?.errors?.[0]?.detail ?? body?.errors?.[0]?.title;
		return detail ? `${fallback}: ${detail}` : `${fallback}: ${res.status}`;
	} catch {
		return `${fallback}: ${res.status}`;
	}
}

export async function listHarnesses(): Promise<Harness[]> {
	const res = await fetch(`${apiBase}/api/harnesses`);
	if (!res.ok) throw new Error(`listing harnesses failed: ${res.status}`);
	return (await res.json()).data;
}

export async function listSessions(): Promise<Session[]> {
	const res = await fetch(`${apiBase}/api/sessions`, { headers: { Accept: JSONAPI } });
	if (!res.ok) throw new Error(`listing sessions failed: ${res.status}`);
	return (await res.json()).data.map(toSession);
}

export async function createSession(attrs: {
	harness_id: string;
	name?: string;
	cwd?: string;
}): Promise<Session> {
	const res = await fetch(`${apiBase}/api/sessions`, {
		method: 'POST',
		headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
		body: JSON.stringify({ data: { type: 'session', attributes: attrs } })
	});
	if (!res.ok) throw new Error(await errorMessage(res, 'creating session failed'));
	return toSession((await res.json()).data);
}

export async function resumeSession(id: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/sessions/${id}/resume`, {
		method: 'PATCH',
		headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
		body: JSON.stringify({ data: { type: 'session', id, attributes: {} } })
	});
	if (!res.ok) throw new Error(await errorMessage(res, 'resuming session failed'));
}

export async function deleteSession(id: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/sessions/${id}`, {
		method: 'DELETE',
		headers: { Accept: JSONAPI }
	});
	if (!res.ok && res.status !== 204) throw new Error(await errorMessage(res, 'deleting session failed'));
}

export async function applyHarnessSetup(id: string): Promise<HarnessSetup> {
	const res = await fetch(`${apiBase}/api/harnesses/${id}/setup`, { method: 'POST' });
	if (!res.ok) {
		let detail = `${res.status}`;
		try {
			detail = (await res.json()).error ?? detail;
		} catch {
			// keep status code
		}
		throw new Error(`harness setup failed: ${detail}`);
	}
	return (await res.json()).data;
}

// Nag-dismissal is per-UI preference, not server state (spec amendment).
const dismissKey = (id: string) => `legend:harness-setup-dismissed:${id}`;

export function isSetupDismissed(id: string): boolean {
	try {
		return localStorage.getItem(dismissKey(id)) === 'true';
	} catch {
		return false;
	}
}

export function dismissSetup(id: string): void {
	try {
		localStorage.setItem(dismissKey(id), 'true');
	} catch {
		// localStorage unavailable — the settings card remains the affordance
	}
}
