/**
 * The copilot's terminal is not on the network — asserted about the *app*, not
 * about a class.
 *
 * `remote/session-fanout.test.ts` proves the filter works when it is told what
 * to hide, and `remote/server.test.ts` proves a phone asking for a hidden id by
 * hand is refused over a real socket. Both of those passed while this app hid
 * nothing at all, because `SessionFanout` grew a `hidden` predicate and
 * `host-core.ts` never answered it — a capability wired to nothing, which is
 * this repository's most expensive class of bug and the second time it has been
 * paid for.
 *
 * So this file assembles the real core, starts a real session the way the
 * copilot's own module starts one, and asks the real `SessionFanout` — the same
 * object `registerRemoteIpc` is handed — what a paired phone would see.
 *
 * ## What is real here and what is stood in for
 *
 * The `PtyManager` is real and the processes are real: these are two pty
 * sessions with two live shells, and the ids are the ids the app would use. The
 * *binary* is a cheap one rather than Claude Code, because what is under test
 * is which session ids the network may reach, and that is decided by the id and
 * nothing else — the copilot answering questions with a real CLI is proved in
 * `copilot-tools-live.test.ts`, against the real thing.
 */

import { mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { CreateSessionInput, SessionMeta } from '../shared/types'
import { createHostCore, type HostCore } from './host-core'
import { ensureCopilot, resetCopilot, type CopilotRuntimeDeps } from './copilot-session'
import { installPaths, resetPaths } from './platform/paths'
import { resetHomeScopes } from './transcript'

const windows = process.platform === 'win32'
const COMMAND = windows ? 'cmd.exe' : '/bin/sh'
/**
 * A process that stays running for the length of a test *and echoes*.
 *
 * The echo is not incidental — it is the entire instrument. The control case
 * below writes at a session and waits for the characters to come back out
 * through the same data callback the window draws from; without an echo the
 * copilot's silence is indistinguishable from a test that types nowhere at all.
 *
 * `cmd.exe /c timeout /t 30` was here and it does neither: `timeout` reads raw
 * keypresses rather than a line, so it echoes nothing and exits on the first
 * character written at it. An interactive `cmd.exe` is a console application
 * with `ENABLE_ECHO_INPUT` on, which is what a person actually types into and
 * therefore what this should be measuring against.
 */
const ARGS = windows ? [] : ['-c', 'sleep 30']

let dir = ''
let core: HostCore
/** Everything every session printed, keyed by id — the desktop's own data hook. */
let output: Map<string, string>

beforeEach(() => {
  resetCopilot()
  dir = realpathSync(mkdtempSync(join(tmpdir(), 'copilot-network-')))
  installPaths({
    userData: () => dir,
    home: () => dir,
    downloads: () => dir,
    temp: () => dir,
  } as never)
  output = new Map()
  core = createHostCore({
    storageDir: join(dir, 'remote'),
    userData: dir,
    onData: (id, data) => output.set(id, (output.get(id) ?? '') + data),
  })
})

afterEach(async () => {
  core.ptys.killAll()
  await core.ptys.drain()
  resetCopilot()
  resetHomeScopes()
  resetPaths()
  /*
   * Retried, because Windows will not delete a directory anything still holds.
   *
   * `drain()` waits for the pty processes to exit; it cannot wait for the
   * console host behind them to let go of the working directory, which is a
   * moment later and is not observable from here. That showed up as `EBUSY:
   * resource busy or locked, rmdir …\copilot` failing a test whose assertions
   * had all passed — a teardown reported as a result. `maxRetries` is Node's
   * own answer to exactly this, and it is a no-op on POSIX where the unlink
   * succeeds first time.
   */
  rmSync(dir, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 })
})

/**
 * Start a real pty and label it the way the app would.
 *
 * `provider` is a parameter of `create` rather than a fact about the binary, so
 * a session can honestly be *the copilot's session* — the thing this test is
 * about — without a Claude subscription being a prerequisite for running the
 * suite.
 */
function startPty(input: Partial<CreateSessionInput> = {}, provider = 'claude'): SessionMeta {
  return core.ptys.create(
    { cwd: dir, cols: 80, rows: 24, ...input },
    { provider: provider as SessionMeta['provider'], command: COMMAND, args: ARGS, path: process.env.PATH ?? '' },
  )
}

