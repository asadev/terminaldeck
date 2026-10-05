import { execFile } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it } from 'vitest'
import { TaskWorkspaces, workspaceProvider } from './task-workspaces'
import { gitRunner, workspaceGitEnv } from './workspace-git'
import { branchFor, repoKeyOf, WORKSPACES_DIR, WORKSPACES_FILE } from './workspace-names'

const run = promisify(execFile)

/**
 * Real repositories in temporary folders, real `git worktree`.
 *
 * Each test makes a repository, a workspace or two and a removal: about a dozen
 * git processes, ~110 ms each on a quiet machine and several times that under
 * load. The ceiling is `readiness.test.ts`'s, for the same reason.
 */
const GIT_HEAVY_MS = process.platform === 'win32' ? 60_000 : 20_000

/** The machine's own git config left out, so a person's hooks or templates cannot change what is seen. */
const ISOLATED = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' }
const git = gitRunner(async () => ISOLATED)

const made: string[] = []

afterEach(() => {
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function tempDir(name: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `td-ws-${name}-`)))
  made.push(dir)
  return dir
}

async function sh(cwd: string, ...args: string[]): Promise<string> {
  const { stdout } = await run('git', args, { cwd, env: workspaceGitEnv(ISOLATED) })
  return stdout.trim()
}

/** A repository with two commits, a subfolder and its own (local) identity. */
async function repository(): Promise<string> {
  const repo = tempDir('repo')
  await sh(repo, 'init', '-q', '-b', 'main')
  await sh(repo, 'config', 'user.name', 'Test')
  await sh(repo, 'config', 'user.email', 'test@example.com')
  writeFileSync(join(repo, 'a.txt'), 'one\n')
  mkdirSync(join(repo, 'app'))
  writeFileSync(join(repo, 'app', 'main.ts'), 'export {}\n')
  await sh(repo, 'add', '.')
  await sh(repo, 'commit', '-q', '-m', 'first')
  writeFileSync(join(repo, 'a.txt'), 'two\n')
  await sh(repo, 'commit', '-q', '-am', 'second')
  return repo
}

/** The person's own work in progress: a stash, a staged file, an edit and an untracked file. */
async function workInProgress(repo: string): Promise<void> {
  writeFileSync(join(repo, 'a.txt'), 'stashed\n')
  await sh(repo, 'stash', '-q')
  writeFileSync(join(repo, 'staged.txt'), 'staged\n')
  await sh(repo, 'add', 'staged.txt')
  writeFileSync(join(repo, 'a.txt'), 'edited, not staged\n')
  writeFileSync(join(repo, 'loose.txt'), 'untracked\n')
}

/**
 * Everything about the person's checkout that a workspace must not change. The
 * index's bytes are read first, and the status is read without optional locks,
 * so taking the snapshot cannot itself rewrite the index.
 */
async function checkout(repo: string): Promise<Record<string, string>> {
  return {
    index: createHash('sha256').update(readFileSync(join(repo, '.git', 'index'))).digest('hex'),
    head: await sh(repo, 'rev-parse', 'HEAD'),
    branch: await sh(repo, 'symbolic-ref', '--short', 'HEAD'),
    status: await sh(repo, '--no-optional-locks', 'status', '--porcelain'),
    stash: await sh(repo, 'stash', 'list'),
    a: readFileSync(join(repo, 'a.txt'), 'utf8'),
    loose: readFileSync(join(repo, 'loose.txt'), 'utf8'),
  }
}

async function worktrees(repo: string): Promise<string[]> {
  const list = await sh(repo, 'worktree', 'list', '--porcelain')
  return list
    .split('\n')
    .filter((line) => line.startsWith('worktree '))
    .map((line) => line.slice('worktree '.length))
}

