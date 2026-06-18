<script lang="ts">
	// Asteroids minigame as the empty-state backdrop. Attract mode plays an
	// ambient auto-demo; click (or a game key) takes control. Vector style drawn
	// on <canvas>, colored from Legend theme tokens (teal accent + ink ramp),
	// over the parallax starfield. ⌘K still opens a surface (shell owns meta+K).
	import { onMount } from 'svelte';
	import type { Snippet } from 'svelte';

	let { children }: { children: Snippet } = $props();

	let host = $state<HTMLDivElement>();
	let canvas = $state<HTMLCanvasElement>();

	// Reactive HUD state only; game entities are plain mutable objects.
	let mode = $state<'attract' | 'playing' | 'over'>('attract');
	let score = $state(0);
	let lives = $state(3);

	const TAU = Math.PI * 2;
	const SHIP_R = 12;
	const TURN = 4.6; // rad/s
	const ACCEL = 320; // px/s^2
	const FRICTION = 0.62; // per second (velocity retained ~ pow(FRICTION,dt))
	const BULLET_SPEED = 460;
	const BULLET_LIFE = 0.9;
	const FIRE_COOLDOWN = 0.18;
	const SIZES: Record<number, { r: number; score: number }> = {
		3: { r: 40, score: 20 },
		2: { r: 24, score: 50 },
		1: { r: 13, score: 100 }
	};

	type Vec = { x: number; y: number };
	type Ship = Vec & { vx: number; vy: number; a: number; thrust: boolean; invuln: number };
	type Rock = Vec & { vx: number; vy: number; size: number; r: number; spin: number; rot: number; verts: number[] };
	type Bullet = Vec & { vx: number; vy: number; life: number };

	let W = 0,
		H = 0,
		dpr = 1;
	let ctx: CanvasRenderingContext2D | null = null;
	let raf = 0;
	let last = 0;
	let fireCd = 0;
	let aiAim = 0;
	let reduced = false;
	const keys = { left: false, right: false, thrust: false, fire: false };
	const C = { accent: '#5eead4', accentHi: '#99f6e4', ink1: '#e8e6f0', ink2: '#a9a6bd', ink3: '#6b6880', amber: '#f3c969' };

	let ship: Ship = { x: 0, y: 0, vx: 0, vy: 0, a: -Math.PI / 2, thrust: false, invuln: 0 };
	let rocks: Rock[] = [];
	let bullets: Bullet[] = [];

	function rand(a: number, b: number) {
		return a + Math.random() * (b - a);
	}
	function wrap(p: Vec) {
		if (p.x < 0) p.x += W;
		else if (p.x >= W) p.x -= W;
		if (p.y < 0) p.y += H;
		else if (p.y >= H) p.y -= H;
	}

	function makeRock(x: number, y: number, size: number): Rock {
		const r = SIZES[size].r;
		const n = 10;
		const verts: number[] = [];
		for (let i = 0; i < n; i++) verts.push(rand(0.72, 1.12)); // per-vertex radius jitter
		const sp = rand(28, 70) * (size === 3 ? 0.7 : 1);
		const dir = rand(0, TAU);
		return { x, y, vx: Math.cos(dir) * sp, vy: Math.sin(dir) * sp, size, r, spin: rand(-1, 1), rot: rand(0, TAU), verts };
	}

	function spawnWave(n: number) {
		rocks = [];
		for (let i = 0; i < n; i++) {
			// spawn away from the centre (where the ship lives)
			let x = 0,
				y = 0;
			do {
				x = rand(0, W);
				y = rand(0, H);
			} while (Math.hypot(x - W / 2, y - H / 2) < Math.min(W, H) * 0.28);
			rocks.push(makeRock(x, y, 3));
		}
	}

	function resetShip() {
		ship = { x: W / 2, y: H / 2, vx: 0, vy: 0, a: -Math.PI / 2, thrust: false, invuln: 2 };
	}

	function startGame() {
		mode = 'playing';
		score = 0;
		lives = 3;
		bullets = [];
		resetShip();
		spawnWave(4);
	}

	function fire() {
		if (fireCd > 0 || bullets.length > 14) return;
		fireCd = FIRE_COOLDOWN;
		bullets.push({
			x: ship.x + Math.cos(ship.a) * SHIP_R,
			y: ship.y + Math.sin(ship.a) * SHIP_R,
			vx: Math.cos(ship.a) * BULLET_SPEED + ship.vx,
			vy: Math.sin(ship.a) * BULLET_SPEED + ship.vy,
			life: BULLET_LIFE
		});
	}

	function splitRock(idx: number) {
		const r = rocks[idx];
		score += SIZES[r.size].score;
		rocks.splice(idx, 1);
		if (r.size > 1) {
			rocks.push(makeRock(r.x, r.y, r.size - 1));
			rocks.push(makeRock(r.x, r.y, r.size - 1));
		}
		if (rocks.length === 0) spawnWave(mode === 'playing' ? 5 : 4);
	}

	function hitShip() {
		if (ship.invuln > 0) return;
		lives -= 1;
		if (lives <= 0) {
			mode = 'over';
			ship.invuln = 999;
		} else {
			resetShip();
		}
	}

	function update(dt: number) {
		fireCd = Math.max(0, fireCd - dt);

		if (mode === 'playing') {
			if (keys.left) ship.a -= TURN * dt;
			if (keys.right) ship.a += TURN * dt;
			ship.thrust = keys.thrust;
			if (keys.fire) fire();
		} else if (mode === 'attract' && !reduced) {
			// light auto-pilot: aim at the nearest rock and fire periodically
			aiAim -= dt;
			let near: Rock | null = null,
				nd = Infinity;
			for (const r of rocks) {
				const d = Math.hypot(r.x - ship.x, r.y - ship.y);
				if (d < nd) {
					nd = d;
					near = r;
				}
			}
			if (near) {
				const target = Math.atan2(near.y - ship.y, near.x - ship.x);
				let diff = ((target - ship.a + Math.PI) % TAU) - Math.PI;
				ship.a += Math.max(-TURN * dt, Math.min(TURN * dt, diff));
				ship.thrust = nd > Math.min(W, H) * 0.3;
				if (aiAim <= 0 && Math.abs(diff) < 0.25) {
					fire();
					aiAim = rand(0.35, 0.7);
				}
			}
		}

		if (mode === 'playing' || (mode === 'attract' && !reduced)) {
			if (ship.thrust) {
				ship.vx += Math.cos(ship.a) * ACCEL * dt;
				ship.vy += Math.sin(ship.a) * ACCEL * dt;
			}
			const fr = Math.pow(FRICTION, dt);
			ship.vx *= fr;
			ship.vy *= fr;
			ship.x += ship.vx * dt;
			ship.y += ship.vy * dt;
			wrap(ship);
			ship.invuln = Math.max(0, ship.invuln - dt);

			for (const r of rocks) {
				r.x += r.vx * dt;
				r.y += r.vy * dt;
				r.rot += r.spin * dt;
				wrap(r);
			}
			for (const b of bullets) {
				b.x += b.vx * dt;
				b.y += b.vy * dt;
				b.life -= dt;
				wrap(b);
			}
			bullets = bullets.filter((b) => b.life > 0);

			// bullet → rock
			for (let bi = bullets.length - 1; bi >= 0; bi--) {
				for (let ri = rocks.length - 1; ri >= 0; ri--) {
					if (Math.hypot(bullets[bi].x - rocks[ri].x, bullets[bi].y - rocks[ri].y) < rocks[ri].r) {
						bullets.splice(bi, 1);
						splitRock(ri);
						break;
					}
				}
			}
			// rock → ship (only when actively playing)
			if (mode === 'playing') {
				for (const r of rocks) {
					if (Math.hypot(r.x - ship.x, r.y - ship.y) < r.r + SHIP_R * 0.7) {
						hitShip();
						break;
					}
				}
			}
		}
	}

	function drawShip() {
		if (mode === 'over') return;
		// blink while invulnerable
		if (ship.invuln > 0 && ship.invuln < 900 && Math.floor(ship.invuln * 10) % 2 === 0) return;
		if (!ctx) return;
		ctx.save();
		ctx.translate(ship.x, ship.y);
		ctx.rotate(ship.a);
		ctx.lineWidth = 1.8;
		ctx.strokeStyle = C.accentHi;
		ctx.beginPath();
		ctx.moveTo(SHIP_R, 0);
		ctx.lineTo(-SHIP_R * 0.8, SHIP_R * 0.7);
		ctx.lineTo(-SHIP_R * 0.45, 0);
		ctx.lineTo(-SHIP_R * 0.8, -SHIP_R * 0.7);
		ctx.closePath();
		ctx.stroke();
		if (ship.thrust && Math.random() > 0.35) {
			ctx.strokeStyle = C.amber;
			ctx.beginPath();
			ctx.moveTo(-SHIP_R * 0.5, SHIP_R * 0.35);
			ctx.lineTo(-SHIP_R * 1.25, 0);
			ctx.lineTo(-SHIP_R * 0.5, -SHIP_R * 0.35);
			ctx.stroke();
		}
		ctx.restore();
	}

	function render() {
		if (!ctx) return;
		ctx.clearRect(0, 0, W, H);

		// rocks
		ctx.lineWidth = 1.6;
		ctx.strokeStyle = C.ink2;
		for (const r of rocks) {
			ctx.save();
			ctx.translate(r.x, r.y);
			ctx.rotate(r.rot);
			ctx.beginPath();
			for (let i = 0; i < r.verts.length; i++) {
				const ang = (i / r.verts.length) * TAU;
				const rad = r.r * r.verts[i];
				const px = Math.cos(ang) * rad;
				const py = Math.sin(ang) * rad;
				if (i === 0) ctx.moveTo(px, py);
				else ctx.lineTo(px, py);
			}
			ctx.closePath();
			ctx.stroke();
			ctx.restore();
		}

		// bullets
		ctx.fillStyle = C.accentHi;
		for (const b of bullets) {
			ctx.beginPath();
			ctx.arc(b.x, b.y, 1.8, 0, TAU);
			ctx.fill();
		}

		drawShip();
	}

	function loop(t: number) {
		const dt = Math.min(0.05, (t - last) / 1000 || 0);
		last = t;
		update(dt);
		render();
		raf = requestAnimationFrame(loop);
	}

	function resize() {
		if (!canvas || !host) return;
		const r = host.getBoundingClientRect();
		W = r.width;
		H = r.height;
		dpr = Math.min(2, window.devicePixelRatio || 1);
		canvas.width = Math.max(1, Math.round(W * dpr));
		canvas.height = Math.max(1, Math.round(H * dpr));
		ctx = canvas.getContext('2d');
		if (ctx) ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
	}

	const GAME_KEY: Record<string, keyof typeof keys | undefined> = {
		ArrowLeft: 'left', a: 'left', A: 'left',
		ArrowRight: 'right', d: 'right', D: 'right',
		ArrowUp: 'thrust', w: 'thrust', W: 'thrust',
		' ': 'fire'
	};

	function onKeyDown(e: KeyboardEvent) {
		if (e.metaKey || e.ctrlKey || e.altKey) return; // leave ⌘K etc. to the shell
		const k = GAME_KEY[e.key];
		if (mode !== 'playing') {
			if (k || e.key === 'Enter') {
				e.preventDefault();
				startGame();
			}
			return;
		}
		if (e.key === 'Escape') {
			mode = 'attract';
			return;
		}
		if (k) {
			e.preventDefault();
			keys[k] = true;
		}
	}
	function onKeyUp(e: KeyboardEvent) {
		const k = GAME_KEY[e.key];
		if (k) keys[k] = false;
	}
	function onPointer() {
		if (mode !== 'playing') startGame();
	}

	const scoreStr = $derived(String(score).padStart(5, '0'));

	onMount(() => {
		reduced = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ?? false;
		const cs = getComputedStyle(document.documentElement);
		const read = (v: string, f: string) => cs.getPropertyValue(v).trim() || f;
		C.accent = read('--accent', C.accent);
		C.accentHi = read('--accent-hi', C.accentHi);
		C.ink1 = read('--text-1', C.ink1);
		C.ink2 = read('--text-2', C.ink2);
		C.ink3 = read('--text-3', C.ink3);
		C.amber = read('--amber', C.amber);

		resize();
		resetShip();
		spawnWave(4);
		const ro = new ResizeObserver(resize);
		if (host) ro.observe(host);
		window.addEventListener('keydown', onKeyDown);
		window.addEventListener('keyup', onKeyUp);
		raf = requestAnimationFrame(loop);

		return () => {
			cancelAnimationFrame(raf);
			ro.disconnect();
			window.removeEventListener('keydown', onKeyDown);
			window.removeEventListener('keyup', onKeyUp);
		};
	});
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<!-- svelte-ignore a11y_click_events_have_key_events -->
<div
	bind:this={host}
	class="relative h-full w-full overflow-hidden bg-app"
	onpointerdown={onPointer}
	role="application"
	aria-label="Asteroids minigame"
