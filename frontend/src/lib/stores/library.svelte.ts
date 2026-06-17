import {
	buildTree,
	deleteFile,
	listTree,
	readFile,
	writeFile,
	type LibraryEntry,
	type TreeNode
} from '$lib/library';

/**
 * Shared Library view-state. Lives in a singleton (not page-local) because the
 * "New file" action is a shell-rendered toolbar outside the page's component
 * tree — the toolbar, rail, editor and side pane all read/write this store, the
 * same way sessionsStore/watchSet coordinate the Sessions chrome.
 */
class LibraryStore {
	entries = $state<LibraryEntry[]>([]);
	tree = $state<TreeNode[]>([]);
	selected = $state<string | null>(null);
	content = $state('');
	savedContent = $state('');
	error = $state('');
	loaded = $state(false);

	dirty = $derived(this.content !== this.savedContent);
	selectedEntry = $derived<LibraryEntry | null>(
		this.selected ? (this.entries.find((e) => e.path === this.selected) ?? null) : null
	);

	// pending-open path for the unsaved-changes guard (click the file again to discard)
	#pendingOpen: string | null = null;

	async refresh(): Promise<void> {
		try {
			this.entries = await listTree();
			this.tree = buildTree(this.entries);
			this.loaded = true;
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to load library';
		}
	}

	async open(path: string): Promise<void> {
		if (this.dirty && this.#pendingOpen !== path) {
			this.#pendingOpen = path;
			this.error = 'Unsaved changes — click the file again to discard them.';
			return;
		}
		this.#pendingOpen = null;
		this.error = '';
		try {
			this.content = await readFile(path);
			this.savedContent = this.content;
			this.selected = path;
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to read file';
		}
	}

	async save(): Promise<void> {
		if (!this.selected) return;
		this.error = '';
		try {
			await writeFile(this.selected, this.content);
			this.savedContent = this.content;
			await this.refresh();
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to save';
		}
	}

	async create(path: string): Promise<void> {
		const p = path.trim();
		if (!p) return;
		this.error = '';
		try {
			await writeFile(p, '');
			await this.refresh();
			await this.open(p);
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to create file';
		}
	}

	async remove(): Promise<void> {
		if (!this.selected) return;
		this.error = '';
		try {
			await deleteFile(this.selected);
			this.selected = null;
			this.content = '';
			this.savedContent = '';
			await this.refresh();
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to delete';
		}
	}
}

export const libraryStore = new LibraryStore();
