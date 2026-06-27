import { apiFetch } from '$lib/api';

async function fail(res: Response, fallback: string): Promise<never> {
	let detail = `${res.status}`;
	try {
		detail = (await res.json()).error ?? detail;
	} catch {
		// keep status code
	}
	throw new Error(`${fallback}: ${detail}`);
}

export interface PairResult {
	token: string;
	device: { id: string; name: string | null };
}

/** Redeem a pairing code (public, pre-auth). The instance mints a device token. */
export async function redeemPairCode(code: string, name?: string): Promise<PairResult> {
	const res = await apiFetch('/api/pair', {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ code, name })
	});
	if (!res.ok) await fail(res, 'pairing failed');
	return res.json();
}

export type RemoteAccessMode = 'direct' | 'via_relay';

export interface RemoteAccess {
	enabled: boolean;
	mode: RemoteAccessMode;
	host: string | null;
	relay_url: string | null;
	relay_handle: string | null;
	relay_secret: string | null;
}

export interface Device {
	id: string;
	name: string | null;
	paired_at: string | null;
	last_seen_at: string | null;
	revoked_at: string | null;
}

export interface AuditEvent {
	id: string;
	device_id: string | null;
	session_id: string | null;
	action: string;
	at: string;
}

export interface RemoteInterfaces {
	candidates: string[];
	suggested: string | null;
}

/** This machine's non-loopback IPv4 addresses; `suggested` flags the Tailscale CGNAT one. */
export async function getRemoteInterfaces(): Promise<RemoteInterfaces> {
	const res = await apiFetch('/api/settings/remote-access/interfaces');
	if (!res.ok) await fail(res, 'detecting interfaces failed');
	return (await res.json()).data;
}

export async function getRemoteAccess(): Promise<RemoteAccess> {
	const res = await apiFetch('/api/settings/remote-access');
	if (!res.ok) await fail(res, 'loading remote access failed');
	return (await res.json()).data;
}

export type RemoteAccessUpdate = {
	enabled: boolean;
	mode?: RemoteAccessMode;
	host?: string | null;
	relay_url?: string | null;
	relay_handle?: string | null;
	relay_secret?: string | null;
};

export async function setRemoteAccess(
	payload: RemoteAccessUpdate
): Promise<{ data: RemoteAccess; restart_required?: boolean }> {
	const res = await apiFetch('/api/settings/remote-access', {
		method: 'PUT',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify(payload)
	});
	if (!res.ok) await fail(res, 'saving remote access failed');
	return res.json();
}

export async function listDevices(): Promise<Device[]> {
	const res = await apiFetch('/api/devices');
	if (!res.ok) await fail(res, 'listing devices failed');
	return (await res.json()).data;
}

export async function generatePairCode(): Promise<{ code: string; expires_at: string }> {
	const res = await apiFetch('/api/devices/pair-code', { method: 'POST' });
	if (!res.ok) await fail(res, 'generating pairing code failed');
	return res.json();
}

export async function revokeDevice(id: string): Promise<void> {
	const res = await apiFetch(`/api/devices/${id}`, { method: 'DELETE' });
	if (!res.ok) await fail(res, 'revoking device failed');
}

export async function listAudit(): Promise<AuditEvent[]> {
	const res = await apiFetch('/api/devices/audit');
	if (!res.ok) await fail(res, 'loading audit failed');
	return (await res.json()).data;
}
