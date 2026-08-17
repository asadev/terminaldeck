import { execFile } from 'node:child_process'
import { mkdirSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { confinedEnv, planFor, realResolver } from './confine'
import type { ConfinementPlan } from './confine/plan'
import { SANDBOX_EXEC, seatbeltProfile } from './confine/seatbelt'
import {
  boundaryAllows,
  boundaryFor,
  forgetBoundary,
  noteBoundary,
  resetBoundaries,
} from './session-boundary'

/**
 * The claim this module makes, and the one measurement it stands on.
 *
 * The claim is: on a confined session, an attachment from outside the granted
 * folder is not a feature, it is a chip and a mention followed by an agent
 * saying it cannot open the file. Everything in the composer that greys out the
 * Browse row rests on that being true, so the last test here does not assert
 * anything about this module at all — it asks the real `sandbox-exec`, with the
 * real generated profile, to read a real file outside the plan, and fails if the
 * bytes come back.
 *
 * That is the same shape as `confine/escapes.test.ts`, deliberately: this is not
 * a second proof of the boundary, it is the *attach* feature refusing to ship a
 * refusal it has not watched happen. If confinement ever stops holding, the two
 * files fail together and the UI's sentence stops being true in the same commit.
 */

beforeEach(() => {
  resetBoundaries()
})

afterEach(() => {
  resetBoundaries()
})

/**
 * A plan written out by hand rather than built by `sessionPlan`.
 *
 * The unit tests below are about what this module *keeps* and what it *answers*,
 * and a real plan would drag in a resolver, a filesystem and a platform's tool
 * roots — every one of which would make these assertions depend on the machine
 * they run on. The real thing is exercised at the bottom of this file, against
 * the real sandbox.
 */
const PLAN: ConfinementPlan = {
  folder: '/Users/apple/granted',
  accountHome: '/Users/apple',
  home: '/Users/apple/Library/Application Support/x/device-homes/abc',
  writable: ['/Users/apple/granted', '/Users/apple/Library/Application Support/x/device-homes/abc'],
  readable: ['/usr', '/bin'],
  readableFiles: ['/Users/apple/Library/Application Support/x/helper.sh'],
  readableProjects: ['/Users/apple/Projects/thing'],
  readExclusions: [],
}

describe('remembering what a session is held inside', () => {
  it('answers null for a session nobody noted, which is every window session', () => {
    // The absence *is* the answer. A session started at this keyboard has no
    // grant to be held inside, so writing an "unconfined" entry for it would be
    // a second spelling of the same fact and one more thing to keep in step.
    expect(boundaryFor('never-noted')).toBeNull()
  })

  it('keeps the folder and both reachable lists', () => {
    noteBoundary('s1', PLAN, 'darwin')
    const boundary = boundaryFor('s1')
    expect(boundary?.folder).toBe('/Users/apple/granted')
    expect(boundary?.readable).toContain('/Users/apple/granted')
    expect(boundary?.readable).toContain('/usr')
    expect(boundary?.readableFiles).toContain('/Users/apple/Library/Application Support/x/helper.sh')
  })

  it('forgets a session when it exits', () => {
    noteBoundary('s2', PLAN, 'darwin')
    forgetBoundary('s2')
    expect(boundaryFor('s2')).toBeNull()
  })
})

describe('what a boundary allows', () => {
  const boundary = (() => {
    noteBoundary('s3', PLAN, 'darwin')
    const found = boundaryFor('s3')
    if (found === null) throw new Error('unreachable')
    return found
  })()

  it('allows the granted folder and everything under it', () => {
    expect(boundaryAllows(boundary, '/Users/apple/granted')).toBe(true)
    expect(boundaryAllows(boundary, '/Users/apple/granted/src/main.ts')).toBe(true)
  })

  it('refuses the desktop, the home directory and another project', () => {
    // The three places a person actually keeps the file they want to attach.
    expect(boundaryAllows(boundary, '/Users/apple/Desktop/shot.png')).toBe(false)
    expect(boundaryAllows(boundary, '/Users/apple/.ssh/id_ed25519')).toBe(false)
    expect(boundaryAllows(boundary, '/Users/apple/Projects/other/README.md')).toBe(false)
  })

  it('is not fooled by a sibling whose name starts the same way', () => {
    // `/Users/apple/granted-old` is not inside `/Users/apple/granted`, and a
    // prefix test with no separator in it says otherwise.
    expect(boundaryAllows(boundary, '/Users/apple/granted-old/x.txt')).toBe(false)
  })

  it('allows the individual files the plan lists without their directory', () => {
    expect(
      boundaryAllows(boundary, '/Users/apple/Library/Application Support/x/helper.sh'),
    ).toBe(true)
    // The sibling in the same directory stays refused: that directory holds
    // every *other* device's guest git identity.
    expect(
      boundaryAllows(boundary, '/Users/apple/Library/Application Support/x/other-device.conf'),
    ).toBe(false)
  })
})

/* ------------------------------------------------------------ the measurement -- */

const onMac = process.platform === 'darwin'

describe.skipIf(!onMac)('why the Browse row is refused on a confined session', () => {
  it('a confined session really cannot read an attachment from outside its folder', async () => {
    /*
     * Not a unit test and not meant to be. The composer tells the user that a
     * session held inside a folder "cannot read a file from anywhere else", and
     * a sentence on screen is only worth what the thing behind it does. So this
     * writes a file where somebody would actually keep a screenshot — outside
     * the granted folder — and asks the real sandbox to read it with the real
     * profile, exactly as an `@"/abs/path"` mention would make the agent do.
     */
    const root = mkdtempSync(join(realpathSync(tmpdir()), 'td-attach-confine-'))
    try {
      const granted = join(root, 'granted')
      const desktop = join(root, 'desktop')
      const deviceHome = join(root, 'device-home')
      mkdirSync(granted)
      mkdirSync(desktop)
      mkdirSync(join(deviceHome, 'tmp'), { recursive: true })

      const secret = 'attachment-bytes-that-must-not-be-readable-4c19'
      const attachment = join(desktop, 'screenshot.png')
      writeFileSync(attachment, secret)

      const plan = planFor({
        folder: granted,
        device: { home: deviceHome, writable: [], files: [] },
        accountHome: homedir(),
        path: process.env.PATH ?? '/usr/bin:/bin',
        platform: 'darwin',
        resolver: realResolver,
      })
      const profile = seatbeltProfile(plan)

      const run = (args: string[]): Promise<{ stdout: string; stderr: string }> =>
        new Promise((resolve) => {
          execFile(
            SANDBOX_EXEC,
            ['-p', profile, ...args],
            {
              cwd: granted,
              timeout: 20_000,
              encoding: 'utf8',
              env: { ...process.env, ...confinedEnv(deviceHome) },
            },
            (_error, stdout, stderr) => resolve({ stdout, stderr }),
          )
        })

      // The positive half first. Without it a profile so broken that nothing
      // runs would "pass" the refusal below by failing at everything — the exact
      // shape of false confidence `confine/index.ts` warns about.
      const alive = await run(['/bin/echo', 'alive'])
      expect(alive.stdout.trim()).toBe('alive')

      const read = await run(['/bin/cat', attachment])
      expect(read.stdout, 'a file outside the folder was readable from inside').not.toContain(secret)

      // And the app's own answer agrees with the machine's, which is the point:
      // the sentence the composer prints is derived from the same fact the OS
      // is enforcing, not from a guess beside it.
      noteBoundary('measured', plan, 'darwin')
      const boundary = boundaryFor('measured')
      expect(boundary).not.toBeNull()
      if (boundary !== null) expect(boundaryAllows(boundary, attachment)).toBe(false)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})
