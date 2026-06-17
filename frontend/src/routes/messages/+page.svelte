<script lang="ts">
	import MessageComposer from '$lib/components/MessageComposer.svelte';
	import SectionLabel from '$lib/components/shell/SectionLabel.svelte';
	import type { Message } from '$lib/messages';
	import { messagesStore } from '$lib/stores/messages.svelte';
	import { sessionsStore } from '$lib/stores/sessions.svelte';

	$effect(() => {
		messagesStore.connect();
		sessionsStore.connect();
	});

	const byId = $derived(new Map(sessionsStore.sessions.map((s) => [s.id, s])));

	// Delegation chain root: walk spawned_by links (cycle-safe).
	function rootOf(id: string): string {
		let current = id;
		const seen = new Set<string>();
		while (!seen.has(current)) {
			seen.add(current);
			const parent = byId.get(current)?.spawned_by_session_id;
			if (!parent) break;
			current = parent;
		}
		return current;
	}

	function sessionLabel(id: string | null): string {
		if (!id) return 'human';
		const s = byId.get(id);
		return s ? s.name || s.harness_id : `${id.slice(0, 8)}…`;
	}

	interface Group {
		root: string;
		messages: Message[];
	}

	const groups = $derived.by((): Group[] => {
		const map = new Map<string, Message[]>();
		for (const m of messagesStore.messages) {
			const key = rootOf(m.from_session_id ?? m.to_session_id);
			map.set(key, [...(map.get(key) ?? []), m]);
		}
		return [...map.entries()]
			.map(([root, messages]) => ({ root, messages }))
			.sort((a, b) =>
				b.messages[b.messages.length - 1].inserted_at.localeCompare(
					a.messages[a.messages.length - 1].inserted_at
				)
			);
	});

	const kindBadge: Record<string, string> = {
		message: 'bg-[var(--accent-soft)] text-brand-hi',
		handoff: 'bg-[color-mix(in_oklab,var(--amber)_16%,transparent)] text-warn',
		system: 'bg-inset text-ink-3'
	};
</script>

<div class="flex h-full flex-col gap-3 p-4">
	<h1 class="text-title font-semibold text-ink-1">Messages</h1>

	<div class="flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto">
		{#each groups as group (group.root)}
			<section class="rounded-[10px] border border-hair">
				<header class="flex items-center gap-2 border-b border-hair px-3 py-2">
					<SectionLabel>{sessionLabel(group.root)} thread</SectionLabel>
					<span class="font-mono text-meta text-ink-3">{group.messages.length}</span>
				</header>
				<ul class="flex flex-col">
					{#each group.messages as m (m.id)}
						<li
							class="flex items-baseline gap-2 px-3 py-1.5 text-ui text-ink-2 not-last:border-b not-last:border-hair"
						>
							<span class="rounded px-1.5 py-0.5 font-mono text-micro uppercase {kindBadge[m.kind]}"
								>{m.kind}</span
							>
							<span class="shrink-0 font-medium text-ink-1">{m.from_label}</span>
							<span class="shrink-0 text-ink-3">→ {sessionLabel(m.to_session_id)}</span>
							<span class="min-w-0 whitespace-pre-wrap break-words">{m.payload}</span>
							{#if !m.read_at}
								<span class="ml-auto shrink-0 text-meta text-warn">unread</span>
							{/if}
						</li>
					{/each}
				</ul>
			</section>
		{:else}
			{#if messagesStore.loaded}
				<p class="text-ui text-ink-3">No messages yet. Agents (and you) can talk here.</p>
			{/if}
		{/each}
	</div>

	<MessageComposer />
</div>
