import { existsSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, describe, expect, it } from 'vitest'
import {
  ConfinementUnavailableError,
  confineSpawn,
  confinementKind,
  deviceHomesRoot,
  prepareDeviceHome,
  proveConfinement,
  unconfinedReason,
  type ProofRunner,
} from './index'
import type { ProbeFiles } from './appcontainer'
import type { ConfinementPlan } from './plan'
import { SANDBOX_EXEC } from './seatbelt'
import { capabilitySid, installWindowsTools, resetWindowsTools, writeGrantRecord } from './tools'

const plan: ConfinementPlan = {
  folder: '/work/app',
  accountHome: '/home/asad',
  home: '/app-storage/device-home/abc',
  writable: ['/work/app'],
  readable: ['/usr'],
  readableFiles: [],
  readableProjects: [],
  readExclusions: [],
}

/**
 * A `sandbox-exec` that does whatever the test needs.
 *
 * The two shapes worth pinning are a sandbox that leaks and a sandbox that
 * refuses everything, and neither can be produced on a machine where the real
 * one works. Injecting the runner is the only way to check that the proof
 * notices both — which matters more than it sounds, because a broken sandbox
 * that runs nothing would pass a naive "did the secret come back" check by
 * failing at absolutely everything.
 */
function runner(behaviour: (args: readonly string[]) => string): ProofRunner {
  return async (command, args) => {
    expect(command).toBe(SANDBOX_EXEC)
    return { stdout: behaviour(args), stderr: '' }
  }
}

/**
 * Which of the proof's two probes this is.
 *
 * The proof runs `sandbox-exec -p <profile> /bin/echo <token>` and then
 * `sandbox-exec -p <profile> /bin/cat <canary>`, so the program is at index two
 * and its one argument is last. Reading them positionally rather than by
 * matching the path keeps this honest if the canary is ever moved somewhere
 * whose name does not contain the word.
 */
function probe(args: readonly string[]): { program: string; target: string } {
  return { program: args[2] ?? '', target: args[args.length - 1] ?? '' }
}

describe('which platforms are confined', () => {
  it('confines macOS and Linux, by two different mechanisms', () => {
    expect(confinementKind('darwin')).toBe('seatbelt')
    expect(confinementKind('win32')).toBe('none')
    /*
     * This used to be `'none'`, with a sentence saying the mechanism held but
     * the launch path had never been run. Both of the reasons that sentence
     * gave are now measured, on the same Ubuntu 24.04 under WSL2:
     *
     *  - a session started through the real `wsl.exe --cd` login-shell path is
     *    held inside its folder, and the same session started that way *without*
     *    the boundary reads the account's `.ssh`, its git credentials, its
     *    stored tokens and the whole of `/mnt/c`;
     *  - `WSL_INTEROP` is shut, and shut by covering `/run/WSL` rather than by
     *    unsetting the variable — with the variable unset and that directory
     *    left alone, a Windows `.exe` inside the granted folder still ran.
     *
     * `linux.ts` carries the whole table. Note that a session inside WSL still
     * reports `win32` here, because the app is a Windows process; that path asks
     * for the Linux answer explicitly through `confineWslLine`.
     */
    expect(confinementKind('linux')).toBe('namespace')
  })

  it('names the mechanism, rather than being vague', () => {
    // The grant screen tells a person which of the two they are getting. It can
    // only do that honestly if the reason is specific enough to act on.
    expect(unconfinedReason('win32')).toMatch(/AppContainer/)
  })

  it('no longer says the Windows mechanisms are unmeasured, because they are not', () => {
    // The sentence this used to carry ended "has not been built or measured".
    // Every mechanism named in it has since been run on a real Windows 11
    // machine: AppContainer holds, restricted tokens and job objects were
    // measured and written off. A UI sentence that outlives its measurement is
    // the same kind of lie as a boundary that outlives its proof.
    expect(unconfinedReason('win32')).not.toMatch(/has not been (built or )?measured/)
    expect(unconfinedReason('win32')).toMatch(/restricted tokens and job objects were measured|one-time permission/)
  })

  it('keeps WSL in a sentence of its own, on whichever reason is showing', () => {
    // A session in a WSL folder is a Linux process that no Windows mechanism can
    // cover. One sentence covering two platforms is what rule 1 of
    // CONFINEMENT.md exists to stop.
    const sentences = unconfinedReason('win32').split('. ')
    expect(sentences.filter((line) => line.includes('WSL'))).toHaveLength(1)
    expect(sentences.find((line) => line.includes('WSL'))).not.toMatch(/AppContainer/)
  })
})

