// Copied from the reference CRM.
/**
 * FROM "THE ROWS CHANGED" TO "WHICH SERVER ACTIONS TO CALL" — pure, no React.
 *
 * The section components under the compact task box (subtasks-section.tsx,
 * checklist-section.tsx, dependencies-section.tsx, task-people-field.tsx) were
 * written for the CREATE dialog: they hold DRAFT rows and report every change as
 * `onChange(nextRows)`. The detail panel reuses them unchanged against a SAVED
 * task, so somebody has to turn "here is the new array" back into "add this
 * one, delete that one, tick this one". That somebody is this file.
 *
 * Each `diff*` compares the previous rows with the next and returns a list of
 * `Op`s in the order they must run. An op names WHAT it is in plain words (for
 * the error line a person reads), the client-side id it CREATES (so the id the
 * server hands back can replace the draft one), and how to RUN it against the
 * injectable action bundle (detail-actions.ts).
 *
 * IDS ARE RESOLVED AT RUN TIME, not at diff time. `InlineAdd` gives a new row a
 * client-side id (`draftRowId`); the server returns the real one only after the
 * insert. The row on screen KEEPS the client id (see detail-sync.ts for why);
 * an op that touches it later — deleting it, ticking it, adding an item to a
 * checklist that itself was added a moment ago — receives an `id()` function
 * that maps client ids to server ids as they become known. Ops run one at a
 * time (detail-sync.ts), so the mapping is always populated in time.
 *
 * NOTHING HERE IS SWALLOWED. A diff that cannot be honoured returns `refused`
 * with the reason instead of an empty list, and the caller reverts and shows
 * it. An empty list means "nothing changed that the server needs to know".
 */

import type { ActionResult, DetailActions } from "./detail-actions";
import type {
  TaskAttachment,
  TaskChecklist,
  TaskDependency,
  TaskPeople,
  TaskSubtaskRow,
} from "../../shared/crm/collab-types";
import { peopleList } from "./task-collab-draft";

export type ResolveId = (clientId: string) => string;

export type Op = {
  /** Plain words for the error line: 'Adding subtask "Call the landlord"'. */
  what: string;
  /** The client-side id whose server row this op creates; the result's id replaces it. */
  creates?: string;
  run: (actions: DetailActions, id: ResolveId) => Promise<ActionResult>;
};

export type Diff = { ops: Op[] } | { refused: string };

const q = (s: string) => `“${s}”`;

// ── people ──────────────────────────────────────────────────────────────────

/**
 * The header's faces. Adding somebody is `addTaskAssignee` and never touches
 * the primary. Taking the PRIMARY off (task-people-field.tsx promotes the next
 * face in that case) is `assignTask` — the one action that moves
 * ops.tasks.assignee_user_id — and taking the LAST person off is refused:
 * every sub-item without a person of its own falls back to the primary, so a
 * task with nobody would make those items ownerless (collab-types.ts,
 * `effectiveAssignee`).
 */
export function diffPeople(taskId: string, prev: TaskPeople, next: TaskPeople): Diff {
  const ops: Op[] = [];
  const prevIds = new Set(peopleList(prev).map((p) => p.id));
  const nextIds = new Set(peopleList(next).map((p) => p.id));

  const prevPrimary = prev.primary?.id ?? null;
  const nextPrimary = next.primary?.id ?? null;

  if (prevPrimary !== nextPrimary) {
    if (!next.primary) {
      const who = prev.primary?.name ?? "the main person";
      return { refused: `A task needs a main person. Add someone else before taking ${who} off.` };
    }
    const person = next.primary;
    ops.push({
      what: `Making ${person.name} the main person`,
      run: (a) => a.assignTask(taskId, person.id),
    });
  }

  for (const p of peopleList(next)) {
    if (prevIds.has(p.id)) continue;
    // The new primary of a task that had none is assignTask above, not an extra.
    if (p.id === nextPrimary && prevPrimary !== nextPrimary) continue;
    ops.push({ what: `Adding ${p.name}`, run: (a) => a.addTaskAssignee(taskId, p.id) });
  }
  for (const p of peopleList(prev)) {
    if (nextIds.has(p.id)) continue;
    // The old primary leaves by being replaced (assignTask), not by a row delete.
    if (p.id === prevPrimary) continue;
    ops.push({ what: `Removing ${p.name}`, run: (a) => a.removeTaskAssignee(taskId, p.id) });
  }
  return { ops };
}

