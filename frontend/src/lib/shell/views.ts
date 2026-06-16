// The Spaces switcher is the whole navigation footprint. Views are list items,
// not pixels on an edge — adding one costs zero canvas (design system §3).
//
// A view is fully self-describing: besides its label/icon/route it can declare
// the body chrome the shell renders for it — a `bench` rail, a per-view
// `toolbar`, a dynamic `sub` line and a chip `count`. The shell knows nothing
// about any specific view; it just renders what the active view declares. This
// is the reusable <LegendView> contract: a new feature ships a view entry plus
// its own bench/toolbar components and slots straight in.

import type { Component } from 'svelte';
import type { IconName } from '$lib/components/shell/Icon.svelte';
import SessionBench from '$lib/components/sessions/SessionBench.svelte';
import SessionsToolbar from '$lib/components/sessions/SessionsToolbar.svelte';
import { sessionsStore } from '$lib/stores/sessions.svelte';
import { messagesStore } from '$lib/stores/messages.svelte';

export interface ViewDef {
	id: string;
	label: string;
	/** route, or null for views not yet built (rendered as "soon") */
	href: string | null;
	icon: IconName;
	soon?: boolean;
	defaultPinned?: boolean;
	/** optional left rail rendered in the body row */
	bench?: Component;
	/** optional per-view toolbar rendered in the top bar */
	toolbar?: Component;
	/** dynamic sub line under the switcher chip */
	sub?: () => string;
	/** count shown on the switcher chip */
	count?: () => number | undefined;
}

function unreadMessages(): number {
	return messagesStore.messages.filter((m) => !m.read_at).length;
}

export const VIEWS: ViewDef[] = [
	{
		id: 'sessions',
		label: 'Sessions',
		href: '/',
		icon: 'sessions',
		defaultPinned: true,
		bench: SessionBench,
		toolbar: SessionsToolbar,
		count: () => sessionsStore.sessions.length || undefined
	},
	{
		id: 'library',
		label: 'Library',
		href: '/library',
		icon: 'folder',
		defaultPinned: true,
		sub: () => 'shared knowledge, skills & artifacts'
	},
	{
		id: 'messages',
		label: 'Messages',
		href: '/messages',
		icon: 'message',
		defaultPinned: true,
		sub: () => 'agent ↔ agent signal bus',
		count: () => unreadMessages() || undefined
	},
	{
		id: 'settings',
		label: 'Settings',
		href: '/settings',
		icon: 'gear',
		sub: () => 'workspace & harness integrations'
	}
];

const BY_ID = new Map(VIEWS.map((v) => [v.id, v]));

export function viewById(id: string): ViewDef | undefined {
	return BY_ID.get(id);
}

/** Which view a pathname belongs to (drives the switcher chip + active row). */
export function sectionForPath(pathname: string): string {
	if (pathname === '/' || pathname.startsWith('/sessions')) return 'sessions';
	if (pathname.startsWith('/library')) return 'library';
	if (pathname.startsWith('/messages')) return 'messages';
	if (pathname.startsWith('/settings')) return 'settings';
	return 'sessions';
}
