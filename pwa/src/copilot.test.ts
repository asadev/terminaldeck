import { describe, expect, it } from 'vitest'
import {
  NO_COPILOT,
  NO_GRANT,
  copilotOffered,
  copilotStep,
  grantSentence,
  mergeChat,
  settledSentence,
  type CopilotState,
} from './copilot'
import type { CopilotGrantWire, CopilotLinkWire, ServerMessage } from './protocol-client'

/**
 * The rules of a copilot connection, pinned where a browser cannot be looked at.
 *
 * Everything here is a rule that is invisible in a diff and obvious on a screen,
 * which is the standing reason this client's logic lives outside `main.ts` at
 * all: there is no DOM under vitest, so a decision written inside a `render` is
 * a decision verified only by somebody remembering to take a screenshot.
 *
 * Four of these guard failures the design documents name by name — a client that
 * believes a `welcome` means it is already connected, a watching device drawing
 * an Allow button, a control offered for a frame that would be refused, and an
 * answer that is not the same with the driving turned off.
 */

const GRANT = (over: Partial<CopilotGrantWire> = {}): CopilotGrantWire => ({ ...NO_GRANT, ...over })
const LINK = (over: Partial<CopilotLinkWire> = {}): CopilotLinkWire => ({
  linked: true,
  open: true,
  grant: GRANT({ read: true, act: true, alter: true }),
  ...over,
})

/** A state as it is after a welcome and a hello, unless told otherwise. */
function connected(over: Partial<CopilotState> = {}): CopilotState {
  return { ...NO_COPILOT, offered: true, link: LINK(), ...over }
}

describe('whether there is a copilot here at all', () => {
  it('is the capability and nothing else', () => {
    expect(copilotOffered(['create', 'copilot'])).toBe(true)
    expect(copilotOffered(['create', 'localhost'])).toBe(false)
  })

  it('takes everything away when a machine stops offering one', () => {
    /*
     * A guest is never told the machine has a copilot, and neither is a browser
     * switched to a second machine that has none. Anything held from the last
     * one is a statement about a different computer.
     */
    const held = connected({ chat: [{ id: 'm1', role: 'agent', text: 'hello', at: 1 }] })
    const step = copilotStep(held, { t: 'welcome', capabilities: ['create'], link: null, credential: 'c' })
    expect(step.state.offered).toBe(false)
    expect(step.state.link.linked).toBe(false)
    expect(step.state.chat).toEqual([])
    expect(step.send).toEqual([])
  })
})

describe('the separate connection', () => {
  it('sends a hello on every welcome, carrying the stored credential', () => {
    const step = copilotStep(NO_COPILOT, {
      t: 'welcome',
      capabilities: ['copilot'],
      link: LINK({ open: false }),
      credential: 'stored-credential',
    })
    expect(step.send).toEqual([{ t: 'copilot.hello', credential: 'stored-credential' }])
  })

  it('never believes a welcome that claims the connection is already open', () => {
    /*
     * `welcome.copilot.open` is always false on the wire and the protocol says a
     * client that treats it as "already in" sends frames that are all refused.
     * Forced rather than trusted, because a client whose correctness depends on
     * the far end never having a bug is not correct.
     */
    const step = copilotStep(NO_COPILOT, {
      t: 'welcome',
      capabilities: ['copilot'],
      link: LINK({ open: true }),
      credential: null,
    })
    expect(step.state.link.open).toBe(false)
  })

  it('asks for a code rather than a hello when nothing is stored', () => {
    const step = copilotStep(NO_COPILOT, {
      t: 'welcome',
      capabilities: ['copilot'],
      link: LINK({ linked: false, open: false, grant: NO_GRANT }),
      credential: null,
    })
    expect(step.send).toEqual([])
    expect(step.state.link.linked).toBe(false)
  })

  it('hands a new credential out to be stored, and starts watching', () => {
    const linked: ServerMessage = { t: 'copilot.linked', credential: 'fresh', link: LINK() }
    const step = copilotStep(
      { ...NO_COPILOT, offered: true, connecting: true },
      { t: 'frame', message: linked },
    )
    expect(step.credential).toBe('fresh')
    expect(step.state.connecting).toBe(false)
    expect(step.send.map((frame) => frame.t)).toEqual([
      'copilot.attach',
      'copilot.state',
      'copilot.sessions',
      'copilot.pending',
    ])
  })

  it('drops the conversation when the machine closes the connection', () => {
    // A disconnect at the machine. Leaving the bubbles up would be a screen
    // showing a copilot this browser can no longer reach.
    const held = connected({ chat: [{ id: 'm1', role: 'agent', text: 'hi', at: 1 }], run: 'r1' })
    const closed: ServerMessage = { t: 'copilot.grant', link: LINK({ open: false, grant: NO_GRANT }) }
    const step = copilotStep(held, { t: 'frame', message: closed })
    expect(step.state.chat).toEqual([])
    expect(step.state.run).toBeNull()
  })

  it('keeps `linked` when the socket drops, and closes the connection', () => {
    const step = copilotStep(connected(), { t: 'offline' })
    expect(step.state.link.linked).toBe(true)
    expect(step.state.link.open).toBe(false)
  })
})

