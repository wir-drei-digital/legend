<script lang="ts">
	import { onMount } from 'svelte';
	import { Terminal } from '@xterm/xterm';
	import { FitAddon } from '@xterm/addon-fit';
	import '@xterm/xterm/css/xterm.css';
	import { getSocket } from '$lib/socket';
	import type { Channel } from 'phoenix';
	import type { SessionStatus } from '$lib/sessions';

	interface JoinReply {
		status: SessionStatus;
		buffer: string;
		exit_code: number | null;
		error: string | null;
	}

	let {
		sessionId,
		onstatus,
		fontSize = 13,
		background = '#100d1a'
	}: {
		sessionId: string;
		onstatus?: (status: SessionStatus, exitCode: number | null, error: string | null) => void;
		fontSize?: number;
		background?: string;
	} = $props();

	let container: HTMLDivElement;
	let channel: Channel | undefined;

	/** Ask the backend to terminate the agent process (graceful, then SIGKILL). */
	export function requestStop(): void {
		channel?.push('stop', {});
	}

	function b64ToBytes(b64: string): Uint8Array {
		const bin = atob(b64);
		const bytes = new Uint8Array(bin.length);
		for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
		return bytes;
	}

	onMount(() => {
		const term = new Terminal({
			cursorBlink: true,
			fontFamily: "'Geist Mono Variable', ui-monospace, SFMono-Regular, Menlo, monospace",
			fontSize,
			lineHeight: 1.2,
			theme: { background }
		});
		const fit = new FitAddon();
		term.loadAddon(fit);
		term.open(container);
		fit.fit();

		const chan = getSocket().channel(`session:${sessionId}`);
		channel = chan;

		// Replaying scrollback makes xterm.js answer any device/color queries
		// (e.g. Hermes' OSC 11 background probe) buried in it — answers the app
		// stopped waiting for long ago. Mute input during the replay write so
		// they never reach the PTY as keystrokes.
		let replaying = false;
		term.onData((data) => {
			if (!replaying) chan.push('input', { data });
		});
		term.onResize(({ cols, rows }) => chan.push('resize', { cols, rows }));

		chan.on('output', ({ data }: { data: string }) => term.write(b64ToBytes(data)));
		chan.on('exit', ({ exit_code }: { exit_code: number | null }) =>
			onstatus?.('exited', exit_code, null)
		);
		chan.on('status', ({ status }: { status: SessionStatus }) => onstatus?.(status, null, null));

		let joined = false;

		chan
			.join()
			.receive('ok', (reply: JoinReply) => {
				// phoenix re-fires this hook on every socket rejoin: re-sync status
				// and size each time, but write the scrollback snapshot only once.
				if (!joined && reply.buffer) {
					replaying = true;
					term.write(b64ToBytes(reply.buffer), () => (replaying = false));
				}
				joined = true;
				onstatus?.(reply.status, reply.exit_code, reply.error);
				chan.push('resize', { cols: term.cols, rows: term.rows });
				term.focus();
			})
			.receive('error', () => onstatus?.('failed', null, 'could not join session'));

		const observer = new ResizeObserver(() => fit.fit());
		observer.observe(container);

		return () => {
			observer.disconnect();
			chan.leave();
			term.dispose();
			channel = undefined;
		};
	});
</script>

<div bind:this={container} class="h-full w-full" style:background></div>
