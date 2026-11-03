/**
 * The task popup's calls, answered on this computer.
 *
 * The popup is the reference CRM's task page, copied; it takes every read and
 * write it makes as one injectable bundle (`DetailActions`, and
 * `TaskFieldActions` for custom fields). This is that bundle for your own
 * tasks: each function is one call on the `tasks:local-detail` channel — its
 * name and the CRM function's own arguments — answered by
 * `src/main/tasks/task-detail-local.ts` with the CRM's own result shape.
 *
 * Two arguments change shape on the way: a `File` (a drop, a paste, the
 * comment box's clip) travels as its name, type and bytes, because a renderer
 * file object cannot cross to the main process.
 */

import type { DetailActions } from './detail-actions'
import type { TaskFieldActions } from './task-fields-section'
import type { LocalDetailFn, LocalUpload } from '../../shared/crm/detail-contract'
import type { TagAreaKey, TagHit } from '../../shared/crm/tag-areas'

/** The one bridge method this needs, as `window.deck` offers it. */
export type DetailBridge = (fn: LocalDetailFn, args: unknown[]) => Promise<unknown>

type Failure = { ok: false; error: string }

/** The bridge from `window.deck`, or null in a build (or a test) without it. */
export function windowDetailBridge(): DetailBridge | null {
  const deck = (globalThis as unknown as { deck?: { tasksLocalDetail?: (fn: string, args: unknown[]) => Promise<unknown> } }).deck
  const call = deck?.tasksLocalDetail
  return typeof call === 'function' ? (fn, args) => call.call(deck, fn, args) : null
}

/** Whatever came back, as the CRM's result: an answer with `ok`, or a refusal in words. */
function answer(value: unknown): unknown {
  if (typeof value === 'object' && value !== null && typeof (value as { ok?: unknown }).ok === 'boolean') return value
  return { ok: false, error: 'Terminal Deck did not answer that.' } satisfies Failure
}

/** One call: never a rejection the popup would have to catch — a failure is a sentence, as the CRM's actions give. */
export function caller(bridge: DetailBridge | null): <T>(fn: LocalDetailFn, args: unknown[]) => Promise<T> {
  return async <T>(fn: LocalDetailFn, args: unknown[]): Promise<T> => {
    if (bridge === null) return { ok: false, error: 'This build cannot change tasks.' } as T
    try {
      return answer(await bridge(fn, args)) as T
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) } as T
    }
  }
}

/** A renderer file as the main process takes it. */
export async function uploadOf(file: File): Promise<LocalUpload> {
  return { name: file.name, type: file.type, bytes: new Uint8Array(await file.arrayBuffer()) }
}

