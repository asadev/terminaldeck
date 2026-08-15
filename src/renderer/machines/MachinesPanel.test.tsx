import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  MachineRow,
  MachinesPanel,
  SessionRow,
  newSessionOffer,
  secondsLeft,
  shortPath,
} from './MachinesPanel'
import {
  asCodeResult,
  asOutput,
  asPairResult,
  asView,
  machineNoun,
  resolveBridge,
  type Machine,
  type MachineLinkState,
  type MachinesBridge,
} from './types'

/**
 * No DOM environment here, so these render to static markup — the same
 * arrangement `HooksPanel.test.tsx` uses. That covers what a refactor quietly
 * breaks on this screen: which state a row prints, whether the key it asks a
 * person to compare is still on it, and whether New session is offered against
 * a machine that could not serve it.
 *
 * Everything that needs a click is either state (covered by the main process's
 * own tests through the channels it answers) or a socket (covered end to end in
 * `src/main/remote/machines/live.test.ts`).
 */

function machine(partial: Partial<Machine> = {}): Machine {
  return {
    id: 'MACHINE1',
    name: 'Studio PC',
    hostId: 'MACHINE1',
    fingerprint: 'ABCD-EFGH-JKLM-NPQR-STUV-WXYZ',
    platform: 'win32',
    pairedAt: 1,
    lastConnectedAt: null,
    ...partial,
  }
}

function link(partial: Partial<MachineLinkState> = {}): MachineLinkState {
  return {
    id: 'MACHINE1',
    state: 'online',
    reason: null,
    sessions: [],
    folders: ['/Users/a/projects/deck'],
    capabilities: ['create'],
    hostPlatform: 'win32',
    retryAt: null,
    ...partial,
  }
}

const NOOP_BRIDGE: MachinesBridge = {
  listMachines: () => Promise.resolve({}),
  startMachineCode: () => Promise.resolve({}),
  cancelMachineCode: () => Promise.resolve({}),
  pairMachine: () => Promise.resolve({}),
  forgetMachine: () => Promise.resolve({}),
  renameMachine: () => Promise.resolve({}),
  connectMachine: () => Promise.resolve({}),
  disconnectMachine: () => Promise.resolve({}),
  attachMachineSession: () => Promise.resolve(true),
  detachMachineSession: () => Promise.resolve(true),
  writeToMachineSession: () => Promise.resolve(true),
  resizeMachineSession: () => Promise.resolve(true),
  createMachineSession: () => Promise.resolve(true),
  onMachinesState: () => () => {},
  onMachineOutput: () => () => {},
}

function row(state: MachineLinkState, overrides: Partial<Machine> = {}): string {
  return renderToStaticMarkup(
    <MachineRow
      machine={machine(overrides)}
      link={state}
      bridge={NOOP_BRIDGE}
      openSessionId={null}
      onOpen={() => {}}
      onClose={() => {}}
      onChanged={() => {}}
    />,
  )
}

describe('a machine row', () => {
  it('names the machine, the kind of machine it is, and what the link is doing', () => {
    const markup = row(link())
    expect(markup).toContain('Studio PC')
    expect(markup).toContain('PC')
    expect(markup).toContain('Connected')
    expect(markup).toContain('data-state="online"')
  })

  it('keeps the key on screen, because comparing it is the point of having it', () => {
    expect(row(link())).toContain('ABCD-EFGH-JKLM-NPQR-STUV-WXYZ')
  })

  it('says "waiting to be approved" rather than an error', () => {
    // The two are a different instruction to the person reading them: one is
    // "press a button on the other machine", the other is "something is wrong".
    const markup = row(
      link({
        state: 'awaiting-approval',
        reason: 'This device is waiting to be approved. Approve it in the desktop app, then reconnect.',
      }),
    )
    expect(markup).toContain('Waiting to be approved')
    expect(markup).not.toContain('Cannot connect')
  })

  it('rewrites the one sentence the far machine writes for a phone', () => {
    /*
     * `authenticatorFor` answers a pending device with "Approve it in the
     * desktop app, then reconnect". That is right for a phone and nonsense on a
     * desktop that *is* the app: the person is being told to go somewhere they
     * already are, when what they have to do is walk to the other keyboard.
     * Every other refusal keeps the far machine's own words.
     */
    const markup = row(
      link({
        state: 'awaiting-approval',
        reason: 'This device is waiting to be approved. Approve it in the desktop app, then reconnect.',
      }),
      { name: 'Studio PC' },
    )
    expect(markup).toContain('on Studio PC')
    expect(markup).not.toContain('in the desktop app')

    // And a machine that is genuinely broken still says what it was told.
    expect(row(link({ state: 'error', reason: 'The relay stopped answering.' }))).toContain(
      'The relay stopped answering.',
    )
  })

  it('offers Connect when it is not connected and Disconnect when it is', () => {
    expect(row(link({ state: 'offline' }))).toContain('Connect')
    expect(row(link({ state: 'online' }))).toContain('Disconnect')
  })

  it('says nothing is running rather than leaving a blank where a list would be', () => {
    expect(row(link())).toContain('Nothing is running on that PC')
  })

  it('lists the sessions on that machine', () => {
    const markup = row(
      link({
        sessions: [
          {
            id: 's1',
            title: 'agent',
            cwd: '/Users/a/projects/deck',
            provider: 'claude',
            status: 'running',
            exitCode: null,
          },
        ],
      }),
    )
    expect(markup).toContain('agent')
    expect(markup).toContain('projects/deck')
    expect(markup).toContain('running')
  })

  it('calls a machine that never said what it is a desktop, never a Mac', () => {
    // The bug this noun exists to end: a phone paired to a Windows PC printed
    // "Running on the Mac" because the only place the kind appeared was a
    // constant compiled into the client.
    // Both blank: what the link just heard, and what the store remembers from
    // the last time it heard anything.
    expect(row(link({ hostPlatform: '' }), { platform: '' })).toContain('desktop')
    expect(machineNoun('')).toBe('desktop')
    expect(machineNoun('darwin')).toBe('Mac')
    expect(machineNoun('win32')).toBe('PC')
    expect(machineNoun('linux')).toBe('machine')
  })
})

