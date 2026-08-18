import { describe, expect, it } from 'vitest'
import { decodeServerMessage } from './protocol-client'
import { readCopilots, withCopilot, withoutCopilot, MAX_STORED_COPILOTS } from './copilot-store'

/**
 * What this client will and will not read off a copilot frame, and where it
 * keeps the credential.
 *
 * The decoder's refusals are not symmetric and the asymmetry is the whole
 * design: a frame that *is* one fact is refused whole when that fact is
 * incomplete, and a frame carrying a list drops the unreadable row and keeps the
 * rest. Both directions are asserted here, because the wrong one in either place
 * is a screen that lies — a consent prompt with no arguments, or a session list
 * that vanished because one row had a null title.
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

  it('refuses a `copilot.linked` with no credential in it', () => {
    // It is sent exactly once and the machine keeps only a hash. A frame
    // accepted without one would leave this browser believing it had connected
    // while holding nothing.
    expect(frame({ t: 'copilot.linked', link: LINK }).ok).toBe(false)
    expect(frame({ t: 'copilot.linked', credential: 'abc', link: LINK }).ok).toBe(true)
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
     * The cost of not reading it is exact: `linked` would be false on every
     * welcome, the Copilot screen would ask for a connect code on every reload,
     * and the code would work — producing a second record for a browser that
     * already had one.
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

  it('leaves it absent when the machine has no copilot layer', () => {
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
})

describe('where the credential is kept', () => {
  it('is keyed by machine, because a copilot connection is to one machine', () => {
    // A single stored string would be presented to whichever machine happened to
    // be current — refused, and counted against that machine's limiter.
    const held = withCopilot(withCopilot({}, 'machine-a', 'cred-a'), 'machine-b', 'cred-b')
    expect(held).toEqual({ 'machine-a': 'cred-a', 'machine-b': 'cred-b' })
    expect(withoutCopilot(held, 'machine-a')).toEqual({ 'machine-b': 'cred-b' })
  })

  it('drops the longest-held entry rather than growing without bound', () => {
    let held = {}
    for (let index = 0; index < MAX_STORED_COPILOTS + 2; index += 1) {
      held = withCopilot(held, `machine-${index}`, `cred-${index}`)
    }
    expect(Object.keys(held)).toHaveLength(MAX_STORED_COPILOTS)
    expect(Object.keys(held)).not.toContain('machine-0')
    expect(Object.keys(held)).toContain(`machine-${MAX_STORED_COPILOTS + 1}`)
  })

  it('reads a hand-edited store as empty rather than handing a machine rubbish', () => {
    const store = (value: string | null) => ({
      getItem: () => value,
      setItem: () => undefined,
      removeItem: () => undefined,
    })
    expect(readCopilots(store('not json'))).toBeNull()
    expect(readCopilots(store('[]'))).toBeNull()
    expect(readCopilots(store(JSON.stringify({ a: 'x'.repeat(5_000) })))).toBeNull()
    expect(readCopilots(store(JSON.stringify({ a: 'fine' })))).toEqual({ a: 'fine' })
  })
})
