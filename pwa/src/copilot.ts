/**
 * The copilot, as a browser tab holds one.
 *
 * ## Why this file exists at all
 *
 * Because it did not, and he asked for it. `REVIEW-2026-08-17.md` part 4 ends
 * *"all of the above applies to the web app too, not just the desktop"*, and the
 * whole of part 4 is about the copilot. Measured before any of this was written:
 * `pwa/src` contained zero occurrences of the word. There was no surface to
 * attach anything to, so this is a build rather than a port.
 *
 * ## The one rule that shapes everything below: it is a **separate connection**
 *
 * A browser paired to run terminals has no copilot reach whatsoever — not a tab,
 * not a frame, not a refusal it could measure — until somebody at the machine
 * mints a copilot code and it is redeemed here. `src/main/remote/copilot-link.ts`
 * carries the argument and it is his sentence that settled it:
 *
 *   > *"Phones will have full control over copilot, same as the actual machine
 *   > app. But connecting copilot will be a separate connection than the
 *   > sessions."*
 *
 * Three consequences this module is built around, and getting any of them wrong
 * is a client that ships broken:
 *
 *  1. **`welcome.copilot.open` is always false.** A reconnect has `linked: true`
 *     and `open: false` until `copilot.hello` is sent again. A client that
 *     treated the welcome as "already in" would send frames that are all refused.
 *  2. **The credential arrives exactly once**, in `copilot.linked`, and the
 *     desktop keeps only a scrypt hash of it. A browser that loses it asks for a
 *     new code; there is no frame that will hand it over again.
 *  3. **A guest never has any of this.** The desktop does not advertise the
 *     `copilot` capability to a device that is not the owner's own, so
 *     {@link copilotOffered} is false and the tab is *absent* — never drawn and
 *     disabled. His words, about the public demo box: *"we don't want to give
 *     this copilot to others to see how we use it."*
 *
 * ## Controls come off the grant, never off the capability
 *
 * `read` is a watching grant and carries no new power: what is my copilot doing,
 * what did it start, what was it refused. `act` is Start, the message box,
 * Cancel and Stop — talking to the copilot spends money and causes tool calls.
 * `alter` is the Allow/Refuse pair on a confirmation, and nothing else.
 * `COPILOT_FRAME_TIER` on the desktop is what is actually enforced; this file
 * draws from the same three booleans so that a control is never offered for a
 * frame that would be refused.
 *
 * ## No DOM, no timers, no socket
 *
 * Same shape as `localhost.ts` next door and for the same reason: every branch
 * returns the frames it wants sent rather than sending them, so the wire traffic
 * is assertable from a test with no browser in it. The caller's only job is to
 * put them on the socket in order, persist a credential when one comes back, and
 * redraw.
 */

import {
  CAPABILITY,
  MAX_COPILOT_CREDENTIAL_CHARS,
  copilotSayFits,
  type ClientMessage,
  type CopilotActionRow,
  type CopilotChatMessage,
  type CopilotConsentQuestion,
  type CopilotGrantWire,
  type CopilotLinkWire,
  type CopilotPendingRow,
  type CopilotSessionRow,
  type CopilotStateReport,
  type ServerMessage,
} from './protocol-client'

/* ----------------------------------------------------------------- state -- */

export const NO_GRANT: CopilotGrantWire = { read: false, act: false, alter: false }

/**
 * Not linked, not open, nothing granted.
 *
 * The same value stands for two different facts — *this desktop has no copilot*
 * and *this desktop has one and this browser has not been connected to it* — and
 * that is safe only because {@link CopilotState.offered} is what tells them
 * apart. Folding the two would draw a Connect screen against a machine with
 * nothing to connect to.
 */
export const NO_LINK: CopilotLinkWire = { linked: false, open: false, grant: NO_GRANT }

