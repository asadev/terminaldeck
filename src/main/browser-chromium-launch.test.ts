import { PassThrough } from 'node:stream'
import { describe, expect, it } from 'vitest'
import {
  CHROMIUM_LINUX_PACKAGES,
  CHROMIUM_STDIO,
  chromiumFlags,
  chromiumLibraryHint,
  describeExit,
  launchChromium,
  readSandboxFacts,
  sandboxDecision,
  type SandboxFacts,
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
 * A child that spawned cleanly, with the fd 3/4 pipe pair present, and a handle
 * on the two things that only happen later — the exit, and what it said on the
 * way out.
 *
 * `exit()` is the whole point: the failure this file's newer tests are about is
 * a process that is perfectly healthy at the instant `launchChromium` inspects
 * it and dead on the next tick, which is not expressible with a static object.
 */
interface FakeChild extends SpawnedChild {
  exit(code: number | null, signal?: NodeJS.Signals | null): void
  say(text: string): void
}

function makeChild(overrides: Partial<SpawnedChild> = {}): FakeChild {
  const listeners: ((code: number | null, signal: NodeJS.Signals | null) => void)[] = []
  const stderr = new PassThrough()
  const base: SpawnedChild = {
    pid: 4242,
    exitCode: null,
    stdio: [null, new PassThrough(), stderr, new PassThrough(), new PassThrough()],
    kill: () => true,
    on: (_event, listener) => {
      listeners.push(listener)
      return undefined
    },
  }
  const child = { ...base, ...overrides } as FakeChild
  // The overridden object keeps this fake's own `on`, so a caller that replaced
  // `stdio` or `pid` still gets a child whose exit can be fired.
  child.on = (_event, listener) => {
    listeners.push(listener)
    return undefined
  }
  child.exit = (code, signal = null) => {
    for (const listener of listeners) listener(code, signal)
  }
  child.say = (text) => {
    stderr.write(text)
  }
  return child
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

/**
 * Sandbox facts for a machine that has one.
 *
 * Passed explicitly by every launch test so the flag list is a function of the
 * test's input rather than of the machine the suite happens to run on — the
 * assertions below compare against `chromiumFlags`, and on a Linux CI runner a
 * decision read from the real `/proc` would silently change both sides.
 */
const SANDBOXED: SandboxFacts = {
  platform: 'darwin',
  uid: 501,
  maxUserNamespaces: -1,
  apparmorRestrictsUserns: false,
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
    const flags = chromiumFlags({ userDataDir: '/p', extraFlags: ['--proxy-server=x', '--lang=en'] })
    expect(flags.slice(-2)).toEqual(['--proxy-server=x', '--lang=en'])
  })

  it('keeps the sandbox on unless told otherwise', () => {
    expect(chromiumFlags({ userDataDir: '/p' })).not.toContain('--no-sandbox')
    expect(chromiumFlags({ userDataDir: '/p', sandbox: true })).not.toContain('--no-sandbox')
  })

  it('adds --no-sandbox only when sandbox is false, and still lets extra flags be last', () => {
    const flags = chromiumFlags({ userDataDir: '/p', sandbox: false, extraFlags: ['--lang=en'] })
    expect(flags).toContain('--no-sandbox')
    expect(flags[flags.length - 1]).toBe('--lang=en')
  })
})

/* ------------------------------------------------------------- sandbox -- */

