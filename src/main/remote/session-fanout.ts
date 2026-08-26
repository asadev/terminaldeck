import { emptyUsageReading, type ControlsReadingWire, type RemoteSession, type UsageWant } from './protocol'
import { reachesFolder } from './device-reach'
import type {
  CreateOutcome,
  CreateRequest,
  RemoteControlsAccess,
  RemoteAccountAccess,
  RemoteLoginsAccess,
  RemoteUsageAccess,
  SessionAccess,
  SessionHandle,
} from './server'

/**
 * Lets more than one watcher follow the same session.
 *
 * `PtyManager` reports each session's output through a single callback, which
 * the main process forwards to the window. A phone is a second watcher of the
 * same bytes, and there can be several — the laptop, the phone, a tablet — so
 * something has to fan one stream out to many without either of them stealing
 * it from the other.
 *
 * It deliberately does not own the PTY. Sessions belong to `PtyManager` and
 * outlive every remote connection, which is the whole reason attaching from a
 * phone is better than SSH: closing the phone detaches a listener, it does not
 * end the agent's work.
 *
 * ## Some sessions are not the network's business, and that was a live hole
 *
 * `list()` used to be `ptys.list()` mapped with no filter, and `attach()`
 * admitted any id that came back from that same list. Remote access is on by
 * default. So on every machine with a paired device, that device could `list`,
 * find the row whose folder is `<userData>/copilot`, `attach` to it and `input`
 * straight into the Claude CLI holding `deck-control` — bypassing the per-device
 * copilot grant, every tier check, every budget and every confirmation dialog,
 * because none of those sit between a pty and its keyboard.
 *
 * That is not a gap in an unbuilt feature; it was true of a shipped build, and
 * shipping a new phone client would not have changed it. {@link PtySource.hidden}
 * is the fix and it is deliberately a predicate rather than a list: the set is
 * the copilot's session plus every per-device copilot run, and both change while
 * the app is running.
 *
 * Two details are load-bearing:
 *
 *  - **`attach` honours it as well as `list`.** Hiding an id from the listing
 *    alone makes it unlisted, not unreachable, and these ids are recoverable —
 *    they appear in `SessionMeta.originRunId`, in alerts, and in a transcript
 *    path. `write` and `resize` honour it too, so nothing that took a handle
 *    before the predicate started answering true keeps a keyboard afterwards.
 *  - **The folder is filtered too.** `folders()` is assembled partly from the
 *    cwd of every running session, so an unfiltered list would *offer* the
 *    copilot's own folder to a phone's New Session picker. `refuseStateDirectory`
 *    would then refuse to start there, which is the right answer arriving in the
 *    wrong place: a picker should not show a row whose only outcome is a
 *    refusal.
 *
 * ## And the same hole again, one step out: every *ordinary* session
 *
 * The paragraph above closed the copilot's terminal and stopped there, because
 * the question it was asking was "which sessions are nobody's business". The
 * question it did not ask is "whose business is the rest of them", and the
 * answer until now was *everyone's*: `list()` took no device id, so a phone
 * paired to open one shared folder was sent every session running on the
 * machine, and `attach()` admitted any id from that list.
 *
 * So starting a new shell in an ungranted folder was refused while typing into
 * an agent already running in one was not. {@link PtySource.reach} is the fix,
 * `device-reach.ts` is the rule, and {@link SessionFanout.visible} is the door.
 * It is asked again on every keystroke rather than only at attach, which is what
 * makes taking a folder back immediate instead of taking effect at the next
 * reconnection — the same property `hidden` has, for the same reason.
 */