export interface CopilotState {
  /** Did this desktop advertise `copilot` to *this* device. See the header. */
  offered: boolean
  link: CopilotLinkWire
  /** A `copilot.connect` is on the wire and has not been answered. */
  connecting: boolean
  /**
   * The last state report, or null when none has arrived.
   *
   * Null is not "stopped". A screen that read it as stopped would offer to start
   * something it has not been told anything about, which is the same class of
   * mistake as a live-looking cursor over a dead socket.
   */
  report: CopilotStateReport | null
  /**
   * Which run the held conversation belongs to, so a frame from a previous one
   * is dropped rather than merged.
   *
   * The protocol says why in as many words: without it a client that reconnected
   * after the grace window expired would splice the end of a dead conversation
   * onto the start of a live one, and the person would read an answer to a
   * question they never asked in this run.
   */
  run: string | null
  /** Oldest first, merged by id — see {@link mergeChat}. */
  chat: readonly CopilotChatMessage[]
  /** Tool calls as they happen, newest last, bounded by {@link MAX_TOOL_ROWS}. */
  tools: readonly CopilotActionRow[]
  sessions: readonly CopilotSessionRow[]
  pending: readonly CopilotPendingRow[]
  /** The one confirmation this connection may answer, or null. */
  ask: CopilotConsentQuestion | null
  /** A `copilot.say` is on the wire and its bubble has not come back yet. */
  sending: boolean
  /**
   * One sentence about the last thing that happened, or null.
   *
   * Never invented here when the desktop sent words of its own: a refusal is
   * explained in the machine's wording, because the machine is the only party
   * that knows why it refused.
   */
  notice: string | null
}

export const NO_COPILOT: CopilotState = {
  offered: false,
  link: NO_LINK,
  connecting: false,
  report: null,
  run: null,
  chat: [],
  tools: [],
  sessions: [],
  pending: [],
  ask: null,
  sending: false,
  notice: null,
}

/**
 * How many tool rows the live list keeps.
 *
 * The action log on the machine is a file and can be thousands of lines; this is
 * the *live* view of it, which is a different thing — it is what the copilot has
 * done since this browser started watching. Sixty rows is more than a phone
 * screen holds and few enough that a copilot in a tight loop cannot grow this
 * array without bound in a tab somebody leaves open overnight.
 *
 * Trimmed from the **front**, so the newest are always the ones kept.
 */
export const MAX_TOOL_ROWS = 60

/* --------------------------------------------------------------- actions -- */

export type CopilotAction =
  /**
   * A `welcome` arrived: this is what the desktop advertised, and this is the
   * copilot credential this browser holds for it, if any.
   *
   * Sending `copilot.hello` from here rather than from a later tap is the whole
   * of point 3 in the header — a copilot connection is not carried by a session
   * channel existing, and every reconnect has to open it again.
   */
  | { t: 'welcome'; capabilities: readonly string[]; link: CopilotLinkWire | null; credential: string | null }
  /** Six digits, typed. */
  | { t: 'connect'; code: string }
  /** Start watching: state, sessions, pending and the conversation. */
  | { t: 'attach' }
  | { t: 'detach' }
  /** Start this device's own run. */
  | { t: 'start' }
  | { t: 'say'; text: string }
  | { t: 'cancel' }
  | { t: 'stop' }
  | { t: 'answer'; id: string; approved: boolean }
  /** Leave the copilot connection, without touching the pairing. */
  | { t: 'bye' }
  | { t: 'frame'; message: ServerMessage }
  /** The socket went down. */
  | { t: 'offline' }
  /** The person dismissed the sentence on screen. */
  | { t: 'clear' }

export interface CopilotStep {
  state: CopilotState
  /** Frames to put on the wire, in order. Empty is the common case. */
  send: ClientMessage[]
  /**
   * A copilot credential to persist, when one has just been handed over.
   *
   * Carried out rather than written here because this module owns no storage and
   * must not: the answer to *where does a secret live in this browser* is
   * `remember.ts`'s, and it depends on what the person said about whether this
   * computer is theirs.
   */
  credential?: string
}

function still(state: CopilotState): CopilotStep {
  return { state, send: [] }
}

/* --------------------------------------------------------------- offered -- */

/**
 * Did this desktop tell *this* device that it has a copilot.
 *
 * The capability is filtered per device on the machine — a guest is never told —
 * so this is the whole of the guest rule on this side. There is no second check
 * anywhere in this client, deliberately: a client that drew the tab and then
 * hid the controls would have made a claim about somebody else's machine that
 * the machine went out of its way not to make.
 */
export function copilotOffered(capabilities: readonly string[]): boolean {
  return capabilities.includes(CAPABILITY.copilot)
}

/* --------------------------------------------------------------- the run -- */

/**
 * One transition.
 *
 * Every outbound frame in this feature is gated twice — once on the connection
 * being open and once on the tier the verb needs — and both gates are here
 * rather than at the call sites. The desktop enforces the same table
 * (`COPILOT_FRAME_TIER`), so this is not the security boundary; it is what stops
 * a control ever being *offered* for a frame that would come back refused, which
 * is the standing rule this whole review turns on.
 */
