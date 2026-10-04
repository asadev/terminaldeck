// Copied from the reference CRM.
import { RelativeTime } from "./relative-time";
import { localDayStartMs, localParts, localStamp } from "../../shared/crm/local-time";
import { useMemo, useRef, useState } from "react";
import { CalendarClock, Check, ChevronRight, CornerDownRight, Flag, RotateCcw, SendHorizontal, SmilePlus, Timer, UserRound } from "lucide-react";
import { AnchoredPopover } from "./anchored-popover";
import {
  REACTION_EMOJI,
  formatScheduled,
  isPending,
  threadComments,
  visibleTo,
  type CommentExtras,
  type CommentMeta,
  type CommentReaction,
} from "../../shared/crm/task-comments";
import { cn } from "./lib/utils";
import { PersonAvatar } from "./people/person-picker";
import { InlineTitle } from "./inline-title";
import { relativeDay } from "./timeline-field";
import { STATUS_WORD, activityStamp, activityTime, formatDuration } from "../../shared/crm/task-page";
import { fieldActivitySentence, formatFieldValue } from "../../shared/crm/task-fields";
import type { ActivityKind, TaskActivityRow } from "../../shared/crm/task-activity";
import type { TaskAttachment } from "../../shared/crm/collab-types";
import { taskBoardLabel, type TaskAssignee, type TaskComment, type TaskPriority, type TaskStatus } from "../../shared/crm/tasks-data";

