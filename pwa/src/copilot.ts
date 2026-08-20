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
 * ## The one rule that shapes everything below: **pairing is the whole of it**
 *
 * This module used to open with the opposite sentence. A copilot connection was
 * a *separate* connection with its own six-digit code, its own credential and
 * its own record, and a browser paired to run terminals had no copilot reach at
 * all until somebody minted a second code at the machine and it was redeemed
 * here. That is deleted, on 2026-08-19, in his words:
 *
 *   > *"instead of giving mobile app separate connection for copilot just make
 *   > it like if we are connecting as my device copilot automatically comes, if
 *   > we connect as guest then copilot don't come — that's all we need to do
 *   > instead of two different connections"*
 *
 * The second ceremony proved a fact the first one had already established. A
 * device's **kind** is decided by a person at that keyboard when they approve
 * it, it cannot be changed without pairing again, and the approval screen says
 * so in the wording that is already his: *"My device — Full access. It's you at
 * another keyboard."* against *"Guest — You choose what they can reach. The
 * copilot is never shared."* Asking for six more digits on top of that was
 * asking somebody to say yes twice to the same question.
 *
 * Three consequences this module is built around, and getting any of them wrong
 * is a client that ships broken:
 *
 *  1. **The copilot is present or absent, never pending.** `welcome.copilot` is
 *     sent to one of his own devices and is *absent* — not false — for a guest.
 *     There is no third state in which a device is paired and the copilot is
 *     "not connected yet", so there is no screen for one and no code field.
 *  2. **`welcome.copilot.open` is still always false**, and `copilot.hello` is
 *     still sent on every socket. What changed is that it carries nothing: the
 *     socket is already authenticated as this device, and the machine reads the
 *     device's kind rather than a secret. A session channel does not carry the
 *     copilot by existing, and a client that read the welcome as "already in"
 *     would send frames that are all refused.
 *  3. **Nothing is stored.** There is no copilot credential in this browser, so
 *     there is nothing to persist, nothing to clear when a machine is forgotten,
 *     and nothing left behind on a computer somebody does not own. The old
 *     `copilot-store.ts` is deleted; `remember.ts` sweeps the key it wrote.
 *
 * ## Why the presence of the key, and not the capability string
 *
 * `welcome.capabilities` still names `copilot` and the client no longer reads
 * it, deliberately. Two signals for one question is two answers that can differ,
 * and the difference would land on the one screen where being wrong is a claim
 * about somebody else's machine: a tab drawn for a guest, or a tab withheld from
 * one of his own devices. The copilot key is the per-device answer — it is
 * filtered by kind at the machine — so it is the only thing asked here.
 *
 * ## Controls come off the grant, never off the presence
 *
 * A device that gets the key at all is now granted everything: `{read, act,
 * alter}`, all three, because *full access* is what "my device" means. The three
 * booleans are still **read off the wire** rather than assumed, and every
 * outbound frame is still gated on them. The machine is the authority on what it
 * will serve, this client's job is never to offer a control for a frame that
 * would come back refused, and a client that assumed the grant would be drawing
 * buttons from a value it made up.
 *
 * ## What a mismatched pair does
 *
 * `app.terminaldeck.dev` deploys on its own and the desktop somebody has
 * installed is whatever they last updated to, so a new client will meet an old
 * machine. It sends a bare `copilot.hello`, that machine refuses it for want of
 * a credential, and the refusal lands on screen in the machine's own words
 * through {@link CopilotState.notice} — which is why {@link CopilotState.opening}
 * exists at all. There is deliberately no fallback path: a client that kept the
 * old ceremony in reserve would be keeping the credential store, and the store
 * is the thing being deleted.
 *
 * ## No DOM, no timers, no socket
 *
 * Same shape as `localhost.ts` next door and for the same reason: every branch
 * returns the frames it wants sent rather than sending them, so the wire traffic
 * is assertable from a test with no browser in it. The caller's only job is to
 * put them on the socket in order and redraw.
 */

