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

  chan.on('event', ({ seq, item }: { seq: number; item: AcpItem }) => upsert({ ...item, seq }));
  chan.on('status', ({ status }: { status: SessionStatus }) => { state.status = status; });
  chan.on('exit', () => { state.status = 'exited'; state.busy = false; });

  chan.join().receive('ok', (reply: { transport: string; items?: AcpItem[]; cursor?: number; status: SessionStatus; busy?: boolean }) => {
    state.status = reply.status;
    // Reconcile the snapshot on EVERY join — including Phoenix's silent auto-rejoin
    // after a transient socket reconnect. Feeding each item through `upsert` (NOT a
    // raw byId.set / byId.clear) makes re-applying idempotent: the `seq <= cursor &&
    // byId.has` dedup drops items we already have, while items that broadcast during
    // the disconnect (seq > cursor, where the backend advanced its offset) are applied
    // and advance the cursor via `max`. Never clear — that would drop live items.
    if (reply.items) {
      for (const it of reply.items) upsert(it);
      // Belt for the cursor: upsert's per-item max covers applied items; this guards
      // the case where the snapshot's cursor sits ahead of every item's seq.
      cursor = Math.max(cursor, reply.cursor ?? 0);
      // upsert already rebuilds per item, but ensure the sorted view reflects the
      // fully-reconciled set (cheap; no-op if nothing changed).
      rebuild();
    }
    // Seed busy from the authoritative server-side turn-in-flight flag AFTER the
    // snapshot reconcile, so the server flag is the final word on EVERY join/rejoin.
    // The reconcile loop's `upsert` clears busy when it applies a completed `turn`
    // item; on an auto-rejoin where a finished turn sits in the snapshot while a NEW
    // turn is in flight (server busy = true), seeding first would let the loop falsely
    // clear it → idle composer mid-turn. Seeding last keeps the server flag authoritative.
    state.busy = reply.busy ?? false;
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
