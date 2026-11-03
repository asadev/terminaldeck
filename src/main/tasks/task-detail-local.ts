/**
 * The task popup's storage for your own tasks: the reference CRM's task page,
 * answered on this computer.
 *
 * ## One call per CRM function
 *
 * The popup is the CRM's task page, copied. Every read and write it makes is a
 * function of the CRM's `DetailActions` (and `TaskFieldActions` for custom
 * fields); the window sends each one here by name on one channel
 * (`src/shared/crm/detail-contract.ts`), and {@link LocalTaskDetail.call}
 * answers with the CRM function's own result shape — `{ ok: true, … }` or
 * `{ ok: false, error }` with a sentence a person can act on. The rules are the
 * CRM's (title lengths, one running timer, no time on a day that has not come,
 * one-level reply threads, the custom-field normalisers); the storage is the
 * local task record.
 *
 * ## Where it is kept
 *
 * On the task itself, as `TaskRecord.detail`: subtasks, checklists,
 * dependencies, attachments, custom fields, comments, the Activity lines this
 * file writes, time entries, followers, reminders and the routine. Files are
 * copied into `<userData>/remote/task-files/<task>/`. Tag colours belong to a
 * tag everywhere, so they sit in one small file beside the task records.
 *
 * ## The task row goes through LocalTasks
 *
 * Status, title, details, dates, priority, tags, board, type, estimate,
 * archive and the main assignee change only through `LocalTasks.update`, so its
 * checks and the engine's rules hold: giving the task to an agent starts that
 * agent, and its refusals ("Choose the project folder…") come back here as the
 * CRM's `{ ok: false, error }`. `LocalTasks` tells this file what each update
 * changed ({@link LocalTaskDetail.noteUpdate}), which becomes the CRM's
 * from → to line in Activity — whether the change came from the popup or the
 * list.
 *
 * ## People
 *
 * The CRM's people are its team. A local task's are you, Hoot and your task
 * agents (`localPeople`). The main assignee is the local task's own assignee;
 * anyone else put on the task is kept as a list and runs nothing.
 *
 * ## What happens on its own
 *
 * Three things come due with time, and {@link LocalTaskDetail.runDue} does
 * them when the task clock (`task-clock.ts`) says one has: a routine "On a
 * schedule" makes its next one, a reminder is delivered (`deps.notify`; none
 * wired, and "Remind me" is not offered), and a scheduled comment goes out. A
 * routine "On status change" makes its next one when the status changes —
 * from the popup, the list or an agent ({@link LocalTaskDetail.noteStatus}).
 * The rules are the reference CRM's routine engine, on one computer: the
 * history (`occurrences`) is the idempotency key, a date already made is never
 * made twice, "after N times" counts the dates made, a schedule that slept
 * makes only the latest date and records the ones between as skipped.
 *
 * ## Only you
 *
 * Nobody else sees a task on this computer, so there are no followers to add
 * or a task to unfollow, and no link to share: those refuse in words.
 */

import { randomUUID } from 'node:crypto'
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmdirSync, statSync, unlinkSync, writeFileSync } from 'node:fs'
import { basename, dirname, join } from 'node:path'
import { checkUpload, fileExtension, inlineKind } from '../../shared/crm/attachment-rules'
import { DEPENDENCY_KINDS, type DependencyKind, type TaskAttachment, type TaskChecklist, type TaskDependency, type TaskPeople, type TaskSubtaskRow } from '../../shared/crm/collab-types'
import { HOOT_ID, ME_ID, localPeople, localPerson, type LocalDetailFn, type LocalUpload } from '../../shared/crm/detail-contract'
import { stripFileTokens, truncateVisible, VISIBLE_TITLE_MAX } from '../../shared/crm/inline-files'
import { localInstantAt, localToday } from '../../shared/crm/local-time'
import { isTaskRecurrence, type TaskRecurrence } from '../../shared/crm/recurrence'
import {
  addDays,
  daysBetween,
  dueScheduleDates,
  isActive,
  isPastEnd,
  legacyRecurrence,
  localInstant,
  nextAfter,
  nextDateOnDone,
  nextMovesWithDue,
  normalizeRoutine,
  routineAnchor,
  routineRefusal,
  routineSummary,
  ruleFromLegacy,
  shortDay,
  upcoming,
  type OccurrenceRow,
  type RoutineRule,
} from '../../shared/crm/recurrence-rules'
import type { RoutineView } from '../../shared/crm/routine-actions'
import type { TagHit } from '../../shared/crm/tag-areas'
import type { ActivityKind, ActivityReadPayload, TaskActivityRow } from '../../shared/crm/task-activity'
import { isReactionEmoji, REACTION_EMOJI, type CommentExtras, type CommentMeta, type CommentReaction } from '../../shared/crm/task-comments'
import {
  feedValue,
  formatFieldValue,
  formulaRefs,
  isActionOnlyKind,
  isComputedKind,
  isFieldKind,
  normaliseConfig,
  normaliseFieldLabel,
  normaliseValue,
  reconcileValue,
  renameFormulaRefs,
  sameLabel,
  sortFields,
  type AutoProgress,
  type FieldKind,
  type FileRef,
  type TaskField,
  type TaskRef,
} from '../../shared/crm/task-fields'
import { LABEL_COLORS, type LabelColor } from '../../shared/crm/task-more'
import type { DescriptionVersion, TaskMore } from '../../shared/crm/task-more-actions'
import { isTaskType, MAX_LABELS, normalizeLabels, normalizeRecurrenceRule, type RecurrenceRule, type SubtaskMeta, type TaskPageExtras, type TimeEntry } from '../../shared/crm/task-page'
import type { TaskAssignee, TaskComment, TaskPriority } from '../../shared/crm/tasks-data'
import { writeSecretFile } from '../remote/secret-file'
import { actorNow, appActorName } from './task-actor'
import { TaskConfigProblem, type TaskConfig } from './task-config'
import type { LocalChange, LocalTasks } from './task-local'
import { PRIORITIES, type TaskNote, type TaskRecord, type TaskStore } from './task-store'

/* ------------------------------------------------------------- stored -- */

interface StoredSubtask {
  id: string
  title: string
  done: boolean
  sortOrder: number
  assigneeUserId: string | null
  priority: TaskPriority | null
  dueDate: string | null
}

interface StoredItem {
  id: string
  title: string
  done: boolean
  sortOrder: number
  assigneeUserId: string | null
}

interface StoredChecklist {
  id: string
  title: string
  sortOrder: number
  items: StoredItem[]
}

interface StoredDependency {
  kind: DependencyKind
  otherTaskId: string
  at: number
}

interface StoredAttachment {
  id: string
  /** `upload`: copied here. `document`: a pointer at a file already attached to another of your tasks. */
  kind: 'upload' | 'document'
  fileName: string
  mimeType: string | null
  sizeBytes: number | null
  /** The file, relative to the files folder; a pointer carries its source's. */
  file: string | null
  /** A pointer's source: `<task id>/<attachment id>`. */
  documentId: string | null
  uploadedBy: string
  at: number
}

interface StoredComment {
  id: string
  authorUserId: string
  body: string
  at: number
}

interface StoredActivity {
  id: string
  kind: ActivityKind
  payload: ActivityReadPayload
  by: string
  at: number
}

interface StoredTimeEntry extends TimeEntry {
  tags: string[]
}

/** One date of a routine, kept on the routine's own task — the CRM's occurrence row. */
interface StoredOccurrence {
  id: string
  date: string
  dueDate: string | null
  /** Whose copy it is (one copy per person); null: the whole task. */
  person: string | null
  /** The task that stands for this date; null for a date recorded as skipped. */
  taskId: string | null
  status: OccurrenceRow['status']
  completedAt: string | null
  completedBy: string | null
}

/** A reminder; `sentAt` set once it went (or was given up on, with `lastError` saying why). */
interface StoredReminder {
  id: string
  remindAt: string
  note: string | null
  sentAt?: string | null
  attempts?: number
  lastError?: string | null
  /** After a failed delivery: not before then. */
  retryAt?: number | null
}

/** Everything the popup adds to one local task, kept on `TaskRecord.detail`. */
export interface LocalTaskDetailData {
  v: 1
  /** Everyone on the task besides its main assignee — kept, never run. */
  people: string[]
  subtasks: StoredSubtask[]
  checklists: StoredChecklist[]
  /** One row per link, on the task it was made from; the other task shows the mirror. */
  dependencies: StoredDependency[]
  attachments: StoredAttachment[]
  fields: TaskField[]
  comments: StoredComment[]
  /** By comment id — the stored ones and those read from an agent's notes alike. */
  commentMeta: Record<string, CommentMeta>
  reactions: Record<string, CommentReaction[]>
  /** The Activity lines this file writes, newest last. */
  activity: StoredActivity[]
  /** The notes an Activity line already tells, so they are not told twice. */
  covered: string[]
  time: StoredTimeEntry[]
  followers: Record<string, { following: boolean; since: string }>
  reminders: StoredReminder[]
  syncSubtaskDates: boolean
  routine: RoutineRule | null
  routineVersion: number
  recurrenceRule: RecurrenceRule | null
  /** On a routine's own task: its dates, oldest first. */
  occurrences: StoredOccurrence[]
  /** On a routine's own task: why its last next one was not made; null when it was. */
  routineError: { at: string; message: string } | null
  /** The next one this task brought, once made — finishing it again makes no second. */
  nextId: string | null
}

/** Most Activity lines kept on one task; the oldest go first. */
export const MAX_ACTIVITY = 500
/** Most comments kept on one task. */
export const MAX_COMMENTS = 1_000
/** The CRM's caps. */
const MAX_SUBTASK_TITLE = 300
const MAX_CHECKLIST_TITLE = 200
const MAX_CHECKLIST_ITEM_TITLE = 300
const MAX_COMMENT_BODY = 2_000
const MAX_FIELDS_PER_TASK = 100
const DAY_SECONDS = 86_400
const YEAR_MS = 366 * 86_400_000
/** Pictures up to this size travel to the window as a `data:` address for their chip. */
export const MAX_PREVIEW_BYTES = 4 * 1024 * 1024
/** The least a search needs, as the CRM's. */
export const MIN_SEARCH = 2

const LABEL_FILE = 'task-detail.json'

const NOT_FOUND = 'That task no longer exists.'
const RELATED_ONLY_IN_CRM = 'Related records live in a CRM; local tasks cannot link to them.'

type Fail = { ok: false; error: string }
type Ok = { ok: true }
const fail = (error: string): Fail => ({ ok: false, error })

/** Mime types by extension, for files that arrive with none. */
const MIME: Record<string, string> = {
  pdf: 'application/pdf',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  gif: 'image/gif',
  webp: 'image/webp',
  bmp: 'image/bmp',
  heic: 'image/heic',
  heif: 'image/heif',
  tif: 'image/tiff',
  tiff: 'image/tiff',
  txt: 'text/plain',
  md: 'text/markdown',
  csv: 'text/csv',
  rtf: 'application/rtf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  xls: 'application/vnd.ms-excel',
  xlsx: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ppt: 'application/vnd.ms-powerpoint',
  pptx: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  odt: 'application/vnd.oasis.opendocument.text',
  ods: 'application/vnd.oasis.opendocument.spreadsheet',
  odp: 'application/vnd.oasis.opendocument.presentation',
  mp3: 'audio/mpeg',
  m4a: 'audio/mp4',
  wav: 'audio/wav',
  ogg: 'audio/ogg',
  mp4: 'video/mp4',
  mov: 'video/quicktime',
  webm: 'video/webm',
  zip: 'application/zip',
}

/** The pictures the app's window can draw. */
const DRAWABLE = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/bmp'])

function mimeOf(name: string, given: string | null | undefined): string | null {
  if (given && given.trim() !== '') return given.trim().slice(0, 120)
  return MIME[fileExtension(name)] ?? null
}

/** A file name safe to put on disk: no folders, no control characters. */
function safeName(name: string): string {
  const base = basename(name).replace(/[^\w.\- ()]+/g, '_').trim()
  return (base === '' ? 'file' : base).slice(0, 120)
}

/** A short, stable fingerprint — for ids read from notes, which have none of their own. */
function hashOf(text: string): string {
  let h = 5381
  for (let i = 0; i < text.length; i++) h = ((h * 33) ^ text.charCodeAt(i)) >>> 0
  return h.toString(16)
}

/**
 * A uuid-shaped stand-in for a person's id. The CRM's custom-field rules
 * accept only uuids for people (its profile ids); yours are `me`, `hoot` and
 * your agents' ids, so they cross those rules under a fixed stand-in and come
 * back as themselves.
 */
function personAlias(id: string): string {
  const a = hashOf(`p1:${id}`).padStart(8, '0')
  const b = hashOf(`p2:${id}`).padStart(8, '0')
  return `00000000-0000-4000-8000-${(a + b).slice(0, 12)}`
}

function emptyDetail(): LocalTaskDetailData {
  return {
    v: 1,
    people: [],
    subtasks: [],
    checklists: [],
    dependencies: [],
    attachments: [],
    fields: [],
    comments: [],
    commentMeta: {},
    reactions: {},
    activity: [],
    covered: [],
    time: [],
    followers: {},
    reminders: [],
    syncSubtaskDates: false,
    routine: null,
    routineVersion: 0,
    recurrenceRule: null,
    occurrences: [],
    routineError: null,
    nextId: null,
  }
}

const EMPTY_META: CommentMeta = { parentId: null, resolvedAt: null, resolvedBy: null, assigneeUserId: null, scheduledFor: null }

/** The note kinds an agent's output arrives as — shown as its comments, as the CRM shows an agent's. */
const COMMENT_NOTES: ReadonlySet<TaskNote['kind']> = new Set(['progress', 'question', 'blocker', 'completion'])

function noteKey(note: TaskNote): string {
  return `${note.at}|${note.kind}|${note.text}`
}

export interface LocalTaskDetailDeps {
  store: TaskStore
  config: TaskConfig
  local: Pick<LocalTasks, 'update' | 'create' | 'remove' | 'reply'>
  /** `<userData>/remote/task-files`; null keeps files nowhere and tag colours in memory (tests). */
  filesDir: string | null
  /** The Mac's file chooser: the paths picked, none when cancelled. */
  chooseFiles(): Promise<string[]>
  /** The Mac's folder chooser: the folder picked, null when cancelled. */
  chooseFolder(): Promise<string | null>
  /** Open a file in the Mac's own app for it: '' when it opened, else what went wrong (Electron's `shell.openPath`). */
  openPath(path: string): Promise<string>
  /**
   * Deliver a reminder to you. Absent: nothing on this computer delivers one,
   * and "Remind me" is not offered.
   */
  notify?(reminder: ReminderNotice): Promise<ReminderDelivery>
  now?: () => number
  onChange?(): void
}

/** What a reminder says when it is delivered. */
export interface ReminderNotice {
  taskId: string
  title: string
  body: string
}

/**
 * What delivering one did: it went; it cannot go and never will (`retry:
 * false` — notifications switched off for the app); or it failed this time.
 */
export type ReminderDelivery = { delivered: true } | { delivered: false; reason: string; retry: boolean }

/** A reminder that failed is tried again this many times in all, then given up on with the reason kept (the CRM's five). */
export const REMINDER_ATTEMPTS = 5
/** How long after a failed delivery it is tried again, times the attempts so far. */
export const REMINDER_RETRY_MS = 60_000
/** Done finishes a task whatever a routine's trigger is (the CRM's `isFinishedFor`). */
const DONE = 'Done'

/** The functions that only read — everything else redraws the Tasks page when it succeeds. */
const READS: ReadonlySet<LocalDetailFn> = new Set<LocalDetailFn>([
  'fetchTaskDetailBundle',
  'listTaskComments',
  'listTaskActivity',
  'fetchTaskPageExtras',
  'fetchRoutine',
  'fetchTaskMore',
  'fetchDescriptionHistory',
  'fetchCommentExtras',
  'listTaskFields',
  'searchTags',
  'openTaskFile',
])

