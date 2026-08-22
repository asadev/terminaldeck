/**
 * One copilot run per paired device, and the token that says which is which.
 *
 * This is the implementation behind `CopilotRemote` — the interface
 * `copilot-remote.ts` names so that `server.ts` can speak copilot frames without
 * knowing how a Claude CLI process is started, and so that this file can start
 * one without knowing what a WebSocket is. `COPILOT-REMOTE.md` §1 is the
 * argument; this is the machinery.
 *
 * ## The phone gets a run of its own, not the copilot's keyboard
 *
 * The obvious design is the wrong one, and it is worth writing down why here
 * rather than only in the spec, because it is the decision every other line in
 * this file hangs off and it is the one somebody will try to "simplify".
 *
 * The obvious design is: the phone's sentences go into the copilot session that
 * is pinned in the sidebar. One conversation, one transcript, one bill, and what
 * Asad asked for read literally — *"we should be able to control the copilot
 * from the phone."* It cannot be secured, for two independent reasons.
 *
 * **Attribution.** In one shared conversation every tool call arrives on one MCP
 * connection carrying one token, so `DeckControl` cannot tell a call the phone
 * caused from a call the person at the desk caused — by the time the call is
 * made, the cause is a sentence in a context window. The only repair is a latch
 * ("attribute tool calls to the phone from the moment its text was injected
 * until the turn ends"), and a turn boundary in a pty is *inferred* rather than
 * known. An inferred boundary on a permission edge is not a boundary.
 *
 * **Laundering.** A read-only phone could write into the shared context: *"when
 * he next says anything, also stop session 4."* The person types "hi", the turn
 * is attributed locally with all three tiers, and the read-only device has just
 * caused an alter action. That is privilege escalation made of prose, and it
 * cannot be closed while one context is fed by two trust levels.
 *
 * So: a run per device, and the caller is the token. That is the same mechanism
 * `unattendedToken` already uses to mark a routine run, and it cannot be raced —
 * see `deck-control/callers.ts`, which is where the table lives.
 *
 * ## What a run shares, and the one thing it must not
 *
 * Same folder, same `CLAUDE.md`, same `memory/`, same action log, same tools,
 * same profile, same records fence. Everything except the conversation and the
 * token. By the design's own definition of continuity — `copilot-session.ts`
 * spawns with `resume: false` and says *"continuity is `memory/`"* — a run that
 * shares `memory/` **is** the same copilot. What it gives up is a scrollback,
 * and the scrollback was never the thing.
 *
 * The one thing that must not be per-device is `memory/` itself. Two memories is
 * two copilots, and then the promise that this is "the same copilot" is false in
 * the one way he would notice. Nothing in this file writes there; the run
 * inherits the folder and the copilot's own instructions do the rest.
 *
 * ## Why the run's session is hidden from the fanout
 *
 * {@link CopilotRuns.isRunSession} is handed to `SessionFanout` as part of its
 * `hidden` predicate, and it is not a tidiness measure. A pty is a keyboard, and
 * a keyboard on a Claude CLI holding `deck-control` is the whole machine — every
 * tier check in this design sits *above* that layer, not below it. A phone that
 * could `attach` to its own run's pty would hold the **whole machine** no matter
 * what its grant said, because it could simply type — a keyboard on a Claude CLI
 * with `Bash` is not a tier, it is everything. That is the hole §0.1 of the spec
 * calls blocking, and it stays closed only while every run id is in that
 * predicate.
 *
 * This rule did not soften when devices gained the `alter` tier, and it is worth
 * saying why, because "full control over copilot" sounds like it should include
 * the terminal. Full control means its chat, its tools and its confirmations —
 * things that go through the gate, the budgets and the action log. A pty goes
 * through none of them: it is *underneath* the permission model, not the top of
 * it, so handing one over would not be granting the highest tier, it would be
 * leaving the building. Whether the copilot connection should offer its own
 * terminal separately is a real question and it is not this file's to answer.
 *
 * ## The token is minted here and dropped here
 *
 * 32 random bytes per run, written into a config file of that run's own through
 * `secret-file.ts`, registered in the caller table against a *function* that
 * re-reads the grant. Never a snapshot of the tiers: storing what a device held
 * when its run started would freeze them there, so unticking a box in Settings
 * would edit a store the live run no longer consults. Reading per call is what
 * makes an untick land on the **next tool call** rather than on the next
 * reconnect, and it is the property `folder-grants.ts` already has for `create`.
 */

import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { rmSync } from 'node:fs'
import { hideSession, isHiddenSession, releaseSession } from './hidden-sessions'
import { writeSecretFile } from './secret-file'
import { toConsentQuestion, toPendingRow } from './copilot-consent'
import type { CopilotOutcome, CopilotRemote, CopilotSink } from './copilot-remote'
import { remoteCopilotCaller, type CopilotAccess } from './copilot-access'
import {
  MAX_COPILOT_LOG_ROWS,
  MAX_COPILOT_MESSAGE_CHARS,
  type CopilotActionRow,
  type CopilotChatMessage,
  type CopilotGrantWire,
  type CopilotPendingRow,
  type CopilotSessionRow,
  type CopilotStateReport,
} from './protocol'
import { deviceSurface, type ConsentOutcome, type ConsentRequest } from '../deck-control/consent'
import type { Caller } from '../deck-control/surface'

