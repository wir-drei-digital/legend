// Shell-wide UI state: the Spaces launcher overlay, the Settings modal, and the
// New-session dialog. Spaces are the whole navigation footprint now.

class ShellStore {
	spacesOpen = $state(false);
	settingsOpen = $state(false);
	newSessionOpen = $state(false);
	/** id of the space currently being renamed (drives the rename modal), or null */
	renameSpaceId = $state<string | null>(null);

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

	/** Open the rename-space modal. Closes the launcher so the modal stands alone. */
	openSpaceRename(id: string): void {
		this.closeSpaces();
		this.renameSpaceId = id;
	}
	closeSpaceRename(): void {
		this.renameSpaceId = null;
	}
}

export const shell = new ShellStore();
