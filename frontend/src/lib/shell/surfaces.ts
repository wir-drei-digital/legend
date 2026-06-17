import type { Component } from 'svelte';
import type { IconName } from '$lib/components/shell/Icon.svelte';
import SessionSurface from '$lib/components/surfaces/SessionSurface.svelte';
import FileSurface from '$lib/components/library/FileSurface.svelte';
import MessagesSurface from '$lib/components/surfaces/MessagesSurface.svelte';

export interface SurfaceDef {
	kind: string;
	title: (params: Record<string, unknown>) => string;
	icon: IconName;
	dragLabel?: (params: Record<string, unknown>) => string;
	/** stable identity for dedupe ("focus existing instead of duplicate") */
	key?: (params: Record<string, unknown>) => string;
	component: Component<{ tileId: string; params: Record<string, unknown>; grab?: (e: PointerEvent) => void }>;
}

export const SURFACES: Record<string, SurfaceDef> = {
	session: {
		kind: 'session',
		title: (p) => (p.name as string) || 'session',
		icon: 'sessions',
		dragLabel: (p) => (p.name as string) || 'session',
		key: (p) => `session:${p.sessionId}`,
		component: SessionSurface
	},
	file: {
		kind: 'file',
		title: (p) => ((p.path as string) ?? 'file').split('/').at(-1) ?? 'file',
		icon: 'file',
		dragLabel: (p) => ((p.path as string) ?? 'file').split('/').at(-1) ?? 'file',
		key: (p) => `file:${p.path}`,
		component: FileSurface
	},
	messages: {
		kind: 'messages',
		title: () => 'Messages',
		icon: 'message',
		key: () => 'messages',
		component: MessagesSurface
	}
};