/** The CRM's DetailActions, every one sent to the main process. */
export function localDetailActions(bridge: DetailBridge | null = windowDetailBridge()): DetailActions {
  const call = caller(bridge)
  return {
    fetchTaskDetailBundle: (taskId) => call('fetchTaskDetailBundle', [taskId]),
    listTaskComments: (taskId) => call('listTaskComments', [taskId]),
    listTaskActivity: (taskId) => call('listTaskActivity', [taskId]),
    setTaskStatus: (taskId, status) => call('setTaskStatus', [taskId, status]),
    updateTask: (taskId, patch) => call('updateTask', [taskId, patch]),
    assignTask: (taskId, userId) => call('assignTask', [taskId, userId]),
    addTaskAssignee: (taskId, userId) => call('addTaskAssignee', [taskId, userId]),
    removeTaskAssignee: (taskId, userId) => call('removeTaskAssignee', [taskId, userId]),
    addTaskSubtask: (taskId, title) => call('addTaskSubtask', [taskId, title]),
    setTaskSubtaskDone: (taskId, subtaskId, done) => call('setTaskSubtaskDone', [taskId, subtaskId, done]),
    deleteTaskSubtask: (taskId, subtaskId) => call('deleteTaskSubtask', [taskId, subtaskId]),
    setTaskSubtaskAssignee: (taskId, subtaskId, userId) => call('setTaskSubtaskAssignee', [taskId, subtaskId, userId]),
    addChecklist: (taskId, title) => call('addChecklist', [taskId, title ?? null]),
    renameChecklist: (checklistId, title) => call('renameChecklist', [checklistId, title]),
    deleteChecklist: (checklistId) => call('deleteChecklist', [checklistId]),
    addChecklistItem: (checklistId, title) => call('addChecklistItem', [checklistId, title]),
    setChecklistItemDone: (itemId, done) => call('setChecklistItemDone', [itemId, done]),
    setChecklistItemAssignee: (itemId, userId) => call('setChecklistItemAssignee', [itemId, userId]),
    deleteChecklistItem: (itemId) => call('deleteChecklistItem', [itemId]),
    addTaskDependency: (taskId, otherTaskId, kind) => call('addTaskDependency', [taskId, otherTaskId, kind]),
    removeTaskDependency: (taskId, otherTaskId, kind) => call('removeTaskDependency', [taskId, otherTaskId, kind]),
    attachExistingDocument: (taskId, documentId) => call('attachExistingDocument', [taskId, documentId]),
    detachTaskAttachment: (attachmentId) => call('detachTaskAttachment', [attachmentId]),
    uploadTaskFile: async (taskId, file) => call('uploadTaskFile', [taskId, await uploadOf(file)]),
    addTaskComment: (taskId, body) => call('addTaskComment', [taskId, body]),
    fetchTaskPageExtras: (taskId) => call('fetchTaskPageExtras', [taskId]),
    setTaskType: (taskId, type) => call('setTaskType', [taskId, type]),
    setTaskLabels: (taskId, labels) => call('setTaskLabels', [taskId, labels]),
    setTaskLinks: (taskId, tags) => call('setTaskLinks', [taskId, tags]),
    moveTask: (taskId, board) => call('moveTask', [taskId, board]),
    setTimeEstimate: (taskId, minutes) => call('setTimeEstimate', [taskId, minutes]),
    setTaskRecurrence: (taskId, recurrence, rule) => call('setTaskRecurrence', [taskId, recurrence, rule]),
    setSubtaskMeta: (taskId, subtaskId, patch) => call('setSubtaskMeta', [taskId, subtaskId, patch]),
    startTaskTimer: (taskId) => call('startTaskTimer', [taskId]),
    stopTaskTimer: (taskId) => call('stopTaskTimer', [taskId]),
    addTaskTimeEntry: (taskId, input) => call('addTaskTimeEntry', [taskId, input]),
    deleteTaskTimeEntry: (taskId, entryId) => call('deleteTaskTimeEntry', [taskId, entryId]),
    duplicateTask: (taskId) => call('duplicateTask', [taskId]),
    fetchRoutine: (taskId) => call('fetchRoutine', [taskId]),
    saveRoutine: (taskId, rule, version) => call('saveRoutine', [taskId, rule, version ?? null]),
    stopRoutine: (taskId) => call('stopRoutine', [taskId]),
    pauseRoutine: (taskId, paused) => call('pauseRoutine', [taskId, paused]),
    restartRoutine: (taskId) => call('restartRoutine', [taskId]),
    fetchTaskMore: (taskId) => call('fetchTaskMore', [taskId]),
    // No setFollowing / addFollower / removeFollower: only you see a task on this computer, so the
    // popup offers no Follow, Unfollow or "add a follower" (the main side refuses them in words too).
    setReminder: (taskId, remindAtIso, note) => call('setReminder', [taskId, remindAtIso, note ?? null]),
    clearReminder: (taskId, reminderId) => call('clearReminder', [taskId, reminderId]),
    setArchived: (taskId, archived) => call('setArchived', [taskId, archived]),
    mergeTaskInto: (taskId, targetId) => call('mergeTaskInto', [taskId, targetId]),
    convertToSubtask: (taskId, parentId) => call('convertToSubtask', [taskId, parentId]),
    setSyncSubtaskDates: (taskId, on) => call('setSyncSubtaskDates', [taskId, on]),
    setTaskTimes: (taskId, patch) => call('setTaskTimes', [taskId, patch]),
    setLabelColor: (label, color) => call('setLabelColor', [label, color]),
    deleteLabelEverywhere: (label) => call('deleteLabelEverywhere', [label]),
    setTimeEntryTags: (taskId, entryId, tags) => call('setTimeEntryTags', [taskId, entryId, tags]),
    fetchDescriptionHistory: (taskId) => call('fetchDescriptionHistory', [taskId]),
    fetchCommentExtras: (taskId) => call('fetchCommentExtras', [taskId]),
    addTaskCommentWith: (taskId, body, opts) => call('addTaskCommentWith', [taskId, body, opts]),
    toggleCommentReaction: (taskId, commentId, emoji) => call('toggleCommentReaction', [taskId, commentId, emoji]),
    setCommentResolved: (taskId, commentId, resolved) => call('setCommentResolved', [taskId, commentId, resolved]),
    assignComment: (taskId, commentId, userId) => call('assignComment', [taskId, commentId, userId]),
    sendScheduledNow: (taskId, commentId) => call('sendScheduledNow', [taskId, commentId]),
    chooseTaskFiles: (taskId) => call('chooseTaskFiles', [taskId]),
    openTaskFile: (taskId, attachmentId) => call('openTaskFile', [taskId, attachmentId]),
  }
}

