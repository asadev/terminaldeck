import { describe, expect, it } from 'vitest'
import { asServerSignIn, setupChangedTheAnswer, signInLine } from './server-signin'

/**
 * The slot on the bar over a terminal on a server, and the rule it now obeys.
 *
 * Asad, about the same slot over a session on one of his own machines:
 *
 *   > *"It is saying default, so never default. Whatever is actual account
 *   > should be visible here, never default."*
 *
 * The server version of that failure was quieter and worse: it said **nothing**.
 * `servers:shell:account` answered `null` in four different situations — a
 * server nobody had opened, one that would not answer, one with no coding agent
 * on it, and one whose agents were all signed out — and the bar drew an empty
 * space for all four. Nothing is the one answer that is never true, and the four
 * lead somewhere different from each other.
 *
 * So there are four sentences and this is what pins them. They are composed
 * rather than drawn straight from the wire, which is why they are a pure
 * function in a file with no React in it: which sentence applies is the whole of
 * the decision.
 */

const HOST = 'hetzner-1'

describe('what the bar says about a server terminal’s coding logins', () => {
  it('names the agent and the address when there is one login', () => {
    const words = signInLine({ known: 'yes', agents: 1, logins: [{ agentId: 'claude', account: 'me@example.test' }] }, HOST)
    expect(words.line).toBe('Claude Code signs in as me@example.test')
    // The caveat that makes this different from every other account on this bar
    // is in the tooltip rather than on the line: this app did not start what is
    // running in that terminal.
    expect(words.title).toContain('did not start what is running in this terminal')
    expect(words.title).toContain(HOST)
  })

  it('names every login rather than picking one', () => {
    /*
     * The wire used to answer the first agent it found with an address on it, so
     * a server with a Claude login and a Codex login named one of them over a
     * terminal somebody runs the other in. Both are named.
     */
    const words = signInLine(
      {
        known: 'yes',
        agents: 3,
        logins: [
          { agentId: 'claude', account: 'me@example.test' },
          { agentId: 'codex', account: 'other@example.test' },
        ],
      },
      HOST,
    )
    expect(words.line).toContain('Claude Code signs in as me@example.test')
    expect(words.line).toContain('Codex CLI signs in as other@example.test')
  })

  it('says a login with no address is signed in, without inventing a name for it', () => {
    // Two of the three can be signed in with an API key, which has nobody's
    // address on it. "Signed in" is the whole of what is known.
    const words = signInLine({ known: 'yes', agents: 1, logins: [{ agentId: 'codex', account: null }] }, HOST)
    expect(words.line).toBe('Codex CLI is signed in')
    expect(words.line).not.toMatch(/as\b/)
  })

  it('says there is no login, rather than nothing, when agents are there and signed out', () => {
    const words = signInLine({ known: 'yes', agents: 2, logins: [] }, HOST)
    expect(words.line).toBe('No coding login here')
    // Precisely where to go, since this is the one of the four that has a next
    // step and the person is not looking at the screen that has it.
    expect(words.title).toContain('Settings → Coding AI → Servers')
  })

  it('says there is no agent, which is a different thing from no login', () => {
    const words = signInLine({ known: 'yes', agents: 0, logins: [] }, HOST)
    expect(words.line).toBe('No coding agent here')
    expect(words.title).toContain('Settings → Coding AI → Servers')
  })

  it('says the question could not be put, in the words of whatever refused it', () => {
    const words = signInLine({ known: 'cannot', why: 'That address did not answer.' }, HOST)
    expect(words.line).toBe('Coding logins unknown')
    expect(words.title).toContain('That address did not answer.')
  })

  it('falls back to a plain word for the server when the tab has no name for it', () => {
    const words = signInLine({ known: 'yes', agents: 0, logins: [] }, '')
    expect(words.title).toContain('this server')
  })
})

describe('reading the answer off the bridge', () => {
  it('reads a list of logins', () => {
    expect(
      asServerSignIn({ known: 'yes', agents: 2, logins: [{ agentId: 'codex', account: 'a@b.test' }] }),
    ).toEqual({ known: 'yes', agents: 2, logins: [{ agentId: 'codex', account: 'a@b.test' }] })
  })

  it('reads an empty address as no address rather than as an address of nothing', () => {
    const read = asServerSignIn({ known: 'yes', agents: 1, logins: [{ agentId: 'gemini', account: '' }] })
    expect(read).toEqual({ known: 'yes', agents: 1, logins: [{ agentId: 'gemini', account: null }] })
  })

  it('never reports fewer agents than logins, whatever the far end said', () => {
    // A far end that miscounted would otherwise produce "no coding agent here"
    // on a bar that is about to list two of them.
    const read = asServerSignIn({ known: 'yes', agents: 0, logins: [{ agentId: 'claude', account: null }] })
    expect(read).toEqual({ known: 'yes', agents: 1, logins: [{ agentId: 'claude', account: null }] })
  })

  it('keeps the refusal’s own sentence', () => {
    expect(asServerSignIn({ known: 'cannot', why: 'No terminal was named.' })).toEqual({
      known: 'cannot',
      why: 'No terminal was named.',
    })
  })

  it('answers null for a build whose far end does not know this shape', () => {
    // Null draws nothing, which is right for exactly one situation: the answer
    // has not arrived. Everything else has a sentence.
    expect(asServerSignIn(null)).toBeNull()
    expect(asServerSignIn({ agentId: 'claude', account: 'a@b.test' })).toBeNull()
  })
})

describe('when the bar asks again', () => {
  it('asks again after a sign-in finishes and after an install is taken back off', () => {
    expect(setupChangedTheAnswer({ step: 'done' })).toBe(true)
    expect(setupChangedTheAnswer({ step: 'idle' })).toBe(true)
  })

  it('does not ask again on progress, which would be a round trip per line of output', () => {
    for (const step of ['installing', 'installed', 'signing-in', 'failed']) {
      expect(setupChangedTheAnswer({ step })).toBe(false)
    }
    expect(setupChangedTheAnswer('done')).toBe(false)
  })
})
