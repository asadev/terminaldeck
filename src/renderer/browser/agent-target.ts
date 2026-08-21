import { SUBMIT_GAP_MS, terminalWrites } from '../chat/attach/mentions'
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
 * ## Terminals on servers, which were the third of three lists
 *
 * `session:list` is this machine's ptys and `machines:list` is the machines
 * running this app. A shell on a **server** is neither, and for the same reason
 * it is neither in any other file: nothing at the far end keeps it, so there is
 * nothing to ask — the list is this window's own (`machines/servers/
 * server-sessions.ts`, which opens with that argument). It reached the rail, the
 * strip and the window bar and never reached this picker.
 *
 * Asad found the gap with the server's own page on screen, 2026-08-21:
 *
 *   > *"Now let's say I give same to Office PC, if it will show. **It is not
 *   > even showing this session**, by the way, Office PC session. So this is
 *   > another thing to remember."*
 *
 * The page he had just screenshotted was being served by Office PC and the one
 * session running on Office PC was the one session he could not send it to. So
 * {@link readSessions} takes the open shells as its third argument — a
 * parameter rather than a fourth channel on the bridge, because they are React
 * state in this window and there is no IPC call that could answer for them — and
 * they are labelled by the same {@link labelFor} the other two lists use, under
 * the server's name where a machine's name goes.
 *
 * A shell that is still opening is listed and is **not** a target: this window
 * mints a tab id before it asks the server for anything, so for a moment there
 * is a row with no handle behind it. It says so in {@link whyDisabled} rather
 * than being hidden, because the row is already in the rail and a picker that
 * disagrees with the rail about what is open is the failure this file exists to
 * avoid.
 *
 * ## Send means sent
 *
 * The last thing this file learnt is that a line is not delivered until it has
 * been **submitted**. Asad, 2026-08-21, having pressed Send and then found the
 * message sitting in the target session's prompt box:
 *
 *   > *"When we send from here, in the session, it should not be waiting us to
 *   > come and send… Just make it like this send actually send and pushed inside
 *   > the session also."*
 *
 * The write was `writeToSession(id, line)` with no return at all, and the fix is
 * not to append one: `chat/attach/mentions.ts` measured the CLI classifying any
 * stdin chunk of 64 bytes or more as **pasted text**, where a carriage return is
 * a newline rather than submit — and every line this picker composes carries a
 * screenshot path, so every one of them is over that. {@link submitLine} is the
 * two writes that work, `SUBMIT_GAP_MS` apart, and it is the same pair for all
 * three routes because it is the same pty on the other end of each of them.
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
  /**
   * What the computer it runs on is called here, or empty for this one.
   *
   * A paired machine's name or a server's, because the two rows say it in the
   * same place and every sentence about a failed send names it the same way.
   * Never guessed: a machine this window cannot name is not listed at all.
   */
  machineName: string
  /**
   * The server it is a shell on, or empty.
   *
   * Never set at the same time as {@link machineId}: a session runs on this
   * computer, on a machine running this app, or on a server, and those are three
   * different routes rather than three shades of one. `session-transfer.ts`
   * reads both fields off this row for the same reason — where the file has to
   * end up is the same question as where the line has to go.
   */
  serverId: string
  /**
   * The far end's handle for that shell, or empty while it is still opening.
   *
   * The picker chooses server rows by their **tab** id, which this window mints
   * before it asks the server for anything, so the row can exist for a moment
   * with no channel behind it. This is the handle `servers:shell:write` actually
   * takes, and its emptiness is what {@link resolveTarget} refuses on — an
   * honest "not yet" rather than a press that writes into nothing.
   */
  shellId: string
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
 * The names this window is using, out of the two places it keeps them.
 *
 * A function rather than a `useMemo` body, for the reason every rule in this
 * file is one: it is a *rule about a list*, and this project's tests have no DOM
 * to run a hook in — so a rule left inside a hook is a rule nothing can stand
 * on. `useAgentTarget` calls it and does nothing else with either source.
 *
 * The two sources, and neither of them is the session list the picker reads:
 *
 *  - **The store**, which is where a rename typed in the rail lands and where
 *    the auto-titler writes what an agent has called itself. It is React state
 *    in this window and never reaches the main process, so `session:list` could
 *    not carry it even in principle. A title that is still the folder's own name
 *    is the *absence* of a name and is skipped — {@link nameOf} says the same
 *    thing about the list's own title, and leaving the folder in here would
 *    override the far better title the main process may have derived.
 *  - **The copilot**, whose name is the one session name in this app that is not
 *    a session property at all: it lives in its instruction file.
 *
 * ## The copilot is named by its session, not by its folder
 *
 * This matched on the copilot's working directory for a day, and a folder does
 * not name one session — it names everything anybody starts in it. Asad,
 * 2026-08-21, having started a session of his own in that folder and renamed it
 * in the rail:
 *
 *   > *"Why all of them calls commander now? I mean, why do we have two
 *   > commander sessions and none of this is calling template? **This Mac
 *   > session, the one I just called.** See, this is also a problem."*
 *
 * There were not two copilots. There was one, plus his own session wearing its
 * name — and because the folder match ran *after* the loop above, it overwrote
 * the name he had typed with a name he had not. So the copilot's row is keyed on
 * its id, and it is applied after the loop rather than inside it because the
 * copilot's session need not be in the store this window is holding.
 *
 * A null id is a real answer — no copilot channels in this build, the copilot is
 * not running, the read failed — and the honest response to it is to name
 * nothing specially, rather than to guess which row is the copilot.
 */
export function namesFrom(
  stored: readonly { id: string; cwd: string; title: string }[],
  copilot: { sessionId: string | null; name: string },
): NameSource {
  const map = new Map<string, string>()
  for (const session of stored) {
    if (session.title && session.title !== folderName(session.cwd)) map.set(session.id, session.title)
  }
  if (copilot.sessionId !== null && copilot.sessionId !== '' && copilot.name !== '') {
    map.set(copilot.sessionId, copilot.name)
  }
  return map
}

/**
 * The name somebody gave it, or `folder · Session 2` when nobody has.
 *
 * One function because the two lists have to number the same way. A remote
 * session that read `Session 4` while the rail beside it read `Session 2` would
 * be the picker disagreeing with the app about which session it means, which is
 * the failure this labelling scheme exists to avoid in the first place.
 *
 * ## A named session is called by its name and by nothing else
 *
 * Asad, naming the copilot and then opening this picker: *"it should call
 * commander also because I name it as commander, but it is showing copilot."*
 * It was showing `copilot · Commander` — the name was there, second, behind the
 * folder the copilot happens to live in, and `copilot` is the word he had just
 * replaced. A name is the one fact on the row he chose himself, so it is the
 * whole row.
 *
 * The folder stays for every session that has no name, because then there is
 * nothing else to tell two rows apart. The name displaces the number for the
 * same reason it displaces the folder: the number exists to tell two sessions
 * in one folder apart, and a name already does.
 */
function labelFor(cwd: string, index: number, name: string): string {
  if (name) return name
  const folder = cwd ? folderName(cwd) : ''
  return folder ? `${folder} · Session ${index}` : `Session ${index}`
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
      serverId: '',
      shellId: '',
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
        serverId: '',
        shellId: '',
      })
    }
  }
  return out
}

/**
 * One shell this window has open on a server, as this picker needs to see it.
 *
 * Four of its fields come straight off `machines/servers/server-sessions.ts`'s
 * `ServerSession`; `ended` is its `status` reduced to the one transition this
 * list cares about, and `shellId` is the handle the window learns *afterwards*
 * and keeps beside that list. It is declared here rather than imported so this
 * module stays reachable from a test with no window around it — the same reason
 * {@link AgentSession} mirrors `SessionMeta` instead of importing it.
 */
export interface AgentServerShell {
  /** The tab id: what the rail, the strip and this picker all choose by. */
  tabId: string
  serverId: string
  /** What that server is called here. */
  serverName: string
  /** `servers:shell:write`'s handle, or empty while the shell is opening. */
  shellId: string
  /** The folder it was opened in, or empty for wherever the sign-in lands. */
  startIn: string
  /** The far end has gone: somebody typed `exit`, or the link dropped. */
  ended: boolean
}

/**
 * The shells this window has open on servers, as rows.
 *
 * Numbered per folder **per server**, which is the rule the machines branch
 * above states and for the same reason: a shell on Office PC that read
 * `Session 3` because two are open on this Mac would be a number matching
 * nothing on either screen. A shell opened with no folder — wherever the
 * account's sign-in lands, which is what SSH gives you and what this app did for
 * the whole life of the feature — is numbered in its own group and reads
 * `Office PC · Session 1`, which is exactly what the rail calls it.
 *
 * `named` is passed and contributes nothing today, and that is deliberate rather
 * than an oversight: nothing in this app renames a shell on a server, so the map
 * — which is built from this window's session store — holds no entry for one.
 * Forking a second labelling rule to say so would be the drift the one
 * {@link labelFor} exists to prevent.
 */
function sessionsOnServers(
  shells: readonly AgentServerShell[],
  named: NameSource,
): AgentSession[] {
  const counts = new Map<string, number>()
  const out: AgentSession[] = []
  for (const shell of shells) {
    if (shell.tabId === '' || shell.serverId === '' || shell.serverName === '') continue
    const key = `${shell.serverId}\u0000${shell.startIn}`
    const index = (counts.get(key) ?? 0) + 1
    counts.set(key, index)
    const name = nameOf(shell.tabId, shell.startIn, '', named)
    out.push({
      id: shell.tabId,
      cwd: shell.startIn,
      name,
      label: `${shell.serverName} · ${labelFor(shell.startIn, index, name)}`,
      // Nothing on this side classifies what is running in a shell on a server:
      // it is a login shell until somebody types something into it, and this
      // window never sees what. An empty string is that, rather than a guess
      // that would print the wrong agent's name beside the row.
      provider: '',
      ended: shell.ended,
      machineId: '',
      machineName: shell.serverName,
      serverId: shell.serverId,
      shellId: shell.shellId,
    })
  }
  return out
}

/**
 * The same rows, with no two of them reading the same words.
 *
 * A label is what somebody picks a session by, so two rows wearing one label is
 * a dropdown that cannot be used for its only purpose. Asad, 2026-08-21, with
 * two rows both reading `Commander`: *"Why all of them calls commander now? I
 * mean, why do we have two commander sessions and none of this is calling
 * template?"* — the naming defect that caused that pair is fixed in
 * {@link namesFrom}, and this is the guard that keeps the *shape* of it from
 * coming back through any other route: two sessions a person has typed the same
 * name into, an agent that titled itself the same as its neighbour.
 *
 * The qualifier is the label the row would have had with no name at all, which
 * is the one thing that is already unique — folder and position, or the server's
 * name and position. Only a colliding row wears it, so the ordinary list is
 * untouched, and a row is never re-qualified twice: running this over a list it
 * has already fixed finds no collisions and changes nothing.
 */
function distinctLabels(rows: readonly AgentSession[]): AgentSession[] {
  const seen = new Map<string, number>()
  for (const row of rows) seen.set(row.label, (seen.get(row.label) ?? 0) + 1)
  const counts = new Map<string, number>()
  return rows.map((row) => {
    if ((seen.get(row.label) ?? 0) < 2) return row
    // The same per-group counter the unnamed rows are numbered with, recomputed
    // here because a row that carries a name never asked for its number and does
    // not carry it. The group is the machine or server it is on plus its folder,
    // which is what makes the answer match the number the rail would show.
    const key = `${row.machineId}\u0000${row.serverId}\u0000${row.cwd}`
    const index = (counts.get(key) ?? 0) + 1
    counts.set(key, index)
    const where = row.machineName === '' ? '' : `${row.machineName} · `
    return { ...row, label: `${row.label} — ${where}${labelFor(row.cwd, index, '')}` }
  })
}

/**
 * Turn the bridge's answer into a labelled list.
 *
 * The numbering is per project and follows list order, which is creation order
 * — the same rule the sidebar uses, so the two agree about which session is
 * "Session 2". A session with no folder is numbered in its own group rather
 * than being thrown in with the first project's, because it belongs to none.
 *
 * This machine's sessions come first, then the ones on paired machines, then the
 * shells open on servers — grouped by the computer they run on. Same order as
 * the machine picker beside it, where "this machine" is always the first row and
 * the servers are last, and the useful order besides.
 *
 * `shells` is a parameter rather than a third channel on the bridge because
 * there is nothing to ask: a shell on a server exists because this window is
 * holding a connection to it, so this window's own list is the only list there
 * is. See {@link AgentServerShell}.
 */
export function readSessions(
  value: unknown,
  named: NameSource = NO_NAMES,
  shells: readonly AgentServerShell[] = [],
): AgentSession[] {
  const servers = sessionsOnServers(shells, named)
  // A bare array is this machine's sessions and nothing else. See the note on
  // `AgentSessionBridge.listSessions`: that is a real answer, not an old one.
  if (Array.isArray(value)) return distinctLabels([...sessionsHere(value, named), ...servers])
  if (typeof value !== 'object' || value === null) return distinctLabels(servers)
  const envelope = value as Record<string, unknown>
  return distinctLabels([
    ...sessionsHere(envelope.here, named),
    ...sessionsElsewhere(envelope.elsewhere, named),
    ...servers,
  ])
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
 *
 * There is a fourth again, and it is a *moment* rather than a state: a shell on
 * a server whose handle has not come back yet. That row is real — it is in the
 * rail, and this window opened it — but `servers:shell:write` has nothing to
 * take, so it is refused for the second or two it takes the server to answer,
 * with its own sentence in {@link whyDisabled}.
 */
export function resolveTarget(
  chosenId: string,
  sessions: readonly AgentSession[],
): AgentSession | null {
  if (!chosenId) return null
  const found = sessions.find((session) => session.id === chosenId)
  if (!found || found.ended) return null
  if (found.serverId !== '' && found.shellId === '') return null
  return found
}

/**
 * What actually goes down the pty, or empty when there is nothing to send.
 *
 * Two callers with two meanings, and the difference is one character. The
 * browser's popups send **context** — an element, a recorded flow, a
 * screenshot's description — into a session for somebody to read and edit before
 * they press Return themselves; a `\r` there would fire off a half-written
 * prompt. The copilot's rail panel is a **chat box**, and a message that lands
 * on the agent's command line without being sent is a box that silently did
 * nothing.
 *
 * `\r` rather than `\n` for the reason `agent-controls.ts` gives at length: it
 * is what the CLI's key parser reads as return.
 *
 * Pure and exported so both of those are pinned. There is no DOM in this
 * project's tests, so the hook that calls this cannot be driven, and "the chat
 * box does not submit" is exactly the shape of defect that passes a typecheck
 * and every existing test.
 */
export function sendPayload(text: string, submit: boolean): string {
  const typed = text.trim()
  if (typed === '') return ''
  return submit ? `${typed}\r` : typed
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
  // The one refusal on this list that clears itself: the server is opening the
  // shell and has not answered with its handle. Saying so beats a button that
  // works a second later with no explanation of why it did not before.
  if (found.serverId !== '' && found.shellId === '') {
    return `That terminal on ${found.machineName} is still opening.`
  }
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

/* ------------------------------------------------------------- sending -- */

/** What one write to a session came back with. A sentence only when it failed. */
export type SendOutcome = { ok: true } | { ok: false; message: string }

/**
 * Put one line into a session **and submit it**.
 *
 * ## Why this is two writes and not a string with a `\r` on the end
 *
 * Because the CLI on the other end classifies each stdin chunk before it looks
 * at the keys in it, and a chunk of 64 bytes or more is *pasted text*, where a
 * carriage return is a newline rather than submit. `chat/attach/mentions.ts`
 * measured that and owns the sequence; this calls its {@link terminalWrites} so
 * there is one description of the trap and not two.
 *
 * Every line this picker composes carries a screenshot path and a size, so every
 * one of them is well over that limit. A single write is therefore not "usually
 * fine" here — it is a send button that never submits anything, which is exactly
 * what Asad filmed: the composed line sitting unsent in the target session's
 * prompt while the transcript above it still ended at *"Hi"*.
 *
 * ## Why the gap is real time
 *
 * The chunk is the unit being classified, so anything producing one `write` — a
 * longer string, `\r\n`, the two concatenated — is one chunk and is read as a
 * paste. The Return only arrives *as a key* when it is alone in its own read,
 * which means a gap on the clock. `wait` is a parameter so a test can supply a
 * fake one rather than sleeping.
 *
 * ## What it answers when the second write is the one that fails
 *
 * The second write's refusal, which means a caller can be told "it did not
 * arrive" about a line that is now sitting typed and unsent in somebody's
 * prompt. That is the honest report of what happened and it is the rarer half of
 * a case that needs a session to exit inside fifty milliseconds; claiming
 * success because the *characters* landed is how the defect this function exists
 * for was invisible for a day.
 */
export async function submitLine(
  line: string,
  write: (data: string) => Promise<SendOutcome>,
  wait: (ms: number) => Promise<void> = (ms) =>
    new Promise((done) => {
      setTimeout(done, ms)
    }),
): Promise<SendOutcome> {
  const [typed, submit] = terminalWrites(line)
  const first = await write(typed)
  if (!first.ok) return first
  await wait(SUBMIT_GAP_MS)
  return write(submit)
}
