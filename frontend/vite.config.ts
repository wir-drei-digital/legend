import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
	plugins: [tailwindcss(), sveltekit()],
	server: {
		// Fixed, non-default port so this dev server doesn't collide with other
		// SvelteKit projects (Vite's default 5173 / its auto-incremented neighbours).
		// strictPort: fail loudly rather than silently grabbing another free port.
		port: 4173,
		strictPort: true,
		proxy: {
			'/api': 'http://localhost:4100',
			'/socket': { target: 'ws://localhost:4100', ws: true }
		}
	},
	test: {
		// Pure-logic unit tests run in node. Component/runes tests are out of scope
		// for Phase 1; tiling-core.ts imports no runes and no .svelte modules.
		environment: 'node',
		include: ['src/**/*.test.ts']
	}
});
