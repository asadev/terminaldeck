/**
 * Copied from the reference CRM: the shapes its task page's "more" read and
 * description history answer with. Only the types; the local answers come from
 * `src/main/tasks/task-detail-local.ts`.
 */
import type { LabelColor } from "./task-more";

export type TaskMore = {
  followers: { userId: string; since: string | null }[];
  /** Does the caller hear everything on this task? */
  iFollow: boolean;
  /** The caller's own waiting reminders on this task. */
  reminders: { id: string; remindAt: string; note: string | null }[];
  archivedAt: string | null;
  startTime: string | null;
  dueTime: string | null;
  syncSubtaskDates: boolean;
  /** Tag colours, by lower-case tag name. */
  labelColors: Record<string, LabelColor>;
  /** Each time entry's tags, by entry id. */
  entryTags: Record<string, string[]>;
  /** "Remind me" is offered only once something delivers reminders. */
  remindersLive: boolean;
  /** May change a tag's colour. Absent = no. */
  canColorTags?: boolean;
  /** May take other people off the followers. Absent = no. */
  canRemoveFollowers?: boolean;
};

export type DescriptionVersion = { at: string; by: string | null; from: string | null; to: string | null };