/**
 * How long a run outlives the socket that started it.
 *
 * Ten minutes, and the number is chosen rather than inherited: it is the
 * shortest interval that survives a lift ride. A phone that reconnects inside it
 * gets its conversation back; outside it, a new run and a `reset` chat frame.
 *
 * The alternative — stopping the run the instant the socket drops — would make
 * a tunnel, a lock screen or a lift into a lost turn, and the turn is the
 * expensive part. The opposite alternative, never stopping, would leave a Claude
 * CLI process spending money for a phone that was put in a drawer.
 */
export const RUN_GRACE_MS = 10 * 60 * 1000

/**
 * The slice of `CallerTable` this needs.
 *
 * Structural rather than the class itself, so that a test can hand in an object
 * literal and count what was registered without standing up a `deck-control`
 * endpoint. The real one is on `DeckControlEndpoint.callers`.
 */
export interface CallerRegistry {
  set(token: string, grant: { attended: boolean; caller(): Caller; signal?: AbortSignal }): void
  delete(token: string): boolean
}

/** What a run's spawn needs to know. Assembled here, carried out by the host. */
export interface CopilotRunSpawn {
  /** The copilot's own folder — identical to the local copilot's cwd. */
  cwd: string
  /**
   * The MCP config file this run, and only this run, is launched with.
   *
   *     claude --mcp-config <path> --strict-mcp-config
   *
   * `--strict-mcp-config` is the host's decision and it is the right one for the
   * same reason it is right for the copilot at the desk: without it the run also
   * inherits whatever MCP servers happen to be in the person's own
   * `~/.claude.json`, so a phone's powers would depend on something nobody
   * thought of as part of this feature.
   */
  mcpConfig: string
  /** Which device asked. A label for the session, never a permission. */
  deviceId: string
}

/** The copilot at the desk, as a phone's state frame reports it. */
export interface CopilotDeskReport {
  status: 'stopped' | 'starting' | 'running'
  /** The account it runs as, by name. Never a credential. */
  profile: string | null
  signedIn: boolean | null
  /**
   * Could a run start at all — is there a CLI, is it signed in, is the folder
   * writable. False with a `reason` beats a Start button that fails.
   */
  available: boolean
  reason: string | null
}

/** A chat push from a run's transcript. Parsed messages, never terminal bytes. */
export interface CopilotChatUpdate {
  messages: CopilotChatMessage[]
  /** The transcript was replaced. Drop everything and take this as the whole of it. */
  reset: boolean
}

/**
 * Everything this needs from the rest of the app.
 *
 * Injected rather than imported, for the reason every other module in this
 * directory gives: the host core assembles `startSession`, the Electron shell
 * owns the transcript reader, and a module that reached for a global copy of
 * either would be a second answer to a question the app has already answered
 * once. It also means the whole of this file is exercised in a test with no
 * Electron, no pty and no network — which is the only way the grace window and
 * the revocation ordering can be driven at all.
 */
/**
 * The consent broker, as this file needs it.
 *
 * Structural rather than the class, so a test drives the whole answering path
 * against an object literal with no `deck-control` endpoint in the room — the
 * same reason {@link CallerRegistry} is structural. The real one is
 * `DeckControlHandle.consent`.
 *
 * A function returning it rather than the object, because `deck-control` starts
 * asynchronously and can fail to start at all: capturing it at assembly would
 * capture null forever. Asked per call, a device with no broker behind it simply
 * has nothing to answer, and it is told so.
 */
export interface CopilotConsent {
  list(): readonly ConsentRequest[]
  respond(id: string, approved: boolean, by: string): boolean
  callerGone(surface: string): void
}

export interface CopilotRunDeps {
  /**
   * Who reaches the copilot. Read per call, never cached; see the header.
   *
   * This has been three things and the direction of travel is the whole story.
   * It was a `CopilotGrants` — a per-device tick box riding the session channel.
   * Then a `CopilotLinks` — a separate connection per device, its own code and
   * its own credential, because a tick box was not an authorisation. It is now a
   * `CopilotAccess`, which answers from the kind chosen when the device was
   * approved, because that choice **already is** the authorisation the middle
   * step was reaching for. `copilot-access.ts` carries the argument and
   * preserves the one it superseded.
   *
   * The mechanical guarantee here is unchanged and is one line: `granted()`
   * answers nothing for a guest, so a device somebody else is holding cannot
   * reach a tool through this file no matter what any panel says.
   */
  links: CopilotAccess
  /** The confirmation gate, or null before `deck-control` has come up. */
  consent(): CopilotConsent | null
  /** Where a run's token is registered, and dropped. */
  callers: CallerRegistry
  /**
   * Where `deck-control` is listening, or null when it is not.
   *
   * Null is a refusal rather than a run without tools. A Claude CLI in the
   * copilot's folder with no `deck-control` is not a copilot — it is a general
   * assistant that will answer questions about this machine by guessing, and
   * the phone has no way to tell the difference. Better a Start button that says
   * why.
   */
  endpoint(): { url: string } | null
  /** The copilot's folder. Its config files live here, beside the copilot's own. */
  copilotRoot(): string
  /** Start the run. Resolves with the session id. */
  spawn(request: CopilotRunSpawn): Promise<string>
  isAlive(sessionId: string): boolean
  stop(sessionId: string): void
  /**
   * Type a sentence into a run.
   *
   * The desktop does this, on the phone's behalf, with prose the phone sent. The
   * phone never touches the pty — see the header — so this is the only path
   * between a `copilot.say` frame and a keystroke, and it is on this side of the
   * boundary.
   */
  say(sessionId: string, text: string): void
  /** Interrupt the current turn of one run, and of nothing else. */
  interrupt(sessionId: string): void
  /** The copilot at the desk. Watching this is the whole of the read tier. */
  desk(): CopilotDeskReport
  /** How many tools the copilot has and what they cost it every turn. */
  cost(): { tools: number; turnTokens: number }
  /** The sessions the copilot started, each linked back to the turn that made it. */
  sessions(): CopilotSessionRow[]
  /** The tail of `actions.jsonl`, already scrubbed. */
  log(options: { limit: number; before?: string }): { rows: CopilotActionRow[]; more: boolean }
  /**
   * Push a run's conversation as it changes. Returns the unsubscribe.
   *
   * A subscription rather than a poll, because the pty already emits an event
   * every time the agent writes a byte and a timer beside it would be a second
   * clock measuring something that already announced itself. The reader on the
   * other end is `chat-transcript.ts`, which is the same parser the desktop's
   * own chat view uses — one parser, one truth, and no ANSI on a phone.
   */
  chat(sessionId: string, onUpdate: (update: CopilotChatUpdate) => void): () => void
  /** Injected so a test can drive the grace window without waiting ten minutes. */
  now?(): number
  graceMs?: number
}

