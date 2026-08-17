import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The surface, against real things.
 *
 * `control.test.ts` proves the rules with a fake app behind them; this file
 * proves the other half — that each method reaches the module the app itself
 * uses and gets the same answer. Everything here is real: a real `git init`, a
 * real `settings.json` written and read back off disk, a real transcript file
 * in the layout the Claude CLI writes, a real store.
 *
 * The failure this exists to catch is the one this repository keeps paying for:
 * a feature that compiles, passes its unit tests against a stub, and is wired to
 * nothing. A `DeckSurface` whose `gitStatus` did not actually call
 * `readGitStatus` would satisfy every test in `control.test.ts`.
 */

const ROOT = join(tmpdir(), `deck-control-live-${process.pid}`)

/*
 * `settings-extra.ts` asks Electron for `userData`, so it gets an Electron.
 *
 * The same shape `settings-extra.test.ts` uses, and for the same reason: it is
 * the only thing that module wants from the runtime, and mocking one call is
 * cheaper than the alternative of not exercising the real settings writer at
 * all.
 */
vi.mock('electron', async () => {
  const { tmpdir: tmp } = await import('node:os')
  const { join: j } = await import('node:path')
  const root = j(tmp(), `deck-control-live-${process.pid}`)
  return {
    app: {
      getPath: (name: string) => (name === 'logs' ? j(root, 'Logs') : root),
      getAppPath: () => root,
      getVersion: () => '0.0.0-test',
      isPackaged: false,
    },
    shell: { openPath: async () => '', showItemInFolder: () => undefined },
    session: { fromPartition: () => ({ clearStorageData: async () => undefined, clearCache: async () => undefined }) },
  }
})

const { installPaths, resetPaths } = await import('../platform/paths')
const { resetSettingsCache } = await import('../settings-extra')
const { encodeProjectPath } = await import('../transcript')
const { createLiveSurface } = await import('./live-surface')
const { store } = await import('../store')
import type { SessionMeta, SessionStatus } from '../../shared/types'
import type { DeckSurface } from './surface'

let work = ''
let sessions: SessionMeta[] = []
let typed: Array<{ id: string; data: string }> = []
let killed: string[] = []

function surface(): DeckSurface {
  return createLiveSurface({
    ptys: {
      list: () => sessions,
      write: (id, data) => {
        typed.push({ id, data })
      },
      kill: (id) => {
        killed.push(id)
      },
      screen: async () => 'a rendered screen',
    },
    startSession: async (input) => {
      const meta: SessionMeta = {
        id: 'started-1',
        cwd: input.cwd,
        title: 'started',
        provider: input.provider ?? 'claude',
        exitCode: null,
        createdAt: 1,
      }
      sessions = [...sessions, meta]
      return meta
    },
    sessionStatus: (id) =>
      id === 'live-1' ? { status: 'working' as SessionStatus, at: 42 } : undefined,
  })
}

/** One line of the JSONL the Claude CLI writes, in the two shapes that carry prose. */
function prompt(uuid: string, text: string, at: string): string {
  return `${JSON.stringify({
    type: 'user',
    uuid,
    timestamp: at,
    sessionId: 'cli-session',
    cwd: work,
    message: { role: 'user', content: text },
  })}\n`
}

function reply(id: string, text: string, at: string): string {
  return `${JSON.stringify({
    type: 'assistant',
    uuid: `u-${id}`,
    timestamp: at,
    sessionId: 'cli-session',
    cwd: work,
    message: { id, role: 'assistant', model: 'claude-x', content: [{ type: 'text', text }] },
  })}\n`
}

beforeEach(() => {
  rmSync(ROOT, { recursive: true, force: true })
  mkdirSync(ROOT, { recursive: true })
  work = join(ROOT, 'work')
  mkdirSync(work, { recursive: true })

  resetPaths()
  installPaths({
    userData: () => ROOT,
    home: () => ROOT,
    downloads: () => ROOT,
    appRoot: () => ROOT,
  })
  resetSettingsCache()
  process.env.CLAUDE_CONFIG_DIR = join(ROOT, 'claude')

  sessions = []
  typed = []
  killed = []
})

afterEach(() => {
  delete process.env.CLAUDE_CONFIG_DIR
  resetPaths()
})

afterAll(() => {
  rmSync(ROOT, { recursive: true, force: true })
})

/* --------------------------------------------------------------- sessions -- */

