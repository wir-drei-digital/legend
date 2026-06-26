import { Socket } from 'phoenix';
import { PUBLIC_WS_URL } from '$env/static/public';
import { getDeviceToken } from './remote/deviceToken';

let socket: Socket | undefined;

/**
 * Lazily-connected singleton Phoenix socket. When a device token exists it is
 * sent as the `token` connect param (verified by UserSocket.connect/3); loopback
 * has no token and connects anonymously, exactly as before. The token is read
 * once at first connect — pairing navigates the page so a fresh load re-inits.
 */
export function getSocket(): Socket {
	if (!socket) {
		const token = getDeviceToken();
		socket = new Socket(PUBLIC_WS_URL || '/socket', token ? { params: { token } } : {});
		socket.connect();
	}
	return socket;
}