export class LocalTaskDetail {
  private readonly now: () => number
  private labelColors: Record<string, LabelColor> = {}

  constructor(private readonly deps: LocalTaskDetailDeps) {
    this.now = deps.now ?? Date.now
    this.loadLabels()
  }

  /* ------------------------------------------------------------ the door -- */

  /** One call from the popup: the CRM function's name and arguments, answered with its own result shape. */
  async call(fn: LocalDetailFn, args: unknown[]): Promise<unknown> {
    let result: unknown
    try {
      result = await this.dispatch(fn, args)
    } catch (error) {
      if (error instanceof TaskConfigProblem) return fail(error.message)
      console.error('[tasks] the task popup call failed:', fn, error)
      return fail(`That did not save: ${error instanceof Error ? error.message : String(error)}`)
    }
    if (!READS.has(fn) && typeof result === 'object' && result !== null && (result as { ok?: unknown }).ok === true) {
      try {
        this.deps.onChange?.()
      } catch (error) {
        console.error('[tasks] a change listener threw:', error)
      }
    }
    return result
  }

  private dispatch(fn: LocalDetailFn, a: unknown[]): unknown {
    const s = (i: number): string => {
      const v = a[i]
      if (typeof v !== 'string') throw new TaskConfigProblem('That request was not understood.')
      return v
    }
    const ns = (i: number): string | null => (a[i] === null || a[i] === undefined ? null : s(i))
    const b = (i: number): boolean => a[i] === true
    const o = (i: number): Record<string, unknown> => (typeof a[i] === 'object' && a[i] !== null ? (a[i] as Record<string, unknown>) : {})
    switch (fn) {
      case 'fetchTaskDetailBundle':
        return this.fetchTaskDetailBundle(s(0))
      case 'listTaskComments':
        return this.listTaskComments(s(0))
      case 'listTaskActivity':
        return this.listTaskActivity(s(0))
      case 'setTaskStatus':
        return this.setTaskStatus(s(0), s(1))
      case 'updateTask':
        return this.updateTask(s(0), o(1))
      case 'assignTask':
        return this.assignTask(s(0), s(1))
      case 'addTaskAssignee':
        return this.addTaskAssignee(s(0), s(1))
      case 'removeTaskAssignee':
        return this.removeTaskAssignee(s(0), s(1))
      case 'addTaskSubtask':
        return this.addTaskSubtask(s(0), a[1])
      case 'setTaskSubtaskDone':
        return this.setTaskSubtaskDone(s(0), s(1), b(2))
      case 'deleteTaskSubtask':
        return this.deleteTaskSubtask(s(0), s(1))
      case 'setTaskSubtaskAssignee':
        return this.setTaskSubtaskAssignee(s(0), s(1), ns(2))
      case 'addChecklist':
        return this.addChecklist(s(0), a[1])
      case 'renameChecklist':
        return this.renameChecklist(s(0), a[1])
      case 'deleteChecklist':
        return this.deleteChecklist(s(0))
      case 'addChecklistItem':
        return this.addChecklistItem(s(0), a[1])
      case 'setChecklistItemDone':
        return this.setChecklistItemDone(s(0), b(1))
      case 'setChecklistItemAssignee':
        return this.setChecklistItemAssignee(s(0), ns(1))
      case 'deleteChecklistItem':
        return this.deleteChecklistItem(s(0))
      case 'addTaskDependency':
        return this.addTaskDependency(s(0), s(1), a[2])
      case 'removeTaskDependency':
        return this.removeTaskDependency(s(0), s(1), a[2])
      case 'attachExistingDocument':
        return this.attachExistingDocument(s(0), s(1))
      case 'detachTaskAttachment':
        return this.detachTaskAttachment(s(0))
      case 'uploadTaskFile':
        return this.uploadTaskFile(s(0), a[1])
      case 'addTaskComment':
        return this.addTaskCommentWith(s(0), a[1], {})
      case 'fetchTaskPageExtras':
        return this.fetchTaskPageExtras(s(0))
      case 'setTaskType':
        return this.setTaskType(s(0), a[1])
      case 'setTaskLabels':
        return this.setTaskLabels(s(0), a[1])
      case 'setTaskLinks':
        return fail(RELATED_ONLY_IN_CRM)
      case 'moveTask':
        return this.moveTask(s(0), a[1])
      case 'setTimeEstimate':
        return this.setTimeEstimate(s(0), a[1])
      case 'setTaskRecurrence':
        return this.setTaskRecurrence(s(0), a[1], a[2])
      case 'setSubtaskMeta':
        return this.setSubtaskMeta(s(0), s(1), o(2))
      case 'startTaskTimer':
        return this.startTaskTimer(s(0))
      case 'stopTaskTimer':
        return this.stopTaskTimer(s(0))
      case 'addTaskTimeEntry':
        return this.addTaskTimeEntry(s(0), o(1))
      case 'deleteTaskTimeEntry':
        return this.deleteTaskTimeEntry(s(0), s(1))
      case 'duplicateTask':
        return this.duplicateTask(s(0))
      case 'fetchRoutine':
        return this.fetchRoutine(s(0))
      case 'saveRoutine':
        return this.saveRoutine(s(0), a[1], a[2])
      case 'stopRoutine':
        return this.stopRoutine(s(0))
      case 'pauseRoutine':
        return this.pauseRoutine(s(0), b(1))
      case 'restartRoutine':
        return this.restartRoutine(s(0))
      case 'fetchTaskMore':
        return this.fetchTaskMore(s(0))
      case 'setFollowing':
      case 'addFollower':
      case 'removeFollower':
        return this.notFollowable()
      case 'setReminder':
        return this.setReminder(s(0), a[1], a[2])
      case 'clearReminder':
        return this.clearReminder(s(0), s(1))
      case 'setArchived':
        return this.setArchived(s(0), b(1))
      case 'mergeTaskInto':
        return this.mergeTaskInto(s(0), s(1))
      case 'convertToSubtask':
        return this.convertToSubtask(s(0), s(1))
      case 'setSyncSubtaskDates':
        return this.setSyncSubtaskDates(s(0), b(1))
      case 'setTaskTimes':
        return this.setTaskTimes(s(0), o(1))
      case 'setLabelColor':
        return this.setLabelColor(a[0], a[1])
      case 'deleteLabelEverywhere':
        return this.deleteLabelEverywhere(a[0])
      case 'setTimeEntryTags':
        return this.setTimeEntryTags(s(0), s(1), a[2])
      case 'fetchDescriptionHistory':
        return this.fetchDescriptionHistory(s(0))
      case 'fetchCommentExtras':
        return this.fetchCommentExtras(s(0))
      case 'addTaskCommentWith':
        return this.addTaskCommentWith(s(0), a[1], o(2))
      case 'toggleCommentReaction':
        return this.toggleCommentReaction(s(0), s(1), a[2])
      case 'setCommentResolved':
        return this.setCommentResolved(s(0), s(1), b(2))
      case 'assignComment':
        return this.assignComment(s(0), s(1), ns(2))
      case 'sendScheduledNow':
        return this.sendScheduledNow(s(0), s(1))
      case 'listTaskFields':
        return this.listTaskFields(s(0))
      case 'createTaskField':
        return this.createTaskField(s(0), o(1))
      case 'updateTaskFieldValue':
        return this.updateTaskFieldValue(s(0), a[1])
      case 'renameTaskField':
        return this.renameTaskField(s(0), a[1])
      case 'updateTaskFieldConfig':
        return this.updateTaskFieldConfig(s(0), a[1])
      case 'reorderTaskFields':
        return this.reorderTaskFields(s(0), a[1])
      case 'deleteTaskField':
        return this.deleteTaskField(s(0))
      case 'toggleTaskFieldVote':
        return this.toggleTaskFieldVote(s(0))
      case 'pressTaskFieldButton':
        return this.pressTaskFieldButton(s(0))
      case 'chooseTaskFiles':
        return this.chooseTaskFiles(s(0))
      case 'openTaskFile':
        return this.openTaskFile(s(0), s(1))
      case 'searchTags':
        return this.searchTags(s(0), typeof a[1] === 'string' ? a[1] : '')
      case 'setTaskProject':
        return this.setTaskProject(s(0), a[1])
      case 'chooseTaskProject':
        return this.chooseTaskProject(s(0))
    }
  }

  /* ------------------------------------------------------------ helpers -- */

  private task(id: string): TaskRecord {
    const task = this.deps.store.byId(id)
    if (task === null || task.local !== true) throw new TaskConfigProblem(NOT_FOUND)
    return task
  }

  private locals(): TaskRecord[] {
    return this.deps.store.all().filter((task) => task.local === true)
  }

  /** The task's detail, with every part present — records from before a part existed read as empty. */
  private detail(task: TaskRecord): LocalTaskDetailData {
    if (task.detail === undefined) task.detail = emptyDetail()
    // Filled in place, so every caller in one call works on the same object.
    const stored = task.detail as unknown as Record<string, unknown>
    const fresh = emptyDetail() as unknown as Record<string, unknown>
    for (const key of Object.keys(fresh)) if (stored[key] === undefined) stored[key] = fresh[key]
    return task.detail
  }

  private save(task: TaskRecord): void {
    const d = this.detail(task)
    if (d.activity.length > MAX_ACTIVITY) d.activity = d.activity.slice(-MAX_ACTIVITY)
    if (d.covered.length > 200) d.covered = d.covered.slice(-200)
    this.deps.store.update(task, { detail: d })
  }

  private iso(at: number = this.now()): string {
    return new Date(at).toISOString()
  }

  private people(): TaskAssignee[] {
    // Archived agents are not offered; one already on a task is still named by its record.
    return localPeople(this.deps.config.pickableAgents())
  }

  private person(id: string | null | undefined): TaskAssignee | null {
    if (!id || id === 'none') return null
    return this.people().find((p) => p.id === id) ?? null
  }

  /** A person by id; one no longer known (a removed agent) is still named by its id. */
  private named(id: string): TaskAssignee {
    return this.person(id) ?? localPerson(id, appActorName(id) ?? id)
  }

  private requirePerson(id: string): TaskAssignee {
    const p = this.person(id)
    if (p === null) throw new TaskConfigProblem('That person is not one of yours: you, Hoot or one of your task agents.')
    return p
  }

  private record(task: TaskRecord, kind: ActivityKind, payload: ActivityReadPayload, by: string = actorNow()): void {
    const d = this.detail(task)
    d.activity.push({ id: randomUUID(), kind, payload, by, at: this.now() })
  }

  /** Run a LocalTasks update; its refusal comes back as the CRM's `{ ok: false, error }`. */
  private async update(task: TaskRecord, patch: Record<string, unknown>): Promise<Ok | Fail> {
    try {
      await this.deps.local.update(task.id, patch)
      return { ok: true }
    } catch (error) {
      if (error instanceof TaskConfigProblem) return fail(error.message)
      throw error
    }
  }

  /** Put someone on the task when a sub-item names them — the CRM's own "joins the task" rule. */
  private join(task: TaskRecord, userId: string): void {
    if (userId === task.assignee.identity) return
    const d = this.detail(task)
    if (!d.people.includes(userId)) d.people.push(userId)
  }

  /* -------------------------------------------------------------- people -- */

  private peopleOf(task: TaskRecord): TaskPeople {
    const primary = task.assignee.kind === 'none' ? null : this.named(task.assignee.identity)
    const others = this.detail(task)
      .people.filter((id) => id !== primary?.id)
      .map((id) => this.named(id))
    return { primary, others }
  }

  private async assignTask(taskId: string, userId: string): Promise<Ok | Fail> {
    const task = this.task(taskId)
    if (userId !== 'none') this.requirePerson(userId)
    const r = await this.update(task, { assignee: userId })
    if (!r.ok) return r
    // The one put on as the main person is no longer one of the others.
    const d = this.detail(task)
    if (d.people.includes(userId)) {
      d.people = d.people.filter((id) => id !== userId)
      this.save(task)
    }
    return r
  }

  private addTaskAssignee(taskId: string, userId: string): Ok | Fail {
    const task = this.task(taskId)
    const who = this.requirePerson(userId)
    const d = this.detail(task)
    if (userId === task.assignee.identity || d.people.includes(userId)) return { ok: true }
    d.people.push(userId)
    this.record(task, 'assigned', { user_id: userId, name: who.name, primary: false })
    this.save(task)
    return { ok: true }
  }

  private removeTaskAssignee(taskId: string, userId: string): Ok | Fail {
    const task = this.task(taskId)
    const d = this.detail(task)
    if (!d.people.includes(userId)) return fail('That person is not on this task.')
    d.people = d.people.filter((id) => id !== userId)
    this.record(task, 'unassigned', { user_id: userId })
    this.save(task)
    return { ok: true }
  }

  /* -------------------------------------------------------- the bundle -- */

  private fetchTaskDetailBundle(taskId: string): { ok: true; bundle: { people: TaskPeople; subtasks: TaskSubtaskRow[]; checklists: TaskChecklist[]; dependencies: TaskDependency[]; attachments: TaskAttachment[] } } {
    const task = this.task(taskId)
    const d = this.detail(task)
    return {
      ok: true,
      bundle: {
        people: this.peopleOf(task),
        subtasks: [...d.subtasks]
          .sort((x, y) => x.sortOrder - y.sortOrder)
          .map((s) => ({ id: s.id, title: s.title, done: s.done, sortOrder: s.sortOrder, assigneeUserId: s.assigneeUserId })),
        checklists: [...d.checklists]
          .sort((x, y) => x.sortOrder - y.sortOrder)
          .map((l) => ({
            id: l.id,
            title: l.title,
            sortOrder: l.sortOrder,
            items: [...l.items].sort((x, y) => x.sortOrder - y.sortOrder).map((i) => ({ ...i })),
          })),
        dependencies: this.dependenciesOf(task),
        attachments: d.attachments.map((a) => this.attachmentView(a)),
      },
    }
  }

  /* --------------------------------------------------------- the row -- */

  private async setTaskStatus(taskId: string, status: string): Promise<Ok | Fail> {
    return this.update(this.task(taskId), { status })
  }

  private async updateTask(taskId: string, patch: Record<string, unknown>): Promise<Ok | Fail> {
    const task = this.task(taskId)
    const change: Record<string, unknown> = {}
    if (typeof patch.title === 'string') change.title = patch.title
    if ('priority' in patch) change.priority = patch.priority ?? null
    if (typeof patch.description === 'string') change.instructions = patch.description
    for (const key of ['startDate', 'dueDate'] as const) {
      if (typeof patch[key] === 'string') change[key] = patch[key] === '' ? null : patch[key]
    }
    // A date cleared takes its time with it, as the CRM's one date writer does.
    if (change.startDate === null && task.startTime) change.startTime = null
    if (change.dueDate === null && task.dueTime) change.dueTime = null
    const hasRecurrence = 'recurrence' in patch
    if (Object.keys(change).length === 0 && !hasRecurrence) return fail('Nothing to update')
    if (Object.keys(change).length > 0) {
      const r = await this.update(task, change)
      if (!r.ok) return r
    }
    if (hasRecurrence) {
      const r = this.setTaskRecurrence(taskId, patch.recurrence ?? null, null)
      if (!r.ok) return r
    }
    return { ok: true }
  }

