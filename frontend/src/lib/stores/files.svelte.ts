import { readFile, writeFile } from '$lib/library';

interface Buffer {
	content: string;
	savedContent: string;
}

/**
 * Open file buffers, keyed by library path and shared across every tile showing
 * that path — so two tiles on one file stay in sync, with one Save and one dirty
 * state. Svelte 5 deeply proxies $state objects, so nested mutation is reactive.
 */
class FilesStore {
	buffers = $state<Record<string, Buffer>>({});
	error = $state('');

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
		if (b) b.content = content;
	}

	async save(path: string): Promise<void> {
		const b = this.buffers[path];
		if (!b) return;
		this.error = '';
		try {
			await writeFile(path, b.content);
			b.savedContent = b.content;
		} catch (e) {
			this.error = e instanceof Error ? e.message : 'failed to save';
		}
	}

	release(path: string): void {
		delete this.buffers[path];
	}
}

export const filesStore = new FilesStore();
