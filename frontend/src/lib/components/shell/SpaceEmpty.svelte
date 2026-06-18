<script lang="ts">
	// Empty-state backdrop: a parallax starfield with a cruising spaceship, drawn
	// entirely from Legend theme tokens (teal accent + ink ramp over bg-app). The
	// caption (children) sits centered over it. Honors prefers-reduced-motion.
	import type { Snippet } from 'svelte';

	let { children }: { children: Snippet } = $props();
</script>

<div class="relative flex h-full w-full flex-col items-center justify-center overflow-hidden bg-app">
	<!-- parallax starfield: three layers drifting at different speeds (far→near) -->
	<div class="lg-stars lg-stars--far" aria-hidden="true"></div>
	<div class="lg-stars lg-stars--mid" aria-hidden="true"></div>
	<div class="lg-stars lg-stars--near" aria-hidden="true"></div>

	<!-- foreground: ship + caption -->
	<div class="relative z-10 flex flex-col items-center gap-4 px-6 text-center">
		<div class="lg-ship" aria-hidden="true">
			<svg viewBox="0 0 112 64" width="92" height="53" fill="none">
				<!-- thruster glow (pulses behind the nozzle) -->
				<ellipse class="lg-ship__glow" cx="20" cy="34" rx="18" ry="5" />
				<!-- exhaust flame -->
				<path class="lg-ship__flame" d="M30 34 L8 28 M30 34 L2 34 M30 34 L8 40" />
				<!-- rear fins -->
				<path class="lg-ship__fin" d="M40 34 L28 16 L52 26 Z" />
				<path class="lg-ship__fin" d="M40 34 L28 52 L52 42 Z" />
				<!-- hull: pointed nose to the right -->
				<path
					class="lg-ship__hull"
					d="M38 34 C38 22 48 16 70 16 C90 16 104 24 108 34 C104 44 90 52 70 52 C48 52 38 46 38 34 Z"
				/>
				<!-- cockpit -->
				<circle class="lg-ship__cockpit" cx="80" cy="34" r="7" />
				<circle class="lg-ship__spark" cx="83" cy="31" r="1.6" />
			</svg>
		</div>

		<div class="flex flex-col items-center gap-2">
			{@render children()}
		</div>
	</div>
</div>

<style>
	/* ---- parallax starfield (repeating radial-gradient tiles drift left) ---- */
	.lg-stars {
		position: absolute;
		inset: -10% -10%;
		background-repeat: repeat;
		pointer-events: none;
		will-change: background-position;
	}
	.lg-stars--far {
		opacity: 0.32;
		background-size: 170px 170px;
		background-image:
			radial-gradient(1px 1px at 24px 32px, var(--text-3), transparent),
			radial-gradient(1px 1px at 96px 12px, var(--text-3), transparent),
			radial-gradient(1px 1px at 142px 78px, var(--text-3), transparent),
			radial-gradient(1px 1px at 56px 118px, var(--text-3), transparent),
			radial-gradient(1px 1px at 118px 150px, var(--text-3), transparent),
			radial-gradient(1px 1px at 158px 54px, var(--text-3), transparent);
		animation: lg-drift-far 95s linear infinite;
	}
	.lg-stars--mid {
		opacity: 0.55;
		background-size: 250px 250px;
		background-image:
			radial-gradient(1.5px 1.5px at 40px 60px, var(--text-2), transparent),
			radial-gradient(1.5px 1.5px at 180px 30px, var(--text-2), transparent),
			radial-gradient(1.5px 1.5px at 110px 190px, var(--text-2), transparent),
			radial-gradient(1.5px 1.5px at 230px 130px, var(--text-2), transparent),
			radial-gradient(1.5px 1.5px at 70px 230px, var(--text-3), transparent);
		animation: lg-drift-mid 58s linear infinite;
	}
	.lg-stars--near {
		opacity: 0.9;
		background-size: 340px 340px;
		background-image:
			radial-gradient(2px 2px at 60px 80px, var(--text-1), transparent),
			radial-gradient(2.5px 2.5px at 300px 220px, var(--text-1), transparent),
			radial-gradient(3px 1px at 170px 300px, var(--accent-hi), transparent),
			radial-gradient(2px 2px at 240px 50px, var(--text-2), transparent),
			radial-gradient(3px 1px at 100px 170px, var(--accent), transparent);
		animation: lg-drift-near 34s linear infinite;
	}
	@keyframes lg-drift-far {
		to {
			background-position: -170px 0;
		}
	}
	@keyframes lg-drift-mid {
		to {
			background-position: -250px 0;
		}
	}
	@keyframes lg-drift-near {
		to {
			background-position: -340px 0;
		}
	}

	/* ---- spaceship ---- */
	.lg-ship {
		animation: lg-bob 5s ease-in-out infinite;
		filter: drop-shadow(0 8px 18px color-mix(in oklab, var(--accent) 35%, transparent));
	}
	.lg-ship__hull {
		fill: var(--bg-raised);
		stroke: var(--accent);
		stroke-width: 2;
	}
	.lg-ship__cockpit {
		fill: color-mix(in oklab, var(--accent-hi) 55%, var(--bg-raised));
		stroke: var(--accent-hi);
		stroke-width: 1.5;
	}
	.lg-ship__spark {
		fill: var(--text-1);
		opacity: 0.9;
	}
	.lg-ship__fin {
		fill: var(--accent-soft);
		stroke: var(--accent);
		stroke-width: 1.5;
		stroke-linejoin: round;
	}
	.lg-ship__flame {
		stroke: var(--accent-hi);
		stroke-width: 2.5;
		stroke-linecap: round;
		transform-origin: 30px 34px;
		animation: lg-flame 0.45s ease-in-out infinite;
	}
	.lg-ship__glow {
		fill: var(--accent);
		filter: blur(6px);
		opacity: 0.5;
		transform-origin: 20px 34px;
		animation: lg-glow 0.9s ease-in-out infinite;
	}
	@keyframes lg-bob {
		0%,
		100% {
			transform: translateY(0) rotate(-1.5deg);
		}
		50% {
			transform: translateY(-7px) rotate(1.5deg);
		}
	}
	@keyframes lg-flame {
		0%,
		100% {
			transform: scaleX(0.85);
			opacity: 0.75;
		}
		50% {
			transform: scaleX(1.15);
			opacity: 1;
		}
	}
	@keyframes lg-glow {
		0%,
		100% {
			transform: scaleX(0.8);
			opacity: 0.35;
		}
		50% {
			transform: scaleX(1.1);
			opacity: 0.6;
		}
	}

	/* ---- calm down for reduced-motion ---- */
	@media (prefers-reduced-motion: reduce) {
		.lg-stars--far,
		.lg-stars--mid,
		.lg-stars--near {
			animation-duration: 600s;
		}
		.lg-ship,
		.lg-ship__flame,
		.lg-ship__glow {
			animation: none;
		}
	}
</style>
