/**
 * A task's own workspace, in its detail: the separate copy of the project an
 * agent works in for this task (a git worktree on a branch of its own), with
 * its folder, its branch and whether it is still there.
 *
 * Two actions, both answered by `src/main/workspaces/workspaces-ipc.ts` by task
 * id alone: open the folder in the Mac's own file browser, and remove the
 * workspace — which the main process does only when it holds no uncommitted
 * changes and no session is running in it, and otherwise keeps, saying why.
 * The branch is never removed, so a task's commits outlive its folder.
 */

import { useCallback, useEffect, useMemo, useState, type ReactElement } from 'react'

/** The three calls, as `window.deck` offers them. */
export interface WorkspaceBridge {
  taskWorkspace(taskId: string): Promise<unknown>
  taskWorkspaceOpen(taskId: string): Promise<unknown>
  taskWorkspaceRemove(taskId: string): Promise<unknown>
}

export type WorkspaceState = 'active' | 'kept' | 'removed'

export interface WorkspaceShown {
  /** The folder the task runs in. */
  folder: string
  branch: string
  repo: string
  state: WorkspaceState
  /** Why it was kept, or what removing it left behind. */
  reason: string | null
}

export interface WorkspaceViewModel {
  workspace: WorkspaceShown | null
  /** Why the task runs in its project folder although it asked for a workspace. */
  refusal: string | null
}

/** What an action said, under the row. */
export interface WorkspaceNote {
  ok: boolean
  text: string
}

const NONE: WorkspaceViewModel = { workspace: null, refusal: null }

const STATE_WORDS: Record<WorkspaceState, string> = { active: 'Active', kept: 'Kept', removed: 'Removed' }

/** The bridge from `window.deck`, or null in a build (or a test) without it. */
export function windowWorkspaceBridge(): WorkspaceBridge | null {
  const deck = (globalThis as unknown as { deck?: Partial<WorkspaceBridge> }).deck
  if (
    deck === undefined ||
    typeof deck.taskWorkspace !== 'function' ||
    typeof deck.taskWorkspaceOpen !== 'function' ||
    typeof deck.taskWorkspaceRemove !== 'function'
  ) {
    return null
  }
  const host = deck as WorkspaceBridge
  return {
    taskWorkspace: (taskId) => host.taskWorkspace(taskId),
    taskWorkspaceOpen: (taskId) => host.taskWorkspaceOpen(taskId),
    taskWorkspaceRemove: (taskId) => host.taskWorkspaceRemove(taskId),
  }
}

function text(value: unknown): string | null {
  return typeof value === 'string' ? value : null
}

/** What the main process sent, checked: the shapes cross the bridge as `unknown`. */
export function workspaceViewOf(value: unknown): WorkspaceViewModel {
  if (typeof value !== 'object' || value === null) return NONE
  const raw = value as { workspace?: unknown; refusal?: unknown }
  const refusal = text(raw.refusal)
  const w = raw.workspace as Record<string, unknown> | null | undefined
  if (typeof w !== 'object' || w === null) return { workspace: null, refusal }
  const folder = text(w.folder)
  const branch = text(w.branch)
  const repo = text(w.repo)
  const state = w.state === 'active' || w.state === 'kept' || w.state === 'removed' ? w.state : null
  if (folder === null || branch === null || repo === null || state === null) return { workspace: null, refusal }
  return { workspace: { folder, branch, repo, state, reason: text(w.reason) }, refusal }
}

/** Whether the task has anything to show here: a workspace, or why it has none. */
export function showsWorkspace(view: WorkspaceViewModel | null): view is WorkspaceViewModel {
  return view !== null && (view.workspace !== null || view.refusal !== null)
}

/**
 * The calls, each settling to what the row shows next — never a rejection the
 * row would have to catch.
 */
export function workspaceActions(bridge: WorkspaceBridge | null, taskId: string): {
  load(): Promise<WorkspaceViewModel>
  open(): Promise<WorkspaceNote | null>
  remove(): Promise<{ view: WorkspaceViewModel | null; note: WorkspaceNote }>
} {
  const failure = (error: unknown): WorkspaceNote => ({ ok: false, text: error instanceof Error ? error.message : String(error) })
  return {
    load: async () => {
      if (bridge === null) return NONE
      try {
        return workspaceViewOf(await bridge.taskWorkspace(taskId))
      } catch {
        return NONE
      }
    },
    open: async () => {
      if (bridge === null) return { ok: false, text: 'This build cannot open folders.' }
      try {
        const answer = (await bridge.taskWorkspaceOpen(taskId)) as { ok?: unknown; error?: unknown } | null
        return answer?.ok === true ? null : { ok: false, text: text(answer?.error) ?? 'The folder could not be opened.' }
      } catch (error) {
        return failure(error)
      }
    },
    remove: async () => {
      if (bridge === null) return { view: null, note: { ok: false, text: 'This build cannot remove workspaces.' } }
      try {
        const answer = (await bridge.taskWorkspaceRemove(taskId)) as { ok?: unknown; message?: unknown; view?: unknown } | null
        return {
          view: answer?.view === undefined ? null : workspaceViewOf(answer.view),
          note: { ok: answer?.ok === true, text: text(answer?.message) ?? 'The workspace could not be removed.' },
        }
      } catch (error) {
        return { view: null, note: failure(error) }
      }
    },
  }
}