describe('the Windows gate', () => {
  const dirs: string[] = []
  afterAll(() => {
    for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
    resetWindowsTools()
  })
  const machineWith = (options: { launcher: boolean; record: boolean }): void => {
    const dir = mkdtempSync(join(tmpdir(), 'confine-gate-'))
    dirs.push(dir)
    if (options.launcher) writeFileSync(join(dir, 'tdconfine.exe'), 'not really an exe')
    if (options.record) {
      writeGrantRecord(join(dir, 'windows-confinement.json'), {
        capability: capabilitySid(),
        read: ['C:\\Program Files\\nodejs'],
        ancestors: ['C:\\', 'C:\\Users', 'C:\\Users\\Imza'],
        established: '2026-08-16T05:00:00.000Z',
      })
    }
    installWindowsTools({
      launcher: join(dir, 'tdconfine.exe'),
      recordFile: join(dir, 'windows-confinement.json'),
    })
  }

  it('is off on a build that ships no launcher, and says why', () => {
    machineWith({ launcher: false, record: true })
    expect(confinementKind('win32')).toBe('none')
    expect(unconfinedReason('win32')).toMatch(/does not ship/)
  })

  it('is off on a machine that has not been set up, and says something else', () => {
    // Two reasons with two remedies. Running them together would tell somebody a
    // feature is missing from their copy of the app when it is one prompt away.
    machineWith({ launcher: true, record: false })
    expect(confinementKind('win32')).toBe('none')
    expect(unconfinedReason('win32')).toMatch(/one-time permission/)
  })

  it('is on only when the launcher is there and the grant has been made', () => {
    machineWith({ launcher: true, record: true })
    expect(confinementKind('win32')).toBe('appcontainer')
  })

  it('does not answer for Windows on a machine nothing has been installed on', () => {
    // The headless build on a server, and every test that never called
    // `installWindowsTools`. Answering anything but 'none' here would be a claim
    // made out of a default.
    resetWindowsTools()
    expect(confinementKind('win32')).toBe('none')
  })
})

describe('the proof', () => {
  it('refuses to claim a boundary on a platform that has none', async () => {
    const proof = await proveConfinement(plan, 'win32')
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/Windows/)
  })

  it('fails when the canary comes back out', async () => {
    // The whole point. A sandbox that hands over a file written outside the plan
    // is not a boundary, however good the profile looks.
    const leaky = runner((args) => {
      const { program, target } = probe(args)
      // Both probes behave exactly as an unconfined machine would: `echo` prints
      // its argument, and `cat` prints the file. That is a sandbox that starts
      // processes perfectly and confines nothing.
      return program === '/bin/echo' ? target : readCanary(target)
    })
    const proof = await proveConfinement(plan, 'darwin', leaky)
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/outside the folder was readable/)
  })

  it('fails when the sandbox refuses to run anything at all', async () => {
    // The failure a naive check would score as a pass: nothing runs, so nothing
    // leaks. It has to be reported as broken, not as confined.
    const dead = runner(() => '')
    const proof = await proveConfinement(plan, 'darwin', dead)
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/would not run a command/)
  })

  it('passes when the token comes back and the canary does not', async () => {
    const proof = await proveConfinement(plan, 'darwin', workingSandbox())
    expect(proof).toEqual({ ok: true, detail: '' })
  })
})

/* --------------------------------------------------------------- the linux -- */

/**
 * A machine that answers the Linux proof, with the knobs that matter.
 *
 * The proof runs the same script three times — plant, read-from-inside, clean —
 * and every failure it exists to catch is a different answer to one of those.
 * None of them can be produced on a machine where the real thing works, which
 * is the whole reason the runner is injectable.
 *
 * The arguments are read from the end because that is the only stable place:
 * the confined run has a whole `unshare` invocation and a shell script in front
 * of them, and matching on that would be a test of the argument builder wearing
 * a test of the proof as a disguise.
 */
