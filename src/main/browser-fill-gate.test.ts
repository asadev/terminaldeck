import { describe, expect, it } from 'vitest'
import { AGENT_HELD_MESSAGE, ISOLATED_MESSAGE, mayAutofill, stampDocument } from './browser-fill-gate'

/**
 * The rule standing between a saved password and an agent's transcript.
 *
 * Every case below is a sentence from the requirement rather than a branch from
 * the implementation, because this is one of the few files in this app where a
 * test that only covers what the code does is worth nothing.
 */
describe('a page an agent is driving is never filled by itself', () => {
  it('withholds while the debugger is attached', () => {
    const verdict = mayAutofill({ agentHolding: true, documentFromAgent: false, isolated: false })
    expect(verdict.fill).toBe(false)
    expect(verdict.fill === false && verdict.reason).toBe('agent')
  })

  it('withholds after the drive let go, if the drive is what put the page there', () => {
    /*
     * The seam this exists for. The guest preload looks for a sign-in form
     * three times — DOMContentLoaded, 700ms and 2200ms — so a drive that
     * navigated a page and then released inside that window would leave a page
     * the *agent* chose, with no debugger on it, about to be filled by the
     * third look.
     */
    const verdict = mayAutofill({ agentHolding: false, documentFromAgent: true, isolated: false })
    expect(verdict.fill).toBe(false)
    expect(verdict.fill === false && verdict.reason).toBe('agent')
  })

  it('says what happened and that the login is still available', () => {
    const verdict = mayAutofill({ agentHolding: true, documentFromAgent: false, isolated: false })
    // Not "blocked", not "refused". A sentence that only names a prohibition
    // reads as a fault in the store, and the next thing somebody does about a
    // fault is stop trusting the feature.
    expect(verdict.fill === false && verdict.message).toBe(AGENT_HELD_MESSAGE)
    expect(AGENT_HELD_MESSAGE).toMatch(/fill it yourself/i)
  })
})

describe('a page a person navigated to is filled, as it always was', () => {
  it('fills when nothing is driving and nothing drove', () => {
    // The ordinary case, and the one that must not acquire a click. Somebody
    // opening their own webmail is not a security event.
    expect(mayAutofill({ agentHolding: false, documentFromAgent: false, isolated: false })).toEqual({
      fill: true,
    })
  })
})

describe('an Isolated tab is a different sentence, not the same refusal', () => {
  it('names the reason it has no logins at all', () => {
    const verdict = mayAutofill({ agentHolding: false, documentFromAgent: false, isolated: true })
    expect(verdict.fill).toBe(false)
    expect(verdict.fill === false && verdict.reason).toBe('isolated')
    expect(verdict.fill === false && verdict.message).toBe(ISOLATED_MESSAGE)
  })

  it('wins over the agent reason, because it is the narrower fact', () => {
    // An isolated tab has no profile, so there is nothing to withhold. Saying
    // "an agent opened this page" there would send somebody looking for a
    // login that does not exist.
    const verdict = mayAutofill({ agentHolding: true, documentFromAgent: true, isolated: true })
    expect(verdict.fill === false && verdict.reason).toBe('isolated')
  })
})

describe('what a freshly committed document inherits', () => {
  it('is an agent document exactly when an agent was on the page', () => {
    expect(stampDocument(true)).toBe(true)
    expect(stampDocument(false)).toBe(false)
  })
})
