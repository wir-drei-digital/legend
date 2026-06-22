import { readFile, writeFile } from '$lib/library';

/** Persist a buffer this long after the last keystroke (debounced autosave). */
const AUTOSAVE_MS = 600;

interface Buffer {
	content: string;
	savedContent: string;
}

/**
 * Open file buffers, keyed by library path and shared across every tile showing
 * that path — so two tiles on one file stay in sync, with one dirty state and
 * one debounced autosave timer. Svelte 5 deeply proxies $state objects, so
 * nested mutation (and adding/removing record keys) is reactive.
 */
class FilesStore {
	buffers = $state<Record<string, Buffer>>({});
	error = $state('');
	/** paths with a write in flight — drives the header "Saving…" hint */
	savingPaths = $state<Record<string, boolean>>({});
	/** per-path autosave debounce timers; not reactive */
	#timers: Record<string, ReturnType<typeof setTimeout>> = {};

	has(path: string): boolean {
		return path in this.buffers;
	}
	buffer(path: string): Buffer | undefined {
		return this.buffers[path];
	}
	dirty(path: string): boolean {
		const b = this.buffers[path];
		return !!b && b.content !== b.savedContent;
	}
	saving(path: string): boolean {
		return !!this.savingPaths[path];
	}
	openPaths(): string[] {
		return Object.keys(this.buffers);
	}

	async load(path: string): Promise<void> {
		if (this.buffers[path]) return;
		this.error = '';
		try {
			const content = await readFile(path);
			this.buffers[path] = { content, savedContent: content };
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to read file';
		}
	}

	setContent(path: string, content: string): void {
		const b = this.buffers[path];
		if (!b) return;
		b.content = content;
		this.#scheduleAutosave(path);
	}

	/** Debounced autosave: persist AUTOSAVE_MS after the last edit. */
	#scheduleAutosave(path: string): void {
		clearTimeout(this.#timers[path]);
		this.#timers[path] = setTimeout(() => void this.save(path), AUTOSAVE_MS);
	}

	/** Persist now. Pre-empts the pending autosave timer (Cmd+S / blur path). */
	async save(path: string): Promise<void> {
		const b = this.buffers[path];
		if (!b) return;
		clearTimeout(this.#timers[path]);
		delete this.#timers[path];
		if (b.content === b.savedContent) return; // nothing to persist
		this.error = '';
		const pending = b.content;
		this.savingPaths[path] = true;
		try {
			await writeFile(path, pending);
			b.savedContent = pending;
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to save';
		} finally {
			delete this.savingPaths[path];
		}
	}

	release(path: string): void {
		clearTimeout(this.#timers[path]);
		delete this.#timers[path];
		delete this.savingPaths[path];
		delete this.buffers[path];
	}
}

export const filesStore = new FilesStore();
