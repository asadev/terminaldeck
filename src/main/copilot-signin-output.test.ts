import { describe, expect, it } from 'vitest'
import { outputOf } from './copilot-session'
import { parseAuthStatus } from './profiles-signin'

/**
 * A command that answers by exiting non-zero still answered.
 *
 * ## The bug this pins, seen on screen
 *
 * `claude auth status --json` **exits 1 when it is not logged in** — measured
 * against Claude Code 2.1.233, with a complete `{"loggedIn": false, …}` on
 * stdout and nothing on stderr. `promisify(execFile)` rejects on any non-zero
 * exit and hangs the output off the *rejection*, so the sign-in probe awaited
 * it, caught the rejection, threw away a perfectly good answer and reported
 * `unknown`.
 *
 * `unknown` is the one sign-in state drawn as *"this window could not check"*.
 * So the effect was that a signed-out copilot could never be reported as
 * signed out — and **every copilot is signed out on its first run**, by design,
 * because its login lives inside a sandbox that cannot reach the macOS
 * keychain. The single state a person most needs explained was the one state
 * the app could not reach. The copilot's own terminal showed `Select login
 * method:` while the pane above it said the sign-in could not be checked.
 *
 * `profiles-signin.ts` had already learned this for the per-account probes and
 * reads stdout off the failure. This is that lesson applied to the prober that
 * had not had it, and this file is what stops the `await run(...)` going back.
 */

/** The exact shape `execFile` rejects with. */
function execFailure(over: { stdout?: string; stderr?: string; code?: number }): Error {
  return Object.assign(new Error('Command failed'), {
    code: over.code ?? 1,
    killed: false,
    signal: null,
    stdout: over.stdout ?? '',
    stderr: over.stderr ?? '',
  })
}

const SIGNED_OUT = '{\n  "loggedIn": false,\n  "authMethod": "none",\n  "apiProvider": "firstParty"\n}\n'

describe('reading a probe that exited non-zero', () => {
  it('keeps the answer the CLI printed before it exited 1', async () => {
    const output = await outputOf(Promise.reject(execFailure({ stdout: SIGNED_OUT })))
    expect(output.stdout).toBe(SIGNED_OUT)
  })

  it('turns that answer into "signed out" rather than "could not check"', async () => {
    // The whole point, end to end: this is the pair of calls `probeSignIn`
    // makes, and it is what decides whether the first-run explanation ever
    // appears for the copilot it was written for.
    const output = await outputOf(Promise.reject(execFailure({ stdout: SIGNED_OUT })))
    const parsed = parseAuthStatus(`${output.stdout}\n${output.stderr}`)
    expect(parsed).not.toBeNull()
    expect(parsed?.loggedIn).toBe(false)
  })

  it('passes a successful run straight through', async () => {
    const ok = { stdout: '{"loggedIn":true,"email":"a@b.c"}', stderr: '' }
    expect(await outputOf(Promise.resolve(ok))).toEqual(ok)
  })

  it('still reports nothing when the process was killed with nothing written', async () => {
    // A timeout genuinely is "could not check", and it has to stay that way:
    // `unknown` must never be collapsed into `signed-out`, because the two send
    // a person to completely different places.
    const output = await outputOf(Promise.reject(execFailure({})))
    expect(parseAuthStatus(`${output.stdout}\n${output.stderr}`)).toBeNull()
  })

  it('survives a rejection that is not an exec failure at all', async () => {
    // A spawn that never started rejects with a plain Error carrying no
    // streams. Reading `.stdout` off it must produce empty strings rather than
    // an `undefined` that reaches the parser.
    const output = await outputOf(Promise.reject(new Error('spawn ENOENT')))
    expect(output).toEqual({ stdout: '', stderr: '' })
  })
})
