/**
 * The task detail's view of a task's workspace: read it, open its folder,
 * remove it when clean.
 *
 * The window sends a task id and nothing else. The folder opened or removed is
 * always the one recorded for that task, so no path the renderer writes can
 * reach `shell.openPath` or `git worktree remove`. Only the app's own window
 * may call these, as with every other task channel.
 */

import type { InvokeRegistrar } from '../ipc-seam'
import { taskWorkspaces, type RemoveOutcome, type TaskWorkspaces, type WorkspaceView } from './task-workspaces'

export interface WorkspacesIpcDeps {
  /** The app's workspaces, unless a test hands in its own. */
  workspaces?: () => TaskWorkspaces
  /** `shell.openPath`: empty on success, else what went wrong. */
  openFolder(path: string): Promise<string>
  /** The folders of the sessions running now — a workspace with one in it is never removed. */
  liveFolders(): string[]
  isApprover(sender: unknown): boolean
}

export interface OpenOutcome {
  ok: boolean
  error?: string
}

const NO_TASK: WorkspaceView = { workspace: null, refusal: null }

export function registerWorkspacesIpc(ipcMain: InvokeRegistrar, deps: WorkspacesIpcDeps): void {
  const workspaces = deps.workspaces ?? taskWorkspaces

  const guard = (event: unknown): void => {
    if (!deps.isApprover((event as { sender?: unknown } | null)?.sender)) {
      throw new Error('workspaces: only the app’s own window may use a task’s workspace')
    }
  }

  ipcMain.handle('tasks:workspace', async (event, taskId: unknown): Promise<WorkspaceView> => {
    guard(event)
    return typeof taskId === 'string' ? await workspaces().view(taskId) : NO_TASK
  })

  ipcMain.handle('tasks:workspace-open', async (event, taskId: unknown): Promise<OpenOutcome> => {
    guard(event)
    const folder = typeof taskId === 'string' ? await workspaces().folderToOpen(taskId) : null
    if (folder === null) return { ok: false, error: 'This task has no workspace folder to open.' }
    const problem = await deps.openFolder(folder)
    return problem === '' ? { ok: true } : { ok: false, error: problem }
  })

  ipcMain.handle('tasks:workspace-remove', async (event, taskId: unknown): Promise<RemoveOutcome> => {
    guard(event)
    if (typeof taskId !== 'string') return { ok: false, message: 'That request was not understood.', view: NO_TASK }
    return await workspaces().remove(taskId, deps.liveFolders())
  })

  // Workspaces whose folders went while the app was closed are said so now, not when next opened.
  void workspaces()
    .pruneVanished()
    .catch((error: unknown) => console.error('[workspaces] could not check for deleted workspaces:', error))
}
