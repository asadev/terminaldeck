import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { createHostCore, type HostCore } from './host-core'
import type { ProviderId } from '../shared/types'

/**
 * The two ceilings this file states for itself, and why it may not take the
 * default.
 *
 * These cases spawn a *real* pty and wait for a real program's output to come
 * back through it. On this Mac that is a `fork` and a few milliseconds; on
 * Windows it is a ConPTY, which is a process launch plus a pseudoconsole
 * handshake, on a runner `vitest.config.ts` has measured at roughly 25x
 * scheduling variance for unchanged code.
 *
 * Both numbers had to move, because they fail in different ways and only one of
 * them was visible. The `it()` argument overrides the 30 s Windows allowance the
 * config exists to provide — so this file opted out of it with a figure chosen
 * on a Mac. The in-body deadline is worse: no config setting can reach it at
 * all, so a slow spawn does not time the test out, it makes the loop give up
 * and assert against whatever had been printed by then — a *wrong answer*
 * rather than a red clock.
 *
 * POSIX values are unchanged, deliberately: this is where the work is done and
 * the tight ceiling is what would notice a genuine slowdown. The shape is
 * `readiness.test.ts`'s, which `vitest.config.ts` endorses in as many words.
 */
const PTY_ECHO_MS = process.platform === 'win32' ? 20_000 : 4000
const PTY_CASE_MS = process.platform === 'win32' ? 45_000 : 10_000

/**
 * An added agent, started by the one function that starts sessions.
 *
 * The bug this pins is a silent one and it is the whole reason the wiring goes
 * through `host-core.ts` rather than through the Electron shell. `startSession`
 * used to choose its agent with `available[requested] ? requested : 'shell'`,
 * and `detectProviders` answers about the agents in the catalogue — so an id it
 * has never had read `undefined`, fell to the fallback, and a person who added
 * an agent and pressed Start got a plain shell with nothing said.
 *
 * That fallback is gone, and the second half of this file is why: it turned a
 * failure to start into a *record* of what was open, so the downgrade outlived
 * the thing that caused it. Asking for an agent that cannot run now refuses and
 * says so, and the tests below pin both halves — an added agent that is there
 * runs, and one that is not produces no session and a sentence naming it.
 *
 * A real core, a real pty and a real command, because every part of the chain
 * that could be stubbed here is a part that has been wrong before: the launcher
 * that wraps a command for Windows, the lookup that decides whether a command
 * can run, and the fallback itself.
 *
 * `/bin/echo` on POSIX and `cmd.exe /c` on Windows, resolved as an *absolute
 * path* — which is the branch of `lookupCommand` that checks the executable bit
 * rather than shelling out to `which`, so this test never depends on what
 * happens to be installed on the machine running it.
 *
 * ## What the assertion in the fixture caught
 *
 * `expect(added.ok, …)` below is there so that a failure lands on the setup
 * rather than as three mysterious failures underneath it, and on the Windows
 * runner it did exactly that: the agent could not be added at all. The cause was
 * not this fixture being POSIX-shaped — the command above is already the right
 * one for the platform. It was the feature. `validateDraft` refused any command
 * containing a backslash, which is every absolute path on Windows, so no Windows
 * user could add an agent by path either. Fixed in `shared/custom-agents.ts`,
 * where the reasoning is written out, and pinned in `custom-agents.test.ts` on
 * both platforms. The lesson worth keeping is the shape of it: the untestable
 * branch was refused on a Mac with a comment saying nothing here runs on
 * Windows, in a repository that ships a Windows installer from every tag.
 */

const windows = process.platform === 'win32'
const REAL_COMMAND = windows ? `${process.env.SystemRoot ?? 'C:\\Windows'}\\System32\\cmd.exe` : '/bin/echo'

let dir = ''
let core: HostCore

beforeAll(async () => {
  dir = mkdtempSync(join(tmpdir(), 'td-core-agents-'))
  installPaths(nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: dir }, home: dir, appRoot: dir }))
  core = createHostCore({ storageDir: join(dir, 'remote'), userData: dir })

  const added = await core.agents.add({
    label: 'Echo',
    description: '',
    command: REAL_COMMAND,
    args: 'hello',
    resumeArgs: '',
  })
  expect(added.ok, 'the fixture agent has to be addable, or nothing below means anything').toBe(true)
}, 30_000)

