/**
 * What the CLI does when the record on disk is lying.
 *
 * `cli.test.ts` covers the sentences and `control.test.ts` covers the socket;
 * this is the seam between them, and it exists because of a failure found on a
 * real machine rather than an imagined one.
 *
 * On Asad's WSL Ubuntu the host's record survives a shutdown of the distribution
 * — it is a file on the distribution's own disk — while the process it names
 * does not. Windows then restarts the distribution and **pids restart from 1**,
 * so a record written by a host systemd started early in the previous boot names
 * a low pid that some other service is holding now. `processAlive` says yes, and
 * the CLI believed it: `status` printed "No host is listening here." and exited
 * 1, where its contract is that a switched-off machine is a complete answer
 * worth exit 0; and `pair`, whose entire job is to start the host the first time
 * somebody runs it, refused rather than starting anything.
 *
 * The fix is that the socket is the authority and the record is a hint. These
 * tests pin both halves of it.
 */

import { mkdtempSync, mkdirSync, existsSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import { currentPlatform, type Platform } from '../main/platform/host'
import { nodePaths } from '../main/platform/paths'
import { formatServerAddress, parseServerAddress } from '../shared/server-address'
import { RECORD_FILE, controlPaths, serveControl, writeDaemonRecord, type ControlServer } from './control'
import { run } from './main'

/**
 * The platform this file is RUNNING on, because half of it opens a real channel.
 *
 * Everything else in this folder pins a platform as a value and asserts the
 * string that comes back, which is the right shape for a pure function. The
 * `address` tests below are not that: `hostAnswering` genuinely binds, and a
 * socket is not a value. A POSIX path pinned on a Windows runner is not a Unix
 * socket there — Windows has no such thing — it is a filename, and libuv maps
 * `listen(path)` to a named pipe, so the runner answered
 *
 *     EACCES … \Temp\td-cli-rLLZpM/.local/share/terminaldeck/host.sock
 *
 * on all four of them, faithfully doing what this file told it to. The control
 * channel already has a Windows answer — a named pipe, `\\.\pipe\<brand>-<tag>`,
 * which `controlPaths` picks from exactly this argument — so the fix is to hand
 * it the machine rather than a guess. `hook-server.test.ts` had the identical
 * bug for the identical reason and was fixed the identical way; its header says
 * so. Nothing in `src/headless/control.ts` needed changing.
 */
const PLATFORM: Platform = currentPlatform()

/**
 * A state directory that is not this developer's own — built once for the file.
 *
 * Built through `nodePaths` with an explicit platform rather than by setting
 * `XDG_DATA_HOME`, because the suite runs on macOS where that variable is
 * ignored by design — the real path would be answered instead, and the test
 * would read and then delete the record of whatever host is running on the
 * machine running the tests.
 *
 * The platform handed to `nodePaths` is the SHAPE OF THE DIRECTORY, which is a
 * different question from {@link PLATFORM} above and gets a different answer on
 * a Mac. macOS's own `<home>/Library/Application Support/<id>` is 41 characters,
 * and under a `mkdtemp` home — `/var/folders/…/T/td-cli-XXXXXX`, 61 — appending
 * `/host.sock` lands at 112, past the 104 `sockaddr_un` holds
 * (`MAX_SOCKET_PATH`). `bind` would refuse it with `EINVAL`. The POSIX branch's
 * `<home>/<id>` is 13 and fits with room to spare, so POSIX hosts take the
 * XDG shape and only the *channel* follows the real platform. Windows has
 * neither that directory nor that limit — a pipe name is not a path — so there
 * it is the real one.
 *
 * The env is picked the same way: `nodePaths` reads `APPDATA` on Windows and
 * `XDG_DATA_HOME` everywhere else, and by the XDG rule a `C:\…` value is not
 * absolute and is therefore ignored. That is precisely how this file used to
 * produce `C:\…\Temp\td-cli-rLLZpM/.local/share/terminaldeck` — one path with
 * both separators in it, the fallback branch joined with `posix.join`.
 *
 * One directory for the whole file, and not by preference: `installPaths`
 * refuses a second, different set in one process, because one process is one
 * shell. So the fixture is the record inside this directory, which each test
 * writes for itself.
 */
const HOME = mkdtempSync(join(tmpdir(), 'td-cli-'))
const PATHS = nodePaths({
  platform: PLATFORM === 'win32' ? 'win32' : 'linux',
  env: PLATFORM === 'win32' ? { APPDATA: HOME } : { XDG_DATA_HOME: HOME },
  home: HOME,
  appRoot: HOME,
})
const STATE_DIR = PATHS.userData()
mkdirSync(STATE_DIR, { recursive: true })

/**
 * The channel this machine would really name for this state directory.
 *
 * Written through `controlPaths` rather than as `join(STATE_DIR, 'host.sock')`
 * so that the stale-record cases reach "nothing is listening there" the way
 * production reaches it — a named pipe nobody has created on Windows, a socket
 * file that is not on disk on POSIX, both answering `ENOENT`, which is the code
 * `callControl` turns into `no-listener` and the code those cases are about.
 *
 * A hand-spelled `…/host.sock` happens to answer `ENOENT` on Windows too, since
 * libuv reads it as a pipe name that was never created. That is the accident
 * that let three of these tests pass on the runner while the four that BOUND one
 * failed: the same string is harmless to connect to and impossible to listen on.
 * Asking `controlPaths` removes the accident from both halves.
 */
const SOCKET = controlPaths(STATE_DIR, PLATFORM).socket

function noRecord(): void {
  rmSync(join(STATE_DIR, RECORD_FILE), { force: true })
}

/**
 * A record naming a pid that is certainly alive and is certainly not a host.
 *
 * `process.pid` is this test runner, which is the honest stand-in for the
 * unrelated service that ends up holding the old pid after a reboot: alive, and
 * not listening on that socket.
 */
function staleRecord(): void {
  writeFileSync(
    join(STATE_DIR, RECORD_FILE),
    JSON.stringify({
      pid: process.pid,
      socket: SOCKET,
      token: 'not-the-token',
      startedAt: 1,
      version: '0.0.0-test',
    }),
    'utf8',
  )
}

let written = ''
let complained = ''
const real = process.stdout.write.bind(process.stdout)
const realError = process.stderr.write.bind(process.stderr)
function capture(): void {
  written = ''
  complained = ''
  process.stdout.write = ((chunk: string | Uint8Array): boolean => {
    written += typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8')
    return true
  }) as typeof process.stdout.write
  // Captured separately, and that separation is the point of one of the tests
  // below rather than a convenience: `address` promises that stdout is the token
  // and nothing else, and a harness that merged the two streams could not tell
  // whether it kept that promise.
  process.stderr.write = ((chunk: string | Uint8Array): boolean => {
    complained += typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8')
    return true
  }) as typeof process.stderr.write
}

afterEach(() => {
  process.stdout.write = real
  process.stderr.write = realError
})

describe('a record whose pid has been reused', () => {
  it('answers status as "not running", with exit 0 and somewhere to look', async () => {
    noRecord()
    staleRecord()
    capture()

    const code = await run(['status'], PATHS)

    expect(code).toBe(0)
    expect(written).toContain('not running')
    // The state directory is the one thing a person needs next, and the failure
    // this replaces printed neither it nor any advice.
    expect(written).toContain(STATE_DIR)
    expect(written).not.toContain('No host is listening here.')
  })

  it('deletes the record it found to be lying', async () => {
    noRecord()
    staleRecord()
    capture()

    await run(['status'], PATHS)

    expect(existsSync(join(STATE_DIR, RECORD_FILE))).toBe(false)
  })

  it('tells a folders command to start a host rather than refusing blankly', async () => {
    noRecord()
    staleRecord()
    capture()

    // Not `pair`: that one goes on to spawn a real host, which is not a unit
    // test's business. Every other command takes the identical branch, and this
    // asserts the branch — the advice a person is given instead of a syscall.
    const code = await run(['folders'], PATHS)

    expect(code).toBe(1)
    expect(written).toContain(`${BRAND.id}-host`)
    expect(written).toContain(`${BRAND.id} pair`)
  })
})

describe('a record for a pid that is simply gone', () => {
  it('is the same answer, since neither record describes a live host', async () => {
    noRecord()
    // A pid that cannot exist. `processAlive` already caught this case; it is
    // here so the two ways a record goes stale are pinned side by side and
    // nobody has to guess whether they still agree.
    writeFileSync(
      join(STATE_DIR, RECORD_FILE),
      JSON.stringify({
        pid: 0x7fffffff,
        socket: SOCKET,
        token: 't',
        startedAt: 1,
        version: '0.0.0-test',
      }),
      'utf8',
    )
    capture()

    const code = await run(['status'], PATHS)

    expect(code).toBe(0)
    expect(written).toContain('not running')
  })
})

describe('a state directory with no record at all', () => {
  it('is not an error, because a machine that is off is a complete answer', async () => {
    noRecord()
    capture()

    const code = await run(['status'], PATHS)

    expect(code).toBe(0)
    expect(written).toContain('not running')
    expect(written).toContain(STATE_DIR)
  })
})

/**
 * `terminaldeck address`, over a real control socket.
 *
 * A stand-in host rather than the real daemon, because what is under test here
 * is the *command* — which stream each half goes to, and what the exit code says
 * — and the address itself is derived by `addressOf` from the relay state this
 * socket hands back. `address-live.test.ts` is the other half: a genuine host
 * identity, minted for real, parsing back into its own three facts.
 */
const ADDRESS = formatServerAddress({
  url: 'wss://relay.terminaldeck.dev',
  hostId: 'A2B3C4D5E6F7G8H9JKLMNPQSTU',
  hostKey: Buffer.alloc(32, 7).toString('base64url'),
}) as string

/**
 * A stand-in, plus the one thing about it worth asserting: how often it was asked.
 *
 * The call count is what tells "gave up at once" from "stood there polling", and
 * it is used instead of a wall clock on purpose. Timing this from outside would
 * be a measurement of the runner: `vitest.config.ts` documents a **25x** spread
 * on identical bytes on `windows-latest`, with tests that touch ten files taking
 * seven seconds. A budget tight enough to catch a ten-second wait would be a
 * budget that runner fails at random, and a budget loose enough to survive it
 * would no longer catch the wait.
 */
type StandIn = ControlServer & { calls(): number }

async function hostAnswering(relay: unknown, extra: Record<string, unknown> = {}): Promise<StandIn> {
  return hostAnsweringEach(() => relay, extra)
}

/**
 * A stand-in whose relay state can differ from one `status` to the next.
 *
 * The relay connection is made *after* the host starts, so "not on the relay"
 * and "on the relay" are the same host a second apart — which a stand-in with
 * one fixed answer cannot express, and which is exactly the case `address` got
 * wrong on a real server.
 */
async function hostAnsweringEach(
  relayFor: (call: number) => unknown,
  extra: Record<string, unknown> = {},
): Promise<StandIn> {
  noRecord()
  const token = 'a-token'
  let calls = 0
  const control = await serveControl({
    // The machine's own channel and the machine's own platform, because this
    // line opens a real listener and the two platforms do not have the same
    // kind of thing to open.
    //
    // Every stand-in in this file reuses the one name, exactly as a host
    // restarting on one machine does. That is safe only because each is awaited
    // to `close()` in a `finally` — and if one ever is not, Windows says so
    // rather than hiding it: `FILE_FLAG_FIRST_PIPE_INSTANCE` turns a second bind
    // on a live pipe name into EADDRINUSE instead of quietly stealing it.
    socket: SOCKET,
    token,
    platform: PLATFORM,
    handle: async (cmd) => {
      if (cmd !== 'status') throw new Error(`this stand-in only answers status, not ${cmd}`)
      calls += 1
      return { ...extra, remote: { relay: relayFor(calls) } }
    },
  })
  writeDaemonRecord(STATE_DIR, {
    pid: process.pid,
    socket: SOCKET,
    token,
    startedAt: Date.now(),
    version: '0.0.0-test',
  })
  return { close: () => control.close(), calls: () => calls }
}

const CONNECTED_RELAY = {
  url: 'wss://relay.terminaldeck.dev',
  hostId: 'A2B3C4D5E6F7G8H9JKLMNPQSTU',
  publicKey: Buffer.alloc(32, 7).toString('base64url'),
  fingerprint: 'AAAA-BBBB',
  connected: true,
  channels: 0,
  reason: null,
  retryAt: null,
}

describe('the address command', () => {
  it('puts the address on stdout and every sentence it has on stderr', async () => {
    const control = await hostAnswering({
      url: 'wss://relay.terminaldeck.dev',
      hostId: 'A2B3C4D5E6F7G8H9JKLMNPQSTU',
      publicKey: Buffer.alloc(32, 7).toString('base64url'),
      fingerprint: 'AAAA-BBBB',
      connected: true,
      channels: 0,
      reason: null,
      retryAt: null,
    })
    capture()

    try {
      const code = await run(['address'], PATHS)

      expect(code).toBe(0)
      // The promise `install-headless.sh` relies on: `A=$(… address)` is an
      // address, not an address with prose stuck to it.
      expect(written.trim()).toBe(ADDRESS)
      expect(parseServerAddress(written)).not.toBeNull()
      expect(complained).toContain('Add a server')
      expect(complained).toContain('not a secret')
      expect(complained).not.toContain(ADDRESS)
    } finally {
      await control.close()
    }
  })

  it('writes nothing to stdout and exits 1 when there is no address to give', async () => {
    const control = await hostAnswering(null)
    capture()

    try {
      const code = await run(['address'], PATHS)

      // Nothing shaped like an address, so nothing to paste and then wonder
      // about minutes later at a handshake.
      expect(code).toBe(1)
      expect(written).toBe('')
      expect(complained).toContain('not dialling out to a relay')
    } finally {
      await control.close()
    }
  })

  /*
   * The install-script race, pinned.
   *
   * `install.sh` starts the host and asks for the address in the next breath, so
   * the first `status` legitimately answers "no relay yet". Reporting that as the
   * final word is how an installer ends by telling somebody the thing they just
   * installed cannot be reached — measured happening on a real server on
   * 2026-08-22, with the address available fourteen seconds later.
   */
  it('waits for a host that has only just started to reach the relay', async () => {
    const control = await hostAnsweringEach(
      (call) => (call < 3 ? null : CONNECTED_RELAY),
      { startedAt: Date.now() },
    )
    capture()

    try {
      const code = await run(['address'], PATHS)
      expect(code).toBe(0)
      expect(written.trim()).toBe(ADDRESS)
      // It asked again rather than believing the first "no relay yet", which is
      // the whole of the fix and the half a passing address alone cannot prove.
      expect(control.calls()).toBe(3)
    } finally {
      await control.close()
    }
  })

  /*
   * And the other direction, which is what keeps the wait from becoming a hang:
   * a host that has been up for an hour and is not on the relay has a real
   * problem, and ten more seconds of standing there would not find it.
   */
  it('does not wait for a host that has been up long enough to know better', async () => {
    const control = await hostAnswering(null, { startedAt: Date.now() - 60 * 60 * 1000 })
    capture()

    try {
      const code = await run(['address'], PATHS)
      expect(code).toBe(1)
      expect(written).toBe('')
      // Asked once, and that is the assertion — not a stopwatch. See {@link
      // StandIn}: on `windows-latest` a wall-clock budget measures the runner's
      // luck rather than this command's behaviour, and the two things it would
      // have to tell apart are one round trip and one round trip plus
      // `ADDRESS_WAIT_MS`.
      expect(control.calls()).toBe(1)
    } finally {
      await control.close()
    }
  })
})
