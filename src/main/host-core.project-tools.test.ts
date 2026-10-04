import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { delimiter, join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { resetAgentBinaryCache } from './agent-binaries'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { resetLoginPathCache } from './providers'

/**
 * What a session's command line and environment carry from `projectTools` —
 * the seam Stays Fixed's server reaches agent sessions through.
 *
 * The same shape as `host-core.session-tools.test.ts`, and for the same
 * reason: a flag that is composed and then dropped on the way to the spawn
 * looks, from every other side, exactly like a session that has not called the
 * tool yet. So the argv is read off the fence — the last thing before the pty —
 * and the environment off the fake agent itself, which writes what it was given
 * to a file, because a fence sees arguments and not variables.
 *
 * Fake CLIs rather than real ones, so this runs the same on a machine with none
 * of the three agents installed. POSIX only: the seam is not asked inside WSL,
 * and the fixtures are shell scripts.
 */

const windows = process.platform === 'win32'
const CASE_MS = 15_000

let dir = ''
let core: HostCore
let path = ''
let shell: string | undefined

const spawned: string[][] = []
const asked: Array<{ provider: string; cwd: string }> = []

const recorder = {
  apply: (command: string, args: readonly string[]) => {
    spawned.push([...args])
    return { command, args: [...args] }
  },
}

/** What each agent is handed, so the argv is the only variable. */
const projectTools = {
  launch: async (provider: string, cwd: string): Promise<{ args: string[]; env: Record<string, string> } | null> => {
    asked.push({ provider, cwd })
    if (provider === 'claude') return { args: ['--mcp-config', join(dir, 'sf-claude.json')], env: {} }
    if (provider === 'codex') return { args: ['-c', 'mcp_servers.staysfixed.command="x"'], env: {} }
    if (provider === 'gemini') return { args: [], env: { GEMINI_CLI_SYSTEM_DEFAULTS_PATH: join(dir, 'sf-gemini.json') } }
    return null
  },
}

function fakeAgent(bin: string, name: string): void {
  const script = join(bin, name)
  writeFileSync(
    script,
    `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.0.0-fake; exit 0; fi\nenv > "${join(dir, `${name}.env`)}"\nsleep 60\n`,
  )
  chmodSync(script, 0o755)
}

async function waitForFile(file: string): Promise<string> {
  for (let i = 0; i < 100; i++) {
    if (existsSync(file)) {
      const text = readFileSync(file, 'utf8')
      if (text.includes('PATH=')) return text
    }
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  return ''
}

beforeAll(async () => {
  if (windows) return
  dir = mkdtempSync(join(tmpdir(), 'td-core-project-tools-'))
  const bin = join(dir, 'bin')
  for (const name of ['bin', 'work']) mkdirSync(join(dir, name), { recursive: true })
  for (const name of ['claude', 'codex', 'gemini']) fakeAgent(bin, name)
  const fakeShell = join(bin, 'login-shell')
  writeFileSync(fakeShell, '#!/bin/sh\nprintf \'%s\' "$PATH"\n')
  chmodSync(fakeShell, 0o755)
  shell = process.env.SHELL
  process.env.SHELL = fakeShell
  path = process.env.PATH ?? ''
  process.env.PATH = `${bin}${delimiter}${path}`
  resetLoginPathCache()
  resetAgentBinaryCache()
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir, projectTools })
}, 30_000)

afterAll(async () => {
  if (windows) return
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  process.env.PATH = path
  if (shell === undefined) delete process.env.SHELL
  else process.env.SHELL = shell
  resetLoginPathCache()
  resetAgentBinaryCache()
  rmSync(dir, { recursive: true, force: true })
})

beforeEach(() => {
  spawned.length = 0
  asked.length = 0
})

describe.skipIf(windows)('a session started in a project with tools of its own', () => {
  it(
    'gives Claude Code the server on its command line, beside --session-id',
    async () => {
      const meta = await core.startSession({ cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' }, undefined, undefined, recorder)
      expect(meta.provider).toBe('claude')
      const args = spawned.at(-1) ?? []
      expect(args).toContain(join(dir, 'sf-claude.json'))
      expect(args).toContain('--session-id')
      expect(asked).toEqual([{ provider: 'claude', cwd: join(dir, 'work') }])
    },
    CASE_MS,
  )

  it(
    'gives Codex the server as a config override',
    async () => {
      const meta = await core.startSession({ cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'codex' }, undefined, undefined, recorder)
      expect(meta.provider).toBe('codex')
      expect(spawned.at(-1) ?? []).toContain('mcp_servers.staysfixed.command="x"')
    },
    CASE_MS,
  )

  it(
    'gives Gemini the server through its environment',
    async () => {
      const meta = await core.startSession({ cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'gemini' }, undefined, undefined, recorder)
      expect(meta.provider).toBe('gemini')
      const env = await waitForFile(join(dir, 'gemini.env'))
      expect(env).toContain(`GEMINI_CLI_SYSTEM_DEFAULTS_PATH=${join(dir, 'sf-gemini.json')}`)
    },
    CASE_MS,
  )

  it(
    'leaves a launch the app composed for itself alone',
    async () => {
      await core.startSession(
        { cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' },
        undefined,
        undefined,
        recorder,
        ['--mcp-config', join(dir, 'copilot.json'), '--strict-mcp-config'],
      )
      expect(asked).toEqual([])
      expect(spawned.at(-1) ?? []).not.toContain(join(dir, 'sf-claude.json'))
    },
    CASE_MS,
  )

  it(
    'starts the session anyway when the seam throws',
    async () => {
      const failing = createHostCore({
        storageDir: join(dir, 'remote-failing'),
        userData: dir,
        projectTools: {
          launch: async () => {
            throw new Error('the engine is gone')
          },
        },
      })
      try {
        const meta = await failing.startSession({ cwd: join(dir, 'work'), cols: 80, rows: 24, provider: 'claude' }, undefined, undefined, recorder)
        expect(meta.provider).toBe('claude')
        expect(spawned.at(-1) ?? []).toContain('--session-id')
      } finally {
        failing.ptys.killAll()
        await failing.ptys.drain()
        await failing.credentials.stop()
      }
    },
    CASE_MS,
  )
})
