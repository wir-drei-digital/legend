import { describe, it, expect, beforeEach, vi } from 'vitest';

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

// Capture the params the phoenix Socket constructor is called with, plus any
// onError handlers registered on the instance.
const ctorCalls: Array<{ url: string; opts: unknown }> = [];
const onErrorCalls: Array<(...args: unknown[]) => void> = [];
vi.mock('phoenix', () => ({
	Socket: class {
		constructor(url: string, opts: unknown) {
			ctorCalls.push({ url, opts });
		}
		onError(cb: (...args: unknown[]) => void) {
			onErrorCalls.push(cb);
		}
		connect() {}
	}
}));

beforeEach(() => {
	ctorCalls.length = 0;
	onErrorCalls.length = 0;
	vi.stubGlobal('localStorage', memoryStorage());
	vi.resetModules();
});

describe('getSocket', () => {
	it('passes the device token as a connect param when present', async () => {
		localStorage.setItem('legend.device_token', 'tok123');
		const { getSocket } = await import('./socket');
		getSocket();
		expect(ctorCalls[0].opts).toEqual({ params: { token: 'tok123' } });
	});

	it('connects with no params on loopback (no token)', async () => {
		const { getSocket } = await import('./socket');
		getSocket();
		expect(ctorCalls[0].opts).toEqual({});
	});

	it('registers an onError handler when a token is present', async () => {
		localStorage.setItem('legend.device_token', 'tok123');
		const { getSocket } = await import('./socket');
		getSocket();
		expect(onErrorCalls).toHaveLength(1);
		expect(typeof onErrorCalls[0]).toBe('function');
	});

	it('does not register an onError handler on loopback (no token)', async () => {
		const { getSocket } = await import('./socket');
		getSocket();
		expect(onErrorCalls).toHaveLength(0);
	});
});