/**
 * The task's workspace, read when the task opens and again whenever it changes
 * (`version`: the task's `updatedAt`), since a start can make one.
 */
export function useTaskWorkspace(
  taskId: string,
  version: number,
  bridge: WorkspaceBridge | null,
): {
  view: WorkspaceViewModel | null
  busy: boolean
  note: WorkspaceNote | null
  open(): void
  remove(): void
} {
  const actions = useMemo(() => workspaceActions(bridge, taskId), [bridge, taskId])
  // Each held with the task it is about: ▲ ▼ move the popup to another task
  // without remounting it, and one task's row must never show another's.
  const [view, setView] = useState<{ taskId: string; view: WorkspaceViewModel } | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [note, setNote] = useState<{ taskId: string; note: WorkspaceNote | null } | null>(null)

  useEffect(() => {
    let alive = true
    void actions.load().then((next) => {
      if (alive) setView({ taskId, view: next })
    })
    return () => {
      alive = false
    }
  }, [actions, taskId, version])

  const open = useCallback(() => {
    void actions.open().then((said) => setNote({ taskId, note: said }))
  }, [actions, taskId])

  const remove = useCallback(() => {
    setBusy(taskId)
    setNote(null)
    void actions.remove().then(({ view: next, note: said }) => {
      if (next !== null) setView({ taskId, view: next })
      setNote({ taskId, note: said })
      setBusy(null)
    })
  }, [actions, taskId])

  return {
    view: view?.taskId === taskId ? view.view : null,
    busy: busy === taskId,
    note: note?.taskId === taskId ? note.note : null,
    open,
    remove,
  }
}

/** The row's content: branch, state and folder, the two actions, and what was last said. */
export function WorkspaceCell({
  view,
  busy = false,
  note = null,
  onOpen,
  onRemove,
}: {
  view: WorkspaceViewModel
  busy?: boolean
  note?: WorkspaceNote | null
  onOpen(): void
  onRemove(): void
}): ReactElement {
  const workspace = view.workspace
  if (workspace === null) {
    return (
      <span className="min-w-0 flex-1 text-sm text-slate-500" data-testid="workspace-cell">
        None. {view.refusal}
      </span>
    )
  }
  const there = workspace.state !== 'removed'
  // The note an action left says the same as the reason, newer; one line, not two.
  const below = note ?? (workspace.reason === null ? null : { ok: workspace.state !== 'kept', text: workspace.reason })
  return (
    <span className="flex min-w-0 flex-1 flex-col gap-1 py-1" data-testid="workspace-cell">
      <span className="flex min-w-0 items-center gap-2">
        <span className="min-w-0 truncate font-mono text-xs text-slate-800" title={`Branch ${workspace.branch} in ${workspace.repo}`}>
          {workspace.branch}
        </span>
        <span className={workspace.state === 'kept' ? 'shrink-0 text-xs text-amber-700' : 'shrink-0 text-xs text-slate-500'}>
          {STATE_WORDS[workspace.state]}
        </span>
        {there && (
          <>
            <button type="button" onClick={onOpen} className="btn btn-secondary btn-sm shrink-0">
              Open folder
            </button>
            <button
              type="button"
              onClick={onRemove}
              disabled={busy}
              title="Removes the folder only if it has no uncommitted changes and nothing is running in it. The branch stays."
              className="btn btn-secondary btn-sm shrink-0"
            >
              {busy ? 'Removing…' : 'Remove when clean'}
            </button>
          </>
        )}
      </span>
      {/* Its own line: the folder is what someone opens, and beside the actions it got no width. */}
      <span className="min-w-0 truncate text-xs text-slate-500" title={workspace.folder} data-testid="workspace-folder">
        {workspace.folder}
      </span>
      {below !== null && (
        <span
          role={below.ok ? 'status' : 'alert'}
          className={below.ok ? 'text-xs text-slate-500' : 'text-xs text-amber-700'}
          data-testid="workspace-note"
        >
          {below.text}
        </span>
      )}
    </span>
  )
}
