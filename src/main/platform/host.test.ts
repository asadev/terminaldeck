import { hostname } from 'node:os'
import { describe, expect, it } from 'vitest'
import {
  currentPlatform,
  envPath,
  isPathKey,
  isWindows,
  pathKey,
  thisMachineName,
  withPath,
} from './host'

/**
 * Every case here names both platforms on purpose.
 *
 * CI is macOS-only by policy, so a Windows branch is reachable from nothing
 * except a test that hands it the platform. `process.platform` is read in
 * exactly one function and nothing below calls it except the one case that
 * checks it is still the real thing.
 */

describe('the platform is a value, not an ambient fact', () => {
  it('reports the platform this process is actually on', () => {
    expect(currentPlatform()).toBe(process.platform)
  })

  it('names only win32 as Windows', () => {
    expect(isWindows('win32')).toBe(true)
    expect(isWindows('darwin')).toBe(false)
    expect(isWindows('linux')).toBe(false)
  })
})

describe('finding PATH in an environment', () => {
  it('reads the Windows spelling on Windows', () => {
    // What Windows itself writes. Reading only `PATH` here finds nothing and
    // hands a child process an empty PATH, which fails as "command not found"
    // for every command on the machine.
    expect(envPath({ Path: 'C:\\Windows' }, 'win32')).toBe('C:\\Windows')
    expect(envPath({ PATH: 'C:\\Windows' }, 'win32')).toBe('C:\\Windows')
  })

  it('is case-sensitive off Windows, where a stray Path is a different variable', () => {
    expect(envPath({ PATH: '/usr/bin', Path: '/nonsense' }, 'darwin')).toBe('/usr/bin')
    expect(envPath({ Path: '/nonsense' }, 'darwin')).toBe('')
  })

  it('answers empty rather than undefined when there is no PATH at all', () => {
    expect(envPath({}, 'darwin')).toBe('')
    expect(envPath({}, 'win32')).toBe('')
  })

  it('classifies keys the same way it reads them', () => {
    expect(isPathKey('Path', 'win32')).toBe(true)
    expect(isPathKey('PATH', 'win32')).toBe(true)
    expect(isPathKey('Path', 'darwin')).toBe(false)
    expect(isPathKey('PATH', 'darwin')).toBe(true)
  })

  it('keeps the spelling an environment already uses', () => {
    expect(pathKey({ Path: 'C:\\Windows' }, 'win32')).toBe('Path')
    expect(pathKey({ PATH: 'C:\\Windows' }, 'win32')).toBe('PATH')
    expect(pathKey({}, 'win32')).toBe('Path')
    expect(pathKey({ Path: '/nonsense' }, 'darwin')).toBe('PATH')
  })
})

describe('overriding PATH for a child process', () => {
  it('leaves no second spelling behind on Windows', () => {
    // The bug this function exists for: `{ ...env, PATH }` here produces an
    // object holding both `Path=C:\Windows` and `PATH=C:\tools`, and which one
    // the child sees is a coin flip nobody should be taking.
    const env = withPath({ Path: 'C:\\Windows', HOME: 'C:\\Users\\a' }, 'C:\\tools', 'win32')
    expect(env).toEqual({ Path: 'C:\\tools', HOME: 'C:\\Users\\a' })
    expect(Object.keys(env).filter((key) => key.toUpperCase() === 'PATH')).toHaveLength(1)
  })

  it('behaves exactly like the spread it replaces on macOS', () => {
    const before = { PATH: '/usr/bin', HOME: '/Users/a' }
    expect(withPath(before, '/opt/homebrew/bin', 'darwin')).toEqual({
      PATH: '/opt/homebrew/bin',
      HOME: '/Users/a',
    })
  })

  it('does not touch a POSIX variable that merely looks like PATH', () => {
    expect(withPath({ Path: 'keep me' }, '/usr/bin', 'darwin')).toEqual({
      Path: 'keep me',
      PATH: '/usr/bin',
    })
  })

  it('does not mutate the environment it was given', () => {
    const original = { Path: 'C:\\Windows' }
    withPath(original, 'C:\\tools', 'win32')
    expect(original).toEqual({ Path: 'C:\\Windows' })
  })

  it('keeps a no-undefined environment free of undefined', () => {
    // node-pty wants `Record<string, string>`. Widening the return type would
    // make that caller reach for a cast, and casts are how two bugs shipped.
    const strict: Record<string, string> = { PATH: '/usr/bin', HOME: '/Users/a' }
    const next: Record<string, string> = withPath(strict, '/opt/homebrew/bin', 'darwin')
    expect(next).toEqual({ PATH: '/opt/homebrew/bin', HOME: '/Users/a' })
  })
})

/**
 * The name, which is the half a list of machines needs.
 *
 * A noun says what kind of computer this is; a name says which one — and every
 * surface that draws this computer beside the machines it is paired to was
 * inventing a phrase for it, three of which ended up on one bar at once: *"I
 * don't know what to trust."*
 */
describe('what this computer calls itself', () => {
  it('is the hostname, with Bonjour’s suffix off it', () => {
    expect(thisMachineName()).toBe(hostname().replace(/\.local$/i, '').trim())
    expect(thisMachineName()).not.toMatch(/\.local$/i)
  })

  it('is never a phrase or a stand-in noun — those belong to the caller', () => {
    // Empty is what a computer with no readable hostname answers, and every
    // caller substitutes its own words there. A name invented in here would be
    // the app calling somebody's computer something nobody calls it.
    const name = thisMachineName()
    expect(name).not.toBe('A desktop')
    expect(name.toLowerCase()).not.toContain('this ')
  })
})
