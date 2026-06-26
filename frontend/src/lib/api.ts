import { PUBLIC_API_URL } from '$env/static/public';
import { getDeviceToken, clearDeviceToken } from './remote/deviceToken';

export const apiBase = PUBLIC_API_URL || '';

/** Bearer header when a device token is present; empty on loopback (desktop/local). */
export function authHeaders(): Record<string, string> {
	const token = getDeviceToken();
	return token ? { Authorization: `Bearer ${token}` } : {};
}

/**
 * fetch wrapper for the device-gated REST API: prepends the base, attaches the
 * device bearer token, and on a 401 clears the now-invalid token and sends the
 * user to /pair to re-pair. Loopback never 401s, so the desktop path is
 * unaffected; the /pair page is exempt to avoid a redirect loop.
 */
export async function apiFetch(path: string, init: RequestInit = {}): Promise<Response> {
	const res = await fetch(`${apiBase}${path}`, {
		...init,
		headers: { ...authHeaders(), ...(init.headers as Record<string, string> | undefined) }
	});

	if (res.status === 401 && typeof window !== 'undefined' && window.location.pathname !== '/pair') {
		clearDeviceToken();
		window.location.href = '/pair';
	}

	return res;
}

export async function getHealth(): Promise<{ status: string }> {
	const res = await fetch(`${apiBase}/api/health`);
	if (!res.ok) throw new Error(`health check failed: ${res.status}`);
	return res.json();
}