/** One device's live run. */
interface Run {
  /** The pty session. Hidden from the fanout for as long as this exists. */
  sessionId: string
  /** Its bearer token, so revocation has something to drop. */
  token: string
  /** The config file holding that token, so stopping can remove it. */
  configPath: string
  /**
   * Aborted when this device goes away or loses its grant.
   *
   * Handed to the caller table, which hands it to `DeckControl.call`, which
   * hands it to the consent broker, which resolves any outstanding question as
   * `caller-gone`. That reason exists for exactly this and its comment describes
   * the hole it closes: *"if that timeout fires first the client stops listening
   * — and if the person then clicked Allow, the change would land while the
   * model had already been told the call failed."* The same hole, one transport
   * further out.
   */
  abort: AbortController
  /** Undo for the chat subscription. */
  unchat: () => void
  /**
   * When the grace window ends, or null while somebody is watching.
   *
   * A timestamp rather than a `setTimeout`, so that a machine that slept through
   * the window does not wake up and grant an extra ten minutes it did not
   * measure. It is checked on every state read and every sweep; see
   * {@link CopilotRuns.reap}.
   */
  expiresAt: number | null
  startedAt: number
}

/** Everything one connection is watching with. */
interface Watcher {
  deviceId: string
  sink: CopilotSink
}

export class CopilotRuns implements CopilotRemote {
  private readonly runs = new Map<string, Run>()
  private readonly watchers = new Set<Watcher>()
  private readonly now: () => number
  private readonly graceMs: number

  constructor(private readonly deps: CopilotRunDeps) {
    this.now = deps.now ?? Date.now
    this.graceMs = Math.max(Math.trunc(deps.graceMs ?? RUN_GRACE_MS), 0)
  }

  /* ------------------------------------------------------------- the grant */

  /**
   * What this device may do, read now.
   *
   * All three tiers cross the wire, including `alter`. That is the change: the
   * grant used to stop at `act` and the absence of the third was called the
   * mechanism. It is now the *connection* that is the mechanism — a device with
   * no copilot link gets `{false,false,false}` from the store below, whatever a
   * panel might have been told. See `copilot-link.ts`.
   *
   * Rebuilt field by field rather than passed through, for the reason
   * `copilot-wiring.ts` gives about every row that crosses to a device: a field
   * added to `TierGrant` next year reaches a phone only when somebody writes a
   * line here.
   */
  granted(deviceId: string): CopilotGrantWire {
    const tiers = this.deps.links.granted(deviceId)
    return { read: tiers.read, act: tiers.act, alter: tiers.alter }
  }

  /** Does this desktop hold a copilot record for this device? */
  linked(deviceId: string): boolean {
    return this.deps.links.linked(deviceId)
  }

  /* ------------------------------------------------------ the connection */

  /**
   * Open this socket's copilot stream.
   *
   * **Nothing is proved here any more, and that is the change.** There used to
   * be a `connect` above this — redeem a six-digit code, receive a credential —
   * and an `open` that verified that credential against a stored scrypt hash.
   * Both are gone: the socket arrived already authenticated as this device by
   * `RemoteAuth`, and whether that device reaches the copilot was decided by a
   * person at this keyboard when they approved it as one of their own.
   * `copilot-access.ts` carries the argument.
   *
   * So this is a *check*, not a handshake. It is still worth making rather than
   * assuming: `server.ts` gates the frame on eligibility too, and a second
   * reading here is what keeps the answer honest if a future caller reaches this
   * class by another door. Nothing is started and nothing is spent.
   *
   * A guest gets the same sentence a device with no copilot on the far machine
   * would get, because from the device's side those are the same fact and it is
   * entitled to neither more nor less.
   */
  async open(deviceId: string): Promise<CopilotOutcome> {
    if (this.deps.links.linked(deviceId)) return { ok: true }
    return {
      ok: false,
      code: 'unauthorized',
      message: 'This device does not have the copilot.',
    }
  }

