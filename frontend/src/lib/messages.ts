import { apiFetch } from './api';

export type MessageKind = 'message' | 'handoff' | 'system';

export interface Message {
	id: string;
	from_session_id: string | null;
	from_label: string;
	to_session_id: string;
	kind: MessageKind;
	payload: string;
	read_at: string | null;
	inserted_at: string;
}

const JSONAPI = 'application/vnd.api+json';

/** Human composer: POSTs the send_as_human action (sender is always the human). */
export async function sendMessage(to_session_id: string, payload: string): Promise<void> {
	const res = await apiFetch('/api/messages', {
		method: 'POST',
		headers: { 'Content-Type': JSONAPI, Accept: JSONAPI },
		body: JSON.stringify({ data: { type: 'message', attributes: { to_session_id, payload } } })
	});
	if (!res.ok) {
		let detail = `${res.status}`;
		try {
			const body = await res.json();
			detail = body?.errors?.[0]?.detail ?? body?.errors?.[0]?.title ?? detail;
		} catch {
			// keep status code
		}
		throw new Error(`sending message failed: ${detail}`);
	}
}