/**
 * THE ACTIVITY PANE'S FEED — ClickUp's right-hand column, in ClickUp's words.
 *
 * Asad, 2026-09-15: *"… activities inside and filter i need a pure copy of this
 * tab"*. ClickUp's lines (docs/clickup-task-inventory.md § 2.0): "You created
 * this task", "You assigned to: You", "You created subtask: …", "You added 2
 * items to checklist …", "You set priority to 🚩 High", "You added tag …",
 * "You tracked time ⏱ 1h 30m on Sep 15" — a 4px bullet, 13px grey sentence
 * with the VALUES darker, the time right-aligned ("Just now", "7 mins",
 * "Yesterday at 11:58 pm"). Bottom-anchored: newest against the composer.
 *
 * Comments are cards (white, 1px border, 10px radius: avatar · name · time /
 * body / footer). Once a task has comments the older activity lines FOLD:
 * "You created this task", then "› Show more", then the cards (ClickUp's own
 * behaviour).
 *
 * Nothing in a payload is ever rendered as markup — every value is a string.
 */

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** "just now" · "5 mins ago" · "1 hour ago" · "Yesterday" · "14 Sep" — kept for older callers. */
export function relativeTime(iso: string, now: Date = new Date()): string {
  const t = new Date(iso).getTime();
  if (!Number.isFinite(t)) return "";
  const s = Math.max(0, Math.round((now.getTime() - t) / 1000));
  if (s < 45) return "just now";
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min${m === 1 ? "" : "s"} ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} hour${h === 1 ? "" : "s"} ago`;
  // The day and the label locally, never the machine's zone (#418, lib/tasks/local-time.ts).
  if (t >= localDayStartMs(now) - 86400000) return "Yesterday";
  const d = localParts(t)!;
  const label = `${d.d} ${MONTHS[d.m - 1]}`;
  return d.y === localParts(now)!.y ? label : `${label} ${d.y}`;
}

/**
 * An activity or comment time. A fixed `now` (tests) renders the words at once;
 * otherwise <RelativeTime> shows the local stamp in the server's HTML and the
 * browser's first render — identical in both — and the relative words after
 * mount ("7 mins" can never match between the two renders: React #418).
 */
function When({ iso, now, className }: { iso: string; now?: Date; className?: string }) {
  if (now)
    return (
      <time className={className} dateTime={iso} title={localStamp(iso)}>
        {activityTime(iso, now)}
      </time>
    );
  return <RelativeTime iso={iso} format={activityTime} stamp={activityStamp} title={localStamp(iso)} className={className} />;
}

function monthDayOf(isoDate: string | null | undefined): string {
  if (!isoDate) return "";
  const [, m, d] = String(isoDate).split("-").map(Number);
  return m && d ? `${MONTHS[m - 1]} ${d}` : String(isoDate);
}

/**
 * A merge's kept field values as words — "Budget: AED 5,000" — formatted as the field itself would show them
 * (people by name). A line written before round 6 carries plain text: shown as written.
 */
function keptFieldsText(fk: unknown, who: (userId: string | null | undefined) => string | null): string[] {
  if (typeof fk === "string") return fk ? [fk] : [];
  if (!Array.isArray(fk)) return [];
  return fk.flatMap((f) => {
    if (!f || typeof f !== "object") return [];
    const x = f as { label?: unknown; kind?: unknown; config?: unknown; value?: unknown };
    const label = typeof x.label === "string" && x.label ? x.label : "A field";
    let text: string | null = null;
    try {
      if (typeof x.kind === "string") text = formatFieldValue({ kind: x.kind, config: x.config && typeof x.config === "object" ? x.config : {}, value: x.value } as never, (id) => who(id));
    } catch {
      text = null;
    }
    if (text === null) text = typeof x.value === "string" ? x.value : x.value === null || x.value === undefined ? "" : JSON.stringify(x.value);
    return [`${label}: ${text.slice(0, 80)}`];
  });
}

/** A sentence in pieces: plain words, darker values, a priority flag, the timer glyph. */
export type FeedPart = string | { strong: string } | { flag: TaskPriority } | { timer: true };

export function partsText(parts: FeedPart[]): string {
  return parts.map((p) => (typeof p === "string" ? p : "strong" in p ? p.strong : "flag" in p ? "" : "")).join("");
}

const PRIORITY_FLAG: Record<TaskPriority, string> = {
  Low: "text-slate-400",
  Medium: "text-blue-600",
  High: "text-amber-500",
  Critical: "text-rose-600",
};

/**
 * One sentence per row. `who(id)` resolves a person named only by id; the
 * actor's own name comes from the row. `viewerId` turns both into "You".
 */
export function describeActivity(
  row: TaskActivityRow,
  viewerId: string,
  who: (userId: string | null | undefined) => string | null,
): FeedPart[] {
  const actor = row.actorUserId === viewerId ? "You" : row.actor?.name ?? "Someone";
  const p = row.payload;
  const str = (k: string) => (typeof p[k] === "string" ? (p[k] as string) : null);
  const num = (k: string) => (typeof p[k] === "number" ? (p[k] as number) : null);
  const person = (idKey: string, nameKey: string) => {
    const id = str(idKey);
    if (id && id === viewerId) return "You";
    return str(nameKey) ?? who(id) ?? "someone";
  };
  const status = (s: string | null) => (s && s in STATUS_WORD ? STATUS_WORD[s as TaskStatus] : (s ?? "").toUpperCase());
  switch (row.kind) {
    case "created":
      return [`${actor} created this task`];
    case "assigned":
      return p.primary === false ? [`${actor} added `, { strong: person("user_id", "name") }] : [`${actor} assigned to: `, { strong: person("user_id", "name") }];
    case "unassigned":
      return [`${actor} removed assignee: `, { strong: person("user_id", "name") }];
    case "status": {
      const from = str("from");
      const to = str("to");
      return from
        ? [`${actor} changed status from `, { strong: status(from) }, " to ", { strong: status(to) }]
        : [`${actor} set status to `, { strong: status(to) }];
    }
    case "priority": {
      const to = str("to") as TaskPriority | null;
      return to ? [`${actor} set priority to `, { flag: to }, { strong: to }] : [`${actor} removed the priority`];
    }
    case "dates": {
      // "Sync dates with subtasks" switched (inc8 review L3).
      if (typeof p.sync === "boolean") return [`${actor} turned ${p.sync ? "on" : "off"} `, { strong: "Sync dates with subtasks" }];
      const out: FeedPart[] = [];
      const pair = (label: string, from: string | null, to: string | null) => {
        if (from === to) return;
        if (out.length) out.push(" · ");
        if (!to) out.push(`${actor} removed the ${label}`);
        else if (!from) out.push(`${actor} set the ${label} to `, { strong: relativeDay(to) });
        else out.push(`${actor} changed the ${label} from `, { strong: relativeDay(from) }, " to ", { strong: relativeDay(to) });
      };
      const time = (label: string, from: string | null, to: string | null) => {
        if (from === to) return;
        if (out.length) out.push(" · ");
        if (!to) out.push(`${actor} removed the ${label}`);
        else if (!from) out.push(`${actor} set the ${label} to `, { strong: to });
        else out.push(`${actor} changed the ${label} from `, { strong: from }, " to ", { strong: to });
      };
      pair("start date", str("start_from"), str("start_to"));
      pair("due date", str("due_from"), str("due_to"));
      time("start time", str("start_time_from"), str("start_time_to"));
      time("due time", str("due_time_from"), str("due_time_to"));
      // The owner's "Sync dates with subtasks" moved the task after a subtask changed — the subtask's change was this person's.
      if (p.synced && out.length) return [`Synced from a subtask change by ${actor}: `, ...out.map((x) => (typeof x === "string" ? x.replace(`${actor} `, "") : x))];
      return out.length ? out : [`${actor} changed the dates`];
    }
    case "title":
      return [`${actor} renamed this task`];
    case "description":
      return [`${actor} updated the description`];
    case "archived":
      return [`${actor} ${p.on ? "archived this task" : "restored this task from the archive"}`];
    case "follower": {
      // Someone else's follow changed: who added or removed whom (round 7, V1 — the owner, an admin, or themselves).
      const target = str("user");
      if (target && target !== row.actorUserId) {
        const name = target === viewerId ? "you" : who(target) ?? "someone";
        return p.following ? [`${actor} added `, { strong: name }, " as a follower"] : [`${actor} removed `, { strong: name }, " from the followers"];
      }
      return [`${actor} ${p.following ? "is following" : "unfollowed"} this task`];
    }
    case "merged": {
      if (str("into")) return [`${actor} merged this task into `, { strong: str("title") ?? "another task" }];
      // Who joined, and every value the other task held where this one's won — SHOWN, since this line is the only
      // place it survives (inc8 re-panel #1, #2; ops.task_merge writes people_added and fields_kept).
      const joined = Array.isArray(p.people_added) ? (p.people_added as unknown[]).filter((x): x is string => typeof x === "string").map((id) => who(id) ?? "someone") : [];
      const kept = keptFieldsText(p.fields_kept, who);
      // Past the read's caps the line says how many more there were (r8 #6) — never a list that silently stops.
      const more = (k: string) => (typeof p[k] === "number" && (p[k] as number) > 0 ? ` and ${p[k]} more` : "");
      return [
        `${actor} merged `,
        { strong: str("title") ?? "a task" },
        " into this task",
        ...(joined.length ? [" and added ", { strong: joined.join(", ") + more("people_added_more") }] : []),
        ...(kept.length
          ? [" — its values set aside (this task's were kept): ", { strong: kept.join("; ") + more("fields_kept_more") }]
          : typeof p.fields_kept_more === "number" && p.fields_kept_more > 0
            ? [` — ${p.fields_kept_more} values set aside were too long to show here`]
            : []),
      ];
    }
    case "converted":
      return [`${actor} converted this task into a subtask`];
    case "subtask_added":
      return [`${actor} created subtask: `, { strong: str("title") ?? "" }];
    case "subtask_done":
      return [`${actor} ${p.done ? "completed" : "reopened"} subtask: `, { strong: str("title") ?? "" }];
    case "checklist_added":
      return [`${actor} created checklist `, { strong: str("title") ?? "Checklist" }];
    case "checklist_item":
      return p.done === null || p.done === undefined
        ? [`${actor} added an item to a checklist: `, { strong: str("title") ?? "" }]
        : [`${actor} ${p.done ? "checked" : "unchecked"} `, { strong: str("title") ?? "" }];
    case "dependency": {
      const k = str("kind");
      if (p.removed) return [`${actor} removed a relationship with `, { strong: str("title") ?? "another task" }];
      const rel = k === "blocked_by" ? "is waiting on" : k === "blocks" ? "is blocking" : "is linked to";
      return [`${actor} marked this task ${rel} `, { strong: str("title") ?? "another task" }];
    }
    case "attachment":
      return [`${actor} ${p.removed ? "removed" : "attached"} `, { strong: str("file_name") ?? "a file" }];
    case "comment":
      return [`${actor} commented`];
    case "time_tracked": {
      // A time entry's tags changed (inc8 review L3).
      if ("tags_to" in p || "tags_from" in p) return str("tags_to") ? [`${actor} tagged a time entry `, { strong: str("tags_to")! }] : [`${actor} removed a time entry's tags`];
      const secs = num("seconds") ?? 0;
      return [`${actor} tracked time `, { timer: true }, { strong: formatDuration(secs) }, ` on ${monthDayOf(str("on"))}`];
    }
    case "estimate": {
      const to = num("to");
      return to === null ? [`${actor} removed the time estimate`] : [`${actor} set the time estimate to `, { strong: formatDuration(to * 60) }];
    }
    case "tags":
      return str("added") ? [`${actor} added tag `, { strong: str("added")! }] : [`${actor} removed tag `, { strong: str("removed") ?? "" }];
    case "task_type":
      return [`${actor} changed task type to `, { strong: str("to") === "milestone" ? "Milestone" : "Task" }];
    case "moved": {
      const to = str("to") ?? "";
      return [`${actor} moved this task to `, { strong: taskBoardLabel(to) }];
    }
    case "recurrence": {
      if (p.restarted) return [`${actor} restarted this routine`];
      const to = str("to");
      return to ? [`${actor} set this task to repeat `, { strong: to }] : [`${actor} stopped this task repeating`];
    }
    case "field":
      // A field line carries scalars only (the read lets lists through for the merge line alone).
      return [fieldActivitySentence(actor, p as Parameters<typeof fieldActivitySentence>[1])];
    case "map":
      // bond: docs/bond/charter.md §B7 — never the map's NAME here (the task's viewers may not be on the map).
      return mapActivitySentence(actor, str);
  }
}

