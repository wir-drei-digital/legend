// Shell-wide UI state: the Spaces overlay and the user's pinned views.
// Pinned order persists to localStorage so favourites survive reloads.

import { VIEWS } from './views';

const PIN_KEY = 'legend:pinned-views';

function loadPinned(): string[] {
	try {
		const raw = localStorage.getItem(PIN_KEY);
		if (raw) {
			const ids: string[] = JSON.parse(raw);
			// Drop any stale ids that no longer exist in the registry.
			const known = new Set(VIEWS.map((v) => v.id));
			return ids.filter((id) => known.has(id));
		}
	} catch {
		// fall through to defaults
	}
	return VIEWS.filter((v) => v.defaultPinned).map((v) => v.id);
}

class ShellStore {
	spacesOpen = $state(false);
	settingsOpen = $state(false);
	newSessionOpen = $state(false);
	pinned = $state<string[]>(loadPinned());

	openSpaces(): void {
		this.spacesOpen = true;
	}
	closeSpaces(): void {
		this.spacesOpen = false;
	}
	toggleSpaces(): void {
		this.spacesOpen = !this.spacesOpen;
	}

	openSettings(): void {
		this.closeSpaces();
		this.settingsOpen = true;
	}
	closeSettings(): void {
		this.settingsOpen = false;
	}
	openNewSession(): void {
		this.closeSpaces();
		this.newSessionOpen = true;
	}

	isPinned(id: string): boolean {
		return this.pinned.includes(id);
	}

	togglePin(id: string): void {
		this.pinned = this.pinned.includes(id)
			? this.pinned.filter((x) => x !== id)
			: [...this.pinned, id];
		this.#persist();
	}

	#persist(): void {
		try {
			localStorage.setItem(PIN_KEY, JSON.stringify(this.pinned));
		} catch {
			// non-fatal: pins just won't survive the reload
		}
	}
}

export const shell = new ShellStore();