describe('what New session may do', () => {
  it('is offered when that machine can serve it', () => {
    expect(newSessionOffer(link())).toEqual({ can: true, note: null })
    expect(row(link())).toContain('New session')
  })

  it('is not a button against a machine that cannot start one, and says why', () => {
    const offer = newSessionOffer(link({ capabilities: [] }))
    expect(offer.can).toBe(false)
    expect(offer.note).toMatch(/cannot start a session/)
    const markup = row(link({ capabilities: [] }))
    expect(markup).not.toContain('>New session<')
    expect(markup).toContain('cannot start a session')
  })

  it('is not a button when no folder has been shared with this device', () => {
    // Empty is a real state with a real remedy on the other machine, and it is
    // not the same as a machine that never mentioned folders at all.
    const offer = newSessionOffer(link({ folders: [] }))
    expect(offer.can).toBe(false)
    expect(offer.note).toMatch(/No folder has been shared/)
  })

  it('is offered to a machine that never mentioned folders', () => {
    expect(newSessionOffer(link({ folders: null })).can).toBe(true)
  })

  it('is nothing at all while the link is down', () => {
    // Not a note either: "that machine cannot start a session" is untrue of a
    // machine nobody has asked yet.
    expect(newSessionOffer(link({ state: 'offline' }))).toEqual({ can: false, note: null })
  })
})

describe('a session row', () => {
  it('is a control that says whether it is the one open', () => {
    const session = {
      id: 's1',
      title: 'agent',
      cwd: '/Users/a/projects/deck',
      provider: 'claude',
      status: 'running',
      exitCode: null,
    }
    const closed = renderToStaticMarkup(
      <SessionRow session={session} open={false} onOpen={() => {}} onClose={() => {}} />,
    )
    const open = renderToStaticMarkup(
      <SessionRow session={session} open onOpen={() => {}} onClose={() => {}} />,
    )
    expect(closed).toContain('aria-pressed="false"')
    expect(open).toContain('aria-pressed="true"')
  })
})

describe('shortening a path', () => {
  it('keeps a short one whole and trims a long one to its last two parts', () => {
    expect(shortPath('/tmp')).toBe('/tmp')
    expect(shortPath('/Users/a')).toBe('/Users/a')
    expect(shortPath('/Users/a/projects/deck')).toBe('…/projects/deck')
    expect(shortPath('C:\\Users\\a\\projects\\deck')).toBe('…/projects/deck')
  })
})

