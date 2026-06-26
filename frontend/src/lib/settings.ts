import { apiFetch } from './api';

export interface LibraryPathInfo {
	effective: string;
	source: 'env' | 'setting' | 'default';
	default: string;
	value: string | null;
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

export async function getLibraryPath(): Promise<LibraryPathInfo> {
	const res = await apiFetch('/api/settings/library-path');
	if (!res.ok) await fail(res, 'loading settings failed');
	return (await res.json()).data;
}

export async function putLibraryPath(path: string): Promise<LibraryPathInfo> {
	const res = await apiFetch('/api/settings/library-path', {
		method: 'PUT',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ path })
	});
	if (!res.ok) await fail(res, 'saving library path failed');
	return (await res.json()).data;
}

export async function resetLibraryPath(): Promise<LibraryPathInfo> {
	const res = await apiFetch('/api/settings/library-path', { method: 'DELETE' });
	if (!res.ok) await fail(res, 'resetting library path failed');
	return (await res.json()).data;
}
