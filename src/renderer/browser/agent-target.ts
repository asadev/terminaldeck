import { folderName } from '../session-title'
import { machineChoices, readMachines } from './machines-bridge'

/**
 * Which session the browser sends to — the model behind the picker.
 *
 * ## Why this exists at all
 *
 * Everything the browser could hand an agent went to `activeSessionId`: the tab
 * that happened to be focused behind the browser. He found that on camera on
 * 2026-08-16 and was unambiguous about it:
 *
 * > *"it will just randomly send to anyone whatever I say here… there should be
 * > an arrow next to it and I can choose which session I'm going to send it to
 * > and then I send, and I can make that specific popup from that browser to
 * > specifically link to one session. So every time when I send, it
 * > automatically sends to that specific session only, not to anyone… If I open
 * > a new browser, then I will have to select. Until I don't select the session
 * > this button will stay gray, will not be clickable."*
 *
 * So the rules, in his order, and each of them is pinned by a test below this
 * file:
 *
 *  1. **Nothing is chosen by default.** Not the focused session, not the newest,
 *     not the only one. An automatic choice is exactly the behaviour being
 *     replaced, and it is worse for being invisible.
 *  2. **The send control is dead until something is chosen.** Disabled, not
 *     hidden, and not "send anyway".
 *  3. **The choice sticks for that browser window** and is used by every send it
 *     makes — an element, a flow, a screenshot — until it is changed.
 *  4. **A dead session is not a target.** Its process has exited; writing to it
 *     goes nowhere and reports success.
 *
 * ## Why the labels are built here rather than read from the sidebar
 *
 * The rail's numbering lives in `renderer/shell`, which this file may not reach
 * into, so the scheme is reproduced rather than imported: sessions are grouped
 * by project folder and numbered in the order the main process lists them,
 * which is the order they were created. That is what makes the picker read
 * `terminaldeck · Session 2` — the same words as the row he would have clicked.
 *
 * ## Sessions on another machine: listed, named, and typed into
 *
 * This list used to be `session:list` and nothing else, which is this machine's
 * ptys and only this machine's ptys. That was invisible right up until the
 * browser learned to open another machine's `localhost`
 * (`BrowserWorkspace.openThere`, the 2026-08-18 change): he would be looking at
 * a page served by his PC, inspect an element on it, open this picker, and find
 * nothing but the sessions on the Mac in front of him. **A screen that quietly
 * shows a subset is the failure mode this project keeps finding**, so the rows
 * were added.
 *
 * They were then listed and *refused*, for a whole day, and that was worse. Asad
 * found it on camera on 2026-08-20:
 *
 *   > *"I cannot send from my local browser to remote one, remote session… So
 *   > let's make it, if the browser is local, it should be able to send to the
 *   > remote session too. Not just local sessions. **If they are visible here,
 *   > they should be working too.** Okay, make sure it works cross channel."*
 *
 * He is right, and the refusal was never a rule about what he is allowed to do —
 * it was this file declining to pretend a send had happened. The wire genuinely
 * could not carry one. The only verb on the remote protocol that put characters
 * into a session was `input`, and `server.ts` will not act on it unless this
 * desktop is **attached** to that session — *"Attachment is the authorisation"*,
 * which is load bearing, because without it any device that had seen or guessed
 * an id would have a keyboard on somebody's agent. And attaching in order to
 * send was not free: one connection per machine, handles keyed by session id, so
 * a second attach for a session a pane already holds makes the host drop the
 * pane's handle and replay its whole scrollback into a terminal he is reading.
 *
 * ## What closed it
 *
 * Exactly what the note here used to prescribe: **a verb that authorises typing
 * without subscribing to output.** `session.send` on the wire, gated on
 * `mayTouch` — the device's folder reach — and on nothing else, which is the
 * same door `controls.apply` has always gone through to type `/model` into a
 * remote agent. No attach, no handle, no scrollback replayed at anybody.
 *
 * So {@link resolveTarget} no longer refuses a remote row, and the send routes
 * on `machineId`: local rows through `writeToSession`, remote rows through
 * `sendToMachineSession`. The one asymmetry that survives is worth stating —
 * a remote send is a **round trip that answers**, because the far machine can
 * refuse (the folder was unshared, the session exited a moment ago) and a popup
 * that said "Sent" about a line dropped on the floor is the thing this whole
 * file exists to not do.
 *
 * ## The labels are built here, and now they carry the name somebody typed
 *
 * The rail's numbering lives in `renderer/shell`, which this file may not reach
 * into, so the scheme is reproduced rather than imported: sessions are grouped
 * by project folder and numbered in list order, which is creation order. That is
 * what makes a row read `terminaldeck · Session 2` — the same words as the row
 * he would have clicked.
 *
 * What that scheme could not say was a **name**. Asad, on the same recording,
 * looking at the copilot in this dropdown:
 *
 *   > *"Let's say copilot session one — and it should call commander also,
 *   > because I name it as commander, but it is showing copilot."*
 *
 * `copilot · Session 1` was computed entirely from the session's `cwd`, whose
 * last segment happens to be the word `copilot`. Nothing in this file had ever
 * looked at what the session is *called*. So {@link readSessions} now takes the
 * names the window already knows — the rail's own titles for local sessions, and
 * the title the far machine sends for remote ones — and a session with a name
 * says its name where the number used to be. The number is what is left for a
 * session nobody has named, which is most of them.
 */

