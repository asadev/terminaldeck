// Copied from the reference CRM.
/**
 * OPTIMISTIC ROWS THAT SAVE THEMSELVES — the hook behind every section of the
 * task detail panel.
 *
 * A section component reports `onChange(nextRows)`. This hook shows `nextRows`
 * AT ONCE, works out what the server needs to hear (detail-persist.ts), runs
 * those calls one after another, and — if any of them is refused — puts the
 * rows back exactly as they were and hands the reason to `onError`. Nothing
 * waits for the network to draw, and nothing pretends a refused write went in.
 *
 * ONE QUEUE PER SECTION. Ops run strictly in order so that an id the server
 * returned for one change (a new checklist) is known before the next change
 * that needs it (an item in that checklist) is sent. `idMap` is that memory.
 *
 * THE ROWS ON SCREEN KEEP THEIR CLIENT IDS. A row added from the panel is born
 * with a `draftRowId`; the server's id goes into `idMap` and every later op
 * resolves through it (`id()` in detail-persist.ts). The screen is never
 * rewritten with the server id, because the sections key their DOM on the row
 * id — swapping it would REMOUNT the row, and a checklist whose id arrives
 * while its first item is being typed would eat the half-typed item.
 *
 * A FAILURE DROPS WHAT WAS QUEUED BEHIND IT. If change 1 is refused while
 * change 2 is waiting, the rows revert to before change 1 — which is also
 * before change 2 — and change 2 is not sent. Client and server agree again
 * (neither happened); the error line says what was refused. Sending change 2
 * anyway would leave the screen showing the reverted state while the server
 * holds the change, which is the lie this whole file exists to avoid.
 */

import { useCallback, useRef, useState } from "react";
import type { DetailActions } from "./detail-actions";
import { runOps, type Diff, type Op } from "./detail-persist";

export type SyncedRows<T> = {
  /** null until `seed` — the section has not loaded yet. */
  rows: T | null;
  /** Put the server's rows in; clears the id memory. */
  seed: (initial: T) => void;
  /** The section changed the rows: show, diff, persist, revert on refusal.
   *  `after` runs once every op in this change has been accepted. */
  change: (next: T, after?: () => void) => void;
  /** Run ops that were not produced by a diff (a debounced rename) with the same
   *  revert-on-refusal contract; `fallback` is what to show if they fail. */
  enqueue: (ops: Op[], fallback: T, after?: () => void) => void;
  /** Show rows WITHOUT persisting — for a change the server already made as a
   *  side effect of something else (a person joining the task because a
   *  subtask was handed to them). */
  local: (next: T) => void;
  /** Read the rows right now, outside React's render cycle. */
  current: () => T | null;
};

export function useSyncedRows<T>({
  actions,
  diff,
  onError,
}: {
  actions: DetailActions;
  diff: (prev: T, next: T) => Diff;
  onError: (message: string) => void;
}): SyncedRows<T> {
  const [rows, setRows] = useState<T | null>(null);
  const ref = useRef<T | null>(null);
  const idMap = useRef(new Map<string, string>());
  const queue = useRef<Promise<void>>(Promise.resolve());
  // Bumped on a refusal; a job whose generation is stale skips itself.
  const gen = useRef(0);

  const set = useCallback((next: T) => {
    ref.current = next;
    setRows(next);
  }, []);

  const seed = useCallback(
    (initial: T) => {
      idMap.current = new Map();
      gen.current += 1;
      set(initial);
    },
    [set],
  );

  const enqueue = useCallback(
    (ops: Op[], fallback: T, after?: () => void) => {
      if (!ops.length) {
        after?.();
        return;
      }
      const myGen = gen.current;
      queue.current = queue.current.then(async () => {
        if (gen.current !== myGen) return;
        const r = await runOps(ops, actions, idMap.current);
        if (gen.current !== myGen) return;
        if (!r.ok) {
          gen.current += 1;
          set(fallback);
          onError(r.error);
          return;
        }
        after?.();
      });
    },
    [actions, onError, set],
  );

  const change = useCallback(
    (next: T, after?: () => void) => {
      const prev = ref.current;
      if (prev === null) return;
      set(next);
      const d = diff(prev, next);
      if ("refused" in d) {
        set(prev);
        onError(d.refused);
        return;
      }
      enqueue(d.ops, prev, after);
    },
    [diff, enqueue, onError, set],
  );

  const current = useCallback(() => ref.current, []);

  return { rows, seed, change, enqueue, local: set, current };
}
