import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { delimiter, join } from 'node:path'
import { tmpdir } from 'node:os'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { resetAgentBinaryCache } from './agent-binaries'
import { createHostCore, type HostCore } from './host-core'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { resetLoginPathCache } from './providers'
import { conversationOnDisk, planRestore, type SavedSession } from './session-restore'
import { transcriptDir } from './transcript'

/**
 * A kept Claude tab with no usable conversation id, opened from its row.
 *
 * A real core and a real pty running a fake `claude` that writes down its own
 * argv, with `CLAUDE_CONFIG_DIR` pointed into a throwaway folder — so the
 * command line is the one this app really builds and no real Claude store or
 * session is touched. POSIX only: the product ships for the Mac.
 */

const windows = process.platform === 'win32'
const CASE_MS = 15_000
const OLD = '44444444-4444-4444-8444-444444444444'
const PICKED = '55555555-5555-4555-8555-555555555555'

let dir = ''
let work = ''
let cfg = ''
let core: HostCore
let path = ''
let shell: string | undefined
let configEnv: string | undefined

async function argvOf(pid: number): Promise<string[]> {
  const file = join(dir, 'argv', String(pid))
  for (let i = 0; i < 100 && !existsSync(file); i++) await new Promise((r) => setTimeout(r, 30))
  return readFileSync(file, 'utf8').split('\n').filter((line) => line !== '')
}

describe.skipIf(windows)('opening a kept tab on Claude Code’s conversation list', () => {
  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'td-core-pick-'))
    const bin = join(dir, 'bin')
    work = join(dir, 'work')
    cfg = join(dir, 'cfg')
    for (const name of [bin, work, join(dir, 'argv'), join(cfg, 'sessions')]) mkdirSync(name, { recursive: true })
    const script = join(bin, 'claude')
    writeFileSync(
      script,
      `#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.0.0-fake; exit 0; fi\nprintf '%s\\n' "$@" > '${join(dir, 'argv')}/'$$\nsleep 60\n`,
    )
    chmodSync(script, 0o755)
    const fakeShell = join(bin, 'login-shell')
    writeFileSync(fakeShell, '#!/bin/sh\nprintf \'%s\' "$PATH"\n')
    chmodSync(fakeShell, 0o755)
    shell = process.env.SHELL
    process.env.SHELL = fakeShell
    configEnv = process.env.CLAUDE_CONFIG_DIR
    process.env.CLAUDE_CONFIG_DIR = cfg
    path = process.env.PATH ?? ''
    process.env.PATH = `${bin}${delimiter}${path}`
    resetLoginPathCache()
    resetAgentBinaryCache()
    installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
    core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })
  }, 30_000)

  afterAll(async () => {
    core.ptys.killAll()
    await core.ptys.drain()
    await core.credentials.stop()
    resetPaths()
    process.env.PATH = path
    if (shell === undefined) delete process.env.SHELL
    else process.env.SHELL = shell
    if (configEnv === undefined) delete process.env.CLAUDE_CONFIG_DIR
    else process.env.CLAUDE_CONFIG_DIR = configEnv
    resetLoginPathCache()
    resetAgentBinaryCache()
    rmSync(dir, { recursive: true, force: true })
  })

  it(
    'starts `--resume` with no id beside a live tab in the same folder, and keeps everything the tab had',
    async () => {
      // A live Claude tab already in the folder: a `--continue` would have been
      // dropped for a fresh start here. The list must not be.
      await core.startSession({ cwd: work, cols: 80, rows: 24, provider: 'claude' })
      const meta = await core.startSession({
        cwd: work, cols: 100, rows: 30, provider: 'claude', profileId: null,
        resume: true, pickConversation: true, resumeConversationId: OLD,
        tabKey: 'kept-tab', model: 'sonnet', deniedTools: ['WebFetch'], noSkills: true,
      })
      const argv = await argvOf(core.ptys.pidOf(meta.id) as number)
      expect(argv).toContain('--resume')
      expect(argv[argv.indexOf('--resume') + 1]).not.toBe(OLD)
      expect(argv).not.toContain(OLD)
      expect(argv).not.toContain('--continue')
      expect(argv).not.toContain('--session-id')
      expect(meta.agentSessionId).toBeUndefined()
      // Cancelling the list must lose nothing: the record still has the old id.
      expect(core.ledger.get(meta.id)).toMatchObject({
        agentSessionId: OLD, cwd: work, model: 'sonnet', deniedTools: ['WebFetch'], noSkills: true, tabKey: 'kept-tab',
      })
    },
    CASE_MS,
  )

  it(
    'writes the picked conversation onto the tab, so the next launch continues it by id',
    async () => {
      const meta = await core.startSession({
        cwd: work, cols: 80, rows: 24, provider: 'claude', resume: true, pickConversation: true, tabKey: 'legacy-tab',
      })
      const pid = core.ptys.pidOf(meta.id) as number
      await argvOf(pid)
      expect(core.ledger.get(meta.id)?.agentSessionId).toBeUndefined()

      // The CLI's own process record, before and after the pick.
      writeFileSync(join(cfg, 'sessions', `${pid}.json`), JSON.stringify({ pid, sessionId: PICKED }))
      const settle = async () => {
        for (let i = 0; i < 50 && core.ledger.get(meta.id)?.agentSessionId !== PICKED; i++) {
          await new Promise((r) => setTimeout(r, 20))
        }
      }
      core.noteTyped(meta.id)
      await settle()
      expect(core.ledger.get(meta.id)?.agentSessionId, 'no transcript yet: nothing is taken').toBeUndefined()

      const transcripts = transcriptDir(work, cfg)
      mkdirSync(transcripts, { recursive: true })
      writeFileSync(join(transcripts, `${PICKED}.jsonl`), '{"type":"user","message":"picked"}\n')
      await new Promise((r) => setTimeout(r, 3100)) // past the typing gap
      core.noteTyped(meta.id)
      await settle()
      const record = core.ledger.get(meta.id) as SavedSession
      expect(record.agentSessionId).toBe(PICKED)
      expect(core.ptys.list().find((m) => m.id === meta.id)?.agentSessionId).toBe(PICKED)

      // The restart: planned exactly, it resumes by that id and nothing asks again.
      const [decision] = await planRestore([record], {
        requireExactConversation: true,
        folderExists: async () => true,
        canContinue: () => true,
        configDir: () => cfg,
        conversation: (session, configDir) => conversationOnDisk(session, configDir, 'darwin'),
      })
      expect(decision).toMatchObject({ outcome: 'resume' })
      expect(decision?.pick).toBeUndefined()
      expect(decision?.session.agentSessionId).toBe(PICKED)
    },
    CASE_MS,
  )
})
