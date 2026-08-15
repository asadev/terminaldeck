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
import { nodePaths } from '../main/platform/paths'
import { RECORD_FILE } from './control'
import { run } from './main'

/**
 * A state directory that is not this developer's own — built once for the file.
 *
 * Built through `nodePaths` with an explicit platform rather than by setting
 * `XDG_DATA_HOME`, because the suite runs on macOS where that variable is
 * ignored by design — the real path would be answered instead, and the test
 * would read and then delete the record of whatever host is running on the
 * machine running the tests.
 *
 * One directory for the whole file, and not by preference: `installPaths`
 * refuses a second, different set in one process, because one process is one
 * shell. So the fixture is the record inside this directory, which each test
 * writes for itself.
 */
const HOME = mkdtempSync(join(tmpdir(), 'td-cli-'))
const PATHS = nodePaths({ platform: 'linux', env: { XDG_DATA_HOME: HOME }, home: HOME, appRoot: HOME })
const STATE_DIR = PATHS.userData()
mkdirSync(STATE_DIR, { recursive: true })

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
      socket: join(STATE_DIR, 'host.sock'),
      token: 'not-the-token',
      startedAt: 1,
      version: '0.0.0-test',
    }),
    'utf8',
  )
}

let written = ''
const real = process.stdout.write.bind(process.stdout)
function capture(): void {
  written = ''
  process.stdout.write = ((chunk: string | Uint8Array): boolean => {
    written += typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString('utf8')
    return true
  }) as typeof process.stdout.write
}

afterEach(() => {
  process.stdout.write = real
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
        socket: join(STATE_DIR, 'host.sock'),
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