describe('a control is never offered for a frame that would be refused', () => {
  it('sends nothing at all without an open connection', () => {
    const closed = connected({ link: LINK({ open: false }) })
    for (const action of [{ t: 'start' }, { t: 'say', text: 'hi' }, { t: 'stop' }, { t: 'attach' }] as const) {
      expect(copilotStep(closed, action).send, `${action.t} on a closed connection`).toEqual([])
    }
  })

  it('refuses to talk on a watching grant', () => {
    const watching = connected({ link: LINK({ grant: GRANT({ read: true }) }) })
    expect(copilotStep(watching, { t: 'say', text: 'hello' }).send).toEqual([])
    expect(copilotStep(watching, { t: 'start' }).send).toEqual([])
    // And says so, rather than leaving a gap where a composer was.
    expect(grantSentence(watching.link.grant)).toContain('watch')
  })

  it('asks for nothing on an act-only grant', () => {
    // Legal, if unusual. Four read frames that would each be refused is four
    // refusals on a screen that has just been told it is connected.
    const acting = connected({ link: LINK({ grant: GRANT({ act: true }) }) })
    expect(copilotStep(acting, { t: 'attach' }).send).toEqual([])
  })

  it('will not answer a confirmation without `alter`', () => {
    const question = {
      id: 'q1',
      tool: 'settings.write',
      tier: 'alter',
      summary: 'Set the default agent',
      args: { key: 'defaultProvider' },
      origin: 'device:abc',
      requestedAt: 1,
      expiresAt: 2,
    }
    const watching = connected({ link: LINK({ grant: GRANT({ read: true, act: true }) }), ask: question })
    expect(copilotStep(watching, { t: 'answer', id: 'q1', approved: true }).send).toEqual([])
    // With the tier, it goes — and the sheet closes on the send rather than on
    // the round trip, because first answer wins and a second press would be a
    // decision about a question that is already closed.
    const allowed = connected({ ask: question })
    const step = copilotStep(allowed, { t: 'answer', id: 'q1', approved: false })
    expect(step.send).toEqual([{ t: 'copilot.answer', id: 'q1', approved: false }])
    expect(step.state.ask).toBeNull()
  })

  it('will not answer a question it is not holding', () => {
    expect(copilotStep(connected(), { t: 'answer', id: 'q9', approved: true }).send).toEqual([])
  })
})

describe('the message box', () => {
  it('refuses a message the machine would close the socket over', () => {
    // Refused here and **not chunked**: a paste into a terminal is a stream and
    // half of one is still half a paste, whereas half a sentence to an agent is
    // a different sentence.
    const huge = 'x'.repeat(200_000)
    const step = copilotStep(connected(), { t: 'say', text: huge })
    expect(step.send).toEqual([])
    expect(step.state.notice).toContain('too long')
  })

  it('unlocks when the person’s own words come back, not when the agent answers', () => {
    const sent = copilotStep(connected(), { t: 'say', text: 'what is running' })
    expect(sent.state.sending).toBe(true)
    const echo: ServerMessage = {
      t: 'copilot.chat',
      run: 'r1',
      messages: [{ id: 'm1', role: 'you', text: 'what is running', at: 1 }],
    }
    expect(copilotStep(sent.state, { t: 'frame', message: echo }).state.sending).toBe(false)
  })

  it('sends nothing for an empty message', () => {
    expect(copilotStep(connected(), { t: 'say', text: '   ' }).send).toEqual([])
  })
})

describe('the conversation', () => {
  it('replaces a growing message rather than stacking it', () => {
    const held = [{ id: 'm1', role: 'agent' as const, text: 'Loo', at: 1 }]
    expect(mergeChat(held, [{ id: 'm1', role: 'agent', text: 'Looking…', at: 1 }])).toEqual([
      { id: 'm1', role: 'agent', text: 'Looking…', at: 1 },
    ])
  })

  it('drops a frame from a run it is not holding', () => {
    /*
     * Without this a browser that reconnected after the grace window expired
     * would splice the end of a dead conversation onto the start of a live one,
     * and the person would read an answer to a question they never asked.
     */
    const held = connected({ run: 'r1', chat: [{ id: 'm1', role: 'agent', text: 'old', at: 1 }] })
    const fromNewRun: ServerMessage = {
      t: 'copilot.chat',
      run: 'r2',
      messages: [{ id: 'm9', role: 'agent', text: 'new', at: 2 }],
    }
    const step = copilotStep(held, { t: 'frame', message: fromNewRun })
    expect(step.state.chat).toEqual([{ id: 'm9', role: 'agent', text: 'new', at: 2 }])
    expect(step.state.run).toBe('r2')
  })
})

describe('a dialog never vanishes without saying where it went', () => {
  it('names the surface that answered', () => {
    expect(settledSentence({ granted: true, by: 'window', reason: null })).toBe('Allowed at the machine.')
    expect(settledSentence({ granted: false, by: 'device:x', reason: 'not-granted' })).toBe(
      'Refused on another of your devices — not-granted.',
    )
  })

  it('says a timeout was a refusal rather than a disappearance', () => {
    expect(settledSentence({ granted: false, by: null, reason: null })).toContain('refused')
  })

  it('withdraws the sheet with a sentence when somebody else got there first', () => {
    const question = {
      id: 'q1',
      tool: 'settings.write',
      tier: 'alter',
      summary: 'Set the default agent',
      args: {},
      origin: 'window',
      requestedAt: 1,
      expiresAt: 2,
    }
    const settled: ServerMessage = {
      t: 'copilot.settled',
      settled: { id: 'q1', granted: true, by: 'window', reason: null },
    }
    const step = copilotStep(connected({ ask: question }), { t: 'frame', message: settled })
    expect(step.state.ask).toBeNull()
    expect(step.state.notice).toBe('Allowed at the machine.')
  })
})