/** The CRM's TaskFieldActions, every one sent to the main process. */
export function localFieldActions(bridge: DetailBridge | null = windowDetailBridge()): TaskFieldActions {
  const call = caller(bridge)
  return {
    listTaskFields: (taskId) => call('listTaskFields', [taskId]),
    createTaskField: (taskId, input) => call('createTaskField', [taskId, input]),
    updateTaskFieldValue: (fieldId, value) => call('updateTaskFieldValue', [fieldId, value]),
    renameTaskField: (fieldId, label) => call('renameTaskField', [fieldId, label]),
    updateTaskFieldConfig: (fieldId, config) => call('updateTaskFieldConfig', [fieldId, config]),
    reorderTaskFields: (taskId, ids) => call('reorderTaskFields', [taskId, ids]),
    deleteTaskField: (fieldId) => call('deleteTaskField', [fieldId]),
    toggleTaskFieldVote: (fieldId) => call('toggleTaskFieldVote', [fieldId]),
    pressTaskFieldButton: (fieldId) => call('pressTaskFieldButton', [fieldId]),
    uploadTaskFile: async (taskId, file) => call('uploadTaskFile', [taskId, await uploadOf(file)]),
  }
}

/** The CRM's record search (`/api/tags/search`), answered from your tasks, people and files. */
export async function searchTagsLocally(
  area: TagAreaKey,
  query: string,
  bridge: DetailBridge | null = windowDetailBridge(),
): Promise<{ ok: true; hits: TagHit[] } | Failure> {
  return caller(bridge)<{ ok: true; hits: TagHit[] } | Failure>('searchTags', [area, query])
}

/** Local only: the folder an agent works in, typed or chosen in the Mac's own folder chooser. */
export function localProjectActions(bridge: DetailBridge | null = windowDetailBridge()): {
  setTaskProject(taskId: string, path: string): Promise<{ ok: true; project: string } | Failure>
  chooseTaskProject(taskId: string): Promise<{ ok: true; project: string } | Failure>
} {
  const call = caller(bridge)
  return {
    setTaskProject: (taskId, path) => call('setTaskProject', [taskId, path]),
    chooseTaskProject: (taskId) => call('chooseTaskProject', [taskId]),
  }
}
