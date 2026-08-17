import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve, sep } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { capabilitySid, installWindowsTools, resetWindowsTools, writeGrantRecord } from './tools'
import { confinedHomeEnv } from './index'
import { confinedEnv } from './plan'
import { windowsConfinedEnv } from './appcontainer'

/**
 * One branch, in one place, exercised on both sides from a Mac.
 *
 * ## What went wrong, and why a unit test of either half would have missed it
 *
 * A confined session's home is expressed differently on Windows than on POSIX —
 * `HOME`/`TMPDIR` on one side, `USERPROFILE`/`APPDATA`/`TEMP` and the rest on
 * the other — so there are two functions and something has to choose between
 * them. That choice was written inline in `host-core.ts` and, when the copilot's
 * sign-in probe arrived later, not written at all: it called `confinedEnv`
 * directly. Both files read correctly on their own. Both had tests. The bug was
 * in neither of them; it was in there being two copies of a decision.
 *
 * So the thing under test here is the *choice*, as a function, with both of its
 * answers produced on this machine — and the check that no other file has grown
 * a second copy of it.
 *
 * ## Making a Mac answer `'appcontainer'`
 *
 * `confinementKind('win32')` is not a property of the platform: it asks the disk
 * whether the launcher is installed and the one-time grant recorded. Both of
 * those are files, and `installWindowsTools` takes their paths, so a temporary
 * directory with a launcher-shaped file and a valid grant record is enough to
 * reach the Windows arm from here. That is the whole reason those two are
 * injectable, and it is the difference between testing this branch and
 * asserting that somebody remembered to write it.
 */

const HOME_POSIX = '/Users/x/Library/Application Support/td/remote/device-homes/abc'
const HOME_WIN = 'C:\\Users\\Imza\\AppData\\Roaming\\td\\device-homes\\abc'

let dir: string | null = null

afterEach(() => {
  // The install is module state, and a case that leaked it would make the next
  // one answer 'appcontainer' for reasons it never asked for.
  resetWindowsTools()
  if (dir !== null) rmSync(dir, { recursive: true, force: true })
  dir = null
})

/** A machine that has the launcher and has been granted, as far as the disk shows. */
function setUpWindowsMachine(): void {
  dir = mkdtempSync(join(tmpdir(), 'confined-home-env-'))
  const launcher = join(dir, 'tdconfine.exe')
  writeFileSync(launcher, '')
  const recordFile = join(dir, 'win-confine-grant.json')
  writeGrantRecord(recordFile, {
    capability: capabilitySid(),
    read: ['C:\\Program Files\\nodejs'],
    ancestors: ['C:\\'],
    established: '2026-08-17T00:00:00.000Z',
  })
  installWindowsTools({ launcher, recordFile })
}

describe('confinedHomeEnv picks the spelling the platform actually reads', () => {
  it('gives macOS and Linux the POSIX environment, unchanged', () => {
    expect(confinedHomeEnv(HOME_POSIX, 'darwin')).toEqual(confinedEnv(HOME_POSIX))
    expect(confinedHomeEnv(HOME_POSIX, 'linux')).toEqual(confinedEnv(HOME_POSIX))
  })

  it('gives a set-up Windows machine the Windows environment', () => {
    setUpWindowsMachine()
    const env = confinedHomeEnv(HOME_WIN, 'win32')
    expect(env).toEqual(windowsConfinedEnv(HOME_WIN))
    // Named individually as well, because `toEqual` against the other function
    // would still pass if both were quietly emptied.
    expect(env.USERPROFILE).toBe(HOME_WIN)
    expect(env.APPDATA).toContain('AppData\\Roaming')
    expect(env.TEMP).toBe(`${HOME_WIN}\\tmp`)
    // The variable the POSIX branch grew first and this one did not. It is not
    // a Windows spelling of `TMPDIR` — Claude Code reads it on both platforms
    // and falls back to a literal `/tmp` on neither's terms.
    expect(env.CLAUDE_CODE_TMPDIR).toBe(env.TEMP)
  })

  it('gives a Windows machine that has not been set up the POSIX environment, and that is right', () => {
    /*
     * Before the one-time grant `confinementKind('win32')` is `'none'`, so there
     * is no boundary and no redirected home — and nothing calls this, because
     * every caller gates on the same question first. Answering with the POSIX
     * shape here is not a fallback anybody relies on; it is what "there is no
     * Windows boundary to describe" looks like from a function that must return
     * something. Pinned so that a future reader does not mistake it for the bug
     * this file is about and "fix" it into always spelling Windows.
     */
    expect(confinedHomeEnv(HOME_WIN, 'win32')).toEqual(confinedEnv(HOME_WIN))
  })
})

