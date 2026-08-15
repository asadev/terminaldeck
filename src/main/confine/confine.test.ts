import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs'
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
import type { ConfinementPlan } from './plan'
import { SANDBOX_EXEC } from './seatbelt'

const plan: ConfinementPlan = {
  writable: ['/work/app'],
  readable: ['/usr'],
  readableFiles: [],
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
  it('confines macOS and nothing else', () => {
    expect(confinementKind('darwin')).toBe('seatbelt')
    expect(confinementKind('win32')).toBe('none')
    expect(confinementKind('linux')).toBe('none')
  })

  it('names the mechanism it has not measured, rather than being vague', () => {
    // The grant screen tells a person which of the two they are getting. It can
    // only do that honestly if the reason is specific enough to act on.
    expect(unconfinedReason('win32')).toMatch(/AppContainer/)
  })

  it('does not tell Linux it is unmeasured, because it is not any more', () => {
    /*
     * This assertion used to be `toMatch(/bubblewrap/)`, and the sentence used
     * to end "has not been built or measured". Half of that is no longer true:
     * the mechanism was run on a real Ubuntu 24.04 under WSL2 and it held —
     * unprivileged user namespaces are enabled there, a bind-mount boundary
     * hides the owner's home and `/mnt/c`, and dropping the capability bounding
     * set is what stops the confined shell simply unmounting its way out. The
     * module header records the whole run.
     *
     * `bwrap` is specifically *not* named any more, because it is not installed
     * on that machine and installing it needs sudo — pointing a person at a tool
     * they cannot get is not a reason they can act on. What is still honestly
     * unmeasured is the `wsl.exe --cd` launch this app uses, so that is what the
     * sentence names, and the mechanism is described as holding rather than as
     * unknown.
     */
    const reason = unconfinedReason('linux')
    expect(reason).toMatch(/user namespaces/)
    expect(reason).toMatch(/launch path/)
    // It has to say the mechanism *holds*, which is the half that changed. The
    // sentence still contains "has not been measured" and that is correct — it
    // is now said about the launch path rather than about the whole idea.
    expect(reason).toMatch(/hold/)
    // And it must not point at `bwrap`. It is not installed on the machine this
    // was measured on and installing it needs sudo, so naming it sends a person
    // after a tool they cannot get for a boundary that would not use it.
    expect(reason).not.toMatch(/bubblewrap/)
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
