import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { AgentRow, OneTimeCode } from './ServerSetup'
import type { SetupRow, SetupState } from './types'

/**
 * The two things a person does with their hands during a sign-in on a server,
 * and what this pane now does with each of them.
 *
 * `renderToStaticMarkup` runs no effects and has no clipboard, which is not a
 * limitation here — it is one of the two states worth pinning. See the second
 * test.
 */

function state(over: Partial<SetupState> = {}): SetupState {
  return {
    serverId: 's1',
    agentId: 'codex',
    step: 'signing-in',
    line: 'Codex CLI is waiting for this code.',
    detail: '',
    byHand: false,
    code: '',
    weInstalled: false,
    version: null,
    ...over,
  }
}

function row(over: Partial<SetupRow> = {}): SetupRow {
  return {
    agentId: 'codex',
    label: 'Codex CLI',
    installed: { id: 'codex', path: '/usr/bin/codex', version: '0.149.0', signedIn: 'no', account: null },
    canInstall: true,
    why: null,
    consequence: 'This installs it.',
    signOutConsequence: 'This asks it to forget its login.',
    whyNoSignOut: null,
    state: state(),
    ...over,
  }
}

function drawRow(
  over: {
    state?: SetupState
    row?: SetupRow
    busy?: boolean
    asking?: 'install' | 'sign-out'
    canSignOut?: boolean
  } = {},
): string {
  return renderToStaticMarkup(
    <AgentRow
      row={over.row ?? row()}
      state={over.state ?? state()}
      busy={over.busy ?? true}
      mine
      asking={over.asking ?? null}
      canSignOut={over.canSignOut ?? true}
      onAsk={() => {}}
      onCancelAsk={() => {}}
      onInstall={() => {}}
      onSignIn={() => {}}
      onSignOut={() => {}}
      onRemove={() => {}}
      onStop={() => {}}
    />,
  )
}

describe('the one-time code a device sign-in is waiting for', () => {
  it('draws the code itself, which is what a person was retyping out of a terminal', () => {
    const html = renderToStaticMarkup(<OneTimeCode code="519G-KS0UC" />)
    expect(html).toContain('519G-KS0UC')
  })

  it('spells it out for a screen reader rather than letting it be read as a word', () => {
    // Read aloud, `519G-KS0UC` is a noise. A code nobody can transcribe is a
    // code that has not been given to them.
    const html = renderToStaticMarkup(<OneTimeCode code="519G-KS0UC" />)
    expect(html).toContain('aria-label="5 1 9 G - K S 0 U C"')
  })

  it('offers no Copy where there is no clipboard to copy with', () => {
    /*
     * `navigator.clipboard` is absent in an insecure context and in this
     * renderer, and a Copy that silently does nothing is the control this app
     * has been caught drawing before. The code is still on screen and still
     * selectable, which is the honest smaller version of the same help.
     */
    const html = renderToStaticMarkup(<OneTimeCode code="519G-KS0UC" />)
    expect(html).not.toContain('Copy')
  })
})

describe('the button beside a sign-in that is still running', () => {
  it('says Stop on a route this app can watch to the end', () => {
    // The device-code route: the login command exits when the code is accepted
    // and the flow sees it exit, so the only thing a press can mean is stopping.
    expect(drawRow()).toContain('Stop')
  })

  it('says I’m done on the two routes where only the person knows it finished', () => {
    /*
     * A sign-in that finishes at a prompt, or inside the agent's own full-screen
     * interface, tells this side nothing at all — so the row sat on *"signing
     * in…"* for ever and the only control on it offered to abandon the thing
     * that had already worked. The press now reads the server again.
     */
    const html = drawRow({ state: state({ byHand: true }) })
    expect(html).toContain('I’m done')
    expect(html).not.toContain('>Stop<')
  })
})

describe('the sign-out this pane used to say was impossible', () => {
  const signedIn = row({
    installed: { id: 'codex', path: '/usr/bin/codex', version: '0.149.0', signedIn: 'yes', account: 'a@b.test' },
    state: state({ step: 'idle', line: '' }),
  })

  it('offers it on a row that has a login to let go of', () => {
    const html = drawRow({ row: signedIn, busy: false, state: state({ step: 'idle', line: '' }) })
    expect(html).toContain('Sign out')
  })

  it('offers nothing where the agent has no command for it, and says why instead', () => {
    /*
     * Gemini CLI has no `logout`. §4.1 — *"a control that cannot act is removed,
     * or disabled with a stated reason. Never drawn hopefully."* — so the row
     * keeps the reason and loses the button, which is the same shape the install
     * side already uses for a server that cannot take an agent.
     */
    const html = drawRow({
      row: { ...signedIn, whyNoSignOut: 'Gemini CLI has no way to be signed out from outside its own screen.' },
      busy: false,
      canSignOut: false,
      state: state({ step: 'idle', line: '' }),
    })
    expect(html).toContain('has no way to be signed out')
    expect(html).not.toContain('>Sign out<')
  })

  it('keeps the consequence behind the first press, the way the install does', () => {
    const idle = { row: signedIn, busy: false, state: state({ step: 'idle', line: '' }) }
    // Nothing said until somebody asks for it…
    expect(drawRow(idle)).not.toContain('This asks it to forget its login.')
    // …and then the sentence, written on the other side beside the work.
    expect(drawRow({ ...idle, asking: 'sign-out' })).toContain('This asks it to forget its login.')
  })
})

describe('a build whose preload predates a channel', () => {
  it('draws no Sign out at all, rather than one that opens a terminal and does nothing', () => {
    /*
     * The two conditions are separate facts and both have to hold: this build
     * has to carry the channel, and that agent has to have a command. The panel
     * decides the first and the row carries the second's reason.
     */
    const html = drawRow({
      row: row({
        installed: { id: 'codex', path: '/usr/bin/codex', version: '0.149.0', signedIn: 'yes', account: 'a@b.test' },
      }),
      busy: false,
      canSignOut: false,
      state: state({ step: 'idle', line: '' }),
    })
    expect(html).not.toContain('Sign out')
  })
})
