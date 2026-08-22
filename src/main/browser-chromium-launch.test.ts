import { PassThrough } from 'node:stream'
import { describe, expect, it } from 'vitest'
import {
  CHROMIUM_STDIO,
  chromiumFlags,
  launchChromium,
  type SpawnFn,
  type SpawnOptions,
  type SpawnedChild,
} from './browser-chromium-launch'

/* --------------------------------------------------------------- fakes -- */

interface Recorded {
  command: string
  args: readonly string[]
  options: SpawnOptions
}

/**
 * A spawn that records its call and returns whatever child it was given, so a
 * test can model a healthy launch, a spawn failure, or an immediate exit without
 * a process ever existing.
 */
function fakeSpawn(child: SpawnedChild, recorded: Recorded[]): SpawnFn {
  return (command, args, options) => {
    recorded.push({ command, args, options })
    return child
  }
}

/** A child that spawned cleanly, with the fd 3/4 pipe pair present. */
function healthyChild(): SpawnedChild {
  return {
    pid: 4242,
    exitCode: null,
    stdio: [null, new PassThrough(), new PassThrough(), new PassThrough(), new PassThrough()],
    kill: () => true,
  }
}

/* --------------------------------------------------------------- flags -- */

describe('composing the launch flags', () => {
  it('is the pinned set, in order, with no extensions', () => {
    expect(chromiumFlags({ userDataDir: '/profiles/p1' })).toEqual([
      '--headless=new',
      '--remote-debugging-pipe',
      '--user-data-dir=/profiles/p1',
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-gpu',
    ])
  })

  it('adds --load-extension and --disable-extensions-except when a profile carries extensions', () => {
    const flags = chromiumFlags({
      userDataDir: '/profiles/p1',
      extensionDirs: ['/ext/ublock', '/ext/darkreader'],
    })
    expect(flags).toContain('--load-extension=/ext/ublock,/ext/darkreader')
    expect(flags).toContain('--disable-extensions-except=/ext/ublock,/ext/darkreader')
  })

  it('does not add the extension flags for an empty list', () => {
    const flags = chromiumFlags({ userDataDir: '/p', extensionDirs: [] })
    expect(flags.some((f) => f.startsWith('--load-extension'))).toBe(false)
    expect(flags.some((f) => f.startsWith('--disable-extensions-except'))).toBe(false)
  })

  it('appends extra flags verbatim, after the rest', () => {
    const flags = chromiumFlags({ userDataDir: '/p', extraFlags: ['--no-sandbox', '--proxy-server=x'] })
    expect(flags.slice(-2)).toEqual(['--no-sandbox', '--proxy-server=x'])
  })
})

/* --------------------------------------------------------------- launch -- */

describe('launching Chromium', () => {
  it('spawns with the fd 3/4 stdio and hands back the two pipe streams', () => {
    const recorded: Recorded[] = []
    const child = healthyChild()
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/profiles/p1',
      spawn: fakeSpawn(child, recorded),
    })

    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.handle.pid).toBe(4242)
    expect(result.handle.pipeWrite).toBe(child.stdio[3])
    expect(result.handle.pipeRead).toBe(child.stdio[4])

    // The stdio shape is what makes fds 3 and 4 the CDP channel.
    expect(recorded).toHaveLength(1)
    expect(recorded[0].command).toBe('/opt/chrome/chrome')
    expect(recorded[0].options.stdio).toEqual([...CHROMIUM_STDIO])
    expect(recorded[0].args).toEqual(chromiumFlags({ userDataDir: '/profiles/p1' }))
  })

  it('passes the extension flags through to the spawn', () => {
    const recorded: Recorded[] = []
    launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      extensionDirs: ['/ext/a'],
      spawn: fakeSpawn(healthyChild(), recorded),
    })
    expect(recorded[0].args).toContain('--load-extension=/ext/a')
  })

  it('is a named error when the process comes back with no pid', () => {
    const child: SpawnedChild = { pid: undefined, exitCode: null, stdio: [null, null, null, null, null], kill: () => true }
    const result = launchChromium({
      executablePath: '/no/such/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('could not be spawned')
  })

  it('is a named error when the browser has already exited', () => {
    const child: SpawnedChild = {
      pid: 99,
      exitCode: 1,
      stdio: [null, new PassThrough(), new PassThrough(), new PassThrough(), new PassThrough()],
      kill: () => true,
    }
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('exited immediately')
  })

  it('is a named error when the fd 3/4 pipe channel is missing', () => {
    const child: SpawnedChild = {
      pid: 7,
      exitCode: null,
      stdio: [null, new PassThrough(), new PassThrough(), null, null],
      kill: () => true,
    }
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('pipe channel')
  })

  it('is a named error when spawn throws', () => {
    const throwingSpawn: SpawnFn = () => {
      throw new Error('EACCES')
    }
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: throwingSpawn,
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('EACCES')
  })

  it('close() kills the process', () => {
    let killed = false
    const child: SpawnedChild = {
      pid: 5,
      exitCode: null,
      stdio: [null, new PassThrough(), new PassThrough(), new PassThrough(), new PassThrough()],
      kill: () => {
        killed = true
        return true
      },
    }
    const result = launchChromium({ executablePath: '/opt/chrome/chrome', userDataDir: '/p', spawn: fakeSpawn(child, []) })
    expect(result.ok).toBe(true)
    if (result.ok) result.handle.close()
    expect(killed).toBe(true)
  })
})