// ── subtasks ────────────────────────────────────────────────────────────────

export function diffSubtasks(taskId: string, prev: TaskSubtaskRow[], next: TaskSubtaskRow[]): Diff {
  const ops: Op[] = [];
  const before = new Map(prev.map((r) => [r.id, r]));
  const after = new Map(next.map((r) => [r.id, r]));

  for (const r of prev) {
    if (after.has(r.id)) continue;
    ops.push({
      what: `Removing subtask ${q(r.title)}`,
      run: (a, id) => a.deleteTaskSubtask(taskId, id(r.id)),
    });
  }
  for (const r of next) {
    const was = before.get(r.id);
    if (!was) {
      ops.push({
        what: `Adding subtask ${q(r.title)}`,
        creates: r.id,
        run: (a) => a.addTaskSubtask(taskId, r.title),
      });
      if (r.done) {
        ops.push({ what: `Ticking ${q(r.title)}`, run: (a, id) => a.setTaskSubtaskDone(taskId, id(r.id), true) });
      }
      if (r.assigneeUserId) {
        const who = r.assigneeUserId;
        ops.push({ what: `Assigning ${q(r.title)}`, run: (a, id) => a.setTaskSubtaskAssignee(taskId, id(r.id), who) });
      }
      continue;
    }
    if (was.done !== r.done) {
      ops.push({
        what: `${r.done ? "Ticking" : "Unticking"} ${q(r.title)}`,
        run: (a, id) => a.setTaskSubtaskDone(taskId, id(r.id), r.done),
      });
    }
    if (was.assigneeUserId !== r.assigneeUserId) {
      const who = r.assigneeUserId;
      ops.push({
        what: `${who ? "Assigning" : "Unassigning"} ${q(r.title)}`,
        run: (a, id) => a.setTaskSubtaskAssignee(taskId, id(r.id), who),
      });
    }
    // A subtask has no rename action on the server (tasks-actions.ts) and the
    // section offers no way to rename one, so a changed title is not diffed.
  }
  return { ops };
}


// ── checklists ──────────────────────────────────────────────────────────────

/** A title change on a list, kept apart from the ops: it is debounced (a
 *  controlled input fires per keystroke) rather than sent as typed. */
export type Rename = { listId: string; title: string };

export type ChecklistDiff = { ops: Op[]; renames: Rename[] };

function itemOps(
  listClientId: string,
  prevItems: TaskChecklist["items"],
  nextItems: TaskChecklist["items"],
): Op[] {
  const ops: Op[] = [];
  const before = new Map(prevItems.map((i) => [i.id, i]));
  const after = new Map(nextItems.map((i) => [i.id, i]));

  for (const it of prevItems) {
    if (after.has(it.id)) continue;
    ops.push({ what: `Removing item ${q(it.title)}`, run: (a, id) => a.deleteChecklistItem(id(it.id)) });
  }
  for (const it of nextItems) {
    const was = before.get(it.id);
    if (!was) {
      ops.push({
        what: `Adding item ${q(it.title)}`,
        creates: it.id,
        run: (a, id) => a.addChecklistItem(id(listClientId), it.title),
      });
      if (it.done) ops.push({ what: `Ticking ${q(it.title)}`, run: (a, id) => a.setChecklistItemDone(id(it.id), true) });
      if (it.assigneeUserId) {
        const who = it.assigneeUserId;
        ops.push({ what: `Assigning ${q(it.title)}`, run: (a, id) => a.setChecklistItemAssignee(id(it.id), who) });
      }
      continue;
    }
    if (was.done !== it.done) {
      ops.push({
        what: `${it.done ? "Ticking" : "Unticking"} ${q(it.title)}`,
        run: (a, id) => a.setChecklistItemDone(id(it.id), it.done),
      });
    }
    if (was.assigneeUserId !== it.assigneeUserId) {
      const who = it.assigneeUserId;
      ops.push({
        what: `${who ? "Assigning" : "Unassigning"} ${q(it.title)}`,
        run: (a, id) => a.setChecklistItemAssignee(id(it.id), who),
      });
    }
  }
  return ops;
}