describe('sessions', () => {
  it('forwards to the same pty manager the window uses', async () => {
    sessions = [
      { id: 'live-1', cwd: work, title: 'work', provider: 'claude', exitCode: null, createdAt: 1 },
    ]
    const live = surface()

    expect(live.listSessions()).toHaveLength(1)
    expect(live.sessionStatus('live-1')).toEqual({ status: 'working', at: 42 })
    // Null, not undefined: `DeckSurface` says "no classification yet" with a
    // null, and a surface that leaked `undefined` would make `?? 'idle'` in the
    // catalogue work by accident rather than by contract.
    expect(live.sessionStatus('nobody')).toBeNull()

    live.writeToSession('live-1', 'hello\r')
    live.killSession('live-1')
    expect(typed).toEqual([{ id: 'live-1', data: 'hello\r' }])
    expect(killed).toEqual(['live-1'])
    expect(await live.sessionScreen('live-1')).toBe('a rendered screen')
  })

  /**
   * The tripwire under `COPILOT-REMOTE.md` §0.2, and the reason it is an
   * assertion about an *absence*.
   *
   * `sessions.start` narrows a remote caller's folder through
   * `DeckSurface.deviceFolders` and starts the session through
   * `startSession(input, forDevice)` — the same spawn path that device's own
   * `create` frame takes, so it gets that device's folder grants, its guest git
   * identity and its confinement. This surface implements neither half: it
   * holds the *person's* starter, which knows nothing about devices.
   *
   * That is a coherent state, not a half-built one. `requireDeviceFolder` reads
   * a missing `deviceFolders` as "this host cannot say whether a device may use
   * a folder" and refuses every remote `sessions.start` outright, which is the
   * right answer for a host that cannot honour the argument.
   *
   * What must never happen is one arriving without the other. A `deviceFolders`
   * added here while `startSession` still drops `forDevice` would let a phone,
   * through the copilot, start a session in any folder this desktop has open —
   * with the owner's git credentials and no confinement, which is strictly more
   * than the New Session button on that phone can do. That is the shape of
   * OC-02 (GHSA-943q-mwmv-hhvh): the tool name gated, the effect not.
   *
   * So: when somebody wires the device-aware start, this test fails, and the
   * fix is to delete it and replace it with one asserting the start really is
   * device-aware.
   */
  it('offers no device folders, because it has no device-aware way to start one', () => {
    const live = surface()
    expect(live.deviceFolders).toBeUndefined()
    // The two travel together. Read `deps.startSession`'s arity rather than its
    // behaviour, because "did this honour `forDevice`" is not observable from a
    // starter that ignores it — which is exactly the failure being guarded.
    expect(live.startSession.length).toBe(1)
  })
})

/* --------------------------------------------------------------- projects -- */

describe('projects', () => {
  it('reads the app’s own project list, newest first', () => {
    store().addProject(join(ROOT, 'one'))
    store().addProject(join(ROOT, 'two'))

    const listed = surface().listProjects().map((project) => project.path)
    expect(listed).toContain(join(ROOT, 'one'))
    expect(listed).toContain(join(ROOT, 'two'))
  })
})

/* -------------------------------------------------------------------- git -- */

describe('git', () => {
  it('reports the real state of a real repository', async () => {
    // A real `git init` and a real dirty file. A mocked git would pass whatever
    // shape this test asserted, including a wrong one.
    execFileSync('git', ['init', '-q'], { cwd: work })
    execFileSync('git', ['config', 'user.email', 'test@example.invalid'], { cwd: work })
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: work })
    writeFileSync(join(work, 'README.md'), '# hello\n', 'utf8')

    const status = (await surface().gitStatus(work)) as {
      repo: boolean
      clean: boolean
      untracked: Array<{ path: string }>
    }

    expect(status.repo).toBe(true)
    expect(status.clean).toBe(false)
    expect(status.untracked.map((file) => file.path)).toEqual(['README.md'])
  })

  it('answers about a folder that is not a repository without throwing', async () => {
    const status = (await surface().gitStatus(work)) as { repo: boolean }
    expect(status.repo).toBe(false)
  })
})

/* --------------------------------------------------------------- settings -- */

describe('settings', () => {
  it('writes to the real settings file and reads it back', () => {
    const live = surface()
    live.writeSettings({ 'appearance.theme': 'light' })

    expect(live.readSettings().settings['appearance.theme']).toBe('light')
    // On disk, not only in a cache: the settings window and the copilot are two
    // readers of one file, and a write that only landed in memory would look
    // right here and be gone after a relaunch.
    resetSettingsCache()
    expect(live.readSettings().settings['appearance.theme']).toBe('light')
    expect(statSync(join(ROOT, 'settings.json')).size).toBeGreaterThan(0)
  })

  it('writes a real last-good copy of both stores', () => {
    /*
     * The way back, on disk, before anything changes.
     *
     * Proved here rather than only against the fake surface, because the whole
     * value of the snapshot is that a file exists on the user's machine when
     * they need it — and a `snapshotSettings` that resolved to nothing would
     * satisfy every ordering assertion in `control.test.ts`.
     */
    const live = surface()
    live.writeSettings({ 'appearance.density': 'compact' })

    const written = live.snapshotSettings()
    expect(written.path).toBe(join(ROOT, 'settings.last-good.json'))
    expect(statSync(written.path).size).toBeGreaterThan(0)

    const saved = JSON.parse(readFileSync(written.path, 'utf8')) as {
      settings: { values: Record<string, unknown> }
      preferences: { theme: string }
      reason: string
    }
    expect(saved.settings.values['appearance.density']).toBe('compact')
    expect(saved.preferences.theme).toBe(store().getPreferences().theme)
    expect(saved.reason).toContain('settings.write')
  })

  it('persists a preference rather than mutating the store in place', () => {
    const live = surface()
    const before = live.readSettings().preferences

    live.writePreferences({ theme: 'light' })
    expect(store().getPreferences().theme).toBe('light')
    // The snapshot handed out earlier must not have changed underneath its
    // holder: `getPreferences()` returns the store's own live object, and a
    // surface that passed it straight through would let a caller edit app state
    // without persisting it.
    expect(before.theme).toBe('dark')
  })
})