/** The slice of `PtyManager` this needs. Narrow so tests can supply a literal. */
export interface PtySource {
  list(): Array<{ id: string; title: string; cwd: string; provider?: string; exitCode: number | null }>
  write(id: string, data: string): void
  resize(id: string, cols: number, rows: number): void
  scrollback(id: string): string
  /**
   * Start a session, or say why not. Absent when this host has no PTY layer.
   *
   * Its absence is what stops the desktop advertising the `create` capability —
   * see `SessionAccess.create` — so it is optional here too rather than a
   * method that exists and always refuses.
   */
  /**
   * Give a session a name. Absent when this host has no writable title.
   *
   * Optional for the reason {@link create} and {@link close} are: its absence is
   * what stops the host advertising the `rename` capability, so a client draws
   * no Rename row rather than sending a frame that can only be refused.
   */
  rename?(id: string, title: string): boolean
  create?(request: CreateRequest): Promise<CreateOutcome>
  /**
   * End a session. Absent when this host will not let a device end one.
   *
   * Its absence is what stops the desktop advertising the `close` capability —
   * see `SessionAccess.close` — so it is optional here rather than a method that
   * exists and always refuses. Separate from {@link create} rather than implied
   * by it, because the two are genuinely separable: the public demo box starts
   * sessions for strangers and must not hand a stranger the ✕ on somebody
   * else's.
   *
   * Returns whether a session was actually ended, so "no such session" is a
   * distinct answer from "it worked". `PtyManager.kill` returns void and answers
   * this by whether the id was in its map.
   */
  close?(id: string): boolean
  /**
   * The folders one device may start a session in — the list `create` enforces,
   * sent to that device so its picker matches. Optional and absent together
   * with `create`, for the same reason it is.
   */
  folders?(deviceId: string): string[]
  /**
   * Read and set a session's model, effort and fast mode. Absent when this host
   * has no way to read a session's screen.
   *
   * Its absence is what stops the desktop advertising the `controls` capability
   * — see `SessionAccess.controls` — so it is optional here rather than a method
   * that exists and always refuses. A stub host with a pipe and no shadow
   * terminal genuinely cannot answer these, and a client told otherwise draws a
   * model menu whose every press comes back empty.
   */
  controls?: RemoteControlsAccess
  /**
   * What a session's account has spent, and how full its context window is.
   * Absent when this host has no usage layer to ask.
   *
   * Its absence is what stops the desktop advertising the `usage` capability —
   * see `SessionAccess.usage` — so it is optional here rather than a method that
   * exists and always answers nothing. A stub host with a pipe and no account
   * genuinely cannot answer these, and a client told otherwise draws a bar that
   * asks on every mount and reports nothing back.
   */
  usage?: RemoteUsageAccess
  /**
   * Whose login a session is on, and running it as a different one. Absent when
   * this host has no account store or no way to replace a session's process.
   *
   * Its absence is what stops the desktop advertising the `account` capability —
   * see `SessionAccess.account` — so it is optional here for the reason
   * {@link controls} is. A stub host has terminals and no logins, and a client
   * told otherwise draws a chip whose every row is refused after the press.
   */
  account?: RemoteAccountAccess
  /**
   * This machine's logins with no session in the question, and starting a
   * sign-in here. Absent when the shell cannot open a terminal for a person to
   * finish a login in.
   *
   * Its absence is what stops the host advertising the `logins` capability —
   * `remote/server.ts` reads it off this fanout — and until 2026-08-22 it was
   * absent *everywhere*: `host-core.ts` built `createLoginsServe` and spread it
   * into this constructor, but the field was never declared here and never
   * re-exposed on the class, so the wire read `undefined` off every host and
   * refused every `logins.read` while the assembly looked fully wired. A spread
   * bypasses excess-property checking, which is how the drop was silent.
   */
  logins?: RemoteLoginsAccess
  /**
   * Is this session none of the network's business?
   *
   * True for the copilot's own session and for every per-device copilot run.
   * Those are reachable through `copilot.*` frames, which carry parsed messages
   * and are gated per device and per tier — never as a raw pty, which is a
   * keyboard, and a keyboard on a Claude CLI with Bash is the whole machine.
   *
   * Optional, and its absence means "nothing is hidden", which is what a host
   * with no copilot layer honestly wants — `scripts/remote-host.ts` and the
   * public demo box both have a session layer and no copilot. It is a predicate
   * rather than a set because the answer changes while the app runs: the copilot
   * restarts with a new id, and a run appears the moment a granted phone taps
   * Start.
   *
   * It must never throw. It is consulted on the read path of a socket, and an
   * exception there would be a main process that dies over a `list`. The
   * implementations wrap it; see {@link SessionFanout.isHidden}.
   */
  hidden?(sessionId: string): boolean
  /**
   * What one device may touch — the answer `device-reach.ts` computes from its
   * kind and its granted folders.
   *
   * **Optional, and its absence means no per-device rule at all**, which is what
   * a host with no grant system honestly wants: `scripts/remote-host.ts` and the
   * public demo box have a session layer and no notion of who is asking, and a
   * missing key there must not be read as "this device may see nothing". A host
   * that knows about kinds supplies it and every door is enforced; a host that
   * does not supplies nothing and behaves exactly as it did.
   *
   * That is the one fail-open in this file and it is bounded by construction: a
   * `PtySource` either has the concept or does not, decided at assembly by the
   * code that also builds the stores, and there is no input from the network
   * that can turn the first into the second.
   */
  reach?(deviceId: string): { unrestricted: boolean; folders: string[] }
  /**
   * And the second axis: has this device been narrowed to *some* of the sessions
   * its folders reach?
   *
   * `reach` above answers by folder, which is the only axis this subsystem had
   * and which the header of this file already admits is coarse — a folder grant
   * is "to grant whatever else happens to be running in it". Asad, 2026-08-20:
   * *"when we give remote access we should be able to choose between running
   * sessions which ones to give and which ones not, i mean select vs all type of
   * options"*. The two sessions he wants told apart are usually in the same
   * folder, so the folder rule cannot express it.
   *
   * ANDed with `reach` rather than replacing it: ticking a session in a folder
   * this device was never granted must not share it. `session-grants.ts` holds
   * the store and the argument for what its absence means.
   *
   * **Optional, and its absence means no per-session rule at all**, for the
   * reason {@link reach}'s absence means no per-device rule: a host with a
   * session layer and no grant stores (`scripts/remote-host.ts`, the public demo
   * box) must not be read as one that shares nothing.
   *
   * It must never throw. It is consulted on the read path of a socket and on
   * every keystroke; the wrapper below fails closed if it does.
   */
  shared?(deviceId: string, sessionId: string): boolean
  /**
   * A device just started a session of its own. Tell whatever keeps the ticks.
   *
   * Called after a successful {@link create} and nowhere else. Without it, a
   * device narrowed to *Selected* would get an id back from `create` that it may
   * not attach to, because a session started after the choice is not in the
   * choice — which is the right rule for a session somebody else started and a
   * broken button for one this device asked for by name.
   *
   * Optional and absent together with {@link shared}: a host with no per-session
   * rule has nothing to tick.
   */
  noteStarted?(deviceId: string, sessionId: string): void
}

