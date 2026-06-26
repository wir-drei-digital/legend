// The remote device's bearer credential — a Phoenix.Token string minted by
// POST /api/pair. Persisted in localStorage. Loopback (desktop / local browser)
// never holds one; absence means "trusted by loopback or not yet paired".
const KEY = 'legend.device_token';

export function getDeviceToken(): string | null {
	try {
		return localStorage.getItem(KEY);
	} catch {
		return null;
	}
}

export function setDeviceToken(token: string): void {
	try {
		localStorage.setItem(KEY, token);
	} catch {
		// localStorage unavailable — pairing can't persist; the caller surfaces it.
	}
}

export function clearDeviceToken(): void {
	try {
		localStorage.removeItem(KEY);
	} catch {
		// non-fatal
	}
}
