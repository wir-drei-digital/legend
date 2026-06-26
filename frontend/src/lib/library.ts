import { apiFetch } from './api';

export interface LibraryEntry {
	path: string;
	type: 'file' | 'dir';
	size: number;
	mtime: string;
}

async function fail(res: Response, fallback: string): Promise<never> {
	let detail = `${res.status}`;
	try {
		detail = (await res.json()).error ?? detail;
	} catch {
		// keep status code
	}
	throw new Error(`${fallback}: ${detail}`);
}

export async function listTree(): Promise<LibraryEntry[]> {
	const res = await apiFetch('/api/library/tree');
	if (!res.ok) await fail(res, 'listing library failed');
	return (await res.json()).data;
}

export async function readFile(path: string): Promise<string> {
	const res = await apiFetch(`/api/library/file?path=${encodeURIComponent(path)}`);
	if (!res.ok) await fail(res, 'reading file failed');
	return (await res.json()).data.content;
}

export async function writeFile(path: string, content: string): Promise<void> {
	const res = await apiFetch('/api/library/file', {
		method: 'PUT',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ path, content })
	});
	if (!res.ok) await fail(res, 'saving file failed');
}

export async function deleteFile(path: string): Promise<void> {
	const res = await apiFetch(`/api/library/file?path=${encodeURIComponent(path)}`, {
		method: 'DELETE'
	});
	if (!res.ok) await fail(res, 'deleting file failed');
}

export interface TreeNode {
	name: string;
	path: string;
	type: 'file' | 'dir';
	children: TreeNode[];
}

/** Builds a nested tree from flat entries; dirs first, then files, alphabetical. */
export function buildTree(entries: LibraryEntry[]): TreeNode[] {
	const byPath = new Map<string, TreeNode>();
	const roots: TreeNode[] = [];

	for (const e of [...entries].sort((a, b) => a.path.localeCompare(b.path))) {
		const node: TreeNode = {
			name: e.path.split('/').at(-1) ?? e.path,
			path: e.path,
			type: e.type,
			children: []
		};
		byPath.set(e.path, node);
		const parent = byPath.get(e.path.split('/').slice(0, -1).join('/'));
		(parent ? parent.children : roots).push(node);
	}

	const order = (nodes: TreeNode[]) => {
		nodes.sort((a, b) =>
			a.type === b.type ? a.name.localeCompare(b.name) : a.type === 'dir' ? -1 : 1
		);
		nodes.forEach((n) => order(n.children));
	};
	order(roots);
	return roots;
}

/**
 * Prunes the tree to nodes whose name matches `query` (case-insensitive),
 * keeping the ancestor folders of any match so the path stays navigable.
 * Returns a new tree; the input is not mutated.
 */
export function filterTree(nodes: TreeNode[], query: string): TreeNode[] {
	const q = query.trim().toLowerCase();
	if (!q) return nodes;
	const walk = (list: TreeNode[]): TreeNode[] => {
		const out: TreeNode[] = [];
		for (const n of list) {
			if (n.type === 'dir') {
				const children = walk(n.children);
				if (children.length || n.name.toLowerCase().includes(q)) {
					out.push({ ...n, children });
				}
			} else if (n.name.toLowerCase().includes(q)) {
				out.push(n);
			}
		}
		return out;
	};
	return walk(nodes);
}
