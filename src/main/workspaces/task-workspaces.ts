/**
 * A task's own working folder: a git worktree of its project's repository, on a
 * branch of its own, so two agents on two tasks in one repository never edit
 * the same files.
 *
 * ## What it never touches
 *
 * The person's own checkout. `git worktree add -b <branch> <folder> <commit>`
 * writes a new folder, a new branch and git's note of the worktree under
 * `.git/worktrees/`; it does not move HEAD, stage anything, change a file in the
 * working tree or touch the stash. The commit is the repository's HEAD when the
 * task first asked, read as an id so nothing in between can change what it
 * means. A branch or folder name already taken is skipped past, never reused or
 * moved.
 *
 * ## Where it lives
 *
 * `<userData>/workspaces/<repoKey>/<task folder>`, so every workspace of one
 * repository sits together and none of them is inside a project folder, where a
 * project-wide search or an editor would find a second copy of everything.
 *
 * ## When it goes
 *
 * Only when someone asks, and only when clean — the same `git status` check
 * `git worktree remove` makes itself, run first so the answer is a sentence
 * rather than git's refusal. Never `--force`. A workspace with uncommitted
 * changes, or with a session still running in it, stays `kept` with the reason.
 * The branch always stays: removing a workspace never removes a commit. A
 * workspace whose folder was deleted some other way is marked removed, with that
 * said, the next time it is looked at — never shown as if it were still there.
 *
 * ## A folder that is not a repository
 *
 * Gets no workspace. The task runs in the project folder, and the reason is kept
 * where the task's detail can show it.
 */

import { existsSync, mkdirSync, readdirSync, realpathSync, rmdirSync } from 'node:fs'
import { dirname, isAbsolute, join, relative, sep } from 'node:path'
import { BRAND } from '../../shared/brand'
import type { WorkspaceProvider } from '../../shared/agent-stack'
import { userDataDir } from '../platform/paths'
import { runWorkspaceGit, type GitOutcome, type GitRunner } from './workspace-git'
import { branchFor, folderNameOf, repoKeyOf, WORKSPACES_DIR, WORKSPACES_FILE } from './workspace-names'
import { WorkspaceStore, type WorkspaceRecord } from './workspace-store'

/** Names tried before giving up on finding a free branch or folder. */
const MAX_ATTEMPTS = 50

/** Changed paths named in a "kept" reason; the rest are counted. */
const NAMED_CHANGES = 5

export interface TaskWorkspaceView extends WorkspaceRecord {
  /** The folder the task runs in: the project's place inside the workspace. */
  folder: string
}

/** What the task detail shows. */
export interface WorkspaceView {
  workspace: TaskWorkspaceView | null
  /** Why the task runs in its project folder although it asked for a workspace. */
  refusal: string | null
}

export interface RemoveOutcome {
  ok: boolean
  /** What happened, in words: what was removed and what stays, or why it was kept. */
  message: string
  view: WorkspaceView
}

export interface TaskWorkspacesOptions {
  /** `<userData>`. */
  userData: string
  git?: GitRunner
  now?: () => number
}

type Made = { record: WorkspaceRecord } | { reason: string }

function realOrSelf(path: string): string {
  try {
    return realpathSync(path)
  } catch {
    return path
  }
}

/** `child` is `root` or inside it. */
function within(root: string, child: string): boolean {
  return child === root || child.startsWith(root.endsWith(sep) ? root : `${root}${sep}`)
}