// bond: the task's mind-map lines (src/lib/bond/*).
function mapActivitySentence(actor: string, str: (k: string) => string | null): FeedPart[] {
  const topic = str("topic");
  const sub = str("title") ?? topic ?? "a subtask";
  switch (str("action")) {
    case "made":
      return [`${actor} made this task from a topic on a mind map`];
    case "made_subtask":
      return [`${actor} made subtask `, { strong: topic ?? "" }, " from a topic on a mind map"];
    case "linked":
      return [`${actor} linked this task to a topic on a mind map`];
    case "unlinked":
      return str("subtask_id") ? [`${actor} took subtask `, { strong: topic ?? "" }, " off its mind map topic"] : [`${actor} took this task off its mind map topic`];
    case "promoted":
      return [`${actor} made this task from a subtask moved on a mind map`];
    case "subtask_moved_out":
      return [`${actor} moved subtask `, { strong: sub }, " to another task on a mind map"];
    case "subtask_promoted":
      return [`${actor} turned subtask `, { strong: sub }, " into a task of its own on a mind map"];
    default:
      return [`${actor} changed this task on a mind map`];
  }
}

// ── what the filter can hide ───────────────────────────────────────────────

export const FEED_CATEGORIES = [
  { key: "comments", label: "Comments" },
  { key: "status", label: "Status" },
  { key: "people", label: "Assignees" },
  { key: "dates", label: "Dates" },
  { key: "priority", label: "Priority" },
  { key: "subtasks", label: "Subtasks" },
  { key: "checklists", label: "Checklists" },
  { key: "attachments", label: "Attachments" },
  { key: "relationships", label: "Relationships" },
  { key: "time", label: "Time tracking" },
  { key: "details", label: "Name, description, tags, type & moves" },
] as const;
export type FeedCategory = (typeof FEED_CATEGORIES)[number]["key"];

