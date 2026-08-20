/**
 * This desktop, being somebody else's client.
 *
 * ## What this is the other half of
 *
 * `server.ts` is the host: it answers `hello`, decides who may attach, and
 * serves sessions. This file is the guest half of the same conversation — the
 * side a phone has always been — written for the main process so that a Mac can
 * open a session on a PC and the other way round.
 *
 * It is deliberately the *same protocol*. Nothing here is a machine-to-machine
 * dialect: the frames come from `remote/protocol.ts`, the parser is
 * `parseServerMessage` in that same file, and the host cannot tell a paired
 * desktop from a paired phone and does not try to. That is the uniform model
 * this feature is built on — every connected device is a device with folder
 * grants, and the rules are the rules whatever is holding it.
 *
 * ## Reconnecting is the normal state, not the error path
 *
 * A laptop sleeps, changes networks and moves between wifi and a hotspot, and
 * the relay itself restarts on deploys. Every one of those is a dead channel
 * that still looks alive. So a link that is *supposed* to be up redials with
 * exponential backoff and jitter, exactly the way `relay-client.ts` does on the
 * host side, and for the same reasons — including the jitter, because every
 * machine in the world reconnecting in the same millisecond after a relay
 * restart is how a relay gets knocked over twice.
 *
 * The backoff is also what makes approval work without polling anything. A
 * machine that has just paired is refused with "approve this device", and it is
 * already redialling on the same schedule as any other failure; when somebody
 * presses approve on the other machine, the next dial succeeds. There is no
 * timer watching for approval and nothing to switch off when it never comes.
 *
 * ## The one thing this file will not do
 *
 * It never writes to the store. `store.ts` owns what is on disk and `ipc.ts`
 * owns when a pairing is worth remembering; a connection that persisted its own
 * credential would be one that could persist a credential it got from a channel
 * that then failed its seal.
 */

import { randomUUID } from 'node:crypto'
import { hostname } from 'node:os'
import {
  CAPABILITY,
  PROTOCOL_VERSION,
  chunkInput,
  emptyUsageReading,
  parseClientMessage,
  parseServerMessage,
  serialize,
  type ClientMessage,
  type ControlName,
  type ControlReadingWire,
  type ControlsReadingWire,
  type CopilotLinkWire,
  type CopilotStateReport,
  type LocalPort,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
  type UsageWant,
} from '../protocol'
import type { LocalhostMessage } from '../tunnel'
import { dialMachine, type GuestChannel, type DialRequest } from './dial'
import { overPasteCap } from '../../../shared/paste-cap'
import type { MachineSecrets } from './store'
import { createUploadSender, type SendFileOutcome, type UploadProgress } from './upload-send'

/* -------------------------------------------------------------- constants -- */

/** First retry, before jitter. Short enough that a relay deploy is invisible. */
const BASE_BACKOFF_MS = 1000

/**
 * Longest wait between dials. A minute is the point past which somebody
 * watching the panel decides the feature is broken, and short enough that a
 * machine that was off for an hour is picked up within a minute of coming back.
 */
const MAX_BACKOFF_MS = 60_000

/** A link that held this long failed for a new reason, not the old one. */
const STABLE_MS = 60_000

/**
 * How long a `controls.read` may go unanswered before the promise is given up on.
 *
 * A read is passive on the far end — it parses a screen that has already been
 * written — so the only thing this is really waiting out is the relay. Long
 * enough that a phone-tethered laptop does not time out on a working answer,
 * short enough that a menu does not appear to hang: the bar simply keeps
 * whatever it last genuinely read, which is what the local path does when a read
 * fails too.
 */
const CONTROLS_READ_TIMEOUT_MS = 20_000

/**
 * And how long a `controls.apply` may. Deliberately much longer, because the far
 * end really is waiting.
 *
 * `SHIPPED_TIMINGS` in `agent-controls.ts` allows 2.5s for the typed command to
 * echo, 6s for the CLI to answer it, and — for the permission ring — 2.5s per
 * shift+tab across up to five stops. A ceiling below the far end's own would
 * report a failure for a change that then lands, which is the one outcome worse
 * than a slow menu: the chip would say the old value while the session moved.
 */
const CONTROLS_APPLY_TIMEOUT_MS = 60_000

/**
 * How long a cheap `usage.read` may go unanswered — the plan figure the far end
 * already holds, and the context window it reads off a file.
 *
 * The same twenty seconds a `controls.read` gets, and for the same reason: both
 * are passive over there, so the only thing really being waited out is the
 * relay, and a bar that gives up early simply keeps whatever it last genuinely
 * read.
 */
const USAGE_READ_TIMEOUT_MS = 20_000

/**
 * And how long a `usage.read` with `want: 'refresh'` may. Longer, because the
 * far end really is waiting.
 *
 * It boots a whole Claude Code over there — 725 MB peak, about three seconds
 * measured — and that machine kills its own probe at fifteen seconds and then
 * has to compose an answer and put it on the relay. A ceiling below its own
 * would report "nobody answered" for a reading that then arrives, which on this
 * bar means somebody presses again and spends the 725 MB a second time.
 */
const USAGE_REFRESH_TIMEOUT_MS = 45_000

/**
 * How long a `session.send` may go unanswered.
 *
 * The far end's work is one synchronous write into a pty — it does not read a
 * screen, spawn anything or wait for a CLI — so the only thing being waited out
 * here is the relay, which is what `CONTROLS_READ_TIMEOUT_MS` waits out and why
 * this is the same twenty seconds. What it must not be is short: the answer this
 * settles into on a timeout cannot claim the text failed to land, because by
 * then it may well have.
 */
const SEND_TIMEOUT_MS = 20_000

/** How long a `hello` may go unanswered before the channel is not one. */
const WELCOME_TIMEOUT_MS = 15_000

/* ------------------------------------------------------------------ state -- */

/**
 * What the window may say about a machine, and nothing it may not.
 *
 * Five states, and the two in the middle exist because collapsing them lies to
 * somebody. `connecting` and `offline` differ in whether anything is happening;
 * `pairing-approval` and `error` differ in whether the answer is "wait" or
 * "this is broken", and a machine that has just been paired is in the first for
 * as long as it takes a person to walk to the other keyboard.
 */
export type MachineState = 'offline' | 'connecting' | 'awaiting-approval' | 'online' | 'error'

