import { useEffect, useRef, useState, type ReactNode } from 'react'
import { Button, Group, Notice } from '../settings/controls'
import { thisMachine, type UiPlatform } from '../platform'
import { useAppSettings } from '../settings/useAppSettings'
import { numberSetting, stringSetting } from '../settings/settings-schema'
import { RemoteTerminal } from './RemoteTerminal'
import type { CodeEntryState } from './CodeEntry'
import {
  STATE_LABEL,
  asPairResult,
  asView,
  machineNoun,
  type Machine,
  type MachineLinkState,
  type MachinesBridge,
  type MachinesView,
  type RemotePort,
  type RemoteSession,
} from './types'
import { normaliseCode } from '../../shared/short-code'
import './machines.css'

/**
 * The other half of Remote: the machines *this* one can reach.
 *
 * ## Why this is not a page any more
 *
 * It was. There was a **Machines** row in the sidebar and a **Remote** section
 * in Settings, and between them they answered one question twice — which devices
 * are paired with this machine. Both listed devices, both showed a pairing code
 * minted by the *same* desk in the main process, and both had their own idea of
 * when pairing was possible. Asad, looking at the two of them: they "should be
 * one". They are one now, and this file is the part of it that faces outward.
 *
 * The organising idea is that a phone and a second laptop are the same kind of
 * thing. What is genuinely different — and what is kept here rather than
 * flattened into the device roster — is the *direction*: everything in
 * `RemoteSection` is about something reaching this machine, and everything here
 * is about this machine reaching something else. That difference is real, it has
 * its own controls (Connect, New session, a terminal), and collapsing it would
 * have lost a feature rather than merged one.
 *
 * ## Pure, apart from the terminal
 *
 * `MachineLinks` and every row under it take what they draw. The one component
 * that cannot is {@link MachineSessionPane}, which builds an xterm and needs a
 * DOM — so it is passed *into* the view as a node. That is the same split
 * `RemoteSection` and `DeviceFolders` already use, and the reason is that
 * `renderToStaticMarkup` never runs an effect: a list that read its own machines
 * would be testable in exactly one state, the empty one.
 */

/* -------------------------------------------------------------------------- */
/* What the view is handed                                                     */
/* -------------------------------------------------------------------------- */

/** Every press on this half of the screen. */
export interface MachineActions {
  /** The pairing code being typed in, digit by digit. */
  type(next: string): void
  /** Redeem what has been typed, and remember the machine behind it. */
  pair(): void
  connect(machine: Machine): void
  disconnect(machine: Machine): void
  forget(machine: Machine): void
  newSession(machine: Machine, link: MachineLinkState): void
  open(machineId: string, sessionId: string): void
  close(): void
  /** Open `http://localhost:<port>/` **on that machine**, in its own browser. */
  openPort(machine: Machine, port: number): void
  /** Ask that machine again what is listening on it. */
  refreshPorts(machine: Machine): void
}

/** The machines half of the merged section, as one bundle. */
export interface MachinesHalf {
  /**
   * Whether this build's preload carries the machine channels at all.
   *
   * False is a broken build rather than a setting, and it is said on screen: a
   * window running against an older preload used to render an entry field and a
   * list that could never fill, which reads as a feature that does not work
   * rather than one that is not there.
   */
  wired: boolean
  view: MachinesView
  /** The first read has not landed. Only the list waits on it. */
  reading: boolean
  /**
   * Why the read failed, in a sentence. Null while it has not.
   *
   * The list used to have two states, reading and read, and a read that never
   * came back therefore had no state at all — it stayed on "Reading the
   * machines this desktop knows…" for the rest of the session. The caller now
   * puts a deadline on the read, and a deadline needs somewhere to land: it is
   * this. Printing "No other machine yet" instead would be a claim, and a read
   * that did not answer is no evidence for one.
   */
  error?: string | null
  /** Ask for the list again, for the button beside {@link error}. */
  retry?: () => void
  entry: CodeEntryState
  open: { machineId: string; sessionId: string } | null
  /** The live terminal for {@link open}, or nothing in a static render. */
  pane?: ReactNode
  actions: MachineActions
}