function plural(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`
}

/** Why a folder gets no workspace, from what git said about it. */
function notRepoReason(folder: string, outcome: GitOutcome): string {
  const after = 'so the task runs in the project folder itself.'
  if (outcome.missing) return `git is not installed, or not on the login PATH, ${after}`
  if (/dubious ownership/i.test(outcome.stderr)) return `git will not read ${folder} because it belongs to another user, ${after}`
  if (/not a git repository/i.test(outcome.stderr)) return `${folder} is not a git repository, ${after}`
  return `git could not read ${folder} (${outcome.stderr}), ${after}`
}

export class TaskWorkspaces implements WorkspaceProvider {
  private readonly store: WorkspaceStore
  private readonly userData: string
  private readonly root: string
  private readonly git: GitRunner
  private readonly now: () => number
  /** One change at a time per task: a start and a removal never interleave. */
  private readonly queue = new Map<string, Promise<void>>()

  constructor(options: TaskWorkspacesOptions) {
    // The real path, because git records and reports real paths, and a session's
    // folder is compared with what is recorded here.
    this.userData = realOrSelf(options.userData)
    this.root = join(this.userData, WORKSPACES_DIR)
    this.store = new WorkspaceStore(join(this.root, WORKSPACES_FILE))
    this.git = options.git ?? runWorkspaceGit
    this.now = options.now ?? Date.now
  }

  /**
   * The folder a task runs in. Its workspace when it has one — made now, when it
   * asked for one and has none — else null for the project folder.
   *
   * A workspace the task already has is used whether or not it still asks: its
   * work is in there, and running it elsewhere would split one task's changes
   * across two trees. Removing it is how a task goes back to the project folder.
   */
  folderFor(task: { id: string; project: string; useWorkspace: boolean }, title = ''): Promise<string | null> {
    return this.serial(task.id, async () => {
      const project = realOrSelf(task.project)
      const current = await this.current(task.id)
      if (current !== null) {
        if (current.project !== project) {
          if (task.useWorkspace) {
            this.refuse(
              task.id,
              project,
              `This task's workspace is a copy of ${current.repo}, made for ${current.project}, and its project is now ${project}. ` +
                'Remove that workspace to make one for the new folder.',
            )
          }
          return null
        }
        if (current.state === 'kept') this.store.put({ ...current, state: 'active', reason: null, updatedAt: this.now() })
        return this.folderOf(current)
      }
      if (!task.useWorkspace) {
        // It no longer asks, so why it could not have one is no longer news.
        this.store.clearRefusal(task.id)
        return null
      }
      const made = await this.create(task.id, project, title)
      if ('reason' in made) {
        this.refuse(task.id, project, made.reason)
        return null
      }
      return this.folderOf(made.record)
    })
  }

  /** The task's workspace and why it has none, as the task detail shows it. */
  async view(taskId: string): Promise<WorkspaceView> {
    await this.serial(taskId, async () => {
      await this.current(taskId)
    })
    return this.viewNow(taskId)
  }

  /** The folder to open for a task, or null when it has no workspace on disk. */
  async folderToOpen(taskId: string): Promise<string | null> {
    const view = await this.view(taskId)
    const workspace = view.workspace
    return workspace === null || workspace.state === 'removed' ? null : workspace.folder
  }

  /**
   * Remove a task's workspace, if it is clean and nothing is running in it.
   * `liveFolders`: the folders of the sessions running now.
   */
  remove(taskId: string, liveFolders: readonly string[] = []): Promise<RemoveOutcome> {
    return this.serial(taskId, async () => {
      const found = this.store.get(taskId)
      if (found === null || found.state === 'removed') {
        return { ok: false, message: 'This task has no workspace to remove.', view: this.viewNow(taskId) }
      }
      if (!existsSync(found.path)) {
        const pruned = await this.prune(found)
        return { ok: true, message: pruned.reason ?? '', view: this.viewNow(taskId) }
      }
      const running = liveFolders.find((folder) => within(found.path, folder))
      if (running !== undefined) {
        return this.keep(found, `A session is still running in it (${running}), so it was kept. Stop that session, then remove it.`)
      }
      // The check `git worktree remove` makes itself, so the refusal is ours, in words.
      const status = await this.git(found.path, ['status', '--porcelain', '--ignore-submodules=none'], { optionalLocks: false })
      if (!status.ok) return this.keep(found, `git could not read it, so it was kept: ${status.stderr}`)
      const changes = status.stdout.split('\n').filter((line) => line.trim() !== '')
      if (changes.length > 0) {
        const named = changes.slice(0, NAMED_CHANGES).map((line) => line.slice(3)).join(', ')
        const more = changes.length > NAMED_CHANGES ? `, and ${changes.length - NAMED_CHANGES} more` : ''
        return this.keep(
          found,
          `It has ${plural(changes.length, 'uncommitted change', 'uncommitted changes')} (${named}${more}), so it was kept. ` +
            'Commit or discard them, then remove it.',
        )
      }
      const removed = await this.git(found.repo, ['worktree', 'remove', found.path])
      if (!removed.ok) return this.keep(found, `git would not remove it, so it was kept: ${removed.stderr}`)
      this.tidy(dirname(found.path))
      const record: WorkspaceRecord = {
        ...found,
        state: 'removed',
        reason: `Removed. Its branch ${found.branch} stays in ${found.repo}, with every commit made on it.`,
        updatedAt: this.now(),
      }
      this.store.put(record)
      return { ok: true, message: record.reason ?? '', view: this.viewNow(taskId) }
    })
  }

  /** Mark every workspace whose folder has gone as removed. For a start-up sweep. */
  async pruneVanished(): Promise<WorkspaceRecord[]> {
    const gone = this.store.all().filter((one) => one.state !== 'removed' && !existsSync(one.path))
    const pruned: WorkspaceRecord[] = []
    for (const { taskId } of gone) {
      // Looked at again in turn: a start or a removal queued ahead may have changed it.
      await this.serial(taskId, () => this.current(taskId))
      const after = this.store.get(taskId)
      if (after !== null && after.state === 'removed') pruned.push(after)
    }
    return pruned
  }

  /**
   * The folders of workspaces that exist: their tops, and the folders tasks run
   * in. Synchronous, for the copilot's folder checks.
   */
  liveFolders(): string[] {
    const folders = new Set<string>()
    for (const record of this.store.all()) {
      if (record.state === 'removed' || !existsSync(record.path)) continue
      folders.add(record.path)
      folders.add(this.folderOf(record))
    }
    return [...folders]
  }

  /* ------------------------------------------------------------ inside -- */

  private serial<T>(taskId: string, work: () => Promise<T>): Promise<T> {
    const before = this.queue.get(taskId) ?? Promise.resolve()
    const result = before.then(work)
    const settled = result.then(
      () => undefined,
      () => undefined,
    )
    this.queue.set(taskId, settled)
    void settled.then(() => {
      if (this.queue.get(taskId) === settled) this.queue.delete(taskId)
    })
    return result
  }

  private viewNow(taskId: string): WorkspaceView {
    const record = this.store.get(taskId)
    return {
      workspace: record === null ? null : { ...record, folder: record.state === 'removed' ? record.path : this.folderOf(record) },
      refusal: this.store.refusal(taskId)?.reason ?? null,
    }
  }

  /** The task's workspace while it exists on disk; one whose folder has gone is pruned on the way. */
  private async current(taskId: string): Promise<WorkspaceRecord | null> {
    const record = this.store.get(taskId)
    if (record === null || record.state === 'removed') return null
    if (existsSync(record.path)) return record
    await this.prune(record)
    return null
  }

  /** The project's place inside the workspace, or the workspace's top when that place is not in it. */
  private folderOf(record: WorkspaceRecord): string {
    const inside = relative(record.repo, record.project)
    if (inside === '' || inside.startsWith('..') || isAbsolute(inside)) return record.path
    const folder = join(record.path, inside)
    return existsSync(folder) ? folder : record.path
  }

  private refuse(taskId: string, project: string, reason: string): void {
    this.store.refuse({ taskId, project, reason, at: this.now() })
  }

  private keep(record: WorkspaceRecord, reason: string): RemoveOutcome {
    this.store.put({ ...record, state: 'kept', reason, updatedAt: this.now() })
    return { ok: false, message: reason, view: this.viewNow(record.taskId) }
  }

  /**
   * Said as it is: the folder went some other way. git's note of exactly this
   * worktree is cleared — `worktree remove` on a missing folder does only that,
   * where `worktree prune` would clear every stale one in the person's
   * repository — so the task can have a new one at the same place.
   */
  private async prune(record: WorkspaceRecord): Promise<WorkspaceRecord> {
    if (existsSync(record.repo)) await this.git(record.repo, ['worktree', 'remove', record.path])
    const pruned: WorkspaceRecord = {
      ...record,
      state: 'removed',
      reason: `Its folder was deleted outside ${BRAND.name}, so it is no longer used. Its branch ${record.branch} stays in ${record.repo}.`,
      updatedAt: this.now(),
    }
    this.store.put(pruned)
    return pruned
  }

  /** A repository's folder under `workspaces/` goes once its last workspace has. */
  private tidy(folder: string): void {
    try {
      if (within(this.root, folder) && folder !== this.root && readdirSync(folder).length === 0) rmdirSync(folder)
    } catch {
      /* someone else's file in it, or already gone */
    }
  }

  private async create(taskId: string, project: string, title: string): Promise<Made> {
    if (!existsSync(project)) return { reason: `The project folder ${project} does not exist, so there is nothing to make a workspace from.` }
    const top = await this.git(project, ['rev-parse', '--show-toplevel'])
    if (!top.ok) return { reason: notRepoReason(project, top) }
    const repo = realOrSelf(top.stdout.trim())
    if (within(this.userData, repo)) {
      return { reason: `${repo} is inside ${BRAND.name}'s own storage, so it is not given a workspace of its own.` }
    }
    const head = await this.git(repo, ['rev-parse', '--verify', '--quiet', 'HEAD^{commit}'])
    if (!head.ok) return { reason: `${repo} has no commits yet, so there is nothing to make a workspace from. The task runs in the project folder.` }
    const base = head.stdout.trim()

    let branch: string | null = null
    for (let attempt = 1; attempt <= MAX_ATTEMPTS && branch === null; attempt++) {
      const name = branchFor(title, taskId, attempt)
      const taken = await this.git(repo, ['show-ref', '--verify', '--quiet', `refs/heads/${name}`])
      if (!taken.ok) branch = name
    }
    if (branch === null) return { reason: `Every branch name tried for this task is already taken in ${repo}.` }

    const parent = join(this.root, repoKeyOf(repo))
    mkdirSync(parent, { recursive: true })
    let path: string | null = null
    for (let attempt = 1; attempt <= MAX_ATTEMPTS && path === null; attempt++) {
      const candidate = join(parent, folderNameOf(taskId, attempt))
      if (!existsSync(candidate)) path = candidate
    }
    if (path === null) return { reason: `Every folder name tried for this task is already taken in ${parent}.` }

    const added = await this.git(repo, ['worktree', 'add', '--quiet', '-b', branch, path, base])
    if (!added.ok) {
      this.tidy(parent)
      return { reason: `git could not make the workspace, so the task runs in the project folder: ${added.stderr}` }
    }
    const at = this.now()
    const record: WorkspaceRecord = {
      taskId,
      repo,
      path: realOrSelf(path),
      branch,
      project,
      base,
      createdAt: at,
      state: 'active',
      reason: null,
      updatedAt: at,
    }
    this.store.put(record)
    return { record }
  }
}

/* --------------------------------------------------------- the app's one -- */

let instance: { dir: string; workspaces: TaskWorkspaces } | null = null

/**
 * The app's task workspaces, under the user-data folder in use now. Built on
 * first use, as `store()` is, because that folder is not known at import time.
 */
export function taskWorkspaces(): TaskWorkspaces {
  const dir = userDataDir()
  if (instance === null || instance.dir !== dir) instance = { dir, workspaces: new TaskWorkspaces({ userData: dir }) }
  return instance.workspaces
}

/**
 * The seam the task engine is handed. `titleOf` names the task for its branch;
 * the engine's own call carries only the id.
 */
export function workspaceProvider(titleOf: (taskId: string) => string | null, workspaces: () => TaskWorkspaces = taskWorkspaces): WorkspaceProvider {
  return { folderFor: (task) => workspaces().folderFor(task, titleOf(task.id) ?? '') }
}
