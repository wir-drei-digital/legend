<script lang="ts">
	// 1px · 20px vertical divider between status-bar / toolbar clusters.
	let { height = 20 }: { height?: number } = $props();
</script>

<span class="shrink-0 bg-hair-strong" style:width="1px" style:height="{height}px"></span>