/* -------------------------------------------------------------------------- */
/* Words                                                                       */
/* -------------------------------------------------------------------------- */

/** A session's folder, shortened to its last two segments for a row. */
export function shortPath(cwd: string): string {
  const parts = cwd.split(/[\\/]/).filter((part) => part !== '')
  if (parts.length <= 2) return cwd
  return `…/${parts.slice(-2).join('/')}`
}

/**
 * What the New session button may do, said in one place.
 *
 * Three different answers and only one of them is a button. A machine that
 * never advertised `create` is running a build that cannot start one; a machine
 * that sent an empty folder list has been told by its owner that this device
 * gets nothing. Neither is a case for a button that fails.
 */
export function newSessionOffer(link: MachineLinkState): { can: boolean; note: string | null } {
  if (link.state !== 'online') return { can: false, note: null }
  if (!link.capabilities.includes('create')) {
    return { can: false, note: 'That machine is running a build that cannot start a session from here.' }
  }
  if (link.folders !== null && link.folders.length === 0) {
    return {
      can: false,
      note: 'No folder has been shared with this device. Choose one on that machine, under Remote.',
    }
  }
  return { can: true, note: null }
}

/** The link for a machine, or the resting state of one nothing has dialled. */
export function linkFor(view: MachinesView, id: string): MachineLinkState {
  return (
    view.links.find((link) => link.id === id) ?? {
      id,
      state: 'offline',
      reason: null,
      sessions: [],
      folders: null,
      capabilities: [],
      ports: [],
      hostPlatform: '',
      retryAt: null,
    }
  )
}

/* -------------------------------------------------------------------------- */
/* The list                                                                    */
/* -------------------------------------------------------------------------- */

export function MachineLinks({ half, platform }: { half: MachinesHalf; platform?: UiPlatform }) {
  const { view, actions } = half
  const open = half.open

  const openSession =
    open === null
      ? null
      : (linkFor(view, open.machineId).sessions.find((session) => session.id === open.sessionId) ??
        null)

  return (
    <Group title="Machines you can reach">
      <p className="settings-prose">
        Sessions running on another computer you have paired, opened here as if they were local.
        Pairing goes both ways: this machine has to be approved over there once, under Remote.
      </p>

      {!half.wired ? (
        <Notice tone="warn">
          This window is running against an older preload, so it cannot reach the machines this
          desktop is paired with. Restarting the app usually fixes it.
        </Notice>
      ) : half.reading ? (
        // The list waits, and nothing above it does. A whole section that says
        // "Reading…" for a moment is a section whose first frame is one nobody
        // can start a pairing on — including, on a cold window, the code
        // somebody has walked over to type.
        //
        // "for a moment" is now true rather than hoped for: the caller reads
        // under a deadline, so this line always resolves into a list, an empty
        // list or the notice below it.
        <p className="settings-prose">Reading the machines this desktop knows…</p>
      ) : half.error != null ? (
        <Notice tone="warn">
          {half.error}{' '}
          {half.retry && <Button onClick={half.retry}>Try again</Button>}
        </Notice>
      ) : view.machines.length === 0 ? (
        <p className="settings-prose">
          No other machine yet. Type its code above and its sessions appear here.
        </p>
      ) : (
        <ul className="machines-list">
          {view.machines.map((machine) => (
            <MachineRow
              key={machine.id}
              machine={machine}
              link={linkFor(view, machine.id)}
              platform={platform}
              openSessionId={open?.machineId === machine.id ? open.sessionId : null}
              actions={actions}
            />
          ))}
        </ul>
      )}

      {open !== null && openSession !== null && (
        <div className="machines-pane">
          <div className="machines-pane-head">
            <span className="machines-pane-title">{openSession.title}</span>
            <span className="machines-pane-path">{openSession.cwd}</span>
            <Button onClick={actions.close}>Close</Button>
          </div>
          {half.pane}
        </div>
      )}
    </Group>
  )
}