/**
 * What a session this fanout will not discuss reports about its controls.
 *
 * Every value is the "nothing was read" one, and `live: false` is the field that
 * carries the answer: it is exactly what a session that has already exited
 * reports, so a device that asks about the copilot's terminal learns nothing it
 * could not have learned by asking about an id that never existed.
 */
const NOTHING_READ: ControlsReadingWire = {
  model: { value: null, label: null, source: null },
  effort: { value: null, label: null, source: null },
  fast: { value: null, label: null, source: null },
  permission: { value: null, label: null, source: null },
  live: false,
  agent: { running: false, saw: null },
  gate: { canType: false, reason: null },
}

/**
 * What a session this fanout will not discuss reports about its usage.
 *
 * The same argument {@link NOTHING_READ} makes one field up: a device asking
 * about the copilot's terminal learns exactly what it would have learned by
 * asking about an id that never existed — nothing, in the ordinary words the bar
 * already has for nothing.
 *
 * Composed rather than reduced to a null, because a null would leave the asking
 * side to invent a sentence about a machine it is not on, and the sentence it
 * would invent ("nobody answered") is the one that makes somebody ask again.
 * `emptyUsageReading` is shared with the guest half for exactly that reason:
 * there is one idea of what an absent reading looks like on this wire.
 */
function noSuchSessionUsage(sessionId: string, want: UsageWant): Record<string, unknown> {
  return emptyUsageReading(want, `No session ${sessionId} is running.`)
}

interface Listener {
  readonly handle: SessionHandle
  readonly onData: (data: string) => void
  readonly onStatus: (status: string) => void
  readonly onExit: (exitCode: number) => void
}

