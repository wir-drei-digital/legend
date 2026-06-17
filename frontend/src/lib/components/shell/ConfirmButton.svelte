<script lang="ts">
	import type { IconName } from './Icon.svelte';
	import MenuItem from './MenuItem.svelte';
	let {
		idleLabel,
		confirmLabel,
		onconfirm,
		icon = 'trash'
	}: { idleLabel: string; confirmLabel: string; onconfirm: () => void; icon?: IconName } = $props();
	let armed = $state(false);
</script>

<MenuItem
	{icon}
	tone="danger"
	onclick={() => {
		if (armed) onconfirm();
		else armed = true;
	}}
>
	{armed ? confirmLabel : idleLabel}
</MenuItem>
