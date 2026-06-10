import { Socket } from 'phoenix';
import { PUBLIC_WS_URL } from '$env/static/public';

let socket: Socket | undefined;

/** Lazily-connected singleton Phoenix socket. */
export function getSocket(): Socket {
	if (!socket) {
		socket = new Socket(PUBLIC_WS_URL || '/socket');
		socket.connect();
	}
	return socket;
}
