<script lang="ts">
	import { onMount } from 'svelte';
	import QRCode from 'qrcode';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Label } from '$lib/components/ui/label';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';
	import ConfirmButton from '$lib/components/shell/ConfirmButton.svelte';
	import { relativeTime } from '$lib/shell/format';
	import { apiBase } from '$lib/api';
	import { buildPairUrl, buildRelayPairUrl } from '$lib/remote/pairUrl';
	import {
		getRemoteAccess,
		setRemoteAccess,
		getRemoteInterfaces,
		listDevices,
		generatePairCode,
		revokeDevice,
		listAudit,
		type RemoteAccess,
		type RemoteAccessMode,
		type Device,
		type AuditEvent
	} from '$lib/remote/devices';

	const EMPTY_REMOTE: RemoteAccess = {
		enabled: false,
		mode: 'direct',
		host: null,
		relay_url: null,
		relay_handle: null,
		relay_secret: null
	};

	const MODES = [
		{ id: 'direct', label: 'Direct' },
		{ id: 'via_relay', label: 'Via relay' }
	] satisfies { id: RemoteAccessMode; label: string }[];

	let remote = $state<RemoteAccess>({ ...EMPTY_REMOTE });
	let host = $state('');
	let mode = $state<RemoteAccessMode>('direct');
	let relayUrl = $state('');
	let relayHandle = $state('');
	let relaySecret = $state('');
	let detected = $state<string[]>([]);
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

	// The phone reaches the instance at the configured mesh host on the backend
	// port (0.0.0.0 binds both). Desktop renders inside tauri://localhost (no
	// port), so buildPairUrl derives the port from apiBase there; the web release
	// has a blank apiBase and uses window.location.port. TLS is deferred → http.
	const pairUrl = $derived.by(() => {
		if (mode === 'via_relay') {
			return buildRelayPairUrl(remote.relay_url || relayUrl, remote.relay_handle || relayHandle, code);
		}
		const windowPort = typeof window !== 'undefined' ? window.location.port : '';
		return buildPairUrl(remote.host || host, code, apiBase, windowPort);
	});

	// Enabling needs the mode's required fields: a mesh host (direct) or the full
	// relay triple (via_relay).
	const canEnable = $derived(
		mode === 'via_relay'
			? !!(relayUrl.trim() && relayHandle.trim() && relaySecret.trim())
			: !!host.trim()
	);

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
			syncFromRemote();
			devices = await listDevices();
			audit = await listAudit();
		} catch (e) {
			error = e instanceof Error ? e.message : 'failed to load remote access';
		}
		// Non-fatal: interface detection is a convenience, never blocks the section.
		try {
			const ifs = await getRemoteInterfaces();
			detected = ifs.candidates;
			// Pre-fill the likely mesh IP only when nothing is saved/typed yet.
			if (!host.trim() && ifs.suggested) host = ifs.suggested;
		} catch {
			// leave detection empty
		}
	}

	// Mirror the server's view of the config into the editable inputs.
	function syncFromRemote() {
		host = remote.host ?? '';
		mode = remote.mode ?? 'direct';
		relayUrl = remote.relay_url ?? '';
		relayHandle = remote.relay_handle ?? '';
		relaySecret = remote.relay_secret ?? '';
	}

	async function toggle(next: boolean) {
		if (saving) return;
		saving = true;
		error = '';
		restartRequired = false;
		try {
			const result = await setRemoteAccess({
				enabled: next,
				mode,
				host: host.trim() || null,
				relay_url: relayUrl.trim() || null,
				relay_handle: relayHandle.trim() || null,
				relay_secret: relaySecret.trim() || null
			});
			remote = result.data;
			syncFromRemote();
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
		Reach this instance from a paired device. <span class="text-ink-1">Direct</span> binds the network
		interface for a mesh VPN; <span class="text-ink-1">Via relay</span> exposes the instance through a
		relay subdomain. Off by default; enabling applies on the next restart.
	</p>

	<!-- Mode selector — locked while enabled (switching modes requires a disable/re-enable cycle). -->
	<div class="flex flex-col gap-2">
		<Label>Connection mode</Label>
		<div class="flex w-fit gap-1 rounded-[8px] border border-hair p-0.5">
			{#each MODES as opt (opt.id)}
				<button
					type="button"
					aria-pressed={mode === opt.id}
					disabled={remote.enabled || saving}
					class="rounded-[6px] px-2.5 py-1 text-meta transition-colors disabled:opacity-50
						{mode === opt.id ? 'bg-panel text-ink-1' : 'text-ink-3 hover:text-ink-2'}"
					onclick={() => (mode = opt.id)}
				>
					{opt.label}
				</button>
			{/each}
		</div>
	</div>

	{#if mode === 'direct'}
		<div class="flex flex-col gap-2">
			<Label for="remote-host">Mesh host (the name/IP this machine is reached at)</Label>
			<Input id="remote-host" bind:value={host} placeholder="laptop.tailnet.ts.net" />
			{#if detected.length > 0}
				<div class="flex flex-wrap items-center gap-1.5">
					<span class="text-meta text-ink-3">Detected:</span>
					{#each detected as ip (ip)}
						<button
							type="button"
							class="rounded-[6px] border border-hair px-1.5 py-0.5 font-mono text-meta text-ink-2 hover:text-ink-1"
							onclick={() => (host = ip)}
						>
							{ip}
						</button>
					{/each}
				</div>
			{/if}
		</div>
	{:else}
		<div class="flex flex-col gap-2">
			<Label for="relay-url">Relay URL</Label>
			<Input id="relay-url" bind:value={relayUrl} placeholder="https://relay.example.com" />
			<Label for="relay-handle">Relay handle (your instance's subdomain)</Label>
			<Input id="relay-handle" bind:value={relayHandle} placeholder="laptop" />
			<Label for="relay-secret">Relay secret</Label>
			<Input id="relay-secret" type="password" bind:value={relaySecret} placeholder="••••••••" />
			<p class="text-meta text-ink-3">
				Devices pair against <span class="font-mono text-ink-2">{relayHandle || '<handle>'}.{relayUrl
					? relayUrl.replace(/^https?:\/\//, '')
					: '<relay-host>'}</span>. Device tokens are origin-scoped — pair again on the relay origin
				even if a device was already paired directly.
			</p>
		</div>
	{/if}

	<div class="flex items-center gap-2">
		{#if remote.enabled}
			<Button size="sm" variant="outline" onclick={() => toggle(false)} disabled={saving}>
				Disable remote access
			</Button>
			<span class="text-meta text-ok">
				{#if remote.mode === 'via_relay'}
					Enabled · relay {remote.relay_handle}
				{:else}
					Enabled · host {remote.host}
				{/if}
			</span>
		{:else}
			<Button size="sm" onclick={() => toggle(true)} disabled={saving || !canEnable}>
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
			{#if mode === 'via_relay'}
				{#if !pairUrl}
					<p class="text-center text-meta text-bad">Set the relay URL and handle above so the QR points at the relay subdomain.</p>
				{:else}
					<p class="text-center text-meta text-ink-3">Pair again on the relay origin — device tokens are origin-scoped.</p>
				{/if}
			{:else if !remote.host && !host.trim()}
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