const CATEGORY_OF: Record<ActivityKind, FeedCategory | null> = {
  created: null, // always shown
  title: "details",
  description: "details",
  status: "status",
  priority: "priority",
  dates: "dates",
  assigned: "people",
  unassigned: "people",
  map: "details", // bond:
  subtask_added: "subtasks",
  subtask_done: "subtasks",
  checklist_added: "checklists",
  checklist_item: "checklists",
  dependency: "relationships",
  attachment: "attachments",
  comment: "comments",
  time_tracked: "time",
  estimate: "time",
  tags: "details",
  task_type: "details",
  moved: "details",
  recurrence: "dates",
  field: "details",
  archived: "details",
  follower: "people",
  merged: "details",
  converted: "subtasks",
};

export type FeedEntry =
  | { kind: "activity"; id: string; at: string; actor: TaskAssignee | null; parts: FeedPart[]; text: string; category: FeedCategory | null }
  | { kind: "comment"; id: string; at: string; comment: TaskComment };

/**
 * Activity rows + comments, oldest first. Consecutive "added an item to a
 * checklist" lines by one person within ten minutes fold into ClickUp's
 * "You added 2 items to a checklist".
 */
export function buildFeed(
  rows: TaskActivityRow[],
  comments: TaskComment[],
  viewerId: string,
  who: (userId: string | null | undefined) => string | null,
): FeedEntry[] {
  const entries: FeedEntry[] = [];
  for (const r of rows) {
    if (r.kind === "comment") continue; // the comment itself is in the feed
    const prev = entries[entries.length - 1];
    const isAdd = r.kind === "checklist_item" && (r.payload.done === null || r.payload.done === undefined);
    if (
      isAdd &&
      prev?.kind === "activity" &&
      prev.id.startsWith("group:") &&
      prev.actor?.id === r.actorUserId &&
      new Date(r.createdAt).getTime() - new Date(prev.at).getTime() < 600000
    ) {
      const n = Number(prev.id.split(":")[2]) + 1;
      const actor = r.actorUserId === viewerId ? "You" : r.actor?.name ?? "Someone";
      const parts: FeedPart[] = [`${actor} added `, { strong: `${n} items` }, " to a checklist"];
      entries[entries.length - 1] = { ...prev, id: `group:${r.id}:${n}`, at: r.createdAt, parts, text: partsText(parts) };
      continue;
    }
    const parts = describeActivity(r, viewerId, who);
    entries.push({
      kind: "activity",
      id: isAdd ? `group:${r.id}:1` : r.id,
      at: r.createdAt,
      actor: r.actor ?? (r.actorUserId ? { id: r.actorUserId, name: who(r.actorUserId) ?? "", initials: "", color: "", avatarUrl: null } : null),
      parts,
      text: partsText(parts),
      category: CATEGORY_OF[r.kind] ?? null,
    });
  }
  for (const c of comments) entries.push({ kind: "comment", id: c.id, at: c.createdAt, comment: c });
  return entries.sort((a, b) => new Date(a.at).getTime() - new Date(b.at).getTime());
}

