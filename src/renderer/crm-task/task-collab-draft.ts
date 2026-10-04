// Copied from the reference CRM.
/**
 * WHAT THE NEW-ITEM DIALOG IS HOLDING BEFORE THE TASK EXISTS.
 *
 * The task box collects five things that live in their own tables —
 * ops.task_assignees, ops.task_subtasks, ops.task_checklists(+_items),
 * ops.task_dependencies, ops.task_attachments (migrations/
 * 2026-09-14-task-collaboration.sql). None of them can be written until the
 * task itself has an id, so while the dialog is open they live HERE, in one
 * object, keyed by client-side ids.
 *
 * 🔴 THIS IS NOT A SECOND SET OF TYPES. The rows are `TaskSubtaskRow`,
 * `TaskChecklist`, `TaskChecklistItem`, `TaskDependency` and `TaskPeople` from
 * `@/lib/tasks/collab-types` — the shapes the actions and the DB already
 * speak. The only new shape is `DraftAttachment`, and it exists because an
 * unsaved attachment genuinely is a different thing from a saved one: it has a
 * `File` in memory and no storage path, no uploader and no created_at, because
 * nothing has been uploaded yet.
 */
import type {
  TaskChecklist,
  TaskChecklistItem,
  TaskDependency,
  TaskPeople,
  TaskSubtaskRow,
} from "../../shared/crm/collab-types";
import type { TaskAssignee } from "../../shared/crm/tasks-data";
import { AVATAR_PALETTE, deriveInitials, hashStringToIndex } from "../../shared/crm/task-people";

/**
 * An attachment that is not saved yet. Either a file chosen from the disk
 * (still only in memory) or a pointer at a document already in the Files
 * library — never a copy of one, so a document keeps the permissions it
 * already had instead of growing a second, looser set.
 */
export type DraftAttachment =
  | {
      key: string;
      kind: "upload";
      fileName: string;
      sizeBytes: number;
      mimeType: string;
      /** The real file, held until there is a task id to hang it on. */
      file: File;
    }
  | {
      key: string;
      kind: "document";
      fileName: string;
      documentId: string;
      secondary: string | null;
      href: string;
    };

/** Everything the compact task box has collected, in one object. */
export type TaskCollabDraft = {
  people: TaskPeople;
  subtasks: TaskSubtaskRow[];
  checklists: TaskChecklist[];
  dependencies: TaskDependency[];
  attachments: DraftAttachment[];
};

/** The four optional sections a task box can show. */
export const OPTIONAL_SECTIONS = ["subtasks", "checklist", "dependencies", "attachments"] as const;
export type OptionalSection = (typeof OPTIONAL_SECTIONS)[number];

/**
 * What the "+" MENU offers — ClickUp's "…" menu, copied entry for entry
 * (Asad, 2026-09-15, pointing at it: "also same as this"): Dependencies,
 * Subtasks, Checklist, in that order. Attachments are NOT here: they are
 * reached through the footer paperclip, exactly as in ClickUp.
 */
export const MENU_SECTIONS = ["dependencies", "subtasks", "checklist"] as const satisfies readonly OptionalSection[];

export const SECTION_LABELS: Record<OptionalSection, string> = {
  subtasks: "Subtasks",
  checklist: "Checklist",
  dependencies: "Dependencies",
  attachments: "Attachments",
};

export function emptyDraft(primary: TaskAssignee | null): TaskCollabDraft {
  return {
    people: { primary, others: [] },
    subtasks: [],
    checklists: [],
    dependencies: [],
    attachments: [],
  };
}

/**
 * A client-side id for a row that has none yet. `crypto.randomUUID` is present
 * in every browser this app supports and in Node 19+, but a jsdom test
 * environment can still be missing it, and a React key that comes back
 * `undefined` silently collapses a list — so there is a fallback.
 */
export function draftRowId(): string {
  const c = typeof globalThis !== "undefined" ? globalThis.crypto : undefined;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  return `draft-${Math.random().toString(36).slice(2)}-${Date.now().toString(36)}`;
}