export interface MachineLinkState {
  id: string
  state: MachineState
  /** Why, in a sentence somebody can act on. Null while it is working. */
  reason: string | null
  /** Sessions on that machine, as it last listed them. */
  sessions: RemoteSession[]
  /**
   * Folders that machine will start a session in for this device.
   *
   * Null and `[]` are different answers and the difference is the whole point of
   * the field — see `welcome.folders`. Null means it never said, which is every
   * build older than the field and every host that cannot start sessions at
   * all; `[]` means somebody chose no folders for this device, which is a real
   * state with a real remedy on the other machine.
   */
  folders: string[] | null
  capabilities: string[]
  /**
   * What is listening on **that** machine, as it last answered.
   *
   * The other half of remote localhost, and until now it did not exist on this
   * side at all: `web.open` was on the wire and only the phone sent it, so a Mac
   * could see a PC's sessions and had no idea what that PC was serving. His
   * words for the gap are about the row rather than the list — *"remote
   * localhost should list the remote machine's ports with the machine's icon"* —
   * and the icon is the panel's job; this is the list it draws.
   *
   * Empty for a machine that has not answered and for one that is genuinely
   * serving nothing, which is a distinction this field deliberately does not
   * make: the panel already knows whether the link is online, and a third state
   * here would be a second source of truth for the same fact.
   *
   * Asked once per connection, on the `welcome`, and not polled. A port list is
   * a scan of a process table on somebody else's machine — see
   * `feedback_events_not_polling`: the desktop pushes what it wants watched, and
   * this is a question rather than a subscription.
   */
  ports: LocalPort[]
  /**
   * That machine's copilot, **as offered to this desktop**, or null.
   *
   * Null is the answer to two different questions and deliberately reads as one
   * sentence: that machine has no copilot, or it has one and paired this
   * desktop as a guest. `remote/copilot-access.ts` is why they are the same
   * answer — a guest is sent no `copilot` key at all rather than one saying no,
   * *"because an advertised capability a device may not use invites the ask,
   * and the answer to the ask is always no"* — and a client that could tell the
   * two apart would be a client the desktop had answered a question with.
   *
   * That is why it is a separate field from {@link capabilities} rather than a
   * membership test on it. The capability list says what that *machine* can do
   * and this says what *this desktop* may do there, and a surface that read the
   * first as the second would draw a control that is always refused.
   *
   * Null is also not "not connected". A machine that is offline has this at
   * null and a state of `offline` beside it, and the two say different things:
   * one is a copilot to come back to and the other is a copilot that was never
   * shared. The panel reads the state, so this field never has to encode it.
   *
   * `open` is this socket having said `copilot.hello`, which is a fact about a
   * connection rather than about a machine, and it is false on every fresh
   * `welcome` — a session channel does not carry the copilot by existing.
   */
  copilot: CopilotLinkWire | null
  /** `darwin`, `win32`, `linux`, or empty. Never guessed. */
  hostPlatform: string
  /** When the next dial is due, epoch ms, or null when one is not scheduled. */
  retryAt: number | null
}

/**
 * The answer to every copilot verb on this link: did the request leave, and
 * what to say when it did not.
 *
 * A sentence on every path, including the two that never reach the wire, for
 * the reason {@link MachineLink.send} gives about its own: there is no terminal
 * on screen to show a lost frame. A copilot verb that produced nothing at all
 * would be indistinguishable from a feature that does not work, which is the
 * defect this whole area exists to remove.
 *
 * `ok` means **the frame left this machine**, not that the copilot did
 * anything. There is no request id on the copilot wire — the host answers
 * `copilot.attach` with a pushed `copilot.state` and answers `copilot.say` with
 * nothing at all — so there is nothing here to correlate a reply against. What
 * the far end thinks arrives on {@link MachineLinkOptions.onCopilotState} and
 * `onCopilotChat`, and a refusal arrives as an ordinary `error`, which this
 * link already publishes as `reason`.
 */
export interface CopilotVerbOutcome {
  ok: boolean
  message: string
}

export interface MachineLink {
  /** Begin dialling, and keep dialling. Safe to call twice. */
  connect(): void
  /** Stop, drop the channel, and stay stopped. Safe to call twice. */
  disconnect(): void
  state(): MachineLinkState
  /** Ask for a session's screen. `cols`/`rows` travel so the first paint fits. */
  attach(sessionId: string, cols: number, rows: number): boolean
  detach(sessionId: string): boolean
  /**
   * Type into an attached session over there. A keystroke, or a whole paste.
   *
   * Split into frames by {@link chunkInput}, which is what makes a paste larger
   * than `MAX_INPUT_BYTES` arrive at all: the far end refuses an oversized frame
   * by closing the socket, so before this was chunked a long ⌘V typed nothing
   * and dropped the link. `chunkInput`'s own note carries the measurement.
   *
   * `false` means nothing was sent — the link is down, or the paste is over
   * `MAX_PASTE_BYTES` in `shared/paste-cap.ts`. It never means *some* of it
   * went: a paste that cannot be sent whole is not sent at all, because half a
   * paste at a prompt is worse than none.
   */
  input(sessionId: string, data: string): boolean
  /**
   * Send a file from this machine into that machine's downloads folder.
   *
   * The verb behind dropping a photo on a remote session's pane. Resolves with
   * the path it landed at over there — which the caller types at the prompt,
   * quoted — or with a sentence. Refused before anything is announced when that
   * machine never advertised `upload`.
   *
   * See `upload-send.ts` for the flow control, the digest and the three bounds.
   */
  sendFile(filePath: string): Promise<SendFileOutcome>
  /** Stop the transfer in flight, if there is one. The far end deletes its half. */
  cancelFile(): void
  resize(sessionId: string, cols: number, rows: number): boolean
  /** Start a session over there. Refused unless that machine advertised `create`. */
  create(request: { cwd?: string; provider?: string; resume?: boolean }): boolean
  /**
   * End a session over there. Refused unless that machine advertised `close`.
   *
   * The one verb on this wire whose effect cannot be taken back — the far end
   * kills the process, the agent stops wherever it had got to, and nothing is
   * left to recover from. `guest-close.test.ts` pins the host's side of it,
   * including the part that matters most: a guest granted one folder cannot end
   * a session running in another, and the session layer is never even asked.
   *
   * It exists on this side because the desktop asked for it in as many words:
   * *"It will just close all of the sessions from that PC… so it will go from
   * here, but whenever you want to start, you can start as a new session and you
   * can start from that device."* Ending sessions and un-pairing a machine are
   * two different acts, and this is the first one; nothing here touches the
   * store, so the pairing survives untouched.
   */
  close(sessionId: string): boolean
  /** Ask again what is listening over there. Refused unless it advertised `localhost`. */
  ports(): boolean
  /**
   * Send one tunnel frame to that machine, on behalf of `localhost-reach.ts`.
   *
   * The comment above `openThere` used to say *"a tunnel would bring the page
   * here and this end opens no listener"*. That is no longer true: this desktop
   * now binds a loopback listener for a port on another machine, so the browser
   * can open a remote dev server as an ordinary URL. See `localhost-reach.ts`
   * for the pipe and for why it is bytes rather than HTTP.
   *
   * A raw frame rather than a verb per message, because the seven `tunnel.*` and
   * `net.*` frames are one conversation with its own state machine, and that
   * state machine belongs in one file. This link's job is the channel: it knows
   * whether there is one, and whether the far machine agreed to speak these
   * frames at all — which is the gate below, and the same one `ports` applies
   * for the same reason.
   */
  localhost(message: LocalhostMessage): boolean
  /**
   * Open a page **on that machine**, in its own browser.
   *
   * The half of remote localhost this desktop could not do. A tunnel would bring
   * the page here and this end opens no listener; what it can do is drive — ask
   * the far machine to put the page on its own screen, which is the same verb
   * the phone sends and the same one his review asked for on every surface.
   *
   * Refused unless that machine advertised `web`, which it withholds from a host
   * with no window and from a device it treats as a guest. So a button drawn off
   * this capability is never a button that discovers it does not work.
   */
  openThere(url: string): boolean
  /**
   * What that session's model, effort and fast mode say right now.
   *
   * `null` means the question could not be asked — the link is down, or that
   * machine's build never advertised `controls`. It is deliberately not an
   * empty reading: a caller that was handed four blank chips could not tell "it
   * has no model" from "nobody answered", and the bar's rule is that it keeps
   * the last thing genuinely read rather than blanking on a missed round trip.
   *
   * The only verb on this link that answers with a value rather than a boolean,
   * along with {@link setControl}, and for the reason `machines:reach` is: the
   * whole point of the request is the thing that comes back.
   */
  readControls(sessionId: string): Promise<ControlsReadingWire | null>
  /**
   * Set one control on that session, and report what the far end said.
   *
   * Always answers with a sentence, on every path, including the two that never
   * leave this machine — a link that is down and a machine too old to have the
   * capability. That is the difference between this and every boolean above it:
   * those are typing and a lost keystroke is visible in the terminal a moment
   * later, whereas a menu press that produces nothing at all is indistinguishable
   * from a control that does not work. There is no silent failure here.
   */
  setControl(
    sessionId: string,
    control: ControlName,
    value: string,
  ): Promise<{ ok: boolean; message: string; reading: ControlReadingWire }>
  /**
   * What that session's account has spent, or how full its context window is.
   *
   * One method for the three `want`s because they are one question asked of one
   * capability; the *cost* difference between them is carried by the word, not
   * by the plumbing, and the word comes from a caller that knows which of the
   * three events it is on. `want: 'refresh'` boots a whole Claude Code on the
   * far machine — 725 MB, about three seconds — so it may only ever be passed
   * because a person opened the panel or pressed the retry inside it. `plan` and
   * `context` are free over there and may ride any event the local bar rides.
   *
   * Never `null`. Every path answers with a record the bar can draw, including
   * the two that never leave this machine — a link that is down and a machine
   * whose build predates the capability — because the alternative is a bar that
   * shows nothing with nothing anywhere saying why, which is the defect this
   * whole pass exists to remove. `readControls` above may answer `null` and this
   * may not, and the difference is real: a missed controls read leaves four chips
   * showing the last values they genuinely had, whereas a missed usage read
   * leaves an element with no previous value to fall back to.
   */
  readUsage(sessionId: string, want: UsageWant, force: boolean): Promise<Record<string, unknown>>
  /**
   * Put text into a session over there **without attaching to it**, and report
   * what the far end said about it.
   *
   * Not {@link input}, which is the same bytes and a different authorisation.
   * `input` is only served to a connection that already holds an attach handle
   * for that session, and taking one out in order to type would displace the
   * handle a terminal pane on this very link already holds — dropping its
   * subscription and replaying its whole scrollback at whoever is reading it.
   * This is the verb for a caller with something to say and nothing to read: the
   * browser handing an agent the element it just inspected, over a session
   * running on the PC in the other room.
   *
   * Always answers with a sentence, on every path, including the two that never
   * leave this machine — a link that is down and a machine whose build predates
   * the capability. That is the difference between this and `input` beside it:
   * a lost keystroke on an attached session is visible in the terminal a moment
   * later, whereas this send has no terminal on screen anywhere, so a `false`
   * with nothing attached to it would be indistinguishable from a feature that
   * does not work. The same rule {@link setControl} follows, for the same
   * reason.
   */
  send(sessionId: string, data: string): Promise<{ ok: boolean; message: string }>
  /*
   * The copilot on **that** machine, reached from this one.
   *
   * His words for what this is under: *"the same switch we have for sessions"*
   * at the top of the copilot page, so one page can be pointed at either
   * machine. The four verbs below are the whole of the pipe under that switch,
   * and they are deliberately the same four a phone sends — there is no
   * desktop-to-desktop dialect here, for the reason at the top of this file.
   *
   * None of them opens the connection. `copilot.hello` is sent once per
   * `welcome`, by this file, the moment a welcome arrives carrying a copilot;
   * a caller that had to remember to open it first would be a caller that
   * eventually forgets, and the state it forgets into is a copilot page whose
   * every press comes back refused.
   */
  /**
   * Watch that machine's copilot, and be sent what already exists.
   *
   * Answered over there with a `copilot.state`, and thereafter with pushed
   * `copilot.chat` frames as the conversation moves — so a caller subscribes
   * once and draws whatever arrives, rather than asking again on a timer.
   * Starts nothing and spends nothing on that machine, which is why it is the
   * read tier and why it is safe to send on a page opening.
   */
  copilotAttach(): CopilotVerbOutcome
  /**
   * Start **this desktop's own run** on that machine.
   *
   * Not a second keyboard on the copilot at that desk, and the distinction is
   * the load-bearing one of the whole feature — `copilot-remote.ts` argues it
   * at length. It is also why this is a verb rather than a side effect of
   * attaching: it spawns an agent process on somebody else's computer and
   * spends money, so it is a thing a person presses.
   *
   * Until it has been sent, `CopilotStateReport.run` is null over there and
   * {@link copilotSay} has nothing to say anything to.
   */
  copilotStart(): CopilotVerbOutcome
  /** Say something to this desktop's run over there. `act`, because talking to an agent is acting. */
  copilotSay(text: string): CopilotVerbOutcome
  /** Ask for the state again, without changing the subscription. */
  copilotState(): CopilotVerbOutcome
  /** The machine woke up. Redial now rather than waiting out the backoff. */
  wake(): void
}