afterAll(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  await core.credentials.stop()
  resetPaths()
  /*
   * `maxRetries`, and it is Windows that needs it.
   *
   * The sessions above run in this directory, so it is the working directory of
   * a real child process. On Windows a directory with a handle open on it — and
   * a process's own cwd is such a handle — cannot be removed, and the handle
   * outlives the process by a moment: `drain()` returns when the pty reports
   * exit, while the kernel releases the last reference some milliseconds later,
   * and ConPTY has its own helper process that closes on its own schedule. So
   * the first `rm` lands on `EPERM` and the second, a tenth of a second later,
   * does not. POSIX has no such rule — an unlinked directory is unlinked — so
   * this costs nothing there.
   *
   * `maxRetries` rather than a sleep because Node implements exactly this: it
   * retries `EBUSY`, `EMFILE`, `ENFILE`, `ENOTEMPTY` and `EPERM` on Windows and
   * nothing on POSIX.
   *
   * ## Why a residual failure is reported and not thrown
   *
   * This block used to end by letting `rmSync` throw, arguing that a directory
   * still locked after two seconds is a process this test failed to kill. That
   * is the right instinct pointed at the wrong evidence, and it cost a release
   * build on 2026-08-17: **9136 tests passed and the run failed on `EBUSY`
   * rmdir'ing a temp folder**, after twenty retries, on a shared runner.
   *
   * The claim worth defending is *the process is dead*, and it is already
   * proved directly, one line above: `drain()` resolves when the pty reports
   * exit. What remains after that is ConPTY's helper closing on its own
   * schedule and the kernel dropping its last reference — neither of which this
   * test can hurry, and neither of which says anything about a leak. Inferring
   * "a process escaped" from "Windows had not let go within two seconds on a
   * machine running four jobs" is inferring the wrong thing from a clock.
   *
   * So the retries stay and get real headroom, and what is left is written to
   * the log rather than thrown. The directory is in `%TEMP%`, which the OS
   * cleans; a stray one there is untidy, not wrong. If a genuinely un-killed
   * process is ever the cause, `drain()` is where that has to fail, because
   * that is the assertion that actually knows.
   */
  try {
    rmSync(dir, { recursive: true, force: true, maxRetries: 40, retryDelay: 250 })
  } catch (error) {
    // Never on POSIX: an unlinked directory is unlinked, so a failure here
    // would be a real one and is still surfaced.
    if (process.platform !== 'win32') throw error
    console.warn(
      `[host-core.agents.test] Windows still held ${dir} after the shell exited; ` +
        `leaving it for the OS to clean. ${String(error)}`,
    )
  }
})

