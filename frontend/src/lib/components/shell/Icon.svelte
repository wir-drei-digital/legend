<script lang="ts" module>
	// A single 1.6-stroke, 24px icon set (design system §9). currentColor, no fills
	// except where a glyph reads better solid (star when pinned).
	export type IconName =
		| 'sessions'
		| 'folder'
		| 'message'
		| 'gear'
		| 'grid'
		| 'columns'
		| 'focus'
		| 'list'
		| 'swarm'
		| 'sparkle'
		| 'gauge'
		| 'search'
		| 'plus'
		| 'eye'
		| 'close'
		| 'bell'
		| 'cloud'
		| 'desktop'
		| 'star'
		| 'refresh'
		| 'more'
		| 'pause'
		| 'trash'
		| 'pencil'
		| 'chevron-down'
		| 'chevron-right'
		| 'corner-down-left'
		| 'file'
		| 'panel-right'
		| 'link';
</script>

<script lang="ts">
	let {
		name,
		size = 16,
		strokeWidth = 1.6,
		fill = false,
		class: className = ''
	}: {
		name: IconName;
		size?: number;
		strokeWidth?: number;
		fill?: boolean;
		class?: string;
	} = $props();
</script>

<svg
	viewBox="0 0 24 24"
	width={size}
	height={size}
	fill="none"
	stroke="currentColor"
	stroke-width={strokeWidth}
	stroke-linecap="round"
	stroke-linejoin="round"
	class={className}
	aria-hidden="true"
