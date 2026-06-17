import type { LayoutSnapshot } from './tiling-core';

export const WORKSPACE_SCHEMA = 1;

export interface SpaceSnapshot {
	id: string;
	name: string;
	auto?: 'sessions';
	rail?: 'library';
	side?: 'library';
	layout: LayoutSnapshot;
	bindings: Array<{ id: string; kind: string; params: Record<string, unknown> }>;
}

export interface WorkspaceSnapshot {
	version: number;
	activeId: string;
	dismissed: string[];
	spaces: SpaceSnapshot[];
}

export interface WorkspacePersistence {
	load(): WorkspaceSnapshot | null;
	save(snap: WorkspaceSnapshot): void;
}

const KEY = 'legend:workspace';

export const localStoragePersistence: WorkspacePersistence = {
	load() {
		if (typeof localStorage === 'undefined') return null;
		try {
			const raw = localStorage.getItem(KEY);
			if (!raw) return null;
			const snap = JSON.parse(raw) as WorkspaceSnapshot;
			if (snap.version !== WORKSPACE_SCHEMA) return null; // tolerant: reset on mismatch
			return snap;
		} catch {
			return null;
		}
	},
	save(snap) {
		if (typeof localStorage === 'undefined') return;
		try {
			localStorage.setItem(KEY, JSON.stringify(snap));
		} catch {
			// non-fatal: quota / disabled storage
		}
	}
};
