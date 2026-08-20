import { useCallback, useEffect, useMemo, useState } from 'react'
import { PageEmpty } from '../components/PageEmpty'
import { COPILOT_ICON } from './identity'
import {
  applyChat,
  readChatFrame,
  readStateReport,
  type RemoteBubble,
  type RemoteReport,
} from './remote-copilot-model'
import type { CopilotReach } from './useCopilotMachines'
import './copilot.css'

/**
 * The copilot on **another** machine, in this window.
 *
 * ## What this is a view of, and what it is deliberately not
 *
 * Not the far machine's own copilot conversation. `remote/protocol.ts` is
 * explicit about the shape and the reason: a remote device gets **its own run**
 * on that machine — `CopilotStateReport.run` — and watches the desk copilot's
 * liveness separately, because *"a phone that showed the desk's state on its own
 * Start button would offer to start something that is already running, or refuse
 * to because something unrelated is."* The same holds for a Mac looking at a PC.
 *
 * So this is a conversation with a copilot **running on that machine, in that
 * machine's folders, as that machine's account** — which is the whole of what
 * Asad asked for when he asked for a machine switch on this page.
 *
 * ## Why it is bubbles and not a terminal
 *
 * Because the far machine will not give anybody a terminal onto a copilot, and
 * that refusal is one of the load-bearing rules in this codebase.
 * `remote/hidden-sessions.ts` hides every copilot pty from the network by id,
 * for the reason its header states at length: a pty is a keyboard, and a
 * keyboard sits past the per-device grant, past every tier, past every budget
 * and every confirmation dialog. *"The phone gets parsed `ChatMessage`s, never
 * bytes."*
 *
 * Which is why the local copilot has a terminal in this window and the remote
 * one has none, and why that asymmetry is correct rather than unfinished.
 *
 * ## The three states, and why Start is a state rather than something automatic
 *
 * A run is a coding agent spawned on somebody's computer, and it bills for what
 * it does. Attaching to watch is free and happens the moment this pane opens;
 * *starting* is an act with a cost, so it is a button. That is the same decision
 * `useCopilot` makes about the local copilot — nothing starts it at launch,
 * because *"starting it at launch would put a standing charge on opening the app
 * for an assistant nobody had asked anything."*
 */

interface Props {
  machineId: string
  machineName: string
  /**
   * What the switch knew about this machine when the row was pressed.
   *
   * Here because the row that chose it no longer refuses the press. Until
   * 2026-08-20 an offline machine and one that paired this computer as a guest
   * were greyed out on the switch with the reason on hover, and Asad's sentence
   * about that switch was *"here icon not still choose the local connected
   * server"* — he pressed, nothing happened, and he was left guessing whether
   * the machine was even connected. Every row is pressable now, so the two
   * answers have to arrive somewhere, and this is the pane he is looking at when
   * he asks.
   *
   * They are two answers rather than one because they are two different facts:
   * a machine that is offline has not been asked, and a machine that is online
   * and sent no copilot link has answered. `useCopilotMachines` carries why
   * collapsing those would be the app claiming something it has not been told —
   * and the second answer is worded about the *offer* rather than about the
   * pairing, for the same reason, since the far end sends the same frame for
   * *"you are a guest"* and *"this host has no copilot."*
   */
  reach: CopilotReach
  /**
   * That link has said `copilot.hello` on its current socket.
   *
   * A prop rather than something read here, because the machines view is
   * already being watched one component up and two subscriptions to the same
   * push is two answers to one question. What it is *for* is the re-attach: it
   * goes false on every reconnect and true a round trip later, and this pane has
   * to ask again when it does or it is looking at a socket that has been
   * replaced underneath it.
   */
  open: boolean
  /** Injectable for tests and the harness; defaults to the preload bridge. */
  bridge?: RemoteCopilotBridge | null
}