  /**
   * Every copilot connection this device had is closed.
   *
   * The run is **not** stopped: a phone locking its screen in a lift has not
   * asked for its agent to be killed mid-turn, and the grace window exists for
   * exactly that. What is not deferred is the consent — every question this
   * device raised is refused now, with `caller-gone`, because a question is
   * answered by a person watching for it and there is no longer one. Defaulting
   * to refusal is the direction the whole consent path fails in; see
   * `CopilotRemote.closed`.
   */
  closed(deviceId: string): void {
    const consent = this.deps.consent()
    if (!consent) return
    try {
      consent.callerGone(deviceSurface(deviceId))
    } catch (error) {
      console.error('[remote] could not withdraw a device’s confirmations:', error)
    }
  }

  /* --------------------------------------------------------------- reading */

  state(deviceId: string): CopilotStateReport {
    this.reap()
    const desk = this.deps.desk()
    const run = this.runs.get(deviceId) ?? null
    const cost = this.deps.cost()
    const endpoint = this.deps.endpoint()
    /*
     * The two are reported separately and that is the point.
     *
     * `desk` is the copilot pinned in the sidebar — the conversation the person
     * is having. `run` is *this device's own*, and it is the only thing the
     * phone can talk to. A phone that drew its Start button off the desk's
     * status would offer to start something that is already running, or refuse
     * to because something unrelated is.
     */
    const unavailable = endpoint === null ? 'The copilot’s tools are not running on this machine.' : desk.reason
    return {
      desk: desk.status,
      run: run === null ? null : run.sessionId,
      profile: desk.profile,
      signedIn: desk.signedIn,
      tools: cost.tools,
      turnTokens: cost.turnTokens,
      pending: this.questions().length,
      grant: this.granted(deviceId),
      available: desk.available && endpoint !== null,
      reason: desk.available && endpoint !== null ? null : (unavailable ?? null),
    }
  }

  sessions(): CopilotSessionRow[] {
    return this.deps.sessions()
  }

  /**
   * The tail of the action log, clamped here as well as at the frame layer.
   *
   * Twice on purpose. The frame layer's clamp keeps a malformed message from
   * reaching this function; this one keeps a *second caller* — a future desktop
   * path, a test, the day somebody adds an IPC for the same view — from asking
   * the log for two hundred thousand rows. `MAX_COPILOT_LOG_ROWS` is 200 because
   * the local Activity pane's 2000 is a pane and this is a relay.
   */
  log(options: { limit?: number; before?: string }): { rows: CopilotActionRow[]; more: boolean } {
    const want = options.limit ?? MAX_COPILOT_LOG_ROWS
    const limit = Math.min(Math.max(Math.trunc(Number.isFinite(want) ? want : MAX_COPILOT_LOG_ROWS), 1), MAX_COPILOT_LOG_ROWS)
    return this.deps.log({ limit, ...(options.before === undefined ? {} : { before: options.before }) })
  }

  /**
   * Every waiting confirmation, with `mine` computed for **this** device.
   *
   * Every question, not only this device's, and that is the watching half of the
   * surface rather than an oversight: the failure this feature was built against
   * is a dialog on a screen nobody is looking at, timing out in silence. A
   * device seeing a question it may not answer can still say *go and look*.
   *
   * `mine` is computed here, on the desktop, from the question's own origin. A
   * client is never asked to work it out and is never trusted with the answer —
   * `answer()` re-checks through the broker, which is where the rule lives.
   */
  pending(deviceId: string): CopilotPendingRow[] {
    const surface = deviceSurface(deviceId)
    return this.questions().map((request) => toPendingRow(request, request.origin === surface))
  }

  /**
   * Answer a confirmation on this device's behalf.
   *
   * Three things had to be true before this line runs and none of them is
   * checked here, on purpose, because each belongs somewhere it cannot be
   * forgotten. The copilot connection is open — `server.ts`, per socket. The
   * device holds `alter` — `copilotFrameAllowed`, per frame, against the store.
   * And the device owns the question — `ConsentBroker.respond`, per question,
   * with the question, so a second transport cannot arrive without it.
   *
   * What is left is to pass the surface id and report whether it was taken. A
   * false answer covers a settled question and one this device does not own, and
   * the two are deliberately indistinguishable from out there.
   */
  answer(deviceId: string, id: string, approved: boolean): boolean {
    const consent = this.deps.consent()
    if (!consent) return false
    return consent.respond(id, approved, deviceSurface(deviceId))
  }

  /**
   * Subscribe one connection, and hold the grace window open while it watches.
   *
   * Attaching starts nothing and spends nothing — that is why it is the read
   * tier — so a watching phone costs this machine one callback and one set
   * entry. What it *does* do is cancel the countdown on a run that already
   * exists, because a device that is watching again has not gone away.
   */
  watch(deviceId: string, sink: CopilotSink): () => void {
    const watcher: Watcher = { deviceId, sink }
    this.watchers.add(watcher)
    const run = this.runs.get(deviceId)
    if (run) {
      run.expiresAt = null
      // Replay, so a reconnect inside the window gets its conversation back
      // rather than a blank pane above a live agent. `reset` says "this is the
      // whole conversation" — the same contract `ChatUpdate` uses, so the merge
      // rule on the client is the one it already has.
      sink.chat(run.sessionId, [], true)
    }
    return () => {
      this.watchers.delete(watcher)
      // Only when the *last* watcher of this device leaves. Two sockets from one
      // phone — the app and a reconnect that raced the reap of the first — are
      // two places the same conversation has to appear, and the first of them to
      // close must not start a countdown on a run the second is still reading.
      if (!this.watching(deviceId)) this.beginGrace(deviceId)
    }
  }

