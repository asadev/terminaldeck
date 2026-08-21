import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { BRAND } from '../shared/brand'
import {
  hookAddress,
  hookConfigPath,
  hookServerFailure,
  startHookServer,
  stopHookServer,
  type HookEndpoint,
} from './hook-server'

/**
 * The failure this file exists for, and it had already happened.
 *
 * A unix socket path lives in a fixed `sun_path` field — 104 bytes on macOS, 108
 * on Linux — and `<userData>/hook/hook.sock` is about seventy of them on a
 * normal Mac. On 2026-08-21 a real data directory was measured at **122 bytes**.
 * There is nothing exotic about how to get there: a longer account name, a
 * `--user-data-dir` under a project, a build folder with a suffix.
 *
 * What happened when it did is the reason this is not merely a length check. The
 * endpoint threw at launch, `index.ts` caught it, wrote one line to a console
 * nobody has open, and the app came up looking entirely normal — with every
 * lifecycle event, every status dot and the whole boot-context channel dead for
 * the life of that install. The Settings pane could say the endpoint was not
 * running and could not say why, because nothing kept the reason.
 *
 * So two things are pinned here: the address no longer lets the length of
 * somebody's data directory decide whether the feature exists, and a start that
 * fails for any other reason leaves a sentence a person can be shown.
 */

const dirs: string[] = []

function scratch(prefix: string): string {
  const dir = mkdtempSync(join(tmpdir(), prefix))
  dirs.push(dir)
  return dir
}

/** A data directory whose natural socket path is comfortably over the limit. */
function longDir(): string {
  const base = scratch('td-hook-long-')
  return join(base, 'a'.repeat(120))
}

/**
 * A stand-in home short enough for the first fallback to be chosen.
 *
 * Directly under `/tmp` rather than under `tmpdir()`, and that is the point of
 * having it: a temporary directory on macOS is `/var/folders/<11>/<24>/T/…`, 68
 * bytes before anything is put in it, and a home that long is itself over the
 * limit — the third candidate would be picked and the second would go
 * unexercised on exactly the platform CI runs on.
 */
function shortHome(): string {
  const dir = mkdtempSync('/tmp/tdh-')
  dirs.push(dir)
  return dir
}

afterEach(async () => {
  await stopHookServer()
  while (dirs.length > 0) rmSync(dirs.pop() as string, { recursive: true, force: true })
})

describe('the address is never too long for the kernel', () => {
  it('keeps the path it has always had when that path fits', () => {
    // Unchanged, and it has to be: this is the string in every hook command
    // installed since March, and the one every other test in this repo names.
    expect(hookAddress('/data', 'darwin')).toBe('/data/hook/hook.sock')
  })

  it('moves into the app\u2019s own home directory when it does not', () => {
    const address = hookAddress(longDir(), 'darwin', '/Users/asad')

    expect(Buffer.byteLength(address)).toBeLessThanOrEqual(100)
    expect(address.startsWith(`/Users/asad/.${BRAND.id}/`)).toBe(true)
    expect(address.endsWith('.sock')).toBe(true)
  })

  it('falls to /tmp only when even that home is too long to hold it', () => {
    const address = hookAddress(longDir(), 'darwin', `/Users/${'n'.repeat(90)}`)

    // The last resort is spelled out rather than read from `TMPDIR`, because
    // this is the one candidate whose whole job is to be short enough that
    // nothing can refuse it. 39 bytes on every POSIX machine there is.
    expect(address.startsWith(`/tmp/${BRAND.id}-`)).toBe(true)
    expect(Buffer.byteLength(address)).toBeLessThanOrEqual(100)
  })

  it('is still the same string next week, and still one per install', () => {
    const long = longDir()
    const other = longDir()

    // Both halves of the Windows pipe argument, now true of POSIX too: the name
    // is a digest of the data directory, so it carries nothing minted per run
    // and two installs cannot collide.
    expect(hookAddress(long, 'darwin', '/Users/asad')).toBe(
      hookAddress(long, 'darwin', '/Users/asad'),
    )
    expect(hookAddress(long, 'darwin', '/Users/asad')).not.toBe(
      hookAddress(other, 'darwin', '/Users/asad'),
    )
  })

  it('leaves Windows exactly as it was, because a pipe name is not a path', () => {
    const dir = 'C:\\Users\\asad\\AppData\\Roaming\\terminaldeck'
    expect(hookAddress(dir, 'win32', '/anything')).toBe(hookAddress(dir, 'win32'))
    expect(hookAddress(longDir(), 'win32').startsWith('\\\\.\\pipe\\')).toBe(true)
  })
})

describe('and a data directory that used to kill the feature now serves it', () => {
  it('binds, and writes the moved path into the config a hook reads', async () => {
    const dir = longDir()
    const home = shortHome()

    // Before this change the whole of this test was one throw.
    const endpoint: HookEndpoint = await startHookServer({ dir, home })

    expect(endpoint.socketPath.startsWith(home)).toBe(true)
    expect(existsSync(endpoint.socketPath)).toBe(true)
    expect(hookServerFailure()).toBeNull()

    /*
     * And this is why moving it is cheap. A hook never learns the socket path
     * from its own command — it reads it out of the config at call time, with
     * `curl -K` — so an address that changed shape breaks nothing that is
     * already installed.
     */
    const config = readFileSync(hookConfigPath(dir), 'utf8')
    expect(config).toContain(`unix-socket = "${endpoint.socketPath}"`)
  })
})

describe('a start that fails leaves something to show a person', () => {
  it('keeps the reason, instead of only a console line nobody has open', async () => {
    // A directory that cannot be created: `mkdir` under a path component that is
    // a regular file fails with ENOTDIR, which is a plain, real, non-length
    // failure — exactly the shape the old code turned into silence.
    const file = join(scratch('td-hook-fail-'), 'not-a-directory')
    writeFileSync(file, 'x')

    await expect(startHookServer({ dir: join(file, 'inside') })).rejects.toThrow()

    const why = hookServerFailure()
    expect(why).not.toBeNull()
    expect(why).toMatch(/ENOTDIR|not a directory/i)
  })

  it('forgets it again once a start works, so the panel cannot show a stale one', async () => {
    const file = join(scratch('td-hook-fail2-'), 'not-a-directory')
    writeFileSync(file, 'x')
    await expect(startHookServer({ dir: join(file, 'inside') })).rejects.toThrow()
    expect(hookServerFailure()).not.toBeNull()

    await startHookServer({ dir: scratch('td-hook-ok-') })

    expect(hookServerFailure()).toBeNull()
  })
})