>
	{#if name === 'sessions'}
		<rect x="3.5" y="3.5" width="17" height="17" rx="3" />
		<path d="M12 3.5v17M3.5 12h17" />
	{:else if name === 'grid'}
		<rect x="3.5" y="3.5" width="7" height="7" rx="1.6" />
		<rect x="13.5" y="3.5" width="7" height="7" rx="1.6" />
		<rect x="3.5" y="13.5" width="7" height="7" rx="1.6" />
		<rect x="13.5" y="13.5" width="7" height="7" rx="1.6" />
	{:else if name === 'columns'}
		<rect x="3.5" y="3.5" width="7.5" height="17" rx="1.6" />
		<rect x="13" y="3.5" width="7.5" height="7.6" rx="1.6" />
		<rect x="13" y="12.9" width="7.5" height="7.6" rx="1.6" />
	{:else if name === 'focus'}
		<rect x="4" y="4.5" width="16" height="15" rx="2.4" />
		<path d="M8.5 9.5h7M8.5 13h4.5" />
	{:else if name === 'folder'}
		<path d="M3.5 7.5a2 2 0 012-2h3.2l2 2.4h7.8a2 2 0 012 2v7.6a2 2 0 01-2 2H5.5a2 2 0 01-2-2z" />
	{:else if name === 'message'}
		<path d="M4.5 5.5h15a1.5 1.5 0 011.5 1.5v8a1.5 1.5 0 01-1.5 1.5H9l-4 3.2V16H4.5A1.5 1.5 0 013 14.5V7a1.5 1.5 0 011.5-1.5z" />
	{:else if name === 'gear'}
		<circle cx="12" cy="12" r="3" />
		<path d="M19.4 13.5a1.7 1.7 0 00.34 1.86l.05.05a2 2 0 11-2.83 2.83l-.05-.05a1.7 1.7 0 00-1.86-.34 1.7 1.7 0 00-1.03 1.56V21a2 2 0 11-4 0v-.09A1.7 1.7 0 008.5 19.3a1.7 1.7 0 00-1.86.34l-.05.05a2 2 0 11-2.83-2.83l.05-.05a1.7 1.7 0 00.34-1.86 1.7 1.7 0 00-1.56-1.03H3a2 2 0 110-4h.09A1.7 1.7 0 004.7 8.5a1.7 1.7 0 00-.34-1.86l-.05-.05a2 2 0 112.83-2.83l.05.05a1.7 1.7 0 001.86.34H9a1.7 1.7 0 001.03-1.56V3a2 2 0 114 0v.09a1.7 1.7 0 001.03 1.56 1.7 1.7 0 001.86-.34l.05-.05a2 2 0 112.83 2.83l-.05.05a1.7 1.7 0 00-.34 1.86V9a1.7 1.7 0 001.56 1.03H21a2 2 0 110 4h-.09a1.7 1.7 0 00-1.51 1.47z" />
	{:else if name === 'list'}
		<path d="M8 6.5h12M8 12h12M8 17.5h12" />
		<circle cx="4.2" cy="6.5" r="1" fill="currentColor" stroke="none" />
		<circle cx="4.2" cy="12" r="1" fill="currentColor" stroke="none" />
		<circle cx="4.2" cy="17.5" r="1" fill="currentColor" stroke="none" />
	{:else if name === 'swarm'}
		<circle cx="17.5" cy="5.5" r="2.4" />
		<circle cx="6" cy="12" r="2.4" />
		<circle cx="17.5" cy="18.5" r="2.4" />
		<path d="M8.1 10.8l7.3-4.1M8.1 13.2l7.3 4.1" />
	{:else if name === 'sparkle'}
		<path d="M12 3.5l1.7 5 5 1.7-5 1.7-1.7 5-1.7-5-5-1.7 5-1.7z" />
		<path d="M18.5 16.5l.7 1.9 1.9.7-1.9.7-.7 1.9-.7-1.9-1.9-.7 1.9-.7z" />
	{:else if name === 'gauge'}
		<path d="M4.5 17.5a7.5 7.5 0 1115 0" />
		<path d="M12 17.5l3.6-4.3" />
		<circle cx="12" cy="17.5" r="1.1" fill="currentColor" stroke="none" />
	{:else if name === 'search'}
		<circle cx="11" cy="11" r="7" />
		<path d="M21 21l-4.35-4.35" />
	{:else if name === 'plus'}
		<path d="M12 5.5v13M5.5 12h13" />
	{:else if name === 'eye'}
		<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z" />
		<circle cx="12" cy="12" r="3" />
	{:else if name === 'close'}
		<path d="M6 6l12 12M18 6L6 18" />
	{:else if name === 'bell'}
		<path d="M18 8.5a6 6 0 10-12 0c0 6.5-2.5 8.5-2.5 8.5h17S18 15 18 8.5" />
		<path d="M13.7 20.5a2 2 0 01-3.4 0" />
	{:else if name === 'cloud'}
		<path d="M17.5 18.5a4 4 0 00.5-7.97A6 6 0 106 14.5h11.5z" />
	{:else if name === 'desktop'}
		<rect x="3" y="4.5" width="18" height="11.5" rx="2" />
		<path d="M9 20h6M12 16v4" />
	{:else if name === 'star'}
		<path
			d="M12 3.6l2.6 5.27 5.82.85-4.21 4.1.99 5.79L12 17.08l-5.2 2.73.99-5.79-4.21-4.1 5.82-.85z"
			fill={fill ? 'currentColor' : 'none'}
		/>
	{:else if name === 'more'}
		<circle cx="5" cy="12" r="1.5" fill="currentColor" stroke="none" />
		<circle cx="12" cy="12" r="1.5" fill="currentColor" stroke="none" />
		<circle cx="19" cy="12" r="1.5" fill="currentColor" stroke="none" />
	{:else if name === 'pause'}
		<path d="M9 5.5v13M15 5.5v13" />
	{:else if name === 'trash'}
		<path d="M4 7h16" />
		<path d="M9 7V5a1 1 0 011-1h4a1 1 0 011 1v2" />
		<path d="M6.5 7l.8 12a2 2 0 002 1.9h5.4a2 2 0 002-1.9L17.5 7" />
	{:else if name === 'pencil'}
		<path d="M15.5 5.5l3 3M4 20l1-4.2L16.3 4.5a1.5 1.5 0 012.1 0l1.1 1.1a1.5 1.5 0 010 2.1L8.2 19z" />
	{:else if name === 'refresh'}
		<path d="M3.5 12a8.5 8.5 0 0114.95-5.5" />
		<path d="M19 3.5V8h-4.5" />
		<path d="M20.5 12a8.5 8.5 0 01-14.95 5.5" />
		<path d="M5 20.5V16h4.5" />
	{:else if name === 'chevron-down'}
		<path d="M6 9.5l6 6 6-6" />
	{:else if name === 'chevron-right'}
		<path d="M9.5 6l6 6-6 6" />
	{:else if name === 'file'}
		<path d="M13 3.5H6.5A1.5 1.5 0 005 5v14a1.5 1.5 0 001.5 1.5h11A1.5 1.5 0 0019 19V9.5z" />
		<path d="M13 3.5V9.5h6" />
	{:else if name === 'panel-right'}
		<rect x="3.5" y="4.5" width="17" height="15" rx="2.4" />
		<path d="M14.5 4.5v15" />
	{:else if name === 'link'}
		<path d="M9.5 14.5l5-5" />
		<path d="M8 11l-2.2 2.2a3.1 3.1 0 004.4 4.4L12 16" />
		<path d="M16 13l2.2-2.2a3.1 3.1 0 00-4.4-4.4L12 8" />
	{:else if name === 'corner-down-left'}
		<path d="M9 10l-4 4 4 4" />
		<path d="M5 14h10a4 4 0 004-4V6" />
	{/if}
</svg>
