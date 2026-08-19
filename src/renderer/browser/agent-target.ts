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
 * ## Sessions on another machine: listed, named, and not typed into
 *
 * This list used to be `session:list` and nothing else, which is this machine's
 * ptys and only this machine's ptys — `src/main/index.ts:2293`, answered from
 * `ptys.list()`. That was invisible right up until the browser learned to open
 * another machine's `localhost` (`BrowserWorkspace.openThere`, the 2026-08-18
 * change): he would be looking at a page served by his PC, inspect an element on
 * it, open this picker, and find nothing but the sessions on the Mac in front of
 * him. The session he actually wanted was in the rail two inches away, on the
 * machine the page came from, and the picker did not mention that it had left it
 * out. **A screen that quietly shows a subset is the failure mode this project
 * keeps finding**, so the rows are here now.
 *
 * They are here, and they are refused, and the refusal is a fact about the wire
 * rather than a decision taken here:
 *
 *  - The only verb on the remote protocol that puts characters into a session is
 *    `input`, and `src/main/remote/server.ts:2867-2878` will not act on it
 *    unless this desktop is **attached** to that session. The comment there says
 *    why in four words — *"Attachment is the authorisation"* — and it is load
 *    bearing: without it any device that had ever seen or guessed an id would
 *    have a keyboard on somebody's agent.
 *  - Attaching in order to send is not free, and the cost lands on a terminal he
 *    is reading. There is one connection per machine and `connection.handles` is
 *    keyed by session id, so a second attach for a session a pane already holds
 *    makes the host drop the pane's handle and replay the whole scrollback
 *    (`server.ts:1749-1753` and `:1785-1791`). The pane writes every byte it is
 *    given straight into xterm without looking at the `replay` flag
 *    (`src/renderer/machines/RemoteTerminal.tsx:123`), so he would watch his own
 *    scrollback print itself a second time — and when that pane closed, its
 *    detach (`RemoteTerminal.tsx:147`) would take the browser's target away with
 *    it. One handle, two owners, and no way for either to know about the other.
 *
 * The obvious way around that was tried on paper and rejected: **list only the
 * remote sessions this window is already attached to.** Those sends do land, and
 * the preload is a choke point every attach passes through, so it is buildable.
 * It was dropped because the resulting list is not a rule anybody could state —
 * a PC running four agents would show the one that happens to have a pane open,
 * and the other three would be missing for a reason that is invisible from the
 * dropdown. Replacing "this machine only", which is a sentence, with "whichever
 * of them you opened here", which is an accident, is not an improvement; it is
 * the same omission with a worse boundary.
 *
 * So every session on every connected machine is listed, carrying that machine's
 * name, and choosing one turns Send off with a sentence saying where it is. That
 * is the shape `machines-bridge.ts` already settled on for a machine whose ports
 * cannot be reached — *"Machines that cannot be reached are kept, carrying their
 * sentence"* — and the argument is the same: the most useful thing this dropdown
 * can say about a computer he is looking at is that it is there.
 *
 * **What closes it.** A verb that authorises typing without subscribing to
 * output, or an `attach` that does not displace a handle this connection already
 * holds — either one in `src/main/remote/protocol.ts` and `server.ts`, with the
 * guest half in `machines/guest.ts`. When that exists, {@link resolveTarget}
 * stops refusing these rows and the send routes on `machineId` through the
 * preload's `writeToMachineSession`, which has been on the bridge since the
 * remote pane needed it. Nothing else here has to change.
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
   * The paired machine it runs on, or empty for this one.
   *
   * Empty is not a missing value and never should be read as one: it is the
   * answer for every session on this computer, which is every session that can
   * be sent to today. `resolveTarget` refuses anything else — see the header for
   * the wire's reason and for what would let it stop.
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
function readSession(value: unknown): { id: string; cwd: string; provider: string; ended: boolean } | null {
  if (typeof value !== 'object' || value === null) return null
  const record = value as Record<string, unknown>
  if (typeof record.id !== 'string' || record.id === '') return null
  return {
    id: record.id,
    cwd: typeof record.cwd === 'string' ? record.cwd : '',
    provider: typeof record.provider === 'string' ? record.provider : '',
    // `exitCode` is null while the process lives and a number once it has gone.
    ended: typeof record.exitCode === 'number',
  }
}

