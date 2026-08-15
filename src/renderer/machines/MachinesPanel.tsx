import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { PageEmpty, PageNote } from '../components/PageEmpty'
import { useWhenActive } from '../schedule'
import { panelSpec } from '../shell/panels'
import { thisMachine } from '../platform'
import { useAppSettings } from '../settings/useAppSettings'
import { numberSetting, stringSetting } from '../settings/settings-schema'
import { RemoteTerminal } from './RemoteTerminal'
import {
  STATE_LABEL,
  asCodeResult,
  asOutput,
  asPairResult,
  asView,
  machineNoun,
  resolveBridge,
  type Machine,
  type MachineLinkState,
  type MachinesBridge,
  type MachinesView,
  type PairingCode,
  type RemoteSession,
} from './types'
import './MachinesPanel.css'

/**
 * Other machines — the ones this desktop can open sessions on.
 *
 * ## The two halves of one screen, and why they are not two screens
 *
 * Pairing has two sides and a person doing it is standing at both. One machine
 * shows a code; the other is typed into. Splitting that across two pages would
 * mean explaining which page to open on which machine before anything can
 * happen, and the code is on screen for sixty seconds. So both live here, side
 * by side, in the order somebody does them.
 *
 * ## Nothing on this page claims anything it has not read back
 *
 * Every action answers with the whole view and the screen draws the answer,
 * never what it just asked for. That is the same rule the devices panel is
 * built on and it is the only version that cannot show a machine as connected
 * because a button was pressed.
 *
 * The states are the main process's own, and there are five because collapsing
 * them lies to somebody: `Waiting to be approved` is not `Cannot connect`, and
 * a person who reads the second walks away from a pairing that needed them to
 * press one button on the other keyboard.
 */

interface Props {
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: MachinesBridge
}

const EMPTY: MachinesView = { machines: [], links: [], blocked: null }

/** A session's folder, shortened to its last two segments for a row. */
/**
 * Whole seconds left on a pairing code, floored at zero.
 *
 * Pure so the countdown can be tested without a clock, and floored because a
 * timer that shows a negative number has outlived the thing it was counting —
 * the code is dead on the main process at that instant (`PAIRING_TTL_MS` in
 * `device-auth.ts`), and the screen is only catching up.
 */
export function secondsLeft(expiresAt: number, now: number): number {
  return Math.max(0, Math.ceil((expiresAt - now) / 1000))
}

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
      note: 'No folder has been shared with this device. Choose one on that machine, under Devices.',
    }
  }
  return { can: true, note: null }
}

