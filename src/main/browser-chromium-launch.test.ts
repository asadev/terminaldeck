import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { PassThrough } from 'node:stream'
import { describe, expect, it } from 'vitest'
import {
  CHROMIUM_LINUX_PACKAGES,
  CHROMIUM_STDIO,
  chromiumFlags,
  chromiumLibraryCommand,
  chromiumLibraryHint,
  confirmReady,
  describeExit,
  detectPackageFamily,
  isDiagnostic,
  launchChromium,
  readSandboxFacts,
  sandboxDecision,
  spawnChromium,
  type HaveCommand,
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
      '--disable-blink-features=AutomationControlled',
    ])
  })

  it('always suppresses the automation tell and never turns automation on', () => {
    // The half of the Google-sign-in fix that lives in the flags: measured
    // 2026-08-27, `navigator.webdriver` read `true` without this flag and
    // `false` with it, on this exact `--headless=new --remote-debugging-pipe`
    // launch. `--enable-automation` would put the tell back and raise an
    // infobar, so its absence is asserted, not merely assumed.
    const flags = chromiumFlags({ userDataDir: '/p' })
    expect(flags).toContain('--disable-blink-features=AutomationControlled')
    expect(flags.some((flag) => flag.includes('--enable-automation'))).toBe(false)
  })

  it('adds --user-agent only when the caller supplies one, never on an empty string', () => {
    const has = (flags: string[]): boolean => flags.some((flag) => flag.startsWith('--user-agent='))
    // The side-loaded case returns '' from `machineBrowserUserAgent`, and an
    // empty `--user-agent` would send no User-Agent header at all — worse than
    // the headless one. So an empty string adds nothing.
    expect(has(chromiumFlags({ userDataDir: '/p' }))).toBe(false)
    expect(has(chromiumFlags({ userDataDir: '/p', userAgent: '' }))).toBe(false)
    const ua =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/146.0.0.0 Safari/537.36'
    expect(chromiumFlags({ userDataDir: '/p', userAgent: ua })).toContain(`--user-agent=${ua}`)
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
    expect(chromiumLibraryHint('apt')).toContain('apt-get install -y')
    for (const name of CHROMIUM_LINUX_PACKAGES) expect(chromiumLibraryHint('apt')).toContain(name)
  })

  /*
   * Every library that came back "not found" from `ldd` on the reference box —
   * a stock Ubuntu 24.04 Hetzner server, 2026-08-22 — has to be covered by a
   * package in the apt list, or the pasteable line leaves the machine broken
   * and the person with no further clue.
   *
   * `libxext6` is the one that made this test worth writing: it was missing on
   * that box and was *not* in the list, and the install still worked because
   * apt happened to pull it in behind `libxrandr2`. A list that only works
   * through somebody else's dependency graph is a list that breaks silently.
   */
  it('covers every library the reference server was actually missing', () => {
    const measured: Record<string, string> = {
      'libasound.so.2': 'libasound2t64',
      'libatk-1.0.so.0': 'libatk1.0-0t64',
      'libatk-bridge-2.0.so.0': 'libatk-bridge2.0-0t64',
      'libatspi.so.0': 'libatspi2.0-0t64',
      'libcairo.so.2': 'libcairo2',
      'libcups.so.2': 'libcups2t64',
      'libgbm.so.1': 'libgbm1',
      'libpango-1.0.so.0': 'libpango-1.0-0',
      'libXcomposite.so.1': 'libxcomposite1',
      'libXdamage.so.1': 'libxdamage1',
      'libXext.so.6': 'libxext6',
      'libXfixes.so.3': 'libxfixes3',
      'libXrandr.so.2': 'libxrandr2',
    }
    expect(Object.keys(measured)).toHaveLength(13)
    for (const [library, pkg] of Object.entries(measured)) {
      expect(CHROMIUM_LINUX_PACKAGES, `${library} is supplied by ${pkg}`).toContain(pkg)
    }
  })

  /*
   * The defect this replaced: one hardcoded `apt-get` line, printed at whoever
   * ran the command, on whatever distribution. `install-headless.sh` has done
   * this properly for build tools since 2026-08-18 — walk `apk`, `dnf`, `yum`,
   * `pacman`, `zypper`, fall back to apt — and this walks the same list in the
   * same order so a box cannot be one family to the shell script and another to
   * the browser installer.
   */
  it('detects the package manager the way install-headless.sh does', () => {
    const only = (present: string): HaveCommand => (command) => command === present
    expect(detectPackageFamily(only('apk'))).toBe('musl')
    expect(detectPackageFamily(only('dnf'))).toBe('dnf')
    expect(detectPackageFamily(only('yum'))).toBe('yum')
    expect(detectPackageFamily(only('pacman'))).toBe('pacman')
    expect(detectPackageFamily(only('zypper'))).toBe('zypper')
    expect(detectPackageFamily(() => false)).toBe('apt')
    // apk is asked first, because it is the one answer that changes the advice.
    expect(detectPackageFamily((command) => command === 'apk' || command === 'dnf')).toBe('musl')
  })

  it('spells the same libraries the way each family spells them', () => {
    expect(chromiumLibraryHint('dnf')).toBe(
      'sudo dnf install -y atk at-spi2-atk cups-libs mesa-libgbm alsa-lib at-spi2-core ' +
        'libXcomposite libXdamage libXext libXfixes libXrandr pango cairo nss libxkbcommon',
    )
    expect(chromiumLibraryHint('pacman')).toContain('pacman -S --needed --noconfirm')
    expect(chromiumLibraryHint('zypper')).toContain('zypper install -y')
    // Every family names as many packages as apt does — a short row is a row
    // somebody forgot to finish.
    for (const family of ['apt', 'dnf', 'yum', 'pacman', 'zypper'] as const) {
      const command = chromiumLibraryCommand(family)
      expect(command).not.toBeNull()
      expect(command?.args.length).toBe(CHROMIUM_LINUX_PACKAGES.length + (family === 'pacman' ? 3 : 2))
    }
  })

  /*
   * Alpine is the case where printing *a* command would be worse than printing
   * none. chrome-for-testing publishes glibc builds only, so the missing piece
   * on musl is the loader itself and no `apk add` line reaches it. The honest
   * answer is the distribution's own chromium through the side-load door this
   * app already has.
   */
  it('refuses to invent an apk line, and points at the side-load door instead', () => {
    expect(chromiumLibraryCommand('musl')).toBeNull()
    const hint = chromiumLibraryHint('musl')
    expect(hint).toContain('TERMINALDECK_CHROMIUM_PATH')
    expect(hint).toContain('glibc')
    expect(hint).not.toContain('apk add --no-cache lib')
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

  /*
   * The stack-trace defect, pinned against the real thing.
   *
   * Measured on the reference server, 2026-08-22: a Chromium whose
   * `chrome_crashpad_handler` had not come out of the archive executable printed
   * its `FATAL:` line, then `Received signal 6`, then twenty-one stack frames,
   * then a register dump, then `[end of stack trace]` — about 1.6 kB of noise
   * after the only sentence that mattered.
   *
   * Two things were wrong with what a person got. The two-kilobyte stderr tail
   * no longer held the FATAL line at all, and `describeExit` took the *last*
   * non-empty line of what was left, so the message read:
   *
   *     Chromium exited on signal SIGABRT: [end of stack trace]
   *
   * which is the "a stack trace, not a sentence a person can act on" failure
   * exactly. The fix is two-sided — the diagnostic line is captured as it
   * streams, and whatever is left is filtered — so both sides are pinned here.
   */
  const CRASH_DUMP = [
    'Received signal 6',
    '#0 0x5954576637fa (/opt/chrome/chrome+0x4ebf7f9)',
    '#1 0x59545cec1c84 (/opt/chrome/chrome+0xa71dc83)',
    '#20 0x595458e52e2a (/opt/chrome/chrome+0x66aee29)',
    '  r8: 000019980007047d  r9: 0000000000000001 r10: 0000000000000008 r11: 0000000000000246',
    ' trp: 0000000000000000 msk: 0000000000000000 cr2: 0000000000000000',
    '[end of stack trace]',
    '',
  ].join('\n')

  const FATAL_LINE =
    '[177373:177373:0822/141803.896655:FATAL:third_party/crashpad/crashpad/util/posix/spawn_subprocess.cc:237] ' +
    'posix_spawn /opt/chrome/chrome_crashpad_handler: Permission denied (13)'

  it('says what aborted the browser, not the last line of its stack trace', () => {
    const said = describeExit(null, 'SIGABRT', CRASH_DUMP, FATAL_LINE)
    expect(said).toContain('chrome_crashpad_handler')
    expect(said).toContain('Permission denied')
    expect(said).not.toContain('end of stack trace')
    // The Chromium log prefix is stripped: a person needs the message, not the
    // path of the .cc file inside Chromium that noticed.
    expect(said).not.toContain('spawn_subprocess.cc')
  })

  it('skips the crash dump even with no diagnostic to fall back on', () => {
    const said = describeExit(null, 'SIGABRT', CRASH_DUMP)
    expect(said).not.toContain('end of stack trace')
    expect(said).not.toContain('#20')
    expect(said).toContain('SIGABRT')
  })

  it('knows a reason line from noise', () => {
    expect(isDiagnostic(FATAL_LINE)).toBe(true)
    expect(isDiagnostic('[0822/142501.964623:ERROR:chrome/app/chrome_main_delegate.cc:1094] Remote debugging pipe file descriptors are not open.')).toBe(true)
    expect(isDiagnostic('/opt/chrome/chrome: error while loading shared libraries: libatk-1.0.so.0: cannot open shared object file')).toBe(true)
    expect(isDiagnostic('[end of stack trace]')).toBe(false)
    expect(isDiagnostic('#12 0x5954576637fa (/opt/chrome/chrome+0x4ebf7f9)')).toBe(false)
    expect(isDiagnostic(' trp: 0000000000000000 msk: 0000000000000000 cr2: 0000000000000000')).toBe(false)
    expect(isDiagnostic('Received signal 6')).toBe(false)
    // A warning is noise about a browser that is running, not a reason one died.
    expect(isDiagnostic('[1:1:0822/141803:WARNING:foo.cc:1] something cosmetic')).toBe(false)
  })
})

