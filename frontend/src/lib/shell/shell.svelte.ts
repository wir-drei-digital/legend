// Shell-wide UI state: the Spaces launcher overlay, the Settings modal, and the
// New-session dialog. Spaces are the whole navigation footprint now.

class ShellStore {
	spacesOpen = $state(false);
	settingsOpen = $state(false);
	newSessionOpen = $state(false);

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
}

export const shell = new ShellStore();