export function MachinesPanel({ bridge: supplied }: Props) {
  const bridge = useMemo(() => resolveBridge(supplied), [supplied])
  /*
   * Read here rather than passed down from `App.tsx`.
   *
   * `PanelView` renders every page with the props a page needs, and threading
   * two appearance settings through it for one of them would be two more things
   * for a future page to forget. The hook is one read at launch plus whatever
   * the settings dialog pushes, so asking for it here costs nothing — and the
   * alternative is the bug this repository has already shipped twice: a font
   * size in Settings that reaches a preview and no terminal.
   */
  const { values: settings } = useAppSettings()
  const fontSize = numberSetting(settings, 'appearance.terminalFontSize')
  const fontFamily = stringSetting(settings, 'appearance.terminalFontFamily')
  const [view, setView] = useState<MachinesView>(EMPTY)
  const [reading, setReading] = useState(true)
  const [code, setCode] = useState<PairingCode | null>(null)
  const [codeError, setCodeError] = useState<string | null>(null)
  /**
   * Seconds left on the code that is on screen.
   *
   * A clock, because nothing else can be: no file changes and no channel fires
   * while a code ages — it simply stops being valid, and the only thing that
   * notices the passing of time is something watching the time. It ticks only
   * while a code is up, which is at most a minute a year.
   */
  const [remaining, setRemaining] = useState(0)
  /** Whether the code has just been copied, for the moment the button says so. */
  const [copied, setCopied] = useState(false)
  const [typed, setTyped] = useState('')
  const [pairing, setPairing] = useState(false)
  const [pairError, setPairError] = useState<string | null>(null)
  const [open, setOpen] = useState<{ machineId: string; sessionId: string } | null>(null)

  /**
   * Every open terminal's writer, by machine and session.
   *
   * One subscription to `onMachineOutput` for the whole panel rather than one
   * per pane: the bridge pushes every machine's bytes down one channel, and a
   * second listener would hand the same chunk to the same terminal twice.
   */
  const sinks = useRef(new Map<string, (data: string) => void>())

  /**
   * The key one open terminal is filed under.
   *
   * The separator is a NUL rather than a space or a slash, and that is not
   * fussiness: both halves come off the wire. A session id is bounded by
   * `ID_RE` and a machine id is a host id, so neither can contain one today —
   * which is exactly the reason to use the character that stays impossible if
   * either of those ever loosens, instead of one that would let two different
   * pairs collapse onto one entry and cross two terminals' output.
   */
  const sinkKey = (machineId: string, sessionId: string): string =>
    `${machineId}\u0000${sessionId}`

  useEffect(() => {
    if (!bridge) return
    return bridge.onMachineOutput((chunk) => {
      const output = asOutput(chunk)
      if (output === null) return
      sinks.current.get(sinkKey(output.machineId, output.sessionId))?.(output.data)
    })
  }, [bridge])

  useEffect(() => {
    if (!bridge) {
      setReading(false)
      return
    }
    let live = true
    void bridge
      .listMachines()
      .then((value) => {
        if (live) setView(asView(value))
      })
      .finally(() => {
        if (live) setReading(false)
      })
    const off = bridge.onMachinesState((value) => {
      if (live) setView(asView(value))
    })
    return () => {
      live = false
      off()
    }
  }, [bridge])

  /**
   * True while this panel is on screen, so a read that lands after it is gone
   * does not set state nobody is looking at.
   */
  const mounted = useRef(true)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])

  const reread = useCallback(async (): Promise<void> => {
    if (!bridge) return
    const value = await bridge.listMachines()
    if (mounted.current) setView(asView(value))
  }, [bridge])

  /**
   * Read it again when the window comes back, because one thing on this screen
   * has nothing pushing it.
   *
   * `machines:state` is announced when a *link* changes — a machine coming up,
   * going away, being paired. `blocked` is not a link: it is this desktop's own
   * relay, and nothing in the main process announces that connecting or
   * dropping. So the sentence about the relay was decided once, when the page
   * was opened, and then stood there being wrong in whichever direction the
   * relay moved next: still saying "wait for it to connect" a minute after it
   * had, or still offering a code after the socket died.
   *
   * This is the same answer `RemoteSection` gives for the same reason and in the
   * same words — coming back to the window is the moment a stale answer starts
   * to matter — and it is an event rather than a timer, which is the standing
   * rule here: nothing polls for something a person's own attention already
   * signals.
   */
  useWhenActive(() => {
    void reread()
  })

  /**
   * Take the code off screen when it dies.
   *
   * One timeout for the life of one code, not a tick. The code is already dead
   * on the main process at that instant — `PAIRING_TTL_MS` is enforced in
   * `device-auth.ts` and the rendezvous stops answering with it — so this is the
   * screen catching up with a fact rather than a screen deciding one.
   */
  useEffect(() => {
    if (code === null) return
    const timer = setTimeout(
      () => {
        setCode(null)
        setCodeError('That code has expired. Show another one.')
      },
      Math.max(0, code.expiresAt - Date.now()),
    )
    return () => clearTimeout(timer)
  }, [code])

  /**
   * The countdown under the code.
   *
   * Sixty seconds is not long to read nine characters off one screen and type
   * them into another, and the copy says "it lasts a minute" — so the screen
   * has to show which minute. Without it the code simply died mid-typing and
   * the only sign was an error about something the reader had no way to see
   * coming.
   */
  useEffect(() => {
    if (code === null) {
      setRemaining(0)
      return
    }
    setRemaining(secondsLeft(code.expiresAt, Date.now()))
    const tick = setInterval(() => setRemaining(secondsLeft(code.expiresAt, Date.now())), 1000)
    return () => clearInterval(tick)
  }, [code])

  // The "Copied" reply is about the press, not about the code, so it clears
  // itself rather than waiting for the next one.
  useEffect(() => {
    if (!copied) return
    const timer = setTimeout(() => setCopied(false), 2000)
    return () => clearTimeout(timer)
  }, [copied])

  const subscribeFor = useCallback((machineId: string, sessionId: string) => {
    return (handler: (data: string) => void): (() => void) => {
      const key = sinkKey(machineId, sessionId)
      sinks.current.set(key, handler)
      return () => {
        if (sinks.current.get(key) === handler) sinks.current.delete(key)
      }
    }
  }, [])

  const showCode = useCallback(async (): Promise<void> => {
    if (!bridge) return
    setCodeError(null)
    const result = asCodeResult(await bridge.startMachineCode())
    if (result.ok) setCode(result.code)
    else {
      setCode(null)
      setCodeError(result.message)
    }
  }, [bridge])

  const hideCode = useCallback(async (): Promise<void> => {
    if (!bridge) return
    setCode(null)
    setCodeError(null)
    await bridge.cancelMachineCode()
  }, [bridge])

  const addMachine = useCallback(async (): Promise<void> => {
    if (!bridge || typed.trim() === '') return
    setPairing(true)
    setPairError(null)
    try {
      const result = asPairResult(await bridge.pairMachine(typed))
      if (result.ok) {
        setTyped('')
        setView(asView(await bridge.listMachines()))
      } else {
        setPairError(result.message)
      }
    } finally {
      setPairing(false)
    }
  }, [bridge, typed])

  const linkFor = useCallback(
    (id: string): MachineLinkState =>
      view.links.find((link) => link.id === id) ?? {
        id,
        state: 'offline',
        reason: null,
        sessions: [],
        folders: null,
        capabilities: [],
        hostPlatform: '',
        retryAt: null,
      },
    [view.links],
  )

  if (!bridge) {
    return (
      <PageEmpty icon={panelSpec('machines').icon} title="Machines are not in this build">
        This window is running against an older preload, so it cannot reach the machines this
        desktop is paired with. Restarting the app usually fixes it.
      </PageEmpty>
    )
  }

  const openSession =
    open === null
      ? null
      : linkFor(open.machineId).sessions.find((session) => session.id === open.sessionId) ?? null

  return (
    <section className="machines" aria-label="Machines">
      <h2 className="machines-heading">Machines</h2>

      {/*
        The reason pairing cannot happen, above the two halves it governs.

        It used to sit *below* both of them, between the pairing block and the
        list of machines, where it read as a footnote about the list — so the
        page said "this machine cannot show or read a pairing code" underneath a
        filled blue button that still offered to show one. Pressing it then
        printed the main process's version of the same sentence in a third
        place, and the screen had two paragraphs saying one thing and a primary
        button that could only ever fail.

        Now the precondition comes first and the controls it disables come
        after, which is the order somebody reads them in.
      */}
      {view.blocked !== null && <p className="machines-blocked">{view.blocked}</p>}

      <div className="machines-pair">
        <div className="machines-pair-half">
          <h3 className="machines-pair-title">Let another machine in</h3>
          <p className="machines-pair-body">
            Show a code here, then type it into the other machine. It lasts a minute and works
            once.
          </p>
          {code === null ? (
            /*
              Disabled while the relay is down, because the app already knows
              the answer. `machines:code` refuses the moment it sees the same
              state this button is reading, so an enabled one was a press whose
              only possible outcome was an error — the dead control the design
              brief's first rule is about, dressed as the one filled button on
              the page. The reason is on the hover as well as in the notice
              above, so the disabled state is never a mystery.
            */
            <button
              type="button"
              className="btn-primary"
              onClick={() => void showCode()}
              disabled={view.blocked !== null}
              title={view.blocked ?? undefined}
            >
              Show a code
            </button>
          ) : (
            <>
              <p className="machines-code" aria-label="Pairing code">
                {code.token}
              </p>
              {/* How long is left, and a way to take the code with you.

                  Neither existed. The code lived for sixty seconds with nothing
                  on screen counting them, and the only way to move it was to
                  select nine characters by hand while that clock ran — then it
                  died into an error that was the first anyone heard of a time
                  limit. `aria-live` is off: a screen reader announcing every
                  second of a minute is worse than the silence it replaces. */}
              <p className="machines-code-life" aria-live="off">
                {remaining > 0
                  ? `Good for another ${remaining} second${remaining === 1 ? '' : 's'}`
                  : 'Expiring…'}
              </p>
              <div className="machines-code-actions">
                <button
                  type="button"
                  onClick={() => {
                    void navigator.clipboard
                      ?.writeText(code.token)
                      .then(() => setCopied(true))
                      // Nothing is lost — the code is still on screen to be
                      // read, which is what it was there for.
                      .catch(() => setCopied(false))
                  }}
                >
                  {copied ? 'Copied' : 'Copy'}
                </button>
                {/* "Done" read as "the pairing is finished", which is the one
                    thing it does not mean: it takes the code off screen and
                    cancels it. */}
                <button type="button" onClick={() => void hideCode()}>
                  Hide the code
                </button>
              </div>
            </>
          )}
          {codeError !== null && <p className="machines-error">{codeError}</p>}
        </div>

        <div className="machines-pair-half">
          <h3 className="machines-pair-title">Add a machine</h3>
          <p className="machines-pair-body">
            Type the code the other machine is showing. You will then approve this one over there,
            once.
          </p>
          <form
            className="machines-add"
            onSubmit={(event) => {
              event.preventDefault()
              void addMachine()
            }}
          >
            <input
              className="machines-input"
              value={typed}
              onChange={(event) => setTyped(event.target.value)}
              // Not an example code. It was "H4K9-2FQT" — the literal example
              // from the short-code doc comment — set in the same mono face as
              // a real value and only slightly dimmer, so an empty field read
              // as one somebody had already filled in. Placeholder data dressed
              // as real data is the "nothing fake" rule, and this one was
              // typeable: a person could copy it and wonder why it failed.
              placeholder="Paste the code"
              spellCheck={false}
              autoComplete="off"
              aria-label="Pairing code from the other machine"
              // Both halves go quiet together. The notice above says this
              // machine can neither show *nor read* a code, and a field that
              // still takes nine characters while that is true is an invitation
              // to type a code that dies on submit.
              disabled={pairing || view.blocked !== null}
              title={view.blocked ?? undefined}
            />
            <button
              type="submit"
              disabled={pairing || view.blocked !== null || typed.trim() === ''}
              title={view.blocked ?? undefined}
            >
              {pairing ? 'Adding…' : 'Add'}
            </button>
          </form>
          {pairError !== null && <p className="machines-error">{pairError}</p>}
        </div>
      </div>

      {/*
        The reading note belongs to the *list*, not to the page.
        The two halves of pairing above do not depend on what is stored, and a
        whole page that says "Reading…" for a moment is a page whose first frame
        is one nobody can do anything on — including, on a cold window, the code
        somebody has walked over to type.
      */}
      {reading ? (
        <PageNote busy>Reading the machines this desktop knows…</PageNote>
      ) : view.machines.length === 0 ? (
        <PageNote>No other machine yet. Pair one above and its sessions appear here.</PageNote>
      ) : (
        <ul className="machines-list">
          {view.machines.map((machine) => (
            <MachineRow
              key={machine.id}
              machine={machine}
              link={linkFor(machine.id)}
              bridge={bridge}
              openSessionId={open?.machineId === machine.id ? open.sessionId : null}
              onOpen={(sessionId) => setOpen({ machineId: machine.id, sessionId })}
              onClose={() => setOpen(null)}
              onChanged={(next) => setView(next)}
            />
          ))}
        </ul>
      )}

      {open !== null && openSession !== null && (
        <div className="machines-pane">
          <div className="machines-pane-head">
            <span className="machines-pane-title">{openSession.title}</span>
            <span className="machines-pane-path">{openSession.cwd}</span>
            <button type="button" onClick={() => setOpen(null)}>
              Close
            </button>
          </div>
          <RemoteTerminal
            key={`${open.machineId}\u0000${open.sessionId}`}
            machineId={open.machineId}
            sessionId={open.sessionId}
            bridge={bridge}
            subscribe={subscribeFor(open.machineId, open.sessionId)}
            fontSize={fontSize}
            fontFamily={fontFamily}
          />
        </div>
      )}
    </section>
  )
}