function Part({ part }: { part: FeedPart }) {
  if (typeof part === "string") return <>{part}</>;
  if ("strong" in part) return <span className="font-medium text-slate-700">{part.strong}</span>;
  if ("flag" in part) return <Flag className={cn("mx-0.5 inline h-3.5 w-3.5 -translate-y-px fill-current", PRIORITY_FLAG[part.flag])} aria-hidden />;
  return <Timer className="mx-0.5 inline h-3.5 w-3.5 -translate-y-px text-slate-500" aria-hidden />;
}

export function ActivityFeed({
  rows,
  comments,
  viewerId,
  team,
  taskId,
  attachments = null,
  now,
  query = "",
  hidden,
  commentExtras = null,
  commentActions,
  replyingTo = null,
  replyBox = null,
}: {
  rows: TaskActivityRow[];
  comments: TaskComment[];
  viewerId: string;
  team: TaskAssignee[];
  /** For the files and mentions inside comment bodies. */
  taskId?: string;
  attachments?: TaskAttachment[] | null;
  now?: Date;
  /** The pane's 🔍 search — only entries whose words contain it. */
  query?: string;
  /** The pane's filter — categories switched off. */
  hidden?: ReadonlySet<FeedCategory>;
  /**
   * The comment card's threading, reactions, assignee, resolution and schedule
   * (task-comments.ts). Absent (the comments migration not applied) = plain
   * cards, no footer — never a footer whose buttons would be refused.
   */
  commentExtras?: CommentExtras | null;
  commentActions?: CommentActions;
  /** The reply box, drawn under the thread whose Reply was pressed. */
  replyingTo?: string | null;
  replyBox?: React.ReactNode;
}) {
  const who = useMemo(() => {
    const byId = new Map(team.map((p) => [p.id, p.name]));
    return (id: string | null | undefined) => (id ? byId.get(id) ?? null : null);
  }, [team]);
  const people = useMemo(() => new Map(team.map((p) => [p.id, p])), [team]);
  const meta = useMemo(() => commentExtras?.meta ?? {}, [commentExtras]);
  const { top, replies } = useMemo(() => {
    const visible = comments.filter((c) => visibleTo(c, meta[c.id], viewerId));
    return threadComments(visible, meta);
  }, [comments, meta, viewerId]);
  const all = useMemo(() => buildFeed(rows, top, viewerId, who), [rows, top, viewerId, who]);
  const [expanded, setExpanded] = useState(false);

  const q = query.trim().toLowerCase();
  const shown = all.filter((e) => {
    if (e.kind === "comment") {
      if (hidden?.has("comments")) return false;
      const thread = [e.comment, ...(replies.get(e.comment.id) ?? [])];
      return !q || thread.some((c) => c.body.toLowerCase().includes(q) || c.authorName.toLowerCase().includes(q));
    }
    if (e.category && hidden?.has(e.category)) return false;
    return !q || e.text.toLowerCase().includes(q);
  });

  // ClickUp's fold: with comments present, activity older than the last comment
  // hides behind "Show more" — except the first line ("You created this task").
  const lastComment = shown.map((e) => e.kind).lastIndexOf("comment");
  const foldable = !expanded && !q && lastComment > 0 ? shown.slice(1, lastComment).filter((e) => e.kind === "activity") : [];
  const folded = new Set(foldable.map((e) => e.id));

  if (shown.length === 0) {
    return <p className="px-5 py-3 text-[13px] text-slate-400">{q || hidden?.size ? "Nothing matches." : "Nothing has happened here yet."}</p>;
  }
  return (
    <ol className="space-y-0.5 px-5 py-3" data-testid="activity-feed">
      {shown.map((e, i) => {
        if (folded.has(e.id)) {
          const firstFolded = shown.findIndex((x) => folded.has(x.id)) === i;
          return firstFolded ? (
            <li key="show-more">
              <button
                type="button"
                onClick={() => setExpanded(true)}
                className="flex h-8 items-center gap-1 text-[13px] text-slate-500 hover:text-slate-800"
                data-testid="activity-show-more"
              >
                <ChevronRight className="h-3.5 w-3.5" aria-hidden />
                Show more
              </button>
            </li>
          ) : null;
        }
        if (e.kind === "activity") {
          return (
            <li key={e.id} className="flex min-h-8 items-start gap-2.5 py-1.5 text-[13px] leading-5 text-slate-500">
              <span className="mt-2 h-1 w-1 shrink-0 rounded-full bg-slate-400" aria-hidden />
              <span className="min-w-0 flex-1 break-words">
                {e.parts.map((p, k) => (
                  <Part key={k} part={p} />
                ))}
              </span>
              <When iso={e.at} now={now} className="shrink-0 pl-3 text-xs text-slate-400" />
            </li>
          );
        }
        const c = e.comment;
        return (
          <li key={e.id} className="py-1.5">
            <CommentCard
              comment={c}
              replies={replies.get(c.id) ?? []}
              meta={meta}
              reactions={commentExtras?.reactions ?? {}}
              withFooter={!!commentExtras && !!commentActions}
              actions={commentActions}
              viewerId={viewerId}
              people={people}
              taskId={taskId}
              team={team}
              attachments={attachments}
              now={now}
              replyBox={replyingTo === c.id ? replyBox : null}
            />
          </li>
        );
      })}
    </ol>
  );
}


