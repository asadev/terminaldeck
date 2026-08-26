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
 * That schedule is **flat while the wait is on a human**, and only then. The
 * exponential curve is the right answer to a machine that is off or a relay
 * that is down; it is the wrong answer to somebody standing at the other
 * keyboard about to press a button, because by the fourth refusal the next dial
 * is eight to sixteen seconds away and the press appears to do nothing.
 * Measured: seven seconds from *Let it in* to the copilot appearing, all of it
 * the timer. A refusal costs the far end almost nothing — it is rejected at
 * hello, before anything is attached — so the wait stays at the base delay
 * until that machine has let this one in once. See {@link schedule}.
 *
 * ## The one thing this file will not do
 *
 * It never writes to the store. `store.ts` owns what is on disk and `ipc.ts`
 * owns when a pairing is worth remembering; a connection that persisted its own
 * credential would be one that could persist a credential it got from a channel
 * that then failed its seal.
 */

import { randomUUID } from 'node:crypto'
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
  type AccountWire,
  type ControlsReadingWire,
  type CopilotLinkWire,
  type CopilotStateReport,
  type HostKind,
  type LocalPort,
  type ProtocolErrorCode,
  type RemoteSession,
  type ServerMessage,
  type UsageWant,
  type WindowCallFrame,
} from '../protocol'
import { thisMachineName } from '../../platform/host'
import type { LocalhostMessage } from '../tunnel'
import { dialMachine, type GuestChannel, type DialRequest } from './dial'
import { overPasteCap } from '../../../shared/paste-cap'
import type { HeldSession } from '../../../shared/held-window'
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
 * How long an `account.read` may go unanswered. The same twenty seconds its two
 * neighbours get, and for the same reason: it is a state file and a spawn record
 * over there, so the only thing being waited out is the relay.
 */
const ACCOUNT_READ_TIMEOUT_MS = 20_000

/**
 * And how long an `account.switch` may. The longest ceiling on this wire,
 * because the far end really is waiting the longest.
 *
 * A switch spawns an agent CLI over there, waits for `survivedStart` to see
 * whether it is still alive a moment later, and only then kills the session it
 * replaced. A ceiling below the far end's own would report a failure for a
 * switch that then lands — and here that is worse than on a control, because
 * what lands is a *replacement session*: the window would keep the old id and
 * end up attached to a pty that has already been killed.
 */
const ACCOUNT_SWITCH_TIMEOUT_MS = 90_000

/**
 * How long a `logins.read` may go unanswered. The same twenty seconds
 * `account.read` gets, because it is the same work over there — a state file and
 * a handful of thirty-second-memoised probes — with the session left out of the
 * question.
 */
const LOGINS_READ_TIMEOUT_MS = 20_000

/**
 * And how long a `logins.signin` may.
 *
 * It starts a session over there: resolving the agent binary, a login shell's
 * PATH and a pty. That is seconds rather than the minute and a half a *switch*
 * can take — nothing is being waited out for survival and nothing is being
 * killed — but it is the same class of work, so it gets a ceiling well above a
 * read and well below the switch's.
 */