function linuxMachine(options: {
  leaks?: boolean
  plantable?: boolean
  starts?: boolean
  interop?: string
  runwsl?: string
  modes?: string[]
}): ProofRunner {
  return async (command, args) => {
    const [mode, token, , , homeSecret, tmpSecret] = args.slice(-6)
    options.modes?.push(mode ?? '')
    if (mode === 'clean') return { stdout: '', stderr: '' }

    const confined = command !== '/bin/sh'
    if (confined && options.starts === false) {
      return { stdout: '', stderr: 'unshare: Operation not permitted' }
    }
    const readable = confined ? options.leaks === true : options.plantable !== false
    return {
      stdout: [
        `td-token ${token ?? ''}`,
        `td-home ${readable ? (homeSecret ?? '') : ''}`,
        `td-tmp ${readable ? (tmpSecret ?? '') : ''}`,
        `td-interop ${confined ? (options.interop ?? 'none') : '/run/WSL/7_interop'}`,
        `td-runwsl ${confined ? (options.runwsl ?? '') : '7_interop'}`,
        'td-uid 0',
      ].join('\n'),
      stderr: '',
    }
  }
}

describe('the Linux proof', () => {
  const linuxPlan: ConfinementPlan = {
    folder: '/home/asad/work/app',
    accountHome: '/home/asad',
    home: '/app-storage/device-home/abc',
    writable: ['/home/asad/work/app'],
    readable: ['/usr'],
    readableFiles: [],
    readableProjects: [],
    readExclusions: [],
  }

  it('passes when the canary is readable outside and refused inside', async () => {
    const proof = await proveConfinement(linuxPlan, 'linux', linuxMachine({}))
    expect(proof).toEqual({ ok: true, detail: '' })
  })

  it('fails when the canary comes back from inside', async () => {
    const proof = await proveConfinement(linuxPlan, 'linux', linuxMachine({ leaks: true }))
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/outside the folder was readable/)
  })

  it('fails when the machine will not start the namespace, in its own words', async () => {
    // What a distribution with AppArmor's userns restriction switched on looks
    // like. The kernel's sentence is the only useful thing anybody will have,
    // so it has to survive into the detail.
    const proof = await proveConfinement(linuxPlan, 'linux', linuxMachine({ starts: false }))
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/would not start the namespace/)
    expect(proof.detail).toMatch(/Operation not permitted/)
  })

  it('fails when the canary could not be read from outside either', async () => {
    // The failure a naive check scores as a pass, and not a hypothetical: on a
    // Windows machine launching into WSL, a canary path computed on the Windows
    // side names a file the Linux session could never have read, and every
    // check would have "passed".
    const proof = await proveConfinement(linuxPlan, 'linux', linuxMachine({ plantable: false }))
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/could not fail/)
  })

  it('fails when the session still has the interop socket', async () => {
    const proof = await proveConfinement(
      linuxPlan,
      'linux',
      linuxMachine({ interop: '/run/WSL/7_interop' }),
    )
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/WSL_INTEROP/)
  })

  it('fails when the interop sockets are still reachable, variable or not', async () => {
    // Measured, and the half that does the work: with the variable unset and
    // this directory left alone, a Windows binary inside the granted folder
    // still ran.
    const proof = await proveConfinement(linuxPlan, 'linux', linuxMachine({ runwsl: '7_interop' }))
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/\/run\/WSL/)
  })

  it('passes when the home is the granted folder — uses tmp canary only', async () => {
    /*
     * A grant on the whole account home (the common fallback on a fresh server).
     * homeCanary lands inside the plan, but tmpCanary (/tmp/…) is still outside,
     * so the proof uses only the tmp canary rather than refusing entirely.
     */
    const wide: ConfinementPlan = { ...linuxPlan, writable: ['/home/asad'] }
    const proof = await proveConfinement(wide, 'linux', linuxMachine({}))
    expect(proof.ok).toBe(true)
  })

  it('refuses when both canaries land inside the boundary', async () => {
    // Grant on '/' covers both /home/asad/… and /tmp/… — no canary left outside.
    const everywhere: ConfinementPlan = { ...linuxPlan, writable: ['/'] }
    const proof = await proveConfinement(everywhere, 'linux', linuxMachine({}))
    expect(proof.ok).toBe(false)
    expect(proof.detail).toMatch(/both test files/)
  })

  it('takes its canaries away again, even when the boundary failed', async () => {
    const modes: string[] = []
    await proveConfinement(linuxPlan, 'linux', linuxMachine({ leaks: true, modes }))
    expect(modes).toEqual(['plant', 'read', 'clean'])
  })

  it('wraps the session in a namespace once it has proven one', async () => {
    const launch = await confineSpawn(linuxPlan, '/bin/bash', ['-l'], 'linux', linuxMachine({}))
    expect(launch.command).toMatch(/unshare$/)
    expect(launch.args).toContain('--map-root-user')
    expect(launch.args.slice(launch.args.indexOf('--'))).toEqual(['--', '/bin/bash', '-l'])
  })

  it('throws rather than handing back an unconfined command', async () => {
    await expect(
      confineSpawn(linuxPlan, '/bin/bash', ['-l'], 'linux', linuxMachine({ leaks: true })),
    ).rejects.toBeInstanceOf(ConfinementUnavailableError)
  })
})

