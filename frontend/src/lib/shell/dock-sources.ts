import type { Component } from 'svelte';
import type { IconName } from '$lib/components/shell/Icon.svelte';
import FilesSource from '$lib/components/shell/sources/FilesSource.svelte';
import SessionsSource from '$lib/components/shell/sources/SessionsSource.svelte';

export interface DockSourceProps {
	open: boolean;
	ontoggle: () => void;
}

export interface DockSource {
	id: string;
	label: string;
	icon: IconName;
	component: Component<DockSourceProps>;
}

export const DOCK_SOURCES: DockSource[] = [
	{ id: 'sessions', label: 'Sessions', icon: 'sessions', component: SessionsSource },
	{ id: 'files', label: 'Files', icon: 'folder', component: FilesSource }
];
