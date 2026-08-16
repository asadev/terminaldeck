import { describe, expect, it } from 'vitest'
import type { ConfinementPlan } from './plan'
import { SANDBOX_EXEC, seatbeltCommand, seatbeltProfile, seatbeltString } from './seatbelt'

const plan: ConfinementPlan = {
  folder: '/Users/asad/Projects/app',
  accountHome: '/Users/asad',
  home: '/app-storage/device-home/abc',
  writable: ['/Users/asad/Projects/app', '/app-storage/device-home/abc'],
  readable: ['/usr', '/System'],
  readableFiles: ['/app-storage/guest-git/askpass.sh'],
}

describe('seatbeltString', () => {
  it('escapes the two characters that can end a literal early', () => {
    // A folder called `q"uote` produced `sandbox-exec: unbound variable` and exit
    // 65 — the profile failed to parse, so nothing started at all. Verified
    // against real folders named with each of these.
    expect(seatbeltString('/a/q"uote')).toBe('"/a/q\\"uote"')
    expect(seatbeltString('C:\\work')).toBe('"C:\\\\work"')
  })

  it('escapes the backslash before the quote, not after', () => {
    // Reversed, the backslash introduced by escaping the quote would itself be
    // escaped a second time and the path would no longer name the folder.
    expect(seatbeltString('a\\"b')).toBe('"a\\\\\\"b"')
  })

  it('leaves ordinary paths alone', () => {
    expect(seatbeltString('/Users/asad/Projects/app')).toBe('"/Users/asad/Projects/app"')
  })
})

describe('the generated profile', () => {
  const profile = seatbeltProfile(plan)

  it('denies everything before allowing anything', () => {
    const deny = profile.indexOf('(deny default)')
    const firstAllow = profile.indexOf('(allow ')
    expect(deny).toBeGreaterThanOrEqual(0)
    expect(deny).toBeLessThan(firstAllow)
  })

  it('allows the root directory itself, without which node aborts at startup', () => {
    // Measured: `node` dies inside InitializeOncePerProcessInternal with SIGABRT
    // and prints nothing when this line is missing. Nothing else tested needed
    // it, which is exactly why it would be removed by someone tidying up.
    expect(profile).toContain('(allow file-read* (literal "/"))')
  })

  it('grants the granted folder read and write', () => {
    expect(profile).toContain('(allow file-read* file-write* (subpath "/Users/asad/Projects/app"))')
  })

  it('grants the system roots read only', () => {
    expect(profile).toContain('(allow file-read* (subpath "/usr"))')
    expect(profile).not.toContain('(allow file-read* file-write* (subpath "/usr"))')
  })

  it('grants the helper as a file and never its folder', () => {
    expect(profile).toContain('(allow file-read* (literal "/app-storage/guest-git/askpass.sh"))')
    expect(profile).not.toContain('"/app-storage/guest-git")')
  })

  it('closes the routes that ask another process to act on the session\'s behalf', () => {
    for (const service of [
      'com.apple.coreservices.appleevents',
      'com.apple.coreservices.launchservicesd',
      'com.apple.SecurityServer',
    ]) {
      expect(profile).toContain(`(global-name "${service}")`)
    }
    // And the deny has to come after the blanket allow, or it is overridden.
    expect(profile.indexOf('(allow mach-lookup)')).toBeLessThan(profile.indexOf('(deny mach-lookup'))
  })

  it('lets the session see only its own processes', () => {
    expect(profile).toContain('(allow process-info* (target self))')
    expect(profile).not.toContain('(allow process-info*)\n')
  })

  it('opens the Xcode shim cache by name and never its directory', () => {
    // `/usr/bin/git` is a shim that writes a cache into the per-account temp
    // directory — a directory shared with every other program the account runs.
    // Without a rule every git command prints two permission errors first; with
    // a subpath rule the session could read other programs' temp files.
    expect(profile).toContain('xcrun_db')
    expect(profile).not.toContain('(subpath "/private/var/folders')
  })

  it('names no path that was not in the plan', () => {
    const paths = [...profile.matchAll(/\(subpath "([^"]+)"\)/g)].map((match) => match[1])
    const allowed = new Set([...plan.writable, ...plan.readable, '/dev'])
    for (const path of paths) expect(allowed.has(path ?? '')).toBe(true)
  })
})

describe('seatbeltCommand', () => {
  it('carries the profile as an argument rather than through a file', () => {
    // A file has to be written, read back, and can be replaced by anything
    // running as this account in the moment between the two. An argument cannot
    // be swapped after the call is made.
    const wrapped = seatbeltCommand('(version 1)', '/bin/zsh', ['-l'])
    expect(wrapped.command).toBe(SANDBOX_EXEC)
    expect(wrapped.args).toEqual(['-p', '(version 1)', '/bin/zsh', '-l'])
  })

  it('keeps the original arguments in order after the command', () => {
    const wrapped = seatbeltCommand('P', 'claude', ['--continue', '--verbose'])
    expect(wrapped.args.slice(2)).toEqual(['claude', '--continue', '--verbose'])
  })
})