describe('the choice is made in one place', () => {
  /*
   * The regression this file exists for was a *second copy* of the branch, not a
   * wrong branch — so the last check is structural: which modules outside
   * `confine/` reach for one half of it, and whether each of them is a module
   * somebody has thought about.
   *
   * `confine/` itself is exempt. That is where both halves are written, where
   * the choice is made, and where these tests live.
   *
   * ## Why an allowlist rather than "nobody, ever"
   *
   * Because "nobody" has not been true and pretending it is would make this a
   * test that gets disabled rather than read. `host-core.ts` is where the branch
   * was first written, and written *correctly*; it is on the list by name and by
   * reason. What must never grow is a *second* entry added without one — which
   * is exactly what `copilot-session.ts` was: a new module that called
   * `confinedEnv` because that is the obvious name, on a platform nobody
   * reviewing the diff was sitting at.
   *
   * So the failure this produces is not "you called a forbidden function". It is
   * "a new module is making this decision for itself — call `confinedHomeEnv`,
   * or put yourself on this list and say why".
   */
  const SRC = resolve(__dirname, '..', '..')
  const CONFINE = resolve(__dirname)

  /**
   * The modules outside `confine/` that may name a half, and what earns them it.
   *
   * `host-core.ts` is the spawn path and the branch's original author. It
   * selects with `confinementKind`, which is the same question
   * `confinedHomeEnv` asks, so it cannot be wrong in the way the copilot's
   * sign-in probe was.
   */
  const ALLOWED = new Map([
    ['main/host-core.ts', 'the spawn path, which makes the same choice through confinementKind'],
  ])

  const withoutComments = (source: string): string =>
    source.replace(/\/\*[\s\S]*?\*\//g, ' ').replace(/\/\/[^\n]*/g, ' ')

  function callersOf(name: string): string[] {
    const found: string[] = []
    const walk = (folder: string): void => {
      for (const entry of readdirSync(folder)) {
        const full = join(folder, entry)
        if (statSync(full).isDirectory()) {
          if (full !== CONFINE) walk(full)
          continue
        }
        if (!/\.tsx?$/.test(full) || /\.(test|spec)\.tsx?$/.test(full)) continue
        if (withoutComments(readFileSync(full, 'utf8')).includes(name)) found.push(full)
      }
    }
    walk(SRC)
    // Normalised to forward slashes so the allowlist above reads the same on a
    // Windows checkout, where it would otherwise match nothing and pass by
    // finding no entry to forgive.
    return found.map((file) => file.slice(SRC.length + 1).split(sep).join('/'))
  }

  it('has no unexplained module outside confine/ reaching for one half of it', () => {
    for (const half of ['confinedEnv', 'windowsConfinedEnv']) {
      expect(
        callersOf(half).filter((file) => !ALLOWED.has(file)),
        `${half} is being called from outside confine/ by a module that is not on the list in ` +
          'this test. That is one half of a two-branch platform switch, and calling it ' +
          'directly is exactly how the copilot\u2019s sign-in probe ended up running with the ' +
          'owner\u2019s USERPROFILE on Windows. Call confinedHomeEnv instead \u2014 or add ' +
          'yourself to ALLOWED with the reason it is safe there.',
      ).toEqual([])
    }
  })

  it('keeps the allowlist honest: every entry still exists and still selects', () => {
    /*
     * An allowlist nobody prunes becomes a list of files deleted three refactors
     * ago, and then it forgives a name that has been reused for something else.
     * Each entry has to be a real file, and it has to be doing the thing its
     * reason claims — asking `confinementKind` — rather than merely having been
     * forgiven once.
     */
    for (const [file, reason] of ALLOWED) {
      const source = readFileSync(join(SRC, file), 'utf8')
      expect(
        withoutComments(source),
        `${file} is allowed because it "${reason}", and it no longer mentions confinementKind`,
      ).toContain('confinementKind')
    }
  })
})