describe('starting a session on an agent somebody added', () => {
  it('runs that agent, rather than quietly becoming a shell', async () => {
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' })

    expect(meta.provider).toBe('custom:echo')
    // The tell for the bug: `shell` here means the session started, looked
    // fine, and was not the agent that was asked for.
    expect(meta.provider).not.toBe('shell')
  })

  /**
   * What happens when the agent that was asked for cannot be run.
   *
   * This test used to be called *"falls back to a shell for an added agent that
   * is no longer there"*, and it passed, and the behaviour it was pinning is the
   * bug Asad reported on 2026-08-17. A session whose agent could not be started
   * opened as a plain terminal instead — same tab, same folder, nothing said —
   * and then the ledger wrote *that* down as what was open. Every launch
   * afterwards restored a shell, correctly reported that a shell has no
   * conversation to continue, and never tried the real agent again. A distro
   * that was asleep for eight seconds became a permanent downgrade.
   *
   * So the intent is kept and the answer is inverted: asking for an agent that
   * cannot run must produce **no session at all**, and a sentence naming the
   * agent. Refusing is what makes the failure recoverable — nothing is written
   * down, the request is held as itself (`session-held.ts`), and installing the
   * CLI tomorrow is enough to make the same session start.
   *
   * `custom:never-existed` is not a row in the store at all, which is the same
   * state as an agent removed in another window, or a session restored from a
   * machine that had one.
   */
  it('refuses, rather than quietly starting something else', async () => {
    const before = core.ptys.list().length

    await expect(
      core.startSession({
        cwd: dir,
        cols: 80,
        rows: 24,
        provider: 'custom:never-existed' as ProviderId,
      }),
      'starting an agent that cannot run must not hand back a session',
    ).rejects.toThrow(/could not be found/)

    // Nothing was spawned. A refusal that still left a process behind would be
    // the downgrade wearing a different name.
    expect(core.ptys.list().length).toBe(before)
  })

  it('names the agent it could not start, and where it looked', async () => {
    /*
     * The message is the whole of what most people will ever see of this, so it
     * is pinned rather than left to whoever edits the throw next. Two facts have
     * to be in it: *which* agent, because a person with three configured needs
     * to know which one to install, and *where this app looked* — "on this
     * machine" and "inside the WSL distribution" are different problems with
     * different fixes, and the machine whose work lives in Ubuntu is exactly the
     * machine that would otherwise read a sentence about PATH and check the
     * wrong PATH.
     */
    const error = await core
      .startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:never-existed' as ProviderId })
      .then(
        () => null,
        (thrown: unknown) => thrown,
      )

    expect(error).toBeInstanceOf(Error)
    const message = error instanceof Error ? error.message : ''
    expect(message).toContain('custom:never-existed')
    expect(message).toContain('on this machine')
    expect(message, 'the sentence has to say that nothing was started').toMatch(/not started/)
  })

  it('still starts a shell when a shell is what was asked for', async () => {
    // The refusal above must not become "this app cannot open a terminal".
    // `available.shell` is always true, so asking for one can never reach the
    // throw — pinned because the obvious wrong fix to the test above is a guard
    // that catches `shell` on its way past.
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'shell' })
    expect(meta.provider).toBe('shell')
  })

  /**
   * The flags a launch adds reach the real process, and are read off it.
   *
   * This is the seam the copilot's tools travel through: `startSession(input,
   * guest, confine, fence, extraArgs)`, with `--mcp-config <file>
   * --strict-mcp-config`. Before it existed there was nowhere on the spawn path
   * to put a flag, so the copilot had none of this app's tools while every
   * screen in the product described the gate in front of them.
   *
   * Asserted against a process's *output* rather than against a spec, because
   * the whole failure being guarded is a value that looks right in the object
   * and never arrives at `execvp`. `/bin/echo` is the one command that will say
   * what it was given.
   */
  it.skipIf(windows)('hands a launch’s extra flags to the process itself', async () => {
    const meta = await core.startSession(
      { cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' },
      undefined,
      undefined,
      undefined,
      ['--mcp-config', '/state/copilot/deck-control.json', '--strict-mcp-config'],
    )

    const deadline = Date.now() + PTY_ECHO_MS
    let printed = ''
    while (Date.now() < deadline) {
      printed = core.ptys.scrollback(meta.id)
      if (printed.includes('--strict-mcp-config')) break
      await new Promise((done) => setTimeout(done, 25))
    }

    // The agent's own arguments first, then the launch's — `echo` prints them
    // in the order they were passed, which is the order the CLI parses them in.
    expect(printed).toContain('hello --mcp-config /state/copilot/deck-control.json --strict-mcp-config')
  }, PTY_CASE_MS)

  it('adds nothing to an ordinary session, which is every session but one', async () => {
    // The copilot is the only caller. A session a person opened must have
    // exactly the arguments its agent declares.
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' })
    const deadline = Date.now() + PTY_ECHO_MS
    let printed = ''
    while (Date.now() < deadline) {
      printed = core.ptys.scrollback(meta.id)
      if (printed.includes('hello')) break
      await new Promise((done) => setTimeout(done, 25))
    }
    expect(printed).not.toContain('--mcp-config')
  }, PTY_CASE_MS)

  it('records no account against it, because none was isolated', async () => {
    // `supportsProfiles` is false for an agent whose config directory this app
    // cannot redirect, and an added agent is exactly that. Labelling the session
    // with an account name would be a claim about isolation nothing made happen.
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' })
    expect(meta.profileId).toBeUndefined()
    expect(meta.profileName).toBeUndefined()
  })
})

describe('whether a provider can continue a conversation', () => {
  it('answers for an added agent from its own record', () => {
    // Empty resume arguments is the default and the safe answer, so the picker
    // must not offer resume for it.
    expect(core.canContinue('custom:echo')).toBe(false)
  })

  it('still answers for the agents this build ships', () => {
    expect(core.canContinue('claude')).toBe(true)
    expect(core.canContinue('shell')).toBe(false)
  })

  it('answers false for a name nothing knows, instead of throwing', () => {
    /*
     * This is the crash, not a nicety. Both shells asked
     * `PROVIDERS[provider].resumeArgs` while planning a restore, which throws
     * outright on an id the table has never had — so one saved session naming an
     * added agent took the whole restore down with it, and every other tab in
     * the list with it.
     */
    expect(() => core.canContinue('custom:gone')).not.toThrow()
    expect(core.canContinue('custom:gone')).toBe(false)
    expect(core.canContinue('retired-agent' as ProviderId)).toBe(false)
  })
})