export class SessionFanout implements SessionAccess {
  private readonly listeners = new Map<string, Set<Listener>>()
  /** Last status seen per session, so a late attach knows the state. */
  private readonly status = new Map<string, string>()

  /**
   * Present only when the source can start a session, and that is deliberate.
   *
   * `server.ts` decides whether to advertise the `create` capability by asking
   * whether this method exists. A class method always exists, so declaring it
   * on the prototype and having it refuse would advertise a button on every
   * host — including the ones with no terminals at all. Assigned here instead,
   * so the answer to "can this desktop start a session" is one fact rather than
   * two that have to be kept in step.
   */
  readonly create?: (request: CreateRequest) => Promise<CreateOutcome>

  /**
   * Present only when the source can end a session, assigned for the reason
   * {@link create} is: `server.ts` decides whether to advertise the `close`
   * capability by asking whether this method exists, and a prototype method
   * always exists.
   *
   * It refuses a hidden session outright, whatever the caller learned the id
   * from, and that is not redundant with the reach check in `server.ts`. The
   * copilot's own terminal is hidden from *every* device including the owner's
   * own machines, which reach everything — so without this line the one session
   * a phone must never touch would be the one session any of the owner's devices
   * could end. Refused with `false`, which is the same answer an unknown id
   * gets, and deliberately: a distinct one would confirm that the id names
   * something real. The same argument `attach` makes above, at the door that
   * matters most.
   */
  readonly close?: (id: string) => boolean

  /**
   * Give a session a name, present exactly when the pty layer can take one.
   *
   * Hidden sessions are refused here for the same reason {@link close} refuses
   * them: the copilot's own terminal is hidden from every device including the
   * owner's, and a rename is a write to it. `false` rather than a distinct
   * refusal, so the answer cannot confirm that an id names something real.
   */
  readonly rename?: (id: string, title: string) => boolean

  /**
   * Present exactly when {@link create} is, and assigned the same way for the
   * same reason: `server.ts` reads whether these methods exist to decide what to
   * advertise, and a prototype method always exists.
   */
  readonly folders?: (deviceId: string) => string[]

  /**
   * Whether one device may see and touch one session, present when the source
   * knows about device kinds **or** about per-session choice — assigned rather
   * than declared on the prototype for the same reason {@link create} is, and
   * here it decides more than an advertisement: `server.ts` reads its presence
   * to know whether this host enforces a per-device rule at all, and a prototype
   * method that always existed would make a host with no grants look like one
   * that grants nothing.
   *
   * It is the AND of the two axes — the folder rule in `device-reach.ts` and the
   * per-session choice in `session-grants.ts` — because `server.ts` funnels the
   * listing and every verb through this one predicate, and a second door for the
   * second axis would be a second door somebody forgets to lock. A host with
   * only one of the two is enforced on that one.
   */
  readonly visible?: (deviceId: string, sessionId: string) => boolean

  /**
   * Present exactly when the source can read a screen, assigned for the reason
   * {@link create} is: `server.ts` reads whether this exists to decide whether
   * to advertise the `controls` capability, and a prototype property would make
   * every host claim it.
   *
   * It refuses a hidden session outright, whatever the caller learned the id
   * from, and that is not redundant with the reach check in `server.ts`. The
   * copilot's own terminal is hidden from *every* device including the owner's
   * own machines, which reach everything — so without this line the one session
   * nothing on the network may touch would be the one session any of the
   * owner's desktops could type `/model` into. The same argument
   * {@link close} makes, at a door that also writes.
   */
  readonly controls?: RemoteControlsAccess

  /**
   * Present exactly when the source has a usage layer, assigned for the reason
   * {@link create} is: `server.ts` reads whether this exists to decide whether
   * to advertise the `usage` capability, and a prototype property would make
   * every host claim it.
   *
   * It refuses a hidden session outright, and here the refusal is guarding
   * something the other doors are not: a copilot run's usage is *this machine's
   * own subscription*, and a device that could read it would learn what the
   * owner has spent on a session the network is never told exists. Refused with
   * the same "there is no such session" a hidden `attach` gets, and for the same
   * reason — a distinct answer would confirm that the id names something real.
   */
  readonly usage?: RemoteUsageAccess