/** One session, as a picker needs to see it. Mirrors `SessionMeta`. */
export interface AgentSession {
  id: string
  /** Absolute path of the project folder it runs in. */
  cwd: string
  /** What the picker calls it: `folder · Session 2`. */
  label: string
  /** Which agent CLI is in it, shown when a folder holds more than one kind. */
  provider: string
  /** Its process has exited. Listed, but never a target. */
  ended: boolean
  /**
   * What this session is called, or empty when nobody has named it.
   *
   * Empty is the ordinary case and is not a missing value: most sessions are
   * known by their folder and their position in it, which is what {@link label}
   * falls back to. A non-empty name is either something a person typed into the
   * rail or something the agent titled itself, and either way it is what the
   * rest of the window is calling that session — so it is what this picker calls
   * it too.
   */
  name: string
  /**
   * The paired machine it runs on, or empty for this one.
   *
   * Empty is not a missing value and never should be read as one: it is the
   * answer for every session on this computer. Since `session.send` landed on
   * the wire it no longer decides whether a row can be sent to — it decides
   * *how*, which is the routing in `useAgentTarget`.
   */
  machineId: string
  /** What that machine is called here, or empty for this one. Never guessed. */
  machineName: string
}

/** The slice of `window.deck` this needs. Everything else about it is irrelevant. */
export interface AgentSessionBridge {
  /**
   * Every session this picker should list.
   *
   * The answer is either a bare array — this machine's sessions, which is what
   * `session:list` returns and what a test or a host component hands in — or an
   * {@link AgentTargets} envelope, which is what the adapter below builds once
   * it has a machines half to ask as well. {@link readSessions} reads both, and
   * both are real: the bare array is not a legacy shape, it is the honest answer
   * from a build with no remote machines wired into it.
   */
  listSessions(): Promise<unknown>
  writeToSession(id: string, data: string): void
  /**
   * The set of sessions changed. The payload is deliberately unspecified.
   *
   * It used to be exactly `session:created`, carrying a `SessionMeta`. It is now
   * that channel *and* `machines:state`, which carries a whole machines view,
   * because a session starting on the other computer arrives inside that push
   * and nowhere else — the remote wire has no "a session appeared" event of its
   * own, only a new list. Nothing reads the argument (the one consumer,
   * `useAgentTarget`, re-reads the list on any of these and says at length why
   * patching it would drift), so widening what can arrive costs nothing and
   * leaving the machine pushes out would leave the picker stale for exactly the
   * rows this file was extended to show.
   */
  onSessionCreated(callback: (meta: unknown) => void): () => void
  onSessionExit(callback: (id: string, exitCode: number) => void): () => void
}

/**
 * The other half, when the preload has one.
 *
 * Split out rather than folded into the interface above, and the split is the
 * same one `machines-bridge.ts` argues for its own four methods: a preload that
 * predates remote machines must still get a working picker for the sessions on
 * this computer. Gating the whole thing on `listMachines` would mean an older
 * build losing the send button entirely, which is a worse answer to "this build
 * is old" than showing it the sessions it does have.
 *
 * Named `*Bridge*` on purpose: `src/preload/contract.test.ts` reads every
 * interface in the renderer whose name contains it and fails when the preload
 * has stopped exposing one of these. Both of these are exposed today — the
 * Machines panel and the browser's machine picker already call them — and this
 * is what keeps them exposed.
 */