>
	<!-- parallax starfield backdrop -->
	<div class="lg-stars lg-stars--far" aria-hidden="true"></div>
	<div class="lg-stars lg-stars--near" aria-hidden="true"></div>

	<canvas bind:this={canvas} class="absolute inset-0 h-full w-full"></canvas>

	<!-- HUD (pointer-events pass through to the canvas) -->
	<div class="pointer-events-none absolute inset-0 select-none">
		{#if mode !== 'attract'}
			<div class="absolute left-4 top-3 font-mono text-meta tracking-[0.1em] text-ink-2">
				SCORE {scoreStr}
			</div>
			<div class="absolute right-4 top-3 flex gap-1.5">
				{#each { length: Math.max(0, lives) } as _, i (i)}
					<span class="text-brand-hi">▲</span>
				{/each}
			</div>
		{/if}

		<div class="absolute inset-x-0 top-1/2 flex -translate-y-1/2 flex-col items-center gap-1 text-center">
			{#if mode === 'attract'}
				<p class="font-mono text-meta uppercase tracking-[0.2em] text-ink-3 lg-blink">Click to play</p>
			{:else if mode === 'over'}
				<p class="text-title font-semibold text-ink-1">Game over</p>
				<p class="font-mono text-meta text-ink-3">score {scoreStr} · click to play again</p>
			{/if}
		</div>

		<!-- empty-state caption + controls hint -->
		<div class="absolute inset-x-0 bottom-7 flex flex-col items-center gap-1.5 px-6 text-center">
			{@render children()}
			<p class="font-mono text-micro tracking-[0.08em] text-ink-3">
				←→ turn · ↑ thrust · space fire · ⌘K to open a surface
			</p>
		</div>
	</div>
</div>

<style>
	.lg-stars {
		position: absolute;
		inset: -10%;
		background-repeat: repeat;
		pointer-events: none;
	}
	.lg-stars--far {
		opacity: 0.3;
		background-size: 170px 170px;
		background-image:
			radial-gradient(1px 1px at 24px 32px, var(--text-3), transparent),
			radial-gradient(1px 1px at 96px 12px, var(--text-3), transparent),
			radial-gradient(1px 1px at 142px 78px, var(--text-3), transparent),
			radial-gradient(1px 1px at 56px 118px, var(--text-3), transparent),
			radial-gradient(1px 1px at 158px 54px, var(--text-3), transparent);
		animation: lg-drift-far 110s linear infinite;
	}
	.lg-stars--near {
		opacity: 0.7;
		background-size: 320px 320px;
		background-image:
			radial-gradient(1.5px 1.5px at 60px 80px, var(--text-2), transparent),
			radial-gradient(2px 2px at 280px 200px, var(--text-1), transparent),
			radial-gradient(2px 1px at 160px 300px, var(--accent-hi), transparent),
			radial-gradient(1.5px 1.5px at 230px 50px, var(--text-2), transparent);
		animation: lg-drift-near 60s linear infinite;
	}
	@keyframes lg-drift-far {
		to {
			background-position: -170px 0;
		}
	}
	@keyframes lg-drift-near {
		to {
			background-position: -320px 0;
		}
	}
	.lg-blink {
		animation: lg-blink 1.6s ease-in-out infinite;
	}
	@keyframes lg-blink {
		0%,
		100% {
			opacity: 0.35;
		}
		50% {
			opacity: 0.9;
		}
	}
	@media (prefers-reduced-motion: reduce) {
		.lg-stars--far,
		.lg-stars--near {
			animation-duration: 1200s;
		}
		.lg-blink {
			animation: none;
			opacity: 0.7;
		}
	}
</style>