export function copilotStep(state: CopilotState, action: CopilotAction): CopilotStep {
  switch (action.t) {
    case 'welcome': {
      const offered = copilotOffered(action.capabilities)
      if (!offered) {
        // Everything held about a copilot is about *that* machine, so a desktop
        // that no longer offers one — a different machine on the same pairing,
        // or one launched with a narrower offer — leaves nothing behind.
        return still({ ...NO_COPILOT })
      }
      // `open` is forced false whatever the welcome said. The desktop always
      // sends false here and the note in `CopilotLinkWire` says a client that
      // believes otherwise sends frames that are all refused; taking the value
      // on trust would make this client's correctness depend on the far end
      // never having a bug.
      const link: CopilotLinkWire = { ...(action.link ?? NO_LINK), open: false }
      const opened: CopilotState = {
        ...NO_COPILOT,
        offered: true,
        link,
        // The conversation is not carried across a reconnect. A `copilot.attach`
        // answers with the whole thing and `reset` on that frame is what says so;
        // keeping the old bubbles would show a run that may have ended while the
        // socket was down.
        notice: state.notice,
      }
      if (!link.linked || action.credential === null || action.credential === '') return still(opened)
      if (action.credential.length > MAX_COPILOT_CREDENTIAL_CHARS) {
        // Stored rubbish rather than a credential — a hand-edited store, or a
        // format from a build that is not this one. Refused here rather than put
        // on the wire, because the desktop counts failed credential attempts.
        return still({ ...opened, notice: 'The copilot connection on this browser is unreadable. Connect it again.' })
      }
      return { state: opened, send: [{ t: 'copilot.hello', credential: action.credential }] }
    }

    case 'connect': {
      if (!state.offered || state.connecting) return still(state)
      return {
        state: { ...state, connecting: true, notice: null },
        send: [{ t: 'copilot.connect', code: action.code }],
      }
    }

    case 'attach': {
      // Every one of these is a `read`-tier verb, so an open connection with no
      // read grant asks for nothing at all rather than asking and being refused
      // four times.
      if (!state.link.open || !state.link.grant.read) return still(state)
      return {
        state,
        send: [
          { t: 'copilot.attach' },
          { t: 'copilot.state' },
          { t: 'copilot.sessions' },
          { t: 'copilot.pending' },
        ],
      }
    }

    case 'detach':
      if (!state.link.open) return still(state)
      return { state, send: [{ t: 'copilot.detach' }] }

    case 'start':
      if (!canAct(state)) return still(state)
      return { state: { ...state, notice: null }, send: [{ t: 'copilot.start' }] }

    case 'say': {
      if (!canAct(state) || state.sending) return still(state)
      const text = action.text.trim()
      if (text === '') return still(state)
      if (!copilotSayFits(text)) {
        // Refused here rather than sent and refused there, and **not chunked**.
        // A paste into a terminal is a stream and half of one is still half a
        // paste; half a sentence to an agent is a different sentence.
        return still({ ...state, notice: 'That message is too long to send. Shorten it and try again.' })
      }
      return { state: { ...state, sending: true, notice: null }, send: [{ t: 'copilot.say', text }] }
    }

    case 'cancel':
      if (!canAct(state)) return still(state)
      return { state, send: [{ t: 'copilot.cancel' }] }

    case 'stop':
      if (!canAct(state)) return still(state)
      return { state, send: [{ t: 'copilot.stop' }] }

    case 'answer': {
      // `alter`, and only `alter`. A connection that may not perform alter-tier
      // work has no business deciding whether alter-tier work happens — letting
      // a watching device answer would make the read tier a way to authorise
      // everything the act tier refuses.
      if (!state.link.open || !state.link.grant.alter) return still(state)
      if (state.ask === null || state.ask.id !== action.id) return still(state)
      // The sheet closes on the send rather than on the `copilot.settled` that
      // follows. Two people can answer one question and first answer wins; a
      // sheet that stayed up until the round trip would take a second press,
      // and the second press is a decision about a question that is already
      // closed.
      return { state: { ...state, ask: null }, send: [{ t: 'copilot.answer', id: action.id, approved: action.approved }] }
    }

    case 'bye': {
      if (!state.link.open) return still(state)
      return {
        state: { ...state, link: { ...state.link, open: false }, chat: [], tools: [], ask: null, run: null },
        send: [{ t: 'copilot.bye' }],
      }
    }

    case 'offline':
      // The connection is gone with the socket. `linked` survives — it is a fact
      // about a record on the machine, not about this socket — so the next
      // welcome sends a hello rather than asking for a code that is not needed.
      return still({
        ...state,
        link: { ...state.link, open: false },
        connecting: false,
        sending: false,
        ask: null,
      })

    case 'clear':
      return still(state.notice === null ? state : { ...state, notice: null })

    case 'frame':
      return frame(state, action.message)
  }
}