export interface AgentMachinesBridge {
  listMachines(): Promise<unknown>
  onMachinesState(callback: (view: unknown) => void): () => void
}

/**
 * Both answers, kept apart.
 *
 * Merged here rather than in the main process because the merge is a *labelling*
 * decision — which machine a row belongs to, what it is called, how it is
 * numbered — and that lives in this file for the same reason the rest of the
 * labelling does. `session:list` and `machines:list` stay what they are; nothing
 * else that calls either of them has to learn about the other.
 */
export interface AgentTargets {
  /** Whatever `session:list` answered: this machine's ptys. */
  here: unknown
  /** Whatever `machines:list` answered, or null when there is no machines half. */
  elsewhere: unknown
}

const SESSION_METHODS = [
  'listSessions',
  'writeToSession',
  'onSessionCreated',
  'onSessionExit',
] as const satisfies readonly (keyof AgentSessionBridge)[]

const MACHINE_METHODS = [
  'listMachines',
  'onMachinesState',
] as const satisfies readonly (keyof AgentMachinesBridge)[]

function hasAll(record: Record<string, unknown>, methods: readonly string[]): boolean {
  return methods.every((method) => typeof record[method] === 'function')
}

/**
 * Read the session half of the preload, or null.
 *
 * Null is a real state and the picker draws it: a build whose preload predates
 * these methods gets a sentence saying so rather than a select that cannot be
 * filled, and — critically — no fallback that quietly sends somewhere else.
 *
 * What comes back is an *adapter* rather than the preload itself, which it used
 * to be. That is the whole mechanism by which remote sessions reach this picker:
 * the one consumer asks for a list and gets one, and the fact that two channels
 * were asked is this file's business. The alternative was to teach the hook that
 * owns the state about machines, which would have put the same merge in a second
 * place the moment anything else grew a session picker.
 */
export function resolveAgentSessions(host: unknown): AgentSessionBridge | null {
  if (typeof host !== 'object' || host === null) return null
  const record = host as Record<string, unknown>
  if (!hasAll(record, SESSION_METHODS)) return null
  const sessions = host as unknown as AgentSessionBridge
  const machines = hasAll(record, MACHINE_METHODS) ? (host as unknown as AgentMachinesBridge) : null
  if (!machines) return sessions
  return {
    async listSessions(): Promise<AgentTargets> {
      const here = await sessions.listSessions()
      // A machines half that throws costs the remote rows and nothing else. The
      // sessions on this computer are the ones that can actually be sent to, so
      // losing them because a link was mid-reconnect would be trading the
      // working half of the picker for the half that is only ever informative.
      const elsewhere = await machines.listMachines().catch(() => null)
      return { here, elsewhere }
    },
    writeToSession: (id, data) => sessions.writeToSession(id, data),
    onSessionCreated(callback) {
      const offSessions = sessions.onSessionCreated(callback)
      const offMachines = machines.onMachinesState(callback)
      return () => {
        offSessions()
        offMachines()
      }
    },
    onSessionExit: (callback) => sessions.onSessionExit(callback),
  }
}

/** One session out of whatever the bridge sent, or null if it is not one. */
function readSession(
  value: unknown,
): { id: string; cwd: string; provider: string; ended: boolean; title: string } | null {
  if (typeof value !== 'object' || value === null) return null
  const record = value as Record<string, unknown>
  if (typeof record.id !== 'string' || record.id === '') return null
  return {
    id: record.id,
    cwd: typeof record.cwd === 'string' ? record.cwd : '',
    provider: typeof record.provider === 'string' ? record.provider : '',
    // `exitCode` is null while the process lives and a number once it has gone.
    ended: typeof record.exitCode === 'number',
    // Whatever the far end or the main process is calling it. `nameOf` decides
    // whether that is worth printing; a title that is only the folder name again
    // is not a name and would print `terminaldeck · terminaldeck`.
    title: typeof record.title === 'string' ? record.title : '',
  }
}

