<script lang="ts">
	import Queue from './Queue.svelte';

	// The composer's PRIMARY job is sending a TEXT prompt via onPrompt(text).
	// When the agent is busy, the text is pushed onto a local queue ($state<string[]>)
	// that flushes (one item) when `busy` flips back to false. The queue lives here and
	// renders through the <Queue> part.
	let {
		busy,
		commands,
		mode,
		onPrompt,
		onCancel,
		onSetMode
	}: {
		busy: boolean;
		commands: string[];
		mode: string | null;
		onPrompt: (text: string) => void;
		onCancel: () => void;
		onSetMode: (mode: string) => void;
	} = $props();

	let text = $state('');
	let queue = $state<string[]>([]);

	function submit() {
		const value = text.trim();
		if (!value) return;
		if (busy) queue = [...queue, value];
		else onPrompt(value);
		text = '';
	}

	// Flush the next queued prompt when the agent goes idle.
	$effect(() => {
		if (!busy && queue.length) {
			const [next, ...rest] = queue;
			queue = rest;
			onPrompt(next);
		}
	});

	function onKeydown(e: KeyboardEvent) {
		// ⏎ submits; ⇧⏎ inserts a newline (default behaviour).
		if (e.key === 'Enter' && !e.shiftKey) {
			e.preventDefault();
			submit();
		}
	}

	// Send-now: pull a queued row out and prompt it immediately. ACP queues
	// server-side per turn, so this is allowed even while busy.
	function sendNow(index: number) {
		const value = queue[index];
		if (value === undefined) return;
		queue = queue.filter((_, i) => i !== index);
		onPrompt(value);
	}
	function removeAt(index: number) {
		queue = queue.filter((_, i) => i !== index);
	}
	// Edit pulls the row back into the input (replacing whatever is unsent there).
	function editAt(index: number) {
		const value = queue[index];
		if (value === undefined) return;
		queue = queue.filter((_, i) => i !== index);
		text = value;
	}

	// Mode chip cycles to the next mode the harness reports. Phase-1: we only have
	// the current mode string, so the chip simply re-asserts it (a no-op toggle hook
	// for the host to extend) — clicking surfaces intent without inventing modes.
	function cycleMode() {
		if (mode) onSetMode(mode);
	}

	// Slash hints: surface the first few commands the harness advertises.
	const slashHints = $derived(commands.slice(0, 4));
</script>

<div>
	<!-- sticky queue above the composer -->
	<Queue {queue} onSendNow={sendNow} onRemove={removeAt} onEdit={editAt} />

	<div class="bg-shell px-3 pb-3 pt-2.5">
		<div
			class="overflow-hidden rounded-lg border border-hair-strong bg-app focus-within:border-brand"
		>
			<textarea
				bind:value={text}
				onkeydown={onKeydown}
				rows="2"
				placeholder="Message the agent…  ⏎ send · ⇧⏎ newline · @ file · / command — sends now, or queues while busy"
				class="block min-h-10 w-full resize-none bg-transparent px-3 pb-1.5 pt-2.5 text-body text-ink-1 placeholder:text-ink-3 focus:outline-none"
			></textarea>

			<div class="flex flex-wrap items-center gap-1.5 px-2 pb-2 pt-1.5">
				<!-- Phase-1: context chips are an honest visual affordance only — no file
				     picker, no fake attached state, no content-block assembly yet. -->
				<button
					type="button"
					disabled
					title="Add context (coming soon)"
					class="cursor-default rounded-sm border border-dashed border-hair-strong px-2 py-0.5 text-meta text-ink-2 opacity-60"
				>
					＠ Add context
				</button>

				<span class="flex-1"></span>

				{#if mode}
					<button
						type="button"
						onclick={cycleMode}
						title="Session mode"
						class="rounded-sm border border-hair-strong bg-panel px-2 py-1 text-meta text-ink-2 hover:bg-raised"
					>
						{mode} ▾
					</button>
				{/if}

				{#if busy}
					<button
						type="button"
						onclick={onCancel}
						title="Stop the current turn"
						class="h-[30px] rounded-md border border-hair-strong px-2.5 text-meta text-bad hover:bg-bad/10"
					>
						■ Stop
					</button>
					<button
						type="button"
						onclick={submit}
						title="Agent is busy — enqueue"
						class="h-[30px] rounded-md border border-hair-strong px-2.5 text-meta text-brand-hi hover:bg-raised"
					>
						＋ Queue
					</button>
				{:else}
					<button
						type="button"
						onclick={submit}
						title="Send"
						class="grid h-[30px] w-8 place-items-center rounded-md bg-brand text-title text-void hover:bg-brand-hi"
					>
						↑
					</button>
				{/if}
			</div>
		</div>

		<div class="mt-1.5 flex flex-wrap items-center gap-2.5 text-meta text-ink-3">
			{#if slashHints.length}
				<span class="flex items-center gap-1.5">
					{#each slashHints as cmd (cmd)}
						<code class="font-mono text-brand-hi">/{cmd}</code>
					{/each}
				</span>
			{/if}
			<span class="flex items-center gap-1">⏎ send · ⇧⏎ newline</span>
		</div>
	</div>
</div>