describe('deciding whether the sandbox can stay on', () => {
  it('keeps it on everywhere that is not Linux', () => {
    for (const platform of ['darwin', 'win32'] as const) {
      const decision = sandboxDecision({ platform, uid: -1, maxUserNamespaces: -1, apparmorRestrictsUserns: false })
      expect(decision.sandbox).toBe(true)
    }
  })

  it('keeps it on for an ordinary Linux user with namespaces available', () => {
    const decision = sandboxDecision({
      platform: 'linux',
      uid: 1000,
      maxUserNamespaces: 15127,
      apparmorRestrictsUserns: false,
    })
    expect(decision.sandbox).toBe(true)
  })

  /*
   * The three refusals, each measured on a real Ubuntu 24.04 server on
   * 2026-08-22 before being written down here. Root is first because it is the
   * ordinary case: a rented server hands you root, and this host is installed
   * there.
   */
  it('drops it as root, and says root is why', () => {
    const decision = sandboxDecision({
      platform: 'linux',
      uid: 0,
      maxUserNamespaces: 15127,
      apparmorRestrictsUserns: false,
    })
    expect(decision.sandbox).toBe(false)
    expect(decision.why).toContain('root')
  })

  it('drops it when user namespaces are switched off, and says so', () => {
    const decision = sandboxDecision({
      platform: 'linux',
      uid: 1000,
      maxUserNamespaces: 0,
      apparmorRestrictsUserns: false,
    })
    expect(decision.sandbox).toBe(false)
    expect(decision.why).toContain('max_user_namespaces')
  })

  it("drops it under Ubuntu's AppArmor restriction, and names it", () => {
    const decision = sandboxDecision({
      platform: 'linux',
      uid: 1000,
      maxUserNamespaces: 15127,
      apparmorRestrictsUserns: true,
    })
    expect(decision.sandbox).toBe(false)
    expect(decision.why).toContain('apparmor_restrict_unprivileged_userns')
  })

  it('every refusal carries a reason worth printing', () => {
    const refusals = [
      sandboxDecision({ platform: 'linux', uid: 0, maxUserNamespaces: 1, apparmorRestrictsUserns: false }),
      sandboxDecision({ platform: 'linux', uid: 1, maxUserNamespaces: 0, apparmorRestrictsUserns: false }),
      sandboxDecision({ platform: 'linux', uid: 1, maxUserNamespaces: 1, apparmorRestrictsUserns: true }),
    ]
    for (const refusal of refusals) {
      expect(refusal.sandbox).toBe(false)
      expect(refusal.why.length).toBeGreaterThan(30)
    }
  })

  it('reads the facts from /proc, and survives a machine with none of it', () => {
    // The reads are a seam precisely so the "these files do not exist" path can
    // be taken on a Mac, where they genuinely do not.
    const facts = readSandboxFacts(() => {
      throw new Error('ENOENT')
    })
    expect(facts.maxUserNamespaces === -1 || facts.platform !== 'linux').toBe(true)
    expect(facts.apparmorRestrictsUserns).toBe(false)
  })
})

/* -------------------------------------------------------- the libraries -- */

describe('the system libraries a downloaded Chromium needs', () => {
  it('names packages a person can install, as one pasteable line', () => {
    expect(CHROMIUM_LINUX_PACKAGES.length).toBeGreaterThan(10)
    expect(CHROMIUM_LINUX_PACKAGES).toContain('libatk1.0-0t64')
    expect(CHROMIUM_LINUX_PACKAGES).toContain('libgbm1')
    expect(chromiumLibraryHint()).toContain('apt-get install -y')
    for (const name of CHROMIUM_LINUX_PACKAGES) expect(chromiumLibraryHint()).toContain(name)
  })
})

/* ------------------------------------------------------ describing death -- */

describe('saying why the browser quit', () => {
  /*
   * The exact stderr the real binary produced on the reference server. Pinned
   * verbatim rather than paraphrased, because the whole value of these two
   * branches is that they match what Chromium actually prints.
   */
  it('turns a missing shared library into the package to install', () => {
    const said =
      '/root/.local/share/terminaldeck/chromium/146.0.7680.165/chrome-linux64/chrome: ' +
      'error while loading shared libraries: libatk-1.0.so.0: cannot open shared object file: No such file or directory'
    const reason = describeExit(127, null, said)
    expect(reason).toContain('libatk-1.0.so.0')
    expect(reason).toContain('apt-get install -y')
  })

  it('names the root refusal rather than the Chromium source file that raised it', () => {
    const said =
      '[167882:167882:0822/111334.793602:ERROR:content/browser/zygote_host/zygote_host_impl_linux.cc:101] ' +
      'Running as root without --no-sandbox is not supported. See https://crbug.com/638180.'
    expect(describeExit(1, null, said)).toContain('root')
  })

  it('names the no-usable-sandbox refusal', () => {
    const said =
      '[168022:168022:0822/111341.080117:FATAL:content/browser/zygote_host/zygote_host_impl_linux.cc:128] ' +
      'No usable sandbox! If you are running on Ubuntu 23.10+ …'
    expect(describeExit(null, 'SIGABRT', said)).toContain('apparmor_restrict_unprivileged_userns')
  })

  it('falls back to the code and the last thing it said', () => {
    expect(describeExit(3, null, 'something went wrong\n')).toContain('something went wrong')
    expect(describeExit(3, null, '')).toContain('code 3')
    expect(describeExit(null, 'SIGKILL', '')).toContain('SIGKILL')
  })
})

