import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  MachineLinks,
  MachineRow,
  SessionRow,
  linkFor,
  machineActions,
  shortPath,
  type MachineActions,
  type MachinesHalf,
} from './MachineLinks'
import {
  asOutput,
  asPairResult,
  asView,
  machineNoun,
  resolveBridge,
  type Machine,
  type MachineLinkState,
  type MachinesBridge,
  type MachinesView,
} from './types'

/**
 * The machines this desktop can reach — the half of Remote that dials out.
 *
 * No DOM here, so these render to static markup. That covers what a refactor
 * quietly breaks on this screen: which state a row prints, whether the key it
 * asks a person to compare is still on it, and which two buttons a card is
 * allowed to have — the third one was removed on 2026-08-19 and there is a
 * whole block below pinning that it stays removed.
 *
 * The presses are pinned separately, through `machineActions`, because markup
 * cannot tell you what a button *does* — and what is behind these is a shell on
 * somebody else's computer.
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
    ports: [],
    copilot: null,
    hostPlatform: 'win32',
    retryAt: null,
    ...partial,
  }
}

const NOTHING: MachineActions = {
  type: () => {},
  pair: () => {},
  connect: () => {},
  disconnect: () => {},
  forget: () => {},
  open: () => {},
  close: () => {},
  openPort: () => {},
  refreshPorts: () => {},
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
  // Nothing here drops a file. The transfer path is covered end to end in
  // `main/remote/machines/transfer-live.test.ts`, over a real relay.
  uploadToMachine: () => Promise.resolve({ ok: false, message: 'not in this fake' }),
  cancelMachineUpload: () => Promise.resolve(false),
  onMachineUpload: () => () => {},
  writeToMachineSession: () => Promise.resolve(true),
  // Answers a record rather than a boolean, like the real one: a send from a
  // surface with no terminal on screen has to come back carrying its own
  // sentence, and a stub that answered `true` would let a component that draws
  // the sentence compile against a shape it never gets.
  sendToMachineSession: () => Promise.resolve({ ok: true, message: 'Sent.' }),
  resizeMachineSession: () => Promise.resolve(true),
  createMachineSession: () => Promise.resolve(true),
  closeMachineSession: () => Promise.resolve(true),
  refreshMachinePorts: () => Promise.resolve(true),
  openOnMachine: () => Promise.resolve(true),
  // The copilot verbs answer a record for the same reason `sendToMachineSession`
  // does, and it is the same defect being guarded: there is no terminal on
  // screen to make a lost frame visible, so a stub that answered `true` would
  // let a component that draws the sentence compile against a shape it never
  // gets.
  attachMachineCopilot: () => Promise.resolve({ ok: true, message: 'Watching that machine’s copilot.' }),
  startMachineCopilot: () => Promise.resolve({ ok: true, message: 'Asked that machine to start a copilot run.' }),
  sayToMachineCopilot: () => Promise.resolve({ ok: true, message: 'Sent.' }),
  refreshMachineCopilot: () => Promise.resolve({ ok: true, message: 'Asked.' }),
  onMachineCopilotState: () => () => {},
  onMachineCopilotChat: () => () => {},
  onMachinesState: () => () => {},
  onMachineOutput: () => () => {},
}

function row(state: MachineLinkState, overrides: Partial<Machine> = {}): string {
  return renderToStaticMarkup(
    <MachineRow
      machine={machine(overrides)}
      link={state}
      openSessionId={null}
      actions={NOTHING}
      platform="mac"
    />,
  )
}

function half(over: Partial<MachinesHalf> = {}): MachinesHalf {
  return {
    wired: true,
    view: { machines: [], links: [], blocked: null },
    reading: false,
    entry: { digits: '', busy: false, error: null, blocked: null },
    open: null,
    actions: NOTHING,
    ...over,
  }
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
     *
     * It now names the section as well, and the section it names has moved:
     * approving happens under Remote, because the Machines page it used to say
     * has been folded into it.
     */
    const markup = row(
      link({
        state: 'awaiting-approval',
        reason: 'This device is waiting to be approved. Approve it in the desktop app, then reconnect.',
      }),
      { name: 'Studio PC' },
    )
    expect(markup).toContain('on Studio PC, under Remote')
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

  it('offers to forget it, and asks first', () => {
    // Pairing again from scratch is the cost, so it is a two-press control —
    // and the confirmation is inline rather than a dialog, because this screen
    // is already inside one.
    expect(row(link())).toContain('>Forget</button>')
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

describe('what the card may press', () => {
  /*
   * There were five tests here and they were all about **New session** — when
   * it was offered, when it was a sentence instead, and which of the two
   * reasons the sentence gave. The button is gone: *"we don't need this new
   * session thing here. Just disconnect and forget thing is good enough for
   * us."* (2026-08-19).
   *
   * What replaces them is one test rather than five, and it is the shape the
   * removal actually needs pinned: not "the button is absent today", which any
   * render would show, but that **no state of the link brings it back**. The
   * old gate had three inputs — connected, `create` in the capabilities, a
   * shared folder — and the way a removal like this quietly reverses is
   * somebody restoring one branch of it. So every combination that used to draw
   * the button, and every combination that used to draw a sentence explaining
   * it, is rendered here and checked for both.
   */
  const shapes: Array<[string, MachineLinkState]> = [
    ['everything the old gate wanted', link()],
    ['a build that cannot start one', link({ capabilities: [] })],
    ['no folder shared with this device', link({ folders: [] })],
    ['a machine that never mentioned folders', link({ folders: null })],
    ['a machine nobody has dialled', link({ state: 'offline' })],
  ]

  for (const [what, state] of shapes) {
    it(`draws no New session, and no note about one, against ${what}`, () => {
      const markup = row(state)
      expect(markup).not.toContain('New session')
      // The two sentences that existed only to explain its absence.
      expect(markup).not.toContain('cannot start a session')
      expect(markup).not.toContain('No folder has been shared')
      expect(markup).not.toContain('not inside a window that can open one')
    })
  }

  it('keeps the two that are left, which is what he asked for', () => {
    // "Just disconnect and forget thing is good enough for us." Connect is the
    // same control in its other position, so both halves are checked.
    expect(row(link({ state: 'online' }))).toContain('Disconnect')
    expect(row(link({ state: 'offline' }))).toContain('Connect')
    expect(row(link())).toContain('>Forget</button>')
  })

  it('leaves the route to a session on that machine standing, in the rail', () => {
    /*
     * The one thing this removal must not have done is take the capability
     * away, and the check for it cannot live in this file — the ＋ is on the
     * sidebar's machine heading. It is pinned in
     * `renderer/shell/machine-group.test.tsx`, by the accessible name *"New
     * session on DESKTOP-DDGMNCV"*, and it was verified there **before** the
     * button was taken off this card rather than after.
     *
     * This test is a signpost, not a second copy of that assertion: what it
     * pins is that this file's own actions carry no way to start one, so the
     * rail is the only route and there is nothing here to drift from it.
     */
    expect(Object.keys(NOTHING)).not.toContain('newSession')
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

describe('the list', () => {
  it('says the list is empty rather than drawing an empty list', () => {
    const markup = renderToStaticMarkup(<MachineLinks half={half()} platform="mac" />)
    expect(markup).toContain('No other machine yet')
    expect(markup).toContain('Machines you can reach')
  })

  it('waits for the first read without taking the rest of the section with it', () => {
    // A section that says "Reading…" for a moment is a section whose first
    // frame is one nobody can start a pairing on — and the code somebody has
    // walked over to type is minted at the top of it.
    const markup = renderToStaticMarkup(<MachineLinks half={half({ reading: true })} platform="mac" />)
    expect(markup).toContain('Reading the machines this desktop knows')
    expect(markup).not.toContain('No other machine yet')
  })

  it('says so plainly when this build cannot reach the feature at all', () => {
    const markup = renderToStaticMarkup(<MachineLinks half={half({ wired: false })} platform="mac" />)
    expect(markup).toContain('older preload')
    expect(markup).not.toContain('No other machine yet')
  })

  it('puts the terminal it was handed under the machine whose session is open', () => {
    const markup = renderToStaticMarkup(
      <MachineLinks
        half={half({
          view: {
            machines: [machine()],
            links: [
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
            ],
            blocked: null,
          },
          open: { machineId: 'MACHINE1', sessionId: 's1' },
          pane: <div className="pane-stand-in" />,
        })}
        platform="mac"
      />,
    )
    expect(markup).toContain('machines-pane')
    expect(markup).toContain('pane-stand-in')
    expect(markup).toContain('>Close</button>')
  })

  it('draws no pane for a session that is not in the link any more', () => {
    // Reachable: the far machine ends the session while its terminal is open.
    // A head with a Close button over an empty box would claim a session that
    // no longer exists.
    const markup = renderToStaticMarkup(
      <MachineLinks
        half={half({
          view: { machines: [machine()], links: [link()], blocked: null },
          open: { machineId: 'MACHINE1', sessionId: 'gone' },
          pane: <div className="pane-stand-in" />,
        })}
        platform="mac"
      />,
    )
    expect(markup).not.toContain('pane-stand-in')
    expect(markup).not.toContain('machines-pane')
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

describe('the link for a machine', () => {
  it('is the resting state for one nothing has dialled yet', () => {
    const resting = linkFor({ machines: [], links: [], blocked: null }, 'MACHINE1')
    expect(resting.state).toBe('offline')
    expect(resting.sessions).toEqual([])
    // Null rather than `[]`: "that machine never mentioned folders" is not "no
    // folder was shared". Nothing on this card reads the difference any more —
    // `newSessionOffer` did and went with the button — but the far machine's
    // own answer is still two different answers, and flattening them here is
    // how a later reader would conclude they were one.
    expect(resting.folders).toBeNull()
  })
})

/* ------------------------------------------------------------- pressing -- */

function recorder(answers: Partial<Record<keyof MachinesBridge, unknown>> = {}): {
  bridge: MachinesBridge
  calls: string[]
} {
  const calls: string[] = []
  const bridge: MachinesBridge = { ...NOOP_BRIDGE }
  for (const name of Object.keys(NOOP_BRIDGE) as Array<keyof MachinesBridge>) {
    // The two `on*` channels return an unsubscribe function rather than a
    // promise, so they keep the no-op above: a recorder that made them
    // promise-shaped would be a stub disagreeing with the preload, which is the
    // thing `.harness/stub.ts` has a paragraph about.
    if (name.startsWith('on')) continue
    // Widened to write, rather than narrowed to read: every value put here is a
    // function with the shape the interface asks for, and the index signature is
    // only how the loop reaches it.
    ;(bridge as unknown as Record<string, unknown>)[name] = (
      ...args: unknown[]
    ): Promise<unknown> => {
      calls.push(`${name}(${args.map((arg) => String(arg)).join(', ')})`)
      return Promise.resolve(answers[name] ?? null)
    }
  }
  return { bridge, calls }
}

function pressing(bridge: MachinesBridge | null, digits = ''): {
  actions: MachineActions
  state: {
    digits: string
    view: MachinesView
    busy: boolean
    error: string | null
  }
  settled(): Promise<void>
} {
  const state = {
    digits,
    view: { machines: [], links: [], blocked: null } as MachinesView,
    busy: false,
    error: null as string | null,
  }
  const actions = machineActions({
    bridge,
    digits,
    setDigits: (next) => {
      state.digits = next
    },
    setView: (next) => {
      state.view = next
    },
    setPairing: (next) => {
      state.busy = next
    },
    setError: (next) => {
      state.error = next
    },
    setOpen: () => {},
    isAlive: () => true,
  })
  // Nothing here returns its promise, which is the point — these are presses.
  // One turn of the microtask queue is enough for a resolved bridge.
  return { actions, state, settled: () => new Promise((resolve) => setTimeout(resolve, 0)) }
}

describe('typing a code and sending it', () => {
  it('sends the canonical code rather than whatever was typed', async () => {
    // `pairWithCode` normalises again on the other side, so this is not what
    // makes it work — it is what makes the code in the notice, the code in the
    // field and the code the far machine matched the same string.
    const { bridge, calls } = recorder({ pairMachine: { ok: true } })
    const h = pressing(bridge, '482 913')
    h.actions.pair()
    await h.settled()
    expect(calls[0]).toBe('pairMachine(482913)')
  })

  it('clears the field and re-reads the list when it works', async () => {
    const { bridge, calls } = recorder({
      pairMachine: { ok: true },
      listMachines: { machines: [machine()], links: [link()], blocked: null },
    })
    const h = pressing(bridge, '482913')
    h.actions.pair()
    await h.settled()
    expect(calls).toEqual(['pairMachine(482913)', 'listMachines()'])
    expect(h.state.digits).toBe('')
    expect(h.state.view.machines).toHaveLength(1)
    expect(h.state.busy).toBe(false)
  })

  it('prints the refusal in the far machine’s own words, and keeps the code', async () => {
    // Keeping it is deliberate: a wrong digit is one box to fix, and clearing
    // six boxes because one of them was wrong is the field punishing a typo.
    const { bridge } = recorder({
      pairMachine: {
        ok: false,
        reason: 'not-found',
        message: 'No machine is showing that code. They last a minute.',
      },
    })
    const h = pressing(bridge, '482913')
    h.actions.pair()
    await h.settled()
    expect(h.state.error).toBe('No machine is showing that code. They last a minute.')
    expect(h.state.digits).toBe('482913')
    expect(h.state.busy).toBe(false)
  })

  it('says something rather than nothing when the code is not whole', async () => {
    const { bridge, calls } = recorder()
    const h = pressing(bridge, '4829')
    h.actions.pair()
    await h.settled()
    expect(calls).toEqual([])
    expect(h.state.error).toBe('That is not a whole code yet.')
  })

  it('drops the error the moment the code is retyped', () => {
    const { bridge } = recorder()
    const h = pressing(bridge, '482913')
    h.actions.type('48291')
    expect(h.state.digits).toBe('48291')
    expect(h.state.error).toBeNull()
  })

  it('does not throw when the build has no machine channels', async () => {
    const h = pressing(null, '482913')
    h.actions.pair()
    h.actions.connect(machine())
    h.actions.forget(machine())
    await h.settled()
    expect(h.state.error).toBeNull()
  })
})

describe('the machine buttons', () => {
  it('draw the view that came back rather than the one that was on screen', async () => {
    // The same rule the devices half is built on: what this screen claims about
    // the world comes from an answer, never from the fact that a call returned.
    const answer = { machines: [machine({ name: 'Studio PC' })], links: [link()], blocked: null }
    const { bridge, calls } = recorder({
      connectMachine: answer,
      disconnectMachine: answer,
      forgetMachine: { machines: [], links: [], blocked: null },
    })
    const h = pressing(bridge)
    h.actions.connect(machine())
    await h.settled()
    expect(calls).toEqual(['connectMachine(MACHINE1)'])
    expect(h.state.view.machines).toHaveLength(1)

    h.actions.forget(machine())
    await h.settled()
    expect(h.state.view.machines).toHaveLength(0)
  })

  it('has no way to start a session on the far machine at all, by any name', async () => {
    /*
     * The strongest thing this file can still say about **New session**, now
     * that the button is gone from the card.
     *
     * There were two tests here. One pinned that the press asked the *window*
     * for the dialog rather than calling `createMachineSession` straight out to
     * the far machine — which was itself the fix for a press that answered
     * *which folder*, *which agent* and *which login* on somebody else's
     * computer without asking anybody (2026-08-17: *"we just always wanted this
     * pop-up to come up so we choose which type of terminal we want to
     * open."*). The other pinned that no button was drawn where there was no
     * window to open the dialog in.
     *
     * Neither has anything to hold now, so what is pinned instead is the fact
     * that outlives both: this half exposes **no** action that starts a session,
     * and pressing every action it does expose sends `createMachineSession` to
     * nobody. That is what stops the old spawn coming back through a different
     * door — the door, not the button, was the defect.
     */
    const { bridge, calls } = recorder()
    const h = pressing(bridge)
    expect(Object.keys(h.actions)).not.toContain('newSession')

    h.actions.connect(machine())
    h.actions.disconnect(machine())
    h.actions.forget(machine())
    h.actions.openPort(machine(), 5173)
    h.actions.refreshPorts(machine())
    await h.settled()
    expect(calls.some((call) => call.startsWith('createMachineSession'))).toBe(false)
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

/**
 * Remote localhost on the desktop — the half that was one-way.
 *
 * `web.open` has been on the wire since the web client needed it and only the
 * web client sent it, so a Mac reaching a PC could list that PC's sessions and
 * say nothing at all about what it was serving. What is pinned here is the
 * three decisions this block makes: whether it is drawn at all, whether the
 * Open is drawn, and that every row carries the far machine's own icon.
 */
describe('what the far machine is serving', () => {
  const serving = (over: Partial<MachineLinkState> = {}): MachineLinkState =>
    link({
      capabilities: ['create', 'localhost', 'web'],
      ports: [
        { port: 5173, process: 'node', guessed: false },
        { port: 8080, process: '', guessed: true },
      ],
      ...over,
    })

  it('lists the ports with the machine’s own icon on every row', () => {
    /*
     * On every row and not only on the heading, which is the whole point of the
     * icon: *"remote localhost should list the remote machine's ports with the
     * machine's icon"*. This desktop has its own localhost list on the browser's
     * start page and the rows look identical — a number, a process, an open —
     * so a row that borrowed its identity from a heading four rows up is a row
     * that reads as local.
     */
    const markup = row(serving())
    expect(markup).toContain('Localhost on Studio PC')
    expect(markup).toContain('5173 · node')
    // The far machine could not name the process, so the row says that rather
    // than inventing one.
    expect(markup).toContain('8080 · unknown process')
    // Heading plus one per row.
    expect(markup.split('machines-glyph').length - 1).toBe(3)
  })

  it('is not drawn at all for a machine that does not tunnel', () => {
    expect(row(link({ capabilities: ['create'] }))).not.toContain('machines-ports')
  })

  it('is not drawn for a link that is not up', () => {
    // The list belonged to a connection that has ended. Ports that were open
    // ten minutes ago on a machine that has since rebooted open nothing.
    expect(row(serving({ state: 'offline' }))).not.toContain('machines-ports')
  })

  it('says so rather than drawing an empty list', () => {
    const markup = row(serving({ ports: [] }))
    expect(markup).toContain('Nothing is listening on that PC right now')
  })

  it('offers no Open to a machine that withheld `web`, and writes nothing about it', () => {
    /*
     * A host with no window and a device treated as a guest arrive identically,
     * as a capability the welcome did not carry. The button is absent rather
     * than disabled — a disabled control still invites the ask.
     *
     * Two sentences used to be printed under the list saying that the far
     * machine would not open a page and what to do about it. The rows not
     * having the button is the same fact, drawn instead of narrated, and the
     * paragraph is the shape this whole review was about.
     */
    const markup = row(serving({ capabilities: ['create', 'localhost'] }))
    expect(markup).not.toContain('Open there')
    expect(markup).not.toContain('not letting this one open pages on it')
    expect(markup).not.toContain('Pair this machine as one of your own')
  })

  it('asks the far machine to open the address, and composes it from the row', async () => {
    const opened: Array<{ id: string; url: string }> = []
    const bridge: MachinesBridge = {
      ...NOOP_BRIDGE,
      openOnMachine: async (id: string, url: string) => {
        opened.push({ id, url })
        return true
      },
    }
    const { actions, settled } = pressing(bridge)
    actions.openPort(machine(), 5173)
    await settled()

    expect(opened).toEqual([{ id: 'MACHINE1', url: 'http://localhost:5173/' }])
  })

  it('refreshes without redrawing from the answer', async () => {
    // The far machine replies with a `ports` frame, the link publishes it, and
    // the whole view arrives on `machines:state`. Redrawing from this promise
    // would be a second path to the same list, and the two would disagree the
    // first time one was slow.
    const asked: string[] = []
    const bridge: MachinesBridge = {
      ...NOOP_BRIDGE,
      refreshMachinePorts: async (id: string) => {
        asked.push(id)
        return true
      },
    }
    const { actions, state, settled } = pressing(bridge)
    const before = state.view
    actions.refreshPorts(machine())
    await settled()

    expect(asked).toEqual(['MACHINE1'])
    expect(state.view).toBe(before)
  })
})