describe('confineSpawn', () => {
  it('wraps the command when the boundary is proven', async () => {
    const wrapped = await confineSpawn(plan, '/bin/zsh', ['-l'], 'darwin', workingSandbox())
    expect(wrapped.command).toBe(SANDBOX_EXEC)
    expect(wrapped.args.slice(2)).toEqual(['/bin/zsh', '-l'])
  })

  it('throws rather than handing back an unconfined command', async () => {
    // The rule that keeps the grant screen honest: on a platform where
    // confinement is available, a session either starts confined or does not
    // start. There is no third answer and no silent downgrade.
    const dead = runner(() => '')
    await expect(confineSpawn(plan, '/bin/zsh', ['-l'], 'darwin', dead)).rejects.toBeInstanceOf(
      ConfinementUnavailableError,
    )
  })

  it('carries the reason on the error, for the log rather than for the phone', async () => {
    const dead = runner(() => '')
    const error = await confineSpawn(plan, '/bin/zsh', [], 'darwin', dead).catch(
      (thrown: unknown) => thrown,
    )
    expect(error).toBeInstanceOf(ConfinementUnavailableError)
    expect((error as ConfinementUnavailableError).detail).toMatch(/would not run a command/)
  })

  describe('on Windows', () => {
    const dirs: string[] = []
    const windowsPlan: ConfinementPlan = {
      folder: 'C:\\Users\\Imza\\Projects\\app',
      accountHome: 'C:\\Users\\Imza',
      home: 'C:\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc',
      writable: [
        'C:\\Users\\Imza\\Projects\\app',
        'C:\\Users\\Imza\\AppData\\Roaming\\td\\device-home\\abc',
      ],
      readable: ['C:\\Program Files\\nodejs'],
      readableFiles: [],
      readableProjects: [],
      readExclusions: [],
    }
    afterAll(() => {
      for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
      resetWindowsTools()
    })
    const setUp = (): string => {
      const dir = mkdtempSync(join(tmpdir(), 'confine-spawn-'))
      dirs.push(dir)
      writeFileSync(join(dir, 'tdconfine.exe'), 'not really an exe')
      writeGrantRecord(join(dir, 'windows-confinement.json'), {
        capability: capabilitySid(),
        read: ['C:\\Program Files\\nodejs'],
        ancestors: ['C:\\', 'C:\\Users', 'C:\\Users\\Imza'],
        established: '2026-08-16T05:00:00.000Z',
      })
      installWindowsTools({
        launcher: join(dir, 'tdconfine.exe'),
        recordFile: join(dir, 'windows-confinement.json'),
      })
      return dir
    }

    /**
     * The proof's two canaries, held in memory instead of on this machine's disk.
     *
     * This is the whole of the cross-platform fix, and it is worth saying what it
     * replaced because the old version looked perfectly innocent. The proof plants
     * a canary inside the boundary and one outside it, at paths derived from the
     * plan — and every path in a Windows plan starts with a drive letter. This
     * block used to let the real `fs` write them. On macOS a backslash is an
     * ordinary filename character, so
     * `C:\Users\Imza\AppData\Roaming\td\device-home\abc\.terminaldeck-confine-probe-…`
     * is not a path at all, it is one very long filename in the working directory,
     * and the write succeeds. On a Windows runner it is a real absolute path to a
     * directory that has never existed there, the write is `ENOENT`, the proof
     * correctly refuses, and `confineSpawn` throws — so the one test asserting
     * that Windows spawns the launcher failed on the one platform where Windows
     * confinement is not hypothetical, and passed everywhere else.
     *
     * `appcontainer.ts` had already built the {@link ProbeFiles} seam for exactly
     * this and said so in its comment; it simply was not threaded through
     * `proveConfinement` and `confineSpawn`, so the test could not reach it from
     * the real entry point. It is now, and the run below touches no filesystem on
     * either platform.
     *
     * `remove` keeps the entry rather than dropping it, so the assertions after
     * the run can see both what was planted and what was swept.
     */
    function probeFiles(): ProbeFiles & { written: Map<string, string>; removed: string[] } {
      const written = new Map<string, string>()
      const removed: string[] = []
      return {
        written,
        removed,
        write(path, contents) {
          written.set(path, contents)
        },
        remove(path) {
          removed.push(path)
        },
      }
    }

    /**
     * A launcher that behaves the way the real one did on the real machine: the
     * canary inside the boundary comes back, the one outside it never does, and
     * the tool check answers.
     *
     * The token is echoed back out of the script rather than invented, because
     * whether the script has a tool check at all depends on `toolProbe` finding a
     * real `node.exe` — which a Windows runner has and this Mac does not. Both
     * shapes are pinned deliberately in `appcontainer.test.ts`; here the launcher
     * simply answers whichever one it was handed, so this case is about the
     * launcher being spawned and not about the probe's contents.
     */
    const launcherThatWorks =
      (files: { written: Map<string, string> }): ProofRunner =>
      async (_command, args) => {
        const script = args[args.length - 1] ?? ''
        const canary = /type ([^ ]+)/.exec(script)?.[1] ?? ''
        const token = /echo ([0-9a-f]{24})/.exec(script)?.[1] ?? ''
        return { stdout: `${files.written.get(canary) ?? ''}\n${token}\n`, stderr: '' }
      }

    it('spawns the launcher rather than the command itself', async () => {
      // The whole reason this platform needs an .exe of its own: an AppContainer
      // is applied inside the CreateProcess call, so the thing being spawned has
      // to be the program that makes that call.
      const dir = setUp()
      const files = probeFiles()
      const wrapped = await confineSpawn(
        windowsPlan,
        'C:\\Windows\\System32\\cmd.exe',
        ['/c', 'claude'],
        'win32',
        launcherThatWorks(files),
        // The Linux machine seam, which a Windows plan never reaches. Spelled as
        // `undefined` rather than filled in so that the real default stays the
        // real default, and the argument after it is the one this case is about.
        undefined,
        files,
      )
      expect(wrapped.command).toBe(join(dir, 'tdconfine.exe'))
      expect(wrapped.args.slice(wrapped.args.indexOf('--') + 1)).toEqual([
        'C:\\Windows\\System32\\cmd.exe',
        '/c',
        'claude',
      ])
    })

    it('plants its canaries through the injected filesystem, not this one', async () => {
      /*
       * The guard that stops the bug above coming back, and it fails on a Mac
       * rather than only on a Windows runner — which is the point of it. If
       * `confineSpawn` ever stops passing the seam down to `proveAppContainer`,
       * the proof falls back to the real `fs`, nothing reaches this map, and the
       * count below is zero here, today, in this run. A guard that could only
       * fail on Windows CI is a guard nobody sees until the release.
       *
       * Drive-rooted is asserted for the same reason: these are the paths the
       * launcher is handed, and a canary that had been quietly rewritten into a
       * POSIX path would be testing a boundary the real machine never sees.
       */
      setUp()
      const files = probeFiles()
      await confineSpawn(
        windowsPlan,
        'C:\\Windows\\System32\\cmd.exe',
        [],
        'win32',
        launcherThatWorks(files),
        undefined,
        files,
      )

      const planted = [...files.written.keys()]
      expect(planted).toHaveLength(2)
      for (const path of planted) expect(path).toMatch(/^[A-Za-z]:\\/)
      // One inside the boundary and one outside it, and both swept afterwards —
      // a canary left behind is a file of random hex in somebody's home.
      expect(planted.some((path) => path.startsWith(windowsPlan.home))).toBe(true)
      expect(planted.some((path) => path.startsWith(`${windowsPlan.accountHome}\\.`))).toBe(true)
      expect([...files.removed].sort()).toEqual([...planted].sort())
      // And none of it happened here. On a Mac these are legal filenames in the
      // working directory, which is exactly how the old version passed.
      for (const path of planted) expect(existsSync(path)).toBe(false)
    })

    it('refuses when the machine has not been set up, rather than running anyway', async () => {
      // Reached when the grant is withdrawn between the gate and the spawn — a
      // repair install, or somebody undoing it by hand. The session refuses.
      resetWindowsTools()
      const files = probeFiles()
      await expect(
        confineSpawn(
          windowsPlan,
          'cmd.exe',
          [],
          'win32',
          launcherThatWorks(files),
          undefined,
          files,
        ),
      ).rejects.toBeInstanceOf(ConfinementUnavailableError)
    })
  })
})