export interface RemoteCopilotBridge {
  attachMachineCopilot(machineId: string): Promise<unknown>
  startMachineCopilot(machineId: string): Promise<unknown>
  sayToMachineCopilot(machineId: string, text: string): Promise<unknown>
  onMachineCopilotChat(callback: (machineId: string, frame: unknown) => void): () => void
  onMachineCopilotState(callback: (machineId: string, state: unknown) => void): () => void
}

const METHODS = [
  'attachMachineCopilot',
  'startMachineCopilot',
  'sayToMachineCopilot',
  'onMachineCopilotChat',
  'onMachineCopilotState',
] as const satisfies readonly (keyof RemoteCopilotBridge)[]

function resolveBridge(): RemoteCopilotBridge | null {
  const deck = (globalThis as { deck?: Record<string, unknown> }).deck
  if (!deck) return null
  return METHODS.every((method) => typeof deck[method] === 'function')
    ? (deck as unknown as RemoteCopilotBridge)
    : null
}

/** What a call over the bridge answered, read defensively. */
function outcome(value: unknown): { ok: boolean; message: string } {
  if (typeof value !== 'object' || value === null) return { ok: false, message: '' }
  const record = value as Record<string, unknown>
  return {
    ok: record.ok === true,
    message: typeof record.message === 'string' ? record.message : '',
  }
}

