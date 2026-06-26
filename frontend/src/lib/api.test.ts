import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { authHeaders, apiFetch } from './api';
import { getDeviceToken, setDeviceToken } from './remote/deviceToken';

function memoryStorage(): Storage {
	const m = new Map<string, string>();
	return {
		length: 0,
		clear: () => m.clear(),
		key: () => null,
		getItem: (k: string) => (m.has(k) ? (m.get(k) as string) : null),
		setItem: (k: string, v: string) => void m.set(k, v),
		removeItem: (k: string) => void m.delete(k)
	} as Storage;
}

beforeEach(() => {
	vi.stubGlobal('localStorage', memoryStorage());
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('authHeaders', () => {
	it('is empty without a token', () => {
		expect(authHeaders()).toEqual({});
	});

	it('carries the bearer token when set', () => {
		setDeviceToken('tok123');
		expect(authHeaders()).toEqual({ Authorization: 'Bearer tok123' });
	});
});

describe('apiFetch', () => {
	it('prepends the base and merges auth + caller headers', async () => {
		setDeviceToken('tok123');
		const calls: Array<[string, RequestInit]> = [];
		vi.stubGlobal('fetch', (url: string, init: RequestInit) => {
			calls.push([url, init]);
			return Promise.resolve(new Response('{}', { status: 200 }));
		});

		await apiFetch('/api/sessions', { headers: { Accept: 'application/json' } });

		const [url, init] = calls[0];
		expect(url).toBe('/api/sessions'); // apiBase is '' in tests
		expect(init.headers).toEqual({
			Authorization: 'Bearer tok123',
			Accept: 'application/json'
		});
	});

	it('clears the token and redirects to /pair on 401', async () => {
		setDeviceToken('tok');
		vi.stubGlobal('window', { location: { pathname: '/sessions', href: '' } });
		vi.stubGlobal('fetch', () => Promise.resolve(new Response('', { status: 401 })));

		await apiFetch('/api/sessions');

		expect(getDeviceToken()).toBeNull();
		expect(
			(globalThis as unknown as { window: { location: { href: string } } }).window.location.href
		).toBe('/pair');
	});

	it('does not redirect when the 401 happens on /pair', async () => {
		setDeviceToken('tok');
		vi.stubGlobal('window', { location: { pathname: '/pair', href: '' } });
		vi.stubGlobal('fetch', () => Promise.resolve(new Response('', { status: 401 })));

		await apiFetch('/api/pair');

		expect(
			(globalThis as unknown as { window: { location: { href: string } } }).window.location.href
		).toBe('');
	});
});
