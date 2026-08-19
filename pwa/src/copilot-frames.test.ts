import { describe, expect, it } from 'vitest'
import { decodeServerMessage } from './protocol-client'

/**
 * What this client will and will not read off a copilot frame.
 *
 * The decoder's refusals are not symmetric and the asymmetry is the whole
 * design: a frame that *is* one fact is refused whole when that fact is
 * incomplete, and a frame carrying a list drops the unreadable row and keeps the
 * rest. Both directions are asserted here, because the wrong one in either place
 * is a screen that lies — a consent prompt with no arguments, or a session list
 * that vanished because one row had a null title.
 *
 * There used to be a third section, about where a copilot credential was kept in
 * this browser. It is gone with the credential: pairing a device as one of his
 * own is now the whole of the copilot's authorisation, so there is no second
 * secret and no store to hold one.
 */

const frame = (value: unknown) => decodeServerMessage(JSON.stringify(value))

const GRANT = { read: true, act: true, alter: false }
const LINK = { linked: true, open: true, grant: GRANT }

describe('a frame that is one fact is refused whole', () => {
  it('refuses a consent question with no arguments', () => {
    /*
     * `args` is what turns a prompt from a shape into a decision. A gate that is
     * always answered yes because there was nothing to read is worse than no
     * gate at all, because it looks like protection.
     */
    const result = frame({
      t: 'copilot.ask',
      question: { id: 'q1', tool: 'settings.write', tier: 'alter', summary: 'Change a setting', origin: 'window' },
    })
    expect(result.ok).toBe(false)
  })

  it('reads a whole consent question, arguments verbatim', () => {
    const result = frame({
      t: 'copilot.ask',
      question: {
        id: 'q1',
        tool: 'settings.write',
        tier: 'alter',
        summary: 'Set the default agent',
        args: { key: 'defaultProvider', value: 'codex' },
        origin: 'device:abc',
        requestedAt: 10,
        expiresAt: 20,
      },
    })
    expect(result.ok).toBe(true)
    if (!result.ok) return
    expect(result.message).toEqual({
      t: 'copilot.ask',
      question: {
        id: 'q1',
        tool: 'settings.write',
        tier: 'alter',
        summary: 'Set the default agent',
        args: { key: 'defaultProvider', value: 'codex' },
        origin: 'device:abc',
        requestedAt: 10,
        expiresAt: 20,
      },
    })
  })

  it('refuses a partial grant rather than reading it as "no access"', () => {
    // `CopilotGrantWire` promises one shape so that "no access" has one
    // spelling. A grant read as `{read: true}` with the rest missing would draw
    // a watching surface for a device that may have been given everything.
    expect(frame({ t: 'copilot.grant', link: { linked: true, open: true, grant: { read: true } } }).ok).toBe(false)
    expect(frame({ t: 'copilot.grant', link: LINK }).ok).toBe(true)
  })

  it('refuses a state report whose desk word it does not know', () => {
    // Read as `stopped` it would say the copilot is not running, which is the
    // one claim on that screen somebody acts on by pressing Start.
    expect(frame({ t: 'copilot.state', state: { desk: 'napping', grant: GRANT } }).ok).toBe(false)
  })

  it('folds an unasked `signedIn` onto null rather than onto false', () => {
    const result = frame({ t: 'copilot.state', state: { desk: 'running', grant: GRANT } })
    expect(result.ok).toBe(true)
    if (!result.ok || result.message.t !== 'copilot.state') return
    expect(result.message.state.signedIn).toBeNull()
    // And `available` is false unless it was said, because a Start button that
    // cannot act is the defect this whole review is built on.
    expect(result.message.state.available).toBe(false)
  })
})

describe('a frame carrying a list keeps the rows it can read', () => {
  it('drops one bad chat bubble and keeps the others', () => {
    const result = frame({
      t: 'copilot.chat',
      run: 'r1',
      messages: [
        { id: 'm1', role: 'agent', text: 'one', at: 1 },
        { id: '', role: 'agent', text: 'no id', at: 2 },
        { id: 'm3', role: 'you', text: 'three', at: 3 },
      ],
    })
    expect(result.ok).toBe(true)
    if (!result.ok || result.message.t !== 'copilot.chat') return
    expect(result.message.messages.map((row) => row.id)).toEqual(['m1', 'm3'])
  })

  it('refuses a chat frame with no run, because a run is what makes it mergeable', () => {
    expect(frame({ t: 'copilot.chat', messages: [] }).ok).toBe(false)
  })

  it('drops a tool row whose outcome this build has never heard of', () => {
    /*
     * `outcome: 'refused'` is how somebody finds out a gate held. A fourth
     * outcome added on the machine must produce a *missing* row here, never one
     * that says the call succeeded.
     */
    const result = frame({
      t: 'copilot.tool',
      row: { id: 'a1', tool: 'settings.write', tier: 'alter', outcome: 'deferred', detail: 'x' },
    })
    expect(result.ok).toBe(false)
  })

  it('never marks somebody else’s question as answerable', () => {
    // A client that drew an Allow on a question it may not answer would be
    // offering a control that is always refused.
    const result = frame({
      t: 'copilot.pending',
      questions: [{ id: 'q1', tool: 'settings.write', summary: 'x', requestedAt: 1, expiresAt: 2 }],
    })
    expect(result.ok).toBe(true)
    if (!result.ok || result.message.t !== 'copilot.pending') return
    expect(result.message.questions[0].mine).toBe(false)
  })
})

describe('the copilot link riding on a welcome', () => {
  it('is read, even though the shared parser drops it', () => {
    /*
     * Its presence is now the whole of whether this client draws a Copilot tab,
     * so the cost of not reading it is total rather than cosmetic: a machine
     * with a copilot and a device entitled to it, drawn as though neither
     * existed.
     */
    const result = frame({
      t: 'welcome',
      protocol: 1,
      deviceId: 'd1',
      deviceName: 'This browser',
      token: null,
      sessions: [],
      capabilities: ['copilot'],
      copilot: LINK,
    })
    expect(result.ok).toBe(true)
    if (!result.ok || result.message.t !== 'welcome') return
    // Open forced false whatever arrived: a session channel does not carry the
    // copilot by existing.
    expect(result.message.copilot).toEqual({ linked: true, open: false, grant: GRANT })
  })

  it('leaves it absent for a guest, or for a machine with no copilot layer', () => {
    const result = frame({
      t: 'welcome',
      protocol: 1,
      deviceId: 'd1',
      deviceName: 'This browser',
      token: null,
      sessions: [],
      capabilities: [],
    })
    expect(result.ok).toBe(true)
    if (!result.ok || result.message.t !== 'welcome') return
    expect(result.message.copilot).toBeUndefined()
  })
})

describe('a copilot frame this client did not ask for', () => {
  it('is refused with a sentence of its own, not as an unknown type', () => {
    // `copilot.log` answers a verb this client never sends, so reading it would
    // be a parser for a conversation it is not in.
    const result = frame({ t: 'copilot.log', rows: [], more: false })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.reason).toContain('did not ask for')
  })

  it('refuses a `copilot.linked`, because there is nowhere for a credential to go', () => {
    /*
     * It answered `copilot.connect` and carried the credential that frame
     * minted, and both were deleted on 2026-08-19. Reading it now would be a
     * decoder standing ready to accept a secret this client has nothing to do
     * with — the one shape of dead code worth a test of its own.
     */
    const result = frame({ t: 'copilot.linked', credential: 'abc', link: LINK })
    expect(result.ok).toBe(false)
    if (result.ok) return
    expect(result.reason).toContain('did not ask for')
  })
})