/**
 * `folder · Session 2`, or `Session 2` for a session that has no folder.
 *
 * One function because the two lists have to number the same way. A remote
 * session that read `Session 4` while the rail beside it read `Session 2` would
 * be the picker disagreeing with the app about which session it means, which is
 * the failure this labelling scheme exists to avoid in the first place.
 */
function labelFor(cwd: string, index: number): string {
  const folder = cwd ? folderName(cwd) : ''
  return folder ? `${folder} · Session ${index}` : `Session ${index}`
}

/** This machine's sessions, in the order the main process listed them. */
function sessionsHere(value: unknown): AgentSession[] {
  if (!Array.isArray(value)) return []
  const counts = new Map<string, number>()
  const out: AgentSession[] = []
  for (const entry of value) {
    const session = readSession(entry)
    if (!session) continue
    const index = (counts.get(session.cwd) ?? 0) + 1
    counts.set(session.cwd, index)
    out.push({ ...session, label: labelFor(session.cwd, index), machineId: '', machineName: '' })
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
function sessionsElsewhere(value: unknown): AgentSession[] {
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
      out.push({
        id: session.id,
        cwd: session.cwd,
        label: `${machineName} · ${labelFor(session.cwd, index)}`,
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
export function readSessions(value: unknown): AgentSession[] {
  // A bare array is this machine's sessions and nothing else. See the note on
  // `AgentSessionBridge.listSessions`: that is a real answer, not an old one.
  if (Array.isArray(value)) return sessionsHere(value)
  if (typeof value !== 'object' || value === null) return []
  const envelope = value as Record<string, unknown>
  return [...sessionsHere(envelope.here), ...sessionsElsewhere(envelope.elsewhere)]
}

/**
 * The session a send would actually reach, given what is chosen.
 *
 * Null in four cases, and they are all the same answer to the user: nothing
 * chosen, a choice that is no longer in the list, a choice whose process has
 * exited, and a choice on another machine. The third is the case he named —
 * *"if that session dies, I need to select again another session"* — and it is
 * the reason this is a function over the live list rather than a stored object.
 *
 * The fourth is the newest and the one to be careful with. It is not a rule
 * about what he is allowed to do; it is this file refusing to pretend a send
 * happened. `input` on the remote wire is fire-and-forget from here — the far
 * machine's refusal comes back as an `error` frame that no popup is listening
 * for — so a target that cannot be typed into would report `Sent` and drop the
 * line on the floor. The header has the mechanism and what would remove this
 * branch.
 */
export function resolveTarget(
  chosenId: string,
  sessions: readonly AgentSession[],
): AgentSession | null {
  if (!chosenId) return null
  const found = sessions.find((session) => session.id === chosenId)
  if (!found || found.ended) return null
  if (found.machineId !== '') return null
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
  if (!chosenId) {
    // Everything in the list is somewhere else. He is almost certainly looking
    // at that machine's page — that is how this list came to be all remote — so
    // the sentence has to say why the rows below it will not do, before he
    // picks one and finds out.
    if (sessions.every((session) => session.machineId !== '')) {
      return (
        'Every session listed is on another machine. This browser sends only to sessions on ' +
        'this one — start a session here, then choose it.'
      )
    }
    return 'Choose a session first — this will not guess one for you.'
  }
  const found = sessions.find((session) => session.id === chosenId)
  if (!found) return 'That session is gone. Choose another one.'
  // Before the machine branch, because a session that has exited is finished
  // wherever it was running, and "open it and type into it there" would be
  // advice about a process that is not there any more.
  if (found.ended) return `${found.label} has exited. Choose another one.`
  if (found.machineId !== '') {
    // Kept to two clauses on purpose. This paragraph is `flex-basis: 100%`
    // inside a 26rem popup, so a sentence that reads well in this file becomes
    // five lines under the field; the long form of the argument belongs in the
    // header, not on his screen.
    return (
      `${found.label} is on ${found.machineName}. This browser sends only to sessions on this ` +
      'machine — open that one from the sidebar and type into it there.'
    )
  }
  return ''
}
