import { getSocket } from '$lib/socket';
import type { Channel } from 'phoenix';
import type { SessionStatus } from '$lib/sessions';

export interface AcpItem { id: string; seq: number; type: string; [k: string]: unknown; }

export function createAcpSession(sessionId: string) {
  let channel: Channel | undefined;
  const byId = new Map<string, AcpItem>();
  let cursor = 0;
  const state = $state({ items: [] as AcpItem[], status: 'starting' as SessionStatus, busy: false });

  function rebuild() { state.items = [...byId.values()].sort((a, b) => a.seq - b.seq); }
  function upsert(item: AcpItem) {
    if (item.seq <= cursor && byId.has(item.id)) return;
    byId.set(item.id, item);
    cursor = Math.max(cursor, item.seq);
    // busy is driven by the prompt→turn lifecycle, not item type. The backend emits a
    // `turn` item on EVERY turn completion (success and error → stop_reason "error"), so
    // clearing busy only on `turn` is sufficient: trailing tool/plan/nudge items never
    // touch busy. A live turn item always carries a fresh (higher) seq, so the dedup
    // early-return above can never drop it — the clear below always runs for a real turn.
    if (item.type === 'turn') state.busy = false;
    rebuild();
  }

  const chan = getSocket().channel(`session:${sessionId}`);
  channel = chan;
  let joined = false;

  chan.on('event', ({ seq, item }: { seq: number; item: AcpItem }) => upsert({ ...item, seq }));
  chan.on('status', ({ status }: { status: SessionStatus }) => { state.status = status; });
  chan.on('exit', () => { state.status = 'exited'; state.busy = false; });

  chan.join().receive('ok', (reply: { transport: string; items?: AcpItem[]; cursor?: number; status: SessionStatus; busy?: boolean }) => {
    state.status = reply.status;
    // Seed busy from the authoritative server-side turn-in-flight flag on EVERY
    // join/rejoin — fixes mid-turn reattach showing a falsely idle composer.
    state.busy = reply.busy ?? false;
    if (!joined && reply.items) {
      byId.clear();
      cursor = reply.cursor ?? 0;
      for (const it of reply.items) byId.set(it.id, it);
      rebuild();
    }
    joined = true;
  });

  return {
    get items() { return state.items; },
    get status() { return state.status; },
    get busy() { return state.busy; },
    prompt: (content: unknown) => {
      // Raise busy on send so the Composer's true→false falling edge fires even for an
      // instant/empty turn (FS-3): the queue drains on turn completion, never strands.
      state.busy = true;
      chan.push('prompt', { content });
    },
    cancel: () => chan.push('cancel', {}),
    setMode: (mode: string) => chan.push('set_mode', { mode }),
    answerPermission: (request_id: string, option_id: string) => chan.push('permission', { request_id, option_id }),
    stop: () => chan.push('stop', {}),
    dispose: () => { chan.leave(); channel = undefined; }
  };
}