  /* ---------------------------------------------------------------- acting */

  /**
   * Start this device's run, or answer with the one that exists.
   *
   * Idempotent by design and not by accident: a phone that reconnects and taps
   * Start — which is what a person does when a screen looks empty — must not
   * spawn a second Claude CLI in the same folder. Two runs for one device would
   * also make `stop` ambiguous, and an ambiguous stop on a process that spends
   * money is the kind of bug that shows up on a bill.
   */
  async start(deviceId: string): Promise<CopilotOutcome> {
    this.reap()
    const existing = this.runs.get(deviceId)
    if (existing) {
      existing.expiresAt = null
      return { ok: true }
    }

    const endpoint = this.deps.endpoint()
    if (endpoint === null) {
      return {
        ok: false,
        code: 'unavailable',
        message: 'The copilot’s tools are not running on this machine, so there is nothing to start.',
      }
    }
    const desk = this.deps.desk()
    if (!desk.available) {
      return {
        ok: false,
        code: 'unavailable',
        // The desk's own sentence, forwarded rather than re-composed. It was
        // written by the code that measured the problem — a missing CLI, a
        // folder that could not be created — and a second sentence written here
        // would be a guess about a machine this function did not inspect.
        message: desk.reason ?? 'The copilot cannot start on this machine just now.',
      }
    }

    /*
     * The token, then the file, then the table, then the process — and the order
     * is the design.
     *
     * The table entry has to exist before the CLI can make its first call, and
     * the CLI can make one the instant it is spawned. Registering afterwards
     * would leave a window in which a legitimate call is answered `unauthorized`
     * because the desktop had not finished writing down who was asking. The file
     * comes before the table only because a failed write must not leave a live
     * token behind for a process that was never started.
     */
    const token = randomBytes(32).toString('hex')
    const root = this.deps.copilotRoot()
    const configPath = join(root, runConfigName(deviceId))
    try {
      writeRunConfig(root, configPath, endpoint.url, token)
    } catch (error) {
      console.error('[remote] could not write a copilot run config:', error)
      return {
        ok: false,
        code: 'unavailable',
        // Not quoted. `writeSecretFile` throws when it cannot *protect* the
        // file, and its message names a path inside this person's home
        // directory; `protocol.ts`'s rule that a reason never quotes the value
        // it refused applies more sharply to a sentence drawn on a phone.
        message: 'The copilot’s tools could not be handed to this device securely.',
      }
    }

    const abort = new AbortController()
    this.deps.callers.set(token, {
      /*
       * Attended, and the flag is currently unobservable.
       *
       * `attended` means one thing: *is there a human who could be asked right
       * now.* A phone-originated turn is attended by that definition and by a
       * wider margin than most desktop turns — there is demonstrably a person,
       * they sent a message seconds ago, and they are holding a device that can
       * display a prompt. That every alter call from a phone is refused one
       * check earlier, at the tier, is not a reason to write `false` here. A lie
       * parked in the code waiting for the day a fourth tier makes it matter is
       * worse than a fact nothing reads. See `COPILOT-REMOTE.md` §4.3.
       */
      attended: true,
      /*
       * A function, re-reading the store on every request. This is the single
       * seam `reachable.test.ts` asked for by name — one import rather than a
       * hand-assembled `Caller` with `ALL_TIERS` in it — and it is what makes an
       * untick in Settings land on the next tool call.
       */
      caller: () => remoteCopilotCaller(this.deps.links, deviceId),
      signal: abort.signal,
    })

    let sessionId: string
    try {
      sessionId = await this.deps.spawn({ cwd: this.deps.copilotRoot(), mcpConfig: configPath, deviceId })
    } catch (error) {
      // Unwind everything the failed start left behind, in the reverse order it
      // was made. A token in the table for a process that does not exist is a
      // credential with no owner, which is the one kind of leak this file can
      // produce on its own.
      this.deps.callers.delete(token)
      abort.abort()
      removeQuietly(configPath)
      console.error('[remote] a copilot run could not be started:', error)
      return { ok: false, code: 'unavailable', message: 'The copilot could not be started just now.' }
    }

    const run: Run = {
      sessionId,
      token,
      configPath,
      abort,
      unchat: () => {},
      expiresAt: this.watching(deviceId) ? null : this.now() + this.graceMs,
      startedAt: this.now(),
    }
    /*
     * Hidden before it is recorded as a run, and by a wider mechanism than this
     * map.
     *
     * `isRunSession` below answers the same question, but only for as long as
     * this object is the one being asked. The fanout is assembled in
     * `host-core.ts`, which both shells build and which has no reference to a
     * run manager — so the id goes into the shared register that its `hidden`
     * predicate reads, and it goes in *first*. A pty that existed for even one
     * turn of the event loop without being hidden is a pty a `list` could have
     * named.
     */
    hideSession(sessionId)
    this.runs.set(deviceId, run)
    run.unchat = this.deps.chat(sessionId, (update) => this.pushChat(deviceId, sessionId, update))
    /*
     * **Announce the run to everything already watching, with a `reset`.**
     *
     * `watch` sends this when a connection attaches to a run that already
     * exists, and nothing sent it the other way round — for a connection that
     * attached *before* the run and then started one, which is the ordinary
     * order a phone does things in: open the tab, look, press Start. So the
     * client was left holding no baseline for the run, and `copilot.chat`
     * carries a `run` field precisely so a client can drop frames it has no
     * baseline for. Every chat frame of that run was dropped, forever, and the
     * phone's timeline stayed empty through a whole live conversation.
     *
     * Fixed on both sides on purpose. The clients now adopt a run they have
     * nothing to splice onto, because a client must not depend on the machine
     * being new enough; and the machine says it, because *"this is the whole
     * conversation now"* is a fact only the machine has, and leaving a client to
     * infer it is how the two ends drift again.
     *
     * After `runs.set` and after the reader is attached, so that a frame the
     * reader produces immediately cannot land in front of the reset that is
     * supposed to precede it.
     */
    this.pushChat(deviceId, sessionId, { messages: [], reset: true })
    this.pushState(deviceId)
    return { ok: true }
  }