/* ------------------------------------------------------------------- row -- */

export function MachineRow({
  machine,
  link,
  openSessionId,
  actions,
  platform,
}: {
  machine: Machine
  link: MachineLinkState
  openSessionId: string | null
  actions: MachineActions
  platform?: UiPlatform
}) {
  const [confirming, setConfirming] = useState(false)
  const noun = machineNoun(link.hostPlatform === '' ? machine.platform : link.hostPlatform)
  const offer = newSessionOffer(link)

  return (
    <li className="machines-row" data-state={link.state}>
      <div className="machines-row-head">
        <span className="machines-dot" aria-hidden="true" />
        <span className="machines-name">{machine.name}</span>
        <span className="machines-kind">{noun}</span>
        <span className="machines-state">{STATE_LABEL[link.state]}</span>
      </div>

      {/*
        The far machine's sentence, except for the one state where it is written
        for the wrong reader. `authenticatorFor` says "Approve it in the desktop
        app, then reconnect" — perfect for a phone, and nonsense on a desktop
        that *is* the app, three feet from the machine that has to do the
        approving. So this state gets an instruction that names the machine the
        person has to walk to, and every other state keeps the far end's own
        words, because it knows why it said no and this end does not.
      */}
      {link.state === 'awaiting-approval' ? (
        <p className="machines-reason">
          Approve {thisMachine(platform)} on {machine.name}, under Remote. It will connect by
          itself once you have.
        </p>
      ) : (
        link.reason !== null && <p className="machines-reason">{link.reason}</p>
      )}

      <p className="machines-key" title="Compare this with the same six groups on that machine">
        {machine.fingerprint}
      </p>

      {link.state === 'online' && link.sessions.length === 0 && (
        <p className="machines-note">Nothing is running on that {noun} right now.</p>
      )}

      {link.sessions.length > 0 && (
        <ul className="machines-sessions">
          {link.sessions.map((session) => (
            <SessionRow
              key={session.id}
              session={session}
              open={session.id === openSessionId}
              onOpen={() => actions.open(machine.id, session.id)}
              onClose={actions.close}
            />
          ))}
        </ul>
      )}

      {link.state === 'online' && link.capabilities.includes('localhost') && (
        <RemotePorts
          machine={machine}
          link={link}
          noun={noun}
          onOpen={(port) => actions.openPort(machine, port)}
          onRefresh={() => actions.refreshPorts(machine)}
        />
      )}

      <div className="machines-actions settings-chips">
        {offer.can && (
          <Button onClick={() => actions.newSession(machine, link)}>New session</Button>
        )}
        {link.state === 'online' || link.state === 'connecting' ? (
          <Button onClick={() => actions.disconnect(machine)}>Disconnect</Button>
        ) : (
          <Button onClick={() => actions.connect(machine)}>Connect</Button>
        )}
        {confirming ? (
          <>
            <span className="machines-confirm">
              Forget this {noun}? You would pair it again from scratch.
            </span>
            <Button
              tone="danger"
              onClick={() => {
                setConfirming(false)
                actions.forget(machine)
              }}
            >
              Forget
            </Button>
            <Button onClick={() => setConfirming(false)}>Keep</Button>
          </>
        ) : (
          <Button onClick={() => setConfirming(true)}>Forget</Button>
        )}
      </div>

      {offer.note !== null && <p className="machines-note">{offer.note}</p>}
    </li>
  )
}

export function SessionRow({
  session,
  open,
  onOpen,
  onClose,
}: {
  session: RemoteSession
  open: boolean
  onOpen(): void
  onClose(): void
}) {
  return (
    <li className="machines-session">
      <button
        type="button"
        className="machines-session-open"
        onClick={() => (open ? onClose() : onOpen())}
        aria-pressed={open}
      >
        <span className="machines-session-title">{session.title}</span>
        <span className="machines-session-path">{shortPath(session.cwd)}</span>
        <span className="machines-session-status">{session.status}</span>
      </button>
    </li>
  )
}

