// Copied from the reference CRM.
import type { TaskMore, DescriptionVersion } from "../../shared/crm/task-more-actions";
import type { RelateKind } from "./page/more-menu";
import { DescriptionHistory } from "./page/description-history";
import { localQuickDates, ymdAddDays } from "../../shared/crm/local-time";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlertCircle,
  AlignLeft,
  CalendarDays,
  ChevronsLeft,
  ChevronsRight,
  CircleCheck,
  CircleDashed,
  FileText,
  Flag,
  GitBranch,
  Link2,
  ListChecks,
  MessageSquare,
  Network,
  RefreshCw,
  Tag,
  Timer,
  UserRound,
  UserPlus,
  X,
  Ban,
  TriangleAlert,
  FolderInput,
  PlaySquare,
  CalendarClock,
  Archive,
  FolderOpen,
} from "lucide-react";
import { cn } from "./lib/utils";
import { Dialog } from "./ui/dialog";
import { AnchoredPopover } from "./anchored-popover";
import { ActivityPane, type PostOptions, type SlashCommand } from "./page/activity-pane";
import type { CommentExtras } from "../../shared/crm/task-comments";
import { TaskPageHeader } from "./page/page-header";
import { Property, StatusCell, TagsCell, TrackTimeCell, TypePill, Unavailable } from "./page/property-cells";
import { SubtasksTable } from "./page/subtasks-table";
import { ChecklistsBlock } from "./page/checklists-block";
import type { TaskActivityRow } from "../../shared/crm/task-activity";
import { PersonAvatar } from "./people/person-picker";
import { PriorityPill } from "./pill-select";
import { TaskPeopleField } from "./task-people-field";
import { AttachButton } from "./attach-button";
import { DatesField } from "./dates-field";
import { summariseTimeline } from "./timeline-field";
import { DependenciesSection } from "./dependencies-section";
import { DetailAttachmentsSection, type PendingUpload } from "./detail-attachments";
import { UPLOADS_WIRED } from "./uploads-wired";
import { DropOverlay } from "./drop-overlay";
import { useFileDrop } from "./use-file-drop";
import { InlineTitle } from "./inline-title";
import { TaskTextField, type InlineFileInfo, type TaskTextFieldHandle } from "./task-text-field";
import { TaskFieldsSection, type TaskFieldActions } from "./task-fields-section";
import { checkUpload, inlineKind } from "../../shared/crm/attachment-rules";
import {
  addPerson,
  assigneeFor,
  draftRowId,
  isOnTask,
  newChecklist,
  peopleList,
  removePerson,
  type OptionalSection,
} from "./task-collab-draft";
import type { DetailActions } from "./detail-actions";
import {
  diffAttachments,
  diffChecklists,
  diffDependencies,
  diffPeople,
  diffSubtasks,
  renameOp,
} from "./detail-persist";
import { useSyncedRows } from "./detail-sync";
import type {
  DependencyKind,
  TaskAttachment,
  TaskChecklist,
  TaskDependency,
  TaskPeople,
  TaskSubtaskRow,
} from "../../shared/crm/collab-types";
import { tagAreaLabel } from "../../shared/crm/tag-areas";
import { STATUS_WORD, splitTaskText, type TaskPageExtras, type TaskType } from "../../shared/crm/task-page";
import { dateMoveNote, legacyRecurrence, type RoutineRule } from "../../shared/crm/recurrence-rules";
import { localTodayClient } from "./page/routine-block";
import type { RoutineView } from "../../shared/crm/routine-actions";
import { RoutineBlock } from "./page/routine-block";
import type { TaskRecurrence } from "../../shared/crm/recurrence";
import {
  taskBoardLabel,
  type Task,
  type TaskAssignee,
  type TaskBoard,
  type TaskComment,
  type TaskPriority,
  type TaskStatus,
} from "../../shared/crm/tasks-data";

const STATUSES: TaskStatus[] = ["To-Do", "Working on it", "In Progress", "Done", "Stuck"];
const PRIORITIES: TaskPriority[] = ["Low", "Medium", "High", "Critical"];

/** How long a checklist title may sit unsaved while it is still being typed. */
const RENAME_DEBOUNCE_MS = 600;

/**
 * THE TASK PAGE — a pure copy of ClickUp's open task.
 *
 * Asad, 2026-09-15, with ClickUp's task tab beside ours (screenshot
 * ~/Pictures/Terminal Deck/app.clickup.com-20260915-031455.png): *"i need same
 * size of window and exact same layout exact same shape of comment box and
 * typing box exact items in under the typing box and inside the plus button
 * there and activities inside and filter i need a pure copy of this tab"*.
 * Measurements: docs/clickup-task-inventory.md § 2; plan: backlog § K.
 *
 *   HEADER (page/page-header.tsx) ▲ ▼ · board 🔒 · ⇥ │ Created · Share · ⋯ · ☆ · ⧉ · ×
 *   LEFT (1072px at ClickUp's size; content column ~890px)
 *     top row      Task ⌄ · ⚭ n · ☰ n · n for me
 *     heading      the first line / sentence of the task text, 26px bold (click → edit the whole text)
 *     grid         Status [TO DO ▸][✓] · Assignees / Dates [Start → Due] · Priority / Track time · Tags
 *                  + our Related-to row; "Collapse empty fields"
 *     body         the rest of the task text, then Add description / details
 *     sections     Subtasks table · Relate items or add dependencies · Checklists · Attach file + chips
 *     rail         » collapse Activity · 💬 Activity · ↯ related items
 *   RIGHT (560px, page/activity-pane.tsx) Activity 🔍 🔔 ≡ · the feed · the comment card with ⊕ / 📎 / @ / ☺ / 🎤 / ➤
 *
 * The text IS the task here (Asad removed the separate title on 09-14), so the
 * heading is DISPLAY ONLY — one stored field; editing edits all of it.
 *
 * WHO MAY EDIT THE ROW. The server scopes status / title / priority / dates /
 * description / type / tags / board / estimate to the task's main assignee or
 * its creator. Anyone else on the task works its subtasks, checklists,
 * dependencies, attachments, time and comments. So for them the row controls
 * are read-only, not present-and-refusing.
 *
 * `actions` is injectable so a unit test can prove every write with a
 * recorder; the default is the real server actions. :3005 talks to production.
 */
export type TaskDetailPanelProps = {
  task: Task;
  team: TaskAssignee[];
  currentUserId: string;
  onClose: () => void;
  onPatched: (id: string, patch: Partial<Task>) => void;
  /** Accepted for the old drawer's call site; completion is the status pill now. */
  toggleDone?: (id: string) => void;
  /** The ⋯ menu's "Delete task". Absent = the menu offers no delete. */
  onDelete?: (id: string) => void;
  /** ⋯ → Duplicate made a new task: the list learns of it and opens it. */
  onDuplicated?: (newId: string, source: Task) => void;
  /** The list the page was opened from, in order — the header's ▲ ▼. */
  siblings?: string[];
  onNavigate?: (taskId: string) => void;
  /** The list's tasks — ⋯ Merge / Convert to subtask pick from them. */
  taskOptions?: { id: string; title: string }[];
  /** A task that left the list (merged, converted): drop it, and open another if given. */
  onGone?: (taskId: string, openId?: string) => void;
  actions: DetailActions;
  /** The custom fields' calls (the CRM's own default is its server actions). */
  fieldActions: TaskFieldActions;
  /**
   * Local: the boards in use, for ⇥ Move and the "Move" slash command (the
   * CRM's boards are a fixed list; a local task's are names you give them).
   */
  boards: TaskBoard[];
  /**
   * Local: the "Project folder" row — the folder an agent works in. The CRM
   * has no such row (its AI-agent row stands there); a local task needs it
   * before Hoot or an agent can take it.
   */
  projectField?: React.ReactNode;
  /** Local: the task's own workspace (a git worktree), when it has one or was refused one. */
  workspaceField?: React.ReactNode;
  /** What a create did not save, carried here by "Create and open" (inc8 H2) — at the top until dismissed. */
  notice?: string | null;
  onDismissNotice?: () => void;
};

/**
 * Keyed on the task id: opening a different task while the panel is up
 * REMOUNTS the body, so every piece of state below starts fresh for the new
 * task — no effect has to reset a dozen fields by hand, and none can forget one.
 */
export function TaskDetailPanel(props: TaskDetailPanelProps) {
  const [full, setFull] = useState(false);
  return (
    <Dialog open onClose={props.onClose} className={cn("dlg-wide dlg-page", full && "dlg-page-full")}>
      <TaskDetailBody key={props.task.id} {...props} full={full} onToggleFull={() => setFull((f) => !f)} />
    </Dialog>
  );
}

/** Quick dates on this computer's calendar (shared/crm/local-time.ts). */
function plusDays(n: number): string {
  const q = localQuickDates();
  return n === 0 ? q.today : n === 1 ? q.tomorrow : n === 14 ? q.twoWeeks : ymdAddDays(q.today, n);
}
function nextMonday(): string {
  return localQuickDates().nextMonday;
}

/**
 * One request per `key`, however many times the effect runs. Server actions
 * from one page run ONE AT A TIME (Next.js queues them), and in development
 * StrictMode runs every effect twice — the page's five reads became ten and
 * the bundle arrived eighth (measured on :3005, 8.4 s). The second run now
 * reuses the first run's promise; a later `key` (Retry, a refresh) asks again.
 */
function useKeyedRead<T>(key: string, run: () => Promise<T>, apply: (r: T) => void, fail?: (e: unknown) => void) {
  const cache = useRef<{ key: string; p: Promise<T> } | null>(null);
  const runRef = useRef(run);
  runRef.current = run;
  const applyRef = useRef(apply);
  applyRef.current = apply;
  const failRef = useRef(fail);
  failRef.current = fail;
  useEffect(() => {
    if (!cache.current || cache.current.key !== key) cache.current = { key, p: runRef.current() };
    let alive = true;
    cache.current.p.then(
      (r) => {
        if (alive) applyRef.current(r);
      },
      (e) => {
        if (alive) failRef.current?.(e);
      },
    );
    return () => {
      alive = false;
    };
  }, [key]);
}

