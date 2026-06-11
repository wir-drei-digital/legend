import { apiBase } from './api';

export type SessionStatus = 'starting' | 'running' | 'exited' | 'failed';

export interface Session {
	id: string;
	name: string | null;
	harness_id: string;
	runtime_id: string;
	cwd: string | null;
	status: SessionStatus;
	exit_code: number | null;
	error: string | null;
}

export interface Harness {
	id: string;
	name: string;
	description: string;
	kind: 'terminal' | 'acp' | 'native';
}

const JSONAPI = 'application/vnd.api+json';

interface JsonApiResource {
	id: string;
	attributes: Record<string, unknown>;
}

function toSession(resource: JsonApiResource): Session {
	return { id: resource.id, ...(resource.attributes as Omit<Session, 'id'>) };
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
	if (!res.ok) throw new Error(`creating session failed: ${res.status}`);
	return toSession((await res.json()).data);
}

export async function deleteSession(id: string): Promise<void> {
	const res = await fetch(`${apiBase}/api/sessions/${id}`, {
		method: 'DELETE',
		headers: { Accept: JSONAPI }
	});
	if (!res.ok && res.status !== 204) throw new Error(`deleting session failed: ${res.status}`);
}