/**
 * That machine's icon, in eleven pixels.
 *
 * He asked for it in those words — *"remote localhost should list the remote
 * machine's ports with the machine's icon"* — and the reason is a real
 * confusion rather than decoration. This desktop has its own localhost list, on
 * the browser's start page, and the rows look identical: a number, a process
 * name, an Open. Without something on the row saying *which computer*, a person
 * looking at `3000 · node` has no way to know whether pressing it reaches the
 * thing they are running here or the thing running in the next room.
 *
 * Drawn rather than imported because there is no icon set in this codebase and
 * a downloaded one would drag a licence in — see the ground rule at the top of
 * CLAUDE.md. Three shapes, and each is the machine's own silhouette: a laptop
 * for a Mac, a window pane for a PC, a plain screen for anything else.
 * `currentColor` throughout, so it takes the row's ink in both themes rather
 * than carrying a colour of its own.
 */
export function MachineGlyph({ platform, label }: { platform: string; label: string }) {
  const kind = /^win/i.test(platform) ? 'windows' : /^darwin|mac/i.test(platform) ? 'mac' : 'other'
  return (
    <svg
      className="machines-glyph"
      viewBox="0 0 16 16"
      width="13"
      height="13"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.2"
      strokeLinejoin="round"
      role="img"
      aria-label={label}
    >
      {kind === 'windows' ? (
        <>
          <rect x="2" y="3" width="12" height="10" rx="1.2" />
          <path d="M8 3v10M2 8h12" />
        </>
      ) : (
        <>
          <rect x="2.5" y="3" width="11" height="7.5" rx="1.2" />
          {/* The lid's base, which is what makes the Mac read as a laptop. The
              plain screen leaves it off rather than drawing a different machine
              for a platform this app has no build for. */}
          {kind === 'mac' ? <path d="M1 13h14" strokeLinecap="round" /> : <path d="M6 13h4" strokeLinecap="round" />}
        </>
      )}
    </svg>
  )
}

/** `3000 · node`, or `3000 · unknown process` when the far end could not name it. */
export function portLabel(port: RemotePort): string {
  if (port.process === '' || port.guessed) return `${port.port} · unknown process`
  return `${port.port} · ${port.process}`
}

/**
 * What that machine is serving, and the one thing this desktop can do about it.
 *
 * ## Why Open means "open it there"
 *
 * A tunnel would bring the page here, and this end opens no listener — the
 * desktop's guest link is a socket to one machine, not a proxy. What it can do
 * is drive: ask that machine to put the page on **its own** screen, which is
 * the same verb the phone has been sending since the web client needed it and
 * which nothing on this side had ever sent. That is what made machine-to-machine
 * localhost one-way, and it is the smaller promise this transport can actually
 * keep.
 *
 * ## Why there is a Refresh and it is not a poll
 *
 * The link asks once per connection and pushes the answer, so this list is
 * already there when the row is drawn. What a push cannot cover is the person
 * who has just started a dev server over there: nothing on the far machine
 * watches its own process table, so the only honest options are a timer against
 * somebody else's computer or a button. It is a button.
 */