  /**
   * Say something to this device's run.
   *
   * Starts one if there is none, because the alternative is a phone that has to
   * tap Start, wait, and then type — three steps for what is one intention, and
   * the middle one is a state the person cannot see. `start` is still its own
   * verb because it is the one that spends money without being asked to.
   */
  async say(deviceId: string, text: string): Promise<CopilotOutcome> {
    this.reap()
    if (!this.runs.has(deviceId)) {
      const started = await this.start(deviceId)
      if (!started.ok) return started
    }
    const run = this.runs.get(deviceId)
    if (!run) return { ok: false, code: 'unavailable', message: 'That run is no longer there.' }
    run.expiresAt = this.watching(deviceId) ? null : this.now() + this.graceMs
    try {
      this.deps.say(run.sessionId, text)
    } catch (error) {
      console.error('[remote] could not pass a message to a copilot run:', error)
      return { ok: false, code: 'unavailable', message: 'The copilot did not take that message.' }
    }
    return { ok: true }
  }

  cancel(deviceId: string): CopilotOutcome {
    this.reap()
    const run = this.runs.get(deviceId)
    // Its own run and nothing else. A cancel that could reach the desk's copilot
    // would be a read-tier-shaped verb with an act-tier effect on somebody
    // else's conversation, which is rule 11 of the spec's never-list: runs are
    // keyed by device, and two phones are two conversations.
    if (!run) return { ok: false, code: 'unavailable', message: 'There is no run to interrupt.' }
    try {
      this.deps.interrupt(run.sessionId)
    } catch (error) {
      console.error('[remote] could not interrupt a copilot run:', error)
      return { ok: false, code: 'unavailable', message: 'The copilot did not take the interrupt.' }
    }
    return { ok: true }
  }

  stop(deviceId: string): CopilotOutcome {
    const stopped = this.end(deviceId)
    if (!stopped) return { ok: false, code: 'unavailable', message: 'There is no run to stop.' }
    this.pushState(deviceId)
    return { ok: true }
  }

  /* ------------------------------------------------------------- lifecycle */

  /**
   * A device's grant changed, or the device was revoked entirely.
   *
   * The store has already been written by the time this is called — that
   * ordering is `server.ts`'s and it is deliberate, because everything else is
   * downstream of the disk and a permission that reverts *up* at the next launch
   * is worse than one that reverts down.
   *
   * What is left is to take away what the device no longer holds. Losing `act`
   * ends the run: the token leaves the table so a tool call in flight on it
   * aborts with `caller-gone`, and the process stops. Losing `read` is handled
   * by `server.ts`, which drops the subscription and pushes the new grant.
   *
   * Note what is *not* here: no re-check of whether the run is "still allowed"
   * on some cached copy of the grant. The caller function re-reads the store on
   * every request, so the rule is already live for the very next tool call
   * whether or not this method runs at all. This is what makes the screen agree
   * with the rule, rather than being the rule.
   */
  revoked(deviceId: string): void {
    // Its pending confirmations go first, and unconditionally. A device whose
    // access just changed must not be left holding a dialog it may no longer
    // answer, and re-checking the tier here would be a second copy of a rule the
    // broker already enforces against the question itself.
    this.closed(deviceId)
    if (this.granted(deviceId).act) return
    if (this.end(deviceId)) this.pushState(deviceId)
  }

  /** Every run is stopped. Called when the app quits. */
  stopAll(): void {
    for (const deviceId of [...this.runs.keys()]) this.end(deviceId)
  }

  /* ------------------------------------------------------------- consent */