/**
 * A session's name, or empty when it has none worth printing.
 *
 * Two things arrive here wearing the same field. The main process seeds every
 * session's `title` with `basename(cwd)` at spawn, and the far machine sends
 * that same seed for its own sessions — so a title equal to the folder is not a
 * name, it is the absence of one, and printing it gives `copilot · copilot`. A
 * title that has moved on from the folder is either the agent titling itself or
 * a person typing in the rail, and both are names.
 *
 * The window's own answer wins over the wire's when there is one: the rail is
 * where a rename is typed, and a rename that is only in this window has not
 * reached anybody's `session:list` yet. That is the whole of why `named` is a
 * parameter rather than something read from the row.
 */
function nameOf(id: string, cwd: string, title: string, named: NameSource): string {
  const typed = named.get(id)
  if (typed !== undefined && typed !== '') return typed
  const folder = cwd ? folderName(cwd) : ''
  return title && title !== folder ? title : ''
}

/**
 * Names the window knows that a session list does not carry.
 *
 * A `Map`, taken as a parameter, so this module stays pure and the one consumer
 * decides where the names come from — see `useAgentTarget`, which assembles it
 * from the session store and from the copilot's own identity file. An empty map
 * is a real answer and the honest one for a caller with nothing better: every
 * row falls back to its number.
 */
export type NameSource = ReadonlyMap<string, string>

const NO_NAMES: NameSource = new Map()

/**
 * `folder · Session 2`, or `folder · commander` once somebody has named it.
 *
 * One function because the two lists have to number the same way. A remote
 * session that read `Session 4` while the rail beside it read `Session 2` would
 * be the picker disagreeing with the app about which session it means, which is
 * the failure this labelling scheme exists to avoid in the first place.
 *
 * The name displaces the number rather than joining it. `copilot · commander ·
 * Session 1` is three facts about one row in a dropdown that is 26rem wide, and
 * the number is the least useful of them the moment there is a name: the number
 * exists to tell two sessions in one folder apart, and a name already does.
 */
function labelFor(cwd: string, index: number, name: string): string {
  const folder = cwd ? folderName(cwd) : ''
  const tail = name || `Session ${index}`
  return folder ? `${folder} · ${tail}` : tail
}

/** This machine's sessions, in the order the main process listed them. */
function sessionsHere(value: unknown, named: NameSource): AgentSession[] {
  if (!Array.isArray(value)) return []
  const counts = new Map<string, number>()
  const out: AgentSession[] = []
  for (const entry of value) {
    const session = readSession(entry)
    if (!session) continue
    // Numbered whether or not it has a name, and that is deliberate: the number
    // is a position in a folder, so a session that is named must still consume
    // its place or the two below it renumber every time somebody types in the
    // rail.
    const index = (counts.get(session.cwd) ?? 0) + 1
    counts.set(session.cwd, index)
    const name = nameOf(session.id, session.cwd, session.title, named)
    out.push({
      id: session.id,
      cwd: session.cwd,
      provider: session.provider,
      ended: session.ended,
      name,
      label: labelFor(session.cwd, index, name),
      machineId: '',
      machineName: '',
    })
  }
  return out
}

/**
 * Everything running on the machines this desktop is connected to.
 *
 * Empty for a machine that is offline without any test for it: `guest.ts`
 * publishes `sessions: []` the moment a link goes down, so a machine that has
 * gone quiet drops out of this list by telling the truth rather than by being
 * filtered. A second check on `state` here would be a second source for the same
 * fact, and the two would eventually disagree.
 *
 * The names come from `machineChoices`, which is the *same* function that names
 * the machines in the browser's own machine picker, one dropdown away. Reusing
 * it means the two cannot call the same PC different things; it also carries the
 * rule for a machine that has never been renamed, which reads `That PC` rather
 * than an empty gap. Its `ports` and `refusal` are computed and ignored here,
 * and that is the price of having one naming rule instead of two.
 */