/** Open, granted `act`, and therefore able to press a button that will work. */
function canAct(state: CopilotState): boolean {
  return state.link.open && state.link.grant.act
}

/* ---------------------------------------------------------------- frames -- */

function frame(state: CopilotState, message: ServerMessage): CopilotStep {
  switch (message.t) {
    case 'copilot.linked': {
      // The credential goes out to be stored, and the connection is open from
      // this instant: the desktop answers a connect by opening the socket's
      // copilot connection as well as minting the record, so a client that
      // waited for a hello would ask for a second one it does not need.
      return {
        state: { ...state, connecting: false, link: message.link, notice: null },
        send: openingFrames(message.link),
        credential: message.credential,
      }
    }

    case 'copilot.grant': {
      const wasOpen = state.link.open
      const next: CopilotState = { ...state, connecting: false, link: message.link }
      // A grant that closes the connection — a disconnect at the machine — takes
      // the conversation with it. Leaving the bubbles up would be a screen
      // showing a copilot this browser can no longer reach.
      if (!message.link.open) {
        return still({ ...next, chat: [], tools: [], ask: null, run: null, sending: false })
      }
      // Opening is where the watching starts, and only on the transition: a
      // regrant that arrives while already open must not re-ask for everything.
      return wasOpen ? still(next) : { state: next, send: openingFrames(message.link) }
    }

    case 'copilot.state':
      return still({ ...state, report: message.state, link: { ...state.link, grant: message.state.grant } })

    case 'copilot.chat': {
      // A frame from a run this client is not holding replaces rather than
      // merges. `reset` says so explicitly; a different run id says the same
      // thing without having been told, which is the case the field exists for.
      const fresh = message.reset === true || state.run !== message.run
      const chat = fresh ? [...message.messages] : mergeChat(state.chat, message.messages)
      // The composer unlocks when the person's own words come back, not when
      // the agent answers: that is the moment the message is known to have
      // landed, and waiting for the reply would leave the box dead for as long
      // as a turn takes.
      const echoed = message.messages.some((row) => row.role === 'you')
      return still({ ...state, run: message.run, chat, sending: state.sending && !echoed })
    }

    case 'copilot.tool': {
      const tools = [...state.tools, message.row]
      return still({ ...state, tools: tools.slice(Math.max(0, tools.length - MAX_TOOL_ROWS)) })
    }

    case 'copilot.sessions':
      return still({ ...state, sessions: message.sessions })

    case 'copilot.pending':
      return still({ ...state, pending: message.questions })

    case 'copilot.ask':
      // Only ever sent to the surface that owns the run that raised it, so this
      // is a question this connection may answer. Everything else that is
      // waiting arrives as a `copilot.pending` row with `mine: false`, which is
      // a notice and not a decision.
      return still({ ...state, ask: message.question })

    case 'copilot.settled': {
      if (state.ask !== null && state.ask.id === message.settled.id) {
        // Withdrawn **saying where it went**. A dialog that vanishes on its own
        // teaches a person that the app does things behind their back, which is
        // the one lesson a permission prompt must never teach.
        return still({ ...state, ask: null, notice: settledSentence(message.settled) })
      }
      return still({
        ...state,
        pending: state.pending.filter((row) => row.id !== message.settled.id),
      })
    }

    case 'error':
      // Every copilot verb this client sends is gated on the grant before it
      // goes, so an `unauthorized` here is the machine having changed its mind
      // between the draw and the tap — which is exactly what the sentence should
      // say, in the machine's own words rather than in one composed here.
      if (!state.connecting && !state.sending) return still(state)
      return still({
        ...state,
        connecting: false,
        sending: false,
        notice: message.message !== '' ? message.message : 'The machine refused that.',
      })

    default:
      return still(state)
  }
}

