<script lang="ts">
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { redeemPairCode } from '$lib/remote/devices';
	import { setDeviceToken } from '$lib/remote/deviceToken';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';

	let code = $state('');
	let name = $state('');
	let status = $state<'idle' | 'pairing' | 'done' | 'error'>('idle');
	let error = $state('');

	async function pair() {
		const c = code.trim();
		if (!c || status === 'pairing') return;
		status = 'pairing';
		error = '';
		try {
			const { token } = await redeemPairCode(c, name.trim() || undefined);
			setDeviceToken(token);
			status = 'done';
			// Full navigation so the singleton socket/api clients re-init with the token.
			window.location.href = '/';
		} catch (e) {
			status = 'error';
			error = e instanceof Error ? e.message : 'pairing failed';
		}
	}

	onMount(() => {
		// A QR deep-link arrives as /pair?code=XXXX → prefill and auto-submit.
		const fromUrl = page.url.searchParams.get('code');
		if (fromUrl) {
			code = fromUrl;
			void pair();
		}
	});
</script>

<div class="flex min-h-dvh flex-col items-center justify-center bg-shell px-6">
	<div class="w-full max-w-[360px] rounded-[14px] border border-hair bg-panel p-6">
		<h1 class="text-title font-semibold text-ink-1">Pair this device</h1>
		<p class="mt-1 text-ui text-ink-3">Enter the pairing code shown in Legend on your computer.</p>

		<form
			class="mt-5 flex flex-col gap-3"
			onsubmit={(e) => {
				e.preventDefault();
				pair();
			}}
		>
			<Input bind:value={code} placeholder="Pairing code" autocomplete="off" />
			<Input bind:value={name} placeholder="Device name (optional)" autocomplete="off" />
			<Button type="submit" disabled={!code.trim() || status === 'pairing'}>
				{status === 'pairing' ? 'Pairing…' : 'Pair'}
			</Button>
		</form>

		{#if status === 'error'}
			<p class="mt-3 text-ui text-bad">{error}</p>
		{/if}
		{#if status === 'done'}
			<p class="mt-3 text-ui text-ok">Paired. Opening Legend…</p>
		{/if}
	</div>
</div>
