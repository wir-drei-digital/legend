<script lang="ts">
	import { onMount } from 'svelte';
	import QRCode from 'qrcode';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import { relativeTime } from '$lib/shell/format';
	import {
		getRemoteAccess,
		setRemoteAccess,
		listDevices,
		generatePairCode,
		revokeDevice,
		listAudit,
		type RemoteAccess,
		type Device,
		type AuditEvent
	} from '$lib/remote/devices';

	let remote = $state<RemoteAccess>({ enabled: false, host: null });
	let host = $state('');
	let saving = $state(false);
	let restartRequired = $state(false);
	let error = $state('');

	let devices = $state<Device[]>([]);
	let audit = $state<AuditEvent[]>([]);
	let auditOpen = $state(false);

	// Active pairing code + its QR data URL.
	let code = $state('');
	let qr = $state('');
	let codeExpires = $state('');

	const activeDevices = $derived(devices.filter((d) => !d.revoked_at));

	// The phone reaches the instance at the configured mesh host on the same port
	// the desktop browser is using (0.0.0.0 binds both). TLS is deferred → http.
	const pairUrl = $derived.by(() => {
		const h = (remote.host || host).trim();
		if (!h || !code) return '';
		const port = typeof window !== 'undefined' ? window.location.port : '';
		const authority = port ? `${h}:${port}` : h;
		return `http://${authority}/pair?code=${encodeURIComponent(code)}`;
	});

	$effect(() => {
		if (pairUrl) {
			void QRCode.toDataURL(pairUrl, { margin: 1, width: 220 }).then((url) => (qr = url));
		} else {
			qr = '';
		}
	});

	async function load() {
		error = '';
		try {
			remote = await getRemoteAccess();
			host = remote.host ?? '';
			devices = await listDevices();
			audit = await listAudit();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load remote access';
		}
	}

	async function toggle(next: boolean) {
		if (saving) return;
		saving = true;
		error = '';
		restartRequired = false;
		try {
			const result = await setRemoteAccess(next, host.trim() || null);
			remote = result.data;
			host = remote.host ?? '';
			restartRequired = !!result.restart_required;
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to save';
		} finally {
			saving = false;
		}
	}

	async function newCode() {
		error = '';
		try {
			const c = await generatePairCode();
			code = c.code;
			codeExpires = c.expires_at;
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to generate code';
		}
	}

	async function revoke(id: string) {
		try {
			await revokeDevice(id);
			devices = await listDevices();
			audit = await listAudit();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to revoke';
		}
	}

	onMount(load);
</script>

<section class="flex flex-col gap-3">
	<SectionLabel>Remote access</SectionLabel>

	<p class="text-ui text-ink-2">
		Reach this instance from a paired device over your mesh VPN. Off by default; enabling binds the
		network interface on the next restart.
	</p>

	<div class="flex flex-col gap-2">
		<Label for="remote-host">Mesh host (the name/IP this machine is reached at)</Label>
		<Input id="remote-host" bind:value={host} placeholder="laptop.tailnet.ts.net" />
	</div>

	<div class="flex items-center gap-2">
		{#if remote.enabled}
			<Button size="sm" variant="outline" onclick={() => toggle(false)} disabled={saving}>
				Disable remote access
			</Button>
			<span class="text-meta text-ok">Enabled · host {remote.host}</span>
		{:else}
			<Button size="sm" onclick={() => toggle(true)} disabled={saving || !host.trim()}>
				Enable remote access
			</Button>
		{/if}
	</div>

	{#if restartRequired}
		<p class="text-ui text-ink-2">Restart Legend to apply the new bind.</p>
	{/if}

	<!-- Pairing -->
	<div class="flex flex-col gap-2 rounded-[10px] border border-hair p-3">
		<div class="flex items-center justify-between">
			<span class="text-ui font-medium text-ink-1">Pair a device</span>
			<Button size="sm" variant="outline" onclick={newCode}>Generate code</Button>
		</div>

		{#if code}
			{#if qr}
				<img src={qr} alt="Pairing QR code" class="self-center rounded-[8px] bg-white p-2" width="180" height="180" />
			{/if}
			<p class="text-center font-mono text-body text-ink-1">{code}</p>
			<p class="text-center text-meta text-ink-3">
				Scan the QR or enter the code on the device. Expires {relativeTime(codeExpires)}.
			</p>
			{#if !remote.host && !host.trim()}
				<p class="text-center text-meta text-bad">Set the mesh host above so the QR points at the right address.</p>
			{/if}
		{/if}
	</div>

	<!-- Paired devices -->
	{#if activeDevices.length > 0}
		<div class="flex flex-col gap-1">
			<span class="text-meta text-ink-3">Paired devices</span>
			{#each activeDevices as d (d.id)}
				<div class="flex items-center gap-2 rounded-[8px] border border-hair px-3 py-2">
					<span class="min-w-0 flex-1 truncate text-ui text-ink-1">{d.name || 'unnamed device'}</span>
					<span class="shrink-0 text-meta text-ink-3">
						{d.last_seen_at ? `seen ${relativeTime(d.last_seen_at)}` : 'never seen'}
					</span>
					<ConfirmButton idleLabel="Revoke" confirmLabel="Confirm revoke" onconfirm={() => revoke(d.id)} />
				</div>
			{/each}
		</div>
	{/if}

	<!-- Audit trail -->
	<div class="flex flex-col gap-1">
		<button
			type="button"
			class="self-start text-meta text-ink-3 underline underline-offset-2 hover:text-ink-2"
			onclick={() => (auditOpen = !auditOpen)}
		>
			{auditOpen ? 'Hide' : 'Show'} audit trail ({audit.length})
		</button>
		{#if auditOpen}
			<div class="flex max-h-[180px] flex-col gap-0.5 overflow-y-auto rounded-[8px] border border-hair p-2">
				{#each audit as e (e.id)}
					<div class="flex items-center gap-2 font-mono text-micro text-ink-3">
						<span class="text-ink-2">{e.action}</span>
						<span class="truncate">{e.device_id ?? 'local'}</span>
						<span class="ml-auto shrink-0">{relativeTime(e.at)}</span>
					</div>
				{:else}
					<p class="text-micro text-ink-3">No events yet.</p>
				{/each}
			</div>
		{/if}
	</div>

	{#if error}
		<p class="text-ui text-bad">{error}</p>
	{/if}
</section>