const LOGINS_SIGNIN_TIMEOUT_MS = 45_000

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
  /**
   * That machine's own build version, as its last `welcome` said, or empty.
   *
   * Empty is the answer for a machine that has not connected and for one running
   * a build from before the field — the same neutral both `hostPlatform` and the
   * fallback name mean, and the panel shows nothing rather than guessing a
   * number. Display text off an authenticated-but-not-trusted channel, already
   * stripped and bounded by the wire parser; nothing here trusts it for more
   * than reading.
   */
  hostVersion: string
  /**
   * Which shell is serving over there — desktop or headless server — or null.
   *
   * Null is "it never said", which is every build older than the field; the
   * panel calls it a machine rather than guessing a kind. It is what lets a
   * server read as a *server* on this desktop's Machines panel, and what the
   * behind-sentence names.
   */
  hostKind: HostKind | null
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
   * Send a file from this machine into a folder on that machine.
   *
   * The verb behind dropping a photo on a remote session's pane, and behind
   * delivering a browser download to another computer. Resolves with the path it
   * landed at over there — which the caller types at the prompt, quoted, or
   * shows on a downloads row — or with a sentence. Refused before anything is
   * announced when that machine never advertised `upload`.
   *
   * `dir` is optional and absent is the old behaviour: that machine's own
   * downloads folder. When it is given, **that machine decides whether it is
   * allowed** — see `storeForFolder` in `server.ts` — so a refusal arrives as a
   * sentence from over there rather than being guessed at here.
   *
   * See `upload-send.ts` for the flow control, the digest and the three bounds.
   */
  sendFile(filePath: string, dir?: string): Promise<SendFileOutcome>
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
  /**
   * Give a session over there the name somebody typed here. Refused unless that
   * machine advertised `rename`.
   *
   * *"Now this time once you do all of these then you will align all of the
   * other versions of the application with it… so the things that are aligned
   * they can work seamlessly together when they are connected with remote
   * also."* The name over a terminal is editable at this keyboard by
   * double-click and F2, and until this verb existed that gesture stopped dead
   * at the edge of this computer: a session on his PC was named by his PC and by
   * nothing else. This is the same gesture reaching the same field one machine
   * over.
   *
   * The opposite of {@link close} in the one way that matters — nothing is
   * destroyed and a rename is taken back by renaming again — which is why it is
   * sent with no confirmation anywhere above it. An empty title is not a
   * refusal: it means *take my name off it*, and the far end answers by deriving
   * the folder's name again.
   *
   * There is no `renamed` frame to wait for and deliberately so. `server.ts`
   * answers a rename by resending **every** connected device its own `sessions`
   * list, this one included, so the new name arrives down the same channel the
   * row was drawn from. That is why nothing here touches the cached state: the
   * push is the answer, and a local edit alongside it would be a second copy of
   * the name that can disagree with the machine that owns it.
   */
  rename(sessionId: string, title: string): boolean
  /**
   * Tell that machine which of its sessions this app is holding a browser window
   * for, right now.
   *
   * Called on every welcome by the link itself, and by the app whenever a window
   * is attached or detached. `false` means nothing was sent: the link is down, or
   * that machine's build never advertised `windows` — an older desktop would
   * answer a frame it has never heard of by closing the channel, which is how a
   * new fact becomes a machine that falls off the network.
   *
   * The whole set every time. See the frame's own note for why a delta would
   * drift and this cannot.
   */
  announceWindows(): boolean
  /**
   * Tell that machine what is running **here**, so somebody sitting at it can
   * put one of its browser windows beside one of these sessions.
   *
   * The mirror of {@link announceWindows} and the fact that machine cannot
   * derive. It watches this desktop's sessions only in the direction it dialled;
   * on a link *this* desktop opened, the far end has never been sent a list of
   * this machine's ptys and its attach menu has no row to offer. `sessions.mine`
   * is that list.
   *
   * Sent on every welcome and whenever a session starts or ends here. `false`
   * means nothing was sent: the link is down, this build has no sessions to
   * describe, or that machine never advertised `hostWindows` — and the last of
   * those is the version check, because a build that has never parsed this frame
   * answers it by closing the channel.
   *
   * It hands that machine nothing. There is no verb in this direction that can
   * type into one of these sessions, start one or read one, and this frame adds
   * none; what it enables is a row in a picker over there, and the browser verb
   * that row leads to comes back *here* through `onWindowCall`, where the grant
   * is read per call exactly as it was before.
   */
  announceSessions(): boolean
  /**
   * Ask that machine to act on a browser window **it** is holding, for a session
   * running here.
   *
   * The mirror of {@link announceWindows} and of the `window.call` this link
   * *receives*: same frame, opposite direction, and it goes out only after that
   * machine has advertised `CAPABILITY.hostWindows`. `false` means nothing was
   * sent — the link is down, or that machine's build has never heard of the
   * frame in this direction — and the desk turns that into a sentence in
   * milliseconds rather than a fifty-five second wait.
   *
   * Nothing is decided here. The grant is the far machine's, read there per
   * call; the window is resolved there inside that session's own binding; the
   * answer comes back as a `window.result` and is settled on the desk.
   */
  askWindow(call: WindowCallFrame): boolean
  /**
   * Could {@link askWindow} reach that machine right now, without sending
   * anything?
   *
   * The same two conditions `askWindow` applies — an online link, on a build that
   * advertised `hostWindows` — asked ahead of time. Separate from a probe send,
   * because a probe that put a frame on a socket would be a lookup writing to
   * somebody's network.
   */
  servesWindows(): boolean
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
   * Whose login that session is on, and which logins that machine has.
   *
   * `null` means the question could not be asked — the link is down, or that
   * machine's build never advertised `account`. Deliberately not an empty state:
   * a chip handed an empty account list could not tell "that machine has one
   * login" from "nobody answered", and those want opposite things drawn.
   */
  readAccount(
    sessionId: string,
  ): Promise<{ current: AccountWire | null; accounts: AccountWire[] } | null>
  /**
   * Run that session as another of that machine's logins.
   *
   * Always answers with a sentence, on every path including the two that never
   * leave this machine, for the reason {@link setControl} does — and here there
   * is a second reason. This **replaces the far session**, so the answer carries
   * the id it has afterwards: the same one on a refusal, a new one on a success,
   * and null when that machine could not say. A window that ignored it would sit
   * attached to a pty that has already been killed.
   */
  switchAccount(
    sessionId: string,
    accountId: string,
  ): Promise<{ ok: boolean; message: string; session: string | null }>
  /**
   * Which logins that **machine** has, with no session in the question.
   *
   * `null` means the question could not be asked — the link is down, or that
   * machine's build never advertised `logins`, or this desktop is a guest on it.
   * Deliberately not an empty array: a pane handed an empty list could not tell
   * "that machine has no logins" from "nobody answered", and those want opposite
   * things drawn.
   */
  readLogins(): Promise<AccountWire[] | null>
  /**
   * Start signing one of that machine's logins in, over there.
   *
   * Always answers with a sentence, on every path including the two that never
   * leave this machine, for the reason {@link switchAccount} does. `session` is
   * the terminal that machine opened so the login can be finished in it — null
   * on every refusal — and it is the whole reason this answers with more than a
   * boolean: an interactive login nobody can see is a login nobody can complete.
   */
  signInLogin(accountId: string): Promise<{ ok: boolean; message: string; session: string | null }>
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
  /**
   * That machine has a session that wants to act on a browser window **here**.
   *
   * The one inbound *question* on this link, and the only one — everything else
   * arriving from a paired machine is an answer to something this end asked, or
   * an event. `credential.request` is the same shape one protocol out, and the
   * comparison is worth keeping in mind: both are the far end saying *"you hold
   * the thing, please act"*, and both are refused by default until somebody
   * here says otherwise.
   *
   * ## Why the answer is a handler rather than a map read
   *
   * The window is a `WebContentsView` in this app's renderer and the verb has to
   * go through `deck-control`'s dispatcher — prechecks, tiers, the confirmation
   * broker, the budgets and `actions.jsonl` — because a call that skipped any of
   * those would be a browser holding his logins driven by a path with no record
   * of it. None of that can be reached from this file, and it must not be: this
   * file is a socket and a state machine.
   *
   * Absent means this link never advertises the capability, so the far machine
   * never asks, so a session over there is launched knowing it cannot drive
   * rather than finding out mid-turn. See `CAPABILITY.windows`.
   */
  onWindowCall?(call: {
    sessionId: string
    tool: string
    args: string
  }): Promise<{ ok: boolean; body: string }>
  /**
   * Which of *that* machine's sessions this app currently holds a browser window
   * for, asked whenever the answer has to be sent.
   *
   * The other half of {@link onWindowCall}, and the half without which it only
   * ever fires for sessions this app itself started over there. The window is
   * attached in this process — `browser-binding.ts`, under
   * `<machineId>\0<sessionId>` where the machine id is this link — and the far
   * machine has no way to learn that a page is sitting beside one of its ptys.
   * So it is told: see `CAPABILITY.windows` and {@link MachineLink.announceWindows}.
   *
   * A function rather than a list, read at the moment of sending, because the
   * answer changes every time somebody attaches or detaches a window and the two
   * moments this is sent — a welcome, and a change — are both "say what is true
   * now".
   *
   * Rows rather than bare ids since the far machine started *announcing* these
   * windows to the agents whose sessions they are attached to, which needs a
   * name, a title and a URL for each — see `WindowHoldsFrame.held`. The ids the
   * router acts on are derived from these rows here rather than asked for
   * separately, so the two halves of the frame cannot disagree.
   */
  windowsHeld?(): readonly HeldSession[]
  /**
   * What is running on **this** machine, asked whenever it has to be said.
   *
   * The other half of {@link onWindowCall} on the far machine's behalf, and the
   * one without which nobody over there can ever attach a window to a session
   * here: the picker in that app is built from its own ptys and from the
   * machines *it* dialled, and this desktop is neither — it dialled *out*, so
   * over there it is a device that dialled in. The list has to travel.
   *
   * A function rather than a list, read at the moment of sending, for the reason
   * {@link windowsHeld} is one: the answer changes every time somebody opens or
   * closes a terminal at this keyboard.
   *
   * Absent means this build has nothing to describe — a test harness, a host with
   * no session manager — and absence is also the switch: a frame saying "none"
   * from something that can never have any is noise on somebody's socket.
   */
  ownSessions?(): readonly RemoteSession[]
  /**
   * That machine says it is holding a browser window for these sessions of
   * **ours**. The list replaces whatever it said last.
   *
   * The mirror of {@link windowsHeld}, arriving instead of leaving, and the fact
   * without which the return path could never fire. A window is a
   * `WebContentsView` in the renderer of the app somebody is looking at; when the
   * person is sitting at *that* machine and puts a page beside a session running
   * *here*, the relation is written in that app's `browser-binding.ts` and there
   * is nothing on this machine's pty that says so. So it travels, on
   * `CAPABILITY.hostWindows`, and lands in the machine-side `WindowAskDesk`.
   *
   * Present or absent is also what this link advertises on: absent means this
   * build cannot ask, so it never claims the capability, so the far machine never
   * sends the frame. See {@link MachineLink.askWindow}.
   */
  onWindowHolds?(sessions: readonly string[], held?: readonly HeldSession[]): void
  /**
   * That machine has answered a browser verb this app asked it to run.
   *
   * Handed straight out rather than resolved here: the promise, the deadline and
   * the sentence for a machine that never answers all live on the desk, which is
   * the same file that holds them for the other direction. This link is a socket
   * and a state machine.
   */
  onWindowResult?(result: { id: string; ok: boolean; body: string }): void
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
  const name = thisMachineName()
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
   * The last refusal was *this device is not approved there yet*.
   *
   * Held rather than re-derived, because `schedule()` runs from the timer and
   * has no refusal in hand. Cleared on the first welcome — after that a refusal
   * means something else and is no longer a person about to press a button.
   */
  let awaitingApproval = false
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
    hostVersion: '',
    hostKind: null,
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
   * See {@link MachineLink.announceWindows}. A function rather than only a
   * method because the welcome handler calls it too, before the object that
   * carries the method exists.
   *
   * Two gates, and the second is the version check.
   *
   * `windowsHeld` absent means this build has no windows to hold — the headless
   * host, a test harness — and a frame saying "none" from something that can
   * never have any is noise on somebody's socket. `windows` absent from the far
   * machine's capabilities means it is a build from before this frame existed,
   * and `parseClientMessage` over there answers an unknown type by closing the
   * channel: a machine that drops off the network is a far worse outcome than a
   * window it cannot be told about.
   */
  function announceWindows(): boolean {
    if (options.windowsHeld === undefined) return false
    if (!current.capabilities.includes(CAPABILITY.windows)) return false
    /*
     * The ids come out of the rows, never from a second question.
     *
     * A machine older than this build reads `sessions` and ignores `held`, so
     * both travel; what must never happen is the two describing different sets,
     * because the far end routes on one and prints the other. One read of one
     * map is what makes that impossible. `held` is left off entirely when there
     * is nothing in it — see `WindowHoldsFrame.held` for why an empty array
     * would mean the opposite of nothing.
     */
    const held = [...options.windowsHeld()]
    return send({
      t: 'window.holds',
      sessions: held.map((row) => row.session),
      ...(held.length === 0 ? {} : { held }),
    })
  }

  /**
   * See {@link MachineLink.announceSessions}. A function for the same reason
   * `announceWindows` is one: the welcome handler sends it before the object
   * carrying the method exists.
   *
   * Two gates, and they are not the same pair `announceWindows` uses. The
   * capability here is `hostWindows`, not `windows`, and the difference is the
   * whole direction of the frame: a machine that advertised `windows` said it may
   * *ask about* windows this app holds, which is silence on whether it can hold
   * one of its own. `servesWindows` is the same word `askWindow` sends on, and it
   * has to be — this list exists so that somebody over there can attach a window
   * and the ask can come back.
   */
  function announceSessions(): boolean {
    if (options.ownSessions === undefined) return false
    if (!servesWindows()) return false
    return send({ t: 'sessions.mine', sessions: [...options.ownSessions()] })
  }

  /**
   * See {@link MachineLink.askWindow}. The same two gates as `announceWindows`,
   * pointing the other way.
   *
   * The version check is the one that matters and it is not interchangeable with
   * the one above: a machine that advertised `windows` said it may *ask* about
   * windows this app holds, which is silence on whether it holds any of its own
   * or knows the frame that asks about them. Sending on the wrong word would put
   * a `window.call` from a client on a host that has never parsed one, and
   * `parseClientMessage` over there answers an unknown type by closing the
   * channel — the link, its terminals and its transfers, lost to a page read.
   */
  function servesWindows(): boolean {
    return current.state === 'online' && current.capabilities.includes(CAPABILITY.hostWindows)
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
    /*
     * Flat while somebody is being asked to approve this machine, exponential
     * for everything else. See the note at the top of the file: the curve is
     * for a machine that is off, and this wait is for a person's finger.
     */
    const ceiling = awaitingApproval
      ? baseBackoffMs * 2
      : Math.min(maxBackoffMs, baseBackoffMs * 2 ** Math.min(attempts, 6))
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
    awaitingApproval = refused === 'unauthorized' && !everWelcomed
    publish({
      state: awaitingApproval ? 'awaiting-approval' : 'error',
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
        // Whatever this link waits for next, it is not an approval — this
        // machine has now let this one in. See `schedule`.
        awaitingApproval = false
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
          // The far machine's build and shell kind, off the same welcome. Absent
          // reads as "never said" — empty for the version, null for the kind —
          // which is what a build from before these fields sends and what the
          // panel already renders neutrally. Already cleaned and bounded by the
          // wire parser; this end only reads them.
          hostVersion: message.appVersion ?? '',
          hostKind: message.hostKind ?? null,
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
        /*
         * And which of that machine's sessions has a browser window here.
         *
         * On the welcome, for the same reason the copilot stream is opened here:
         * this socket is new after every reconnect and the far machine's table
         * was cleared with the old one. A surface cannot be relied on to notice a
         * reconnection, and nothing would tell it — so the link says it itself,
         * every time, before anybody over there can ask.
         *
         * `announceWindows` is what gates it on the capability. Sending it to a
         * machine that never advertised `windows` would be a frame that build has
         * never heard of, and `parseClientMessage` answers those by closing the
         * channel.
         */
        announceWindows()
        /*
         * And the mirror of that list: what is running *here*, so the attach menu
         * over there has this machine's sessions in it at all.
         *
         * On the welcome for the same reason as the line above — this socket is
         * new after every reconnect and the far machine dropped whatever it knew
         * with the old one — and gated on `hostWindows` inside `announceSessions`,
         * which is the capability that says the far end can hold a window for a
         * session it does not run.
         */
        announceSessions()
        return
      }
      case 'enrolled':
        // A desktop-as-guest signs in to another machine by pairing, never by
        // `enroll` — that frame is the phones' road, over a sealed relay channel
        // this link does not use — so an `enrolled` here is a host answering a
        // question this end never asked. Dropped rather than acted on, and never
        // fatal: the exhaustive switch just needs the branch to exist.
        return
      case 'window.call': {
        /*
         * A browser verb, from a session on that machine, for a window here.
         *
         * Answered on this socket whatever happens, including when there is no
         * handler and when the handler throws. The far end is inside an MCP tool
         * call with a model waiting on it, so silence there costs a whole turn
         * and produces the one thing `session-verbs.ts` was written to stop: an
         * agent that concludes it has not found the way in yet and goes looking
         * for another.
         *
         * The refusal for "no handler" is deliberately the same sentence a
         * grant refusal gets, composed on the other side of `onWindowCall`. This
         * file does not know which of the two it is and must not guess — see
         * `window-serve.ts`, which holds both.
         */
        const answer = options.onWindowCall
        if (answer === undefined) {
          send({
            t: 'window.result',
            id: message.id,
            ok: false,
            body: JSON.stringify({
              message:
                'that machine is not set up to be driven from here. Say what you would have done on the ' +
                'page and let the person do it.',
            }),
          })
          return
        }
        void answer({ sessionId: message.session, tool: message.tool, args: message.args })
          .then((result) => {
            send({ t: 'window.result', id: message.id, ok: result.ok, body: result.body })
          })
          .catch((error: unknown) => {
            send({
              t: 'window.result',
              id: message.id,
              ok: false,
              body: JSON.stringify({
                message: error instanceof Error ? error.message : 'that could not be done here',
              }),
            })
          })
        return
      }
      case 'window.holds': {
        /*
         * That machine saying which of *this* one's sessions it is holding a
         * browser window for.
         *
         * The mirror of the frame this link sends on every welcome, and it is
         * handled with the same indifference: recorded whatever the ids are and
         * whether or not this machine has ever heard of them. It is not a grant
         * and it takes nothing away — `routeWindowVerb` puts a window attached
         * *here* ahead of it — so a machine that named a session it holds no
         * window for has arranged for its own answers to be refusals.
         *
         * A frame arriving on a build that cannot use it is dropped rather than
         * refused: this app advertises `hostWindows` only when it can, so a
         * machine sending it anyway is one that ignored the negotiation, and
         * closing a working link over that would cost more than the frame does.
         */
        options.onWindowHolds?.([...message.sessions], message.held ?? [])
        return
      }
      case 'window.result': {
        /*
         * And that machine's answer to a verb this one asked for.
         *
         * Matched against the outstanding question on the desk, which drops an
         * id it is not holding in silence: an answer and this end's deadline
         * crossing on the wire is an ordinary race whose outcome is already
         * correct — the tool call has been answered — and closing the link over
         * it would turn a slow network into a dropped machine.
         */
        options.onWindowResult?.({ id: message.id, ok: message.ok, body: message.body })
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
      case 'account.state':
      case 'account.switched':
      case 'logins.state':
      case 'logins.signedin':
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
      case 'devices.rows':
      case 'devices.revoked':
        /*
         * The answer to a `devices.list` or `devices.revoke` this end asked,
         * handed to whoever asked it on its own `rid`.
         *
         * Its own block rather than a label added to the settle group above only
         * so that group's case list stays the fixed set no lane appends to;
         * nothing else is different — the roster belongs to the screen that
         * asked for it, not to link state, keyed by `rid` like every other
         * request and answer on this link.
         */
        settle(message.rid, message)
        return
      case 'devices.changed':
        /*
         * An unsolicited roster push, and this end is not its audience.
         *
         * This machine reaches another as one of *its* devices; it has no
         * screen for managing that machine's roster, so there is nothing to
         * redraw and the frame is dropped rather than published as link state.
         * The phones are the audience for this push. The case exists at all
         * because the inbound switch is exhaustive on purpose — a new
         * `ServerMessage` with no case here stops the build rather than becoming
         * somebody else's silent problem.
         */
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
      case 'settings.state':
      case 'settings.applied':
        /*
         * The answer to one `settings.read` or `settings.apply` this end asked,
         * routed by `rid` to whoever asked — the same handling the readings above
         * get, in its own block because the settle-group's shared case-label list
         * is not appended to across lanes. An answer with no waiting request falls
         * on the floor in `settle`, which is the right place for it.
         */
        settle(message.rid, message)
        return
      case 'settings.changed':
        /*
         * An unsolicited push of the server's own settings. Ignored on this
         * desktop client, deliberately: this link watches another machine's
         * *sessions*, and the server-settings pane lives on the phone clients, not
         * here. Named rather than dropped through a default so that a desktop
         * surface for it later fails the build here instead of going quietly
         * missing — the same rule this switch follows throughout.
         */
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
    /*
     * What this end can serve, and what it may ask — the two halves of the
     * window conversation, one string each.
     *
     * Every other capability in this protocol is a verb the host serves and the
     * guest sends. These two run the other way, so they are advertised from
     * here, and each only when the handler behind it was actually wired:
     *
     *  - `windows` says *"I hold browser windows and will serve asks about
     *    them"*. A build that listed it without `onWindowCall` would have a far
     *    machine sending `window.call` into a socket that answers nothing —
     *    a tool call somebody's turn is blocked on, waiting out a deadline for a
     *    feature that was never there.
     *  - `hostWindows` says *"I have sessions of my own and I may ask about
     *    windows **you** hold"*. Without `onWindowHolds` there is nowhere to put
     *    the far machine's answer, so the frame would arrive and be dropped, and
     *    a capability that produces a dropped frame is a lie told on a socket.
     *
     * They are independent. The headless host holds no windows and lists only
     * the second; a build with no desk lists only the first; a desktop lists
     * both, because on a link between two desktops either end can be the one
     * with the screen.
     */
    const capabilities = [
      ...(options.onWindowCall === undefined ? [] : [CAPABILITY.windows]),
      ...(options.onWindowHolds === undefined ? [] : [CAPABILITY.hostWindows]),
    ]
    opened.send(
      serialize({
        t: 'hello',
        protocol: PROTOCOL_VERSION,
        token: options.secrets.credential,
        device: describeThisMachine(),
        ...(capabilities.length === 0 ? {} : { capabilities }),
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
    sendFile(filePath, dir): Promise<SendFileOutcome> {
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
      return uploads.send(filePath, dir)
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
    rename(sessionId, title): boolean {
      // Refused here rather than sent and refused there, for the reason `close`
      // gives above and with more at stake than usual: a machine paired to a
      // build from before tonight has never heard of this verb, and its answer
      // to one it has never heard of is to close the channel — so a rename typed
      // into a row would have taken every remote session on that machine off the
      // screen for the two seconds it took to reconnect. The row asks the same
      // question before it offers the gesture at all, so this is the backstop
      // rather than the gate; it is here because a gate that lives only in a
      // renderer is a gate an IPC call can walk around.
      if (!current.capabilities.includes(CAPABILITY.rename)) return false
      return send({ t: 'rename', id: sessionId, title })
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
    announceWindows,
    announceSessions,
    askWindow(call: WindowCallFrame): boolean {
      if (!servesWindows()) return false
      return send(call)
    },
    servesWindows,
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
    async readAccount(sessionId) {
      /*
       * Null rather than an empty state on both of the absences that never leave
       * this machine, and that is not the split `readUsage` above makes.
       *
       * A usage bar has no previous value to keep, so it is handed a composed
       * reading with the sentence in it. The account chip does: it keeps the last
       * account it genuinely read, exactly as the control chips beside it do, and
       * an empty list would empty a menu that had rows in it a moment ago. Where
       * the sentence belongs is on the *switch* below, which is the thing
       * somebody presses.
       */
      if (current.state !== 'online') return null
      if (!current.capabilities.includes(CAPABILITY.account)) return null
      const answer = await ask(
        { t: 'account.read', rid: randomUUID(), id: sessionId },
        ACCOUNT_READ_TIMEOUT_MS,
        CAPABILITY.account,
      )
      /*
       * The session is checked as well as the frame type, for the reason
       * `readControls` gives: an `rid` only proves this is the answer to *a*
       * question this end asked, and another session's login on this session's
       * chip is precisely the confusion the per-session clusters exist to
       * prevent.
       */
      if (answer === null || answer.t !== 'account.state' || answer.id !== sessionId) return null
      return { current: answer.current, accounts: answer.accounts }
    },
    async switchAccount(sessionId, accountId) {
      /*
       * The two refusals that never leave this machine, each with its own
       * sentence, because they have different remedies — the same split
       * `setControl` makes. A link that is down is waited out; a machine whose
       * build has no `account` is updated.
       */
      if (current.state !== 'online') {
        return { ok: false, message: 'This desktop is not connected to that machine right now.', session: null }
      }
      if (!current.capabilities.includes(CAPABILITY.account)) {
        return {
          ok: false,
          message:
            'That machine is running a build that cannot change a session’s account from here. Update it and this will work.',
          session: null,
        }
      }
      const answer = await ask(
        { t: 'account.switch', rid: randomUUID(), id: sessionId, accountId },
        ACCOUNT_SWITCH_TIMEOUT_MS,
        CAPABILITY.account,
      )
      if (answer === null || answer.t !== 'account.switched' || answer.id !== sessionId) {
        /*
         * No answer, and the honest sentence for that is the one that does not
         * claim it failed — the same position `setControl` takes, and here the
         * stakes are higher. The far end starts the replacement before it sends
         * anything back, so a channel that died in between leaves a session that
         * has genuinely been switched and a window that was not told. Saying "it
         * failed" is the guess that makes somebody press again, which on a session
         * that already moved starts a *second* replacement.
         */
        return {
          ok: false,
          message: 'That machine did not answer, so it is not known whether the account was changed.',
          session: null,
        }
      }
      return { ok: answer.ok, message: answer.message, session: answer.session }
    },
    async readLogins() {
      /*
       * Null on all three absences that never leave this machine, for the reason
       * `readAccount` above answers null: a pane that is handed an empty list
       * draws "that machine has no logins", which is a claim about somebody's
       * computer, and two of the three cases would make it a false one. The
       * sentence belongs on the thing somebody presses, which is the sign-in
       * below.
       *
       * The third absence is new here and is not a version: this desktop may be
       * a *guest* over there, in which case the capability was never sent and
       * this is the same answer as an old build — which is right, because the
       * remedy is somebody at that keyboard either way.
       */
      if (current.state !== 'online') return null
      if (!current.capabilities.includes(CAPABILITY.logins)) return null
      const answer = await ask({ t: 'logins.read', rid: randomUUID() }, LOGINS_READ_TIMEOUT_MS, CAPABILITY.logins)
      if (answer === null || answer.t !== 'logins.state') return null
      return answer.accounts
    },
    async signInLogin(accountId) {
      /*
       * The two refusals that never leave this machine, each with its own
       * sentence, because they have different remedies — the same split
       * `switchAccount` makes. A link that is down is waited out; a machine that
       * does not offer this is either running an older build or does not know
       * this desktop as one of its own, and the second is not something this end
       * can tell apart from the first. So the sentence names the remedy that
       * covers both: somebody at that keyboard.
       */
      if (current.state !== 'online') {
        return { ok: false, message: 'This desktop is not connected to that machine right now.', session: null }
      }
      if (!current.capabilities.includes(CAPABILITY.logins)) {
        return {
          ok: false,
          message:
            'That machine does not manage its logins from here — it is running an older build, or this desktop is a guest on it.',
          session: null,
        }
      }
      const answer = await ask(
        { t: 'logins.signin', rid: randomUUID(), accountId },
        LOGINS_SIGNIN_TIMEOUT_MS,
        CAPABILITY.logins,
      )
      if (answer === null || answer.t !== 'logins.signedin') {
        /*
         * The honest sentence for no answer is the one that does not claim it
         * failed — the same position `switchAccount` takes. The far end starts
         * the terminal before it sends anything back, so a channel that died in
         * between leaves a session open over there that this end was not told
         * about; saying "it failed" is the guess that makes somebody press again
         * and open a second one.
         */
        return {
          ok: false,
          message: 'That machine did not answer, so it is not known whether a terminal was opened for the login.',
          session: null,
        }
      }
      return { ok: answer.ok, message: answer.message, session: answer.session }
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
