import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { installPaths, nodePaths, resetPaths } from './platform/paths'
import { createHostCore, type HostCore } from './host-core'
import type { ProviderId } from '../shared/types'

/**
 * An added agent, started by the one function that starts sessions.
 *
 * The bug this pins is a silent one and it is the whole reason the wiring goes
 * through `host-core.ts` rather than through the Electron shell.
 * `startSession` chooses its agent with `available[requested] ? requested :
 * 'shell'`, and `detectProviders` answers about the agents in the catalogue —
 * so an id it has never had reads `undefined`, falls to the fallback, and a
 * person who added an agent and pressed Start gets a plain shell with nothing
 * said. `startSession`'s own comments call that failure out twice; this is the
 * third way it could have arrived.
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
   * nothing on POSIX. And retries rather than a `try`/`catch`, because a
   * directory that is *still* locked after two seconds is a process this test
   * failed to kill, which is worth failing over — the whole reason
   * `killAll`/`drain` are above.
   *
   * This only became reachable when the fixture started working on Windows: for
   * as long as `agents.add` refused every path on that platform, no session ever
   * started here and there was nothing holding the folder.
   */
  rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

describe('starting a session on an agent somebody added', () => {
  it('runs that agent, rather than quietly becoming a shell', async () => {
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' })

    expect(meta.provider).toBe('custom:echo')
    // The tell for the bug: `shell` here means the session started, looked
    // fine, and was not the agent that was asked for.
    expect(meta.provider).not.toBe('shell')
  })

  it('falls back to a shell for an added agent that is no longer there', async () => {
    // Not a row in the store at all — the same state as an agent removed in
    // another window, or a session restored from a machine that had one.
    const meta = await core.startSession({
      cwd: dir,
      cols: 80,
      rows: 24,
      provider: 'custom:never-existed' as ProviderId,
    })

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

    const deadline = Date.now() + 4000
    let printed = ''
    while (Date.now() < deadline) {
      printed = core.ptys.scrollback(meta.id)
      if (printed.includes('--strict-mcp-config')) break
      await new Promise((done) => setTimeout(done, 25))
    }

    // The agent's own arguments first, then the launch's — `echo` prints them
    // in the order they were passed, which is the order the CLI parses them in.
    expect(printed).toContain('hello --mcp-config /state/copilot/deck-control.json --strict-mcp-config')
  }, 10_000)

  it('adds nothing to an ordinary session, which is every session but one', async () => {
    // The copilot is the only caller. A session a person opened must have
    // exactly the arguments its agent declares.
    const meta = await core.startSession({ cwd: dir, cols: 80, rows: 24, provider: 'custom:echo' })
    const deadline = Date.now() + 4000
    let printed = ''
    while (Date.now() < deadline) {
      printed = core.ptys.scrollback(meta.id)
      if (printed.includes('hello')) break
      await new Promise((done) => setTimeout(done, 25))
    }
    expect(printed).not.toContain('--mcp-config')
  }, 10_000)

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