export interface MachineLinkOptions {
  id: string
  secrets: MachineSecrets
  /** Told on every change, including the ones nobody asked for. */
  onState(state: MachineLinkState): void
  /** One chunk of a session's screen. `replay` marks scrollback. */
  onOutput(sessionId: string, data: string, replay: boolean): void
  /** A `welcome` landed. The store records the connection and the platform. */
  onWelcome(hostPlatform: string): void
  /**
   * A tunnel frame arrived from that machine.
   *
   * Handed straight out rather than interpreted here. The bytes inside belong to
   * a socket this file knows nothing about, and a link that started tracking
   * streams would be a second place holding the same state as the reach.
   * Optional, so every existing construction of a link still compiles and
   * behaves exactly as it did — a machine nobody has asked to tunnel simply
   * never receives one of these.
   */
  onLocalhost?(message: ServerMessage): void
  /**
   * That machine's copilot said what it is, now.
   *
   * Handed out rather than published as link state, for the reason the tunnel
   * frames above are: it is not something the machines panel draws. It is one
   * page's subject, it changes on every turn of a conversation, and putting it
   * on the link would redraw the sidebar for every token an agent on another
   * computer produced.
   */
  onCopilotState?(state: CopilotStateReport): void
  /**
   * A slice of the conversation with that machine's copilot.
   *
   * The **whole frame**, not one bubble, and that is not laziness about the
   * name a caller gives it. `run` is what makes a frame from a previous run
   * droppable rather than mergeable, and `reset` is the instruction to throw
   * away everything held; a reader handed the messages alone would have to
   * guess at both, and the guess it would make is the one that splices the end
   * of a dead conversation onto the start of a live one.
   *
   * Merging is the reader's, deliberately. This file holds no transcript: a
   * conversation kept here would be a second copy of the one the surface
   * drawing it already has, and the two would disagree about a compaction
   * replay within a week.
   */
  onCopilotChat?(chat: Extract<ServerMessage, { t: 'copilot.chat' }>): void
  /**
   * How the file being sent to that machine is getting on.
   *
   * Handed out rather than published as link state, for the reason the tunnel
   * frames and the copilot state above are: it is one pane's subject, and it
   * changes on every acknowledged slice. Optional, so every existing
   * construction of a link compiles and behaves exactly as it did.
   */
  onUpload?(progress: UploadProgress): void
  now?: () => number
  /** Seams for the tests, so nothing here dials the public internet. */
  dial?: (request: DialRequest) => Promise<GuestChannel>
  baseBackoffMs?: number
  maxBackoffMs?: number
}

/**
 * How this desktop introduces itself to another one.
 *
 * The hostname, because that is what the person approving it on the other
 * machine will recognise, and the platform so the far end can print a noun
 * rather than guess one — the same field, in the same vocabulary, that
 * `welcome.hostPlatform` carries in the other direction. Display text on both
 * ends and treated as untrusted by both.
 */
export function describeThisMachine(): { name: string; platform: string } {
  const name = hostname().replace(/\.local$/i, '').trim()
  return { name: name === '' ? 'A desktop' : name, platform: process.platform }
}