export function RemotePorts({
  machine,
  link,
  noun,
  onOpen,
  onRefresh,
}: {
  machine: Machine
  link: MachineLinkState
  noun: string
  onOpen(port: number): void
  onRefresh(): void
}) {
  // A machine with no window to open a page in never advertises `web`, and
  // neither does one that treats this device as a guest. Both arrive the same
  // way and the button is simply absent — never disabled, which is a control
  // that still invites the ask.
  const canOpen = link.capabilities.includes('web')
  const label = `on ${machine.name}`
  return (
    <div className="machines-ports">
      <div className="machines-ports-head">
        <MachineGlyph platform={link.hostPlatform === '' ? machine.platform : link.hostPlatform} label={label} />
        <span className="machines-ports-title">Localhost on {machine.name}</span>
        <button type="button" className="machines-ports-refresh" onClick={onRefresh}>
          Refresh
        </button>
      </div>

      {link.ports.length === 0 ? (
        <p className="machines-note">Nothing is listening on that {noun} right now.</p>
      ) : (
        <ul className="machines-portlist">
          {link.ports.map((port) => (
            <li key={port.port} className="machines-port">
              {/* The icon is on every row and not only on the heading, which is
                  the whole point of it: a row is what gets read, and a row that
                  borrowed its identity from a heading four rows up is a row that
                  reads as local. */}
              <MachineGlyph
                platform={link.hostPlatform === '' ? machine.platform : link.hostPlatform}
                label={label}
              />
              <span className="machines-port-label">{portLabel(port)}</span>
              {canOpen && (
                <button
                  type="button"
                  className="machines-port-open"
                  title={`Open localhost:${String(port.port)} in the browser on ${machine.name}`}
                  onClick={() => onOpen(port.port)}
                >
                  Open there
                </button>
              )}
            </li>
          ))}
        </ul>
      )}

      {!canOpen && link.ports.length > 0 && (
        <p className="machines-note">
          That {noun} is not letting this one open pages on it. Pair this machine as one of your own
          on {machine.name} to change that.
        </p>
      )}
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* The terminal                                                                */
/* -------------------------------------------------------------------------- */

/**
 * One session on another machine, live.
 *
 * Mounted only while a session is open, and it holds the subscription to
 * `machines:output` itself. The panel this came from kept a map of every open
 * terminal's writer and one subscription for all of them, which was the right
 * shape when it thought it might show several — it never has: one session is
 * open at a time, and the map was one indirection standing between a chunk of
 * bytes and the terminal it belongs to.
 *
 * The filter is not optional. Every machine's output arrives on one channel, so
 * a pane that wrote whatever it was handed would paint another machine's session
 * into this one the moment two links were both busy.
 */
export function MachineSessionPane({
  machineId,
  sessionId,
  bridge,
}: {
  machineId: string
  sessionId: string
  bridge: MachinesBridge
}) {
  /*
   * Read here rather than threaded down from the section.
   *
   * The hook is one read at launch plus whatever the settings window pushes, so
   * asking for it costs nothing — and the alternative is the bug this repository
   * has already shipped twice: a font size in Settings that reaches a preview
   * and no terminal.
   */
  const { values: settings } = useAppSettings()
  const fontSize = numberSetting(settings, 'appearance.terminalFontSize')
  const fontFamily = stringSetting(settings, 'appearance.terminalFontFamily')

  /**
   * The terminal's writer, held in a ref so that `subscribe` never changes.
   *
   * `RemoteTerminal` rebuilds its xterm whenever `subscribe` is a new function —
   * it is in the effect's dependencies, and it has to be, because a stale
   * subscription would deliver bytes to a disposed terminal. A `subscribe`
   * rebuilt on every render would therefore tear the terminal down and put it up
   * again on every keystroke, which is the whole session's scrollback lost each
   * time the font size setting is read.
   */
  const sink = useRef<((data: string) => void) | null>(null)
  const subscribe = useRef((handler: (data: string) => void) => {
    sink.current = handler
    return () => {
      if (sink.current === handler) sink.current = null
    }
  }).current

  useEffect(() => {
    return bridge.onMachineOutput((chunk) => {
      const output = chunk as { machineId?: unknown; sessionId?: unknown; data?: unknown }
      if (output?.machineId !== machineId || output?.sessionId !== sessionId) return
      if (typeof output.data === 'string') sink.current?.(output.data)
    })
  }, [bridge, machineId, sessionId])

  return (
    <RemoteTerminal
      machineId={machineId}
      sessionId={sessionId}
      bridge={bridge}
      subscribe={subscribe}
      fontSize={fontSize}
      fontFamily={fontFamily}
    />
  )
}

/* -------------------------------------------------------------------------- */
/* The actions                                                                 */
/* -------------------------------------------------------------------------- */

export interface MachineActionDeps {
  /** Null when this build has no machine channels; every action then refuses. */
  bridge: MachinesBridge | null
  /** What is in the entry boxes right now. */
  digits: string
  setDigits(next: string): void
  setView(view: MachinesView): void
  setPairing(busy: boolean): void
  setError(message: string | null): void
  setOpen(next: { machineId: string; sessionId: string } | null): void
  /** False once the section has gone, so nothing writes to a dead component. */
  isAlive(): boolean
}

/**
 * Every press on this half, as a plain function of its dependencies.
 *
 * Split out of the component for the reason `remoteActions` is: there is no DOM
 * in this repository's test environment, so anything left inside a `useState`
 * closure is reachable by nothing but a person clicking it in a packaged build —
 * and what is behind these is a shell on somebody else's computer. Pulled out
 * here, the ones that matter are pinned: that pairing sends the *canonical* code
 * rather than whatever was typed, that a refusal is printed in the far machine's
 * own words, and that the list on screen comes from the answer rather than from
 * the fact that a call returned.
 */
export function machineActions(deps: MachineActionDeps): MachineActions {
  const { bridge, setView, setPairing, setError, setOpen, isAlive } = deps

  const reread = async (): Promise<void> => {
    if (!bridge) return
    const view = asView(await bridge.listMachines())
    if (isAlive()) setView(view)
  }

  /** Do it, then draw the view that came back — never the one that was asked for. */
  const settle = (answer: Promise<unknown>): void => {
    void answer.then((next) => {
      if (isAlive()) setView(asView(next))
    })
  }

  return {
    type: (next) => {
      deps.setDigits(next)
      // The error belonged to the code that was there a moment ago. Leaving it
      // under a field somebody is retyping reads as a complaint about what they
      // are typing now.
      setError(null)
    },
    pair: () => {
      if (!bridge) return
      const canonical = normaliseCode(deps.digits)
      if (canonical === null) {
        // Unreachable through the button, which is disabled until the code is
        // whole — and said out loud anyway, because a press that does nothing
        // at all is the one thing this screen may not do.
        setError('That is not a whole code yet.')
        return
      }
      setPairing(true)
      setError(null)
      void bridge
        .pairMachine(canonical)
        .then(async (answer) => {
          const result = asPairResult(answer)
          if (!result.ok) {
            if (isAlive()) setError(result.message)
            return
          }
          if (isAlive()) deps.setDigits('')
          await reread()
        })
        .catch((error: unknown) => {
          if (isAlive()) setError(error instanceof Error ? error.message : String(error))
        })
        .finally(() => {
          if (isAlive()) setPairing(false)
        })
    },
    connect: (machine) => {
      if (bridge) settle(bridge.connectMachine(machine.id))
    },
    disconnect: (machine) => {
      if (bridge) settle(bridge.disconnectMachine(machine.id))
    },
    forget: (machine) => {
      if (bridge) settle(bridge.forgetMachine(machine.id))
    },
    newSession: (machine, link) => {
      // The first shared folder, because that is the only one this end knows is
      // allowed. A machine that never mentioned folders gets an empty string,
      // which is that machine's own default rather than a path invented here.
      if (bridge) void bridge.createMachineSession(machine.id, link.folders?.[0] ?? '')
    },
    open: (machineId, sessionId) => setOpen({ machineId, sessionId }),
    close: () => setOpen(null),
    openPort: (machine, port) => {
      // The address is composed here from a row that is on screen, so nothing
      // arbitrary is ever sent — and the far machine checks it anyway, through
      // the same gate an untrusted link goes through. A second, weaker check
      // written on this side would be the one somebody later mistook for the
      // real one.
      if (bridge) void bridge.openOnMachine(machine.id, `http://localhost:${String(port)}/`)
    },
    refreshPorts: (machine) => {
      // Nothing is drawn from the answer: the far machine replies with a `ports`
      // frame, the link publishes it, and the whole view arrives on
      // `machines:state`. Redrawing from this promise would be a second path to
      // the same list and the two would disagree the first time one was slow.
      if (bridge) void bridge.refreshMachinePorts(machine.id)
    },
  }
}