export function RemoteCopilot({ machineId, machineName, reach, open, bridge }: Props) {
  const deck = useMemo(() => (bridge === undefined ? resolveBridge() : bridge), [bridge])
  const [report, setReport] = useState<RemoteReport | null>(null)
  const [bubbles, setBubbles] = useState<RemoteBubble[]>([])
  const [typed, setTyped] = useState('')
  const [problem, setProblem] = useState('')
  const [busy, setBusy] = useState(false)

  /*
   * Everything about the previous machine goes the moment the choice changes.
   *
   * Not a nicety. The conversation and the state are facts about one machine, and
   * carrying either across a switch would put one computer's transcript on screen
   * under another computer's name for as long as the first frame takes to
   * arrive. `pwa/src/main.ts` makes the same clearance for the same reason and
   * calls it the sharpest case of the rule.
   */
  useEffect(() => {
    setReport(null)
    setBubbles([])
    setProblem('')
  }, [machineId])

  useEffect(() => {
    if (!deck) return
    // Nothing to attach to until the far end has taken this socket's
    // `copilot.hello`; every `copilot.*` verb is refused before that, the
    // read-only ones included. Re-runs when it flips, which is what makes a
    // reconnect recover on its own.
    if (!open) return
    const offChat = deck.onMachineCopilotChat((id, frame) => {
      if (id !== machineId) return
      const parsed = readChatFrame(frame)
      if (parsed) setBubbles((current) => applyChat(current, parsed))
    })
    const offState = deck.onMachineCopilotState((id, state) => {
      if (id !== machineId) return
      const parsed = readStateReport(state)
      if (parsed) setReport(parsed)
    })
    // Attaching is what makes the far end start pushing both of the above, so it
    // goes after the subscriptions rather than before — the state frame comes
    // back on the attach itself, and a subscription made afterwards would miss
    // exactly the frame that tells this pane what it is looking at.
    void deck
      .attachMachineCopilot(machineId)
      .then((value) => {
        const answer = outcome(value)
        if (!answer.ok) setProblem(answer.message || `${machineName} did not answer.`)
      })
      .catch(() => setProblem(`${machineName} did not answer.`))
    return () => {
      offChat()
      offState()
    }
  }, [deck, machineId, machineName, open])

  const start = useCallback(() => {
    if (!deck) return
    setBusy(true)
    setProblem('')
    void deck
      .startMachineCopilot(machineId)
      .then((value) => {
        const answer = outcome(value)
        if (!answer.ok) setProblem(answer.message || `${machineName} would not start it.`)
      })
      .catch(() => setProblem(`${machineName} would not start it.`))
      .finally(() => setBusy(false))
  }, [deck, machineId, machineName])

  const say = useCallback(() => {
    const line = typed.trim()
    if (!deck || !line || busy) return
    setBusy(true)
    setProblem('')
    void deck
      .sayToMachineCopilot(machineId, line)
      .then((value) => {
        const answer = outcome(value)
        // The field is cleared only once it landed. There is no worse moment to
        // lose somebody's sentence than the moment they were told it did not
        // arrive.
        if (answer.ok) setTyped('')
        else setProblem(answer.message || `${machineName} refused it.`)
      })
      .catch(() => setProblem(`${machineName} did not answer.`))
      .finally(() => setBusy(false))
  }, [deck, machineId, machineName, typed, busy])

  if (!deck) {
    return (
      <PageEmpty icon={COPILOT_ICON} title="This build cannot reach another machine's copilot">
        Update this app on both computers.
      </PageEmpty>
    )
  }

  /*
   * The two answers the switch used to give on hover, given here instead.
   *
   * A title and nothing under it, in both cases. The condition is the whole
   * fact, and a paragraph explaining what a guest pairing is would be the habit
   * this week has been spent deleting: *"we don't need to give the statements.
   * We want simplicity."* Neither is a dead end — the rail pairs and re-pairs a
   * machine, and this row goes back to being ordinary the moment it does,
   * because the switch is watching the same push.
   */
  if (reach === 'unreachable') {
    return <PageEmpty icon={COPILOT_ICON} title={`${machineName} is not connected`} />
  }
  if (reach === 'refused') {
    /*
     * Said about the *offer*, not about the pairing, and that wording is
     * load-bearing. `protocol.ts` on the far side: **absent means this host has
     * none** — a machine that paired this computer as a guest and a machine that
     * has no copilot at all send the identical frame, deliberately, *"because an
     * advertised thing a device may not use invites the ask."* A headless host
     * is the second one and Asad runs one. So naming a guest pairing here would
     * be this window asserting which of two it is, having been told neither,
     * which is the failure `useCopilotMachines` refuses one level up.
     */
    return (
      <PageEmpty
        icon={COPILOT_ICON}
        title={`${machineName} is not offering its copilot to this computer`}
      />
    )
  }

  /*
   * Nothing has come back yet.
   *
   * Drawn rather than skipped past, because the alternative is a composer with
   * no run behind it: `run` is null until the far machine says otherwise, and a
   * field somebody can type into that cannot reach anything is exactly the dead
   * control this app keeps removing. One round trip, and then this is replaced
   * by Start or by the conversation.
   */
  if (report === null) {
    return (
      <PageEmpty icon={COPILOT_ICON} title={`Reaching ${machineName}…`}>
        {problem}
      </PageEmpty>
    )
  }

  if (report.run === null) {
    return (
      <PageEmpty
        icon={COPILOT_ICON}
        title={`No copilot running for you on ${machineName}`}
        action={{ label: busy ? 'Starting…' : 'Start it', onClick: start, primary: true }}
      >
        {problem || `It runs there, in that computer's folders, as that computer's account.`}
      </PageEmpty>
    )
  }

  return (
    <div className="cp-remote">
      <div className="cp-remote-log scroll-fade">
        {bubbles.map((bubble) => (
          <div key={bubble.id} className="cp-bubble" data-role={bubble.role}>
            {bubble.text}
          </div>
        ))}
      </div>
      {problem !== '' && (
        <p className="cp-remote-problem" role="status">
          {problem}
        </p>
      )}
      <div className="cp-remote-ask">
        <input
          className="cp-remote-field"
          type="text"
          value={typed}
          aria-label={`Ask the copilot on ${machineName}`}
          placeholder={`Ask the copilot on ${machineName}`}
          onChange={(event) => setTyped(event.target.value)}
          onKeyDown={(event) => {
            if (event.key !== 'Enter') return
            event.preventDefault()
            say()
          }}
        />
        <button
          type="button"
          className="cp-btn"
          disabled={busy || typed.trim() === ''}
          onClick={say}
        >
          Send
        </button>
      </div>
    </div>
  )
}
