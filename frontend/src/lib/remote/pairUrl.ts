/**
 * Pure helpers for the device-pairing QR URL. Extracted from RemoteAccessSection
 * so the backend-port derivation (the Tauri-vs-web subtlety) is unit-testable.
 */

/**
 * The backend's port for the pairing URL.
 *
 * Desktop bakes `apiBase = http://localhost:4807` but renders inside a
 * `tauri://localhost` window (no port), so `window.location.port` is empty there
 * — parse the port from `apiBase` instead. The web release leaves `apiBase` blank
 * and serves the SPA same-origin, so `window.location.port` is the right backend
 * port.
 */
export function backendPort(apiBase: string, windowPort: string): string {
	try {
		if (apiBase) return new URL(apiBase).port;
	} catch {
		/* apiBase isn't an absolute URL — fall through to the window port */
	}
	return windowPort;
}

/**
 * Build the pairing URL the QR encodes: `http://<host>[:<port>]/pair?code=…`.
 * Returns '' when host or code is missing. TLS is deferred → http.
 */
export function buildPairUrl(
	host: string,
	code: string,
	apiBase: string,
	windowPort: string
): string {
	const h = host.trim();
	if (!h || !code) return '';
	const port = backendPort(apiBase, windowPort);
	const authority = port ? `${h}:${port}` : h;
	return `http://${authority}/pair?code=${encodeURIComponent(code)}`;
}