  /**
   * Present exactly when the source can answer for a session's login, assigned
   * for the reason {@link create} is.
   *
   * It refuses a hidden session outright, and this is the door where that
   * matters most: `switch` **ends a process and starts another**, so without
   * this line the one session nothing on the network may touch would be the one
   * session any of the owner's desktops could restart under a different login.
   * The same argument {@link close} makes, at a door that also spawns.
   */
  readonly account?: RemoteAccountAccess

  /**
   * Present exactly when the source can list this machine's logins and start a
   * sign-in — the machine-scoped half of the account surface, with no session
   * in the question and therefore no hidden-session wrapper. See the note on
   * {@link PtySource.logins} for the silent drop this field's absence was.
   */
  readonly logins?: RemoteLoginsAccess

  constructor(private readonly ptys: PtySource) {
    const start = ptys.create
    if (start) {
      /*
       * The spawn, and then the tick for the device that asked for it.
       *
       * Wrapped here rather than in the host's own `create`, for the reason the
       * `folders` filter below is wrapped here: this is the class that owns the
       * per-device rule, and a second copy of "a device may open what it just
       * started" living in the assembly is a second copy that can disagree.
       *
       * `noteStarted` is allowed to fail without failing the spawn. The session
       * is already running by the time this line is reached — reporting the
       * create as failed would leave a live shell nobody was told about, which
       * is strictly worse than a session the device has to tick by hand.
       */
      this.create = async (request) => {
        const outcome = await start(request)
        if (outcome.ok) {
          try {
            ptys.noteStarted?.(request.deviceId, outcome.session.id)
          } catch (error) {
            console.error('[remote] could not record the session this device started:', error)
          }
        }
        return outcome
      }
    }
    const end = ptys.close
    if (end) {
      this.close = (id) => {
        if (this.isHidden(id)) return false
        return end(id)
      }
    }
    const label = ptys.rename
    if (label) {
      this.rename = (id, title) => {
        if (this.isHidden(id)) return false
        return label(id, title)
      }
    }
    const controls = ptys.controls
    if (controls) {
      this.controls = {
        /*
         * A hidden session reads as one that is not there, which is the same
         * answer `attach` and `close` give it and for the same reason: a
         * distinct refusal would confirm that the id names something real, and
         * these ids are recoverable from an alert, a transcript path or an older
         * list.
         */
        read: (id) => (this.isHidden(id) ? Promise.resolve(NOTHING_READ) : controls.read(id)),
        apply: (id, control, value) =>
          this.isHidden(id)
            ? Promise.resolve({
                ok: false,
                message: `No session ${id} is running.`,
                reading: { value: null, label: null, source: null },
              })
            : controls.apply(id, control, value),
      }
    }

    const usage = ptys.usage
    if (usage) {
      this.usage = {
        /*
         * A hidden session reads as one that is not there on all three, which is
         * the answer `attach`, `close` and `controls` give it and for the same
         * reason. `refresh` matters most of the three: without this line, asking
         * about the copilot's own terminal would spend a 725 MB agent CLI on
         * this machine to report the owner's own spending to a device that is
         * never even told the session exists.
         */
        plan: (id) => (this.isHidden(id) ? Promise.resolve(noSuchSessionUsage(id, 'plan')) : usage.plan(id)),
        refresh: (id, force) =>
          this.isHidden(id) ? Promise.resolve(noSuchSessionUsage(id, 'refresh')) : usage.refresh(id, force),
        context: (id) => (this.isHidden(id) ? Promise.resolve(noSuchSessionUsage(id, 'context')) : usage.context(id)),
      }
    }

    const account = ptys.account
    if (account) {
      this.account = {
        /*
         * A hidden session reads as one that is not there on both, which is the
         * answer `attach`, `close`, `controls` and `usage` give it and for the
         * same reason. The empty list rather than this machine's real one: the
         * accounts are a fact about the machine and not about the session, but
         * naming them in answer to an id the network is never told exists would
         * confirm that the id names something real.
         */
        read: (id) =>
          this.isHidden(id) ? Promise.resolve({ current: null, accounts: [] }) : account.read(id),
        switch: (id, accountId) =>
          this.isHidden(id)
            ? Promise.resolve({ ok: false, message: `No session ${id} is running.`, session: null })
            : account.switch(id, accountId),
      }
    }

    /*
     * Passed through without a wrapper, deliberately: these two verbs carry no
     * session id, so there is nothing for the hidden-session rule to hide. Who
     * may ask at all is decided per device in `remote/server.ts` (`ownDevice`),
     * which is the door that owns that question.
     */
    this.logins = ptys.logins

    const offer = ptys.folders
    /*
     * The offered folder list has the hidden sessions taken out of it.
     *
     * The list a host assembles includes the cwd of every running session, so
     * without this the copilot's own folder — and every copilot run's, which is
     * the same folder — turns up in a phone's New Session picker. Filtered here
     * rather than in the host's own `folders` callback because *this* is the
     * class that knows which sessions are hidden, and a second copy of that
     * knowledge in the assembly is a second copy that can disagree.
     *
     * Compared by path rather than by id, because that is what the list carries.
     * The hidden sessions' folders are gathered from the pty list, so a folder
     * that is only ever a hidden session's cwd disappears and one that is also a
     * real project stays — which is right: a project the person opened is theirs
     * to grant whatever else happens to be running in it.
     */
    if (offer) {
      this.folders = (deviceId) => {
        const offered = offer(deviceId)
        const secret = this.hiddenFolders()
        return secret.size === 0 ? offered : offered.filter((folder) => !secret.has(folder))
      }
    }

    /*
     * The per-device door, built once and only when the host has the concept.
     *
     * It answers about a *session id* rather than a folder because this class is
     * the only thing that knows the mapping, and asking `server.ts` to look up a
     * cwd before every check would put half the rule in the file that is not
     * allowed to have any of it. An id that names nothing is refused — a caller
     * asking about a session that is not running has no business being told
     * whether it would have been allowed.
     */
    const reach = ptys.reach
    const shared = ptys.shared
    if (reach || shared) {
      this.visible = (deviceId, sessionId) => {
        if (this.isHidden(sessionId)) return false
        const session = this.ptys.list().find((s) => s.id === sessionId)
        if (!session) return false
        /*
         * Two axes, ANDed, each fails **closed**.
         *
         * The folder axis is the older one and the session axis is the one Asad
         * asked for on 2026-08-20; a session has to pass both. Neither can widen
         * the other, which is the property that matters: ticking a session in a
         * folder this device was never granted shares nothing, and granting a
         * folder does not un-tick anything inside it.
         *
         * Both throw-guards fail closed the same way {@link isHidden} does and
         * for the same reason: this is consulted on the read path of a socket
         * and again on every keystroke, an exception here is a main process that
         * dies over a `list` from a phone on a bad network, and the safe reading
         * of "I do not know whether this device may see this" is that it may
         * not.
         *
         * A host that supplies only one of the two is enforced on that one and
         * unchanged on the other — see the two doc comments on `PtySource`.
         */
        if (reach) {
          try {
            if (!reachesFolder(reach(deviceId), session.cwd)) return false
          } catch (error) {
            console.error('[remote] the device-reach rule threw; refusing the session:', error)
            return false
          }
        }
        if (shared) {
          try {
            if (!shared(deviceId, sessionId)) return false
          } catch (error) {
            console.error('[remote] the session-choice rule threw; refusing the session:', error)
            return false
          }
        }
        return true
      }
    }
  }

