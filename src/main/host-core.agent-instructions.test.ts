import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { delimiter, join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { resetAgentBinaryCache } from './agent-binaries'
import { instructionsDir, writeInstructions } from './agents/agent-instructions'
import { APPEND_SYSTEM_PROMPT_FILE } from './copilot-layer'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { resetLoginPathCache } from './providers'

/**
 * A task agent's instructions file, on the command line of the session that
 * actually starts — read off the spawn fence, the last thing between the
 * composed argv and the pty, the way `host-core.session-tools.test.ts` reads
 * the browser verbs. Fake `claude` and `codex` scripts on a PATH this process
 * controls answer `--version` and otherwise sit still, so nothing real runs.
 */

const windows = process.platform === 'win32'
const CASE_MS = windows ? 45_000 : 15_000

let dir = ''
let storageDir = ''
let core: HostCore
let path = ''
let shell: string | undefined
const spawned: string[][] = []

const recorder = {
  apply: (command: string, args: readonly string[]) => {
    spawned.push([...args])
    return { command, args: [...args] }
  },
}

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-core-instructions-'))
  storageDir = join(dir, 'remote')
  const bin = join(dir, 'bin')
  mkdirSync(bin, { recursive: true })
  for (const name of ['claude', 'codex']) {
    if (windows) {
      writeFileSync(join(bin, `${name}.cmd`), ['@echo off', 'if "%1"=="--version" (echo 1.0.0-fake & exit /b 0)', 'ping -n 60 127.0.0.1 >nul', ''].join('\r\n'))
    } else {
      const script = join(bin, name)
      writeFileSync(script, '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.0.0-fake; exit 0; fi\nsleep 60\n')
      chmodSync(script, 0o755)
    }
  }
  if (!windows) {
    // The login shell answers with this process's PATH, which has the fakes on it.
    const fakeShell = join(bin, 'login-shell')
    writeFileSync(fakeShell, '#!/bin/sh\nprintf \'%s\' "$PATH"\n')
    chmodSync(fakeShell, 0o755)
    shell = process.env.SHELL
    process.env.SHELL = fakeShell
  }
  path = process.env.PATH ?? ''
  process.env.PATH = `${bin}${delimiter}${path}`
  resetLoginPathCache()
  resetAgentBinaryCache()
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  core = createHostCore({ storageDir, userData: dir })
  writeInstructions(instructionsDir(storageDir), 'builder', 'Work on a branch.\nRun the tests before you finish.')
}, 30_000)

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  process.env.PATH = path
  if (shell === undefined) delete process.env.SHELL
  else process.env.SHELL = shell
  resetLoginPathCache()
  resetAgentBinaryCache()
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 40, retryDelay: 250 })
  } catch (error) {
    if (!windows) throw error
  }
})

beforeEach(() => {
  spawned.length = 0
})

async function inProject<T>(run: (project: string) => Promise<T>): Promise<T> {
  // Outside the app's own data folder: a session in there is never remembered as a tab.
  const project = mkdtempSync(join(tmpdir(), 'td-instructions-project-'))
  try {
    return await run(project)
  } finally {
    for (const live of core.ptys.list()) if (live.cwd === project) core.ptys.kill(live.id)
    await core.ptys.drain()
    rmSync(project, { recursive: true, force: true, maxRetries: 40, retryDelay: 250 })
  }
}

describe('a task agent’s instructions file at the start', () => {
  it(
    'reaches Claude Code beside the blocked tools, and is remembered for the next start',
    () =>
      inProject(async (project) => {
        const limits = { deniedTools: ['WebFetch'], agentInstructions: 'builder' }
        await core.startSession({ cwd: project, cols: 80, rows: 24, provider: 'claude', ...limits }, undefined, undefined, recorder)
        const args = spawned.at(-1) ?? []
        expect(args[args.indexOf('--disallowedTools') + 1]).toBe('WebFetch')
        expect(args[args.indexOf(APPEND_SYSTEM_PROMPT_FILE) + 1]).toBe(join(storageDir, 'agent-instructions', 'builder.md'))
        // A restart, a held retry or an account switch starts it with the same file.
        const tab = await core.startSession({ cwd: project, cols: 80, rows: 24, provider: 'claude', ...limits })
        expect(core.ledger.get(tab.id)).toMatchObject(limits)
      }),
    CASE_MS,
  )

  it(
    'reaches Codex as its developer instructions',
    () =>
      inProject(async (project) => {
        await core.startSession({ cwd: project, cols: 80, rows: 24, provider: 'codex', agentInstructions: 'builder' }, undefined, undefined, recorder)
        const args = spawned.at(-1) ?? []
        expect(args[args.indexOf('-c') + 1]).toBe('developer_instructions="Work on a branch.\\nRun the tests before you finish.\\n"')
        expect(args).not.toContain(APPEND_SYSTEM_PROMPT_FILE)
      }),
    CASE_MS,
  )

  it(
    'is refused for an agent that cannot take it, and for a file that is not there — with nothing spawned',
    () =>
      inProject(async (project) => {
        await expect(
          core.startSession({ cwd: project, cols: 80, rows: 24, provider: 'shell', agentInstructions: 'builder' }, undefined, undefined, recorder),
        ).rejects.toThrow(/cannot be given standing instructions/)
        await expect(
          core.startSession({ cwd: project, cols: 80, rows: 24, provider: 'claude', agentInstructions: 'nobody' }, undefined, undefined, recorder),
        ).rejects.toThrow(/missing or empty/)
        await expect(
          core.startSession({ cwd: project, cols: 80, rows: 24, provider: 'claude', agentInstructions: '../remote' }, undefined, undefined, recorder),
        ).rejects.toThrow(/not a task agent id/)
        expect(spawned).toHaveLength(0)
      }),
    CASE_MS,
  )

  it(
    'is never added to a session that did not ask',
    () =>
      inProject(async (project) => {
        await core.startSession({ cwd: project, cols: 80, rows: 24, provider: 'claude' }, undefined, undefined, recorder)
        expect((spawned.at(-1) ?? []).some((arg) => arg.startsWith('--append-system-prompt'))).toBe(false)
      }),
    CASE_MS,
  )
})