import {
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
 * How long a sent message may go unacknowledged before the box unlocks itself.
 *
 * ## Why there has to be a number here at all
 *
 * `sending` locks the composer and it used to have exactly one way out: the
 * person's own words coming back in a `copilot.chat`. That is the right signal
 * and it is not a guarantee — measured on 2026-08-20, a phone sent four
 * messages to a live run and none of them ever echoed, because the desktop was
 * typing them into the CLI's prompt without submitting them
 * (`main/remote/copilot-say.ts` is that fix). The composer stayed dead through
 * all four, through a reload, and through a fresh run. One unanswered message
 * locked the surface permanently, and nothing on screen said anything.
 *
 * The submit bug is fixed. This is the floor under it: whatever goes wrong
 * between here and a pty — a run that died, a machine that swallowed the frame,
 * a future version of the same mistake — costs one wait and not the session.
 *
 * ## Why thirty seconds
 *
 * The echo does not come back when the wire is quiet; it comes back when the
 * CLI has taken the turn. The first message to a device starts the run, so that
 * one waits for a cold agent CLI to boot and read an MCP config — several
 * seconds on this machine, more on a slow one. Thirty is comfortably past that
 * and is still a wait somebody sits through rather than gives up on.
 */
export const SAY_TIMEOUT_MS = 30_000

/** Nothing here, nothing open, nothing granted. */
export const NO_LINK: CopilotLinkWire = { linked: false, open: false, grant: NO_GRANT }

export interface CopilotState {
  /**
   * Did this machine's welcome carry a copilot for *this* device.
   *
   * The whole of the guest rule on this side, and the only thing that decides
   * whether a Copilot tab is drawn. False stands for two facts — *this machine
   * has no copilot* and *this device is a guest* — and folding them is safe
   * precisely because the client owes the same answer to both: draw nothing, say
   * nothing, and make no claim about a machine that went out of its way not to
   * make one.
   */
  offered: boolean
  /**
   * What the machine said this connection has.
   *
   * `open` and `grant` are what anything below reads. `linked` comes along
   * because it is on the wire, and nothing branches on it any more: a device
   * that receives this object at all is one the machine holds a copilot for, so
   * there is no longer a state in which it is false and the client has a screen
   * to draw about it.
   */
  link: CopilotLinkWire
  /**
   * A `copilot.hello` is on the wire and has not been answered.
   *
   * Not a second authorisation — there is none — but the window in which a
   * refusal is worth putting on screen. Without it an old machine's *"copilot.
   * hello without a credential"* would be swallowed and the tab would sit at
   * "Asking the machine…" with no explanation, which is the exact failure this
   * client exists not to produce.
   */
  opening: boolean
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
  opening: false,
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
   * A `welcome` arrived, carrying this device's copilot or carrying nothing.
   *
   * `link` is `welcome.copilot`, and null is the guest — and also the machine
   * with no copilot layer at all. The hello goes out from here rather than from
   * a later tap because a session channel does not carry the copilot by
   * existing: every socket, every reconnect, has to open it again.
   */
  | { t: 'welcome'; link: CopilotLinkWire | null }
  /** Start watching: state, sessions, pending and the conversation. */
  | { t: 'attach' }
  | { t: 'detach' }
  /** Start this device's own run. */
  | { t: 'start' }
  | { t: 'say'; text: string }
  /**
   * {@link SAY_TIMEOUT_MS} passed and the message never came back.
   *
   * Armed by the surface when `sending` goes true and cancelled when it goes
   * false, the same shape the confirmation countdown uses.
   */
  | { t: 'say-timeout' }
  | { t: 'cancel' }
  | { t: 'stop' }
  | { t: 'answer'; id: string; approved: boolean }
  | { t: 'frame'; message: ServerMessage }
  /** The socket went down. */
  | { t: 'offline' }
  /** The person dismissed the sentence on screen. */
  | { t: 'clear' }

export interface CopilotStep {
  state: CopilotState
  /** Frames to put on the wire, in order. Empty is the common case. */
  send: ClientMessage[]
}

function still(state: CopilotState): CopilotStep {
  return { state, send: [] }
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
      if (action.link === null) {
        // A guest, or a machine with no copilot at all, or a different machine
        // on the same pairing. Everything held is a statement about the one that
        // is no longer answering, so none of it survives.
        return still({ ...NO_COPILOT })
      }
      // `open` is forced false whatever the welcome said. The desktop always
      // sends false here and the note in `CopilotLinkWire` says a client that
      // believes otherwise sends frames that are all refused; taking the value
      // on trust would make this client's correctness depend on the far end
      // never having a bug.
      const link: CopilotLinkWire = { ...action.link, open: false }
      const opened: CopilotState = {
        ...NO_COPILOT,
        offered: true,
        link,
        opening: true,
        // The conversation is not carried across a reconnect. A `copilot.attach`
        // answers with the whole thing and `reset` on that frame is what says so;
        // keeping the old bubbles would show a run that may have ended while the
        // socket was down.
        notice: state.notice,
      }
      // Nothing to look up and nothing to decide: the socket has already proved
      // which device it is, and the machine reads that device's kind.
      return { state: opened, send: [{ t: 'copilot.hello' }] }
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

    case 'say-timeout': {
      if (!state.sending) return still(state)
      /*
       * Unlock, say one short thing, and **ask the machine what it has**.
       *
       * The re-ask is the useful half. A run whose process died is not reported
       * to anybody until something asks — `CopilotRuns.reap` runs on a read, not
       * on a clock — so a phone that only unlocked its box would go on offering
       * Send for a run that no longer exists. `copilot.state` makes the desktop
       * reap and answer, and a dead run comes back as `run: null`, which is
       * already the state that draws Start instead of Send.
       */
      return {
        state: { ...state, sending: false, notice: 'The copilot did not answer.' },
        send: state.link.open && state.link.grant.read ? [{ t: 'copilot.state' }] : [],
      }
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
      // everything the act tier refuses. One of his own devices holds all three,
      // so this gate never fires in practice; it stays because the grant is read
      // off the wire and the machine is the party that decides what is in it.
      if (!state.link.open || !state.link.grant.alter) return still(state)
      if (state.ask === null || state.ask.id !== action.id) return still(state)
      // The sheet closes on the send rather than on the `copilot.settled` that
      // follows. Two people can answer one question and first answer wins; a
      // sheet that stayed up until the round trip would take a second press,
      // and the second press is a decision about a question that is already
      // closed.
      return { state: { ...state, ask: null }, send: [{ t: 'copilot.answer', id: action.id, approved: action.approved }] }
    }

    case 'offline':
      // The connection is gone with the socket, and that is all that is gone:
      // whether this device reaches the copilot is a fact about how it was
      // paired, so the next welcome opens it again with a hello rather than
      // asking anybody for anything.
      return still({
        ...state,
        link: { ...state.link, open: false },
        opening: false,
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
    case 'copilot.grant': {
      const wasOpen = state.link.open
      const next: CopilotState = { ...state, opening: false, link: message.link }
      // A grant that closes the connection — this device revoked at the machine
      // — takes the conversation with it. Leaving the bubbles up would be a
      // screen showing a copilot this browser can no longer reach.
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
      // between the draw and the tap — or, on a hello, a machine old enough to
      // still want a credential. Either way the sentence is the machine's own
      // rather than one composed here.
      if (!state.opening && !state.sending) return still(state)
      return still({
        ...state,
        opening: false,
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
 * The one line under the copilot's status, when there is something to say.
 *
 * One of his own devices is granted all three tiers, so the common case is null
 * and this whole function is about the two that are not: a machine that has
 * narrowed what this device may do, and one that has not answered the hello yet.
 * Both look identical on screen — a missing composer — and the absence of a
 * control is worth stating rather than leaving as a gap.
 */
export function grantSentence(grant: CopilotGrantWire): string | null {
  if (grant.act) return null
  if (grant.read) return 'This browser can watch the copilot. Talking to it was not granted.'
  return 'This browser has not been granted anything on the copilot yet.'
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
