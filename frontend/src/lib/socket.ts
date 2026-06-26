import { Socket } from 'phoenix';
import { PUBLIC_WS_URL } from '$env/static/public';
import { getDeviceToken } from './remote/deviceToken';
import { apiFetch } from './api';

let socket: Socket | undefined;
let authProbeTimer: ReturnType<typeof setTimeout> | undefined;

/**
 * Lazily-connected singleton Phoenix socket. When a device token exists it is
 * sent as the `token` connect param (verified by UserSocket.connect/3); loopback
 * has no token and connects anonymously. The token is read once at first
 * connect — pairing navigates the page so a fresh load re-inits.
 *
 * Remote devices only: a revoked/invalid token makes connect/3 return :error, so
 * the socket would retry forever and the UI would show stale data. On a socket
 * error we debounce-probe a device-gated HTTP endpoint; apiFetch's 401 handler
 * clears the token and routes to /pair. A transient network error makes the probe
 * throw (not 401), so a valid token is never cleared. Loopback skips all of this.
 */
export function getSocket(): Socket {
	if (!socket) {
		const token = getDeviceToken();
		socket = new Socket(PUBLIC_WS_URL || '/socket', token ? { params: { token } } : {});

		if (token) {
			socket.onError(() => {
				clearTimeout(authProbeTimer);
				authProbeTimer = setTimeout(() => {
					void apiFetch('/api/devices').catch(() => {});
				}, 3000);
			});
		}

		socket.connect();
	}
	return socket;
}