  /**
   * The predicate, made safe to call from a socket's data handler.
   *
   * A throw here would be an exception on the read path of a connection, which
   * is how a main process dies over a malformed `list` from a phone on a bad
   * network. It fails **closed** — a predicate that threw is a predicate whose
   * answer is unknown, and the safe reading of "I do not know whether this is
   * the copilot's terminal" is that it might be.
   */
  private isHidden(id: string): boolean {
    const ask = this.ptys.hidden
    if (!ask) return false
    try {
      return ask(id)
    } catch (error) {
      console.error('[remote] the hidden-session rule threw; treating the session as hidden:', error)
      return true
    }
  }

  /** Folders that exist only because a hidden session is running in one. */
  private hiddenFolders(): Set<string> {
    const folders = new Set<string>()
    if (!this.ptys.hidden) return folders
    for (const session of this.ptys.list()) {
      if (this.isHidden(session.id)) folders.add(session.cwd)
    }
    return folders
  }

  /* ----------------------------------------------------- from PtyManager -- */

  /** Call from the PtyManager data callback, alongside the window broadcast. */
  noteData(id: string, data: string): void {
    for (const l of this.listeners.get(id) ?? []) l.onData(data)
  }

  noteStatus(id: string, status: string): void {
    this.status.set(id, status)
    for (const l of this.listeners.get(id) ?? []) l.onStatus(status)
  }