export function createMachineLink(options: MachineLinkOptions): MachineLink {
  const now = options.now ?? Date.now
  const dial = options.dial ?? dialMachine
  const baseBackoffMs = options.baseBackoffMs ?? BASE_BACKOFF_MS
  const maxBackoffMs = options.maxBackoffMs ?? MAX_BACKOFF_MS

  let channel: GuestChannel | null = null
  let dialling = false
  let stopped = true
  let attempts = 0
  let connectedAt = 0
  let retry: ReturnType<typeof setTimeout> | null = null
  let welcomeTimer: ReturnType<typeof setTimeout> | null = null
  /** Has a `welcome` ever landed from this machine? Decides "waiting" vs "broken". */
  let everWelcomed = false
  /**
   * The last `error` that arrived on a serving connection, kept only until that
   * connection ends.
   *
   * Its whole job is the sentence. If the far end refused a *request* the
   * channel stays open and this is never read again; if it was refusing the
   * *connection* the close follows within a frame or two, and `closed` reports
   * this instead of the socket's own description — "the relay closed the
   * connection" says nothing to somebody whose device was just revoked.
   */
  let refusal: { message: string; code: ProtocolErrorCode | null } | null = null

  /**
   * Questions asked of the far machine that have not been answered yet, by `rid`.
   *
   * This is the one conversation on this link that is a *request and a reply*
   * rather than a stream or a fire-and-forget verb, so it is the one that needs
   * somewhere to put a promise. Keyed on the request id rather than on the
   * session because a split window mounts a control cluster per pane, and two
   * panes over one session — which this window does — would otherwise resolve
   * each other's reads with each other's answers.
   *
   * Every entry carries its own timer and every entry is settled exactly once,
   * on one of three paths: the answer arrives, the deadline passes, or the
   * channel dies. The third is the one worth being explicit about — a link that
   * drops with reads outstanding must not leave a menu spinning for ever on a
   * machine that has gone.
   */
  const pending = new Map<
    string,
    { settle: (answer: ServerMessage | null) => void; timer: ReturnType<typeof setTimeout> }
  >()

  /**
   * Answer one outstanding request, or note that nobody will.
   *
   * `null` is "there is no answer coming", which is what a timeout and a dropped
   * channel both mean. The waiting side turns that into its own sentence rather
   * than being handed one from here, because the two callers say different
   * things about it: a read keeps the last value it had and an apply has to
   * print something.
   */
  function settle(rid: string, answer: ServerMessage | null): void {
    const waiting = pending.get(rid)
    if (waiting === undefined) return
    pending.delete(rid)
    clearTimeout(waiting.timer)
    waiting.settle(answer)
  }

  /**
   * Send a question and wait for its answer, or for the deadline.
   *
   * Registered *before* the frame goes out, because `send` is synchronous into a
   * socket and an answer that came back inside the same tick would otherwise
   * arrive at an empty map. Refuses without registering anything when the link
   * cannot carry it, so a caller never waits out a timeout for a question that
   * was never asked.
   */
  function ask(
    message: ClientMessage & { rid: string },
    timeoutMs: number,
    capability: string,
  ): Promise<ServerMessage | null> {
    // The capability is a parameter rather than a constant because there are two
    // correlated conversations on this channel now. Sending a frame a machine
    // never advertised is not a harmless no-op — a host that does not know the
    // verb refuses the connection, which would take every terminal session on
    // the link down with one bar's question.
    if (!current.capabilities.includes(capability)) return Promise.resolve(null)
    return new Promise((resolve) => {
      const timer = setTimeout(() => settle(message.rid, null), timeoutMs)
      timer.unref?.()
      pending.set(message.rid, { settle: resolve, timer })
      if (!send(message)) settle(message.rid, null)
    })
  }

  let current: MachineLinkState = {
    id: options.id,
    state: 'offline',
    reason: null,
    sessions: [],
    folders: null,
    capabilities: [],
    ports: [],
    copilot: null,
    hostPlatform: '',
    retryAt: null,
  }

  function publish(patch: Partial<MachineLinkState>): void {
    current = { ...current, ...patch }
    try {
      options.onState(current)
    } catch (error) {
      // The listener's own bookkeeping threw. It must not take the link down.
      console.error('[machines] a state listener threw:', error)
    }
  }

  function send(message: ClientMessage): boolean {
    if (channel === null || current.state !== 'online') return false
    channel.send(serialize(message))
    return true
  }

  /**
   * The file transfer half of this link, built once and kept for its lifetime.
   *
   * Not per-connection: a `send` that fails because the socket went away is
   * already how a transfer in flight learns it is over, and `drop` below ends it
   * with a sentence. One instance also enforces the "one file at a time" rule
   * the far machine enforces from its side, in the one place a person can be
   * told about it.
   */
  const uploads = createUploadSender({
    send,
    onProgress: (progress) => {
      try {
        options.onUpload?.(progress)
      } catch (error) {
        // The listener's own bookkeeping threw, exactly as in `publish`. A
        // progress line must not be able to take a file transfer down.
        console.error('[machines] an upload listener threw:', error)
      }
    },
  })

  /**
   * Why a copilot verb cannot be sent to this machine, in a sentence, or null.
   *
   * The same local gate every other capability on this link has, and it is here
   * for the reason `create` states at the top of the returned object: **a host
   * that has never heard of a frame answers it by closing the channel**, so a
   * hopeful send is not a failed request, it is a disconnection that takes
   * every terminal session on this link with it.
   *
   * The two absences are answered as one sentence on purpose. A machine with no
   * copilot and a machine that paired this desktop as a guest send exactly the
   * same thing — no capability, no key — and `remote/copilot-access.ts` says
   * why in as many words: a guest *"has no frame it can send that measures
   * whether this machine has a copilot"*. A client that told the two apart here
   * would be re-deriving, on this side of a wire, an answer that machine
   * deliberately declined to give. So the sentence names both possibilities and
   * the remedy for the one a person can act on.
   */
  function copilotBarred(): string | null {
    if (current.state !== 'online') return 'This desktop is not connected to that machine right now.'
    if (!current.capabilities.includes(CAPABILITY.copilot) || current.copilot === null) {
      return (
        'That machine is not sharing a copilot with this desktop. ' +
        'Either it has none, or this desktop is paired there as a guest — ' +
        'the copilot is only shared with a machine paired as one of your own, and that is decided by pairing it again.'
      )
    }
    return null
  }

  /** The gate, then the frame. Every copilot verb on this link is these two lines. */
  function copilotVerb(message: ClientMessage, sent: string): CopilotVerbOutcome {
    const barred = copilotBarred()
    return barred === null ? sendCopilot(message, sent) : { ok: false, message: barred }
  }

  /**
   * Put a copilot frame on the wire, having already decided it may go.
   *
   * The `false` branch is very nearly unreachable — `copilotBarred` has just
   * established the link is online — and it is written out anyway rather than
   * asserted, because the alternative is a caller told a message was sent on
   * the strength of a check made a moment earlier against a channel that can
   * close between two statements.
   */
  function sendCopilot(message: ClientMessage, sent: string): CopilotVerbOutcome {
    return send(message)
      ? { ok: true, message: sent }
      : { ok: false, message: 'The connection to that machine went away before the request could be sent.' }
  }

  function schedule(): void {
    if (retry !== null || stopped || dialling || channel !== null) return
    const ceiling = Math.min(maxBackoffMs, baseBackoffMs * 2 ** Math.min(attempts, 6))
    // Full jitter across the top half of the window, for the reason at the top
    // of this file: without it every machine redials in the same millisecond.
    const delay = Math.round(ceiling / 2 + Math.random() * (ceiling / 2))
    attempts += 1
    publish({ retryAt: now() + delay })
    retry = setTimeout(() => {
      retry = null
      publish({ retryAt: null })
      void open()
    }, delay)
    retry.unref?.()
  }

  /**
   * The channel is gone. Say why, and arrange to try again unless told not to.
   *
   * `state` is decided rather than passed in: a refusal from a machine that has
   * never let this one in is a pairing waiting on a human, and printing that as
   * an error would send somebody to the wrong screen.
   */
  function drop(reason: string, refused: ProtocolErrorCode | null): void {
    const live = channel
    channel = null
    refusal = null
    if (welcomeTimer !== null) clearTimeout(welcomeTimer)
    welcomeTimer = null
    if (live !== null) live.close()

    /*
     * Nothing that was waiting on this channel is going to be answered on it.
     *
     * Settled here rather than left to each request's own deadline, because a
     * deadline is a *worst case* and this is a known fact: the socket is gone.
     * Leaving a menu spinning for a minute over a machine that has plainly
     * dropped off the sidebar is the shape of a control that looks broken, and
     * the reconnection that follows will re-read anyway.
     */
    for (const rid of [...pending.keys()]) settle(rid, null)

    /*
     * And the file, for the same reason and with one of its own: a transfer is
     * the only thing on this link whose failure leaves something behind. The far
     * machine deletes its own `.part` when the socket goes, and this end has to
     * settle the promise the drop is waiting on — otherwise a pane sits on a
     * progress line that will never move again.
     */
    uploads.closeAll('The link to that machine dropped.')

    const wasStable = connectedAt !== 0 && now() - connectedAt >= STABLE_MS
    connectedAt = 0
    if (wasStable) attempts = 0

    if (stopped) {
      publish({ state: 'offline', reason: null, sessions: [], ports: [], copilot: null, retryAt: null })
      return
    }
    publish({
      state: refused === 'unauthorized' && !everWelcomed ? 'awaiting-approval' : 'error',
      reason,
      // The list belonged to a connection that is over. Keeping it would leave
      // rows on screen that open nothing, which is the same lie as a hover state
      // on something that is not clickable. The ports go for the same reason and
      // more strongly: a port list describes what is running on a machine, and
      // the most likely reason this link dropped is that the machine stopped.
      sessions: [],
      ports: [],
      // And the copilot, most strongly of the three, because half of what it
      // says is about *this socket*. `open` is "this connection has said hello"
      // and there is no connection; a link that kept it would draw a composer
      // over a stream that has gone, and the press would vanish rather than
      // being refused. It comes back on the next `welcome`, whole, or it does
      // not come back — which is itself the honest answer.
      copilot: null,
    })
    schedule()
  }

  function onMessage(text: string): void {
    const parsed = parseServerMessage(text)
    if (!parsed.ok) {
      // Not fatal on its own — a frame this build has never heard of is exactly
      // what the capability rule expects an older end to see — but it is worth a
      // line, because the other reading is a captive portal answering with HTML.
      console.error(`[machines] ${options.id} sent something unreadable: ${parsed.reason}`)
      return
    }
    const message = parsed.message
    switch (message.t) {
      case 'welcome': {
        if (welcomeTimer !== null) clearTimeout(welcomeTimer)
        welcomeTimer = null
        if (message.protocol !== PROTOCOL_VERSION) {
          drop(
            `That machine speaks protocol ${message.protocol} and this one speaks ${PROTOCOL_VERSION}. Update whichever build is older.`,
            null,
          )
          return
        }
        everWelcomed = true
        connectedAt = now()
        attempts = 0
        // A new connection carries none of the old one's refusals.
        refusal = null
        publish({
          state: 'online',
          reason: null,
          sessions: message.sessions,
          capabilities: message.capabilities,
          // Belonged to a connection that is over, exactly like the session
          // list. A port that was listening ten minutes ago on a machine that
          // has since rebooted is a row that opens nothing.
          ports: [],
          hostPlatform: message.hostPlatform ?? '',
          // Spread rather than assigned, so "never said" survives as null. See
          // the field's own comment.
          ...(message.folders === undefined ? {} : { folders: message.folders }),
          /*
           * The copilot, with `open` forced false whatever arrived.
           *
           * The desktop always sends false here — a session channel does not
           * carry the copilot by existing — and a client whose correctness
           * depends on the far end never having a bug is not correct. It is
           * also the field this end genuinely knows better: `open` is a fact
           * about *this socket*, and this socket has not said hello yet on the
           * line above.
           *
           * Absent stays null, and that absence is load-bearing rather than
           * missing data: it is exactly what a machine that paired this desktop
           * as a guest sends. See the field's own comment.
           */
          copilot: message.copilot === undefined ? null : { ...message.copilot, open: false },
          retryAt: null,
        })
        options.onWelcome(message.hostPlatform ?? '')
        /*
         * And open the copilot stream, here, on every welcome that carried one.
         *
         * Not on a page mounting and not behind a button. Every `copilot.*`
         * verb — the read-tier ones included — is refused by that machine until
         * this socket has said hello, and this socket is new after every
         * reconnect: a laptop that slept has a copilot it is entitled to and a
         * stream that is shut. Opening it from a surface would mean the surface
         * has to notice reconnections, which is a thing no surface can be
         * relied on to do and which nothing here would tell it about anyway.
         *
         * Gated on the key rather than on the capability, because the key is
         * the per-device fact: a machine that has a copilot and paired this
         * desktop as a guest advertises neither, and one that offered it sends
         * both. Sending hello without one would be asking a question whose only
         * possible answer is the refusal `copilot-access.ts` exists to avoid
         * inviting.
         */
        if (message.copilot !== undefined) send({ t: 'copilot.hello' })
        /*
         * And ask what it is serving, once, here.
         *
         * On the welcome rather than when a panel opens, for the reason the
         * phone asks here too: the answer is one small frame, it is what the
         * panel needs the instant somebody looks at it, and a question asked on
         * first paint is a panel that is empty for a round trip every time it is
         * opened. Gated on the advertisement — a host that never offered
         * `localhost` answers this verb by closing the channel, and a button
         * that disconnects you is worse than a button that is not offered.
         */
        if (message.capabilities.includes(CAPABILITY.localhost)) send({ t: 'ports' })
        return
      }
      case 'sessions':
        publish({ sessions: message.sessions })
        return
      case 'created':
        // Merged rather than replacing the list: this frame is the one session
        // that was just started, and the rest of the list is still true.
        //
        // `reason` is cleared with it. A refusal printed under the row is about
        // the request that was refused, and leaving it there next to a session
        // that has just started would describe the wrong thing.
        refusal = null
        publish({
          reason: null,
          sessions: [
            message.session,
            ...current.sessions.filter((session) => session.id !== message.session.id),
          ],
        })
        return
      case 'closed':
        /*
         * The session this end asked to end is gone.
         *
         * Taken out of the list here rather than waited for, and that is not an
         * optimisation. `server.ts` answers the device that sent `close` with
         * this frame and sends every *other* connected device a fresh `sessions`
         * list — deliberately, because `closed` names one device's action and
         * `sessions` is v1 — so this connection is the one that never receives
         * the refreshed list. Without this case the row stayed on screen until
         * something unrelated caused a push, which on a quiet machine is until
         * the next reconnect: the ✕ would have looked broken for as long as it
         * took to notice, which is the exact class of defect this pass exists
         * to remove.
         *
         * `reason` goes with it for the same reason `created` clears it: a
         * refusal printed under the group is about the request that was refused,
         * and leaving it beside a session that has just ended describes the
         * wrong thing.
         */
        refusal = null
        publish({
          reason: null,
          sessions: current.sessions.filter((session) => session.id !== message.id),
        })
        return
      case 'folders':
        publish({ folders: message.folders })
        return
      case 'ports':
        publish({ ports: message.ports })
        return
      case 'tunnel.opened':
      case 'tunnel.closed':
      case 'net.data':
      case 'net.ack':
      case 'net.close':
        /*
         * The tunnel's own conversation, passed through untouched.
         *
         * Listed one by one rather than caught by a default, so that a frame
         * added to the protocol without a decision about where it belongs stops
         * the build rather than quietly becoming somebody else's problem — the
         * same rule `server.ts` follows on the way in.
         *
         * Nothing is published. A tunnel is not link state: it is a listener on
         * this machine with a page open on it, and the panel that draws machines
         * has nothing to say about one. Redrawing the sidebar for every chunk of
         * a page body would also be a re-render per frame.
         */
        options.onLocalhost?.(message)
        return
      case 'web.opened':
        /*
         * The page is open over there, and there is nothing here to change.
         *
         * Deliberately not published as state. The confirmation is a window
         * appearing on the other machine — that is what was asked for and it is
         * what happened — and a panel that also announced it would be narrating
         * a thing the person can see. A *failure* is a plain `error` and does
         * reach the panel through `reason`, which is the asymmetry that matters:
         * silence means it worked.
         */
        return
      case 'output':
        options.onOutput(message.id, message.data, message.replay === true)
        return
      case 'status':
        publish({
          sessions: current.sessions.map((session) =>
            session.id === message.id ? { ...session, status: message.status } : session,
          ),
        })
        return
      case 'exit':
        publish({
          sessions: current.sessions.map((session) =>
            session.id === message.id
              ? { ...session, status: 'exited', exitCode: message.exitCode }
              : session,
          ),
        })
        return
      case 'error': {
        /*
         * Two completely different frames share this shape, and telling them
         * apart is the difference between a sentence and a disconnection.
         *
         * One is the connection being refused: a credential the far end will
         * not take, a device somebody revoked, a protocol frame it could not
         * read. `server.ts` sends those through `refuse`, which closes the
         * socket in the same breath.
         *
         * The other is one *request* being refused on a connection that is
         * working perfectly — `create` naming a folder that device has not been
         * granted, `attach` naming a session that has already exited, a tunnel
         * or an upload turned down. Those are answered and nothing is closed.
         *
         * This handler used to drop the link for both, and on real machines
         * that was the more common one by far. Asking a paired Windows PC for a
         * folder its grant list no longer carried took the whole link down:
         * `online` → `error` with the session list blanked → `connecting` →
         * `online`, measured at 1.9 seconds, for a mistake whose entire correct
         * outcome is one line of red text. Every remote session on that machine
         * vanished from the screen and came back, and any attach in flight was
         * lost with them.
         *
         * There is no request id on this wire to match an answer to a question,
         * so the discriminator is the state of the link: once `welcome` has
         * landed and this thing is serving, a refusal is a refused *request*.
         * A refused connection is still refused — the close follows immediately
         * and `closed` reports it with this sentence rather than the socket's.
         */
        const sentence = message.message === '' ? 'That machine refused the connection.' : message.message
        if (current.state === 'online') {
          refusal = { message: sentence, code: message.code }
          // Published so the sentence reaches the person who caused it. The
          // panel already draws `reason` under the row whatever the state is,
          // and the far end wrote this text for a reader — this end knows less
          // about why it said no than it does.
          publish({ reason: sentence })
          return
        }
        drop(sentence, message.code)
        return
      }
      case 'copilot.grant':
        /*
         * The one copilot frame that *is* link state, and the only one.
         *
         * It answers `copilot.hello` — which is how `open` becomes true — and
         * it also arrives unasked when a person on the other machine revokes
         * this one. That second case is the whole reason it is published rather
         * than handed out: capabilities travel only in the `welcome`, so
         * without this frame a demoted desktop would keep drawing a copilot it
         * may no longer touch until somebody reconnected it.
         */
        publish({ copilot: message.link })
        return
      case 'copilot.state':
        options.onCopilotState?.(message.state)
        return
      case 'copilot.chat':
        options.onCopilotChat?.(message)
        return
      case 'controls.reading':
      case 'controls.applied':
      case 'usage.reading':
      case 'session.sent':
        /*
         * The answer to one question this end asked, handed to whoever asked it.
         *
         * Nothing is published. These are not link state: a reading belongs to
         * one session's control cluster and there can be two of them mounted at
         * once over different sessions on the same machine, so putting the newest
         * answer on the link would be a single slot that the two clusters
         * overwrite for each other. The `rid` is the routing, and an answer with
         * no waiting request — a duplicate, or one that arrived after its own
         * deadline — falls on the floor in `settle`, which is the right place
         * for it.
         */
        settle(message.rid, message)
        return
      case 'upload.ready':
      case 'upload.ack':
      case 'upload.done':
      case 'upload.failed':
        /*
         * Handed to the transfer that is running, and to nothing else.
         *
         * Not published as link state for the reason the copilot frames above
         * are not: a file crossing to another machine belongs to the pane it was
         * dropped on, it changes on every acknowledged slice, and putting it on
         * the link would redraw the sidebar a hundred times a second while a
         * video copies. `upload-send.ts` holds the state and answers the promise
         * the drop is waiting on; a frame with no transfer behind it — a late
         * acknowledgement, an answer that arrived after a cancel — falls on the
         * floor there, which is the right place for it.
         */
        uploads.receive(message)
        return
      case 'attached':
      case 'detached':
      case 'pong':
        // Acknowledgements. The screen is driven by `output`, and a state change
        // on the strength of an ack would be a second source of truth for the
        // same fact.
        return
    }
  }

  async function open(): Promise<void> {
    if (stopped || dialling || channel !== null) return
    dialling = true
    // The copilot goes here as well as in `drop`, because not every road to a
    // new channel runs through a drop: `wake` closes the old one by hand and
    // dials, and a link that kept the old socket's `open: true` across that
    // would offer a composer over a stream nothing is listening on. It is
    // restored by the next `welcome`, which is the only thing that knows.
    publish({ state: 'connecting', reason: null, copilot: null })

    let opened: GuestChannel
    try {
      opened = await dial({
        relayUrl: options.secrets.relayUrl,
        hostId: options.secrets.hostId,
        hostPublicKey: options.secrets.hostPublicKey,
        guestKeys: options.secrets.guestKeys,
        handlers: {
          message: onMessage,
          closed: (reason) => {
            if (channel === null) return
            // A refusal that arrived a moment ago was about this connection
            // after all, so its sentence wins over the socket's: "This device
            // is not allowed in." rather than "the relay closed the channel".
            drop(refusal?.message ?? reason, refusal?.code ?? null)
          },
        },
      })
    } catch (error) {
      dialling = false
      publish({ state: 'error', reason: error instanceof Error ? error.message : String(error) })
      schedule()
      return
    }

    dialling = false
    // Switched off while the dial was in the air. Without this the channel is
    // installed after `disconnect()` has run and then stays open for good:
    // nothing reconnects it and nothing is left holding it to close.
    if (stopped) {
      opened.close()
      return
    }
    channel = opened

    // The credential goes out immediately; there is nothing to wait for. A
    // channel that has completed the handshake has already proved the far end
    // holds the key this machine paired against, which is why sending a bearer
    // secret down it is safe.
    opened.send(
      serialize({
        t: 'hello',
        protocol: PROTOCOL_VERSION,
        token: options.secrets.credential,
        device: describeThisMachine(),
      }),
    )

    // A `hello` that is never answered is the shape of a relay that stapled this
    // channel to something that is not listening. Without this the link sits in
    // `connecting` forever and the panel says nothing at all.
    welcomeTimer = setTimeout(() => {
      welcomeTimer = null
      drop('That machine did not answer. It may be asleep or switched off.', null)
    }, WELCOME_TIMEOUT_MS)
    welcomeTimer.unref?.()
  }

  return {
    connect(): void {
      if (!stopped) return
      stopped = false
      attempts = 0
      void open()
    },
    disconnect(): void {
      if (stopped) return
      stopped = true
      if (retry !== null) clearTimeout(retry)
      retry = null
      if (welcomeTimer !== null) clearTimeout(welcomeTimer)
      welcomeTimer = null
      const live = channel
      channel = null
      live?.close()
      publish({ state: 'offline', reason: null, sessions: [], ports: [], copilot: null, retryAt: null })
    },
    state: () => current,
    attach: (sessionId, cols, rows) => send({ t: 'attach', id: sessionId, cols, rows }),
    detach: (sessionId) => send({ t: 'detach', id: sessionId }),
    input(sessionId, data): boolean {
      /*
       * Measured before anything is sent, so an over-size paste is refused
       * rather than half-delivered. `chunkInput` would happily split a 400 MB
       * clipboard into twenty-five thousand frames, and the far machine's socket
       * buffer would answer by dropping the link somewhere in the middle — with
       * a quarter of the text already typed into a live session.
       */
      if (overPasteCap(data)) return false
      const frames = chunkInput(data)
      for (const frame of frames) {
        if (!send({ t: 'input', id: sessionId, data: frame })) return false
      }
      // An empty string produces no frames and is not a failure — nothing was
      // asked for and nothing went wrong.
      return true
    },
    sendFile(filePath): Promise<SendFileOutcome> {
      // Refused here rather than sent and refused there, for the reason `create`
      // and `close` give below: the far end answers an unadvertised verb by
      // closing the channel, and a drop that disconnects you is worse than one
      // that is turned down.
      if (!current.capabilities.includes(CAPABILITY.upload)) {
        return Promise.resolve({
          ok: false,
          message: 'That machine is running an older build that cannot receive files.',
        })
      }
      return uploads.send(filePath)
    },
    cancelFile(): void {
      uploads.closeAll('Cancelled.')
    },
    resize: (sessionId, cols, rows) => send({ t: 'resize', id: sessionId, cols, rows }),
    create(request): boolean {
      // Refused here rather than sent and refused there, because the far end
      // answers an unadvertised verb by closing the channel. A button that
      // disconnects you is worse than a button that is not offered.
      if (!current.capabilities.includes('create')) return false
      return send({
        t: 'create',
        ...(request.cwd === undefined ? {} : { cwd: request.cwd }),
        ...(request.provider === undefined ? {} : { provider: request.provider }),
        ...(request.resume === undefined ? {} : { resume: request.resume }),
      })
    },
    close(sessionId): boolean {
      // Refused here rather than sent and refused there, for the reason `create`
      // gives above: a host that never advertised this answers it by closing the
      // channel, and a button that disconnects you is worse than one that is not
      // offered. The window asks the same question before it draws the control —
      // see `SidebarMachine.canClose` — so this is the backstop rather than the
      // gate, and it is here because a gate that lives only in a renderer is a
      // gate an IPC call can walk around.
      if (!current.capabilities.includes(CAPABILITY.close)) return false
      return send({ t: 'close', id: sessionId })
    },
    ports(): boolean {
      // Refused here rather than sent and refused there, for the reason
      // `create` gives: the far end answers an unadvertised verb by closing the
      // channel.
      if (!current.capabilities.includes(CAPABILITY.localhost)) return false
      return send({ t: 'ports' })
    },
    localhost(message): boolean {
      // The same gate `ports` uses, and it is the whole of this method: a
      // machine that never advertised `localhost` answers any of these frames by
      // closing the channel, which would take every terminal session on it down
      // with the tunnel. The reach reads the `false` as "not connected" and says
      // so in a sentence rather than leaving a click unanswered.
      if (!current.capabilities.includes(CAPABILITY.localhost)) return false
      return send(message)
    },
    openThere(url): boolean {
      if (!current.capabilities.includes(CAPABILITY.web)) return false
      // The URL is not checked here and deliberately is not. The far machine
      // puts every one through the same gate an untrusted link goes through,
      // because a client is not something a machine gets to trust about what it
      // opens — and a second, weaker check written on this side would be the one
      // somebody later mistook for the real one.
      return send({ t: 'web.open', url })
    },
    async readControls(sessionId): Promise<ControlsReadingWire | null> {
      /*
       * A machine that is up and cannot do this answers with a *reading* rather
       * than with nothing, and that difference is the whole of what an older host
       * degrades to.
       *
       * Null means "nobody answered", and the bar's rule for that is to keep the
       * values it already had — right for a link that has dropped, and wrong
       * here, because there is a settled fact to report. Without this the chips
       * would sit on "Unknown", stay pressable, and produce the sentence only
       * *after* somebody pressed one: a menu that looks live and is not. With it
       * they are drawn back carrying the reason, which is what `blockedFor` in
       * `SessionControls.tsx` does with every other refusal on this bar.
       *
       * `live` is true on purpose. The session really is running over there —
       * this end simply cannot ask about its model — and reporting it as gone
       * would be a second, wronger claim in place of the one being made.
       */
      if (current.state === 'online' && !current.capabilities.includes(CAPABILITY.controls)) {
        const barred: ControlReadingWire = {
          value: null,
          label: null,
          source: null,
          unavailableReason:
            'That machine is running a build that cannot report or set a model from here. Update it and this will work.',
        }
        return {
          model: barred,
          effort: barred,
          fast: barred,
          permission: barred,
          live: true,
          agent: { running: false, saw: null },
          gate: { canType: false, reason: null },
        }
      }
      const answer = await ask(
        { t: 'controls.read', rid: randomUUID(), id: sessionId },
        CONTROLS_READ_TIMEOUT_MS,
        CAPABILITY.controls,
      )
      /*
       * The session is checked as well as the frame type, because an `rid` only
       * proves this is the answer to *a* question this end asked. A far end that
       * echoed the wrong id would put another session's model on this session's
       * chip, which is precisely the confusion the per-pane clusters exist to
       * prevent — and it costs one comparison to make impossible rather than
       * unlikely.
       */
      if (answer === null || answer.t !== 'controls.reading' || answer.id !== sessionId) return null
      return answer.reading
    },
    async setControl(sessionId, control, value) {
      const unread: ControlReadingWire = { value: null, label: null, source: null }
      /*
       * The two refusals that never leave this machine, each with its own
       * sentence, because they have different remedies. A link that is down is
       * waited out; a machine whose build has no `controls` is updated. Telling
       * somebody "that failed" for either would send them looking in the wrong
       * place.
       */
      if (current.state !== 'online') {
        return { ok: false, message: 'This desktop is not connected to that machine right now.', reading: unread }
      }
      if (!current.capabilities.includes(CAPABILITY.controls)) {
        return {
          ok: false,
          message:
            'That machine is running a build that cannot set a model from here. Update it and this will work.',
          reading: unread,
        }
      }
      const answer = await ask(
        { t: 'controls.apply', rid: randomUUID(), id: sessionId, control, value },
        CONTROLS_APPLY_TIMEOUT_MS,
        CAPABILITY.controls,
      )
      if (answer === null || answer.t !== 'controls.applied' || answer.id !== sessionId) {
        /*
         * No answer, and the honest sentence for that is the one that does not
         * claim the change failed.
         *
         * It very well may have landed: the command is typed into the far pty
         * before that machine sends anything back, so a channel that died in
         * between leaves a session that has changed and a window that was not
         * told. Saying "it failed" would be a guess in the direction that makes
         * somebody press it again, which on a session that already moved is a
         * second `/model` block in their conversation.
         */
        return {
          ok: false,
          message: 'That machine did not answer, so it is not known whether the change was made.',
          reading: unread,
        }
      }
      return { ok: answer.ok, message: answer.message, reading: answer.reading }
    },
    async readUsage(sessionId, want, force): Promise<Record<string, unknown>> {
      /*
       * The two absences that never leave this machine, each with its own
       * sentence, because they have different remedies — the same split
       * `setControl` above makes. A link that is down is waited out; a machine
       * whose build has no `usage` is updated.
       *
       * Composed into a *reading* rather than answered with nothing, and that
       * difference is the whole of what an older host degrades to. The bar has no
       * previous value to keep for these figures the way the control chips do,
       * so "nobody answered" would be a blank element with the account of it a
       * press away — which has already been read as a broken feature once on this
       * bar. With a reading the sentence is on screen from the moment it mounts,
       * because `plan` and `context` are both asked for then and both are free.
       */
      if (current.state !== 'online') {
        return emptyUsageReading(want, 'This desktop is not connected to that machine right now.')
      }
      if (!current.capabilities.includes(CAPABILITY.usage)) {
        return emptyUsageReading(
          want,
          'That machine is running a build that cannot report its plan usage or context window from here. Update it and this will work.',
        )
      }
      const answer = await ask(
        { t: 'usage.read', rid: randomUUID(), id: sessionId, want, force },
        // The deadline is chosen by the word, because the word is what decides
        // whether the far end is reading memory or booting an agent CLI.
        want === 'refresh' ? USAGE_REFRESH_TIMEOUT_MS : USAGE_READ_TIMEOUT_MS,
        CAPABILITY.usage,
      )
      /*
       * The session and the `want` are both checked, not just the frame type.
       * An `rid` only proves this is the answer to *a* question this end asked,
       * and the two mistakes it cannot rule out are the two that matter: another
       * session's spending under this session's bar, and a context reading filed
       * where a plan report goes — a token count drawn as a percentage of
       * somebody's subscription. Two comparisons make both impossible rather
       * than unlikely.
       */
      if (answer === null || answer.t !== 'usage.reading' || answer.id !== sessionId || answer.want !== want) {
        return emptyUsageReading(want, 'That machine did not answer, so there is nothing to show for this session yet.')
      }
      const { reading, unavailableReason } = answer.answer
      if (reading !== null) return reading
      // A host that answered without a reading owes a sentence, and if it did
      // not write one this end must not invent a figure to fill the gap — the
      // honest fallback is the same absence with this end's own wording.
      return emptyUsageReading(want, unavailableReason ?? 'That machine had nothing to report for this session.')
    },
    async send(sessionId, data) {
      /*
       * The two refusals that never leave this machine, each with its own
       * sentence, because they have different remedies — the same split
       * `setControl` above makes. A link that is down is waited out; a machine
       * whose build has no `send` is updated.
       *
       * The second one is not merely tidiness about a verb that would be
       * refused. It is the rule `create` states at the top of this object and
       * every gate here repeats: **a host that has never heard of a frame
       * answers it by closing the channel**, so a hopeful send is not a failed
       * request, it is a disconnection — and it would take every terminal
       * session on this link down with one panel's send button.
       */
      if (current.state !== 'online') {
        return { ok: false, message: 'This desktop is not connected to that machine right now.' }
      }
      if (!current.capabilities.includes(CAPABILITY.send)) {
        return {
          ok: false,
          message:
            'That machine is running a build that cannot be sent to without opening the session there first. Update it and this will work.',
        }
      }
      const answer = await ask(
        { t: 'session.send', rid: randomUUID(), id: sessionId, data },
        SEND_TIMEOUT_MS,
        CAPABILITY.send,
      )
      /*
       * The session is checked as well as the frame type, for the reason
       * `readControls` gives about its own answer: an `rid` only proves this is
       * the answer to *a* question this end asked. A far end that echoed the
       * wrong id would report one session's outcome for another, and two panels
       * sending to two sessions on one machine is a thing this window does. One
       * comparison makes that impossible rather than unlikely.
       */
      if (answer === null || answer.t !== 'session.sent' || answer.id !== sessionId) {
        /*
         * No answer, and the honest sentence for that is the one that does not
         * claim the text failed to arrive.
         *
         * It very well may have: the far end writes into the pty before it puts
         * anything back on the wire, so a channel that died in between leaves a
         * session that has been typed into and a panel that was not told.
         * Saying "it failed" would be a guess in the direction that makes
         * somebody press send again, which on an agent that already got the
         * text is the same message twice in its prompt.
         */
        return { ok: false, message: 'That machine did not answer, so it is not known whether the text arrived.' }
      }
      return { ok: answer.ok, message: answer.message }
    },
    copilotAttach: () => copilotVerb({ t: 'copilot.attach' }, 'Watching that machine’s copilot.'),
    copilotStart: () => copilotVerb({ t: 'copilot.start' }, 'Asked that machine to start a copilot run.'),
    copilotState: () => copilotVerb({ t: 'copilot.state' }, 'Asked that machine what its copilot is doing.'),
    copilotSay(text): CopilotVerbOutcome {
      const barred = copilotBarred()
      if (barred !== null) return { ok: false, message: barred }
      if (typeof text !== 'string' || text === '') return { ok: false, message: 'There is nothing to say.' }
      /*
       * Shape-checked against the parser the far end will run, rather than
       * against a second copy of its rules written here.
       *
       * It has to be checked *somewhere* on this side and cannot be hoped
       * through: `parseClientMessage` refuses an oversized or control-bearing
       * `copilot.say`, and `server.ts` answers a refused frame by closing the
       * socket — so a long paste would not be a failed message, it would be a
       * disconnection that took every terminal session on this link with it.
       * That is the rule every gate in this object repeats.
       *
       * Running the real parser rather than re-stating its two rules is what
       * stops the copy drifting. The cap is bytes rather than characters and
       * the control-character refusal exists because this text is written into
       * a pty holding an agent — a carriage return inside it submits early and
       * turns the rest into a second prompt somebody pays for — and both of
       * those are decisions that belong to `protocol.ts` and are re-litigated
       * there, not here.
       */
      const frame = parseClientMessage({ t: 'copilot.say', text })
      if (!frame.ok) {
        return {
          ok: false,
          message:
            frame.code === 'too-large'
              ? 'That message is longer than this connection carries in one piece. Shorten it and send it again.'
              : 'That message cannot be sent as it is: a copilot message may not contain line breaks or control characters.',
        }
      }
      return sendCopilot(frame.message, 'Sent.')
    },
    wake(): void {
      if (stopped) return
      // A channel that slept through a suspend is dead and still looks alive,
      // and the welcome timer would take fifteen seconds to say so. Redialling
      // costs one handshake and gets the machine back a great deal sooner; the
      // backoff resets because waking is not a failed attempt.
      attempts = 0
      if (retry !== null) clearTimeout(retry)
      retry = null
      const live = channel
      channel = null
      live?.close()
      if (welcomeTimer !== null) clearTimeout(welcomeTimer)
      welcomeTimer = null
      publish({ retryAt: null })
      void open()
    },
  }
}
