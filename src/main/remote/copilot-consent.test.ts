import { describe, expect, it } from 'vitest'
import type { ConsentRequest } from '../deck-control/consent'
import { toConsentQuestion, toPendingRow } from './copilot-consent'

/**
 * The two shapes a confirmation crosses a sealed channel as, and the one
 * difference between them that matters.
 *
 * A pending row goes to every device watching the copilot and says *something
 * needs attention*. A question goes only to the device that raised it and says
 * *decide*. The arguments are the difference, in both directions:
 *
 *  - **A watcher must not get them.** They are the most sensitive thing on this
 *    surface — a settings key and its new value, a session id and the text about
 *    to be typed into it — and a device that cannot answer has no decision to
 *    make with them.
 *  - **An answerer must.** A consent prompt without enough context becomes a
 *    reflex Yes, and a gate that is always answered yes is worse than no gate at
 *    all because it looks like protection. Withholding the arguments from the
 *    person being asked to judge would produce exactly that.
 *
 * Both assertions are written against the serialised frame rather than against
 * the object, because what is being pinned is what leaves this machine.
 */

function request(over: Partial<ConsentRequest> = {}): ConsentRequest {
  return {
    id: 'ask-1',
    tool: 'settings.write',
    tier: 'alter',
    summary: 'Change the default agent to Codex',
    args: { scope: 'preferences', patch: { defaultProvider: 'codex' } },
    requestedAt: 1_000,
    expiresAt: 121_000,
    origin: 'device:phone-1',
    ...over,
  }
}

describe('a confirmation a device may only watch', () => {
  it('carries the summary and the countdown, and not the arguments', () => {
    const wire = toPendingRow(request(), false)
    expect(wire).toEqual({
      id: 'ask-1',
      tool: 'settings.write',
      summary: 'Change the default agent to Codex',
      requestedAt: 1_000,
      expiresAt: 121_000,
      mine: false,
    })
    // The value that would have been written, nowhere in the frame.
    expect(JSON.stringify(wire)).not.toContain('codex')
    // The expiry travels so the device counts down exactly as the desktop dialog
    // does. Two minutes is not extended for a phone: a longer window is how an
    // approval arrives six minutes later from somebody who has forgotten what
    // they were approving.
    expect(wire.expiresAt - wire.requestedAt).toBe(120_000)
  })

  /**
   * `origin` never crosses on a watch row.
   *
   * *Which other device asked for this* is not a watching device's business, and
   * an opaque id would only invite a client to display one. What a watcher needs
   * is the summary and the countdown, so it can say *go and look*.
   */
  it('does not say which device raised it', () => {
    expect(JSON.stringify(toPendingRow(request(), false))).not.toContain('phone-1')
  })

  /**
   * `mine` is passed in, never derived.
   *
   * It is computed on the desktop from the question's own origin, and this
   * function is not given the means to guess: with `origin` absent from the row
   * there is nothing a client or a caller could reconstruct it from. A client
   * that drew an Allow button on somebody else's question would be offering a
   * control that is always refused — the defect this repository has paid for
   * twice.
   */
  it('says whether this device may answer, as it was told', () => {
    expect(toPendingRow(request(), true).mine).toBe(true)
    expect(toPendingRow(request(), false).mine).toBe(false)
  })
})

describe('a confirmation a device may answer', () => {
  it('carries every argument, verbatim, so the decision is a real one', () => {
    const wire = toConsentQuestion(request())
    expect(wire.args).toEqual({ scope: 'preferences', patch: { defaultProvider: 'codex' } })
    // The whole point: the value that will actually be written is on screen.
    expect(JSON.stringify(wire)).toContain('codex')
  })

  /**
   * The sentence is the desktop's, and it crosses unchanged.
   *
   * Composed by the tool that is about to run, on this machine, by the code that
   * knows what it will do. A client that wrote its own would be describing an
   * action it did not implement, and the first time the two drifted somebody
   * would approve one thing having read another.
   */
  it('forwards the desktop’s own summary rather than a shape to re-compose', () => {
    expect(toConsentQuestion(request()).summary).toBe('Change the default agent to Codex')
  })

  it('says which run raised it, and at what tier', () => {
    expect(toConsentQuestion(request()).origin).toBe('device:phone-1')
    expect(toConsentQuestion(request({ origin: 'window' })).origin).toBe('window')
    expect(toConsentQuestion(request()).tier).toBe('alter')
  })

  it('carries the same deadline the watch row does', () => {
    const q = toConsentQuestion(request())
    expect(q.expiresAt - q.requestedAt).toBe(120_000)
  })
})