  noteExit(id: string, exitCode: number): void {
    for (const l of this.listeners.get(id) ?? []) l.onExit(exitCode)
    // The session is gone; holding its listeners would leak them for the life
    // of the app, and every one of them is a live socket callback.
    this.listeners.delete(id)
    this.status.delete(id)
  }

  /* ---------------------------------------------------- SessionAccess -- */

  list(): RemoteSession[] {
    // No cast. The first draft asserted `as RemoteSession[]` over an object
    // carrying `exited: boolean`, which the real type does not have — the cast
    // silenced exactly the mismatch it should have surfaced.
    return this.ptys.list().filter((s) => !this.isHidden(s.id)).map((s) => ({
      id: s.id,
      title: s.title,
      cwd: s.cwd,
      provider: s.provider ?? 'shell',
      status: this.status.get(s.id) ?? 'idle',
      exitCode: s.exitCode,
    }))
  }

  attach(
    id: string,
    onData: (data: string) => void,
    onStatus: (status: string) => void,
    onExit: (exitCode: number) => void,
  ): SessionHandle | null {
    // Never attach to a session that is not there: the id came off the network,
    // and a handle for a made-up id would be a listener nothing ever removes.
    if (!this.ptys.list().some((s) => s.id === id)) return null
    /*
     * And never to one that is hidden, whatever the caller learned its id from.
     *
     * Checked here and not only in `list`, because these ids leak by design:
     * `SessionMeta.originRunId` points at them, an alert names them, and a
     * transcript path contains one. A session that is merely unlisted is a
     * session whose keyboard is protected by nobody happening to know a UUID.
     *
     * `null` is the same answer an unknown id gets, and deliberately: the caller
     * turns it into "No session <id> is running", which is what a device that
     * was never meant to see it should be told. A distinct refusal would confirm
     * that the id names something real.
     */
    if (this.isHidden(id)) return null

    // Snapshot and subscribe in the same tick, with no await between them.
    // Reading first loses whatever arrives in the gap; subscribing first sends
    // it twice. This is the only ordering with neither.
    const replay = this.ptys.scrollback(id)
    const handle: SessionHandle = { sessionId: id, replay }
    const set = this.listeners.get(id) ?? new Set<Listener>()
    set.add({ handle, onData, onStatus, onExit })
    this.listeners.set(id, set)
    return handle
  }

  detach(handle: SessionHandle): void {
    const set = this.listeners.get(handle.sessionId)
    if (!set) return
    for (const l of set) {
      if (l.handle === handle) set.delete(l)
    }
    if (set.size === 0) this.listeners.delete(handle.sessionId)
  }

  /*
   * Both of these are already unreachable for a hidden session through the
   * protocol, because `server.ts` refuses an `input` or a `resize` for a session
   * this connection has no handle for and `attach` above is what mints a handle.
   * They check anyway, and the reason is the one this class's header gives about
   * `attach`: this is a `SessionAccess`, it is injected into more than one thing,
   * and a rule that holds only because of the order of checks in a different file
   * is a rule the next caller does not have. The cost is one predicate call per
   * keystroke; the alternative is a second door into a Claude CLI's keyboard.
   */
  write(id: string, data: string): void {
    if (this.isHidden(id)) return
    this.ptys.write(id, data)
  }

  resize(id: string, cols: number, rows: number): void {
    if (this.isHidden(id)) return
    this.ptys.resize(id, cols, rows)
  }

  /** For the desktop UI: how many remote watchers a session has. */
  watcherCount(id: string): number {
    return this.listeners.get(id)?.size ?? 0
  }
}
