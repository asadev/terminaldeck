import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { mayFetchFor } from './auto-usage'

/**
 * Which sessions the usage bar looks for by itself.
 *
 * ## The recording this file is the answer to
 *
 * Asad, on the bar: *"usage should appear on its own, not need a click."* It
 * did, on a session this app had spawned as `claude`. It did not on the session
 * shape he actually works in — a `$SHELL -l` with `claude` typed at its prompt,
 * which is an ordinary thing to do and is a thing the account chip beside this
 * very bar offers a button for. That bar mounted, subscribed to `usage:update`
 * and then never initiated a single look of its own, because `auto-usage.ts`
 * opened both of its effects with `provider !== 'claude'` and the answer
 * `SessionControls` hands it for that session is `undefined` — `runningProvider`
 * turns `shell` into "not known" the moment the screen says an agent is there.
 *
 * So the figure arrived only if some *other* session on the same login went and
 * probed, or if `.claude.json` already held one. On a machine whose only session
 * is that one, the bar sat at "Not reported" for ever, which is the requirement
 * failing on precisely the case it was reported for.
 *
 * ## Why the gate is asserted rather than the hook
 *
 * This project's test setup has no DOM, deliberately — every render test in this
 * folder goes through `react-dom/server`, which never runs an effect. A hook
 * whose entire behaviour is two `useEffect` bodies therefore cannot be observed
 * by rendering it. Pulling the decision out into a named function is what makes
 * it testable at all, and it is also what lets the second test below compare it
 * against the main process's answer, which is the comparison that matters:
 * these two gates are the same question asked in two processes, and the bug was
 * that they had drifted apart.
 */
describe('which sessions fetch their own usage', () => {
  it('lets through the session the requirement was reported on', () => {
    /*
     * `undefined` is not an absence here, it is an answer: this app never saw
     * which CLI was typed at the prompt. It is the commonest answer on his
     * machine and it was the one being refused.
     */
    expect(mayFetchFor(undefined)).toBe(true)
    expect(mayFetchFor('claude')).toBe(true)
    // A bare shell too. It does not reach the bar today — the cluster withdraws
    // itself for one before `UsageBar` is composed — but the main process allows
    // it and a gate that agrees with the far end by accident is a gate that will
    // stop agreeing when the surface above it changes.
    expect(mayFetchFor('shell')).toBe(true)
  })

  it('still turns away a session that is explicitly running another agent', () => {
    // The half of the old gate that was right, and the reason it existed:
    // `usage:refresh` reads a Claude login's figures, and putting them on a
    // Codex bar would push off the reading that bar does have.
    expect(mayFetchFor('codex')).toBe(false)
    expect(mayFetchFor('gemini')).toBe(false)
    /*
     * And an agent this build has never heard of. Written as an allowlist for
     * exactly this case: `ProviderId` includes `custom:${string}`, so a build
     * that learns a new agent tomorrow must not have it fall through to the
     * permissive side of a rule written before it existed.
     */
    expect(mayFetchFor('custom:some-other-cli')).toBe(false)
  })

  it('asks the same question the main process answers, in the same shape', () => {
    /*
     * The drift this whole finding was. `mayShareClaude` in `usage-ipc.ts` is
     * the authority — `refreshUsage` consults it before it reads a byte and
     * returns "This session runs a different agent" for anything it refuses — so
     * a renderer gate stricter than it suppresses a fetch the far end would have
     * served, and a looser one spends a round trip to be told no.
     *
     * Compared by shape rather than by exact text on purpose: this is asserting
     * that the two allowlists still name the same agents, not that nobody may
     * ever reword the sentence beside them.
     */
    const main = readFileSync(join(__dirname, '../../main/usage-ipc.ts'), 'utf8')
    const body = /function mayShareClaude\([^)]*\): boolean \{([\s\S]*?)\n\}/.exec(main)?.[1]
    expect(body, 'mayShareClaude has moved or been renamed — the two gates cannot be compared').toBeTruthy()
    expect(body).toContain('session === null')
    expect(body).toContain("=== 'claude'")
    expect(body).toContain("=== 'shell'")
    expect(body).not.toContain("'codex'")
    expect(body).not.toContain("'gemini'")
  })

  it('has no second copy of the rule left in the effects', () => {
    /*
     * Both effects used to carry the gate inline, and that is how they came to
     * disagree with the main process without anybody noticing: there was nothing
     * named to compare. The literal is asserted absent as well as the call
     * present, because re-adding `provider !== 'claude'` beside `mayFetchFor`
     * would leave every test above green while restoring the bug.
     */
    const source = readFileSync(join(__dirname, 'auto-usage.ts'), 'utf8')
    expect(source.match(/mayFetchFor\(provider\)/g)?.length).toBe(2)
    expect(source).not.toContain("provider !== 'claude' ||")
  })
})