describe('narrowing what crosses the bridge', () => {
  it('reads a whole view', () => {
    const view = asView({
      machines: [{ id: 'M1', name: 'PC', hostId: 'M1', fingerprint: 'AAAA', platform: 'win32', pairedAt: 2 }],
      links: [{ id: 'M1', state: 'online', sessions: [{ id: 's1' }], capabilities: ['create'] }],
      blocked: null,
    })
    expect(view.machines).toHaveLength(1)
    expect(view.links[0].state).toBe('online')
    expect(view.links[0].sessions[0].id).toBe('s1')
  })

  it('treats an unreadable answer as an empty one rather than throwing in an effect', () => {
    // A captive portal, an older preload, a channel that answered `undefined`.
    // The screen says "no machines" instead of showing a stack trace nobody
    // opens a console to read.
    expect(asView(undefined)).toEqual({ machines: [], links: [], blocked: null })
    expect(asView('nope')).toEqual({ machines: [], links: [], blocked: null })
    expect(asView({ machines: 'no', links: 7 })).toEqual({ machines: [], links: [], blocked: null })
  })

  it('refuses a link state it has never heard of rather than printing it', () => {
    expect(asView({ links: [{ id: 'M1', state: 'exploded' }] }).links[0].state).toBe('offline')
  })

  it('reads a code, and a failure to mint one', () => {
    expect(asCodeResult({ ok: true, code: { token: 'H4K9-2FQT', expiresAt: 12 } })).toEqual({
      ok: true,
      code: { token: 'H4K9-2FQT', expiresAt: 12 },
    })
    expect(asCodeResult({ ok: false, message: 'no relay' })).toEqual({ ok: false, message: 'no relay' })
    // A half-written answer is a failure, not a code with a missing field.
    expect(asCodeResult({ ok: true, code: { token: 'H4K9-2FQT' } }).ok).toBe(false)
  })

  it('reads a pairing result', () => {
    expect(asPairResult({ ok: true })).toEqual({ ok: true })
    expect(asPairResult({ ok: false, reason: 'refused', message: 'no' })).toEqual({
      ok: false,
      reason: 'refused',
      message: 'no',
    })
  })

  it('reads a chunk of output, and drops one that names no session', () => {
    expect(asOutput({ machineId: 'M1', sessionId: 's1', data: 'hi', replay: true })).toEqual({
      machineId: 'M1',
      sessionId: 's1',
      data: 'hi',
      replay: true,
    })
    expect(asOutput({ machineId: 'M1', data: 'hi' })).toBeNull()
    expect(asOutput(null)).toBeNull()
  })

  it('reports no bridge rather than pretending there is one', () => {
    // The seam that has broken three times without a type error: a panel calling
    // a method the preload stopped exposing.
    expect(resolveBridge()).toBeNull()
    expect(resolveBridge(NOOP_BRIDGE)).toBe(NOOP_BRIDGE)
  })
})

describe('the life left on a pairing code', () => {
  /**
   * The code is on screen for sixty seconds and nothing used to say so. It
   * simply stopped working mid-typing, and the first anybody heard of a time
   * limit was the error afterwards.
   */
  it('counts whole seconds down, and never below zero', () => {
    const now = 1_000_000
    expect(secondsLeft(now + 60_000, now)).toBe(60)
    // Rounded up: with 59.4 seconds left the honest thing to print is 60,
    // because 59 would be the first number a reader sees and it would be a
    // second short of the truth.
    expect(secondsLeft(now + 59_400, now)).toBe(60)
    expect(secondsLeft(now + 1, now)).toBe(1)
    expect(secondsLeft(now, now)).toBe(0)
    // A code that died while the window was asleep counts zero, not backwards.
    expect(secondsLeft(now - 30_000, now)).toBe(0)
  })
})

describe('the whole page', () => {
  it('draws both halves of pairing, in the order somebody does them', () => {
    // Show a code here, type one there. Splitting those across two screens
    // would mean explaining which screen to open on which machine before
    // anything could happen, inside a code that lasts a minute.
    const markup = renderToStaticMarkup(<MachinesPanel bridge={NOOP_BRIDGE} />)
    expect(markup).toContain('Let another machine in')
    expect(markup).toContain('Add a machine')
    expect(markup.indexOf('Let another machine in')).toBeLessThan(markup.indexOf('Add a machine'))
  })

  it('does not dress a hint up as a code somebody could type', () => {
    // The field's placeholder used to be "H4K9-2FQT" — the example from the
    // short-code doc comment — in the same mono face, uppercased and tracked
    // out exactly like a real value. An empty field read as a filled one, and
    // the fake code was typeable.
    const markup = renderToStaticMarkup(<MachinesPanel bridge={NOOP_BRIDGE} />)
    expect(markup).not.toContain('H4K9-2FQT')
    expect(markup).not.toMatch(/placeholder="[A-Z0-9]{4}-[A-Z0-9]{4}"/)
    expect(markup).toContain('placeholder="Paste the code"')
  })

  it('leaves both halves of pairing live while nothing is blocking them', () => {
    // The other half of the fix that disables them when the relay is down: a
    // page with nothing wrong with it must not come up greyed out. Static
    // markup is the first frame, before any read has answered, which is exactly
    // the moment a defensive `disabled` would show up as a screen nobody can
    // start a pairing on.
    const markup = renderToStaticMarkup(<MachinesPanel bridge={NOOP_BRIDGE} />)
    expect(markup).toContain('Show a code</button>')
    expect(markup).not.toMatch(/<button[^>]*disabled[^>]*>Show a code/)
    expect(markup).not.toMatch(/<input[^>]*placeholder="Paste the code"[^>]*disabled/)
  })

  it('says so plainly when this build cannot reach the feature at all', () => {
    // A window running against an older preload explains itself once rather
    // than throwing inside an effect and leaving a blank page.
    expect(renderToStaticMarkup(<MachinesPanel />)).toContain('not in this build')
  })
})