// Exported (local): a static render in a test draws the body, since the dialog itself only appears once mounted.
export function TaskDetailBody({
  task,
  team,
  currentUserId,
  onPatched,
  onClose,
  onDelete,
  onDuplicated,
  siblings,
  onNavigate,
  taskOptions,
  onGone,
  actions,
  fieldActions,
  boards,
  projectField,
  workspaceField,
  full,
  onToggleFull,
  notice = null,
  onDismissNotice,
}: TaskDetailPanelProps & { full: boolean; onToggleFull: () => void }) {
  const canEditRow = task.assigneeUserId === currentUserId || task.createdBy === currentUserId;
  const me = team.find((p) => p.id === currentUserId) ?? null;

  // The most recent refused write, in the server's own words.
  const [error, setError] = useState<string | null>(null);
  const report = useCallback((message: string) => setError(message), []);

  // ── the bundle: people, subtasks, checklists, dependencies, attachments ──
  const [bundleState, setBundleState] = useState<"loading" | "error" | "ready">("loading");
  const [bundleError, setBundleError] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  const people = useSyncedRows<TaskPeople>({
    actions,
    diff: useCallback((p: TaskPeople, n: TaskPeople) => diffPeople(task.id, p, n), [task.id]),
    onError: report,
  });
  const subtasks = useSyncedRows<TaskSubtaskRow[]>({
    actions,
    diff: useCallback((p: TaskSubtaskRow[], n: TaskSubtaskRow[]) => diffSubtasks(task.id, p, n), [task.id]),
    onError: report,
  });
  const checklists = useSyncedRows<TaskChecklist[]>({
    actions,
    // Renames are debounced separately (see onChecklistChange).
    diff: useCallback((p: TaskChecklist[], n: TaskChecklist[]) => ({ ops: diffChecklists(task.id, p, n).ops }), [task.id]),
    onError: report,
  });
  const dependencies = useSyncedRows<TaskDependency[]>({
    actions,
    diff: useCallback((p: TaskDependency[], n: TaskDependency[]) => diffDependencies(task.id, p, n), [task.id]),
    onError: report,
  });
  const attachments = useSyncedRows<TaskAttachment[]>({
    actions,
    diff: useCallback((p: TaskAttachment[], n: TaskAttachment[]) => diffAttachments(task.id, p, n), [task.id]),
    onError: report,
  });

  // Which optional sections are on screen: whatever has rows, plus whatever an action row revealed.
  const [shown, setShown] = useState<ReadonlySet<OptionalSection>>(() => new Set());
  const [justAdded, setJustAdded] = useState<OptionalSection | null>(null);

  const seedPeople = people.seed;
  const seedSubtasks = subtasks.seed;
  const seedChecklists = checklists.seed;
  const seedDependencies = dependencies.seed;
  const seedAttachments = attachments.seed;

  useKeyedRead(
    `${task.id}:${reloadKey}`,
    () => actions.fetchTaskDetailBundle(task.id),
    (res) => {
        if (!res.ok) {
          setBundleError(res.error);
          setBundleState("error");
          return;
        }
        const b = res.bundle;
        seedPeople(b.people);
        seedSubtasks(b.subtasks);
        seedChecklists(b.checklists);
        seedDependencies(b.dependencies);
        seedAttachments(b.attachments);
        setShown((prev) => {
          const next = new Set(prev);
          if (b.subtasks.length) next.add("subtasks");
          if (b.checklists.length) next.add("checklist");
          if (b.dependencies.length) next.add("dependencies");
          if (b.attachments.length) next.add("attachments");
          return next;
        });
        setBundleState("ready");
    },
    (e) => {
      setBundleError((e as Error).message || "Could not load this task.");
      setBundleState("error");
    },
  );

  // ── the extras: type, tags, time, recurrence options, subtask priority/due ──
  // Their own read, so a migration that has not landed never takes the page down.
  const [extras, setExtras] = useState<TaskPageExtras | null>(null);
  const [extrasError, setExtrasError] = useState<string | null>(null);
  useKeyedRead(
    task.id,
    () => actions.fetchTaskPageExtras(task.id),
    (res) => {
      if (res.ok) setExtras(res.extras);
      else setExtrasError(res.error);
    },
    (e) => setExtrasError((e as Error).message || "Could not read the task page's extra fields."),
  );
  // A sentence from the server (task-page.ts notAvailableSentence) — never a developer filename (round 4).
  const unavailable = extrasError;

  // ── the routine: its rule (the routine's own task's), its history ─────────
  // Read again after a status change — the server records a Done in the history.
  const [routine, setRoutine] = useState<RoutineView | null>(null);
  const [routineError, setRoutineError] = useState<string | null>(null);
  const [routineKey, setRoutineKey] = useState(0);
  useKeyedRead(
    `${task.id}:${routineKey}:${task.group}`,
    () => (actions.fetchRoutine ? actions.fetchRoutine(task.id) : Promise.resolve(null)),
    (res) => {
      if (!res) return;
      if (res.ok) {
        setRoutine(res.routine);
        setRoutineError(null);
      } else setRoutineError(res.error);
    },
    (e) => setRoutineError((e as Error).message || "Could not read this task's routine."),
  );

  // ── part 2: followers, reminders, archive, times, tag colours, time-entry tags ──
  // Its own read (task-more-actions.ts): before migrations/2026-09-15-task-page-2.sql it fails and
  // every control that needs it says so; the rest of the page never waits on it.
  const [more, setMore] = useState<TaskMore | null>(null);
  const [moreError, setMoreError] = useState<string | null>(null);
  const [moreKey, setMoreKey] = useState(0);
  useKeyedRead(
    `${task.id}:${moreKey}`,
    () => (actions.fetchTaskMore ? actions.fetchTaskMore(task.id) : Promise.resolve(null)),
    (res) => {
      if (!res) return;
      if (res.ok) {
        setMore(res.more);
        setMoreError(null);
      } else if ((res as { notReady?: boolean }).notReady) {
        // Before the migration: what needs it is HIDDEN (inc8 M4 — whole feature or none), never shown disabled with a reason.
        setMoreError(null);
      } else setMoreError("Couldn't load follow, reminders and archive — try again.");
    },
    // A throw is a read that failed — said plainly, never its text (inc8 M4 / L12).
    () => setMoreError("Couldn't load follow, reminders and archive — try again."),
  );
  const moreUnavailable = moreError;
  const [versions, setVersions] = useState<DescriptionVersion[] | null>(null);
  const [historyOpen, setHistoryOpen] = useState(false);
  /** Run a part-2 action; its refusal is shown, its success re-reads the part and the feed. */
  async function moreDo<T extends { ok: boolean }>(label: string, run: () => Promise<T>, after?: (r: T) => void): Promise<void> {
    let r: T;
    try {
      r = await run();
    } catch (e) {
      // A throw (a network drop, a server error) is said, and the part is read again — which puts back any value
      // shown optimistically (inc8 M7). Never an unhandled rejection with nothing on the screen.
      console.error("[tasks] a part-2 action failed", label, e);
      setError(`${label}: could not be saved — try again.`);
      setMoreKey((k) => k + 1);
      return;
    }
    if (!r.ok) {
      setError(`${label}: ${(r as unknown as { error?: string }).error ?? "not saved"}`);
      setMoreKey((k) => k + 1);
      return;
    }
    after?.(r);
    setMoreKey((k) => k + 1);
    refreshActivity();
  }
  async function openDescriptionHistory() {
    if (!actions.fetchDescriptionHistory) return;
    setHistoryOpen(true);
    setVersions(null);
    const r = await actions.fetchDescriptionHistory(task.id);
    if (r.ok) setVersions(r.versions);
    else {
      setHistoryOpen(false);
      setError(`Description history: ${r.error}`);
    }
  }
  function relateFromMenu(kind: RelateKind) {
    relate(kind === "relate" ? "linked" : kind);
    depsAnchor.current?.scrollIntoView({ block: "center", behavior: "smooth" });
  }

  function reveal(section: OptionalSection) {
    setShown((s) => (s.has(section) ? s : new Set(s).add(section)));
    // A checklist section with no list has nothing to type into, so the first
    // list is made on reveal — on the server too, so what is on screen exists.
    if (section === "checklist") {
      const cur = checklists.current();
      if (cur && cur.length === 0) checklists.change([newChecklist()]);
    }
    setJustAdded(section);
  }

  // ── the task row ────────────────────────────────────────────────────────
  async function changeStatus(next: TaskStatus) {
    if (next === task.group) return;
    const prev = task.group;
    onPatched(task.id, { group: next });
    const r = await actions.setTaskStatus(task.id, next);
    if (!r.ok) {
      onPatched(task.id, { group: prev });
      setError(`Status: ${r.error}`);
    }
  }

  async function changePriority(next: TaskPriority | null) {
    if (next === task.priority) return;
    const prev = task.priority;
    onPatched(task.id, { priority: next });
    const r = await actions.updateTask(task.id, { priority: next });
    if (!r.ok) {
      onPatched(task.id, { priority: prev });
      setError(`Priority: ${r.error}`);
    }
  }

  async function saveDates(next: { startDate: string; dueDate: string; recurrence?: TaskRecurrence | null }) {
    const patch: { startDate?: string; dueDate?: string; recurrence?: TaskRecurrence | null } = {};
    if (next.startDate !== task.startDate) patch.startDate = next.startDate;
    if (next.dueDate !== task.dueDate) patch.dueDate = next.dueDate;
    if (next.recurrence !== undefined && next.recurrence !== task.recurrence) patch.recurrence = next.recurrence;
    if (!Object.keys(patch).length) return;
    const prev = { startDate: task.startDate, dueDate: task.dueDate, recurrence: task.recurrence };
    onPatched(task.id, patch);
    const r = await actions.updateTask(task.id, patch);
    if (!r.ok) {
      onPatched(task.id, prev);
      setError(`Dates: ${r.error}`);
      return;
    }
    // A date cleared takes its time with it (inc8 M10) — the SERVER does it, in the one date write the phone and MCP
    // share (writeTaskDates, r7 #5), after the date saved. The page mirrors it; it no longer writes it a second time.
    // When the server could NOT clear the time it says so (`warning`), and the page keeps showing the time it kept (r8 #4).
    const kept = (r as { warning?: string }).warning;
    if (kept) setError(`Dates: ${kept}`);
    else if (patch.startDate === "" || patch.dueDate === "")
      setMore((m) => (m ? { ...m, ...(patch.startDate === "" ? { startTime: null } : {}), ...(patch.dueDate === "" ? { dueTime: null } : {}) } : m));
  }

  /**
   * The Recurring panel's Save: the whole routine, written on the routine's own task. One at a time (round 5,
   * L8): a second Save while the first is in flight would carry the version the first is about to change, and
   * be refused as "someone changed this routine" — the someone being you. Save waits (disabled) instead.
   */
  const routineSaving = useRef(false);
  const [routineBusy, setRoutineBusy] = useState(false);
  async function saveRoutineRule(rule: RoutineRule | null) {
    if (routineSaving.current) return;
    routineSaving.current = true;
    setRoutineBusy(true);
    try {
      await saveRoutineRuleOnce(rule);
    } finally {
      routineSaving.current = false;
      setRoutineBusy(false);
    }
  }
  async function saveRoutineRuleOnce(rule: RoutineRule | null) {
    const legacy = rule ? legacyRecurrence(rule) : null;
    const prevRec = task.recurrence;
    const prevRoutine = routine;
    const onThisTask = !routine || routine.isRoot;
    if (onThisTask) onPatched(task.id, { recurrence: legacy });
    setRoutine((r) =>
      r
        ? { ...r, rule }
        : { rootTaskId: task.id, rootTitle: task.title, isRoot: true, rule, canEdit: true, history: [], historyError: null, lastError: null, next: [], peopleCount: 1, version: null, stuck: null, canRestart: false, anchor: null, occurrence: null, datesSoFar: 0 },
    );
    // Without the routine actions (an older build of the fakes), the frequency alone — as before.
    // The Save carries the rule's version as this page read it: a routine someone changed since is refused (round 4).
    const r = actions.saveRoutine ? await actions.saveRoutine(task.id, rule, prevRoutine?.version ?? null) : await actions.updateTask(task.id, { recurrence: legacy });
    if (!r.ok) {
      if (onThisTask) onPatched(task.id, { recurrence: prevRec });
      setRoutine(prevRoutine);
      setError(`Recurring: ${r.error}`);
      return;
    }
    const nextVersion = (r as { version?: number | null }).version;
    if (nextVersion !== undefined) setRoutine((v) => (v ? { ...v, version: nextVersion } : v));
    setRoutineKey((k) => k + 1);
    refreshActivity();
  }

  /** Restart — a status routine whose current copy was deleted or archived makes its next one (routines round 5, F3). */
  async function restartRoutineNow() {
    if (!actions.restartRoutine) return;
    const r = await actions.restartRoutine(task.id);
    if (!r.ok) {
      setError(`Restart: ${r.error}`);
      return;
    }
    // Some people's copies made, not everyone's: said, never a quiet success (routines round 6).
    const warning = (r as { warning?: string }).warning;
    if (warning) setError(`Restart: ${warning}`);
    setRoutineKey((k) => k + 1);
    refreshActivity();
  }

  /** "Stop recurring" — the routine ends; its history and every task it made stay. */
  async function stopRoutineNow() {
    if (!actions.stopRoutine) return;
    const prevRec = task.recurrence;
    const onThisTask = !routine || routine.isRoot;
    if (onThisTask) onPatched(task.id, { recurrence: null });
    const r = await actions.stopRoutine(task.id);
    if (!r.ok) {
      if (onThisTask) onPatched(task.id, { recurrence: prevRec });
      setError(`Stop recurring: ${r.error}`);
      return;
    }
    if (!onThisTask) onPatched(task.id, { recurrence: null });
    setRoutineKey((k) => k + 1);
    refreshActivity();
  }

  async function pauseRoutineNow(paused: boolean) {
    if (!actions.pauseRoutine) return;
    const r = await actions.pauseRoutine(task.id, paused);
    if (!r.ok) {
      setError(`${paused ? "Pause" : "Resume"}: ${r.error}`);
      return;
    }
    setRoutineKey((k) => k + 1);
  }

  async function moveBoard(board: TaskBoard) {
    const prev = task.board;
    onPatched(task.id, { board });
    const r = await actions.moveTask(task.id, board);
    if (!r.ok) {
      onPatched(task.id, { board: prev });
      setError(`Move: ${r.error}`);
    }
  }

  // Local: the CRM's "Related to" picker links CRM records; local tasks show it as unavailable, so nothing saves links here.

  async function patchExtras<T>(apply: (x: TaskPageExtras) => TaskPageExtras, call: () => Promise<{ ok: true } | { ok: false; error: string } | T>, label: string) {
    if (!extras) return;
    const prev = extras;
    setExtras(apply(extras));
    const r = (await call()) as { ok: boolean; error?: string };
    if (!r.ok) {
      setExtras(prev);
      setError(`${label}: ${r.error}`);
    }
  }

  const changeType = (t: TaskType) => patchExtras((x) => ({ ...x, taskType: t }), () => actions.setTaskType(task.id, t), "Task type");
  const changeLabels = (labels: string[]) => patchExtras((x) => ({ ...x, labels }), () => actions.setTaskLabels(task.id, labels), "Tags");
  const changeSubtaskMeta = (subtaskId: string, patch: { priority?: TaskPriority | null; dueDate?: string | null }) =>
    patchExtras(
      (x) => {
        const cur = x.subtaskMeta[subtaskId] ?? { priority: null, dueDate: null };
        return { ...x, subtaskMeta: { ...x.subtaskMeta, [subtaskId]: { ...cur, ...patch } } };
      },
      () => actions.setSubtaskMeta(task.id, subtaskId, patch),
      "Subtask",
    );

  // Time: every call answers with the rows to show, or its reason.
  async function timeStart(): Promise<string | null> {
    const r = await actions.startTaskTimer(task.id);
    if (!r.ok) return r.error;
    setExtras((x) => (x ? { ...x, timeEntries: [...x.timeEntries.filter((e) => !(e.userId === currentUserId && !e.endedAt)), r.entry] } : x));
    refreshActivity();
    return null;
  }
  async function timeStop(): Promise<string | null> {
    const r = await actions.stopTaskTimer(task.id);
    if (!r.ok) return r.error;
    if (r.entry) {
      const done = r.entry;
      setExtras((x) => (x ? { ...x, timeEntries: x.timeEntries.map((e) => (e.id === done.id ? done : e)) } : x));
    }
    refreshActivity();
    return null;
  }
  async function timeAdd(input: { seconds: number; date: string; note: string; billable: boolean; tags?: string[] }): Promise<string | null> {
    const r = await actions.addTaskTimeEntry(task.id, input);
    if (!r.ok) return r.error;
    setExtras((x) => (x ? { ...x, timeEntries: [...x.timeEntries, r.entry] } : x));
    // Track time → Add tags: the entry exists; its tags follow (the entry's own person only).
    if (input.tags?.length && actions.setTimeEntryTags) {
      const t = await actions.setTimeEntryTags(task.id, r.entry.id, input.tags);
      if (t.ok) setMore((m) => (m ? { ...m, entryTags: { ...m.entryTags, [r.entry.id]: t.tags } } : m));
      else setError(`Time tags: ${t.error}`);
    }
    refreshActivity();
    return null;
  }
  async function timeDelete(entryId: string): Promise<string | null> {
    const r = await actions.deleteTaskTimeEntry(task.id, entryId);
    if (!r.ok) return r.error;
    setExtras((x) => (x ? { ...x, timeEntries: x.timeEntries.filter((e) => e.id !== entryId) } : x));
    return null;
  }
  async function timeEstimate(minutes: number | null): Promise<string | null> {
    const r = await actions.setTimeEstimate(task.id, minutes);
    if (!r.ok) return r.error;
    setExtras((x) => (x ? { ...x, estimateMinutes: minutes } : x));
    refreshActivity();
    return null;
  }

  async function duplicate() {
    const r = await actions.duplicateTask(task.id);
    if (!r.ok) {
      setError(`Duplicate: ${r.error}`);
      return;
    }
    if (r.id) onDuplicated?.(r.id, task);
  }

  // ── the text: heading + body (display), one field (edit) ────────────────
  const [editingTitle, setEditingTitle] = useState(false);
  const [titleDraft, setTitleDraft] = useState(task.title);
  const [savingTitle, setSavingTitle] = useState(false);
  const split = useMemo(() => splitTaskText(task.title), [task.title]);

  function startTitleEdit() {
    setTitleDraft(task.title);
    setEditingTitle(true);
  }

  async function saveTitle() {
    const clean = titleDraft.trim();
    if (!clean || savingTitle) return;
    if (clean === task.title) {
      setEditingTitle(false);
      return;
    }
    setSavingTitle(true);
    const r = await actions.updateTask(task.id, { title: clean });
    setSavingTitle(false);
    if (!r.ok) {
      setError(`Title: ${r.error}`);
      return;
    }
    onPatched(task.id, { title: clean });
    setEditingTitle(false);
  }

  const [desc, setDesc] = useState(task.description);
  const [savingDesc, setSavingDesc] = useState(false);

  async function saveDescription() {
    if (savingDesc) return;
    setSavingDesc(true);
    const r = await actions.updateTask(task.id, { description: desc });
    setSavingDesc(false);
    if (!r.ok) {
      setError(`Description: ${r.error}`);
      return;
    }
    onPatched(task.id, { description: desc.trim() });
  }

  // ── people ───────────────────────────────────────────────────────────────
  function joinLocally(userId: string | null) {
    if (!userId) return;
    const cur = people.current();
    if (!cur || isOnTask(cur, userId)) return;
    const person = team.find((p) => p.id === userId);
    if (person) people.local(addPerson(cur, person));
  }

  // Taking the MAIN person off promotes the next face (task-people-field.tsx),
  // which is assignTask — and then the list behind the page must learn who the
  // task now belongs to.
  function onPeopleChange(next: TaskPeople) {
    const prev = people.current();
    const promoted = next.primary && next.primary.id !== prev?.primary?.id ? next.primary : null;
    people.change(
      next,
      promoted
        ? () =>
            onPatched(task.id, {
              assigneeUserId: promoted.id,
              assigneeName: promoted.name,
              assigneeInitials: promoted.initials,
              assigneeColor: promoted.color,
              assigneeAvatarUrl: promoted.avatarUrl,
            })
        : undefined,
    );
  }

  /** Someone put on the task from @, Share or a slash command — the people control's own rule. */
  function invite(person: TaskAssignee) {
    const cur = people.current();
    if (!cur) return;
    if (isOnTask(cur, person.id)) return;
    const personal = peopleList(cur).length === 0 || (peopleList(cur).length === 1 && cur.primary?.id === currentUserId && person.id !== currentUserId);
    onPeopleChange(personal && cur.primary?.id !== person.id ? { primary: person, others: [] } : addPerson(cur, person));
  }

  function removeFromTask(personId: string) {
    const cur = people.current();
    if (cur) onPeopleChange(removePerson(cur, personId));
  }

  function onSubtasksChange(next: TaskSubtaskRow[]) {
    const prev = subtasks.current() ?? [];
    const before = new Map(prev.map((r) => [r.id, r.assigneeUserId]));
    const joined = next.filter((r) => r.assigneeUserId && before.get(r.id) !== r.assigneeUserId).map((r) => r.assigneeUserId);
    subtasks.change(next, joined.length ? () => joined.forEach(joinLocally) : undefined);
  }

  // Checklist renames arrive a keystroke at a time; the server hears the title
  // once typing pauses, and a refusal puts the ORIGINAL back.
  const renameTimers = useRef(new Map<string, ReturnType<typeof setTimeout>>());
  const renameOrigins = useRef(new Map<string, string>());
  const listsCurrent = checklists.current;
  const listsEnqueue = checklists.enqueue;
  const flushRename = useCallback(
    (listId: string) => {
      renameTimers.current.delete(listId);
      const origin = renameOrigins.current.get(listId);
      renameOrigins.current.delete(listId);
      const cur = listsCurrent();
      if (!cur || origin === undefined) return;
      const list = cur.find((l) => l.id === listId);
      if (!list || list.title === origin) return;
      const fallback = cur.map((l) => (l.id === listId ? { ...l, title: origin } : l));
      listsEnqueue([renameOp(listId, list.title)], fallback);
    },
    [listsCurrent, listsEnqueue],
  );

  function onChecklistChange(next: TaskChecklist[]) {
    const prev = checklists.current() ?? [];
    const { renames } = diffChecklists(task.id, prev, next);
    const beforeItems = new Map(prev.flatMap((l) => l.items.map((i) => [i.id, i.assigneeUserId] as const)));
    const joined = next
      .flatMap((l) => l.items)
      .filter((i) => i.assigneeUserId && beforeItems.get(i.id) !== i.assigneeUserId)
      .map((i) => i.assigneeUserId);
    checklists.change(next, joined.length ? () => joined.forEach(joinLocally) : undefined);
    for (const { listId } of renames) {
      const was = prev.find((l) => l.id === listId);
      if (was && !renameOrigins.current.has(listId)) renameOrigins.current.set(listId, was.title);
      const t = renameTimers.current.get(listId);
      if (t) clearTimeout(t);
      renameTimers.current.set(listId, setTimeout(() => flushRename(listId), RENAME_DEBOUNCE_MS));
    }
  }

  // A rename still waiting when the page closes is sent, not lost.
  useEffect(() => {
    const timers = renameTimers.current;
    return () => {
      for (const [listId, t] of timers) {
        clearTimeout(t);
        flushRename(listId);
      }
    };
  }, [flushRename]);

  // ── files ────────────────────────────────────────────────────────────────
  const [pending, setPending] = useState<PendingUpload[]>([]);
  const textRef = useRef<TaskTextFieldHandle | null>(null);
  const editingRef = useRef(false);
  useEffect(() => {
    editingRef.current = editingTitle;
  }, [editingTitle]);
  const [linking, setLinking] = useState(false);

  /**
   * Upload files to the task — from any door (Attach file, a drop, a paste,
   * the comment box's 📎). Each is checked with the route's own rule first;
   * the recorded row is added with `local()` (the route already recorded it).
   * Returns what was attached, so a caller can place the chips.
   */
  async function uploadToTask(files: FileList | File[]): Promise<TaskAttachment[]> {
    if (bundleState !== "ready") {
      setError("Still loading this task — try the file again in a moment.");
      return [];
    }
    setShown((s) => (s.has("attachments") ? s : new Set(s).add("attachments")));
    const done: TaskAttachment[] = [];
    for (const file of Array.from(files)) {
      const check = checkUpload({ name: file.name, size: file.size });
      if (!check.ok) {
        setError(check.error);
        continue;
      }
      const key = draftRowId();
      setPending((p) => [...p, { key, fileName: file.name, sizeBytes: file.size }]);
      const r = await actions.uploadTaskFile(task.id, file);
      setPending((p) => p.filter((x) => x.key !== key));
      if (!r.ok) {
        setError(`Upload “${file.name}”: ${r.error}`);
        continue;
      }
      const cur = attachments.current() ?? [];
      attachments.local([...cur, r.attachment]);
      done.push(r.attachment);
    }
    return done;
  }

  const infoFor = useCallback(
    (a: TaskAttachment): InlineFileInfo => {
      const kind = inlineKind(a.mimeType, a.fileName);
      // Local: a picture is shown from its data: preview (the window shows no other image address).
      const src = kind !== "image" ? null : (a.previewUrl ?? null);
      return { kind, src, name: a.fileName };
    },
    [],
  );

  /** Files from the page's doors: while the text is being edited, placed at its caret too. */
  async function uploadFiles(files: FileList | File[]) {
    const done = await uploadToTask(files);
    if (editingRef.current) for (const a of done) textRef.current?.insertFile(a.id, infoFor(a));
  }

  /**
   * Local: "Upload from device" opens the Mac's own file chooser in the main
   * process, which checks each file with the same rule and copies it in.
   */
  async function chooseFromDevice() {
    if (!actions.chooseTaskFiles) return;
    if (bundleState !== "ready") {
      setError("Still loading this task — try the file again in a moment.");
      return;
    }
    const r = await actions.chooseTaskFiles(task.id);
    if (!r.ok) {
      setError(`Upload: ${r.error}`);
      return;
    }
    if (r.attachments.length) {
      setShown((s) => (s.has("attachments") ? s : new Set(s).add("attachments")));
      attachments.local([...(attachments.current() ?? []), ...r.attachments]);
      if (editingRef.current) for (const a of r.attachments) textRef.current?.insertFile(a.id, infoFor(a));
    }
    if (r.errors.length) setError(r.errors.join(" "));
  }

  const drop = useFileDrop(uploadFiles, UPLOADS_WIRED);

  const attachmentRows = attachments.rows;
  const fileOf = useCallback(
    (id: string): InlineFileInfo | null => {
      const a = attachmentRows?.find((x) => x.id === id);
      return a ? infoFor(a) : null;
    },
    [attachmentRows, infoFor],
  );

  // ── comments ─────────────────────────────────────────────────────────────
  const [comments, setComments] = useState<TaskComment[] | null>(null);
  const [commentsError, setCommentsError] = useState<string | null>(null);

  useKeyedRead(
    task.id,
    () => actions.listTaskComments(task.id),
    (res) => {
      if (res.ok) setComments(res.comments);
      else {
        setComments([]);
        setCommentsError(res.error);
      }
    },
  );

  // ── the comment card: reply · react · resolve · assign · schedule ───────
  // Its own read (migrations/2026-09-15-task-comments.sql); until it answers,
  // the cards are drawn without the footer and the composer without 👤 / ⌄.
  const [commentExtras, setCommentExtras] = useState<CommentExtras | null>(null);
  const [commentExtrasKey, setCommentExtrasKey] = useState(0);
  useKeyedRead(
    `${task.id}:${commentExtrasKey}`,
    () => actions.fetchCommentExtras(task.id),
    (res) => {
      if (res.ok) setCommentExtras(res.extras);
    },
  );

  async function postComment(body: string, opts?: PostOptions): Promise<boolean> {
    const rich = !!opts && (!!opts.parentId || !!opts.assigneeUserId || !!opts.scheduledFor);
    const r = rich ? await actions.addTaskCommentWith(task.id, body, opts ?? {}) : await actions.addTaskComment(task.id, body);
    if (!r.ok) {
      setError(`Comment: ${r.error}`);
      return false;
    }
    const list = await actions.listTaskComments(task.id);
    if (list.ok) setComments(list.comments);
    else setCommentsError(list.error);
    setCommentExtrasKey((k) => k + 1);
    refreshActivity();
    return true;
  }

  async function reactTo(commentId: string, emoji: string) {
    if (!commentExtras) return;
    const prev = commentExtras;
    const list = prev.reactions[commentId] ?? [];
    const hit = list.find((x) => x.emoji === emoji);
    const mine = !!hit?.userIds.includes(currentUserId);
    const nextList = hit
      ? list
          .map((x) => (x.emoji !== emoji ? x : { ...x, userIds: mine ? x.userIds.filter((u) => u !== currentUserId) : [...x.userIds, currentUserId] }))
          .filter((x) => x.userIds.length > 0)
      : [...list, { emoji, userIds: [currentUserId] }];
    setCommentExtras({ ...prev, reactions: { ...prev.reactions, [commentId]: nextList } });
    const r = await actions.toggleCommentReaction(task.id, commentId, emoji);
    if (!r.ok) {
      setCommentExtras(prev);
      setError(`Reaction: ${r.error}`);
    }
  }

  async function resolveComment(commentId: string, resolved: boolean) {
    if (!commentExtras) return;
    const prev = commentExtras;
    const m = prev.meta[commentId] ?? { parentId: null, resolvedAt: null, resolvedBy: null, assigneeUserId: null, scheduledFor: null };
    setCommentExtras({
      ...prev,
      meta: { ...prev.meta, [commentId]: { ...m, resolvedAt: resolved ? new Date().toISOString() : null, resolvedBy: resolved ? currentUserId : null } },
    });
    const r = await actions.setCommentResolved(task.id, commentId, resolved);
    if (!r.ok) {
      setCommentExtras(prev);
      setError(`Resolve: ${r.error}`);
    }
  }

  async function sendCommentNow(commentId: string) {
    const r = await actions.sendScheduledNow(task.id, commentId);
    if (!r.ok) {
      setError(`Send now: ${r.error}`);
      setCommentExtrasKey((k) => k + 1);
      return;
    }
    // Sent, but its feed line or a notice did not go through: said, never a silent success (batch-2 review #3).
    const warning = (r as { warning?: string }).warning;
    if (warning) setError(`Send now: ${warning}`);
    setCommentExtrasKey((k) => k + 1);
  }

  // ── the activity column ──────────────────────────────────────────────────
  // Seeded with the one line we can already say, so it never opens on
  // "Loading…": "You created this task · when". The fetched rows replace it.
  const [activity, setActivity] = useState<TaskActivityRow[] | null>(() =>
    task.createdAt
      ? [
          {
            id: `local-created-${task.id}`,
            taskId: task.id,
            kind: "created",
            payload: {},
            actorUserId: task.createdBy,
            actor: team.find((p) => p.id === task.createdBy) ?? null,
            createdAt: task.createdAt,
          },
        ]
      : null,
  );
  const [activityError, setActivityError] = useState<string | null>(null);
  const [activityKey, setActivityKey] = useState(0);
  const [activityTotal, setActivityTotal] = useState<number | null>(null);
  useKeyedRead(
    `${task.id}:${activityKey}`,
    () => actions.listTaskActivity(task.id),
    (res) => {
      if (res.ok) {
        setActivity(res.rows);
        // Every line the task has — past the newest 500 the pane says "the latest n of N" (MCP coverage r2).
        setActivityTotal(typeof res.total === "number" ? res.total : null);
        setActivityError(null);
      } else {
        setActivity([]);
        // No lines were read, so there is no "latest n of N" to say (r8 #2: it said "the latest 0 of 12").
        setActivityTotal(null);
        setActivityError(res.error);
      }
    },
  );
  const refreshActivity = useCallback(() => setActivityKey((k) => k + 1), []);
  // A Fields "Button" changed the status or commented, or a Files field uploaded:
  // everything it could have touched is read again.
  const refetchAll = useCallback(() => {
    setReloadKey((k) => k + 1);
    setActivityKey((k) => k + 1);
    void actions.listTaskComments(task.id).then((r) => {
      if (r.ok) setComments(r.comments);
    });
  }, [actions, task.id]);
  const changesSeen = useRef({ group: task.group, priority: task.priority, startDate: task.startDate, dueDate: task.dueDate, title: task.title, description: task.description, board: task.board });
  useEffect(() => {
    const seen = changesSeen.current;
    if (
      seen.group !== task.group ||
      seen.priority !== task.priority ||
      seen.startDate !== task.startDate ||
      seen.dueDate !== task.dueDate ||
      seen.title !== task.title ||
      seen.description !== task.description ||
      seen.board !== task.board
    ) {
      changesSeen.current = { group: task.group, priority: task.priority, startDate: task.startDate, dueDate: task.dueDate, title: task.title, description: task.description, board: task.board };
      const t = setTimeout(refreshActivity, 600);
      return () => clearTimeout(t);
    }
  }, [task.group, task.priority, task.startDate, task.dueDate, task.title, task.description, task.board, refreshActivity]);

  const createdRow = activity?.find((r) => r.kind === "created") ?? null;

  // ── the page's own state ─────────────────────────────────────────────────
  const [activityOpen, setActivityOpen] = useState(true);
  const [hideEmpty, setHideEmpty] = useState(false);
  const [depKind, setDepKind] = useState<DependencyKind | undefined>(undefined);
  const [depKey, setDepKey] = useState(0);
  const relateRef = useRef<HTMLButtonElement | null>(null);
  const [relateOpen, setRelateOpen] = useState(false);
  const depsAnchor = useRef<HTMLDivElement | null>(null);

  function relate(kind: DependencyKind) {
    setRelateOpen(false);
    setDepKind(kind);
    setDepKey((k) => k + 1);
    reveal("dependencies");
  }

  const links = useMemo(() => task.links ?? [], [task.links]);
  const isDone = task.group === "Done";
  const peopleRows = people.rows ? peopleList(people.rows) : [];
  const personal = !!people.rows && (peopleRows.length === 0 || (peopleRows.length === 1 && peopleRows[0].id === currentUserId));
  const subtaskRows = subtasks.rows ?? [];
  const checklistItems = (checklists.rows ?? []).flatMap((l) => l.items);
  const forMe =
    people.rows
      ? subtaskRows.filter((r) => !r.done && assigneeFor(r.assigneeUserId, people.rows!).person?.id === currentUserId).length +
        checklistItems.filter((i) => !i.done && assigneeFor(i.assigneeUserId, people.rows!).person?.id === currentUserId).length
      : 0;

  // Empty cells fold away on "Collapse empty fields".
  const timeTotal = extras ? extras.timeEntries.length : 0;
  const empty = {
    dates: !task.startDate && !task.dueDate,
    priority: !task.priority,
    time: !!extras && timeTotal === 0 && extras.estimateMinutes === null,
    tags: !!extras && extras.labels.length === 0,
    related: links.length === 0,
  };

  // ── the slash commands (the comment box's ⊕ and "/") ─────────────────────
  const commands: SlashCommand[] = useMemo(() => {
    const out: SlashCommand[] = [];
    if (me) out.push({ key: "assign-me", group: "TASK ACTIONS", label: "Assign to me", icon: UserRound, run: () => invite(me) });
    out.push({
      key: "assign",
      group: "TASK ACTIONS",
      label: "Assign",
      icon: UserPlus,
      options: team.slice(0, 40).map((p) => ({
        key: p.id,
        label: p.name,
        icon: <PersonAvatar name={p.name} initials={p.initials} color={p.color} avatarUrl={p.avatarUrl} size="xs" />,
        run: () => invite(p),
      })),
    });
    if (canEditRow) {
      out.push({
        key: "priority",
        group: "TASK ACTIONS",
        label: "Priority",
        icon: Flag,
        options: [...[...PRIORITIES].reverse().map((p) => ({ key: p, label: p, run: () => void changePriority(p) })), { key: "clear", label: "Clear", run: () => void changePriority(null) }],
      });
      out.push({ key: "due-today", group: "TASK ACTIONS", label: "Due Date to today", icon: CalendarClock, run: () => void saveDates({ startDate: task.startDate, dueDate: plusDays(0) }) });
      out.push({
        key: "due",
        group: "TASK ACTIONS",
        label: "Due Date",
        icon: CalendarDays,
        options: [
          { key: "today", label: "Today", run: () => void saveDates({ startDate: task.startDate, dueDate: plusDays(0) }) },
          { key: "tomorrow", label: "Tomorrow", run: () => void saveDates({ startDate: task.startDate, dueDate: plusDays(1) }) },
          { key: "next-week", label: "Next week", run: () => void saveDates({ startDate: task.startDate, dueDate: nextMonday() }) },
          { key: "2w", label: "2 weeks", run: () => void saveDates({ startDate: task.startDate, dueDate: plusDays(14) }) },
          { key: "clear", label: "No due date", run: () => void saveDates({ startDate: task.startDate, dueDate: "" }) },
        ],
      });
      out.push({
        key: "start",
        group: "TASK ACTIONS",
        label: "Start Date",
        icon: PlaySquare,
        options: [
          { key: "today", label: "Today", run: () => void saveDates({ startDate: plusDays(0), dueDate: task.dueDate }) },
          { key: "tomorrow", label: "Tomorrow", run: () => void saveDates({ startDate: plusDays(1), dueDate: task.dueDate }) },
          { key: "next-week", label: "Next week", run: () => void saveDates({ startDate: nextMonday(), dueDate: task.dueDate }) },
          { key: "clear", label: "No start date", run: () => void saveDates({ startDate: "", dueDate: task.dueDate }) },
        ],
      });
      out.push({
        key: "status",
        group: "TASK ACTIONS",
        label: "Status",
        icon: CircleDashed,
        options: STATUSES.map((s) => ({ key: s, label: STATUS_WORD[s], run: () => void changeStatus(s) })),
      });
      out.push({ key: "close", group: "TASK ACTIONS", label: "Close task", icon: CircleCheck, run: () => void changeStatus("Done") });
      out.push({
        key: "move",
        group: "TASK ACTIONS",
        label: "Move",
        icon: FolderInput,
        options: ["", ...boards.filter((b) => b.trim() !== "")].map((b) => ({ key: b || "none", label: taskBoardLabel(b), run: () => void moveBoard(b) })),
      });
    }
    out.push({ key: "subtask", group: "TASK ACTIONS", label: "Subtask", icon: GitBranch, run: () => reveal("subtasks") });
    out.push({ key: "waiting", group: "TASK ACTIONS", label: "Waiting on", icon: TriangleAlert, run: () => relate("blocked_by") });
    out.push({ key: "blocking", group: "TASK ACTIONS", label: "Blocking", icon: Ban, run: () => relate("blocks") });
    out.push({ key: "link", group: "TASK ACTIONS", label: "Link To", icon: Link2, run: () => relate("linked") });
    return out;
    // The handlers read the task through props; rebuilt when the task changes.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [me, team, canEditRow, task]);

  return (
    // The whole page is the drop zone and hears pastes, as the create box does.
    <div className="relative flex min-h-0 flex-1 flex-col" {...drop.zoneProps} data-testid="task-drop-zone">
      <DropOverlay show={drop.dragging} />

      <TaskPageHeader
        taskId={task.id}
        board={task.board}
        boards={boards}
        canEditRow={canEditRow}
        onMove={(b) => void moveBoard(b)}
        createdAt={createdRow?.createdAt ?? task.createdAt ?? null}
        siblings={siblings}
        onNavigate={onNavigate}
        personal={personal}
        heading={splitTaskText(task.title).heading.replace(/\[\[file:[^\]]+\]\]/g, "").trim()}
        people={people.rows}
        team={team}
        onInvite={invite}
        onRemovePerson={removeFromTask}
        canDelete={canEditRow && !!onDelete}
        onDelete={onDelete ? () => onDelete(task.id) : undefined}
        onDuplicate={() => void duplicate()}
        onStopRecurring={routine?.rule && !routine.rule.stoppedAt && routine.canEdit && actions.stopRoutine ? () => void stopRoutineNow() : undefined}
        more={more}
        moreUnavailable={moreUnavailable}
        onFollow={more && actions.setFollowing ? (f) => void moreDo(f ? "Follow" : "Unfollow", () => actions.setFollowing!(task.id, f)) : undefined}
        onRemind={more?.remindersLive && actions.setReminder ? (at) => void moreDo("Remind me", () => actions.setReminder!(task.id, at)) : undefined}
        onClearReminder={more?.remindersLive && actions.clearReminder ? (id) => void moreDo("Reminder", () => actions.clearReminder!(task.id, id)) : undefined}
        onArchive={more && actions.setArchived ? (a) => void moreDo(a ? "Archive" : "Restore", () => actions.setArchived!(task.id, a), () => onPatched(task.id, { archivedAt: a ? new Date().toISOString() : null })) : undefined}
        taskOptions={taskOptions}
        onMerge={more && actions.mergeTaskInto && onGone ? (target) => void moreDo("Merge", () => actions.mergeTaskInto!(task.id, target), () => onGone(task.id, target)) : undefined}
        onConvertToSubtask={more && actions.convertToSubtask && onGone ? (parent) => void moreDo("Convert to subtask", () => actions.convertToSubtask!(task.id, parent), () => onGone(task.id, parent)) : undefined}
        onRelate={canEditRow ? relateFromMenu : undefined}
        onDescriptionHistory={actions.fetchDescriptionHistory ? () => void openDescriptionHistory() : undefined}
        taskType={extras?.taskType ?? null}
        onTaskType={
          extras
            ? (t) =>
                void (async () => {
                  const prev = extras.taskType;
                  setExtras((x) => (x ? { ...x, taskType: t } : x));
                  const r = await actions.setTaskType(task.id, t);
                  if (!r.ok) {
                    setExtras((x) => (x ? { ...x, taskType: prev } : x));
                    setError(`Task type: ${r.error}`);
                  }
                })()
            : undefined
        }
        onSyncDates={
          more && actions.setSyncSubtaskDates
            ? (on) =>
                void moreDo("Sync dates", () => actions.setSyncSubtaskDates!(task.id, on), (r) => {
                  const d = r as unknown as { startDate: string | null; dueDate: string | null };
                  if (d.dueDate) onPatched(task.id, { startDate: d.startDate ?? task.startDate, dueDate: d.dueDate });
                })
            : undefined
        }
        full={full}
        onToggleFull={onToggleFull}
        onClose={onClose}
      />

      {more?.archivedAt && (
        <div className="mx-5 mt-3 flex items-center gap-2 rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-100" data-testid="archived-banner">
          <Archive className="h-3.5 w-3.5 shrink-0" aria-hidden />
          <span className="flex-1">This task is archived — it is out of the list.</span>
          {canEditRow && actions.setArchived && (
            <button type="button" onClick={() => void moreDo("Restore", () => actions.setArchived!(task.id, false), () => onPatched(task.id, { archivedAt: null }))} className="font-medium underline">
              Restore
            </button>
          )}
        </div>
      )}
      {historyOpen && <DescriptionHistory versions={versions} team={team} onClose={() => setHistoryOpen(false)} />}
      {notice && (
        <div role="status" className="mx-5 mt-3 flex items-start gap-2 rounded-md bg-amber-50 px-3 py-2 text-xs text-amber-800 ring-1 ring-amber-200" data-testid="create-notice">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 break-words">{notice}</span>
          {onDismissNotice && (
            <button type="button" aria-label="Dismiss" onClick={onDismissNotice} className="shrink-0 rounded-full p-0.5 text-amber-500 hover:bg-amber-100 hover:text-amber-800">
              <X className="h-3 w-3" />
            </button>
          )}
        </div>
      )}
      {error && (
        <div role="alert" className="mx-5 mt-3 flex items-start gap-2 rounded-md bg-rose-50 px-3 py-2 text-xs text-rose-700 ring-1 ring-rose-100">
          <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
          <span className="min-w-0 flex-1 break-words">{error}</span>
          <button type="button" aria-label="Dismiss" onClick={() => setError(null)} className="shrink-0 rounded-full p-0.5 text-rose-400 hover:bg-rose-100 hover:text-rose-700">
            <X className="h-3 w-3" />
          </button>
        </div>
      )}

      <div
        className="grid min-h-0 flex-1"
        style={{ gridTemplateColumns: activityOpen ? "minmax(0,1fr) minmax(320px,560px)" : "minmax(0,1fr)", minHeight: "min(calc(100vh - 110px), 835px)" }}
        data-testid="task-page-columns"
      >
        {/* LEFT — the task, and the rail between it and Activity */}
        <div className="flex min-h-0" data-testid="task-page-left">
          <div className="min-h-0 flex-1 overflow-y-auto">
            <div className="w-full max-w-[1000px] py-5 pl-[clamp(20px,5.5vw,85px)] pr-6">
              {/* TOP ROW — Task ⌄ · ⚭ n · ☰ n · n for me */}
              <div className="mb-2 flex h-7 flex-wrap items-center gap-3 text-[13px] text-slate-500" data-testid="task-top-row">
                {extras && <TypePill value={extras.taskType} canEdit={canEditRow} onChange={(t) => void changeType(t)} />}
                {subtaskRows.length > 0 && (
                  <span className="inline-flex items-center gap-1" title={`${subtaskRows.length} subtasks`} aria-label={`${subtaskRows.length} subtasks`}>
                    <GitBranch className="h-3.5 w-3.5" aria-hidden />
                    {subtaskRows.length}
                  </span>
                )}
                {checklistItems.length > 0 && (
                  <span className="inline-flex items-center gap-1" title={`${checklistItems.length} checklist items`} aria-label={`${checklistItems.length} checklist items`}>
                    <ListChecks className="h-3.5 w-3.5" aria-hidden />
                    {checklistItems.length}
                  </span>
                )}
                {forMe > 0 && me && (
                  <span className="inline-flex items-center gap-1 text-violet-700">
                    <PersonAvatar name={me.name} initials={me.initials} color={me.color} avatarUrl={me.avatarUrl} size="xs" />
                    {forMe} for me
                  </span>
                )}
              </div>

              {/* THE HEADING — click to edit the whole text (ClickUp's title; ours is the task text). */}
              <div data-testid="task-title-block" className="mb-3">
                {!editingTitle ? (
                  canEditRow ? (
                    <div
                      role="button"
                      tabIndex={0}
                      onClick={(e) => {
                        if ((e.target as Element).closest("a,button")) return;
                        startTitleEdit();
                      }}
                      onKeyDown={(e) => {
                        if (e.key === "Enter" && e.target === e.currentTarget) {
                          e.preventDefault();
                          startTitleEdit();
                        }
                      }}
                      aria-label="Edit task"
                      title="Click to edit"
                      className={cn(
                        "-mx-1 block w-full cursor-text rounded-md px-1 text-left text-[26px] font-bold leading-tight text-slate-900 hover:bg-slate-50 focus:outline-none focus:ring-2 focus:ring-blue-500",
                        isDone && "text-slate-400 line-through",
                      )}
                    >
                      <InlineTitle taskId={task.id} text={split.heading} attachments={attachments.rows} people={peopleRows} />
                    </div>
                  ) : (
                    <h1 className={cn("text-[26px] font-bold leading-tight text-slate-900", isDone && "text-slate-400 line-through")}>
                      <InlineTitle taskId={task.id} text={split.heading} attachments={attachments.rows} people={peopleRows} />
                    </h1>
                  )
                ) : (
                  <div>
                    <TaskTextField
                      ref={textRef}
                      autoFocus
                      value={titleDraft}
                      onChange={setTitleDraft}
                      team={team}
                      onMention={invite}
                      fileOf={fileOf}
                      onEscape={() => setEditingTitle(false)}
                      ariaLabel="Task"
                      className="block min-h-[5.5em] w-full resize-y rounded-md border border-slate-200 bg-white px-3 py-2 text-base leading-snug text-slate-900 focus:border-violet-500 focus:outline-none focus:ring-2 focus:ring-violet-500/30"
                    />
                    <div className="mt-1.5 flex justify-end gap-2">
                      <button type="button" onClick={() => setEditingTitle(false)} disabled={savingTitle} className="btn btn-secondary btn-sm">
                        Cancel
                      </button>
                      <button
                        type="button"
                        onClick={saveTitle}
                        disabled={!titleDraft.trim() || savingTitle}
                        className="inline-flex h-8 items-center gap-1.5 rounded-md bg-violet-600 px-3 text-xs font-medium text-white hover:bg-violet-700 disabled:opacity-60"
                      >
                        {savingTitle && <RefreshCw className="h-3 w-3 animate-spin" aria-hidden />}
                        Save
                      </button>
                    </div>
                  </div>
                )}
              </div>

              {/* THE PROPERTIES GRID — ClickUp's two columns, 36px rows. */}
              <dl className="grid max-w-[900px] grid-cols-1 lg:grid-cols-2" data-testid="task-properties">
                <Property icon={CircleDashed} label="Status">
                  <StatusCell value={task.group} statuses={STATUSES} canEdit={canEditRow} onChange={(s) => void changeStatus(s)} />
                </Property>
                <Property icon={UserRound} label="Assignees">
                  {people.rows ? (
                    <TaskPeopleField people={people.rows} team={team} onChange={onPeopleChange} currentUserId={currentUserId} variant="page" />
                  ) : (
                    <span className="inline-flex items-center gap-1 px-1" aria-label="Loading people" data-testid="people-skeleton">
                      <PersonAvatar name={task.assigneeName} initials={task.assigneeInitials} color={task.assigneeColor} avatarUrl={task.assigneeAvatarUrl} size="xs" />
                      <span className="skeleton h-5 w-5 rounded-full" />
                    </span>
                  )}
                </Property>
                {/* Local: the CRM's AI-agent row is a CRM integration; here the row is the folder an agent works in. */}
                {projectField && (
                  <Property icon={FolderOpen} label="Project folder" wide>
                    {projectField}
                  </Property>
                )}
                {workspaceField && (
                  <Property icon={GitBranch} label="Workspace" testId="task-workspace" wide>
                    {workspaceField}
                  </Property>
                )}
                {!(hideEmpty && empty.dates) && (
                  <Property icon={CalendarDays} label="Dates">
                    {canEditRow ? (
                      <DatesField
                        startDate={task.startDate}
                        dueDate={task.dueDate}
                        recurrence={task.recurrence}
                        routine={routine?.rule ?? null}
                        routineReady={!!routine && !routine.historyError}
                        routineUnavailable={routine?.historyError ?? routineError}
                        moveNote={
                          routine?.stuck ??
                          dateMoveNote(routine?.rule ?? null, {
                            status: task.group,
                            due: task.dueDate || null,
                            anchor: routine?.anchor ?? null,
                            occurrence: routine?.occurrence ?? null,
                            today: localTodayClient(),
                            datesSoFar: routine?.datesSoFar ?? 0,
                            scheduleNext: routine?.next[0] ?? null,
                          })
                        }
                        routineSaving={routineBusy}
                        routineStuck={routine?.stuck ?? null}
                        routineStuckHidesNext={!!routine?.stuck && !(routine?.next?.length ?? 0)}
                        onRoutineRestart={routine?.canRestart && actions.restartRoutine ? () => void restartRoutineNow() : undefined}
                        peopleCount={routine?.peopleCount ?? 1}
                        onChange={(v) => void saveDates(v)}
                        onRoutineSave={(rule) => void saveRoutineRule(rule)}
                        onRoutineStop={routine?.rule && !routine.rule.stoppedAt && routine.canEdit && actions.stopRoutine ? () => void stopRoutineNow() : undefined}
                        onRoutinePause={routine?.rule && !routine.rule.stoppedAt && routine.canEdit && actions.pauseRoutine ? (p) => void pauseRoutineNow(p) : undefined}
                        startTime={more?.startTime ?? null}
                        dueTime={more?.dueTime ?? null}
                        onTime={
                          more && actions.setTaskTimes
                            ? (which, t) => {
                                setMore((m) => (m ? { ...m, [which === "start" ? "startTime" : "dueTime"]: t } : m));
                                void moreDo("Time", () => actions.setTaskTimes!(task.id, which === "start" ? { startTime: t } : { dueTime: t }));
                              }
                            : undefined
                        }
                        done={isDone}
                      />
                    ) : (
                      <EmptyWord>{summariseTimeline(task.startDate, task.dueDate)}</EmptyWord>
                    )}
                  </Property>
                )}
                {!(hideEmpty && empty.priority) && (
                  <Property icon={Flag} label="Priority">
                    {canEditRow ? <PriorityPill value={task.priority} options={PRIORITIES} onChange={(p) => void changePriority(p)} variant="cell" /> : <EmptyWord>{task.priority}</EmptyWord>}
                  </Property>
                )}
                {!(hideEmpty && empty.time) && (
                  <Property icon={Timer} label="Track time">
                    {unavailable ? (
                      <Unavailable reason={unavailable} />
                    ) : extras ? (
                      <TrackTimeCell
                        entries={extras.timeEntries}
                        estimateMinutes={extras.estimateMinutes}
                        me={me}
                        team={team}
                        canEditEstimate={canEditRow}
                        onStart={timeStart}
                        onStop={timeStop}
                        onAdd={timeAdd}
                        entryTags={more && actions.setTimeEntryTags ? more.entryTags : undefined}
                        onDelete={timeDelete}
                        onEstimate={timeEstimate}
                      />
                    ) : (
                      <span className="skeleton h-5 w-16" />
                    )}
                  </Property>
                )}
                {!(hideEmpty && empty.tags) && (
                  <Property icon={Tag} label="Tags">
                    {unavailable ? <Unavailable reason={unavailable} /> : extras ? <TagsCell
                        labels={extras.labels}
                        canEdit={canEditRow}
                        onChange={(l) => void changeLabels(l)}
                        colors={more?.labelColors}
                        // A tag's colour is everyone's: only an admin or a manager changes it — the swatches show
                        // only to them, never offered and then refused (inc8 re-panel #5; the server decides who).
                        onColor={more?.canColorTags && actions.setLabelColor ? (l, c) => void moreDo("Tag colour", () => actions.setLabelColor!(l, c)) : undefined}
                        onDeleteEverywhere={
                          more && actions.deleteLabelEverywhere
                            ? (l) =>
                                void moreDo("Delete tag", () => actions.deleteLabelEverywhere!(l), () =>
                                  setExtras((x) => (x ? { ...x, labels: x.labels.filter((y) => y.toLowerCase() !== l.toLowerCase()) } : x)),
                                )
                            : undefined
                        }
                      /> : <span className="skeleton h-5 w-16" />}
                  </Property>
                )}
                {!(hideEmpty && empty.related) && (
                  <div className="lg:col-span-2">
                    <Property icon={Link2} label="Related to">
                      <span className="flex min-w-0 flex-wrap items-center gap-1.5 py-1">
                        {links.map((t) => (
                          <a
                            key={`${t.area}:${t.id}`}
                            href={t.href}
                            data-testid="related-to"
                            className="inline-flex h-7 max-w-full items-center gap-1.5 rounded-[5px] border border-slate-200 bg-white px-2.5 text-xs hover:border-slate-300"
                          >
                            <span className="shrink-0 text-slate-400">{tagAreaLabel(t.area)}</span>
                            <span className="truncate text-slate-800">{t.label}</span>
                          </a>
                        ))}
                        {links.length === 0 && <Unavailable reason="Related records live in a CRM — local tasks cannot link to them." />}
                      </span>
                    </Property>
                  </div>
                )}
              </dl>
              {unavailable && (
                <p className="mt-1 text-[11px] text-amber-700" data-testid="extras-unavailable">
                  {unavailable === "This isn't available yet."
                    ? "Task type, tags, time tracking, recurring options and subtask priority and due dates aren't available yet."
                    : "Task type, tags, time tracking, recurring options and subtask details couldn't be loaded — try again."}
                </p>
              )}
              <div className="mt-2 flex items-center gap-3">
                <hr className="flex-1 border-slate-200" />
                <button type="button" onClick={() => setHideEmpty((h) => !h)} className="text-xs text-slate-400 hover:text-slate-700" aria-pressed={hideEmpty}>
                  {hideEmpty ? "Show empty fields" : "Collapse empty fields"}
                </button>
              </div>

              {/* THE BODY — the rest of the task text, then the description. */}
              {split.body && !editingTitle && (
                <div
                  role={canEditRow ? "button" : undefined}
                  tabIndex={canEditRow ? 0 : undefined}
                  onClick={(e) => {
                    if (!canEditRow || (e.target as Element).closest("a,button")) return;
                    startTitleEdit();
                  }}
                  aria-label={canEditRow ? "Edit task text" : undefined}
                  className={cn("-mx-1 mt-3 rounded-md px-1 py-1 text-sm leading-relaxed text-slate-800", canEditRow && "cursor-text hover:bg-slate-50")}
                  data-testid="task-body"
                >
                  <InlineTitle taskId={task.id} text={split.body} attachments={attachments.rows} people={peopleRows} />
                </div>
              )}
              <div className="mt-3">
                <DetailsBlock value={desc} saved={task.description} canEdit={canEditRow} saving={savingDesc} onChange={setDesc} onSave={saveDescription} />
              </div>

              {/* ClickUp's "✎ Add fields" / Fields block — the Fields builder's section (task-fields-section.tsx). */}
              <div className="mt-3" data-testid="task-fields-mount">
                <TaskFieldsSection taskId={task.id} canEdit={canEditRow} team={team} onTaskChanged={refetchAll} actions={fieldActions} />
              </div>

              {/* The routine — its rule, Pause / Stop, and whether each day was done (routine-block.tsx). */}
              {routine?.rule && (
                <div className="mt-4">
                  <RoutineBlock
                    routine={routine}
                    team={team}
                    onPause={actions.pauseRoutine ? (p) => void pauseRoutineNow(p) : undefined}
                    onStop={actions.stopRoutine ? () => void stopRoutineNow() : undefined}
                    onOpenRoot={!routine.isRoot && onNavigate ? () => onNavigate(routine.rootTaskId) : undefined}
                  />
                </div>
              )}

              {/* THE SECTIONS — ClickUp's order: subtasks · relationships · checklists · files. */}
              <div className="mt-4 space-y-5" data-testid="task-sections">
                {bundleState === "loading" && (
                  <div className="space-y-2" data-testid="bundle-skeleton" aria-busy="true" aria-label="Loading the rest of this task">
                    <div className="skeleton h-9 w-full" />
                    <div className="skeleton h-9 w-4/5" />
                    <div className="skeleton h-9 w-3/5" />
                  </div>
                )}
                {bundleState === "error" && (
                  <div role="alert" className="flex items-start gap-2 rounded-md bg-rose-50 px-3 py-2 text-xs text-rose-700 ring-1 ring-rose-100">
                    <AlertCircle className="mt-0.5 h-3.5 w-3.5 shrink-0" aria-hidden />
                    <span className="min-w-0 flex-1">Could not load the people, subtasks, checklists, dependencies and attachments: {bundleError}</span>
                    <button
                      type="button"
                      onClick={() => {
                        setBundleState("loading");
                        setBundleError(null);
                        setReloadKey((k) => k + 1);
                      }}
                      className="inline-flex shrink-0 items-center gap-1 rounded-md px-2 py-0.5 text-xs font-medium hover:bg-rose-100"
                    >
                      <RefreshCw className="h-3 w-3" aria-hidden />
                      Retry
                    </button>
                  </div>
                )}
                {bundleState === "ready" && people.rows && (
                  <>
                    {shown.has("subtasks") && subtasks.rows && (
                      <SubtasksTable
                        rows={subtasks.rows}
                        people={people.rows}
                        team={team}
                        meta={extras ? extras.subtaskMeta : null}
                        currentUserId={currentUserId}
                        onChange={onSubtasksChange}
                        onMeta={(id, patch) => void changeSubtaskMeta(id, patch)}
                        justAdded={justAdded === "subtasks"}
                      />
                    )}
                    <div ref={depsAnchor}>
                      {shown.has("dependencies") && dependencies.rows && (
                        <DependenciesSection key={depKey} rows={dependencies.rows} justAdded={justAdded === "dependencies"} initialKind={depKind} onChange={dependencies.change} />
                      )}
                    </div>
                    {shown.has("checklist") && checklists.rows && (
                      <ChecklistsBlock lists={checklists.rows} people={people.rows} team={team} justAdded={justAdded === "checklist"} onChange={onChecklistChange} />
                    )}
                    {shown.has("attachments") && attachments.rows && (
                      <DetailAttachmentsSection
                        taskId={task.id}
                        rows={attachments.rows}
                        pending={pending}
                        linking={linking}
                        onLinkingChange={setLinking}
                        onChange={attachments.change}
                      />
                    )}
                    <ul className="space-y-0.5" data-testid="task-action-rows">
                      {!shown.has("subtasks") && <ActionRow icon={GitBranch} label="Add subtask" onClick={() => reveal("subtasks")} />}
                      <li>
                        <button
                          ref={relateRef}
                          type="button"
                          onClick={() => setRelateOpen((o) => !o)}
                          aria-haspopup="menu"
                          aria-expanded={relateOpen}
                          className="inline-flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-left text-sm text-slate-600 hover:bg-slate-50 hover:text-slate-900"
                        >
                          <Network className="h-4 w-4 shrink-0 text-slate-400" aria-hidden />
                          Relate items or add dependencies
                        </button>
                        <AnchoredPopover anchorRef={relateRef} open={relateOpen} onClose={() => setRelateOpen(false)} label="Relate items" width={260}>
                          <div role="menu">
                            <button type="button" role="menuitem" onClick={() => relate("linked")} className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50">
                              <Link2 className="h-4 w-4 text-slate-500" aria-hidden />
                              Relate a Task
                            </button>
                            <div className="my-1 border-t border-slate-100" aria-hidden />
                            <button type="button" role="menuitem" onClick={() => relate("blocks")} className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50">
                              <Ban className="h-4 w-4 text-rose-500" aria-hidden />
                              This task blocks…
                            </button>
                            <button type="button" role="menuitem" onClick={() => relate("blocked_by")} className="flex w-full items-center gap-2.5 px-3 py-1.5 text-left text-sm text-slate-800 hover:bg-slate-50">
                              <TriangleAlert className="h-4 w-4 text-amber-500" aria-hidden />
                              This task is blocked by…
                            </button>
                          </div>
                        </AnchoredPopover>
                      </li>
                      {!shown.has("checklist") && <ActionRow icon={ListChecks} label="Create checklist" onClick={() => reveal("checklist")} />}
                      {/* Always here: the chips carry no doors of their own. */}
                      <li>
                        <AttachButton
                          variant="row"
                          shown={false}
                          onLinkFromFiles={() => {
                            reveal("attachments");
                            setLinking(true);
                          }}
                          onUpload={UPLOADS_WIRED ? uploadFiles : undefined}
                          onChooseFromDevice={actions.chooseTaskFiles ? () => void chooseFromDevice() : undefined}
                        />
                      </li>
                    </ul>
                  </>
                )}
              </div>
            </div>
          </div>
          {/* THE RAIL — between the task and Activity (ClickUp: » · 💬 · ↯). */}
          <nav className="flex w-[34px] shrink-0 flex-col items-center gap-1.5 pt-5" aria-label="Task panels">
            <button
              type="button"
              onClick={() => setActivityOpen((o) => !o)}
              aria-label={activityOpen ? "Collapse activity" : "Show activity"}
              title={activityOpen ? "Collapse" : "Show activity"}
              className="grid h-7 w-7 place-content-center rounded-md text-slate-500 hover:bg-slate-100"
            >
              {activityOpen ? <ChevronsRight className="h-4 w-4" aria-hidden /> : <ChevronsLeft className="h-4 w-4" aria-hidden />}
            </button>
            <button
              type="button"
              onClick={() => setActivityOpen(true)}
              aria-label="Activity"
              aria-pressed={activityOpen}
              className={cn("grid h-7 w-7 place-content-center rounded-md hover:bg-slate-100", activityOpen ? "bg-slate-200/70 text-slate-800" : "text-slate-500")}
            >
              <MessageSquare className="h-4 w-4" aria-hidden />
            </button>
            <button
              type="button"
              onClick={() => {
                reveal("dependencies");
                depsAnchor.current?.scrollIntoView({ block: "center", behavior: "smooth" });
              }}
              aria-label="Related items"
              title="Related items"
              className="grid h-7 w-7 place-content-center rounded-md text-slate-500 hover:bg-slate-100"
            >
              <Network className="h-4 w-4" aria-hidden />
            </button>
          </nav>
        </div>

        {/* RIGHT — Activity */}
        {activityOpen && (
          <ActivityPane
            taskId={task.id}
            viewerId={currentUserId}
            team={team}
            people={people.rows}
            followers={more?.followers ?? null}
            iFollow={more?.iFollow ?? true}
            onFollow={more && actions.setFollowing ? (f) => void moreDo(f ? "Follow" : "Unfollow", () => actions.setFollowing!(task.id, f)) : undefined}
            onAddFollower={more && actions.addFollower ? (id) => void moreDo("Add follower", () => actions.addFollower!(task.id, id)) : undefined}
            onRemoveFollower={more && actions.removeFollower ? (id) => void moreDo("Remove follower", () => actions.removeFollower!(task.id, id)) : undefined}
            canRemoveFollowers={!!more?.canRemoveFollowers}
            followersUnavailable={moreUnavailable}
            activity={activity}
            activityError={activityError}
            activityTotal={activityTotal}
            comments={comments}
            commentsError={commentsError}
            attachments={attachments.rows}
            onPost={postComment}
            commands={commands}
            fileOf={fileOf}
            commentExtras={commentExtras}
            commentActions={{
              react: (id, e) => void reactTo(id, e),
              resolve: (id, v) => void resolveComment(id, v),
              sendNow: (id) => void sendCommentNow(id),
            }}
            onAttachFiles={
              UPLOADS_WIRED
                ? async (files) => {
                    const done = await uploadToTask(files);
                    return done.map((a) => ({ id: a.id, info: infoFor(a) }));
                  }
                : undefined
            }
          />
        )}
      </div>
    </div>
  );
}

/** ClickUp's literal placeholder for an unset value. */
function EmptyWord({ children }: { children?: React.ReactNode }) {
  return <span className="text-sm text-slate-400">{children || "Empty"}</span>;
}

/** One of ClickUp's action rows: an icon, a label, and the section it reveals. */
function ActionRow({ icon: Icon, label, onClick }: { icon: typeof Flag; label: string; onClick: () => void }) {
  return (
    <li>
      <button
        type="button"
        onClick={onClick}
        className="inline-flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-left text-sm text-slate-600 hover:bg-slate-50 hover:text-slate-900"
      >
        <Icon className="h-4 w-4 shrink-0 text-slate-400" aria-hidden />
        {label}
      </button>
    </li>
  );
}

/**
 * "Add description" → click → a textarea; blur saves when it changed. Reads
 * as text, not a form, until touched — ClickUp's description block.
 */
function DetailsBlock({
  value,
  saved,
  canEdit,
  saving,
  onChange,
  onSave,
}: {
  value: string;
  saved: string;
  canEdit: boolean;
  saving: boolean;
  onChange: (v: string) => void;
  onSave: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const dirty = value.trim() !== saved;
  if (!editing) {
    if (!canEdit && !saved) return null;
    return (
      <button
        type="button"
        onClick={() => canEdit && setEditing(true)}
        disabled={!canEdit}
        aria-label={saved ? "Edit details" : "Add description"}
        className={cn(
          "-mx-1 block w-full rounded-md px-1 py-1 text-left text-sm",
          saved ? "whitespace-pre-wrap break-words text-slate-800" : "text-slate-500",
          canEdit && "hover:bg-slate-50",
        )}
        data-testid="task-details"
      >
        {saved ? (
          saved
        ) : (
          <span className="inline-flex items-center gap-2.5">
            <FileText className="h-4 w-4 text-slate-400" aria-hidden />
            Add description
          </span>
        )}
      </button>
    );
  }
  return (
    <div>
      <textarea
        autoFocus
        value={value}
        onChange={(e) => onChange(e.target.value)}
        onBlur={() => {
          if (dirty) onSave();
          setEditing(false);
        }}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            e.preventDefault();
            e.stopPropagation();
            onChange(saved);
            setEditing(false);
          }
        }}
        placeholder="Add details…"
        rows={4}
        maxLength={5000}
        aria-label="Description"
        className="w-full resize-y rounded-md border border-slate-200 bg-white px-3 py-2 text-sm placeholder:text-slate-400 focus:outline-none focus:ring-2 focus:ring-violet-500/40"
      />
      {saving && (
        <span className="mt-1 inline-flex items-center gap-1 text-[11px] text-slate-400">
          <AlignLeft className="h-3 w-3" aria-hidden /> Saving…
        </span>
      )}
    </div>
  );
}
