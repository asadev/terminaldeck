import { describe, expect, it } from 'vitest'
import {
  NO_COPILOT,
  NO_GRANT,
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
 * Five of these guard failures the design documents name by name — a client that
 * believes a `welcome` means it is already connected, one that asks a guest's
 * machine for a copilot, a watching device drawing an Allow button, a control
 * offered for a frame that would be refused, and an answer that is not the same
 * with the driving turned off.
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
  it('is the welcome carrying one, and nothing else', () => {
    /*
     * > *"if we are connecting as my device copilot automatically comes, if we
     * > connect as guest then copilot don't come"*
     *
     * The machine filters `welcome.copilot` by the device's kind, so its
     * presence is the per-device answer and the client asks nothing else. A
     * second signal — the `copilot` capability, which is still advertised — would
     * be a second answer that can differ from this one, and the difference would
     * land as a tab drawn for a guest or withheld from one of his own devices.
     */
    expect(copilotStep(NO_COPILOT, { t: 'welcome', link: LINK({ open: false }) }).state.offered).toBe(true)
    expect(copilotStep(NO_COPILOT, { t: 'welcome', link: null }).state.offered).toBe(false)
  })

  it('asks a machine that offered nothing for nothing', () => {
    // The guest case, and the only thing that makes it safe: no frame goes out
    // at all. A client that said hello anyway would be counting refusals against
    // a machine that had already declined to mention the feature.
    expect(copilotStep(NO_COPILOT, { t: 'welcome', link: null }).send).toEqual([])
  })

  it('takes everything away when a welcome stops carrying one', () => {
    /*
     * A device re-paired as a guest, or a browser switched to a second machine
     * that has no copilot. Anything held from the last one is a statement about
     * a different computer.
     */
    const held = connected({ chat: [{ id: 'm1', role: 'agent', text: 'hello', at: 1 }] })
    const step = copilotStep(held, { t: 'welcome', link: null })
    expect(step.state.offered).toBe(false)
    expect(step.state.link.linked).toBe(false)
    expect(step.state.chat).toEqual([])
    expect(step.send).toEqual([])
  })
})

describe('opening it on a socket', () => {
  it('sends a hello that carries nothing at all', () => {
    /*
     * The frame that used to prove a second secret. There is no copilot code and
     * no copilot credential any more: the socket is already authenticated as
     * this device, and the machine reads the kind a person chose when they
     * approved it. A `credential` key here would be a secret this browser does
     * not have and must not invent.
     */
    const step = copilotStep(NO_COPILOT, { t: 'welcome', link: LINK({ open: false }) })
    expect(step.send).toEqual([{ t: 'copilot.hello' }])
    expect(step.state.opening).toBe(true)
  })

  it('never believes a welcome that claims the connection is already open', () => {
    /*
     * `welcome.copilot.open` is always false on the wire and the protocol says a
     * client that treats it as "already in" sends frames that are all refused.
     * Forced rather than trusted, because a client whose correctness depends on
     * the far end never having a bug is not correct.
     */
    const step = copilotStep(NO_COPILOT, { t: 'welcome', link: LINK({ open: true }) })
    expect(step.state.link.open).toBe(false)
  })

  it('starts watching when the grant that answers the hello arrives', () => {
    const opening: CopilotState = { ...NO_COPILOT, offered: true, opening: true, link: LINK({ open: false }) }
    const step = copilotStep(opening, { t: 'frame', message: { t: 'copilot.grant', link: LINK() } })
    expect(step.state.opening).toBe(false)
    expect(step.state.link.open).toBe(true)
    expect(step.send.map((frame) => frame.t)).toEqual([
      'copilot.attach',
      'copilot.state',
      'copilot.sessions',
      'copilot.pending',
    ])
  })

  it('puts a machine that refuses the hello on screen in its own words', () => {
    /*
     * `app.terminaldeck.dev` deploys on its own, so a new client will meet a
     * desktop old enough to still want a credential. Swallowed, the tab would
     * sit at "Asking the machine…" forever with nothing to read.
     */
    const opening: CopilotState = { ...NO_COPILOT, offered: true, opening: true, link: LINK({ open: false }) }
    const refused: ServerMessage = { t: 'error', code: 'bad-message', message: 'copilot.hello without a credential' }
    const step = copilotStep(opening, { t: 'frame', message: refused })
    expect(step.state.opening).toBe(false)
    expect(step.state.notice).toBe('copilot.hello without a credential')
  })

  it('drops the conversation when the machine closes the connection', () => {
    // This device revoked at the machine. Leaving the bubbles up would be a
    // screen showing a copilot this browser can no longer reach.
    const held = connected({ chat: [{ id: 'm1', role: 'agent', text: 'hi', at: 1 }], run: 'r1' })
    const closed: ServerMessage = { t: 'copilot.grant', link: LINK({ open: false, grant: NO_GRANT }) }
    const step = copilotStep(held, { t: 'frame', message: closed })
    expect(step.state.chat).toEqual([])
    expect(step.state.run).toBeNull()
  })

  it('closes the connection when the socket drops and keeps the entitlement', () => {
    // Nothing has to be re-established by a person: the next welcome carries the
    // copilot again, because being paired to that machine as his own is what
    // entitles this browser to it.
    const step = copilotStep(connected(), { t: 'offline' })
    expect(step.state.offered).toBe(true)
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

/* ------------------------------------------------------------ say timeout -- */

describe('a message that is never acknowledged', () => {
  /*
   * The regression: a phone sent four messages to a live run, none of them ever
   * echoed, and the composer stayed disabled through all four and a reload.
   * `sending` had exactly one way out and the wire is not obliged to provide it.
   */
  const linked: CopilotLinkWire = {
    linked: true,
    open: true,
    grant: { read: true, act: true, alter: true },
  }

  function sent(): CopilotState {
    const open = copilotStep(NO_COPILOT, { t: 'welcome', link: linked }).state
    const granted = copilotStep(open, {
      t: 'frame',
      message: { t: 'copilot.grant', link: linked },
    }).state
    return copilotStep(granted, { t: 'say', text: 'hello' }).state
  }

  it('locks the composer when the message goes out', () => {
    expect(sent().sending).toBe(true)
  })

  it('unlocks it on the timeout and asks the machine what it has', () => {
    const step = copilotStep(sent(), { t: 'say-timeout' })
    expect(step.state.sending).toBe(false)
    expect(step.state.notice).toBe('The copilot did not answer.')
    // The re-ask is what makes a run that died show Start instead of a dead
    // Send: nothing on the desktop reaps a run until something reads its state.
    expect(step.send).toEqual([{ t: 'copilot.state' }])
  })

  it('does nothing when no message is in flight', () => {
    const idle = copilotStep(NO_COPILOT, { t: 'welcome', link: linked }).state
    const step = copilotStep(idle, { t: 'say-timeout' })
    expect(step.state).toBe(idle)
    expect(step.send).toEqual([])
  })

  it('still unlocks when the link has gone read-less, and asks nothing', () => {
    const state: CopilotState = { ...sent(), link: { ...linked, grant: { read: false, act: true, alter: false } } }
    const step = copilotStep(state, { t: 'say-timeout' })
    expect(step.state.sending).toBe(false)
    expect(step.send).toEqual([])
  })
})
