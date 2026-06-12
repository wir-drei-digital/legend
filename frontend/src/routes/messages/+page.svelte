<script lang="ts">
	import MessageComposer from '$lib/components/MessageComposer.svelte';
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
		message: 'bg-accent text-accent-foreground',
		handoff: 'bg-amber-100 text-amber-900 dark:bg-amber-950 dark:text-amber-200',
		system: 'bg-muted text-muted-foreground'
	};
</script>

<div class="flex h-full flex-col gap-3 p-4">
	<h1 class="text-lg font-semibold">Messages</h1>

	<div class="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto">
		{#each groups as group (group.root)}
			<section class="rounded-lg border">
				<header class="border-b px-3 py-2 text-sm font-medium">
					{sessionLabel(group.root)} — thread
				</header>
				<ul class="flex flex-col gap-2 p-3">
					{#each group.messages as m (m.id)}
						<li class="flex items-baseline gap-2 text-sm">
							<span class="rounded px-1.5 py-0.5 text-xs {kindBadge[m.kind]}">{m.kind}</span>
							<span class="shrink-0 font-medium">{m.from_label}</span>
							<span class="shrink-0 text-muted-foreground">→ {sessionLabel(m.to_session_id)}</span>
							<span class="min-w-0 whitespace-pre-wrap break-words">{m.payload}</span>
							{#if !m.read_at}
								<span class="ml-auto shrink-0 text-xs text-amber-600">unread</span>
							{/if}
						</li>
					{/each}
				</ul>
			</section>
		{:else}
			{#if messagesStore.loaded}
				<p class="text-sm text-muted-foreground">No messages yet. Agents (and you) can talk here.</p>
			{/if}
		{/each}
	</div>

	<MessageComposer />
</div>
