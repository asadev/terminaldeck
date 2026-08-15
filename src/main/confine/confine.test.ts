import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import {
  ConfinementUnavailableError,
  confineSpawn,
  confinementKind,
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
    expect(unconfinedReason('linux')).toMatch(/bubblewrap/)
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