  /**
   * What `LocalTasks.update` changed, told as the CRM's Activity lines — the
   * same line whether the popup or the list made the change — and the notes it
   * wrote for them marked as told.
   */
  noteUpdate(task: TaskRecord, changes: LocalChange[], notes: TaskNote[]): void {
    if (task.local !== true) return
    const d = this.detail(task)
    const str = (v: unknown): string | null => (typeof v === 'string' && v !== '' ? v : null)
    const dates: ActivityReadPayload = {}
    for (const c of changes) {
      switch (c.field) {
        case 'title':
          this.record(task, 'title', { from: str(c.from), to: str(c.to) })
          break
        case 'instructions':
          this.record(task, 'description', { from: str(c.from), to: str(c.to) })
          break
        case 'project':
          this.record(task, 'field', { action: 'changed', label: 'Project folder', from: str(c.from), to: str(c.to) })
          break
        case 'status':
          this.record(task, 'status', { from: str(c.from), to: str(c.to) })
          break
        case 'archived':
          this.record(task, 'archived', { on: c.to === true })
          break
        case 'assignee': {
          const to = str(c.to)
          if (to === null || to === 'none') this.record(task, 'unassigned', { user_id: str(c.from) })
          else this.record(task, 'assigned', { user_id: to, name: this.named(to).name, primary: true })
          break
        }
        case 'priority':
          this.record(task, 'priority', { from: str(c.from), to: str(c.to) })
          break
        case 'startDate':
          Object.assign(dates, { start_from: str(c.from), start_to: str(c.to) })
          break
        case 'dueDate':
          Object.assign(dates, { due_from: str(c.from), due_to: str(c.to) })
          break
        case 'startTime':
          Object.assign(dates, { start_time_from: str(c.from), start_time_to: str(c.to) })
          break
        case 'dueTime':
          Object.assign(dates, { due_time_from: str(c.from), due_time_to: str(c.to) })
          break
        case 'labels': {
          const was = Array.isArray(c.from) ? (c.from as string[]) : []
          const now = Array.isArray(c.to) ? (c.to as string[]) : []
          const low = (xs: string[]) => new Set(xs.map((x) => x.toLowerCase()))
          const had = low(was)
          const has = low(now)
          for (const t of now) if (!had.has(t.toLowerCase())) this.record(task, 'tags', { added: t, removed: null })
          for (const t of was) if (!has.has(t.toLowerCase())) this.record(task, 'tags', { added: null, removed: t })
          break
        }
        case 'board':
          this.record(task, 'moved', { from: str(c.from), to: str(c.to) ?? '' })
          break
        case 'taskType':
          this.record(task, 'task_type', { from: str(c.from), to: str(c.to) })
          break
        case 'estimateMinutes':
          this.record(task, 'estimate', { from: typeof c.from === 'number' ? c.from : null, to: typeof c.to === 'number' ? c.to : null })
          break
      }
    }
    if (Object.keys(dates).length > 0) this.record(task, 'dates', dates)
    for (const note of notes) d.covered.push(noteKey(note))
    this.save(task)
    if (changes.some((c) => c.field === 'status')) this.noteStatus(task.id)
  }

  /* ------------------------------------------------- the routine engine -- */

  /** Work the engine queued — a next one being made — in order, one at a time. */
  private work: Promise<void> = Promise.resolve()

  /**
   * A local task's status changed — from the popup, the list, or an agent
   * finishing it. Its routine's history notes it, and when it reached the
   * routine's trigger status the next one is made (the CRM's
   * `spawnNextOccurrence`). Queued: it runs after the change has been saved.
   */
  noteStatus(taskId: string): void {
    this.queue(() => this.afterStatus(taskId, false))
  }

  /** Everything the engine queued has run — work queued meanwhile too. For tests. */
  async settled(): Promise<void> {
    let seen: Promise<void>
    do {
      seen = this.work
      await seen
    } while (seen !== this.work)
  }

  private queue(run: () => Promise<unknown>): Promise<void> {
    const next = this.work.then(run).then(
      () => undefined,
      (error) => console.error('[tasks] the routine engine failed:', error),
    )
    this.work = next
    return next
  }

  /** A routine's own task and its rule. A copy whose own task is gone: the routine is over. */
  private resolveRoutine(task: TaskRecord): { root: TaskRecord; rule: RoutineRule | null } {
    const own = task.detail?.routine ?? null
    if (own?.rootTaskId && own.rootTaskId !== task.id) {
      const root = this.deps.store.byId(own.rootTaskId)
      if (root !== null && root.local === true) return { root, rule: root.detail?.routine ?? null }
      return { root: task, rule: { ...own, rootTaskId: null, stoppedAt: own.stoppedAt ?? this.iso() } }
    }
    return { root: task, rule: own ? { ...own, rootTaskId: null } : null }
  }

