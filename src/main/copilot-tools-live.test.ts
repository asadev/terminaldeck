/**
 * The copilot, with the real Claude CLI, actually calling one of this app's
 * tools.
 *
 * Opt-in, because it spawns a real agent, spends real tokens and needs a signed
 * -in Claude Code on the machine:
 *
 *     TERMINALDECK_LIVE_COPILOT=1 npx vitest run src/main/copilot-tools-live.test.ts
 *
 * ## Why it exists at all
 *
 * For a while the copilot had **no tools**. `deck-control` wrote its MCP config
 * on every start, the loopback server listened behind a bearer token, the
 * routine runner passed it — and `copilot-session.ts` spawned the pinned copilot
 * with no `--mcp-config`, so the agent a person talks to in the sidebar had the
 * native Claude Code tools and none of this app's. Every claim that it was
 * "bounded by the tool tiers and the confirmation gate" described a gate that
 * was not in the path, because there was nothing to gate.
 *
 * That was true while a dozen unit tests passed. They asserted that the config
 * file was correct, that the server answered, that the tier check refused the
 * right things — all of it true, and none of it about a tool surface anybody had
 * ever seen answer. So this file is the one that would have caught it, and the
 * assertion is deliberately not "the pty printed something plausible": it is
 * that a row appears in **this app's own action log**, which only the main
 * process writes, and only when a tool has actually been dispatched through
 * `DeckControl.call`.
 *
 * ## What is real here
 *
 * Everything on the path being proved. A real `deck-control` server on loopback
 * with a freshly minted token; the real config written by `writeSecretFile`; the
 * real `createHostCore().startSession`, so the argv is the argv the app builds,
 * including the records fence; the real `ensureCopilot`, so the flags are the
 * ones the product passes; a real pty running the real `claude` binary; and the
 * person's own Claude Code login, because the copilot is an ordinary session
 * running as them.
 *
 * The `DeckSurface` is this file's own, and that is the one substitution.
 * `createLiveSurface` reaches for Electron's `app` through `settings-extra.ts`
 * and cannot be built outside an Electron process. `listSessions` here is wired
 * to the same `PtyManager` the real one would be, so what the copilot reads back
 * is a true statement about processes that are really running; the rest answer
 * inertly, because no tool but `sessions_list` is called.
 */

import { mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { EventEmitter } from 'node:events'
import type { IpcMain } from 'electron'
import { afterAll, describe, expect, it } from 'vitest'
import type { CreateSessionInput, SessionMeta, SessionStatus } from '../shared/types'
import { createHostCore, type HostCore } from './host-core'
import { ensureCopilot, resetCopilot, stopCopilot } from './copilot-session'
import { copilotPaths } from './copilot-home'
import { installPaths, resetPaths } from './platform/paths'
import { resetHomeScopes } from './transcript'
import { registerDeckControlIpc, type DeckControlHandle } from './deck-control'
import type { DeckSurface } from './deck-control/surface'

const live = process.env.TERMINALDECK_LIVE_COPILOT === '1'

/** Enough of `ipcMain` to register on. Nothing here invokes a channel. */
class FakeIpcMain extends EventEmitter {
  readonly handlers = new Map<string, unknown>()
  handle(channel: string, listener: unknown): void {
    this.handlers.set(channel, listener)
  }
}

/**
 * The app, as the copilot's tools see it.
 *
 * `listSessions` is the live `PtyManager`; the rest answer the empty answer
 * their real counterparts answer for a folder with no repository and a session
 * with no transcript. See the header for why this is not `createLiveSurface`.
 */
function surfaceOver(core: HostCore, root: string): DeckSurface {
  return {
    listSessions: () => core.ptys.list(),
    sessionStatus: () => null,
    startSession: (input: CreateSessionInput) => core.startSession(input),
    writeToSession: (id, data) => core.ptys.write(id, data),
    killSession: (id) => core.ptys.kill(id),
    sessionScreen: (id) => core.ptys.screen(id),
    listProjects: () => [],
    appStateRoot: () => root,
    copilotRoot: () => copilotPaths(root).root,
    gitStatus: async () => ({ repo: false }),
    alerts: async () => ({ alerts: [] }),
    readSettings: () => ({ settings: {}, preferences: {} }),
    writeSettings: () => ({}),
    writePreferences: () => ({}),
    snapshotSettings: () => ({ path: join(root, 'settings.last-good.json'), at: 0 }),
    transcriptsIn: async () => [],
    transcriptBytes: async () => 0,
    readTranscriptFrom: async () => [],
    readToolTrail: async () => ({ events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }),
    transcriptTotals: async () => null,
    gitChanges: async () => ({
      repo: false,
      root: null,
      branch: null,
      ahead: 0,
      behind: 0,
      files: [],
      reason: 'not a repository',
    }),
    fileDiff: async () => '',
    fileModifiedAt: async () => null,
  }
}

let root = ''
let core: HostCore | null = null
let handle: DeckControlHandle | null = null

afterAll(async () => {
  if (core) {
    stopCopilot({
      startSession: async () => ({}) as SessionMeta,
      isAlive: () => true,
      stop: (id) => core?.ptys.kill(id),
      userData: () => root,
    })
    core.ptys.killAll()
    await core.ptys.drain()
    await core.credentials.stop()
  }
  await handle?.stop()
  resetCopilot()
  resetHomeScopes()
  resetPaths()
  if (root) rmSync(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

describe.skipIf(!live)('the copilot, against the real CLI', () => {
  it('answers a question that needs one of this app’s tools', async () => {
    root = realpathSync(mkdtempSync(join(tmpdir(), 'td-copilot-live-')))
    installPaths({
      userData: () => root,
      home: () => root,
      downloads: () => root,
      temp: () => root,
    } as never)

    /* The whole of the visible output, so a failure prints what really happened. */
    const output = new Map<string, string>()
    core = createHostCore({
      storageDir: join(root, 'remote'),
      userData: root,
      onData: (id, data) => output.set(id, (output.get(id) ?? '') + data),
    })

    // A session for the copilot to find. Real process, real folder, so the
    // answer it reads back is a true statement rather than a fixture.
    const watched = core.ptys.create(
      { cwd: root, cols: 80, rows: 24 },
      { provider: 'shell', command: '/bin/sh', args: ['-c', 'sleep 600'], path: process.env.PATH ?? '' },
    )

    const ipc = new FakeIpcMain()
    handle = await registerDeckControlIpc(ipc as unknown as IpcMain, {
      ptys: core.ptys,
      startSession: (input) => (core as HostCore).startSession(input),
      sessionStatus: () => undefined as { status: SessionStatus; at: number } | undefined,
      // No window in this process, so every alter-tier call is refused with
      // `no-approver`. `sessions_list` is a read, which is the point: the read
      // tier is the one a copilot has without anybody clicking anything.
      isApprover: () => false,
      broadcast: () => undefined,
      surface: surfaceOver(core, root),
    })

    const state = await ensureCopilot({
      startSession: (input, _guest, _confine, fence, extraArgs) =>
        (core as HostCore).startSession(input, undefined, undefined, fence, extraArgs),
      isAlive: (id) => (core as HostCore).ptys.list().some((s) => s.id === id && s.exitCode === null),
      stop: (id) => (core as HostCore).ptys.kill(id),
      userData: () => root,
      storageDir: () => join(root, 'remote'),
      mcpConfig: () => handle?.configPath ?? null,
    })
    expect(state.problem).toBeNull()
    expect(state.status).toBe('running')
    const copilot = state.sessionId as string

    const raw = (): string => output.get(copilot) ?? ''
    /**
     * The screen as words, with the drawing taken out.
     *
     * An agent CLI paints by *moving the cursor* rather than by printing spaces,
     * so the raw stream reads `Yes,\x1b[12GI\x1b[14Gtrust\x1b[20Gthis` — every
     * escape stripped naively gives `Yes,Itrustthis`, and every sentence match
     * fails against a screen that plainly says the words. Each escape becomes one
     * space instead, which is what the column move meant.
     */
    const seen = (): string =>
      raw()
        // OSC (window titles) first, because they end with BEL or ST rather than
        // a letter and a CSI pattern would eat past them.
        .replace(/\u001b\][\s\S]*?(?:\u0007|\u001b\\)/g, ' ')
        .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, ' ')
        .replace(/\u001b[@-Z\\-_]/g, ' ')
        .replace(/\s+/g, ' ')
    const waitFor = async (test: (text: string) => boolean, label: string, ms: number): Promise<void> => {
      const deadline = Date.now() + ms
      while (Date.now() < deadline) {
        if (test(seen())) return
        await new Promise((done) => setTimeout(done, 250))
      }
      throw new Error(`timed out waiting for ${label}\n\n----- what the copilot printed -----\n${seen()}`)
    }

    /*
     * The folder-trust prompt, which a first run in a new directory always
     * shows. Answered rather than suppressed: this is the same prompt a person
     * would answer the first time they opened the copilot, and a flag that
     * skipped it would be this test driving a launch the product does not.
     *
     * The wording is matched, not the glyph. The first version of this waited
     * for `❯` — which the *trust prompt itself* draws, beside "1. Yes, I trust
     * this folder" — so it typed the question into the chooser, where the text
     * was swallowed and the Enter at the end of it answered the prompt. The run
     * looked like a copilot that ignored a question; it was a question that was
     * never asked.
     */
    await waitFor((text) => /trust this folder/i.test(text), 'the folder-trust prompt', 120_000)
    core.ptys.write(copilot, '\r')

    /*
     * Then the app itself, identified by something only the running UI prints:
     * the permission-mode footer. Waiting for a prompt glyph is what went wrong
     * above, and waiting for the banner is not enough either — it is drawn
     * before the input is live.
     */
    await waitFor((text) => /bypass permissions|shift\+tab to cycle/i.test(text), 'the composer', 120_000)
    await new Promise((done) => setTimeout(done, 3000))

    /*
     * A question that cannot be answered from the model's own knowledge, in the
     * words a person would use — then the Enter, separately and after a pause.
     * A TUI that re-renders on every keystroke drops a `\r` arriving in the same
     * chunk as the text often enough to make a flaky test.
     */
    core.ptys.write(copilot, 'which sessions are running right now?')
    await new Promise((done) => setTimeout(done, 1500))
    core.ptys.write(copilot, '\r')

    /*
     * The assertion, and the reason it is about the log rather than the screen.
     *
     * A pty full of plausible prose proves nothing — a model with no tools will
     * happily describe what it *would* do. This row is written by the main
     * process, inside `DeckControl.call`, after the tier check, and only when a
     * tool has actually run. Nothing the agent can print can forge it.
     */
    const logged = (): string => {
      try {
        return readFileSync((handle as DeckControlHandle).log.file, 'utf8')
      } catch {
        return ''
      }
    }
    const deadline = Date.now() + 180_000
    while (Date.now() < deadline && !logged().includes('tool.sessions.list')) {
      await new Promise((done) => setTimeout(done, 500))
    }

    /*
     * Then wait for the screen to stop moving, so the transcript printed below
     * is the whole exchange rather than the middle of one.
     *
     * Settling rather than matching a phrase, because the first version of this
     * waited for the words "sessions are running" — which the *echo of the
     * question* contains, so it returned before the answer existed and printed a
     * transcript that stopped at the spinner. There is nothing a finished answer
     * says that an unfinished one cannot, so the honest signal is that the pty
     * has gone quiet.
     *
     * Nothing is asserted about it: whether the model quotes a session id back
     * is a matter of phrasing, and a build must not go red over phrasing. The
     * hard assertions are underneath, and neither is about prose.
     */
    const quiet = Date.now() + 120_000
    let last = ''
    let still = 0
    while (Date.now() < quiet && still < 4) {
      await new Promise((done) => setTimeout(done, 1000))
      const now = raw()
      still = now === last ? still + 1 : 0
      last = now
    }

    const rows = logged()
      .trim()
      .split('\n')
      .filter((line) => line.length > 0)
      .map(
        (line) =>
          JSON.parse(line) as {
            action: string
            outcome?: string
            tier?: string
            result?: { count?: number }
          },
      )

    console.log('----- the copilot’s screen -----\n' + seen())
    console.log('----- the action log -----\n' + logged())

    const call = rows.find((row) => row.action === 'tool.sessions.list')
    expect(call, 'the copilot never dispatched a deck-control tool').toBeDefined()
    expect(call?.outcome).toBe('ok')
    // A read, dispatched with no window in the process to confirm anything —
    // which is what the read tier means.
    expect(call?.tier).toBe('read')
    // And the screen agrees with the log: the CLI drew the call to this app's
    // MCP server. Two independent witnesses, one on each side of the socket.
    expect(seen()).toContain('deck-control')

    /*
     * And what came back was the truth about this machine rather than a guess.
     *
     * Two, and the two are named: the shell started above and the copilot's own
     * session. Asserting the pty layer really holds `watched` is what stops the
     * count being a number that happens to match — the answer the copilot read
     * is a statement about processes that exist.
     */
    expect(core.ptys.list().map((session) => session.id)).toContain(watched.id)
    expect(call?.result?.count).toBe(2)
  }, 600_000)
})