  /**
   * A confirmation was raised. Show it wherever it can be shown.
   *
   * This is the `ConsentRelay` half of `deck-control/index.ts`'s fan-out, and it
   * does two different things that are easy to confuse:
   *
   *  - **Every watcher** gets a refreshed `pending` list. A question raised at
   *    the desk is still news to a device that is watching — that is the whole
   *    of what the read tier was ever worth, and it is unchanged.
   *  - **The owning device** additionally gets the question itself, with the
   *    arguments verbatim, because it is the one being asked to decide. See
   *    `CopilotConsentQuestion` for why the two carry different fields.
   *
   * The return value is narrow on purpose: it says whether an *approver* saw it,
   * not whether anybody did. A pending row is a notification, and a question
   * delivered only to people who cannot answer it must resolve `no-approver`
   * rather than sit for two minutes.
   */
  ask(request: ConsentRequest): boolean {
    // Everybody watching, including the surface that raised it: a device's own
    // pending list has to contain its own question, or a client that draws its
    // count from that list disagrees with the dialog on its own screen.
    this.pushPending()

    const deviceId = deviceIdOf(request.origin)
    if (deviceId === null) return false
    /*
     * Re-read the grant here rather than trusting that the tool call got this
     * far.
     *
     * It did — `DeckControl.call` checked `alter` before reaching the broker —
     * but the check was against a store that can change in between, and this is
     * the moment a dialog appears on somebody's phone. A device whose connection
     * was dropped a millisecond ago must not be handed the arguments of a
     * pending settings change. Cheap, and it fails closed.
     */
    if (!this.granted(deviceId).alter) return false

    const question = toConsentQuestion(request)
    let delivered = false
    for (const watcher of this.watchers) {
      if (watcher.deviceId !== deviceId) continue
      watcher.sink.ask(question)
      delivered = true
    }
    return delivered
  }

  /**
   * A confirmation closed. Withdraw it everywhere, saying where it was answered.
   *
   * Sent to every watcher rather than only to the owner, for the same reason the
   * question's pending row was: a device that showed *something needs you* has
   * to be able to stop showing it. `by` travels with it so a dialog withdrawn on
   * one surface can name the other rather than vanishing — `CopilotSettledRow`
   * carries the argument.
   */
  settled(id: string, outcome: ConsentOutcome): void {
    const row = {
      id,
      granted: outcome.granted,
      by: outcome.by,
      reason: outcome.granted ? null : outcome.reason,
    }
    for (const watcher of this.watchers) watcher.sink.settled(row)
    this.pushPending()
  }

  /**
   * Is this pty one of ours?
   *
   * Handed to `SessionFanout` as part of its `hidden` predicate, alongside the
   * desk copilot's own session id. See the header: this is the difference
   * between a phone that talks to its run through `copilot.*` frames and a phone
   * holding a keyboard on a Claude CLI with `Bash`.
   */
  isRunSession(sessionId: string): boolean {
    for (const run of this.runs.values()) if (run.sessionId === sessionId) return true
    // The shared register too, so this answers the same question the fanout is
    // actually asking rather than a narrower one that happens to agree today.
    // They can differ for exactly one instant — between `hideSession` and the
    // map assignment in `start` — and the safe answer in that instant is yes.
    return isHiddenSession(sessionId)
  }

  /* -------------------------------------------------------------- internals */

  /**
   * Every waiting confirmation, or none when the gate is not up yet.
   *
   * Asked per call rather than held, because `deck-control` starts
   * asynchronously and can fail to start at all. An empty list is the honest
   * answer in that case: there is no gate, so there is nothing waiting at it —
   * and the state frame beside it is already saying `available: false` with a
   * reason.
   */
  private questions(): readonly ConsentRequest[] {
    try {
      return this.deps.consent()?.list() ?? []
    } catch (error) {
      console.error('[remote] could not read the waiting confirmations:', error)
      return []
    }
  }

  /** Push the pending list to every watcher, each with its own `mine`. */
  private pushPending(): void {
    for (const watcher of this.watchers) {
      watcher.sink.pending(this.pending(watcher.deviceId))
    }
  }

  /** Is anybody watching this device's copilot surface right now? */
  private watching(deviceId: string): boolean {
    for (const watcher of this.watchers) if (watcher.deviceId === deviceId) return true
    return false
  }

  /** Start the countdown on a run nobody is watching any more. */
  private beginGrace(deviceId: string): void {
    const run = this.runs.get(deviceId)
    if (!run || run.expiresAt !== null) return
    run.expiresAt = this.now() + this.graceMs
  }

  /**
   * Stop every run whose grace window has passed, and every run whose pty died.
   *
   * Swept on the way into a public method rather than on a timer. The set is at
   * most one entry per paired device, the sweep is a walk over a map, and a
   * timer here would be a clock this app runs forever to notice something it is
   * about to be told anyway — the standing preference is events, not polling.
   * The one cost is that a run belonging to a device that never comes back sits
   * until some *other* device asks a question, which is a stopped agent holding
   * a pty and no money being spent.
   */
  private reap(): void {
    const at = this.now()
    for (const [deviceId, run] of [...this.runs]) {
      if (run.expiresAt !== null && run.expiresAt <= at) {
        this.end(deviceId)
        continue
      }
      // A run whose process exited on its own — the CLI crashed, the person
      // stopped it from the desk — is not a run. Dropping it here is what makes
      // the next `start` spawn a fresh one instead of answering with a corpse.
      if (!this.deps.isAlive(run.sessionId)) this.end(deviceId)
    }
  }

  /**
   * End one run and unwind everything it holds, in the reverse order of `start`.
   *
   * Every step is guarded because this runs on a quit path and on a revoke path,
   * and a throw part way through would leave the rest of the unwind undone — a
   * token in the table, or a config file on disk holding it.
   */
  private end(deviceId: string): boolean {
    const run = this.runs.get(deviceId)
    if (!run) return false
    this.runs.delete(deviceId)
    try {
      run.unchat()
    } catch (error) {
      console.error('[remote] could not drop a copilot run’s chat reader:', error)
    }
    // The token first. Everything after this line is cleanup; this line is the
    // one that means a call arriving a millisecond later is not this device's.
    this.deps.callers.delete(run.token)
    run.abort.abort()
    try {
      this.deps.stop(run.sessionId)
    } catch (error) {
      console.error('[remote] could not stop a copilot run:', error)
    }
    // After the stop, not before. An id released while its process was still
    // being torn down would be reachable for as long as the teardown took, and
    // a pty accepts input right up until it exits.
    releaseSession(run.sessionId)
    removeQuietly(run.configPath)
    return true
  }

