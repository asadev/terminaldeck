/**
 * The one channel the task popup talks to the main process through.
 *
 * The popup is the reference CRM's task page, copied. In the CRM every read and
 * write it makes is a server action, gathered into one injectable bundle
 * (`DetailActions`, plus `TaskFieldActions` for custom fields). Here each of
 * those functions becomes one call on {@link LOCAL_DETAIL_CHANNEL}: its name
 * and its arguments, answered by `src/main/tasks/task-detail-local.ts` with the
 * CRM function's own result shape.
 *
 * A few calls exist only here, because a local task's people, files and
 * search live on this computer rather than behind a CRM's web routes:
 * `uploadTaskFile` carries the bytes ({@link LocalUpload}), `chooseTaskFiles`
 * opens the Mac's file chooser, `openTaskFile` opens a file in the Mac's own
 * app for it, `searchTags` answers the CRM's record search from local tasks,
 * people and files, and `setTaskProject` sets the folder an agent works in.
 */

import type { TaskAssignee } from './tasks-data'
import { AVATAR_PALETTE, deriveInitials, hashStringToIndex } from './task-people'

export const LOCAL_DETAIL_CHANNEL = 'tasks:local-detail'

/** Every function the channel answers. */
export const LOCAL_DETAIL_FNS = [
  // the CRM's DetailActions
  'fetchTaskDetailBundle',
  'listTaskComments',
  'listTaskActivity',
  'setTaskStatus',
  'updateTask',
  'assignTask',
  'addTaskAssignee',
  'removeTaskAssignee',
  'addTaskSubtask',
  'setTaskSubtaskDone',
  'deleteTaskSubtask',
  'setTaskSubtaskAssignee',
  'addChecklist',
  'renameChecklist',
  'deleteChecklist',
  'addChecklistItem',
  'setChecklistItemDone',
  'setChecklistItemAssignee',
  'deleteChecklistItem',
  'addTaskDependency',
  'removeTaskDependency',
  'attachExistingDocument',
  'detachTaskAttachment',
  'uploadTaskFile',
  'addTaskComment',
  'fetchTaskPageExtras',
  'setTaskType',
  'setTaskLabels',
  'setTaskLinks',
  'moveTask',
  'setTimeEstimate',
  'setTaskRecurrence',
  'setSubtaskMeta',
  'startTaskTimer',
  'stopTaskTimer',
  'addTaskTimeEntry',
  'deleteTaskTimeEntry',
  'duplicateTask',
  'fetchRoutine',
  'saveRoutine',
  'stopRoutine',
  'pauseRoutine',
  'restartRoutine',
  'fetchTaskMore',
  'setFollowing',
  'addFollower',
  'removeFollower',
  'setReminder',
  'clearReminder',
  'setArchived',
  'mergeTaskInto',
  'convertToSubtask',
  'setSyncSubtaskDates',
  'setTaskTimes',
  'setLabelColor',
  'deleteLabelEverywhere',
  'setTimeEntryTags',
  'fetchDescriptionHistory',
  'fetchCommentExtras',
  'addTaskCommentWith',
  'toggleCommentReaction',
  'setCommentResolved',
  'assignComment',
  'sendScheduledNow',
  // the CRM's TaskFieldActions
  'listTaskFields',
  'createTaskField',
  'updateTaskFieldValue',
  'renameTaskField',
  'updateTaskFieldConfig',
  'reorderTaskFields',
  'deleteTaskField',
  'toggleTaskFieldVote',
  'pressTaskFieldButton',
  // only here
  'chooseTaskFiles',
  'openTaskFile',
  'searchTags',
  'setTaskProject',
  'chooseTaskProject',
] as const

export type LocalDetailFn = (typeof LOCAL_DETAIL_FNS)[number]

export function isLocalDetailFn(value: unknown): value is LocalDetailFn {
  return typeof value === 'string' && (LOCAL_DETAIL_FNS as readonly string[]).includes(value)
}

/** A file the window hands over — from a drop, a paste or the comment box's clip. */
export interface LocalUpload {
  name: string
  type: string
  bytes: Uint8Array
}

/** The person at this computer, as the CRM's people know them. */
export const ME_ID = 'me'
export const HOOT_ID = 'hoot'

/** One of the people a local task can have: you, Hoot, or one of your task agents. */
export function localPerson(id: string, name: string): TaskAssignee {
  return {
    id,
    name,
    initials: id === ME_ID ? 'ME' : deriveInitials(name),
    color: AVATAR_PALETTE[hashStringToIndex(id, AVATAR_PALETTE.length)],
    avatarUrl: null,
  }
}

/** Everyone a local task can name: you, Hoot, then your task agents in their own order. */
export function localPeople(agents: ReadonlyArray<{ id: string; name: string }>): TaskAssignee[] {
  return [localPerson(ME_ID, 'You'), localPerson(HOOT_ID, 'Hoot'), ...agents.map((agent) => localPerson(agent.id, agent.name))]
}