/* ------------------------------------------------------------ transcripts -- */

describe('transcripts', () => {
  function writeTranscript(name: string, body: string): string {
    const dir = join(ROOT, 'claude', 'projects', encodeProjectPath(work))
    mkdirSync(dir, { recursive: true })
    const path = join(dir, name)
    writeFileSync(path, body, 'utf8')
    return path
  }

  it('lists every conversation in a folder, with its size and when it began', async () => {
    /*
     * Every one, not the newest one, and that is the change this asserts.
     *
     * `newestChatTranscript(cwd)` is right for the chat view and wrong for a
     * fleet: several sessions share a folder, and handing them all the same
     * file made three of them report a fourth session's work as their own.
     * `transcript-match.ts` picks per session from this list.
     */
    const first = writeTranscript(
      'one.jsonl',
      prompt('p1', 'run the tests', '2026-08-17T09:00:00.000Z') +
        reply('m1', 'running them now', '2026-08-17T09:00:01.000Z'),
    )
    const second = writeTranscript('two.jsonl', prompt('p2', 'and again', '2026-08-17T09:05:00.000Z'))

    const found = await surface().transcriptsIn(work)
    expect(found.map((file) => file.path).sort()).toEqual([first, second].sort())
    for (const file of found) {
      expect(file.bytes).toBeGreaterThan(0)
      expect(file.createdAt).toBeGreaterThan(0)
      expect(file.sessionId).toMatch(/^(one|two)$/)
    }
    expect(await surface().transcriptBytes(first)).toBeGreaterThan(0)
  })

  it('answers an empty list for a folder with no transcript at all', async () => {
    expect(await surface().transcriptsIn(join(ROOT, 'nowhere'))).toEqual([])
  })

  it('parses the real JSONL into prose, keeping the roles apart', async () => {
    const path = writeTranscript(
      'one.jsonl',
      prompt('p1', 'run the tests', '2026-08-17T09:00:00.000Z') +
        reply('m1', 'running them now', '2026-08-17T09:00:01.000Z'),
    )

    const messages = await surface().readTranscriptFrom(path, 0)
    expect(messages).toEqual([
      { role: 'you', at: Date.parse('2026-08-17T09:00:00.000Z'), text: 'run the tests', truncated: false },
      {
        role: 'agent',
        at: Date.parse('2026-08-17T09:00:01.000Z'),
        text: 'running them now',
        truncated: false,
      },
    ])
  })

  it('starts mid-file when asked, and absorbs the torn line that produces', async () => {
    const head = prompt('p1', 'the beginning', '2026-08-17T09:00:00.000Z')
    const tail = reply('m1', 'the end', '2026-08-17T09:00:05.000Z')
    const path = writeTranscript('one.jsonl', head + tail)

    // Deliberately a few bytes into the second line, which is what reading a
    // window from the end of a 154 MB file does every time. The fragment fails
    // `JSON.parse` and is skipped — the cost of a tail is one lost line, and
    // this is the test that says so out loud.
    const messages = await surface().readTranscriptFrom(path, head.length + 5)
    expect(messages).toEqual([])

    const whole = await surface().readTranscriptFrom(path, head.length)
    expect(whole.map((message) => message.text)).toEqual(['the end'])
  })

  it('reports zero bytes for a transcript that has gone', async () => {
    // Deleted between the listing and the read is a normal Tuesday; it must
    // read as "nothing to show" rather than as an ENOENT out of a tool call.
    expect(await surface().transcriptBytes(join(ROOT, 'claude', 'gone.jsonl'))).toBe(0)
  })
})

/* ----------------------------------------------------------------- alerts -- */

describe('alerts', () => {
  it('produces a real report for a real folder', async () => {
    execFileSync('git', ['init', '-q'], { cwd: work })
    const report = (await surface().alerts(work)) as { alerts: unknown[]; generatedAt?: number }

    // The shape, not the content: which alerts fire is `alerts.test.ts`'s
    // subject. What matters here is that the copilot's report comes out of the
    // same `collectAlertInput`/`deriveAlerts` pair the panel uses, rather than
    // a second scanner that would drift away from it.
    expect(Array.isArray(report.alerts)).toBe(true)
  })
})
