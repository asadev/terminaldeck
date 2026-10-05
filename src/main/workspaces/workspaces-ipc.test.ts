import { execFile } from 'node:child_process'
import { existsSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it } from 'vitest'
import { TaskWorkspaces, type RemoveOutcome, type WorkspaceView } from './task-workspaces'
import { gitRunner, workspaceGitEnv } from './workspace-git'
import { registerWorkspacesIpc, type OpenOutcome } from './workspaces-ipc'

const run = promisify(execFile)
const GIT_HEAVY_MS = process.platform === 'win32' ? 60_000 : 20_000
const ISOLATED = { ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_SYSTEM: '/dev/null' }

const made: string[] = []
afterEach(() => {
  for (const dir of made.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function tempDir(name: string): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), `td-ws-ipc-${name}-`)))
  made.push(dir)
  return dir
}

async function repository(): Promise<string> {
  const repo = tempDir('repo')
  const sh = (...args: string[]) => run('git', args, { cwd: repo, env: workspaceGitEnv(ISOLATED) })
  await sh('init', '-q')
  await sh('config', 'user.name', 'Test')
  await sh('config', 'user.email', 'test@example.com')
  writeFileSync(join(repo, 'a.txt'), 'one\n')
  await sh('add', '.')
  await sh('commit', '-q', '-m', 'first')
  return repo
}

const WINDOW = { id: 'main-window' }

function wire(liveFolders: string[] = []) {
  const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()
  const opened: string[] = []
  const workspaces = new TaskWorkspaces({ userData: tempDir('data'), git: gitRunner(async () => ISOLATED) })
  registerWorkspacesIpc(
    { handle: (channel, listener) => void handlers.set(channel, listener) },
    {
      workspaces: () => workspaces,
      openFolder: async (path) => {
        opened.push(path)
        return ''
      },
      liveFolders: () => liveFolders,
      isApprover: (sender) => sender === WINDOW,
    },
  )
  const call = <T>(channel: string, ...args: unknown[]): Promise<T> =>
    Promise.resolve(handlers.get(channel)?.({ sender: WINDOW }, ...args) as T)
  return { handlers, opened, workspaces, call }
}

describe('the task workspace channels', () => {
  it('are the three the preload calls', () => {
    expect([...wire().handlers.keys()].sort()).toEqual(['tasks:workspace', 'tasks:workspace-open', 'tasks:workspace-remove'])
  })

  it('answer only the app’s own window', async () => {
    const { handlers } = wire()
    for (const handler of handlers.values()) {
      await expect(Promise.resolve().then(() => handler({ sender: { id: 'a browser tab' } }, 'local:a'))).rejects.toThrow(/own window/)
    }
  })

  it('show a task’s workspace, open the recorded folder, and remove it when clean', async () => {
    const repo = await repository()
    const { workspaces, call, opened } = wire()
    const folder = (await workspaces.folderFor({ id: 'local:a', project: repo, useWorkspace: true }, 'Wired')) as string

    const view = await call<WorkspaceView>('tasks:workspace', 'local:a')
    expect(view.workspace).toMatchObject({ folder, state: 'active' })

    expect(await call<OpenOutcome>('tasks:workspace-open', 'local:a')).toEqual({ ok: true })
    expect(opened).toEqual([folder])

    const removed = await call<RemoveOutcome>('tasks:workspace-remove', 'local:a')
    expect(removed.ok).toBe(true)
    expect(existsSync(folder)).toBe(false)
    expect(await call<OpenOutcome>('tasks:workspace-open', 'local:a')).toEqual({ ok: false, error: 'This task has no workspace folder to open.' })
    expect(opened).toEqual([folder])
  }, GIT_HEAVY_MS)

  it('never remove a workspace a running session is in', async () => {
    const repo = await repository()
    const live: string[] = []
    const { workspaces, call } = wire(live)
    const folder = (await workspaces.folderFor({ id: 'local:a', project: repo, useWorkspace: true }, 'Busy')) as string
    live.push(folder)
    const outcome = await call<RemoveOutcome>('tasks:workspace-remove', 'local:a')
    expect(outcome.ok).toBe(false)
    expect(existsSync(folder)).toBe(true)
  }, GIT_HEAVY_MS)

  it('take a task id and nothing else', async () => {
    const { call, opened } = wire()
    expect(await call<WorkspaceView>('tasks:workspace', { path: '/' })).toEqual({ workspace: null, refusal: null })
    expect((await call<OpenOutcome>('tasks:workspace-open', '/')).ok).toBe(false)
    expect((await call<RemoveOutcome>('tasks:workspace-remove', 42)).ok).toBe(false)
    expect(opened).toEqual([])
  })
})