  /** Newest date first, as the CRM reads its history. */
  private history(root: TaskRecord): StoredOccurrence[] {
    return [...this.detail(root).occurrences].sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0))
  }

  /** "After N times" counts the dates made — one a day however many copies; a skipped date is not one. */
  private datesSoFar(root: TaskRecord): number {
    return new Set(this.detail(root).occurrences.filter((r) => r.status !== 'skipped').map((r) => r.date)).size
  }

  private isFinishedFor(rule: RoutineRule | null, status: string): boolean {
    return status === DONE || (rule !== null && rule.trigger === 'status' && status === rule.triggerStatus)
  }

  /** The task's own date in the history: done when it is finished, open again when it is not (the CRM's `recordCompletion`). */
  private recordCompletion(root: TaskRecord, task: TaskRecord, rule: RoutineRule): void {
    const row = this.history(root).find((r) => r.taskId === task.id)
    if (row === undefined) return
    const complete = this.isFinishedFor(rule, task.crmStatus)
    if (complete && (row.status === 'open' || row.status === 'missed')) {
      row.status = 'done'
      row.completedAt = this.iso(task.completedAt ?? this.now())
      row.completedBy = actorNow()
    } else if (!complete && row.status === 'done') {
      row.status = 'open'
      row.completedAt = null
      row.completedBy = null
    } else return
    this.save(root)
  }

  private setRoutineError(root: TaskRecord, message: string | null): void {
    const d = this.detail(root)
    if (message === null && d.routineError === null) return
    d.routineError = message === null ? null : { at: this.iso(), message }
    this.save(root)
  }

  private today(): string {
    return localToday(new Date(this.now()))
  }

  /** The start date a next one keeps: as far before its due date as this one's was (the CRM's `withLead`). */
  private withLead(startDate: string | null | undefined, dueDate: string | null | undefined, nextDue: string): string | null {
    if (!startDate) return null
    const lead = dueDate ? Math.max(0, daysBetween(startDate, dueDate)) : 0
    return addDays(nextDue, -lead)
  }

  /** Everyone on the routine's own task: its main assignee and the others. */
  private everyoneOn(root: TaskRecord): string[] {
    const out = root.assignee.kind === 'none' ? [] : [root.assignee.identity]
    for (const id of this.detail(root).people) if (!out.includes(id)) out.push(id)
    return out
  }

  /**
   * The routine's task comes back with the next dates. Its status change is
   * seen like any other (`noteStatus`) and is never a finish: a next one
   * always starts in an open status (`routineRefusal`), and one that starts in
   * the trigger status is already in it, so nothing changes.
   */
  private async bringBack(task: TaskRecord, rule: RoutineRule, date: string, startDate: string | null): Promise<string | null> {
    try {
      await this.deps.local.update(task.id, { status: rule.updateStatusTo, startDate, dueDate: date })
      return null
    } catch (error) {
      return error instanceof Error ? error.message : String(error)
    }
  }

  /**
   * A new task for one date (the CRM's `createOccurrence`): the source's
   * title, details, folder, priority, tags and board, the routine's start
   * status, the date — and its working parts with every tick cleared. Its
   * history row is written first, so the date is never made twice.
   */
  private async makeCopy(root: TaskRecord, source: TaskRecord, rule: RoutineRule, date: string, startDate: string | null, person: string | null): Promise<{ id: string } | { error: string }> {
    const row: StoredOccurrence = { id: randomUUID(), date, dueDate: date, person, taskId: null, status: 'open', completedAt: null, completedBy: null }
    this.detail(root).occurrences.push(row)
    this.save(root)
    const assignee = person ?? (source.assignee.kind === 'none' ? 'none' : source.assignee.identity)
    let copy: TaskRecord
    try {
      copy = await this.deps.local.create({
        title: source.title,
        instructions: source.instructions,
        project: source.project,
        assignee,
        status: rule.updateStatusTo,
        priority: source.priority ?? null,
        startDate,
        dueDate: date,
        labels: source.labels ?? [],
        board: source.board ?? null,
        taskType: source.taskType ?? 'task',
        estimateMinutes: source.estimateMinutes ?? null,
      })
    } catch (error) {
      // Taken back: the date is free for the next try.
      const d = this.detail(root)
      d.occurrences = d.occurrences.filter((r) => r.id !== row.id)
      this.save(root)
      return { error: error instanceof Error ? error.message : String(error) }
    }
    row.taskId = copy.id
    this.save(root)
    const from = this.detail(source)
    const into = this.detail(copy)
    into.routine = { ...rule, rootTaskId: root.id }
    if (person === null) into.people = from.people.filter((id) => id !== copy.assignee.identity)
    into.subtasks = from.subtasks.map((x) => ({ ...x, id: randomUUID(), done: false }))
    into.checklists = from.checklists.map((l) => ({ ...l, id: randomUUID(), items: l.items.map((i) => ({ ...i, id: randomUUID(), done: false })) }))
    this.deps.store.update(copy, { recurrence: root.recurrence ?? legacyRecurrence(rule) })
    this.save(copy)
    return { id: copy.id }
  }

  /**
   * ON STATUS CHANGE. The history first, then — when the task reached the
   * trigger status (or, restarting, is Done) and has brought no next one yet —
   * the next date: the task itself back (Create new task off) or a new task
   * for it, one per person with "each person gets their own". A copy that
   * could not be made is said on the routine and made on the next finish.
   */
  private async afterStatus(taskId: string, restart: boolean): Promise<void> {
    const task = this.deps.store.byId(taskId)
    if (task === null || task.local !== true) return
    const { root, rule } = this.resolveRoutine(task)
    if (rule === null) return
    this.recordCompletion(root, task, rule)
    if (!isActive(rule) || (root.recurrence ?? null) === null) return
    // An archived routine makes nothing — as if paused.
    if (root.archivedAt != null) return
    const triggered = task.crmStatus === rule.triggerStatus || (restart && task.crmStatus === DONE)
    if (rule.trigger !== 'status' || !triggered) return
    if (this.detail(task).nextId !== null) return
    const rows = this.history(root)
    const today = this.today()
    const oldest = rows.length > 0 ? rows[rows.length - 1].date : null
    const anchor = routineAnchor(rule, { rootDue: root.dueDate ?? null, oldest, taskDue: task.dueDate ?? null, today })
    const own = rows.find((r) => r.taskId === task.id && r.status !== 'skipped')
    const next = nextDateOnDone(rule, {
      anchor,
      occurrence: own?.date ?? null,
      due: task.dueDate ?? null,
      today,
      own: rows.filter((r) => r.taskId === task.id).map((r) => r.date),
    })
    const isNewDate = (date: string): boolean => !rows.some((r) => r.date === date && r.status !== 'skipped')
    const soFar = this.datesSoFar(root)
    const startDate = this.withLead(task.startDate, task.dueDate, next)

    if (!rule.createNew) {
      if (isPastEnd(rule, next, soFar - (isNewDate(next) ? 0 : 1))) return
      const row: StoredOccurrence = { id: randomUUID(), date: next, dueDate: next, person: null, taskId: task.id, status: 'open', completedAt: null, completedBy: null }
      this.detail(root).occurrences.push(row)
      this.save(root)
      const why = await this.bringBack(task, rule, next, startDate)
      if (why !== null) {
        const d = this.detail(root)
        d.occurrences = d.occurrences.filter((r) => r.id !== row.id)
        this.save(root)
        this.setRoutineError(root, `The next one (${shortDay(next)}) could not be made: ${why} Mark it done again to retry.`)
        return
      }
      this.setRoutineError(root, null)
      return
    }

    let persons: Array<string | null> = [null]
    if (rule.perAssignee && task.id === root.id) {
      const everyone = this.everyoneOn(root)
      if (everyone.length > 0) persons = everyone
    } else if (rule.perAssignee) {
      persons = [task.assignee.kind === 'none' ? null : task.assignee.identity]
    }
    const source = rule.perAssignee ? root : task
    const made: string[] = []
    const failed: string[] = []
    for (const person of persons) {
      if (isPastEnd(rule, next, soFar - (isNewDate(next) ? 0 : 1))) continue
      if (rows.some((r) => r.date === next && r.person === person && r.status !== 'skipped')) continue
      const r = await this.makeCopy(root, source, rule, next, startDate, person)
      if ('id' in r) made.push(r.id)
      else failed.push(`${person === null ? 'the task' : this.named(person).name}: ${r.error}`)
    }
    if (failed.length > 0) {
      // Not stamped: finishing it again makes only the missing ones.
      this.setRoutineError(root, `Not every copy was made (${failed.length} of ${persons.length}): ${failed.join('; ')} Mark it done again to retry — only the missing ones are made.`)
      return
    }
    if (made.length === 0) return
    this.detail(task).nextId = made[0]
    this.save(task)
    this.setRoutineError(root, null)
  }

  /** The routines "On a schedule" on this computer: their own tasks, with a running rule. */
  private scheduled(): Array<{ root: TaskRecord; rule: RoutineRule }> {
    const out: Array<{ root: TaskRecord; rule: RoutineRule }> = []
    for (const task of this.locals()) {
      const rule = task.detail?.routine ?? null
      if (rule === null || rule.rootTaskId || rule.trigger !== 'schedule' || !isActive(rule)) continue
      if ((task.recurrence ?? null) === null || task.archivedAt != null) continue
      out.push({ root: task, rule })
    }
    return out
  }

  private scheduleAnchor(root: TaskRecord, rule: RoutineRule, rows: StoredOccurrence[]): string {
    const oldest = rows.length > 0 ? rows[rows.length - 1].date : null
    return rule.anchor ?? oldest ?? root.dueDate ?? localToday(new Date(root.createdAt))
  }

  /** When a schedule's next date comes, on this computer's clock; null when it never will. */
  private nextScheduleAt(root: TaskRecord, rule: RoutineRule): number | null {
    const rows = this.history(root)
    const anchor = this.scheduleAnchor(root, rule, rows)
    if (rule.ends.type === 'count' && this.datesSoFar(root) >= rule.ends.count) return null
    const next = nextAfter(anchor, rule, rows[0]?.date ?? anchor)
    if (rule.ends.type === 'until' && next > rule.ends.until) return null
    return localInstant(next, rule.timeOfDay).getTime()
  }

  /**
   * ON A SCHEDULE (the CRM's `runOne`): the latest date whose time has come
   * is made — finished or not — and the dates between it and the last one
   * are recorded as skipped, never made. With "mark missed", the dates still
   * open before it are marked missed and their copies tagged Missed.
   */
  private async runSchedule(root: TaskRecord, rule: RoutineRule): Promise<void> {
    const rows = this.history(root)
    const anchor = this.scheduleAnchor(root, rule, rows)
    const { latest, gap } = dueScheduleDates(anchor, rows[0]?.date ?? anchor, rule, new Date(this.now()), this.datesSoFar(root))
    if (latest === null) return
    const d = this.detail(root)
    const has = (date: string, person: string | null): boolean => d.occurrences.some((r) => r.date === date && r.person === person && r.status !== 'skipped')
    for (const date of gap) {
      if (d.occurrences.some((r) => r.date === date)) continue
      d.occurrences.push({ id: randomUUID(), date, dueDate: date, person: null, taskId: null, status: 'skipped', completedAt: null, completedBy: null })
    }
    if (rule.missedPolicy === 'mark_missed') {
      for (const r of d.occurrences) {
        if (r.status !== 'open' || r.date >= latest) continue
        r.status = 'missed'
        if (r.taskId === null || r.taskId === root.id) continue
        const copy = this.deps.store.byId(r.taskId)
        const labels = copy?.labels ?? []
        if (copy !== null && labels.length < MAX_LABELS && !labels.some((l) => l.toLowerCase() === 'missed')) {
          this.deps.store.update(copy, { labels: normalizeLabels([...labels, 'Missed']) })
        }
      }
    }
    this.save(root)
    const startDate = this.withLead(root.startDate, root.dueDate, latest)
    if (!rule.createNew) {
      if (has(latest, null)) return
      d.occurrences.push({ id: randomUUID(), date: latest, dueDate: latest, person: null, taskId: root.id, status: 'open', completedAt: null, completedBy: null })
      d.nextId = null
      this.save(root)
      const why = await this.bringBack(root, rule, latest, startDate)
      this.setRoutineError(root, why === null ? null : `The one for ${shortDay(latest)} could not be made: ${why}`)
      return
    }
    const persons: Array<string | null> = rule.perAssignee ? this.everyoneOn(root) : [null]
    const failed: string[] = []
    for (const person of persons.length > 0 ? persons : [null]) {
      if (has(latest, person)) continue
      const r = await this.makeCopy(root, root, rule, latest, startDate, person)
      if ('error' in r) failed.push(`${person === null ? 'the task' : this.named(person).name}: ${r.error}`)
    }
    this.setRoutineError(root, failed.length === 0 ? null : `The one for ${shortDay(latest)} was not made for ${failed.join('; ')} It is tried again at the next time.`)
  }

  /** Every task of a routine that still exists: its own task and its copies. */
  private chainOf(root: TaskRecord): TaskRecord[] {
    return this.locals().filter((t) => t.id === root.id || t.detail?.routine?.rootTaskId === root.id)
  }

  /**
   * A status routine with nothing left to work on — every task of it finished,
   * archived or deleted, and none brought a next one (finished while paused,
   * or its next one failed). Restart is offered then.
   */
  private stuck(root: TaskRecord, rule: RoutineRule | null): string | null {
    if (rule === null || !isActive(rule) || rule.trigger !== 'status') return null
    const chain = this.chainOf(root)
    const open = chain.some((t) => t.archivedAt == null && !this.isFinishedFor(rule, t.crmStatus))
    if (open) return null
    const waiting = chain.some((t) => t.archivedAt == null && this.detail(t).nextId === null)
    if (!waiting && chain.length > 0) return null
    return 'Nothing more will come: every task of this routine is finished and none brought the next one. Restart makes the next one.'
  }

  /* --------------------------------------------- the clock's due work -- */

  /** The next moment something comes due — a schedule, a reminder, a scheduled comment; null when nothing will. */
  nextDueAt(): number | null {
    let soonest: number | null = null
    const take = (at: number | null): void => {
      if (at !== null && Number.isFinite(at) && (soonest === null || at < soonest)) soonest = at
    }
    for (const { root, rule } of this.scheduled()) take(this.nextScheduleAt(root, rule))
    for (const task of [...this.locals(), ...this.inTrash()]) {
      const d = task.detail
      if (d === undefined) continue
      if (this.deps.notify !== undefined) {
        for (const r of d.reminders ?? []) if (!r.sentAt) take(Math.max(Date.parse(r.remindAt), r.retryAt ?? 0))
      }
      if (task.deletedAt != null) continue
      for (const meta of Object.values(d.commentMeta ?? {})) if (meta.scheduledFor && !meta.deliveredAt) take(Date.parse(meta.scheduledFor))
    }
    return soonest
  }

  /** Do what has come due. Called by the task clock; changes are told through `onChange`. */
  async runDue(): Promise<void> {
    await this.queue(async () => {
      let changed = false
      for (const { root, rule } of this.scheduled()) {
        const at = this.nextScheduleAt(root, rule)
        if (at === null || at > this.now()) continue
        await this.runSchedule(root, rule)
        changed = true
      }
      for (const task of this.locals()) {
        if (await this.sendDueComments(task)) changed = true
        if (await this.sendDueReminders(task)) changed = true
      }
      // A reminder on a task in the Trash is settled at its time, never sent — the CRM's "the task was deleted".
      for (const task of this.inTrash()) if (await this.sendDueReminders(task)) changed = true
      if (changed) this.deps.onChange?.()
    })
  }

  /** Scheduled comments whose time has come go out: shown, told in Activity, and passed to the agent they address. */
  private async sendDueComments(task: TaskRecord): Promise<boolean> {
    const d = this.detail(task)
    let sent = false
    for (const c of d.comments) {
      const meta = d.commentMeta[c.id]
      if (!meta?.scheduledFor || meta.deliveredAt || Date.parse(meta.scheduledFor) > this.now()) continue
      meta.deliveredAt = this.iso()
      this.record(task, 'comment', { comment_id: c.id })
      this.save(task)
      sent = true
      const parentAuthor = meta.parentId ? (this.allComments(task).find((x) => x.id === meta.parentId)?.authorUserId ?? null) : null
      const warning = await this.deliver(task, c.body, parentAuthor)
      if (warning !== null) console.error('[tasks] a scheduled comment went out but did not reach its agent:', task.id, warning)
    }
    return sent
  }

  /**
   * Reminders whose time has come (the CRM's `deliverDueReminders`): each is
   * claimed before it is sent, so it never goes twice; one on an archived task
   * is skipped with the reason kept; one that failed is tried again later, up
   * to five times; one that can never go is settled with the reason.
   */
  private async sendDueReminders(task: TaskRecord): Promise<boolean> {
    const notify = this.deps.notify
    if (notify === undefined) return false
    const d = this.detail(task)
    let touched = false
    for (const r of d.reminders) {
      if (r.sentAt || Date.parse(r.remindAt) > this.now() || (r.retryAt ?? 0) > this.now()) continue
      r.sentAt = this.iso()
      this.save(task)
      touched = true
      if (task.deletedAt != null || task.archivedAt != null) {
        r.lastError = task.deletedAt != null ? 'skipped: the task was deleted' : 'skipped: the task is archived'
        this.save(task)
        continue
      }
      const title = stripFileTokens(task.title.split('\n')[0]).trim().slice(0, 80) || 'A task'
      let outcome: ReminderDelivery
      try {
        outcome = await notify({ taskId: task.id, title, body: r.note?.trim() || 'You asked to be reminded about this task.' })
      } catch (error) {
        outcome = { delivered: false, reason: error instanceof Error ? error.message : String(error), retry: true }
      }
      const attempts = (r.attempts ?? 0) + 1
      r.attempts = attempts
      if (outcome.delivered) {
        r.lastError = null
        r.retryAt = null
      } else if (!outcome.retry) {
        r.lastError = `skipped: ${outcome.reason}`
      } else if (attempts >= REMINDER_ATTEMPTS) {
        r.lastError = `stopped after ${attempts} tries: ${outcome.reason}`
      } else {
        r.sentAt = null
        r.lastError = outcome.reason
        r.retryAt = this.now() + REMINDER_RETRY_MS * attempts
      }
      this.save(task)
    }
    return touched
  }

  /* ------------------------------------------------------------ subtasks -- */

  private subtask(task: TaskRecord, subtaskId: string): StoredSubtask {
    const s = this.detail(task).subtasks.find((x) => x.id === subtaskId)
    if (s === undefined) throw new TaskConfigProblem('Subtask not found')
    return s
  }

  private addTaskSubtask(taskId: string, raw: unknown): { ok: true; id: string } | Fail {
    const task = this.task(taskId)
    const title = typeof raw === 'string' ? raw.trim() : ''
    if (title === '' || title.length > MAX_SUBTASK_TITLE) return fail('Subtask title is required (max 300 chars)')
    const d = this.detail(task)
    const id = randomUUID()
    d.subtasks.push({ id, title, done: false, sortOrder: d.subtasks.reduce((m, s) => Math.max(m, s.sortOrder), -1) + 1, assigneeUserId: null, priority: null, dueDate: null })
    this.record(task, 'subtask_added', { subtask_id: id, title })
    this.save(task)
    return { ok: true, id }
  }

  private setTaskSubtaskDone(taskId: string, subtaskId: string, done: boolean): Ok | Fail {
    const task = this.task(taskId)
    const s = this.subtask(task, subtaskId)
    s.done = done
    this.record(task, 'subtask_done', { subtask_id: s.id, title: s.title, done })
    this.save(task)
    return { ok: true }
  }

  private deleteTaskSubtask(taskId: string, subtaskId: string): Ok | Fail {
    const task = this.task(taskId)
    this.subtask(task, subtaskId)
    const d = this.detail(task)
    d.subtasks = d.subtasks.filter((s) => s.id !== subtaskId)
    this.save(task)
    return { ok: true }
  }

  private setTaskSubtaskAssignee(taskId: string, subtaskId: string, userId: string | null): Ok | Fail {
    const task = this.task(taskId)
    const s = this.subtask(task, subtaskId)
    if (userId !== null) this.requirePerson(userId)
    s.assigneeUserId = userId
    if (userId !== null) this.join(task, userId)
    this.save(task)
    return { ok: true }
  }

  private async setSubtaskMeta(taskId: string, subtaskId: string, patch: Record<string, unknown>): Promise<Ok | Fail> {
    const task = this.task(taskId)
    const s = this.subtask(task, subtaskId)
    let touched = false
    if ('priority' in patch) {
      const p = patch.priority ?? null
      if (p !== null && !(PRIORITIES as readonly unknown[]).includes(p)) return fail('Invalid priority')
      s.priority = p as TaskPriority | null
      touched = true
    }
    let dueChanged = false
    if ('dueDate' in patch) {
      const v = patch.dueDate
      if (v !== null && v !== '' && (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v))) return fail('Invalid due date')
      s.dueDate = typeof v === 'string' && v !== '' ? v : null
      touched = true
      dueChanged = true
    }
    if (!touched) return fail('Nothing to update')
    this.save(task)
    if (dueChanged && this.detail(task).syncSubtaskDates) await this.syncDates(task)
    return { ok: true }
  }

  /** The subtasks' earliest and latest due dates — what "Sync dates with subtasks" puts on the task. */
  private span(task: TaskRecord): { start: string; due: string } | null {
    const days = this.detail(task)
      .subtasks.map((s) => s.dueDate)
      .filter((d): d is string => d !== null)
      .sort()
    return days.length === 0 ? null : { start: days[0], due: days[days.length - 1] }
  }

  private async syncDates(task: TaskRecord): Promise<Ok | Fail> {
    const span = this.span(task)
    if (span === null || (task.startDate === span.start && task.dueDate === span.due)) return { ok: true }
    return this.update(task, { startDate: span.start, dueDate: span.due })
  }

  /* ---------------------------------------------------------- checklists -- */

  private findChecklist(checklistId: string): { task: TaskRecord; list: StoredChecklist } {
    for (const task of this.locals()) {
      const list = (task.detail?.checklists ?? []).find((l) => l.id === checklistId)
      if (list !== undefined) return { task, list: this.detail(task).checklists.find((l) => l.id === checklistId) as StoredChecklist }
    }
    throw new TaskConfigProblem('Checklist not found')
  }

  private findItem(itemId: string): { task: TaskRecord; list: StoredChecklist; item: StoredItem } {
    for (const task of this.locals()) {
      for (const list of task.detail?.checklists ?? []) {
        const item = list.items.find((i) => i.id === itemId)
        if (item !== undefined) return { task, list, item }
      }
    }
    throw new TaskConfigProblem('Checklist item not found')
  }

  private checklistTitle(raw: unknown): string | null {
    if (raw === null || raw === undefined) return 'Checklist'
    if (typeof raw !== 'string') return null
    const t = raw.trim()
    if (t === '') return 'Checklist'
    return t.length > MAX_CHECKLIST_TITLE ? null : t
  }

  private addChecklist(taskId: string, raw: unknown): { ok: true; id: string } | Fail {
    const task = this.task(taskId)
    const title = this.checklistTitle(raw)
    if (title === null) return fail('Checklist name is too long (max 200)')
    const d = this.detail(task)
    const id = randomUUID()
    d.checklists.push({ id, title, sortOrder: d.checklists.reduce((m, l) => Math.max(m, l.sortOrder), -1) + 1, items: [] })
    this.record(task, 'checklist_added', { checklist_id: id, title })
    this.save(task)
    return { ok: true, id }
  }

  private renameChecklist(checklistId: string, raw: unknown): Ok | Fail {
    const title = this.checklistTitle(raw)
    if (title === null) return fail('Checklist name is too long (max 200)')
    const { task, list } = this.findChecklist(checklistId)
    list.title = title
    this.save(task)
    return { ok: true }
  }

  private deleteChecklist(checklistId: string): Ok | Fail {
    const { task } = this.findChecklist(checklistId)
    const d = this.detail(task)
    d.checklists = d.checklists.filter((l) => l.id !== checklistId)
    this.save(task)
    return { ok: true }
  }

  private addChecklistItem(checklistId: string, raw: unknown): { ok: true; id: string } | Fail {
    const title = typeof raw === 'string' ? raw.trim() : ''
    if (title === '' || title.length > MAX_CHECKLIST_ITEM_TITLE) return fail('Item is required (max 300 chars)')
    const { task, list } = this.findChecklist(checklistId)
    const id = randomUUID()
    list.items.push({ id, title, done: false, sortOrder: list.items.reduce((m, i) => Math.max(m, i.sortOrder), -1) + 1, assigneeUserId: null })
    this.record(task, 'checklist_item', { item_id: id, title, done: null })
    this.save(task)
    return { ok: true, id }
  }

  private setChecklistItemDone(itemId: string, done: boolean): Ok | Fail {
    const { task, item } = this.findItem(itemId)
    item.done = done
    this.record(task, 'checklist_item', { item_id: item.id, title: item.title, done })
    this.save(task)
    return { ok: true }
  }

  private setChecklistItemAssignee(itemId: string, userId: string | null): Ok | Fail {
    const { task, item } = this.findItem(itemId)
    if (userId !== null) this.requirePerson(userId)
    item.assigneeUserId = userId
    if (userId !== null) this.join(task, userId)
    this.save(task)
    return { ok: true }
  }

  private deleteChecklistItem(itemId: string): Ok | Fail {
    const { task, list } = this.findItem(itemId)
    list.items = list.items.filter((i) => i.id !== itemId)
    this.save(task)
    return { ok: true }
  }

  /* -------------------------------------------------------- dependencies -- */

  private static mirror(kind: DependencyKind): DependencyKind {
    return kind === 'blocks' ? 'blocked_by' : kind === 'blocked_by' ? 'blocks' : 'linked'
  }

  /** The task's own links, and the other side of every link another task made to it. */
  private dependenciesOf(task: TaskRecord): TaskDependency[] {
    const rows: Array<{ kind: DependencyKind; otherTaskId: string; at: number }> = [...this.detail(task).dependencies]
    for (const other of this.locals()) {
      if (other.id === task.id) continue
      for (const dep of other.detail?.dependencies ?? []) {
        if (dep.otherTaskId === task.id) rows.push({ kind: LocalTaskDetail.mirror(dep.kind), otherTaskId: other.id, at: dep.at })
      }
    }
    const seen = new Set<string>()
    const out: TaskDependency[] = []
    for (const row of rows.sort((a, b) => a.at - b.at)) {
      const key = `${row.kind}:${row.otherTaskId}`
      if (seen.has(key)) continue
      seen.add(key)
      const other = this.deps.store.byId(row.otherTaskId)
      if (other === null || other.local !== true) continue
      out.push({ kind: row.kind, otherTaskId: other.id, otherTitle: other.title, otherDone: other.crmStatus === 'Done' })
    }
    return out
  }

  private addTaskDependency(taskId: string, otherTaskId: string, kind: unknown): Ok | Fail {
    if (typeof kind !== 'string' || !(DEPENDENCY_KINDS as readonly string[]).includes(kind)) return fail('Invalid dependency kind')
    if (taskId === otherTaskId) return fail('A task cannot depend on itself')
    const task = this.task(taskId)
    const other = this.deps.store.byId(otherTaskId)
    if (other === null || other.local !== true) return fail('Other task not found or not yours')
    const k = kind as DependencyKind
    if (this.dependenciesOf(task).some((d) => d.kind === k && d.otherTaskId === otherTaskId)) return { ok: true }
    this.detail(task).dependencies.push({ kind: k, otherTaskId, at: this.now() })
    this.record(task, 'dependency', { other_task_id: otherTaskId, title: other.title, kind: k, removed: false })
    this.save(task)
    return { ok: true }
  }

  private removeTaskDependency(taskId: string, otherTaskId: string, kind: unknown): Ok | Fail {
    if (typeof kind !== 'string' || !(DEPENDENCY_KINDS as readonly string[]).includes(kind)) return fail('Invalid dependency kind')
    const task = this.task(taskId)
    const k = kind as DependencyKind
    const d = this.detail(task)
    const before = d.dependencies.length
    d.dependencies = d.dependencies.filter((x) => !(x.kind === k && x.otherTaskId === otherTaskId))
    let removed = d.dependencies.length !== before
    const other = this.deps.store.byId(otherTaskId)
    if (!removed && other !== null && other.local === true) {
      // The link was made from the other task: it is taken off there.
      const od = this.detail(other)
      const mirrored = LocalTaskDetail.mirror(k)
      const was = od.dependencies.length
      od.dependencies = od.dependencies.filter((x) => !(x.kind === mirrored && x.otherTaskId === task.id))
      removed = od.dependencies.length !== was
      if (removed) this.save(other)
    }
    if (!removed) return fail('Dependency not found')
    this.record(task, 'dependency', { other_task_id: otherTaskId, title: other?.title ?? null, kind: k, removed: true })
    this.save(task)
    return { ok: true }
  }

  /* --------------------------------------------------------- attachments -- */

  private abs(file: string): string | null {
    return this.deps.filesDir === null ? null : join(this.deps.filesDir, file)
  }

  private previewOf(a: StoredAttachment): string | null {
    if (a.file === null || a.mimeType === null || !DRAWABLE.has(a.mimeType)) return null
    if (a.sizeBytes !== null && a.sizeBytes > MAX_PREVIEW_BYTES) return null
    const path = this.abs(a.file)
    if (path === null || !existsSync(path)) return null
    try {
      const bytes = readFileSync(path)
      if (bytes.byteLength > MAX_PREVIEW_BYTES) return null
      return `data:${a.mimeType};base64,${bytes.toString('base64')}`
    } catch {
      return null
    }
  }

  private attachmentView(a: StoredAttachment): TaskAttachment {
    const image = inlineKind(a.mimeType, a.fileName) === 'image'
    return {
      id: a.id,
      kind: a.kind,
      fileName: a.fileName,
      mimeType: a.mimeType,
      sizeBytes: a.sizeBytes,
      documentId: a.kind === 'document' ? a.documentId : null,
      storagePath: a.kind === 'upload' ? a.file : null,
      uploadedBy: a.uploadedBy,
      createdAt: this.iso(a.at),
      previewUrl: image ? this.previewOf(a) : null,
    }
  }

  /** Keep one file on the task: its bytes written into the task's own folder. */
  private keepFile(task: TaskRecord, name: string, mime: string | null, write: (path: string) => number): StoredAttachment {
    if (this.deps.filesDir === null) throw new TaskConfigProblem('Files cannot be kept on this computer right now.')
    const id = randomUUID()
    const rel = join(task.externalTaskId, `${id}-${safeName(name)}`)
    const path = join(this.deps.filesDir, rel)
    mkdirSync(dirname(path), { recursive: true, mode: 0o700 })
    const size = write(path)
    return { id, kind: 'upload', fileName: basename(name).slice(0, 200) || 'file', mimeType: mimeOf(name, mime), sizeBytes: size, file: rel, documentId: null, uploadedBy: actorNow(), at: this.now() }
  }

  private uploadTaskFile(taskId: string, raw: unknown): { ok: true; attachment: TaskAttachment } | Fail {
    const task = this.task(taskId)
    const upload = raw as Partial<LocalUpload> | null
    if (upload === null || typeof upload !== 'object' || typeof upload.name !== 'string' || !(upload.bytes instanceof Uint8Array)) {
      return fail('That file could not be read.')
    }
    const check = checkUpload({ name: upload.name, size: upload.bytes.byteLength })
    if (!check.ok) return fail(check.error)
    const bytes = upload.bytes
    const row = this.keepFile(task, upload.name, typeof upload.type === 'string' ? upload.type : null, (path) => {
      writeFileSync(path, bytes, { mode: 0o600 })
      return bytes.byteLength
    })
    this.detail(task).attachments.push(row)
    this.record(task, 'attachment', { attachment_id: row.id, file_name: row.fileName, removed: false })
    this.save(task)
    return { ok: true, attachment: this.attachmentView(row) }
  }

  private async chooseTaskFiles(taskId: string): Promise<{ ok: true; attachments: TaskAttachment[]; errors: string[] } | Fail> {
    const task = this.task(taskId)
    const paths = await this.deps.chooseFiles()
    const attachments: TaskAttachment[] = []
    const errors: string[] = []
    for (const path of paths) {
      const name = basename(path)
      let size = 0
      try {
        size = statSync(path).size
      } catch {
        errors.push(`“${name}” could not be read.`)
        continue
      }
      const check = checkUpload({ name, size })
      if (!check.ok) {
        errors.push(check.error)
        continue
      }
      const row = this.keepFile(task, name, null, (to) => {
        copyFileSync(path, to)
        return size
      })
      this.detail(task).attachments.push(row)
      this.record(task, 'attachment', { attachment_id: row.id, file_name: row.fileName, removed: false })
      attachments.push(this.attachmentView(row))
    }
    if (attachments.length > 0) this.save(task)
    return { ok: true, attachments, errors }
  }

  private findAttachment(attachmentId: string): { task: TaskRecord; row: StoredAttachment } {
    for (const task of this.locals()) {
      const row = (task.detail?.attachments ?? []).find((a) => a.id === attachmentId)
      if (row !== undefined) return { task, row }
    }
    throw new TaskConfigProblem('Attachment not found')
  }

  private attachExistingDocument(taskId: string, documentId: string): { ok: true; id?: string } | Fail {
    const task = this.task(taskId)
    const cut = documentId.lastIndexOf('/')
    const source = cut > 0 ? this.deps.store.byId(documentId.slice(0, cut)) : null
    const src = source?.local === true ? (source.detail?.attachments ?? []).find((a) => a.id === documentId.slice(cut + 1)) : undefined
    if (src === undefined || src.file === null) return fail('That file is no longer attached to any of your tasks.')
    const d = this.detail(task)
    // Already on this task, as itself or as a pointer: nothing to add.
    if (source?.id === task.id || d.attachments.some((a) => a.documentId === documentId)) return { ok: true }
    const row: StoredAttachment = {
      id: randomUUID(),
      kind: 'document',
      fileName: src.fileName,
      mimeType: src.mimeType,
      sizeBytes: src.sizeBytes,
      file: src.file,
      documentId,
      uploadedBy: actorNow(),
      at: this.now(),
    }
    d.attachments.push(row)
    this.record(task, 'attachment', { attachment_id: row.id, file_name: row.fileName, removed: false })
    this.save(task)
    return { ok: true, id: row.id }
  }

  /** Is any attachment row anywhere still pointing at this file? */
  /** A file still on a task — one in the Trash too: deleting a task never takes its files, so Restore finds them. */
  private fileInUse(file: string): boolean {
    return [...this.locals(), ...this.inTrash()].some((t) => (t.detail?.attachments ?? []).some((a) => a.file === file))
  }

  /** Your tasks in the Trash. */
  private inTrash(): TaskRecord[] {
    return this.deps.store.inTrash().filter((task) => task.local === true)
  }

  private deleteFileIfUnused(file: string | null): void {
    if (file === null || this.fileInUse(file)) return
    const path = this.abs(file)
    if (path === null) return
    try {
      if (existsSync(path)) unlinkSync(path)
      const folder = dirname(path)
      if (existsSync(folder) && readdirSync(folder).length === 0) rmdirSync(folder)
    } catch (error) {
      console.error('[tasks] a task file could not be removed:', error)
    }
  }

  private detachTaskAttachment(attachmentId: string): Ok | Fail {
    const { task, row } = this.findAttachment(attachmentId)
    const d = this.detail(task)
    d.attachments = d.attachments.filter((a) => a.id !== attachmentId)
    this.record(task, 'attachment', { attachment_id: row.id, file_name: row.fileName, removed: true })
    this.save(task)
    this.deleteFileIfUnused(row.file)
    return { ok: true }
  }

  private async openTaskFile(taskId: string, attachmentId: string): Promise<Ok | Fail> {
    const task = this.task(taskId)
    const row = this.detail(task).attachments.find((a) => a.id === attachmentId)
    if (row === undefined) return fail('Attachment not found')
    const path = row.file === null ? null : this.abs(row.file)
    if (path === null || !existsSync(path)) return fail(`“${row.fileName}” is no longer on this computer.`)
    const said = await this.deps.openPath(path)
    return said === '' ? { ok: true } : fail(`“${row.fileName}” could not be opened: ${said}`)
  }

  /* ----------------------------------------------------- custom fields -- */

  private findField(fieldId: string): { task: TaskRecord; field: TaskField } {
    for (const task of this.locals()) {
      const field = (task.detail?.fields ?? []).find((f) => f.id === fieldId)
      if (field !== undefined) return { task, field: this.detail(task).fields.find((f) => f.id === fieldId) as TaskField }
    }
    throw new TaskConfigProblem('That field is no longer on this task')
  }

  /**
   * A value through the CRM's rule, with the local ids it names carried
   * across that rule's uuid checks and checked against what exists here.
   */
  private normalise(task: TaskRecord, kind: FieldKind, config: TaskField['config'], raw: unknown): { ok: true; value: unknown } | Fail {
    const people = this.people()
    const alias = new Map(people.map((p) => [p.id, personAlias(p.id)] as const))
    const back = new Map(people.map((p) => [personAlias(p.id), p.id] as const))
    let input = raw
    if (kind === 'people' && Array.isArray(raw)) input = raw.map((id) => (typeof id === 'string' ? (alias.get(id) ?? id) : id))
    if (kind === 'tasks' && Array.isArray(raw)) {
      input = raw.map((ref) =>
        typeof ref === 'object' && ref !== null && typeof (ref as { id?: unknown }).id === 'string'
          ? { ...(ref as object), id: (this.deps.store.byId((ref as { id: string }).id)?.externalTaskId ?? (ref as { id: string }).id) }
          : ref,
      )
    }
    const v = normaliseValue(kind, config, input, { userId: ME_ID, now: this.iso() })
    if (!v.ok) return v
    if (v.value === null) return { ok: true, value: null }
    if (kind === 'people') {
      const ids = v.value as string[]
      if (ids.some((id) => !back.has(id))) return fail('A person is not one of yours')
      return { ok: true, value: ids.map((id) => back.get(id) as string) }
    }
    if (kind === 'tasks') {
      const refs = v.value as TaskRef[]
      const out: TaskRef[] = []
      for (const ref of refs) {
        const linked = this.locals().find((t) => t.externalTaskId === ref.id)
        if (linked === undefined) return fail('A linked task no longer exists')
        if (linked.id === task.id) return fail('A task cannot link to itself')
        out.push({ id: linked.id, label: linked.title || 'Task' })
      }
      return { ok: true, value: out }
    }
    if (kind === 'files') {
      const refs = v.value as FileRef[]
      const rows = new Map(this.detail(task).attachments.map((a) => [a.id, a] as const))
      if (refs.some((r) => !rows.has(r.id))) return fail('A file is not attached to this task')
      return { ok: true, value: refs.map((r) => ({ id: r.id, name: rows.get(r.id)?.fileName ?? r.name, mime: rows.get(r.id)?.mimeType ?? null })) }
    }
    return v
  }

  private say(field: TaskField, value: unknown): string | null {
    return feedValue(formatFieldValue({ kind: field.kind, config: field.config, value }, (id) => this.person(id)?.name ?? null))
  }

  private fieldLine(task: TaskRecord, payload: ActivityReadPayload): void {
    this.record(task, 'field', payload)
  }

  private writeValue(task: TaskRecord, field: TaskField, raw: unknown): { ok: true; field: TaskField } | Fail {
    const v = this.normalise(task, field.kind, field.config, raw)
    if (!v.ok) return v
    const from = this.say(field, field.value)
    field.value = v.value
    field.updatedAt = this.iso()
    this.fieldLine(task, { action: 'changed', field_id: field.id, label: field.label, from, to: this.say(field, field.value) })
    this.save(task)
    return { ok: true, field: { ...field } }
  }

  private autoOf(task: TaskRecord): AutoProgress {
    const d = this.detail(task)
    const items = d.checklists.flatMap((l) => l.items)
    return {
      subtasks: { done: d.subtasks.filter((s) => s.done).length, total: d.subtasks.length },
      checklists: { done: items.filter((i) => i.done).length, total: items.length },
    }
  }

  private listTaskFields(taskId: string): { ok: true; fields: TaskField[]; people: Record<string, TaskAssignee>; auto: AutoProgress | null; viewerId: string } {
    const task = this.task(taskId)
    const fields = sortFields([...this.detail(task).fields]).map((f) => ({ ...f }))
    const named = new Set<string>()
    for (const f of fields) {
      const v = f.value as Record<string, unknown> | unknown[] | null
      if (!v) continue
      if (f.kind === 'people' && Array.isArray(v)) for (const id of v) if (typeof id === 'string') named.add(id)
      if (!Array.isArray(v)) {
        if (f.kind === 'signature' && typeof v.by === 'string') named.add(v.by)
        if (f.kind === 'button' && typeof v.lastBy === 'string') named.add(v.lastBy)
        if (f.kind === 'voting' && v.votes && typeof v.votes === 'object') for (const id of Object.keys(v.votes as object)) named.add(id)
      }
    }
    const people: Record<string, TaskAssignee> = {}
    for (const id of named) people[id] = this.named(id)
    return { ok: true, fields, people, auto: fields.some((f) => f.kind === 'progress_auto') ? this.autoOf(task) : null, viewerId: ME_ID }
  }

  private createTaskField(taskId: string, input: Record<string, unknown>): { ok: true; field: TaskField } | Fail {
    const task = this.task(taskId)
    const label = normaliseFieldLabel(input.label)
    if (!label.ok) return label
    if (!isFieldKind(input.kind)) return fail('Unknown field type')
    const kind = input.kind
    const d = this.detail(task)
    if (d.fields.length >= MAX_FIELDS_PER_TASK) return fail(`A task can hold ${MAX_FIELDS_PER_TASK} fields`)
    if (d.fields.some((f) => sameLabel(f.label, label.value))) return fail(`This task already has a field called “${label.value}”`)
    const cfg = normaliseConfig(kind, input.config, d.fields)
    if (!cfg.ok) return cfg
    let value: unknown = null
    if (input.value !== undefined && input.value !== null && !isComputedKind(kind) && !isActionOnlyKind(kind)) {
      const v = this.normalise(task, kind, cfg.value, input.value)
      if (!v.ok) return v
      value = v.value
    }
    const now = this.iso()
    const field: TaskField = {
      id: randomUUID(),
      taskId: task.id,
      label: label.value,
      kind,
      config: cfg.value,
      value,
      sortOrder: d.fields.reduce((m, f) => Math.max(m, f.sortOrder ?? -1), -1) + 1,
      createdBy: actorNow(),
      createdAt: now,
      updatedAt: now,
    }
    d.fields.push(field)
    this.fieldLine(task, { action: 'added', field_id: field.id, label: field.label, kind })
    this.save(task)
    return { ok: true, field: { ...field } }
  }

  private updateTaskFieldValue(fieldId: string, value: unknown): { ok: true; field: TaskField } | Fail {
    const { task, field } = this.findField(fieldId)
    return this.writeValue(task, field, value)
  }

  private renameTaskField(fieldId: string, raw: unknown): { ok: true; field: TaskField; formulas: TaskField[] } | Fail {
    const clean = normaliseFieldLabel(raw)
    if (!clean.ok) return clean
    const { task, field } = this.findField(fieldId)
    const old = field.label
    if (old === clean.value) return { ok: true, field: { ...field }, formulas: [] }
    const d = this.detail(task)
    if (d.fields.some((f) => f.id !== field.id && sameLabel(f.label, clean.value))) return fail(`This task already has a field called “${clean.value}”`)
    field.label = clean.value
    field.updatedAt = this.iso()
    // Formulas that said {Old} now say {New}, so a rename never silently breaks a sum.
    const formulas: TaskField[] = []
    for (const f of d.fields) {
      if (f.kind !== 'formula' || !f.config.expression) continue
      if (!formulaRefs(f.config.expression).some((n) => sameLabel(n, old))) continue
      f.config = { ...f.config, expression: renameFormulaRefs(f.config.expression, old, clean.value) }
      formulas.push({ ...f })
    }
    this.fieldLine(task, { action: 'renamed', field_id: field.id, label: clean.value, from: old, to: clean.value })
    this.save(task)
    return { ok: true, field: { ...field }, formulas }
  }

  private updateTaskFieldConfig(fieldId: string, config: unknown): { ok: true; field: TaskField } | Fail {
    const { task, field } = this.findField(fieldId)
    const d = this.detail(task)
    const cfg = normaliseConfig(
      field.kind,
      config,
      d.fields.filter((f) => f.id !== field.id),
    )
    if (!cfg.ok) return cfg
    field.config = cfg.value
    field.value = reconcileValue(field.kind, cfg.value, field.value)
    field.updatedAt = this.iso()
    this.fieldLine(task, { action: 'options', field_id: field.id, label: field.label })
    this.save(task)
    return { ok: true, field: { ...field } }
  }

  private reorderTaskFields(taskId: string, raw: unknown): Ok | Fail {
    if (!Array.isArray(raw) || raw.some((id) => typeof id !== 'string') || new Set(raw).size !== raw.length) return fail('Invalid order')
    const task = this.task(taskId)
    const d = this.detail(task)
    const have = new Set(d.fields.map((f) => f.id))
    if (have.size !== raw.length || raw.some((id) => !have.has(id as string))) return fail('The fields changed — reload and try again')
    raw.forEach((id, index) => {
      const f = d.fields.find((x) => x.id === id)
      if (f) f.sortOrder = index
    })
    this.save(task)
    return { ok: true }
  }

  private deleteTaskField(fieldId: string): Ok | Fail {
    const { task, field } = this.findField(fieldId)
    const d = this.detail(task)
    d.fields = d.fields.filter((f) => f.id !== fieldId)
    this.fieldLine(task, { action: 'removed', field_id: field.id, label: field.label })
    this.save(task)
    return { ok: true }
  }

  private toggleTaskFieldVote(fieldId: string): { ok: true; field: TaskField } | Fail {
    const { task, field } = this.findField(fieldId)
    if (field.kind !== 'voting') return fail('This field is not a vote')
    const cur = field.value && typeof field.value === 'object' && !Array.isArray(field.value) ? ((field.value as { votes?: Record<string, true> }).votes ?? {}) : {}
    const votes: Record<string, true> = { ...cur }
    const voted = !votes[ME_ID]
    if (voted) votes[ME_ID] = true
    else delete votes[ME_ID]
    field.value = Object.keys(votes).length > 0 ? { votes } : null
    field.updatedAt = this.iso()
    this.fieldLine(task, { action: 'voted', field_id: field.id, label: field.label, to: voted ? 'voted' : 'unvoted' })
    this.save(task)
    return { ok: true, field: { ...field } }
  }

  /** A Button: its one action through the task's own path, then the press counted. */
  private async pressTaskFieldButton(fieldId: string): Promise<{ ok: true; field: TaskField; target: TaskField | null; status: string | null } | Fail> {
    const { task, field } = this.findField(fieldId)
    if (field.kind !== 'button') return fail('This field is not a button')
    const action = field.config.action
    if (!action) return fail('This button has no action — Edit options to choose one')
    let target: TaskField | null = null
    let status: string | null = null
    if (action.type === 'status') {
      const r = await this.setTaskStatus(task.id, action.status)
      if (!r.ok) return r
      status = action.status
    } else if (action.type === 'comment') {
      const r = await this.addTaskCommentWith(task.id, action.body, {})
      if (!r.ok) return r
    } else {
      const t = this.detail(task).fields.find((f) => f.id === action.fieldId)
      if (t === undefined) return fail('The field this button sets is no longer on this task')
      const r = this.writeValue(task, t, action.value)
      if (!r.ok) return fail(`“${t.label}”: ${r.error}`)
      target = r.field
    }
    const live = this.findField(fieldId).field
    const prev = live.value && typeof live.value === 'object' ? (live.value as { count?: unknown }).count : 0
    live.value = { count: (typeof prev === 'number' ? prev : 0) + 1, lastBy: actorNow(), lastAt: this.iso() }
    live.updatedAt = this.iso()
    this.fieldLine(task, { action: 'pressed', field_id: live.id, label: live.label })
    this.save(task)
    return { ok: true, field: { ...live }, target, status }
  }

  /* ------------------------------------------------------------ comments -- */

  /** The comments read from the task's notes: an agent's or Hoot's output, and your replies the popup did not write. */
  private noteComments(task: TaskRecord): TaskComment[] {
    const d = this.detail(task)
    const mine = new Set(d.comments.filter((c) => c.authorUserId === ME_ID).map((c) => c.body.trim()))
    const out: TaskComment[] = []
    for (const note of task.notes ?? []) {
      const fromAgent = COMMENT_NOTES.has(note.kind)
      const reply = note.kind === 'reply' && !mine.has(note.text.trim())
      if (!fromAgent && !reply) continue
      const who = this.named(note.by)
      out.push({
        id: `note-${note.at}-${hashOf(`${note.kind}|${note.text}`)}`,
        taskId: task.id,
        authorUserId: who.id,
        authorName: who.name,
        authorInitials: who.initials,
        authorColor: who.color,
        body: note.text,
        createdAt: this.iso(note.at),
      })
    }
    return out
  }

  private allComments(task: TaskRecord): TaskComment[] {
    const stored = this.detail(task).comments.map((c): TaskComment => {
      const who = this.named(c.authorUserId)
      return { id: c.id, taskId: task.id, authorUserId: who.id, authorName: who.name, authorInitials: who.initials, authorColor: who.color, body: c.body, createdAt: this.iso(c.at) }
    })
    return [...stored, ...this.noteComments(task)].sort((a, b) => Date.parse(a.createdAt) - Date.parse(b.createdAt))
  }

  private listTaskComments(taskId: string): { ok: true; comments: TaskComment[] } {
    return { ok: true, comments: this.allComments(this.task(taskId)) }
  }

  private comment(task: TaskRecord, commentId: string): TaskComment {
    const c = this.allComments(task).find((x) => x.id === commentId)
    if (c === undefined) throw new TaskConfigProblem('That comment is no longer on this task')
    return c
  }

  private metaOf(task: TaskRecord, commentId: string): CommentMeta {
    const d = this.detail(task)
    const meta = d.commentMeta[commentId] ?? { ...EMPTY_META }
    d.commentMeta[commentId] = meta
    return meta
  }

  private fetchCommentExtras(taskId: string): { ok: true; extras: CommentExtras } {
    const task = this.task(taskId)
    const d = this.detail(task)
    const meta: Record<string, CommentMeta> = {}
    const reactions: Record<string, CommentReaction[]> = {}
    const order = (e: string) => {
      const i = (REACTION_EMOJI as readonly string[]).indexOf(e)
      return i < 0 ? 99 : i
    }
    for (const c of this.allComments(task)) {
      meta[c.id] = { ...(d.commentMeta[c.id] ?? EMPTY_META) }
      const list = d.reactions[c.id]
      if (list?.length) reactions[c.id] = [...list].sort((a, b) => order(a.emoji) - order(b.emoji)).map((r) => ({ emoji: r.emoji, userIds: [...r.userIds] }))
    }
    return { ok: true, extras: { meta, reactions } }
  }

  /**
   * Who a comment should also reach: an agent or Hoot that holds the task or
   * handed it back to you, when the comment names them ("@Builder …") or
   * replies to one of their comments.
   */
  private listener(task: TaskRecord, body: string, parentAuthor: string | null): string | null {
    const candidates = [task.assignee.kind === 'agent' || task.assignee.kind === 'hoot' ? task.assignee.agentId : null, task.handedFrom ?? null].filter(
      (id): id is string => id !== null,
    )
    const lower = body.toLowerCase()
    for (const id of candidates) {
      const name = id === HOOT_ID ? 'Hoot' : (this.deps.config.agent(id)?.name ?? null)
      if (name === null) continue
      const at = `@${name.toLowerCase()}`
      const i = lower.indexOf(at)
      if (i >= 0 && (i === 0 || /\s/.test(lower[i - 1])) && !/[\p{L}\p{N}]/u.test(lower[i + at.length] ?? '')) return id
      if (parentAuthor === id) return id
    }
    return null
  }

  private async deliver(task: TaskRecord, body: string, parentAuthor: string | null): Promise<string | null> {
    if (this.listener(task, body, parentAuthor) === null) return null
    try {
      await this.deps.local.reply(task.id, body)
      return null
    } catch (error) {
      const why = error instanceof Error ? error.message : String(error)
      return `Posted, but it could not reach the agent: ${why}`
    }
  }

  private async addTaskCommentWith(taskId: string, raw: unknown, opts: Record<string, unknown>): Promise<{ ok: true; id: string; warning?: string } | Fail> {
    const body = typeof raw === 'string' ? raw.trim() : ''
    if (body === '' || body.length > MAX_COMMENT_BODY) return fail('Comment is required (max 2000 chars)')
    let scheduled: string | null = null
    if (opts.scheduledFor) {
      const t = typeof opts.scheduledFor === 'string' ? Date.parse(opts.scheduledFor) : Number.NaN
      if (!Number.isFinite(t)) return fail('That time could not be read')
      if (t <= this.now()) return fail('Pick a time in the future')
      if (t > this.now() + YEAR_MS) return fail('A comment can be scheduled up to a year ahead')
      scheduled = new Date(t).toISOString()
    }
    const task = this.task(taskId)
    let parentId: string | null = null
    let parentAuthor: string | null = null
    if (typeof opts.parentId === 'string' && opts.parentId !== '') {
      const parent = this.comment(task, opts.parentId)
      // A reply to a reply joins the same thread: threads are one level deep.
      parentId = this.detail(task).commentMeta[parent.id]?.parentId ?? parent.id
      parentAuthor = parent.authorUserId
    }
    let assignee: string | null = null
    if (typeof opts.assigneeUserId === 'string' && opts.assigneeUserId !== '') assignee = this.requirePerson(opts.assigneeUserId).id
    const d = this.detail(task)
    const id = randomUUID()
    d.comments.push({ id, authorUserId: actorNow(), body, at: this.now() })
    if (d.comments.length > MAX_COMMENTS) d.comments = d.comments.slice(-MAX_COMMENTS)
    // A scheduled one waits for the clock: until it goes out, it is not delivered (the CRM's record, not the time).
    d.commentMeta[id] = { parentId, resolvedAt: null, resolvedBy: null, assigneeUserId: assignee, scheduledFor: scheduled, ...(scheduled === null ? {} : { deliveredAt: null }) }
    // A scheduled comment is told about only when it goes out.
    if (scheduled === null) this.record(task, 'comment', { comment_id: id })
    this.save(task)
    const warning = scheduled === null ? await this.deliver(task, body, parentAuthor) : null
    return warning === null ? { ok: true, id } : { ok: true, id, warning }
  }

  private toggleCommentReaction(taskId: string, commentId: string, emoji: unknown): { ok: true; on: boolean } | Fail {
    if (!isReactionEmoji(emoji)) return fail('That reaction is not offered')
    const task = this.task(taskId)
    this.comment(task, commentId)
    const d = this.detail(task)
    const list = d.reactions[commentId] ?? []
    const hit = list.find((r) => r.emoji === emoji)
    let on: boolean
    if (hit?.userIds.includes(ME_ID)) {
      hit.userIds = hit.userIds.filter((u) => u !== ME_ID)
      on = false
    } else if (hit) {
      hit.userIds.push(ME_ID)
      on = true
    } else {
      list.push({ emoji, userIds: [ME_ID] })
      on = true
    }
    d.reactions[commentId] = list.filter((r) => r.userIds.length > 0)
    this.save(task)
    return { ok: true, on }
  }

  private setCommentResolved(taskId: string, commentId: string, resolved: boolean): Ok | Fail {
    const task = this.task(taskId)
    this.comment(task, commentId)
    const meta = this.metaOf(task, commentId)
    meta.resolvedAt = resolved ? this.iso() : null
    meta.resolvedBy = resolved ? actorNow() : null
    this.save(task)
    return { ok: true }
  }

  private assignComment(taskId: string, commentId: string, userId: string | null): Ok | Fail {
    const task = this.task(taskId)
    this.comment(task, commentId)
    if (userId !== null) this.requirePerson(userId)
    const meta = this.metaOf(task, commentId)
    // A new assignment reopens it, as the CRM's.
    meta.assigneeUserId = userId
    meta.resolvedAt = null
    meta.resolvedBy = null
    this.save(task)
    return { ok: true }
  }

  private async sendScheduledNow(taskId: string, commentId: string): Promise<{ ok: true; warning?: string; alreadySent?: boolean } | Fail> {
    const task = this.task(taskId)
    const c = this.comment(task, commentId)
    if (c.authorUserId !== actorNow()) return fail('Only the person who wrote it can send it now')
    const meta = this.metaOf(task, commentId)
    if (!meta.scheduledFor) return fail('That comment is not scheduled')
    if (meta.deliveredAt) return { ok: true, alreadySent: true }
    const now = this.iso()
    meta.scheduledFor = now
    meta.deliveredAt = now
    this.record(task, 'comment', { comment_id: commentId })
    this.save(task)
    const parentAuthor = meta.parentId ? (this.allComments(task).find((x) => x.id === meta.parentId)?.authorUserId ?? null) : null
    const warning = await this.deliver(task, c.body, parentAuthor)
    return warning === null ? { ok: true } : { ok: true, warning }
  }

  /* ------------------------------------------------------------ activity -- */

  /** The task's own notes, as Activity lines — those the popup has not already told in its own words. */
  private noteRows(task: TaskRecord): StoredActivity[] {
    const covered = new Set(this.detail(task).covered)
    const rows: StoredActivity[] = []
    let status: string | null = null
    for (const note of task.notes ?? []) {
      const key = noteKey(note)
      const id = `note-${note.at}-${hashOf(key)}`
      if (note.kind === 'status') {
        const to = note.text.replace(/^Status:\s*/, '').trim()
        if (!covered.has(key)) rows.push({ id, kind: 'status', payload: { from: status, to }, by: note.by, at: note.at })
        status = to
        continue
      }
      if (covered.has(key)) continue
      if (note.kind === 'assigned') {
        if (note.text === 'Handed to you.') rows.push({ id, kind: 'assigned', payload: { user_id: ME_ID, name: 'You', primary: true }, by: note.by, at: note.at })
        else {
          const name = note.text.replace(/^Assigned to\s*/, '').replace(/\.$/, '')
          const who = this.people().find((p) => p.name === name || (name === 'you' && p.id === ME_ID))
          if (name === 'nobody') rows.push({ id, kind: 'unassigned', payload: { user_id: null, name: 'nobody' }, by: note.by, at: note.at })
          else rows.push({ id, kind: 'assigned', payload: { user_id: who?.id ?? null, name: who?.name ?? name, primary: true }, by: note.by, at: note.at })
        }
        continue
      }
      if (note.kind !== 'edited') continue
      if (note.text.startsWith('Created')) rows.push({ id, kind: 'created', payload: {}, by: note.by, at: note.at })
      else if (note.text === 'Archived.') rows.push({ id, kind: 'archived', payload: { on: true }, by: note.by, at: note.at })
      else if (note.text.startsWith('Restored')) rows.push({ id, kind: 'archived', payload: { on: false }, by: note.by, at: note.at })
      else if (note.text.startsWith('Changed the ')) {
        // Lines from before the popup tell only which fields changed, not from what: the ones the CRM can say so.
        const words = note.text.replace(/^Changed the /, '').replace(/\.$/, '').split(', ')
        if (words.includes('title')) rows.push({ id: `${id}-t`, kind: 'title', payload: {}, by: note.by, at: note.at })
        if (words.includes('details')) rows.push({ id: `${id}-d`, kind: 'description', payload: {}, by: note.by, at: note.at })
        if (words.some((w) => /date|time/.test(w))) rows.push({ id: `${id}-w`, kind: 'dates', payload: {}, by: note.by, at: note.at })
      }
    }
    return rows
  }

  private listTaskActivity(taskId: string): { ok: true; rows: TaskActivityRow[]; total: number } {
    const task = this.task(taskId)
    const all = [...this.noteRows(task), ...this.detail(task).activity].sort((a, b) => b.at - a.at)
    const rows = all.slice(0, MAX_ACTIVITY).map((r): TaskActivityRow => ({
      id: r.id,
      taskId: task.id,
      kind: r.kind,
      payload: r.payload,
      actor: this.named(r.by),
      actorUserId: r.by,
      createdAt: this.iso(r.at),
    }))
    return { ok: true, rows, total: all.length }
  }

  private fetchDescriptionHistory(taskId: string): { ok: true; versions: DescriptionVersion[] } {
    const task = this.task(taskId)
    const versions = this.detail(task)
      .activity.filter((r) => r.kind === 'description')
      .sort((a, b) => b.at - a.at)
      .map((r) => ({
        at: this.iso(r.at),
        by: r.by,
        from: typeof r.payload.from === 'string' ? r.payload.from : null,
        to: typeof r.payload.to === 'string' ? r.payload.to : null,
      }))
    return { ok: true, versions }
  }

  /* -------------------------------------------------------- extras · time -- */

  private fetchTaskPageExtras(taskId: string): { ok: true; extras: TaskPageExtras } {
    const task = this.task(taskId)
    const d = this.detail(task)
    const subtaskMeta: Record<string, SubtaskMeta> = {}
    for (const s of d.subtasks) subtaskMeta[s.id] = { priority: s.priority, dueDate: s.dueDate }
    return {
      ok: true,
      extras: {
        taskType: task.taskType ?? 'task',
        labels: [...(task.labels ?? [])],
        estimateMinutes: task.estimateMinutes ?? null,
        recurrenceRule: normalizeRecurrenceRule(d.recurrenceRule),
        timeEntries: [...d.time].sort((a, b) => Date.parse(a.startedAt) - Date.parse(b.startedAt)).map(entryOf),
        subtaskMeta,
      },
    }
  }

  private async setTaskType(taskId: string, type: unknown): Promise<Ok | Fail> {
    if (!isTaskType(type)) return fail('Invalid task type')
    return this.update(this.task(taskId), { taskType: type })
  }

  private async setTaskLabels(taskId: string, labels: unknown): Promise<Ok | Fail> {
    if (!Array.isArray(labels)) return fail('Invalid tags')
    return this.update(this.task(taskId), { labels: normalizeLabels(labels) })
  }

  private async moveTask(taskId: string, board: unknown): Promise<Ok | Fail> {
    if (typeof board !== 'string') return fail('Invalid board')
    return this.update(this.task(taskId), { board: board.trim() === '' ? null : board })
  }

  private async setTimeEstimate(taskId: string, minutes: unknown): Promise<Ok | Fail> {
    if (minutes !== null && (typeof minutes !== 'number' || !Number.isInteger(minutes) || minutes < 0 || minutes > 100_000)) return fail('Invalid estimate')
    return this.update(this.task(taskId), { estimateMinutes: minutes })
  }

  /** Close every running timer — on every local task, or on one. Each closed entry gets its line. */
  private stopRunning(onlyTask: TaskRecord | null): StoredTimeEntry[] {
    const closed: StoredTimeEntry[] = []
    const now = this.now()
    for (const task of onlyTask === null ? this.locals() : [onlyTask]) {
      // One running timer per person: yours, Hoot's or an app's never stops another's.
      const running = (task.detail?.time ?? []).filter((e) => e.endedAt === null && e.userId === actorNow())
      if (running.length === 0) continue
      for (const e of this.detail(task).time) {
        if (e.endedAt !== null || e.userId !== actorNow()) continue
        const secs = Math.min(DAY_SECONDS, Math.max(0, Math.floor((now - Date.parse(e.startedAt)) / 1000)))
        e.endedAt = this.iso(now)
        e.seconds = secs
        this.record(task, 'time_tracked', { seconds: secs, on: localToday(new Date(now)) })
        closed.push(e)
      }
      this.save(task)
    }
    return closed
  }

  private startTaskTimer(taskId: string): { ok: true; entry: TimeEntry } {
    const task = this.task(taskId)
    // One timer at a time, across every task: one running elsewhere stops first.
    this.stopRunning(null)
    const entry: StoredTimeEntry = { id: randomUUID(), userId: actorNow(), startedAt: this.iso(), endedAt: null, seconds: null, note: null, billable: false, tags: [] }
    this.detail(task).time.push(entry)
    this.save(task)
    return { ok: true, entry: entryOf(entry) }
  }

  private stopTaskTimer(taskId: string): { ok: true; entry: TimeEntry | null } {
    const task = this.task(taskId)
    const closed = this.stopRunning(task)
    return { ok: true, entry: closed[0] ? entryOf(closed[0]) : null }
  }

  private addTaskTimeEntry(taskId: string, input: Record<string, unknown>): { ok: true; entry: TimeEntry } | Fail {
    const seconds = Math.floor(Number(input.seconds))
    if (!Number.isFinite(seconds) || seconds <= 0 || seconds > DAY_SECONDS) return fail('Enter a time between 1 minute and 24 hours')
    const note = typeof input.note === 'string' ? input.note.trim().slice(0, 2_000) || null : null
    const task = this.task(taskId)
    const now = this.now()
    const today = localToday(new Date(now))
    const date = typeof input.date === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(input.date) ? input.date : today
    if (date > today) return fail('That day has not happened yet')
    // Today: it ended now. Another day: midday on that day, so it sits on the day chosen.
    const ended = date === today ? now : localInstantAt(date, 12).getTime()
    const entry: StoredTimeEntry = {
      id: randomUUID(),
      userId: actorNow(),
      startedAt: this.iso(ended - seconds * 1000),
      endedAt: this.iso(ended),
      seconds,
      note,
      billable: input.billable === true,
      tags: [],
    }
    this.detail(task).time.push(entry)
    this.record(task, 'time_tracked', { seconds, on: date })
    this.save(task)
    return { ok: true, entry: entryOf(entry) }
  }

  private deleteTaskTimeEntry(taskId: string, entryId: string): Ok | Fail {
    const task = this.task(taskId)
    const d = this.detail(task)
    if (!d.time.some((e) => e.id === entryId && e.userId === actorNow())) return fail('Time entry not found or not yours')
    d.time = d.time.filter((e) => e.id !== entryId)
    this.save(task)
    return { ok: true }
  }

  private setTimeEntryTags(taskId: string, entryId: string, raw: unknown): { ok: true; tags: string[] } | Fail {
    if (!Array.isArray(raw)) return fail('Invalid tags')
    const task = this.task(taskId)
    const entry = this.detail(task).time.find((e) => e.id === entryId && e.userId === actorNow())
    if (entry === undefined) return fail('That time entry is not yours')
    const next = normalizeLabels(raw).slice(0, 10)
    const was = entry.tags.join(', ')
    entry.tags = next
    if (was !== next.join(', ')) this.record(task, 'time_tracked', { entry: entryId, tags_from: was || null, tags_to: next.join(', ') || null })
    this.save(task)
    return { ok: true, tags: next }
  }

  /* ---------------------------------------------------------------- more -- */

  private fetchTaskMore(taskId: string): { ok: true; more: TaskMore } {
    const task = this.task(taskId)
    const d = this.detail(task)
    const entryTags: Record<string, string[]> = {}
    for (const e of d.time) if (e.tags.length > 0) entryTags[e.id] = [...e.tags]
    return {
      ok: true,
      more: {
        // Only you see a task on this computer: you hear everything on it, and there is nobody else to add.
        followers: [{ userId: ME_ID, since: this.iso(task.createdAt) }],
        iFollow: true,
        reminders: d.reminders.filter((r) => !r.sentAt).map((r) => ({ id: r.id, remindAt: r.remindAt, note: r.note })),
        archivedAt: task.archivedAt != null ? this.iso(task.archivedAt) : null,
        startTime: task.startTime ?? null,
        dueTime: task.dueTime ?? null,
        syncSubtaskDates: d.syncSubtaskDates,
        labelColors: { ...this.labelColors },
        entryTags,
        remindersLive: this.deps.notify !== undefined,
        canColorTags: true,
        canRemoveFollowers: false,
      },
    }
  }

  private notFollowable(): Fail {
    return fail('Only you see tasks on this computer, so there is nobody else to follow this one — and nothing to unfollow.')
  }

  /** ⋯ → Remind me: kept until its time, then delivered by `deps.notify` (see `runDue`). */
  private setReminder(taskId: string, at: unknown, note: unknown): { ok: true; id: string } | Fail {
    const task = this.task(taskId)
    if (this.deps.notify === undefined) return fail('Nothing on this computer delivers reminders.')
    const t = typeof at === 'string' ? Date.parse(at) : Number.NaN
    if (!Number.isFinite(t)) return fail('Invalid time')
    if (t < this.now() - 60_000) return fail('That time has already passed')
    if (t > this.now() + YEAR_MS) return fail('Pick a time within a year')
    const id = randomUUID()
    this.detail(task).reminders.push({ id, remindAt: new Date(t).toISOString(), note: typeof note === 'string' && note !== '' ? note.slice(0, 500) : null, sentAt: null, attempts: 0, lastError: null, retryAt: null })
    this.save(task)
    return { ok: true, id }
  }

  private clearReminder(taskId: string, reminderId: string): Ok | Fail {
    const task = this.task(taskId)
    const d = this.detail(task)
    if (!d.reminders.some((r) => r.id === reminderId && !r.sentAt)) return fail('Reminder not found')
    d.reminders = d.reminders.filter((r) => r.id !== reminderId)
    this.save(task)
    return { ok: true }
  }

  private async setArchived(taskId: string, archived: boolean): Promise<Ok | Fail> {
    return this.update(this.task(taskId), { archived })
  }

  private routineTask(task: TaskRecord): boolean {
    const rule = task.detail?.routine ?? null
    return (rule !== null && !rule.stoppedAt) || (task.recurrence ?? null) !== null
  }

  /**
   * ⋯ → Merge: everything on this task moves onto the other, which says so,
   * and this one leaves the list — the CRM's merge, on two local tasks.
   */
  private async mergeTaskInto(taskId: string, targetId: string): Promise<Ok | Fail> {
    if (taskId === targetId) return fail('Pick another task')
    const source = this.task(taskId)
    const target = this.deps.store.byId(targetId)
    if (target === null || target.local !== true) return fail(NOT_FOUND)
    if (this.routineTask(source) || this.routineTask(target)) return fail('A repeating task cannot be merged — stop it repeating first.')
    if (source.sessionId !== null) return fail('An agent is working on this task — take it back before merging it.')
    const from = this.detail(source)
    const into = this.detail(target)
    const added: string[] = []
    for (const id of [source.assignee.kind === 'none' ? null : source.assignee.identity, ...from.people]) {
      if (id === null || id === target.assignee.identity || into.people.includes(id)) continue
      into.people.push(id)
      added.push(id)
    }
    const shift = (rows: Array<{ sortOrder: number }>, base: Array<{ sortOrder: number }>) => {
      const start = base.reduce((m, r) => Math.max(m, r.sortOrder), -1) + 1
      rows.forEach((r, i) => (r.sortOrder = start + i))
    }
    shift(from.subtasks, into.subtasks)
    into.subtasks.push(...from.subtasks)
    shift(from.checklists, into.checklists)
    into.checklists.push(...from.checklists)
    into.attachments.push(...from.attachments)
    into.comments.push(...from.comments)
    Object.assign(into.commentMeta, from.commentMeta)
    Object.assign(into.reactions, from.reactions)
    into.time.push(...from.time)
    for (const [id, f] of Object.entries(from.followers)) if (!(id in into.followers)) into.followers[id] = f
    // The fields: one of each name — the target's value wins, the source's is said in the merge line.
    const kept: string[] = []
    for (const f of from.fields) {
      if (into.fields.some((x) => sameLabel(x.label, f.label))) {
        const said = this.say(f, f.value)
        if (said !== null) kept.push(`${f.label}: ${said}`)
        continue
      }
      into.fields.push({ ...f, taskId: target.id, sortOrder: into.fields.reduce((m, x) => Math.max(m, x.sortOrder ?? -1), -1) + 1 })
    }
    // Links follow the task: its own move across, and every link to it now points at the target.
    for (const dep of from.dependencies) {
      if (dep.otherTaskId === target.id) continue
      if (!into.dependencies.some((x) => x.kind === dep.kind && x.otherTaskId === dep.otherTaskId)) into.dependencies.push(dep)
    }
    for (const other of this.locals()) {
      if (other.id === source.id || other.detail === undefined) continue
      let moved = false
      for (const dep of other.detail.dependencies) {
        if (dep.otherTaskId === source.id) {
          dep.otherTaskId = target.id
          moved = true
        }
      }
      if (moved) {
        other.detail.dependencies = other.detail.dependencies.filter((dep, i, all) => dep.otherTaskId !== other.id && all.findIndex((x) => x.kind === dep.kind && x.otherTaskId === dep.otherTaskId) === i)
        if (other.id !== target.id) this.save(other)
      }
    }
    into.dependencies = into.dependencies.filter((dep) => dep.otherTaskId !== target.id)
    from.attachments = []
    from.dependencies = []
    this.record(target, 'merged', { title: source.title, people_added: added, fields_kept: kept.slice(0, 20), ...(kept.length > 20 ? { fields_kept_more: kept.length - 20 } : {}) })
    this.save(target)
    this.save(source)
    try {
      await this.deps.local.remove(source.id)
    } catch (error) {
      if (error instanceof TaskConfigProblem) return fail(error.message)
      throw error
    }
    return { ok: true }
  }

  /** ⋯ → Convert to › Subtask: this task's first line becomes a subtask of another, and this one leaves the list. */
  private async convertToSubtask(taskId: string, parentId: string): Promise<Ok | Fail> {
    if (taskId === parentId) return fail('Pick another task')
    const source = this.task(taskId)
    const parent = this.deps.store.byId(parentId)
    if (parent === null || parent.local !== true) return fail(NOT_FOUND)
    if (this.routineTask(source)) return fail('A repeating task cannot become a subtask — stop it repeating first.')
    if (source.sessionId !== null) return fail('An agent is working on this task — take it back before converting it.')
    const title = truncateVisible(stripFileTokens(source.title).split('\n')[0].trim() || 'Untitled', VISIBLE_TITLE_MAX)
    const d = this.detail(parent)
    d.subtasks.push({
      id: randomUUID(),
      title,
      done: source.crmStatus === 'Done',
      sortOrder: d.subtasks.reduce((m, s) => Math.max(m, s.sortOrder), -1) + 1,
      assigneeUserId: source.assignee.kind === 'none' ? null : source.assignee.identity,
      priority: null,
      dueDate: null,
    })
    this.record(parent, 'subtask_added', { title })
    this.save(parent)
    try {
      await this.deps.local.remove(source.id)
    } catch (error) {
      if (error instanceof TaskConfigProblem) return fail(error.message)
      throw error
    }
    return { ok: true }
  }

  /**
   * ⋯ → Duplicate: a new task with the same text plus " (copy)", its fields of
   * the row, people, subtasks and checklists. A copy is a one-off, and it is
   * yours: a copy of an agent's task does not start that agent again — the
   * agent comes along as one of the people on it.
   */
  private async duplicateTask(taskId: string): Promise<{ ok: true; id: string } | Fail> {
    const task = this.task(taskId)
    const keepsAssignee = task.assignee.kind === 'human' || task.assignee.kind === 'none'
    let copy: TaskRecord
    try {
      copy = await this.deps.local.create({
        title: truncateVisible(`${stripFileTokens(task.title)} (copy)`, VISIBLE_TITLE_MAX),
        instructions: task.instructions,
        project: task.project,
        assignee: keepsAssignee ? task.assignee.identity : ME_ID,
        status: task.crmStatus,
        priority: task.priority ?? null,
        startDate: task.startDate ?? null,
        dueDate: task.dueDate ?? null,
        startTime: task.startTime ?? null,
        dueTime: task.dueTime ?? null,
        labels: task.labels ?? [],
        board: task.board ?? null,
        taskType: task.taskType ?? 'task',
        estimateMinutes: task.estimateMinutes ?? null,
      })
    } catch (error) {
      if (error instanceof TaskConfigProblem) return fail(error.message)
      throw error
    }
    const from = this.detail(task)
    const into = this.detail(copy)
    into.people = [...from.people, ...(keepsAssignee ? [] : [task.assignee.identity])].filter((id, i, all) => id !== copy.assignee.identity && all.indexOf(id) === i)
    into.subtasks = from.subtasks.map((s) => ({ ...s, id: randomUUID() }))
    into.checklists = from.checklists.map((l) => ({ ...l, id: randomUUID(), items: l.items.map((i) => ({ ...i, id: randomUUID() })) }))
    this.save(copy)
    return { ok: true, id: copy.id }
  }

  private async setSyncSubtaskDates(taskId: string, on: boolean): Promise<{ ok: true; startDate: string | null; dueDate: string | null } | Fail> {
    const task = this.task(taskId)
    const span = on ? this.span(task) : null
    this.detail(task).syncSubtaskDates = on
    this.record(task, 'dates', { sync: on })
    this.save(task)
    if (span !== null) {
      const r = await this.syncDates(task)
      if (!r.ok) return r
    }
    return { ok: true, startDate: span?.start ?? null, dueDate: span?.due ?? null }
  }

  private async setTaskTimes(taskId: string, patch: Record<string, unknown>): Promise<Ok | Fail> {
    const task = this.task(taskId)
    const change: Record<string, unknown> = {}
    for (const key of ['startTime', 'dueTime'] as const) {
      if (!(key in patch)) continue
      const v = patch[key]
      if (v !== null && (typeof v !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d$/.test(v))) return fail('Invalid time')
      change[key] = v
    }
    if (Object.keys(change).length === 0) return fail('Nothing to update')
    return this.update(task, change)
  }

  private setLabelColor(label: unknown, color: unknown): Ok | Fail {
    const name = normalizeLabels([label])[0]
    if (!name) return fail('Invalid tag')
    if (typeof color !== 'string' || !(LABEL_COLORS as readonly string[]).includes(color)) return fail('Invalid colour')
    this.labelColors[name.toLowerCase()] = color as LabelColor
    this.saveLabels()
    return { ok: true }
  }

  private async deleteLabelEverywhere(label: unknown): Promise<{ ok: true; removed: number; keptElsewhere: number; taskIds: string[] } | (Fail & { taskIds?: string[] })> {
    const name = normalizeLabels([label])[0]
    if (!name) return fail('Invalid tag')
    const low = name.toLowerCase()
    const taskIds: string[] = []
    for (const task of this.locals()) {
      const labels = task.labels ?? []
      if (!labels.some((l) => l.toLowerCase() === low)) continue
      const r = await this.update(task, { labels: labels.filter((l) => l.toLowerCase() !== low) })
      if (!r.ok) return { ok: false, error: `The tag was removed from ${taskIds.length} of your tasks, then stopped — try again.`, taskIds }
      taskIds.push(task.id)
    }
    if (low in this.labelColors) {
      delete this.labelColors[low]
      this.saveLabels()
    }
    return { ok: true, removed: taskIds.length, keptElsewhere: 0, taskIds }
  }

  /* ------------------------------------------------------------ routines -- */

  /**
   * A routine on a local task is KEPT — its rule, pause, stop and the next
   * dates it would fall on — but nothing makes the next copy yet: the engine
   * that spawns occurrences is a later stage.
   */
  private routineView(task: TaskRecord): RoutineView {
    const { root, rule } = this.resolveRoutine(task)
    const d = this.detail(root)
    const today = this.today()
    const rows = this.history(root)
    const stuck = this.stuck(root, rule)
    const own = rows.find((r) => r.taskId === task.id && r.status !== 'skipped') ?? null
    const anchor = rule === null ? null : rule.trigger === 'schedule' ? this.scheduleAnchor(root, rule, rows) : routineAnchor(rule, { rootDue: root.dueDate ?? null, oldest: rows.length > 0 ? rows[rows.length - 1].date : null, taskDue: task.dueDate ?? null, today })
    let next: string[] = []
    if (rule !== null && isActive(rule) && stuck === null) {
      const from = rule.trigger === 'schedule' ? (rows[0]?.date ?? anchor ?? today) : (task.dueDate ?? today)
      next = upcoming(from, anchor === null ? rule : { ...rule, anchor }, 3, this.datesSoFar(root))
    }
    return {
      rootTaskId: root.id,
      rootTitle: root.title,
      isRoot: root.id === task.id,
      rule,
      canEdit: true,
      history: rows.map((r) => ({
        id: r.id,
        occurrenceDate: r.date,
        dueDate: r.dueDate,
        assigneeUserId: r.person,
        spawnedTaskId: r.taskId,
        status: r.status,
        completedAt: r.completedAt,
        completedBy: r.completedBy,
        who: r.person === null ? null : this.named(r.person).name,
      })),
      historyError: null,
      lastError: d.routineError,
      next,
      peopleCount: this.everyoneOn(root).length,
      version: d.routineVersion,
      stuck,
      canRestart: stuck !== null,
      anchor,
      occurrence: own?.date ?? null,
      datesSoFar: this.datesSoFar(root),
    }
  }

  private fetchRoutine(taskId: string): { ok: true; routine: RoutineView } {
    return { ok: true, routine: this.routineView(this.task(taskId)) }
  }

  private writeRoutine(task: TaskRecord, rule: RoutineRule | null): void {
    const d = this.detail(task)
    d.routine = rule
    d.routineVersion += 1
    const recurrence: TaskRecurrence | null = rule !== null && !rule.stoppedAt ? legacyRecurrence(rule) : null
    this.record(task, 'recurrence', { to: rule !== null && !rule.stoppedAt ? routineSummary(rule) : null })
    this.deps.store.update(task, { recurrence })
    this.save(task)
  }

  /** The routine a task belongs to is changed on its own task — from any of its copies too, as the CRM's. */
  private routineRoot(taskId: string): TaskRecord {
    return this.resolveRoutine(this.task(taskId)).root
  }

  private saveRoutine(taskId: string, raw: unknown, version: unknown): { ok: true; rootTaskId: string; version: number } | Fail {
    const task = this.routineRoot(taskId)
    const d = this.detail(task)
    if (typeof version === 'number' && version !== d.routineVersion) return fail('This routine was changed since it was opened — reload and try again.')
    if (raw === null || raw === undefined) {
      this.writeRoutine(task, null)
      return { ok: true, rootTaskId: task.id, version: d.routineVersion }
    }
    const today = this.today()
    const refusal = typeof raw === 'object' ? routineRefusal(raw as RoutineRule, today) : 'Choose how often it repeats.'
    if (refusal !== null) return fail(refusal)
    const rule = normalizeRoutine(raw, null)
    if (rule === null) return fail('Choose how often it repeats.')
    this.writeRoutine(task, { ...rule, anchor: rule.anchor ?? task.dueDate ?? today, pausedAt: null, stoppedAt: null, rootTaskId: null })
    this.setRoutineError(task, null)
    return { ok: true, rootTaskId: task.id, version: d.routineVersion }
  }

  private stopRoutine(taskId: string): Ok | Fail {
    const task = this.routineRoot(taskId)
    const rule = this.detail(task).routine
    if (rule === null || rule.stoppedAt) return fail('This task does not repeat.')
    this.writeRoutine(task, { ...rule, stoppedAt: this.iso() })
    return { ok: true }
  }

  private pauseRoutine(taskId: string, paused: boolean): Ok | Fail {
    const task = this.routineRoot(taskId)
    const d = this.detail(task)
    const rule = d.routine
    if (rule === null || rule.stoppedAt) return fail('This task does not repeat.')
    d.routine = { ...rule, pausedAt: paused ? this.iso() : null }
    d.routineVersion += 1
    this.save(task)
    return { ok: true }
  }

  /**
   * Restart a stuck status routine (the CRM's `restartStatusRoutine`): the
   * next date as if finished today — a new task (Create new task on), or the
   * routine's own task back — and every finished task of it now points at
   * the new one, so finishing it again never makes a second.
   */
  private async restartRoutine(taskId: string): Promise<{ ok: true; taskId: string } | Fail> {
    const root = this.routineRoot(taskId)
    const rule = this.detail(root).routine
    if (rule === null || !isActive(rule) || rule.trigger !== 'status') return fail('This routine cannot be restarted.')
    if (root.archivedAt != null) return fail('This routine’s task is archived — restore it first.')
    if (this.stuck(root, rule) === null) return fail('This routine is not stuck: one of its tasks is still open.')
    const rows = this.history(root)
    const today = this.today()
    const anchor = routineAnchor(rule, { rootDue: root.dueDate ?? null, oldest: rows.length > 0 ? rows[rows.length - 1].date : null, taskDue: root.dueDate ?? null, today })
    const base = nextMovesWithDue(rule) ? anchor : today
    // Never a date one of its tasks already stands for — its history's, or a task's own due date.
    const taken = new Set([...rows.filter((r) => r.status !== 'skipped').map((r) => r.date), ...this.chainOf(root).flatMap((t) => (t.dueDate ? [t.dueDate] : []))])
    let date = nextAfter(base, rule, today)
    for (let i = 0; i < 5000 && taken.has(date); i++) date = nextAfter(base, rule, date)
    if (isPastEnd(rule, date, this.datesSoFar(root))) return fail('This routine has ended.')
    const startDate = this.withLead(root.startDate, root.dueDate, date)
    if (!rule.createNew) {
      this.detail(root).occurrences.push({ id: randomUUID(), date, dueDate: date, person: null, taskId: root.id, status: 'open', completedAt: null, completedBy: null })
      this.detail(root).nextId = null
      this.record(root, 'recurrence', { restarted: true })
      this.save(root)
      const why = await this.bringBack(root, rule, date, startDate)
      if (why !== null) return fail(`It could not be brought back: ${why}`)
      this.setRoutineError(root, null)
      return { ok: true, taskId: root.id }
    }
    const made = await this.makeCopy(root, root, rule, date, startDate, null)
    if ('error' in made) return fail(`The next one could not be made: ${made.error}`)
    for (const t of this.chainOf(root)) {
      if (t.id === made.id || this.detail(t).nextId !== null) continue
      this.detail(t).nextId = made.id
      this.save(t)
    }
    this.record(root, 'recurrence', { restarted: true })
    this.save(root)
    this.setRoutineError(root, null)
    return { ok: true, taskId: made.id }
  }

  private setTaskRecurrence(taskId: string, recurrence: unknown, rule: unknown): Ok | Fail {
    if (recurrence !== null && !isTaskRecurrence(recurrence)) return fail('Invalid recurrence')
    const task = this.routineRoot(taskId)
    const d = this.detail(task)
    d.recurrenceRule = recurrence !== null && rule !== null && typeof rule === 'object' ? normalizeRecurrenceRule(rule) : null
    this.writeRoutine(task, recurrence === null ? null : { ...ruleFromLegacy(recurrence), anchor: task.dueDate ?? localToday(new Date(this.now())) })
    return { ok: true }
  }

  /* -------------------------------------------------------------- search -- */

  private searchTags(area: string, raw: string): { ok: true; hits: TagHit[] } {
    const q = raw.trim().toLowerCase()
    if (q.length < MIN_SEARCH) return { ok: true, hits: [] }
    if (area === 'person') {
      return {
        ok: true,
        hits: this.people()
          .filter((p) => p.name.toLowerCase().includes(q))
          .map((p) => ({ area: 'person', id: p.id, label: p.name, secondary: p.id === ME_ID ? 'You' : p.id === HOOT_ID ? 'Hoot' : 'Task agent', href: `/people/${encodeURIComponent(p.id)}` })),
      }
    }
    if (area === 'task') {
      return {
        ok: true,
        hits: this.locals()
          .filter((t) => t.title.toLowerCase().includes(q))
          .sort((a, b) => b.updatedAt - a.updatedAt)
          .slice(0, 20)
          .map((t) => ({ area: 'task', id: t.id, label: t.title, secondary: t.board ?? null, status: t.crmStatus, href: `/tasks?task=${encodeURIComponent(t.id)}` })),
      }
    }
    if (area === 'file') {
      const hits: TagHit[] = []
      for (const t of this.locals()) {
        for (const a of t.detail?.attachments ?? []) {
          if (a.kind !== 'upload' || !a.fileName.toLowerCase().includes(q)) continue
          hits.push({ area: 'file', id: `${t.id}/${a.id}`, label: a.fileName, secondary: t.title, href: `/files/${encodeURIComponent(t.id)}/${encodeURIComponent(a.id)}` })
        }
      }
      return { ok: true, hits: hits.slice(0, 20) }
    }
    return { ok: true, hits: [] }
  }

  /* ------------------------------------------------------ project folder -- */

  private async setTaskProject(taskId: string, path: unknown): Promise<{ ok: true; project: string } | Fail> {
    if (typeof path !== 'string') return fail('Choose a folder.')
    const task = this.task(taskId)
    const r = await this.update(task, { project: path })
    return r.ok ? { ok: true, project: task.project } : r
  }

  /** The Mac's folder chooser; cancelled, nothing changes (`chosen: false`). */
  private async chooseTaskProject(taskId: string): Promise<{ ok: true; project: string; chosen: boolean } | Fail> {
    const task = this.task(taskId)
    const folder = await this.deps.chooseFolder()
    if (folder === null) return { ok: true, project: task.project, chosen: false }
    const r = await this.update(task, { project: folder })
    return r.ok ? { ok: true, project: task.project, chosen: true } : r
  }

  /* ---------------------------------------------------------- tag colours -- */

  private labelFile(): string | null {
    return this.deps.filesDir === null ? null : join(dirname(this.deps.filesDir), LABEL_FILE)
  }

  private loadLabels(): void {
    const file = this.labelFile()
    if (file === null || !existsSync(file)) return
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as { v?: number; labelColors?: Record<string, unknown> }
      if (raw.v !== 1 || typeof raw.labelColors !== 'object' || raw.labelColors === null) return
      for (const [key, color] of Object.entries(raw.labelColors)) {
        if (typeof color === 'string' && (LABEL_COLORS as readonly string[]).includes(color)) this.labelColors[key] = color as LabelColor
      }
    } catch (error) {
      console.error('[tasks] could not read the tag colours; starting without:', error)
    }
  }

  private saveLabels(): void {
    const file = this.labelFile()
    if (file === null) return
    try {
      writeSecretFile(dirname(file), file, `${JSON.stringify({ v: 1, labelColors: this.labelColors })}\n`)
    } catch (error) {
      console.error('[tasks] could not save the tag colours:', error)
    }
  }
}

function entryOf(e: StoredTimeEntry): TimeEntry {
  return { id: e.id, userId: e.userId, startedAt: e.startedAt, endedAt: e.endedAt, seconds: e.seconds, note: e.note, billable: e.billable }
}