function sessionsElsewhere(value: unknown, named: NameSource): AgentSession[] {
  const view = readMachines(value)
  const names = new Map(machineChoices(view).map((choice) => [choice.id, choice.name]))
  const counts = new Map<string, number>()
  const out: AgentSession[] = []
  for (const link of view.links) {
    const machineName = names.get(link.id) ?? ''
    // A link whose machine is not in the list is one this window can say nothing
    // about — it was forgotten while connected, or the two halves of the view
    // disagree. `lostMachine` in `machines-bridge.ts` takes the same line about
    // the same gap: a row that cannot be named is not a row.
    if (machineName === '') continue
    for (const session of link.sessions) {
      // Numbered per folder *per machine*. Sharing the counter with this
      // computer would make `terminaldeck` on the PC read `Session 3` because
      // two are open here, which is a number that matches nothing on either
      // screen.
      const key = `${link.id}\u0000${session.cwd}`
      const index = (counts.get(key) ?? 0) + 1
      counts.set(key, index)
      // The far machine's own word for it. A rename typed on *that* keyboard
      // rides here in `RemoteSession.title`, which is the only channel it has;
      // `named` is this window's map and holds nothing about another computer's
      // sessions, so it contributes nothing to this branch and is passed anyway
      // rather than forked into a second rule.
      const name = nameOf(session.id, session.cwd, session.title, named)
      out.push({
        id: session.id,
        cwd: session.cwd,
        name,
        label: `${machineName} · ${labelFor(session.cwd, index, name)}`,
        provider: session.provider,
        ended: session.exitCode !== null,
        machineId: link.id,
        machineName,
      })
    }
  }
  return out
}

/**
 * Turn the bridge's answer into a labelled list.
 *
 * The numbering is per project and follows list order, which is creation order
 * — the same rule the sidebar uses, so the two agree about which session is
 * "Session 2". A session with no folder is numbered in its own group rather
 * than being thrown in with the first project's, because it belongs to none.
 *
 * This machine's sessions come first and the remote ones follow, grouped by the
 * machine they run on. Same order as the machine picker beside it, where "this
 * machine" is always the first row — and the useful order besides, since the
 * rows at the top are the ones a send can actually reach.
 */
export function readSessions(value: unknown, named: NameSource = NO_NAMES): AgentSession[] {
  // A bare array is this machine's sessions and nothing else. See the note on
  // `AgentSessionBridge.listSessions`: that is a real answer, not an old one.
  if (Array.isArray(value)) return sessionsHere(value, named)
  if (typeof value !== 'object' || value === null) return []
  const envelope = value as Record<string, unknown>
  return [
    ...sessionsHere(envelope.here, named),
    ...sessionsElsewhere(envelope.elsewhere, named),
  ]
}

/**
 * The session a send would actually reach, given what is chosen.
 *
 * Null in three cases, and they are the same answer to the user: nothing
 * chosen, a choice that is no longer in the list, and a choice whose process has
 * exited. The last is the case he named — *"if that session dies, I need to
 * select again another session"* — and it is the reason this is a function over
 * the live list rather than a stored object.
 *
 * There was a fourth, and it is gone: a session on another machine used to
 * resolve to null, because the wire had no verb that could type into one without
 * attaching. `session.send` is that verb, so a remote row is now a target like
 * any other and the machine it is on decides the *route* rather than the answer.
 * The header carries the mechanism.
 */
export function resolveTarget(
  chosenId: string,
  sessions: readonly AgentSession[],
): AgentSession | null {
  if (!chosenId) return null
  const found = sessions.find((session) => session.id === chosenId)
  if (!found || found.ended) return null
  return found
}

/**
 * Why the send button is off, in one sentence, or empty when it is on.
 *
 * A disabled control with no explanation is the thing this whole change is
 * against, so the disabled state carries its own reason and every reason is a
 * different sentence.
 *
 * Two of them are about the boundary between this machine and the others, and
 * they only appear when that boundary is what is in the way: a person with no
 * paired machines never reads a word about machines. Saying "only sessions on
 * this machine are listed" on a desktop that has never been paired to anything
 * would be noise on the sentence that is shown before every single send.
 */
export function whyDisabled(
  chosenId: string,
  sessions: readonly AgentSession[],
  available: boolean,
): string {
  if (!available) return 'This build cannot list your sessions, so there is nothing to send to.'
  if (sessions.length === 0) return 'No sessions are open. Start one, then choose it here.'
  if (!chosenId) return 'Choose a session first — this will not guess one for you.'
  const found = sessions.find((session) => session.id === chosenId)
  if (!found) return 'That session is gone. Choose another one.'
  if (found.ended) return `${found.label} has exited. Choose another one.`
  /*
   * Two sentences about machines used to live here — one for a list that was
   * entirely remote, one for a remote row that had been chosen — and both were
   * refusals. They are gone with the refusal itself: a session on another
   * machine is a target now, so there is nothing left to explain before the
   * press. What can still go wrong goes wrong *during* the send, on the far
   * machine, and comes back as that machine's own sentence; `useAgentTarget`
   * shows it there rather than predicting it here.
   */
  return ''
}