/** Everyone on the task, primary first, for an avatar stack. */
export function peopleList(people: TaskPeople): TaskAssignee[] {
  return people.primary ? [people.primary, ...people.others] : [...people.others];
}

export function isOnTask(people: TaskPeople, id: string): boolean {
  return people.primary?.id === id || people.others.some((p) => p.id === id);
}

/**
 * Add somebody. The FIRST person on an empty task becomes the primary — the
 * one ops.tasks.assignee_user_id stores, the one a sub-item falls back to and
 * the one the notification addresses. Everyone after that is an equal.
 * Adding somebody already on the task is a no-op, not a duplicate.
 */
export function addPerson(people: TaskPeople, person: TaskAssignee): TaskPeople {
  if (isOnTask(people, person.id)) return people;
  if (!people.primary) return { primary: person, others: people.others };
  return { primary: people.primary, others: [...people.others, person] };
}

/**
 * Take somebody off. Removing the PRIMARY promotes the next person rather than
 * leaving the task ownerless — with no primary, every sub-item that inherits
 * would inherit nothing.
 */
export function removePerson(people: TaskPeople, id: string): TaskPeople {
  if (people.primary?.id === id) {
    const [next, ...rest] = people.others;
    return { primary: next ?? null, others: rest };
  }
  return { primary: people.primary, others: people.others.filter((p) => p.id !== id) };
}

/** The face to draw for a sub-item: its own person, or the one it inherits. */
export function assigneeFor(
  itemAssigneeUserId: string | null,
  people: TaskPeople,
): { person: TaskAssignee | null; inherited: boolean } {
  if (itemAssigneeUserId) {
    const own = peopleList(people).find((p) => p.id === itemAssigneeUserId);
    if (own) return { person: own, inherited: false };
  }
  return { person: people.primary, inherited: true };
}

/** A person found by the cross-CRM search, who is not in the team list we were
 *  handed, still needs a face. Same palette and same initials rule the server
 *  uses, so their circle matches the one they have everywhere else. */
export function assigneeFromHit(hit: { id: string; label: string }): TaskAssignee {
  return {
    id: hit.id,
    name: hit.label,
    initials: deriveInitials(hit.label),
    color: AVATAR_PALETTE[hashStringToIndex(hit.id, AVATAR_PALETTE.length)],
    avatarUrl: null,
  };
}

/**
 * Files chosen from the device, as draft rows — held in memory until the task
 * has an id. The same file picked twice is one attachment, not two.
 */
export function withDraftUploads(rows: DraftAttachment[], files: FileList | File[]): DraftAttachment[] {
  const next: DraftAttachment[] = [];
  for (const f of Array.from(files)) {
    if (rows.some((r) => r.kind === "upload" && r.fileName === f.name && r.sizeBytes === f.size)) continue;
    if (next.some((r) => r.kind === "upload" && r.fileName === f.name && r.sizeBytes === f.size)) continue;
    next.push({
      key: draftRowId(),
      kind: "upload",
      fileName: f.name,
      sizeBytes: f.size,
      mimeType: f.type || "application/octet-stream",
      file: f,
    });
  }
  return next.length ? [...rows, ...next] : rows;
}

export function newChecklist(title = "Checklist"): TaskChecklist {
  return { id: draftRowId(), title, sortOrder: null, items: [] };
}

export function newChecklistItem(title: string): TaskChecklistItem {
  return { id: draftRowId(), title, done: false, sortOrder: null, assigneeUserId: null };
}

export function newSubtask(title: string): TaskSubtaskRow {
  return { id: draftRowId(), title, done: false, sortOrder: null, assigneeUserId: null };
}

/** Is there anything here worth saving beyond the task row itself? */
export function draftHasCollaboration(draft: TaskCollabDraft): boolean {
  return (
    draft.people.others.length > 0 ||
    draft.subtasks.length > 0 ||
    draft.checklists.some((c) => c.items.length > 0) ||
    draft.dependencies.length > 0 ||
    draft.attachments.length > 0
  );
}
