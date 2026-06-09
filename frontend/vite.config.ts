import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [sveltekit()],
	server: {
		proxy: {
			'/api': 'http://localhost:4000',
			'/socket': { target: 'ws://localhost:4000', ws: true }
		}
	}
});