/** The copilot, started through its own module so the wiring under test is used. */
async function startCopilot(): Promise<string> {
  const started: SessionMeta[] = []
  const deps: CopilotRuntimeDeps = {
    userData: () => dir,
    storageDir: () => join(dir, 'remote'),
    platform: process.platform === 'win32' ? 'win32' : 'darwin',
    agents: async () => ({ claude: true, codex: false, gemini: false, shell: true }),
    // No `sandbox-exec` run: the fence is measured against a real kernel in
    // `confine/records.test.ts`, and it decides nothing here.
    fence: async () => ({ fence: null, reason: 'not measured in this test' }),
    profile: () => ({
      id: 'system',
      name: 'Default',
      provider: 'claude',
      configDir: join(dir, '.claude'),
      system: true,
      color: '#000000',
      createdAt: 0,
      lastUsedAt: null,
    }),
    async startSession(input) {
      const meta = startPty({ cwd: input.cwd })
      started.push(meta)
      return meta
    },
    isAlive: (id) => core.ptys.list().some((meta) => meta.id === id && meta.exitCode === null),
    stop: (id) => core.ptys.kill(id),
  }
  const state = await ensureCopilot(deps)
  expect(state.status).toBe('running')
  expect(state.sessionId).toBe(started[0]?.id)
  return state.sessionId as string
}

/** Give a pty a moment to echo, without pinning a duration to a fast machine. */
async function settle(predicate: () => boolean, label: string): Promise<void> {
  const deadline = Date.now() + 2000
  while (Date.now() < deadline) {
    if (predicate()) return
    await new Promise((done) => setTimeout(done, 20))
  }
  throw new Error(`timed out waiting for ${label}`)
}

describe('what a paired phone can see of this app', () => {
  it('lists the sessions a person opened and not the copilot’s', async () => {
    const mine = startPty({ cwd: dir }, 'shell')
    const copilot = await startCopilot()

    // Both are real, both are running, and the app itself can see both.
    expect(core.ptys.list().map((s) => s.id).sort()).toEqual([mine.id, copilot].sort())
    // The network sees one of them.
    expect(core.sessions.list().map((s) => s.id)).toEqual([mine.id])
  })

  it('refuses to attach to the copilot even holding its id', async () => {
    const copilot = await startCopilot()
    /*
     * The id is not a secret and was never going to be one: it appears in
     * `SessionMeta.originRunId` on every session the copilot starts, in the
     * alerts feed, and in the path of a transcript file. A session that is
     * merely unlisted is a session whose keyboard is protected by nobody
     * happening to know a UUID.
     */
    expect(core.sessions.attach(copilot, () => {}, () => {}, () => {})).toBeNull()
    // And the answer is the same one a made-up id gets, so the refusal does not
    // confirm that the id names something real.
    expect(core.sessions.attach('not-a-session', () => {}, () => {}, () => {})).toBeNull()
  })

  it('will not type into it, against a live process', async () => {
    const mine = startPty({ cwd: dir }, 'shell')
    const copilot = await startCopilot()

    /*
     * A pty echoes what is typed at it, which is what makes this observable
     * without a co-operating program: if the write lands, the characters come
     * back out through the same data callback the window draws from. So the
     * control case is asserted first — the fanout really can type at a session
     * — and only then the copilot's silence, which would otherwise be
     * indistinguishable from a test that types nowhere at all.
     */
    core.sessions.write(mine.id, 'echo-me')
    await settle(() => (output.get(mine.id) ?? '').includes('echo-me'), 'the echo from the person’s session')

    core.sessions.write(copilot, 'rm -rf ~/Projects\r')
    core.sessions.resize(copilot, 200, 60)
    // Same wait again, so the copilot gets at least as long to betray itself as
    // the session above took to answer.
    await new Promise((done) => setTimeout(done, 200))
    expect(output.get(copilot) ?? '').not.toContain('rm -rf')
  })

  it('does not offer the copilot’s folder in the folders it advertises', async () => {
    await startCopilot()
    // The offered list is built partly from the cwd of every running session,
    // so without the filter the copilot's own folder turns up in a phone's New
    // Session picker — where `refuseStateDirectory` would refuse it, which is
    // the right answer arriving in the wrong place.
    expect(core.sessions.folders?.('phone-1')).not.toContain(join(dir, 'copilot'))
  })
})
