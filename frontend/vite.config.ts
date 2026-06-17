import tailwindcss from '@tailwindcss/vite';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig({
	plugins: [tailwindcss(), sveltekit()],
	server: {
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
