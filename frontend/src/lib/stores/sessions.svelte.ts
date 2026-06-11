import { listSessions, type Session } from '$lib/sessions';
import { getSocket } from '$lib/socket';
import type { Channel } from 'phoenix';

class SessionsStore {
	sessions = $state<Session[]>([]);
	loaded = $state(false);
	#channel: Channel | undefined;

	async refresh(): Promise<void> {
		try {
			this.sessions = await listSessions();
			this.loaded = true;
		} catch {
			// Backend unreachable; sidebar shows the last known list.
		}
	}

	/** Joins the lobby once; refetches the list whenever the backend says it changed. */
	connect(): void {
		if (this.#channel) return;
		this.#channel = getSocket().channel('sessions:lobby');
		this.#channel.on('changed', () => void this.refresh());
		// 'ok' fires on every (re)join, so a backend restart triggers a refetch
		// of whatever changed while we were disconnected.
		this.#channel.join().receive('ok', () => void this.refresh());
		void this.refresh();
	}
}

export const sessionsStore = new SessionsStore();
