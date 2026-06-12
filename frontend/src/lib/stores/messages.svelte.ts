import type { Message } from '$lib/messages';
import { getSocket } from '$lib/socket';
import type { Channel } from 'phoenix';

class MessagesStore {
	messages = $state<Message[]>([]);
	loaded = $state(false);
	#channel: Channel | undefined;

	/** Joins the timeline once; the join reply replaces the list, pushes append. */
	connect(): void {
		if (this.#channel) return;
		this.#channel = getSocket().channel('signals:timeline');
		this.#channel.on('message', (m: Message) => {
			this.messages = [...this.messages, m];
		});
		this.#channel.on('read', ({ ids }: { session_id: string; ids: string[] }) => {
			const read = new Set(ids);
			this.messages = this.messages.map((m) =>
				read.has(m.id) ? { ...m, read_at: m.read_at ?? new Date().toISOString() } : m
			);
		});
		// 'ok' fires on every (re)join, replacing the list — a backend restart
		// resyncs whatever we missed.
		this.#channel.join().receive('ok', (reply: { messages: Message[] }) => {
			this.messages = reply.messages;
			this.loaded = true;
		});
	}

	unreadCount(sessionId: string): number {
		return this.messages.filter((m) => m.to_session_id === sessionId && !m.read_at).length;
	}

	forSession(sessionId: string): Message[] {
		return this.messages.filter(
			(m) => m.from_session_id === sessionId || m.to_session_id === sessionId
		);
	}
}

export const messagesStore = new MessagesStore();