/* -------------------------------------------------------------------------- */

/** Read the canary the proof just wrote, which is what a leak would return. */
function readCanary(path: string): string {
  return readFileSync(path, 'utf8')
}

/** A sandbox that runs commands and refuses the canary — the answer we want. */
function workingSandbox(): ProofRunner {
  return runner((args) => {
    const { program, target } = probe(args)
    return program === '/bin/echo' ? target : ''
  })
}

/**
 * What a device's home has in it before its first session runs.
 *
 * Two directories, and each is made in advance for a reason that only shows up
 * somewhere else. `tmp` is the session's `TMPDIR`, and a `TMPDIR` that does not
 * exist means `git commit` fails with a message about a path the person cannot
 * see. `.claude/projects` is where the agent will write its transcripts, and it
 * is made now so that the cost pane's watcher — which reads these stores — is
 * aimed at a directory that exists rather than at one that is about to.
 */
describe('a device home before anything has run in it', () => {
  const made: string[] = []
  afterAll(() => {
    for (const dir of made) rmSync(dir, { recursive: true, force: true })
  })

  function root(): string {
    const dir = mkdtempSync(join(tmpdir(), 'deck-device-home-'))
    made.push(dir)
    return dir
  }

  it('makes the scratch directory and the agent store', () => {
    const home = prepareDeviceHome(root(), 'device-abc')
    expect(existsSync(join(home, 'tmp'))).toBe(true)
    expect(existsSync(join(home, '.claude', 'projects'))).toBe(true)
  })

  it('is keyed by device, so two devices do not share a home', () => {
    const base = root()
    expect(prepareDeviceHome(base, 'device-a')).not.toBe(prepareDeviceHome(base, 'device-b'))
  })

  it('can be prepared twice, because every spawn calls it', () => {
    const base = root()
    expect(prepareDeviceHome(base, 'device-abc')).toBe(prepareDeviceHome(base, 'device-abc'))
  })

  it.skipIf(process.platform === 'win32')('keeps it to the owner', () => {
    // One account owns the machine, but nothing in here needs to be readable by
    // another one. Skipped on Windows, where POSIX mode bits are not the
    // mechanism and `mkdir`'s mode argument is ignored.
    const home = prepareDeviceHome(root(), 'device-abc')
    expect(statSync(join(home, 'tmp')).mode & 0o777).toBe(0o700)
  })

  it('puts the homes under one root, spelled in one place', () => {
    // The spelling is shared with `transcript.ts`, which reads these stores to
    // find a confined session's conversation. Two spellings of one directory
    // name is how a reader ends up looking somewhere the writer never writes.
    expect(deviceHomesRoot('/app-storage')).toBe(join('/app-storage', 'device-home'))
  })
})
