<script lang="ts">
	let {
		color,
		pulse = false,
		size = 6,
		class: className = ''
	}: { color: string; pulse?: boolean; size?: number; class?: string } = $props();
</script>

<span
	class="relative inline-block shrink-0 rounded-full {className}"
	class:lg-dot-pulse={pulse}
	style:width="{size}px"
	style:height="{size}px"
	style:background={color}
	style:--dot={color}
></span>

<style>
	.lg-dot-pulse::after {
		content: '';
		position: absolute;
		inset: 0;
		border-radius: 999px;
		background: var(--dot);
		animation: lg-dot-ring 1.8s ease-out infinite;
	}
	@keyframes lg-dot-ring {
		0% {
			opacity: 0.5;
			transform: scale(1);
		}
		70%,
		100% {
			opacity: 0;
			transform: scale(2.6);
		}
	}
</style>
