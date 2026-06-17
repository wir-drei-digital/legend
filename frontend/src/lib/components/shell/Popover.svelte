<script lang="ts">
	import type { Snippet } from 'svelte';
	import Surface from './Surface.svelte';

	let {
		open = $bindable(false),
		class: className = '',
		elevation = 'pop',
		onclose,
		children
	}: {
		open?: boolean;
		class?: string;
		elevation?: 'pop' | 'overlay';
		onclose?: () => void;
		children: Snippet;
	} = $props();

	function close() {
		open = false;
		onclose?.();
	}
</script>

{#if open}
	<button
		type="button"
		class="fixed inset-0 z-40 cursor-default"
		aria-label="Close"
		onclick={close}
	></button>
	<div class="absolute z-50 {className}" style:animation="lg-rise 0.12s ease-out">
		<Surface {elevation} class="w-full">
			{@render children()}
		</Surface>
	</div>
{/if}
