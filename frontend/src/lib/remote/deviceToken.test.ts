import { describe, it, expect, beforeEach, vi } from 'vitest';
import { getDeviceToken, setDeviceToken, clearDeviceToken } from './deviceToken';

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

describe('deviceToken', () => {
	it('round-trips and clears a token', () => {
		expect(getDeviceToken()).toBeNull();
		setDeviceToken('abc');
		expect(getDeviceToken()).toBe('abc');
		clearDeviceToken();
		expect(getDeviceToken()).toBeNull();
	});
});
