<script lang="ts">
	import { onDestroy } from 'svelte';
	import { createAcpSession } from '$lib/shell/acpSession.svelte';
	import ToolCall from './acp-parts/ToolCall.svelte';
	import PermissionCard from './acp-parts/PermissionCard.svelte';
	import PlanBar from './acp-parts/PlanBar.svelte';
	import Composer from './acp-parts/Composer.svelte';

	let { sessionId }: { sessionId: string } = $props();

	// The store joins one `session:<id>` channel for the component's lifetime;
	// capturing the initial sessionId once is intended (no re-subscribe on change).
	// svelte-ignore state_referenced_locally
	const acp = createAcpSession(sessionId);
	onDestroy(() => acp.dispose());

	// Suspend parity with Terminal: kill the ACP adapter process via the
	// transport-agnostic channel `stop`. Bound by SessionPane for the menu.
	export function requestStop() {
		acp.stop();
	}

	// Agent output is untrusted: every text field below is rendered with plain
	// Svelte interpolation ({asText(...)}), which auto-escapes. No {@html}, no
	// markdown renderer — whitespace-pre-wrap preserves line breaks instead.
	// `AcpItem.text` is typed `unknown` via the index signature, so we coerce here.
	const asText = (value: unknown) => (typeof value === 'string' ? value : '');

	// The reducer emits at most one `commands` and one `mode` singleton; derive
	// them from the stream for the composer.
	const commandsItem = $derived(acp.items.find((it) => it.type === 'commands'));
	const commands = $derived(
		commandsItem && Array.isArray(commandsItem.commands)
			? (commandsItem.commands as unknown[]).filter((c): c is string => typeof c === 'string')
			: ([] as string[])
	);
	const modeItem = $derived(acp.items.find((it) => it.type === 'mode'));
	const mode = $derived(modeItem && typeof modeItem.mode === 'string' ? modeItem.mode : null);
</script>

<div class="flex h-full min-h-0 flex-col bg-app">
	<div class="flex flex-1 flex-col gap-3.5 overflow-auto px-4 py-4">
		{#each acp.items as item (item.id)}
			{#if item.type === 'message' && item.role === 'user'}
				<!-- user turn: soft right-aligned bubble -->
				<div
					class="max-w-[82%] self-end whitespace-pre-wrap break-words rounded-[12px_12px_4px_12px] border border-hair-strong bg-panel px-3 py-2 text-ui text-ink-1"
				>
					{asText(item.text)}
				</div>
			{:else if item.type === 'message'}
				<!-- assistant turn: plain prose, no avatar -->
				<div class="whitespace-pre-wrap break-words text-ui text-ink-1">{asText(item.text)}</div>
			{:else if item.type === 'thought'}
				<!-- reasoning strip -->
				<div
					class="whitespace-pre-wrap break-words border-l-2 border-hair-strong pl-3 text-meta text-ink-3"
				>
					{asText(item.text)}
				</div>
			{:else if item.type === 'tool'}
				<ToolCall {item} />
			{:else if item.type === 'permission'}
				<PermissionCard {item} onAnswer={acp.answerPermission} />
			{/if}
			<!-- plan/commands/mode are dock singletons, rendered below the stream -->
		{/each}
	</div>

	<!-- sticky dock: plan above the queue+composer -->
	<div class="border-t border-hair">
		<PlanBar items={acp.items} />
		<Composer
			busy={acp.busy}
			{commands}
			{mode}
			onPrompt={acp.prompt}
			onCancel={acp.cancel}
			onSetMode={acp.setMode}
		/>
	</div>
</div>
