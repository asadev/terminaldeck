// Copied from the reference CRM.
/**
 * THE COMMENT CARD'S RULES — ClickUp's reply · react · resolve · assign ·
 * "Schedule for later" (docs/clickup-task-inventory.md § 2.0, § 2.10), pure.
 *
 * The columns behind them come from migrations/2026-09-15-task-comments.sql;
 * the page reads them through task-comment-actions.fetchCommentExtras, so the
 * comments themselves read exactly as before when that migration is not there.
 */
import { localClock, localInstantAt, localParts, todayYmd, ymdAddDays, ymdDiff, ymdWeekday } from "./local-time";
import type { TaskComment } from "./tasks-data";

export const TASK_COMMENTS_MIGRATION = "2026-09-15-task-comments.sql";

/** What a comment carries beyond its body. */
export type CommentMeta = {
  /** The comment this one replies to — threads are one level deep, as ClickUp's. */
  parentId: string | null;
  resolvedAt: string | null;
  resolvedBy: string | null;
  /** 👤 "Assign comment" — the person it is waiting on. */
  assigneeUserId: string | null;
  /** Send ⌄ "Schedule for later": shown to others only once it goes out at this moment. */
  scheduledFor: string | null;
  /**
   * Its time came but it was NOT posted — its author was no longer on the task (comment-delivery.ts). Only its author
   * ever receives a withdrawn comment, so only they see "Not posted — <reason>" (batch-2 re-panel #5). Absent = posted.
   */
  withdrawn?: { at: string; reason: string } | null;
  /**
   * When it went out (the tick or Send now) — null while it waits. Present only once the delivery migration is there;
   * then THIS decides "still waiting", never the clock (batch-2 round 3, #5). Absent = before it: the clock decides.
   */
  deliveredAt?: string | null;
};

export type CommentReaction = { emoji: string; userIds: string[] };

export type CommentExtras = {
  meta: Record<string, CommentMeta>;
  reactions: Record<string, CommentReaction[]>;
};

/** The quick reactions under a comment. */
export const REACTION_EMOJI = ["👍", "❤️", "😂", "🎉", "👀", "🙏", "✅", "🔥"] as const;

export function isReactionEmoji(e: unknown): e is (typeof REACTION_EMOJI)[number] {
  return typeof e === "string" && (REACTION_EMOJI as readonly string[]).includes(e);
}

// ── Send ⌄ "Schedule for later" ────────────────────────────────────────────

/** "8:00 AM" — local. */
function clock(d: Date): string {
  return localClock(d, true);
}

const DAY = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/**
 * ClickUp's presets (inventory § 2.10), each with the moment it resolves to:
 * In 20 minutes · In 2 hours · Tomorrow 8:00 AM · In 2 days 8:00 AM · Next week (Mon) 8:00 AM.
 * "8:00 AM" and the days are local, whatever zone the browser is in.
 */
export function schedulePresets(now: Date = new Date()): { key: string; label: string; at: Date; hint: string }[] {
  const plus = (ms: number) => new Date(now.getTime() + ms);
  const today = todayYmd(now);
  const days = (n: number) => localInstantAt(ymdAddDays(today, n), 8);
  const toMonday = ((8 - ymdWeekday(today)) % 7) || 7;
  const presets = [
    { key: "20m", label: "In 20 minutes", at: plus(20 * 60 * 1000) },
    { key: "2h", label: "In 2 hours", at: plus(2 * 3600 * 1000) },
    { key: "tomorrow", label: "Tomorrow", at: days(1) },
    { key: "2d", label: "In 2 days", at: days(2) },
    { key: "next-week", label: "Next week", at: days(toMonday) },
  ];
  return presets.map((p) => ({
    ...p,
    hint: p.key === "20m" || p.key === "2h" ? clock(p.at) : `${DAY[localParts(p.at)!.weekday]}, ${clock(p.at)}`,
  }));
}

/** "Tomorrow at 8:00 AM" / "Thu, Sep 17 at 8:00 AM" — the scheduled card's line, in this computer's time. */
export function formatScheduled(iso: string, now: Date = new Date()): string {
  const p = localParts(iso);
  if (!p) return "";
  const diff = ymdDiff(todayYmd(now), p.ymd);
  const when = diff === 0 ? "Today" : diff === 1 ? "Tomorrow" : `${DAY[p.weekday]}, ${MON[p.m - 1]} ${p.d}`;
  return `${when} at ${clock(new Date(iso))}`;
}

/** Is a scheduled comment still waiting? */
export function isPending(meta: CommentMeta | undefined, now: Date = new Date()): boolean {
  if (!meta?.scheduledFor || meta.withdrawn) return false;
  // Delivered or not — the server's record, not the time (round 3 #5): between its time and the tick it still waits.
  if (meta.deliveredAt !== undefined) return meta.deliveredAt === null;
  return new Date(meta.scheduledFor).getTime() > now.getTime();
}

/**
 * Who sees a comment: everyone once it is sent; while it waits, only the
 * person who wrote it. (No job publishes it — the moment passing is enough.)
 */
export function visibleTo(comment: Pick<TaskComment, "authorUserId">, meta: CommentMeta | undefined, viewerId: string, now: Date = new Date()): boolean {
  return !isPending(meta, now) || comment.authorUserId === viewerId;
}

/**
 * Threads: the top-level comments (in order) and each one's replies (in
 * order). A reply whose parent is missing — deleted, or not visible — is
 * shown at the top level rather than lost.
 */
export function threadComments<C extends { id: string }>(comments: C[], meta: Record<string, CommentMeta>): { top: C[]; replies: Map<string, C[]> } {
  const ids = new Set(comments.map((c) => c.id));
  const top: C[] = [];
  const replies = new Map<string, C[]>();
  for (const c of comments) {
    const parent = meta[c.id]?.parentId ?? null;
    if (parent && ids.has(parent)) {
      const list = replies.get(parent) ?? [];
      list.push(c);
      replies.set(parent, list);
    } else {
      top.push(c);
    }
  }
  return { top, replies };
}