/* --------------------------------------------------------------- launch -- */

describe('spawning Chromium', () => {
  it('spawns with the fd 3/4 stdio and hands back the two pipe streams', () => {
    const recorded: Recorded[] = []
    const child = makeChild()
    const result = spawnChromium({
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
    spawnChromium({
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
    const result = spawnChromium({
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
    const result = spawnChromium({
      executablePath: '/no/such/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('could not be spawned')
  })

  it('is a named error when the browser has already exited', () => {
    const result = spawnChromium({
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
    const result = spawnChromium({
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
    const result = spawnChromium({
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
    const result = spawnChromium({
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
   * The measured failure, in the shape it actually arrived in: `spawnChromium`
   * inspects a child that has a pid, a null `exitCode` and both pipe fds, says
   * yes, and the process is gone on a later tick with code 127. That is why
   * `spawnChromium` is not the exported door any more — `launchChromium` is,
   * and it does not answer until the browser has.
   */
  it('reports it as still running at the moment of the call', () => {
    const child = makeChild()
    const result = spawnChromium({
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
    const result = spawnChromium({
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
    const result = spawnChromium({
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

/* ------------------------------------------------ a launch that is finished -- */

/**
 * A child whose fd 3/4 pair behaves like a browser: it reads NUL-framed CDP
 * commands off the write pipe and answers them on the read pipe.
 *
 * Small enough to be obviously right, and it has to exist for the same reason
 * `makeChild` does — the thing under test is a *sequence*, and a static object
 * cannot express "answers" any more than it can express "dies on the next tick".
 */
function makeAnsweringChild(): FakeChild {
  const child = makeChild()
  const toBrowser = child.stdio[3] as PassThrough
  const fromBrowser = child.stdio[4] as PassThrough
  let buffered = ''
  toBrowser.on('data', (chunk: Buffer) => {
    buffered += String(chunk)
    let nul = buffered.indexOf('\0')
    while (nul !== -1) {
      const frame = JSON.parse(buffered.slice(0, nul)) as { id: number; method: string }
      buffered = buffered.slice(nul + 1)
      fromBrowser.write(
        `${JSON.stringify({ id: frame.id, result: { product: 'Chrome/146.0.7680.165' } })}\0`,
      )
      nul = buffered.indexOf('\0')
    }
  })
  return child
}

describe('a launch is not finished until the browser has answered', () => {
  it('hands back the handle and the pipe it answered on', async () => {
    const child = makeAnsweringChild()
    const result = await launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.handle.pid).toBe(4242)
    // The same pipe the handshake went over — a second CdpPipe on these fds
    // would race the first for every byte.
    expect(await result.transport.command({ method: 'Browser.getVersion' })).toEqual({
      product: 'Chrome/146.0.7680.165',
    })
    result.handle.close()
  })

  /*
   * The measured failure, end to end. Before this, a Chromium missing
   * `libatk-1.0.so.0` produced a launch that said `ok: true`, a pid, and two
   * open fds — and was gone thirty milliseconds later with exit 127.
   */
  it('refuses when the child dies immediately, and says why', async () => {
    const child = makeChild()
    const pending = launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
      readyTimeoutMs: 2000,
    })
    child.say(
      '/opt/chrome/chrome: error while loading shared libraries: libatk-1.0.so.0: cannot open shared object file: No such file or directory\n',
    )
    await new Promise((resolve) => setImmediate(resolve))
    child.exit(127)

    const result = await pending
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('libatk-1.0.so.0')
    expect(result.why).toContain('install')
  })

  it('refuses, and kills the child, when the browser starts and never answers', async () => {
    let killed = 0
    const child = makeChild({
      kill: () => {
        killed += 1
        return true
      },
    })
    const result = await launchChromium({
      executablePath: '/opt/chrome/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(child, []),
      sandboxFacts: SANDBOXED,
      readyTimeoutMs: 30,
    })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.why).toContain('did not answer its first command')
    // A wedged browser still holds the profile lock, so it is not left behind.
    expect(killed).toBe(1)
  })

  it('passes a spawn failure straight through, with nothing to confirm', async () => {
    const result = await launchChromium({
      executablePath: '/no/such/chrome',
      userDataDir: '/p',
      spawn: fakeSpawn(makeChild({ pid: undefined, stdio: [null, null, null, null, null] }), []),
      sandboxFacts: SANDBOXED,
    })
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('could not be spawned')
  })
})

describe('confirmReady, on its own', () => {
  const answers = { command: async () => ({}) }
  const silence = { command: () => new Promise<unknown>(() => {}) }

  it('is null when the browser answers', async () => {
    expect(await confirmReady(answers, new Promise(() => {}), 1000)).toBeNull()
  })

  it('is the death when the browser dies first', async () => {
    const why = await confirmReady(silence, Promise.resolve('Chromium exited with code 127'), 1000)
    expect(why).toContain('code 127')
  })

  it('is the timeout when it neither answers nor dies', async () => {
    const why = await confirmReady(silence, new Promise(() => {}), 20)
    expect(why).toContain('did not answer its first command')
  })

  it('is a named error when the browser rejects the command and never exits', async () => {
    const refuses = { command: async () => Promise.reject(new Error('the debugger pipe is closed')) }
    const why = await confirmReady(refuses, new Promise(() => {}), 1000, 20)
    expect(why).toContain('refused its first command')
    expect(why).toContain('the debugger pipe is closed')
  })

  /*
   * The ordering that the real-process test caught. With a live child the fd
   * closes before `'exit'` is delivered, so the pipe's own complaint wins the
   * race — and it is the one arm that knows nothing about why. The exit gets a
   * bounded moment to arrive, and when it does it is what a person is told.
   */
  it('prefers the exit reason over the pipe error that arrived first', async () => {
    const refuses = { command: async () => Promise.reject(new Error('the debugger pipe closed')) }
    const laterExit = new Promise<string>((resolve) =>
      setTimeout(() => resolve('Chromium could not start: it needs libatk-1.0.so.0'), 10),
    )
    const why = await confirmReady(refuses, laterExit, 1000, 500)
    expect(why).toContain('libatk-1.0.so.0')
    expect(why).not.toContain('pipe closed')
  })
})

/* ------------------------------------------------------ against a real exec -- */

/**
 * A real process, on this machine, that dies the way the reference server's
 * Chromium died.
 *
 * Everything above models a child. This one *is* one: a shell script that writes
 * the linker's own sentence to stderr and exits 127, spawned through the real
 * `node:child_process`. It is the check on the model — the fakes agree with the
 * production code by construction, and this is the only assertion in the file
 * that could catch them agreeing about the wrong thing.
 *
 * Skipped on Windows, where there is no `/bin/sh` and the whole failure mode
 * belongs to Linux anyway.
 */
describe.skipIf(process.platform === 'win32')('against a process that really dies', () => {
  it('refuses the launch and names the missing library', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'td-launch-'))
    const fake = join(dir, 'chrome')
    writeFileSync(
      fake,
      '#!/bin/sh\n' +
        'echo "$0: error while loading shared libraries: libatk-1.0.so.0: cannot open shared object file: No such file or directory" >&2\n' +
        'exit 127\n',
    )
    chmodSync(fake, 0o755)
    try {
      const result = await launchChromium({
        executablePath: fake,
        userDataDir: join(dir, 'profile'),
        readyTimeoutMs: 5000,
      })
      expect(result.ok).toBe(false)
      if (result.ok) return
      expect(result.why).toContain('libatk-1.0.so.0')
      expect(result.why).toContain('install')
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })
})