/* ------------------------------------------------------------------- row -- */

export function MachineRow({
  machine,
  link,
  bridge,
  openSessionId,
  onOpen,
  onClose,
  onChanged,
}: {
  machine: Machine
  link: MachineLinkState
  bridge: MachinesBridge
  openSessionId: string | null
  onOpen(sessionId: string): void
  onClose(): void
  onChanged(view: MachinesView): void
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
          Approve {thisMachine()} on {machine.name}, under Devices. It will connect by itself once
          you have.
        </p>
      ) : (
        link.reason !== null && <p className="machines-reason">{link.reason}</p>
      )}

      <p className="machines-key" title="Compare this with the same six groups on that machine">
        {machine.fingerprint}
      </p>

      {link.state === 'online' && link.sessions.length === 0 && (
        <PageNote>Nothing is running on that {noun} right now.</PageNote>
      )}

      {link.sessions.length > 0 && (
        <ul className="machines-sessions">
          {link.sessions.map((session) => (
            <SessionRow
              key={session.id}
              session={session}
              open={session.id === openSessionId}
              onOpen={() => onOpen(session.id)}
              onClose={onClose}
            />
          ))}
        </ul>
      )}

      <div className="machines-actions">
        {offer.can && (
          <button
            type="button"
            onClick={() => {
              void bridge.createMachineSession(machine.id, link.folders?.[0] ?? '')
            }}
          >
            New session
          </button>
        )}
        {link.state === 'online' || link.state === 'connecting' ? (
          <button
            type="button"
            onClick={() => {
              void bridge.disconnectMachine(machine.id).then((next) => onChanged(asView(next)))
            }}
          >
            Disconnect
          </button>
        ) : (
          <button
            type="button"
            onClick={() => {
              void bridge.connectMachine(machine.id).then((next) => onChanged(asView(next)))
            }}
          >
            Connect
          </button>
        )}
        {confirming ? (
          <>
            <span className="machines-confirm">
              Forget this {noun}? You would pair it again from scratch.
            </span>
            <button
              type="button"
              className="machines-danger"
              onClick={() => {
                setConfirming(false)
                void bridge.forgetMachine(machine.id).then((next) => onChanged(asView(next)))
              }}
            >
              Forget
            </button>
            <button type="button" onClick={() => setConfirming(false)}>
              Keep
            </button>
          </>
        ) : (
          <button type="button" onClick={() => setConfirming(true)}>
            Forget
          </button>
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
