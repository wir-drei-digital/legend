import { describe, it, expect } from 'vitest';
import { backendPort, buildPairUrl } from './pairUrl';

describe('backendPort', () => {
	it('parses the port from an absolute apiBase (desktop / tauri://localhost)', () => {
		expect(backendPort('http://localhost:4807', '')).toBe('4807');
	});

	it('falls back to the window port when apiBase is blank (web same-origin)', () => {
		expect(backendPort('', '4173')).toBe('4173');
	});

	it('falls back to the window port when apiBase is not an absolute URL', () => {
		expect(backendPort('/api', '4173')).toBe('4173');
	});

	it('returns empty when an absolute apiBase carries no explicit port', () => {
		expect(backendPort('http://example.com', '')).toBe('');
	});
});

describe('buildPairUrl', () => {
	it('uses the backend port from apiBase (tauri://localhost window has no port)', () => {
		expect(buildPairUrl('laptop.ts.net', 'ABC 123', 'http://localhost:4807', '')).toBe(
			'http://laptop.ts.net:4807/pair?code=ABC%20123'
		);
	});

	it('uses the window port on the web release (blank apiBase)', () => {
		expect(buildPairUrl('laptop.ts.net', 'CODE', '', '4173')).toBe(
			'http://laptop.ts.net:4173/pair?code=CODE'
		);
	});

	it('omits the colon when there is no port', () => {
		expect(buildPairUrl('laptop.ts.net', 'CODE', 'http://example.com', '')).toBe(
			'http://laptop.ts.net/pair?code=CODE'
		);
	});

	it('trims the host and returns empty without host or code', () => {
		expect(buildPairUrl('  laptop  ', 'CODE', '', '4807')).toBe(
			'http://laptop:4807/pair?code=CODE'
		);
		expect(buildPairUrl('', 'CODE', '', '4807')).toBe('');
		expect(buildPairUrl('laptop', '', '', '4807')).toBe('');
	});
});