export function diffChecklists(taskId: string, prev: TaskChecklist[], next: TaskChecklist[]): ChecklistDiff {
  const ops: Op[] = [];
  const renames: Rename[] = [];
  const before = new Map(prev.map((l) => [l.id, l]));
  const after = new Map(next.map((l) => [l.id, l]));

  for (const l of prev) {
    if (after.has(l.id)) continue;
    // Deleting the list cascades to its items on the server (deleteChecklist).
    ops.push({ what: `Removing checklist ${q(l.title)}`, run: (a, id) => a.deleteChecklist(id(l.id)) });
  }
  for (const l of next) {
    const was = before.get(l.id);
    if (!was) {
      ops.push({
        what: `Adding checklist ${q(l.title)}`,
        creates: l.id,
        run: (a) => a.addChecklist(taskId, l.title),
      });
      ops.push(...itemOps(l.id, [], l.items));
      continue;
    }
    if (was.title !== l.title) renames.push({ listId: l.id, title: l.title });
    ops.push(...itemOps(l.id, was.items, l.items));
  }
  return { ops, renames };
}

export function renameOp(listId: string, title: string): Op {
  return {
    what: `Renaming checklist to ${q(title)}`,
    run: (a, id) => a.renameChecklist(id(listId), title),
  };
}


// ── dependencies ────────────────────────────────────────────────────────────

const depKey = (d: TaskDependency) => `${d.kind}:${d.otherTaskId}`;

export function diffDependencies(taskId: string, prev: TaskDependency[], next: TaskDependency[]): Diff {
  const ops: Op[] = [];
  const before = new Set(prev.map(depKey));
  const after = new Set(next.map(depKey));
  for (const d of prev) {
    if (after.has(depKey(d))) continue;
    ops.push({
      what: `Unlinking ${q(d.otherTitle)}`,
      run: (a) => a.removeTaskDependency(taskId, d.otherTaskId, d.kind),
    });
  }
  for (const d of next) {
    if (before.has(depKey(d))) continue;
    ops.push({
      what: `Linking ${q(d.otherTitle)}`,
      run: (a) => a.addTaskDependency(taskId, d.otherTaskId, d.kind),
    });
  }
  return { ops };
}

// ── attachments ─────────────────────────────────────────────────────────────

/**
 * Only `document` rows can be ADDED from the panel (a pointer at a file already
 * in Files — `attachExistingDocument`); there is no upload route yet, so an
 * `upload` row that appears in `next` without having been in `prev` is refused
 * by name rather than quietly dropped. Any row can be removed.
 */
export function diffAttachments(taskId: string, prev: TaskAttachment[], next: TaskAttachment[]): Diff {
  const ops: Op[] = [];
  const before = new Map(prev.map((a) => [a.id, a]));
  const after = new Set(next.map((a) => a.id));
  for (const a of prev) {
    if (after.has(a.id)) continue;
    ops.push({ what: `Removing ${q(a.fileName)}`, run: (x, id) => x.detachTaskAttachment(id(a.id)) });
  }
  for (const a of next) {
    if (before.has(a.id)) continue;
    if (a.kind !== "document" || !a.documentId) {
      // Uploads never come through this diff: the panel posts the bytes to the
      // route and adds the recorded row with `local()`. A stray upload row here
      // is a programming error, and saying so beats inventing an op for it.
      return { refused: `${q(a.fileName)} was not uploaded — uploads go through the attachment route, not the row diff.` };
    }
    const docId = a.documentId;
    ops.push({
      what: `Attaching ${q(a.fileName)}`,
      creates: a.id,
      run: (x) => x.attachExistingDocument(taskId, docId),
    });
  }
  return { ops };
}


// ── running ─────────────────────────────────────────────────────────────────

/**
 * Run ops in order against the bundle, recording every id the server hands
 * back into `idMap` so later ops (and the caller's rows) can use it. Stops at
 * the first refusal and returns it whole — the caller reverts and shows it.
 */
export async function runOps(
  ops: Op[],
  actions: DetailActions,
  idMap: Map<string, string>,
): Promise<{ ok: true } | { ok: false; error: string }> {
  const id: ResolveId = (c) => idMap.get(c) ?? c;
  for (const op of ops) {
    let r: ActionResult;
    try {
      r = await op.run(actions, id);
    } catch (e) {
      r = { ok: false, error: (e as Error).message || "failed" };
    }
    if (!r.ok) return { ok: false, error: `${op.what}: ${r.error}` };
    if (op.creates) {
      if (!r.id) return { ok: false, error: `${op.what}: saved, but the server returned no id` };
      idMap.set(op.creates, r.id);
    }
  }
  return { ok: true };
}