async function branchExists(repo: string, branch: string): Promise<boolean> {
  return (await git(repo, ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`])).ok
}

function setup(): { userData: string; workspaces: TaskWorkspaces } {
  const userData = tempDir('data')
  return { userData, workspaces: new TaskWorkspaces({ userData, git, now: () => 1_000 }) }
}

const TASK = 'local:6f1c2d'

describe('a task workspace', () => {
  it('is a worktree on a new td/ branch from HEAD, and the person’s checkout is left exactly as it was', async () => {
    const repo = await repository()
    await workInProgress(repo)
    const { userData, workspaces } = setup()
    const before = await checkout(repo)

    const folder = await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Fix the login page!')

    expect(folder).not.toBeNull()
    const path = folder as string
    expect(path.startsWith(join(userData, WORKSPACES_DIR, repoKeyOf(repo)))).toBe(true)
    const branch = branchFor('Fix the login page!', TASK)
    expect(await sh(path, 'symbolic-ref', '--short', 'HEAD')).toBe(branch)
    expect(await sh(path, 'rev-parse', 'HEAD')).toBe(before.head)
    // The committed tree, not the person's edits, staging or stash.
    expect(readFileSync(join(path, 'a.txt'), 'utf8')).toBe('two\n')
    expect(existsSync(join(path, 'staged.txt'))).toBe(false)
    expect(existsSync(join(path, 'loose.txt'))).toBe(false)

    expect(await checkout(repo)).toEqual(before)

    const view = await workspaces.view(TASK)
    expect(view.refusal).toBeNull()
    expect(view.workspace).toMatchObject({ taskId: TASK, repo, path, branch, base: before.head, state: 'active', folder: path })
    const stored = JSON.parse(readFileSync(join(userData, WORKSPACES_DIR, WORKSPACES_FILE), 'utf8'))
    expect(stored.workspaces.map((one: { path: string }) => one.path)).toEqual([path])
  }, GIT_HEAVY_MS)

  it('is reused by the same task, and survives a restart', async () => {
    const repo = await repository()
    const { userData, workspaces } = setup()
    const first = await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Ship it')
    const second = await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Ship it, renamed')
    expect(second).toBe(first)
    const restarted = new TaskWorkspaces({ userData, git })
    expect(await restarted.folderFor({ id: TASK, project: repo, useWorkspace: true })).toBe(first)
    expect(await worktrees(repo)).toHaveLength(2)
  }, GIT_HEAVY_MS)

  it('is made once when two starts ask at the same moment', async () => {
    const repo = await repository()
    const { workspaces } = setup()
    const [a, b] = await Promise.all([
      workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Same'),
      workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Same'),
    ])
    expect(a).toBe(b)
    expect(await worktrees(repo)).toHaveLength(2)
  }, GIT_HEAVY_MS)

  it('runs a project that is a subfolder of the repository in the same subfolder of the workspace', async () => {
    const repo = await repository()
    const { workspaces } = setup()
    const folder = await workspaces.folderFor({ id: TASK, project: join(repo, 'app'), useWorkspace: true }, 'App only')
    const view = await workspaces.view(TASK)
    expect(view.workspace?.repo).toBe(repo)
    expect(folder).toBe(join(view.workspace?.path ?? '', 'app'))
    expect(existsSync(join(folder as string, 'main.ts'))).toBe(true)
  }, GIT_HEAVY_MS)

  it('is not made for a task that does not ask, and one it already has is kept in use', async () => {
    const repo = await repository()
    const { workspaces } = setup()
    expect(await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: false })).toBeNull()
    expect(await worktrees(repo)).toHaveLength(1)
    const made = await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'x')
    expect(await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: false })).toBe(made)
  }, GIT_HEAVY_MS)

  it('skips past a branch name already taken, and leaves that branch where it was', async () => {
    const repo = await repository()
    const taken = branchFor('Taken', TASK)
    await sh(repo, 'branch', taken, 'HEAD~1')
    const was = await sh(repo, 'rev-parse', taken)
    const { workspaces } = setup()
    const folder = await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Taken')
    expect(await sh(folder as string, 'symbolic-ref', '--short', 'HEAD')).toBe(`${taken}-2`)
    expect(await sh(repo, 'rev-parse', taken)).toBe(was)
  }, GIT_HEAVY_MS)

  it('gives the provider the task’s title for its branch', async () => {
    const repo = await repository()
    const { workspaces } = setup()
    const provider = workspaceProvider((id) => (id === TASK ? 'Named by the store' : null), () => workspaces)
    const folder = await provider.folderFor({ id: TASK, project: repo, useWorkspace: true })
    expect(await sh(folder as string, 'symbolic-ref', '--short', 'HEAD')).toBe(branchFor('Named by the store', TASK))
  }, GIT_HEAVY_MS)
})

describe('removing a workspace', () => {
  it('removes a clean one, keeps its branch and says so, and leaves the checkout alone', async () => {
    const repo = await repository()
    await workInProgress(repo)
    const { workspaces } = setup()
    const folder = (await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Clean up')) as string
    // A commit on the task's branch, so "the branch is kept" is about real work.
    writeFileSync(join(folder, 'done.txt'), 'done\n')
    await sh(folder, 'add', 'done.txt')
    await sh(folder, 'commit', '-q', '-m', 'task work')
    const tip = await sh(folder, 'rev-parse', 'HEAD')
    const before = await checkout(repo)

    const outcome = await workspaces.remove(TASK)

    expect(outcome.ok).toBe(true)
    const branch = branchFor('Clean up', TASK)
    expect(outcome.message).toContain(branch)
    expect(outcome.view.workspace?.state).toBe('removed')
    expect(existsSync(folder)).toBe(false)
    expect(await branchExists(repo, branch)).toBe(true)
    expect(await sh(repo, 'rev-parse', branch)).toBe(tip)
    expect(await worktrees(repo)).toEqual([repo])
    expect(await checkout(repo)).toEqual(before)
    expect(await workspaces.folderToOpen(TASK)).toBeNull()
  }, GIT_HEAVY_MS)

  it('keeps one with uncommitted changes, with the reason, and never forces it', async () => {
    const repo = await repository()
    const { workspaces } = setup()
    const folder = (await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Dirty')) as string
    writeFileSync(join(folder, 'a.txt'), 'changed by the agent\n')
    writeFileSync(join(folder, 'new.txt'), 'new\n')

    const outcome = await workspaces.remove(TASK)

    expect(outcome.ok).toBe(false)
    expect(outcome.message).toContain('2 uncommitted changes')
    expect(outcome.message).toContain('a.txt')
    expect(outcome.message).toContain('new.txt')
    expect(outcome.view.workspace).toMatchObject({ state: 'kept', reason: outcome.message })
    expect(readFileSync(join(folder, 'a.txt'), 'utf8')).toBe('changed by the agent\n')
    expect(await worktrees(repo)).toHaveLength(2)

    // Used again, it is the task's working folder again.
    expect(await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true })).toBe(folder)
    expect((await workspaces.view(TASK)).workspace).toMatchObject({ state: 'active', reason: null })

    // Once clean, it goes.
    await sh(folder, 'checkout', '--', 'a.txt')
    rmSync(join(folder, 'new.txt'))
    expect((await workspaces.remove(TASK)).ok).toBe(true)
    expect(existsSync(folder)).toBe(false)
  }, GIT_HEAVY_MS)

  it('keeps one a session is still running in', async () => {
    const repo = await repository()
    const { workspaces } = setup()
    const folder = (await workspaces.folderFor({ id: TASK, project: join(repo, 'app'), useWorkspace: true }, 'Busy')) as string
    const outcome = await workspaces.remove(TASK, [folder])
    expect(outcome.ok).toBe(false)
    expect(outcome.message).toContain('A session is still running in it')
    expect(outcome.view.workspace?.state).toBe('kept')
    expect(existsSync(folder)).toBe(true)
  }, GIT_HEAVY_MS)

  it('says so when the task has none', async () => {
    const { workspaces } = setup()
    const outcome = await workspaces.remove('local:none')
    expect(outcome).toMatchObject({ ok: false, message: 'This task has no workspace to remove.' })
  })
})

describe('a workspace whose folder was deleted', () => {
  it('is marked removed with that said, its branch kept, and git’s note of it cleared', async () => {
    const repo = await repository()
    const { workspaces, userData } = setup()
    const folder = (await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Gone')) as string
    rmSync(folder, { recursive: true, force: true })

    expect(workspaces.liveFolders()).toEqual([])
    const view = await workspaces.view(TASK)
    expect(view.workspace?.state).toBe('removed')
    expect(view.workspace?.reason).toContain('deleted outside')
    expect(await worktrees(repo)).toEqual([repo])
    expect(await branchExists(repo, branchFor('Gone', TASK))).toBe(true)

    // Asked again, the task gets a new one, on a fresh branch beside the kept one.
    const again = await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Gone')
    expect(again).toBe(folder)
    expect(await sh(again as string, 'symbolic-ref', '--short', 'HEAD')).toBe(`${branchFor('Gone', TASK)}-2`)

    // And a sweep after a restart finds one deleted while the app was closed.
    rmSync(again as string, { recursive: true, force: true })
    const pruned = await new TaskWorkspaces({ userData, git }).pruneVanished()
    expect(pruned.map((one) => one.taskId)).toEqual([TASK])
  }, GIT_HEAVY_MS)
})

describe('no workspace, with the reason', () => {
  it('for a folder that is not a git repository: the task runs in the project folder', async () => {
    const plain = tempDir('plain')
    const { userData, workspaces } = setup()
    expect(await workspaces.folderFor({ id: TASK, project: plain, useWorkspace: true }, 'x')).toBeNull()
    const view = await workspaces.view(TASK)
    expect(view.workspace).toBeNull()
    expect(view.refusal).toBe(`${plain} is not a git repository, so the task runs in the project folder itself.`)
    expect(existsSync(join(userData, WORKSPACES_DIR, repoKeyOf(plain)))).toBe(false)

    // A task that stops asking is no longer told why it could not have one.
    await workspaces.folderFor({ id: TASK, project: plain, useWorkspace: false })
    expect((await workspaces.view(TASK)).refusal).toBeNull()
  })

  it('for a repository with no commits', async () => {
    const empty = tempDir('empty')
    await sh(empty, 'init', '-q')
    const { workspaces } = setup()
    expect(await workspaces.folderFor({ id: TASK, project: empty, useWorkspace: true })).toBeNull()
    expect((await workspaces.view(TASK)).refusal).toContain('has no commits yet')
  }, GIT_HEAVY_MS)

  it('for a project folder that does not exist', async () => {
    const { workspaces } = setup()
    expect(await workspaces.folderFor({ id: TASK, project: '/no/such/folder', useWorkspace: true })).toBeNull()
    expect((await workspaces.view(TASK)).refusal).toContain('does not exist')
  })

  it('for a task whose project moved to another repository', async () => {
    const first = await repository()
    const second = await repository()
    const { workspaces } = setup()
    const made = await workspaces.folderFor({ id: TASK, project: first, useWorkspace: true }, 'Moved')
    expect(await workspaces.folderFor({ id: TASK, project: second, useWorkspace: true })).toBeNull()
    const view = await workspaces.view(TASK)
    expect(view.refusal).toContain(`its project is now ${second}`)
    expect(view.workspace?.path).toBe(made)
    expect(await worktrees(second)).toHaveLength(1)
  }, GIT_HEAVY_MS)
})

describe('the folders the copilot may start a session in', () => {
  it('are the workspaces that exist: their tops and the folders tasks run in', async () => {
    const repo = await repository()
    const { workspaces } = setup()
    const folder = (await workspaces.folderFor({ id: TASK, project: join(repo, 'app'), useWorkspace: true }, 'App')) as string
    const top = (await workspaces.view(TASK)).workspace?.path as string
    expect(workspaces.liveFolders().sort()).toEqual([top, folder].sort())
  }, GIT_HEAVY_MS)
})

describe('git’s environment for workspaces', () => {
  it('drops every variable that would point git at another repository or index', () => {
    const env = workspaceGitEnv({ PATH: '/bin', GIT_DIR: '/x/.git', GIT_INDEX_FILE: '/x/index', GIT_WORK_TREE: '/x', GIT_COMMON_DIR: '/x' })
    expect(env).toEqual({ PATH: '/bin', LC_ALL: 'C', GIT_TERMINAL_PROMPT: '0' })
  })

  it('so an inherited GIT_INDEX_FILE cannot reach the person’s index', async () => {
    const repo = await repository()
    await workInProgress(repo)
    const before = await checkout(repo)
    const stray = gitRunner(async () => ({ ...ISOLATED, GIT_INDEX_FILE: join(repo, '.git', 'index'), GIT_DIR: join(repo, '.git') }))
    const { userData } = setup()
    const workspaces = new TaskWorkspaces({ userData, git: stray })
    const folder = await workspaces.folderFor({ id: TASK, project: repo, useWorkspace: true }, 'Stray')
    expect(folder).not.toBeNull()
    expect(await checkout(repo)).toEqual(before)
  }, GIT_HEAVY_MS)
})
