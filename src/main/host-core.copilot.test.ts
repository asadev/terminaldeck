import { mkdirSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { createHostCore, type HostCore } from './host-core'
import { store } from './store'

/**
 * What gets written into `openSessions`, and what must never be.
 *
 * `openSessions` is the list a launch restores, so everything in it is a promise
 * that starting it again reproduces what was there. For one kind of session that
 * promise cannot be kept, and it was being made anyway.
 *
 * The copilot is a singleton `ensureCopilot` starts, in this app's own storage,
 * with an instruction layer and a `--mcp-config` composed at start time — and it
 * goes through the same `startSession` as every tab, so it was being remembered
 * like one. On `DESKTOP-DDGMNCV` on 2026-08-17 there were **two** of them in
 * `state.json`, because it had been restarted once. A `SavedSession` carries a
 * folder, an agent and an account and nothing else, so what a launch would
 * restore is two plain Claude Code sessions in `<userData>/copilot`: no layer,
 * no `deck-control` tools, no fence, invisible in the sidebar because the window
 * filters that folder out, and billing on every launch.
 *
 * `startCopilot` already refuses to start a copilot without its layer — *"A
 * copilot spawned with no layer is not a diminished copilot. It is a plain
 * Claude Code session in somebody's workspace, wearing this app's name"* — and
 * the rule pinned here is that same refusal, enforced at the one place that
 * could otherwise arrange it behind everybody's back.
 *
 * The question is asked of the *arguments* rather than of a flag a caller sets,
 * because the arguments are the fact: a renderer cannot compose argv, so
 * `extraArgs` and `fence` are main-process-only by construction, and "was this
 * launch composed by the app" and "did it carry these" are the same question.
 */

let dir = ''
let core: HostCore

beforeAll(() => {
  dir = mkdtempSync(join(tmpdir(), 'td-core-copilot-'))
  /*
   * The folders every case below starts a session in, made rather than assumed.
   *
   * They were only ever named, and on macOS that is survivable — node-pty hands
   * a missing working directory to the shell and something still starts. On
   * Windows `CreateProcess` refuses outright with error 267, ERROR_DIRECTORY,
   * and all four cases in this file failed on the Windows runner while passing
   * here. The subject under test is what gets written into `openSessions`, not
   * whether a shell tolerates a folder that is not there, so the fixture makes
   * the folders and the assertions stay about the thing they are about.
   */
  for (const name of ['copilot', 'fenced', 'live-project']) {
    mkdirSync(join(dir, name), { recursive: true })
  }
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })
})

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  // `maxRetries`, and a warning rather than a throw, for the reason
  // `host-core.agents.test.ts` writes out at length: on Windows the kernel
  // releases a dead process's cwd handle a moment after the process is gone, and
  // inferring "a process escaped" from that clock cost a release build once.
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 40, retryDelay: 250 })
  } catch (error) {
    if (process.platform !== 'win32') throw error
    console.warn(`[host-core.copilot.test] Windows still held ${dir}: ${String(error)}`)
  }
})

/** Every folder currently written down as having been open. */
const remembered = (): string[] => store().getOpenSessions().map((session) => session.cwd)

describe('a session this app composed for itself', () => {
  it('is not written down as a session somebody had open', async () => {
    const copilotHome = join(dir, 'copilot')
    await core.startSession(
      { cwd: copilotHome, cols: 80, rows: 24, provider: 'shell' },
      undefined,
      undefined,
      undefined,
      ['--mcp-config', join(dir, 'deck-control.json'), '--strict-mcp-config'],
    )

    expect(
      remembered(),
      'a launch carrying flags the app composed was remembered as a tab, so the next ' +
        'launch would restore it without them',
    ).not.toContain(copilotHome)
  })

  it('still remembers an ordinary session in the same folder', async () => {
    /*
     * The obvious wrong fix is to exclude the copilot's *folder*, and this is
     * what rules it out. The copilot can be pointed at a folder of the person's
     * own, and a rule keyed on the directory would then stop remembering their
     * real tabs in a real workspace — the app deciding a session was never
     * theirs. Only the arguments say who composed a launch.
     */
    const shared = join(dir, 'copilot')
    await core.startSession({ cwd: shared, cols: 80, rows: 24, provider: 'shell' })

    expect(remembered()).toContain(shared)
  })

  it('is not written down when it carried a fence either', async () => {
    // The other main-process-only argument, and the same argument: a launch held
    // away from this app's own files is a launch this app arranged.
    const fenced = join(dir, 'fenced')
    await core.startSession(
      { cwd: fenced, cols: 80, rows: 24, provider: 'shell' },
      undefined,
      undefined,
      // A fence that changes nothing about the launch, so this test is about
      // being *remembered* and not about what a fence does.
      { apply: (command, args) => ({ command, args: [...args] }) },
    )

    expect(remembered()).not.toContain(fenced)
  })
})

describe('the order the list is written in', () => {
  it('puts the sessions that did not come back before the ones that did', async () => {
    /*
     * `openSessions` is read back in order and restored in order. A held entry is
     * a tab from *before* this launch and every live record is one from during
     * it, so this is the order they were in — and writing the survivors of a
     * failed restore after the sessions that replaced them would reshuffle
     * somebody's tabs a little more on every launch that could not start one.
     */
    const live = join(dir, 'live-project')
    await core.startSession({ cwd: live, cols: 80, rows: 24, provider: 'shell' })
    core.ledger.held.hold(
      {
        cwd: '/home/asad/ClaudeImza',
        provider: 'claude',
        profileId: null,
        cols: 100,
        rows: 30,
        lastSeenAt: 1,
      },
      'it could not be started again',
    )

    const list = store().getOpenSessions()
    expect(list[0]?.cwd).toBe('/home/asad/ClaudeImza')
    // And it is written as the agent that was asked for. This is the whole of
    // the second bug: the app used to answer "claude would not start" by
    // recording `shell`, which made a transient failure permanent.
    expect(list[0]?.provider).toBe('claude')
    expect(list.map((session) => session.cwd)).toContain(live)
  })

  it('writes a held session back to disk the moment it is held', async () => {
    // Held entries live in memory on a `HeldSessions`; what makes them survive is
    // that the ledger's change hook flushes. Without it the whole point is lost —
    // the list on disk would still be replaced by the live map on the next open.
    core.ledger.held.hold(
      {
        cwd: '/home/asad/ClaudeSpace',
        provider: 'claude',
        profileId: null,
        cols: 100,
        rows: 30,
        lastSeenAt: 1,
      },
      'it could not be started again',
    )
    expect(store().getOpenSessions().map((s) => s.cwd)).toContain('/home/asad/ClaudeSpace')
  })
})