// ── the comment card ─────────────────────────────────────────────────────────

export type CommentActions = {
  react: (commentId: string, emoji: string) => void;
  reply: (commentId: string) => void;
  resolve: (commentId: string, resolved: boolean) => void;
  sendNow: (commentId: string) => void;
};

function Body({ c, taskId, team, attachments }: { c: TaskComment; taskId?: string; team: TaskAssignee[]; attachments: TaskAttachment[] | null }) {
  return taskId ? <InlineTitle taskId={taskId} text={c.body} attachments={attachments} people={team} /> : <span className="whitespace-pre-wrap break-words">{c.body}</span>;
}

/**
 * ClickUp's comment card (inventory § 2.0): avatar · name · time / body / a
 * 1px rule / 👍 react … Reply. Ours also carries ClickUp's assigned-comment
 * line (Assigned to X · Resolve), the replies (one level, under the card), and
 * — for its author only — a scheduled comment's "Scheduled for … · Send now".
 */
function CommentCard({
  comment: c,
  replies,
  meta,
  reactions,
  withFooter,
  actions,
  viewerId,
  people,
  taskId,
  team,
  attachments,
  now,
  replyBox,
}: {
  comment: TaskComment;
  replies: TaskComment[];
  meta: Record<string, CommentMeta>;
  reactions: Record<string, CommentReaction[]>;
  withFooter: boolean;
  actions?: CommentActions;
  viewerId: string;
  people: Map<string, TaskAssignee>;
  taskId?: string;
  team: TaskAssignee[];
  attachments: TaskAttachment[] | null;
  now?: Date;
  replyBox: React.ReactNode;
}) {
  const m = meta[c.id];
  const face = c.authorUserId ? people.get(c.authorUserId) : undefined;
  const withdrawn = m?.withdrawn ?? null;
  const pending = !withdrawn && isPending(m, now);
  const assignee = m?.assigneeUserId ? people.get(m.assigneeUserId) : undefined;
  const resolved = !!m?.resolvedAt;
  const resolver = m?.resolvedBy ? (m.resolvedBy === viewerId ? "you" : people.get(m.resolvedBy)?.name ?? "someone") : null;
  const name = (id: string | null) => (id === viewerId ? "You" : people.get(id ?? "")?.name ?? "Someone");
  return (
    <article
      className={cn("rounded-[10px] border bg-white", withdrawn ? "border-dashed border-rose-300" : pending ? "border-dashed border-violet-300" : "border-slate-200", resolved && "opacity-75")}
      data-testid="comment-card"
    >
      {withdrawn && (
        <div className="flex items-center gap-2 rounded-t-[10px] bg-rose-50 px-4 py-1.5 text-xs text-rose-800" role="status" data-testid="comment-withdrawn">
          <CalendarClock className="h-3.5 w-3.5" aria-hidden />
          <span className="flex-1">Not posted — {withdrawn.reason}. Only you can see it.</span>
        </div>
      )}
      {pending && m?.scheduledFor && (
        <div className="flex items-center gap-2 rounded-t-[10px] bg-violet-50 px-4 py-1.5 text-xs text-violet-800" data-testid="comment-scheduled">
          <CalendarClock className="h-3.5 w-3.5" aria-hidden />
          <span className="flex-1">
            {new Date(m.scheduledFor).getTime() > (now ?? new Date()).getTime()
              ? `Scheduled for ${formatScheduled(m.scheduledFor, now)} — only you can see it until then`
              : "Waiting to be sent — only you can see it until it goes out"}
          </span>
          {actions && (
            <button type="button" onClick={() => actions.sendNow(c.id)} className="inline-flex items-center gap-1 rounded px-1.5 py-0.5 font-medium hover:bg-violet-100">
              <SendHorizontal className="h-3 w-3" aria-hidden />
              Send now
            </button>
          )}
        </div>
      )}
      <header className="flex items-center gap-2 px-4 pt-3">
        <PersonAvatar name={c.authorName} initials={c.authorInitials} color={c.authorColor} avatarUrl={face?.avatarUrl ?? null} size="xs" />
        <span className="text-sm font-semibold text-slate-800">{c.authorUserId === viewerId ? "You" : c.authorName}</span>
        <When iso={c.createdAt} now={now} className="text-xs text-slate-400" />
      </header>
      <div className="px-4 pb-3 pt-1.5 text-sm leading-relaxed text-slate-800">
        <Body c={c} taskId={taskId} team={team} attachments={attachments} />
      </div>
      {(assignee || resolved) && (
        <div className="mx-4 mb-2 flex items-center gap-2 rounded-md bg-slate-50 px-2.5 py-1.5 text-xs text-slate-600" data-testid="comment-assigned">
          {assignee && (
            <>
              <UserRound className="h-3.5 w-3.5 text-slate-400" aria-hidden />
              <span>
                Assigned to <b className="font-medium text-slate-800">{m?.assigneeUserId === viewerId ? "you" : assignee.name}</b>
              </span>
            </>
          )}
          {resolved && (
            <span className="inline-flex items-center gap-1 text-emerald-700">
              <Check className="h-3.5 w-3.5" aria-hidden />
              Resolved{resolver ? ` by ${resolver}` : ""}
            </span>
          )}
          {withFooter && actions && (assignee || resolved) && (
            <button
              type="button"
              onClick={() => actions.resolve(c.id, !resolved)}
              className="ml-auto inline-flex items-center gap-1 rounded px-1.5 py-0.5 font-medium text-slate-700 hover:bg-slate-200"
            >
              {resolved ? <RotateCcw className="h-3 w-3" aria-hidden /> : <Check className="h-3 w-3" aria-hidden />}
              {resolved ? "Reopen" : "Resolve"}
            </button>
          )}
        </div>
      )}
      {replies.length > 0 && (
        <ol className="mx-4 mb-2 space-y-2 border-l-2 border-slate-100 pl-3" aria-label="Replies" data-testid="comment-replies">
          {replies.map((r) => {
            const rf = r.authorUserId ? people.get(r.authorUserId) : undefined;
            return (
              <li key={r.id} className="text-sm">
                <div className="flex items-center gap-1.5">
                  <PersonAvatar name={r.authorName} initials={r.authorInitials} color={r.authorColor} avatarUrl={rf?.avatarUrl ?? null} size="xs" />
                  <span className="text-[13px] font-semibold text-slate-800">{name(r.authorUserId)}</span>
                  <When iso={r.createdAt} now={now} className="text-[11px] text-slate-400" />
                </div>
                <div className="pl-6 leading-relaxed text-slate-800">
                  <Body c={r} taskId={taskId} team={team} attachments={attachments} />
                </div>
                {withFooter && actions && (
                  <div className="pl-6">
                    <Reactions list={reactions[r.id] ?? []} viewerId={viewerId} people={people} onReact={(e) => actions.react(r.id, e)} small />
                  </div>
                )}
              </li>
            );
          })}
        </ol>
      )}
      {replyBox && <div className="mx-4 mb-3">{replyBox}</div>}
      {withFooter && actions && (
        <footer className="flex items-center gap-2 border-t border-slate-100 px-3 py-1.5">
          <Reactions list={reactions[c.id] ?? []} viewerId={viewerId} people={people} onReact={(e) => actions.react(c.id, e)} />
          <button
            type="button"
            onClick={() => actions.reply(c.id)}
            className="ml-auto inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[13px] text-slate-500 hover:bg-slate-100 hover:text-slate-800"
          >
            <CornerDownRight className="h-3.5 w-3.5" aria-hidden />
            Reply
          </button>
        </footer>
      )}
    </article>
  );
}

