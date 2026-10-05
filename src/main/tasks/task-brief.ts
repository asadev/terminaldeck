/**
 * The parts of a worker's brief that come from around the task rather than
 * from the task itself: the goals it serves, and what has already been said and
 * done on it.
 *
 * A task's instructions say what to do. They rarely say why, and they never
 * carry what happened after they were written — the subtask somebody ticked,
 * the comment that changed the plan, the blocker a first try hit, the task it
 * has to wait for. An agent started without those does the work the way the
 * instructions read on the day they were typed. So the brief carries them,
 * bounded: the last few of each, each line cut short, and the whole section held
 * under {@link BRIEF_CONTEXT_CHARS} so a long-lived task does not hand its
 * worker a transcript instead of a brief.
 *
 * Pure: the engine passes the records in, and a test reads the words out.
 */

import type { Goal } from '../../shared/agent-stack'
import { isDone, linksOf } from './goal-progress'
import type { TaskNote, TaskRecord } from './task-store'

/** The most the "already on this task" section may take. */
export const BRIEF_CONTEXT_CHARS = 6_000
/** The most of one goal's description a brief carries. */
export const GOAL_DESCRIPTION_CHARS = 600
const LINE_CHARS = 400
const MAX_NOTES = 8
const MAX_COMMENTS = 8
const MAX_SUBTASKS = 20
const MAX_LINKS = 12

/** The notes worth a worker's attention; the rest (edits, status lines, assignments) are bookkeeping. */
const TOLD_KINDS: ReadonlySet<TaskNote['kind']> = new Set(['progress', 'blocker', 'question', 'completion', 'reply'])

function oneLine(text: string, max = LINE_CHARS): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length <= max ? flat : `${flat.slice(0, max)}…`
}

/**
 * The goal chain, top first: the goal everything serves down to the one this
 * task serves. `chain` is as `GoalStore.chain` answers it — this task's goal
 * first. Empty when there is none.
 */
export function goalSection(chain: readonly Goal[]): string {
  if (chain.length === 0) return ''
  const top = [...chain].reverse()
  const lines = top.map((goal, depth) => {
    const about = goal.description.trim() === '' ? '' : ` — ${oneLine(goal.description, GOAL_DESCRIPTION_CHARS)}`
    return `${'  '.repeat(depth)}- **${oneLine(goal.title, 200)}** (${goal.status})${about}`
  })
  return (
    `\n\n## The goal this serves\n\n` +
    `This task is part of the goal${top.length > 1 ? 's below, from the broadest down to the one it serves directly' : ' below'}. ` +
    `Keep the work pointed at it; say so in your summary if something in the task works against it.\n\n${lines.join('\n')}`
  )
}

/**
 * What is already on the task: its subtasks, the tasks it is linked to, and the
 * latest comments and notes. Empty when there is nothing.
 *
 * `nameOf` turns an author id (`me`, `hoot`, an agent's id) into a name.
 */
export function contextSection(task: TaskRecord, all: readonly TaskRecord[], nameOf: (id: string) => string): string {
  const parts: string[] = []
  const detail = task.detail
  const subtasks = [...(detail?.subtasks ?? [])].sort((a, b) => a.sortOrder - b.sortOrder).slice(0, MAX_SUBTASKS)
  if (subtasks.length > 0) {
    parts.push(`### Subtasks\n\n${subtasks.map((sub) => `- [${sub.done ? 'x' : ' '}] ${oneLine(sub.title)}`).join('\n')}`)
  }
  const links = linksOf(task, all).slice(0, MAX_LINKS)
  if (links.length > 0) {
    const word = { blocked_by: 'Waits for', blocks: 'Needed by', linked: 'Related to' } as const
    parts.push(
      `### Linked tasks\n\n${links
        .map((link) => `- ${word[link.kind]}: ${oneLine(link.other.title, 200)} (${isDone(link.other) ? 'done' : link.other.crmStatus || 'open'})`)
        .join('\n')}`,
    )
  }
  const comments = [...(detail?.comments ?? [])].sort((a, b) => a.at - b.at).slice(-MAX_COMMENTS)
  if (comments.length > 0) {
    parts.push(`### Latest comments\n\n${comments.map((comment) => `- ${nameOf(comment.authorUserId)}: ${oneLine(comment.body)}`).join('\n')}`)
  }
  const notes = (task.notes ?? []).filter((note) => TOLD_KINDS.has(note.kind)).slice(-MAX_NOTES)
  if (notes.length > 0) {
    parts.push(`### Latest notes\n\n${notes.map((note) => `- ${nameOf(note.by)} (${note.kind}): ${oneLine(note.text)}`).join('\n')}`)
  }
  if (parts.length === 0) return ''
  let body = parts.join('\n\n')
  if (body.length > BRIEF_CONTEXT_CHARS) body = `${body.slice(0, BRIEF_CONTEXT_CHARS)}\n…(the rest is on the task)`
  return `\n\n## Already on this task\n\nWhat people and agents have written and done on it so far, newest last.\n\n${body}`
}

/** A try after one that did not finish: what the person or Hoot said about it. */
export function retrySection(task: TaskRecord): string {
  const retry = task.retry ?? null
  if (retry === null) return ''
  const said = retry.note.trim() === '' ? '' : `\n\n${oneLine(retry.note, 2_000)}`
  return `\n\n## Tried again\n\nThis task was started before and did not finish (try ${retry.count + 1}).${said}`
}