/* --------------------------------------------------------------- launch -- */

describe('launching Chromium', () => {
  it('spawns with the fd 3/4 stdio and hands back the two pipe streams', () => {
    const recorded: Recorded[] = []
    const child = makeChild()
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/profiles/p1',
      spawn: fakeSpawn(child, recorded),
      sandboxFacts: SANDBOXED,
    })

    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.handle.pid).toBe(4242)
    expect(result.handle.pipeWrite).toBe(child.stdio[3])
    expect(result.handle.pipeRead).toBe(child.stdio[4])
    expect(result.sandbox.sandbox).toBe(true)

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
      spawn: fakeSpawn(makeChild(), recorded),
      sandboxFacts: SANDBOXED,
    })
    expect(recorded[0].args).toContain('--load-extension=/ext/a')
  })

  it('drops the sandbox when the machine has none, and reports that it did', () => {
    const recorded: Recorded[] = []
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(makeChild(), recorded),
      sandboxFacts: { platform: 'linux', uid: 0, maxUserNamespaces: 15127, apparmorRestrictsUserns: false },
    })
    expect(recorded[0].args).toContain('--no-sandbox')
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.sandbox.sandbox).toBe(false)
    expect(result.sandbox.why).toContain('root')
  })

  it('is a named error when the process comes back with no pid', () => {
    const child = makeChild({ pid: undefined, stdio: [null, null, null, null, null] })
    const result = launchChromium({
      executablePath: '/no/such/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('could not be spawned')
  })

  it('is a named error when the browser has already exited', () => {
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(makeChild({ pid: 99, exitCode: 1 }), []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('exited immediately')
  })

  it('is a named error when the fd 3/4 pipe channel is missing', () => {
    const child = makeChild({ pid: 7, stdio: [null, new PassThrough(), new PassThrough(), null, null] })
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
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
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('EACCES')
  })

  it('close() kills the process', () => {
    let killed = false
    const child = makeChild({
      pid: 5,
      kill: () => {
        killed = true
        return true
      },
    })
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(true)
    if (result.ok) result.handle.close()
    expect(killed).toBe(true)
  })
})

/* ------------------------------------------------- a pid is not a browser -- */

describe('a browser that dies after it was called healthy', () => {
  /*
   * The measured failure, in the shape it actually arrived in: `launchChromium`
   * inspects a child that has a pid, a null `exitCode` and both pipe fds, says
   * yes, and the process is gone on a later tick with code 127. Everything
   * before `whenGone` existed had no way to learn that.
   */
  it('reports it as still running at the moment of the call', () => {
    const child = makeChild()
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.handle.exitReason()).toBeNull()
  })

  it('resolves whenGone with the reason, and answers synchronously afterwards', async () => {
    const child = makeChild()
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(true)
    if (!result.ok) return

    child.say(
      '/opt/chrome/chrome: error while loading shared libraries: libatk-1.0.so.0: cannot open shared object file: No such file or directory\n',
    )
    // The write has to land on the stream before the exit fires, which is the
    // real ordering too: Chromium says why and then quits.
    await new Promise((resolve) => setImmediate(resolve))
    child.exit(127)

    const reason = await result.handle.whenGone
    expect(reason).toContain('libatk-1.0.so.0')
    expect(reason).toContain('apt-get install -y')
    expect(result.handle.exitReason()).toBe(reason)
  })

  it('whenGone stays pending while the browser is alive', async () => {
    const result = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(makeChild(), []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(true)
    if (!result.ok) return
    const settled = await Promise.race([
      result.handle.whenGone.then(() => 'gone'),
      new Promise((resolve) => setTimeout(() => resolve('still running'), 20)),
    ])
    expect(settled).toBe('still running')
  })
})