/** The reaction chips (emoji + count, pressed when yours) and the ☺+ picker. */
function Reactions({
  list,
  viewerId,
  people,
  onReact,
  small = false,
}: {
  list: CommentReaction[];
  viewerId: string;
  people: Map<string, TaskAssignee>;
  onReact: (emoji: string) => void;
  small?: boolean;
}) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const [open, setOpen] = useState(false);
  return (
    <span className="inline-flex flex-wrap items-center gap-1">
      {list.map((r) => {
        const mine = r.userIds.includes(viewerId);
        const who = r.userIds.map((id) => (id === viewerId ? "You" : people.get(id)?.name ?? "Someone")).join(", ");
        return (
          <button
            key={r.emoji}
            type="button"
            onClick={() => onReact(r.emoji)}
            aria-pressed={mine}
            aria-label={`${r.emoji} ${r.userIds.length} — ${who}`}
            title={who}
            className={cn(
              "inline-flex h-6 items-center gap-1 rounded-full border px-1.5 text-xs",
              mine ? "border-violet-300 bg-violet-50 text-violet-800" : "border-slate-200 bg-white text-slate-600 hover:bg-slate-50",
            )}
          >
            <span>{r.emoji}</span>
            <span className="tabular-nums">{r.userIds.length}</span>
          </button>
        );
      })}
      <button
        ref={ref}
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-label="Add a reaction"
        title="React"
        className={cn("grid place-content-center rounded text-slate-400 hover:bg-slate-100 hover:text-slate-700", small ? "h-5 w-5" : "h-6 w-6")}
      >
        <SmilePlus className={small ? "h-3.5 w-3.5" : "h-4 w-4"} aria-hidden />
      </button>
      <AnchoredPopover anchorRef={ref} open={open} onClose={() => setOpen(false)} label="Reactions" width={232}>
        <div className="flex flex-wrap gap-0.5 p-1.5" data-testid="reaction-picker">
          {REACTION_EMOJI.map((e) => (
            <button
              key={e}
              type="button"
              onClick={() => {
                setOpen(false);
                onReact(e);
              }}
              aria-label={`React ${e}`}
              className="grid h-8 w-8 place-content-center rounded text-lg hover:bg-slate-100"
            >
              {e}
            </button>
          ))}
        </div>
      </AnchoredPopover>
    </span>
  );
}