  /** Push a chat update to every connection of one device. */
  private pushChat(deviceId: string, sessionId: string, update: CopilotChatUpdate): void {
    // `run` travels with the frame so a late update from a previous run is
    // dropped by the client rather than merged into the new conversation. The
    // check here is the desktop half of the same rule: a reader that outlived
    // its run must not push into the one that replaced it.
    const run = this.runs.get(deviceId)
    if (!run || run.sessionId !== sessionId) return
    const messages = update.messages.map(truncateMessage)
    for (const watcher of this.watchers) {
      if (watcher.deviceId !== deviceId) continue
      watcher.sink.chat(sessionId, messages, update.reset)
    }
  }

  /** Push the state to every connection of one device. */
  private pushState(deviceId: string): void {
    const state = this.state(deviceId)
    for (const watcher of this.watchers) {
      if (watcher.deviceId !== deviceId) continue
      watcher.sink.state(state)
    }
  }
}

/* --------------------------------------------------------------- helpers -- */

/**
 * Which device raised a question, or null when the desk did.
 *
 * The inverse of `deviceSurface`, and it lives here rather than beside that
 * function because the *composing* side is `deck-control`'s and the *reading*
 * side is the relay's. A device id is opaque and may contain anything
 * `device-auth.ts` mints — base64url, which has no colon — so splitting on the
 * first colon is exact rather than approximate.
 */
function deviceIdOf(origin: string): string | null {
  if (!origin.startsWith('device:')) return null
  const id = origin.slice('device:'.length)
  return id === '' ? null : id
}

/**
 * Cut a bubble that is too long, and say that it was cut.
 *
 * **Cut with a flag, never chunked.** `TranscriptMessage.truncated` set the
 * precedent and the argument is the same: a chat bubble is read rather than
 * scrolled, and a 400 KB agent answer split across fifty bubbles is not the
 * conversation, it is a transcript of one. The flag is what keeps it honest — a
 * client can show that there is more and offer the desktop, which has the file.
 */
function truncateMessage(message: CopilotChatMessage): CopilotChatMessage {
  if (message.text.length <= MAX_COPILOT_MESSAGE_CHARS) return message
  return { ...message, text: message.text.slice(0, MAX_COPILOT_MESSAGE_CHARS), truncated: true }
}

/**
 * The config file name for one device's run.
 *
 * The device id is hashed down to an alphabet this function controls rather than
 * interpolated, because a device id reaches this process from a paired client
 * and a path built out of one is a path traversal waiting for the day the
 * pairing code stops being generated here. `device-auth.ts` already constrains
 * the alphabet; this does not rely on it, for the reason `secret-file.ts` gives
 * about not depending on a check that lives in another file.
 */
export function runConfigName(deviceId: string): string {
  const safe = [...deviceId].map((ch) => (/[a-zA-Z0-9]/.test(ch) ? ch : '-')).join('').slice(0, 64)
  return `deck-control-device-${safe || 'unnamed'}.json`
}

/**
 * The same bytes `mcpConfigFor` writes, with this run's token in them.
 *
 * Deliberately not that function: it takes a `DeckControlEndpoint` and chooses
 * between the two *fixed* tokens on it, and a third caller passing "the other
 * one" would be a signature that grows a mode flag every time a caller is added.
 * The shape is a four-line JSON object and duplicating it costs nothing; sharing
 * a function whose job is to pick between two secrets costs the distinction
 * between them.
 */
function writeRunConfig(dir: string, path: string, url: string, token: string): void {
  /*
   * `dir` and the full `path`, which is `writeSecretFile`'s shape rather than a
   * redundant pair: it creates the directory 0700 *before* the temp file exists,
   * because on Windows it is the folder's inheritable ACL that makes the temp
   * file protected from the instant it is created rather than a moment later.
   *
   * Through `writeSecretFile`, never `writeFileSync`.
   *
   * `secret-file.test.ts` sweeps this directory for exactly that mistake, and
   * the reason is on that module: 0600 on POSIX, and on Windows an ACL naming
   * this account alone, because a mode there is a synthesised number rather than
   * a permission and a second administrator on the machine would otherwise read
   * this file directly with nothing to notice afterwards. What is in it is a
   * bearer token for a server that can start sessions and run tools.
   */
  writeSecretFile(
    dir,
    path,
    `${JSON.stringify(
      {
        mcpServers: {
          'deck-control': { type: 'http', url, headers: { Authorization: `Bearer ${token}` } },
        },
      },
      null,
      2,
    )}\n`,
  )
}

/**
 * Remove a config file, and treat a failure as nothing.
 *
 * The token in it is already dead — it left the caller table before this is
 * called — so a file left behind is a file that authenticates nothing. Throwing
 * here would abort a quit path over litter.
 */
function removeQuietly(path: string): void {
  try {
    rmSync(path, { force: true })
  } catch (error) {
    console.error('[remote] could not remove a copilot run config:', error)
  }
}
