import { beforeEach, describe, expect, it, vi } from 'vitest'
import { resetLoginPathCache } from '../providers'
import {
  BLOCKED_REASONS,
  blockedReasons,
  findTailscale,
  resetTailscaleBinaryCache,
  type TailnetBlockedState,
} from './tailnet'

/**
 * The platform half of `tailnet.ts`, kept in its own file so `tailnet.test.ts`
 * stays about the tailnet.
 *
 * `tailnet.test.ts` already checks that every blocked reason is an actionable
 * sentence — but it checks the *exported* table, which is the one for whichever
 * platform the test run is on, and CI only ever runs macOS. Without this file
 * the Windows table would be shipped having satisfied nothing.
 */

const ACTIONABLE = /install |open |click |approve |give it |run `|switch it off/i
const NAMES_A_PLACE = /menu bar|Applications|https:\/\/|terminal|notification area|Start menu/

/**
 * Only `accessSync` is faked, so the rest of `node:fs` keeps working. A Windows
 * path cannot be made executable on this machine any other way, and the whole
 * point of the lookup-then-list order is which of two absolute paths wins.
 */
const disk = vi.hoisted(() => ({ executable: new Set<string>() }))

vi.mock('node:fs', async (importOriginal) => {
  const actual = await importOriginal<typeof import('node:fs')>()
  return {
    ...actual,
    accessSync: (path: string): void => {
      if (!disk.executable.has(path)) throw Object.assign(new Error('ENOENT'), { code: 'ENOENT' })
    },
  }
})

const shell = vi.hoisted(() => ({ ran: [] as string[], lookup: '' }))

vi.mock('node:child_process', () => {
  const execFile = ((): unknown => undefined) as unknown as Record<symbol, unknown>
  execFile[Symbol.for('nodejs.util.promisify.custom')] = async (
    file: string,
  ): Promise<{ stdout: string; stderr: string }> => {
    shell.ran.push(file)
    if (file === 'which' || file === 'where.exe') return { stdout: shell.lookup, stderr: '' }
    // The login shell, on the macOS path only.
    return { stdout: '/usr/bin:/bin', stderr: '' }
  }
  return { execFile }
})

/** What `tailscaleCandidates` falls back to when no Program Files is in scope. */
const DEFAULT_WINDOWS_PATH = 'C:\\Program Files\\Tailscale\\tailscale.exe'

beforeEach(() => {
  disk.executable = new Set()
  shell.ran = []
  shell.lookup = ''
  resetTailscaleBinaryCache()
  resetLoginPathCache()
})

describe('finding the tailscale binary', () => {
  it('looks it up with where.exe on Windows, not which', async () => {
    shell.lookup = 'C:\\tools\\tailscale.exe\r\n'
    disk.executable.add('C:\\tools\\tailscale.exe')

    expect(await findTailscale(true, 'win32')).toBe('C:\\tools\\tailscale.exe')
    expect(shell.ran).toContain('where.exe')
    expect(shell.ran).not.toContain('which')
  })

  it('takes the moved install the lookup found over the documented default', async () => {
    // `INSTALLDIR` is a settable MSI property, so an administrator's Tailscale
    // is somewhere no list can name. The lookup has to win when it answers.
    shell.lookup = 'D:\\Apps\\Tailscale\\tailscale.exe\r\n'
    disk.executable.add('D:\\Apps\\Tailscale\\tailscale.exe')
    disk.executable.add(DEFAULT_WINDOWS_PATH)

    expect(await findTailscale(true, 'win32')).toBe('D:\\Apps\\Tailscale\\tailscale.exe')
  })

  it('falls back to the documented Program Files path when PATH has nothing', async () => {
    // Tailscale's docs do not say the install directory is added to PATH, so
    // this is not an exotic case — it may well be the normal one.
    disk.executable.add(DEFAULT_WINDOWS_PATH)
    expect(await findTailscale(true, 'win32')).toBe(DEFAULT_WINDOWS_PATH)
  })

  it('answers null rather than a path that is not there', async () => {
    expect(await findTailscale(true, 'win32')).toBeNull()
  })

  it('is unchanged on macOS', async () => {
    shell.lookup = '/opt/homebrew/bin/tailscale\n'
    disk.executable.add('/opt/homebrew/bin/tailscale')

    expect(await findTailscale(true, 'darwin')).toBe('/opt/homebrew/bin/tailscale')
    expect(shell.ran).toContain('which')
    expect(shell.ran).not.toContain('where.exe')
  })

  it('still falls back to the Homebrew list on macOS', async () => {
    disk.executable.add('/usr/local/bin/tailscale')
    expect(await findTailscale(true, 'darwin')).toBe('/usr/local/bin/tailscale')
  })
})

describe('the reasons a Windows user is given', () => {
  const windows = blockedReasons('win32')

  it('covers exactly the same states as the macOS table', () => {
    // A state with no Windows wording would fall back to `undefined` and render
    // as an empty panel, which reads as "everything is fine".
    expect(Object.keys(windows).sort()).toEqual(Object.keys(blockedReasons('darwin')).sort())
  })

  it.each(Object.entries(blockedReasons('win32')))('%s is an instruction, not a diagnosis', (state, reason) => {
    expect(reason, `${state} ends as a sentence`).toMatch(/\.$/)
    expect(reason.length, `${state} says more than a label`).toBeGreaterThan(60)
    expect(reason, `${state} names a next step`).toMatch(ACTIONABLE)
    expect(reason, `${state} names where`).toMatch(NAMES_A_PLACE)
  })

  it('never sends a Windows user to the menu bar or the Applications folder', () => {
    // The failure this file exists to prevent: a port done by find-and-replace
    // that leaves the remedies describing a Mac.
    for (const [state, reason] of Object.entries(windows)) {
      expect(reason, state).not.toMatch(/menu bar|Applications folder|this Mac/)
    }
  })

  it('names Windows places and commands instead', () => {
    expect(windows['not-running']).toMatch(/net start Tailscale/)
    expect(windows['logged-out']).toMatch(/notification area/)
    expect(windows.stopped).toMatch(/tailscale up/)
  })

  it('keeps the admin URL, which is the same on every platform', () => {
    expect(windows['needs-approval']).toContain('https://login.tailscale.com/admin/machines')
  })
})

describe('the macOS reasons are untouched by the port', () => {
  const mac = blockedReasons('darwin')

  it('still says Mac, menu bar and Applications', () => {
    expect(mac['not-running']).toContain('Applications folder')
    expect(mac['logged-out']).toContain('menu bar')
    expect(mac.unreadable).toContain('this Mac')
  })

  it('is what the module exports on this machine', () => {
    // The exported table is the current platform's, which is how every caller
    // gets the right wording without deciding for itself. This run is macOS.
    const expected: Record<TailnetBlockedState, string> =
      process.platform === 'win32' ? blockedReasons('win32') : mac
    expect(BLOCKED_REASONS).toEqual(expected)
  })
})