/**
 * What to ask for the moment a copilot connection opens.
 *
 * Gated on `read` rather than sent unconditionally, because a connection can be
 * opened with no watching grant at all — `act` without `read` is a legal, if
 * unusual, thing to have been given — and four frames that would each be refused
 * is four refusals on a screen that has just been told it is connected.
 */
function openingFrames(link: CopilotLinkWire): ClientMessage[] {
  if (!link.grant.read) return []
  return [{ t: 'copilot.attach' }, { t: 'copilot.state' }, { t: 'copilot.sessions' }, { t: 'copilot.pending' }]
}

/**
 * Merge a chat frame into what is held: replace a match, append otherwise.
 *
 * An agent's answer arrives in pieces under one id and grows, so a client that
 * appended would stack a paragraph at a time — the same bubble four times, each
 * a little longer. Replacing in place is what makes it read as one message being
 * written.
 */
export function mergeChat(
  held: readonly CopilotChatMessage[],
  arriving: readonly CopilotChatMessage[],
): CopilotChatMessage[] {
  const next = [...held]
  for (const row of arriving) {
    const at = next.findIndex((entry) => entry.id === row.id)
    if (at === -1) next.push(row)
    else next[at] = row
  }
  return next
}

/* ------------------------------------------------------------- sentences -- */

/**
 * Where a confirmation was answered, in words.
 *
 * `by` is `'window'`, `device:<id>`, or null for a timeout, and the three read
 * differently on purpose: *the machine answered this* and *another of your
 * devices answered this* are different events, and *nobody answered* is a
 * refusal that happened by default rather than by decision.
 */
export function settledSentence(settled: { granted: boolean; by: string | null; reason: string | null }): string {
  if (settled.by === null) {
    return 'Nobody answered in time, so it was refused.'
  }
  const where = settled.by === 'window' ? 'at the machine' : 'on another of your devices'
  if (settled.granted) return `Allowed ${where}.`
  return settled.reason !== null ? `Refused ${where} — ${settled.reason}.` : `Refused ${where}.`
}

/**
 * What the desk is doing, in a word somebody reads rather than a status code.
 *
 * `desk` is the copilot pinned at the machine — the conversation the person is
 * having there — and it is deliberately not the same thing as this device's own
 * run. A screen that showed one on the other's Start button would offer to start
 * something that is already running, or refuse to because something unrelated is.
 */
export function deskSentence(report: CopilotStateReport | null): string {
  if (report === null) return 'Asking the machine…'
  switch (report.desk) {
    case 'running':
      return 'The copilot is running at the machine.'
    case 'starting':
      return 'The copilot is starting at the machine.'
    case 'stopped':
      return 'The copilot is not running at the machine.'
  }
}

/**
 * Why Start cannot act, or null when it can.
 *
 * The desktop composes this: it is the only party that knows whether there is an
 * agent installed, whether it is signed in and whether the folder can be written
 * to. A sentence written here would be a guess about somebody else's computer.
 */
export function unavailableSentence(report: CopilotStateReport | null): string | null {
  if (report === null) return null
  if (report.available) return null
  return report.reason ?? 'The machine cannot start a copilot run right now.'
}

/**
 * The one line under the tier controls, when there is something to say.
 *
 * A connection with `read` and nothing else is the grant worth handing out first
 * — *what is my copilot doing, what did it start, what was it refused* — and it
 * is also the one that looks broken if nothing explains the missing composer. So
 * the absence of a control is stated rather than left as a gap.
 */
export function grantSentence(grant: CopilotGrantWire): string | null {
  if (grant.act) return null
  if (grant.read) return 'This browser can watch the copilot. Talking to it was not granted.'
  return 'This browser is connected to the copilot but was granted nothing yet.'
}

/**
 * How a pending confirmation reads to a device that may not answer it.
 *
 * Watching a question is not judging it, and the row deliberately carries no
 * arguments — a device that cannot answer has no decision to make with them. The
 * value of seeing it at all is the failure the design named: a dialog on a screen
 * nobody is looking at, timing out in silence two minutes later.
 */
export const GO_AND_LOOK = 'Waiting at the machine. Only the machine can answer this one.'

/** Seconds left before a question refuses itself, floored at zero. */
export function secondsLeft(expiresAt: number, now: number): number {
  return Math.max(0, Math.ceil((expiresAt - now) / 1000))
}
