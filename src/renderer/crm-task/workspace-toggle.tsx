/**
 * "Own workspace": whether a task's agent works in a separate copy of the
 * project — a git worktree on a branch of its own — instead of the project
 * folder, so two agents on one project never edit the same checkout.
 *
 * It sits in the Project folder row because it is a choice about that folder.
 * The workspace itself, once one is made, has its own row below (its branch,
 * its folder, open and remove). Changing the choice takes effect at the next
 * start; a task that already has a workspace keeps using it until that is
 * removed, so its work is never split across two folders.
 *
 * Saved through `tasks:local-update` with `useWorkspace`, the same change any
 * other field of the task goes through.
 */

import { useEffect, useState, type ReactElement } from 'react'
import { resolveTasksBridge, toTasksResult, type TaskRow } from '../tasks/tasks-model'

export type SaveTask = (taskId: string, patch: Record<string, unknown>) => Promise<unknown>

/** The window's own update, or null in a build (or a test) without it. */
function windowSave(): SaveTask | null {
  const update = resolveTasksBridge().tasksLocalUpdate
  return update === undefined ? null : (taskId, patch) => update(taskId, patch)
}

/** Save the choice; a refusal comes back as its sentence, never as a throw. */
export async function saveWorkspaceChoice(send: SaveTask, taskId: string, on: boolean): Promise<{ ok: boolean; message: string | null }> {
  try {
    const result = toTasksResult(await send(taskId, { useWorkspace: on }))
    return { ok: result.ok, message: result.ok ? null : result.message }
  } catch (error) {
    return { ok: false, message: error instanceof Error ? error.message : String(error) }
  }
}

export function WorkspaceToggle({ task, save }: { task: TaskRow; save?: SaveTask | null }): ReactElement | null {
  const [on, setOn] = useState(task.useWorkspace === true)
  const [problem, setProblem] = useState<string | null>(null)
  // The main process's next state is the truth; follow it when it arrives.
  useEffect(() => setOn(task.useWorkspace === true), [task.id, task.useWorkspace])
  const send = save === undefined ? windowSave() : save
  if (send === null) return null
  const change = async (next: boolean): Promise<void> => {
    setOn(next)
    setProblem(null)
    const result = await saveWorkspaceChoice(send, task.id, next)
    if (!result.ok) {
      setOn(!next)
      setProblem(result.message)
    }
  }
  return (
    <>
      <label
        className="inline-flex shrink-0 cursor-pointer select-none items-center gap-1 text-xs text-slate-600"
        title="The agent works in a separate copy of the project (a git worktree on its own branch), from its next start."
      >
        <input type="checkbox" checked={on} onChange={(event) => void change(event.target.checked)} aria-label="Own workspace" />
        Own workspace
      </label>
      {problem && (
        <span role="alert" className="truncate text-xs text-rose-700" title={problem}>
          {problem}
        </span>
      )}
    </>
  )
}
