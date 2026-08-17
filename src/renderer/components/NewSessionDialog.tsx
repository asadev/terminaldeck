import {
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type FormEvent,
  type KeyboardEvent,
} from 'react'
import type { ProviderId } from '@shared/types'
import { formatChord } from '../keymap'
import {
  DEFAULT_COLS,
  DEFAULT_ROWS,
  parseStartMemory,
  rememberStart,
  resolveStart,
  START_MEMORY_KEY,
  type SpawnRequest,
  type StartMemory,
  type StartProvider,
} from '../session-start'
import { folderName, shortSessionId } from '../session-title'
import { Modal } from './Modal'
import { normalizePreferences } from '../preferences'
import { useOptionalStore } from '../state/store'
import { relativeTime } from './relative-time'
import {
  isolationNotice,
  parseProfile,
  parseSnapshot,
  profileBadges,
  profileBridge,
  profileLoginLabel,
  type ProfileView,
  type SnapshotView,
} from './ProfilePicker'
import { buildProviderRows, PROVIDER_OPTIONS, resumeAvailability, type ProviderRow } from './ProviderPicker'
// Relative, not '@shared/…', for the reason `ProviderPicker.tsx` gives: vitest
// runs without the electron-vite alias, so a *value* import through it resolves
// in the app and throws in a test.
import {
  EMPTY_DRAFT,
  isCustomProviderId,
  parseCustomAgents,
  type CustomAgent,
  type CustomAgentDraft,
  type CustomAgentProblems,
} from '../../shared/custom-agents'
import type { CustomProviderId } from '@shared/types'
import { AddAgentForm } from './AddAgentForm'
import './NewSessionDialog.css'

/**
 * Everything a session needs decided before it starts.
 *
 * Until this dialog existed, clicking a project spawned a process immediately:
 * a guessed provider, whatever login happened to be default, always a fresh
 * conversation, and no way to say what the session was for. Each of those is
 * cheap to get right up front and expensive to discover afterwards — the wrong
 * login has already committed something, the fresh session has already lost the
 * thread you meant to continue.
 *
 * ## The dialog shows what will happen, not what was clicked
 *
 * Nothing here holds a "current provider" of its own. The controls hold the
 * user's *overrides* — usually nothing at all — and what is rendered as
 * selected comes back out of `resolveStart`. So the radio that looks chosen is
 * the one that will actually be spawned, including when it is chosen by a
 * remembered default or by a fallback the user never saw. Two sources of truth
 * for "which agent is selected" is precisely how a dialog ends up lying.
 *
 * ## What is reused
 *
 * The provider catalogue and its PATH detection stay in `ProviderPicker`; the
 * profile list, its parsing and the rule about which agents can be isolated
 * stay in `ProfilePicker`; the precedence rules stay in `session-start`. This
 * file is layout and one `localStorage` round-trip.
 */

/* --------------------------------------------------------------- storage -- */

/**
 * `localStorage`, when this window has one.
 *
 * Reading the property can itself throw when storage is disabled by policy, so
 * the guard is a try/catch rather than a typeof test alone.
 */
function memoryStore(): Storage | null {
  try {
    return typeof localStorage === 'undefined' ? null : localStorage
  } catch {
    return null
  }
}

/* ---------------------------------------------------------------- bridge -- */

/**
 * The slice of the preload bridge this dialog reads.
 *
 * Guarded the way `ProfilePicker` and `CloseSessionConfirm` guard theirs, and
 * for a sharper reason here: these calls live in an effect. A renderer whose
 * preload failed to load has no `window.deck` at all, so reaching straight
 * through it throws synchronously *during* the effect — React unmounts the
 * tree, and the dialog that would have explained the problem is the thing that
 * vanishes. Each call is also checked individually, because a partially wired
 * bridge is what every one of these methods looked like before it was written.
 */
interface StartBridge {
  listProjects(): Promise<unknown>
  detectProviders(): Promise<unknown>
  /**
   * The agents this machine added, beyond the ones the build ships.
   *
   * Three methods rather than a saved list, and `addAgent` is the only one that
   * creates anything: it is the only path that resolves the command on the login
   * PATH before writing, which is the rule that keeps a row out of this dialog
   * unless it can actually start. `main/custom-agents.ts` holds it.
   */
  listAgents(): Promise<unknown>
  addAgent(draft: unknown): Promise<unknown>
  removeAgent(id: string): Promise<unknown>
  getPreferences(): Promise<unknown>
  pickProjectFolder(): Promise<string | null>
  /** Forget a folder. Nothing on disk is touched — see the Remove button. */
  removeProject(path: string): Promise<void>
  /**
   * Every transcript Claude Code has written for a folder, newest first.
   *
   * `insights:list` in the main process, which is `listTranscripts` over every
   * store the folder can have written to. It is the only enumeration of past
   * conversations this app can honestly make, and it is what the Conversation
   * section names — see {@link parseConversations}.
   */
  listSessionInsights(cwd: string): Promise<unknown>
  /** Read-only sign-in status for one login, cached 30s in the main process. */
  profileSignIn(id: string, options?: { provider?: ProviderId }): Promise<unknown>
  setDefaultProfile(id: string | null): Promise<unknown>
}

function startBridge(): Partial<StartBridge> | null {
  return (globalThis as { deck?: Partial<StartBridge> }).deck ?? null
}

/** Last choice per project, or nothing at all if the blob is unusable. */
export function readStartMemory(
  known: readonly ProviderId[],
  storage: Storage | null = memoryStore(),
): StartMemory {
  if (!storage) return {}
  try {
    return parseStartMemory(storage.getItem(START_MEMORY_KEY), known)
  } catch {
    return {}
  }
}

export function writeStartMemory(
  memory: StartMemory,
  storage: Storage | null = memoryStore(),
): void {
  if (!storage) return
  try {
    storage.setItem(START_MEMORY_KEY, JSON.stringify(memory))
  } catch {
    // Quota, or a store disabled after the read succeeded. Forgetting the last
    // choice is a small loss; refusing to start the session over it is not.
  }
}

/* ----------------------------------------------------------- added agents -- */

/**
 * What `addAgent` answered, narrowed to something the form can draw.
 *
 * Exported and total, because every branch of it is a real state and three of
 * them are silent failures if they are not handled:
 *
 *  - a refusal with per-field problems, which is the ordinary one;
 *  - a refusal with nothing in it, from a build that answered a shape this one
 *    does not know — still a refusal, and the button must not sit there looking
 *    broken while the form says nothing;
 *  - a success whose `agent.id` is not a custom id, which is not a success this
 *    dialog can act on: it would select a provider that is not in the list.
 */
export type AddAgentOutcomeView =
  | { ok: true; id: CustomProviderId }
  | { ok: false; problems: CustomAgentProblems }

const REFUSED: CustomAgentProblems = {
  command: 'That agent could not be added. Check the command and try again.',
}

export function parseAddOutcome(value: unknown): AddAgentOutcomeView {
  if (typeof value !== 'object' || value === null) return { ok: false, problems: REFUSED }
  const answer = value as { ok?: unknown; agent?: unknown; problems?: unknown }

  if (answer.ok !== true) {
    const said = answer.problems
    if (typeof said !== 'object' || said === null) return { ok: false, problems: REFUSED }
    // Only the keys the form has a field for. A problem under a name it cannot
    // draw would be a refusal with nothing on screen.
    const problems: CustomAgentProblems = {}
    for (const field of ['label', 'description', 'command', 'args', 'resumeArgs'] as const) {
      const text = (said as Record<string, unknown>)[field]
      if (typeof text === 'string' && text !== '') problems[field] = text
    }
    return { ok: false, problems: Object.keys(problems).length > 0 ? problems : REFUSED }
  }

  const id = (answer.agent as { id?: unknown } | undefined)?.id
  if (!isCustomProviderId(id)) return { ok: false, problems: REFUSED }
  return { ok: true, id }
}

/* --------------------------------------------------------------- projects -- */

export interface RecentProject {
  path: string
  name: string
  lastOpenedAt: number
}

/**
 * Narrow the project list off the bridge.
 *
 * Sorted here rather than trusted: the main store sorts on its way out, but a
 * folder the user has just browsed to is appended locally and has to land in
 * the right place without a round-trip.
 */
export function parseRecentProjects(raw: unknown): RecentProject[] {
  if (!Array.isArray(raw)) return []

  const seen = new Set<string>()
  const projects: RecentProject[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const { path, lastOpenedAt } = entry as { path?: unknown; lastOpenedAt?: unknown }
    if (typeof path !== 'string' || path === '' || seen.has(path)) continue
    seen.add(path)
    projects.push({
      path,
      name: folderName(path),
      lastOpenedAt: typeof lastOpenedAt === 'number' ? lastOpenedAt : 0,
    })
  }
  return projects.sort((a, b) => b.lastOpenedAt - a.lastOpenedAt)
}

/** Put a browsed folder at the top of the list without waiting for a reload. */
export function withProject(projects: readonly RecentProject[], path: string): RecentProject[] {
  const rest = projects.filter((project) => project.path !== path)
  return [{ path, name: folderName(path), lastOpenedAt: Date.now() }, ...rest]
}

/* ---------------------------------------------------------- conversations -- */

/**
 * One past conversation in the folder, as far as this app can honestly see it.
 *
 * ## What the recording asked for, and what is actually available
 *
 * > *"which conversation will it bring? …it should actually give the choice of
 * > which session, maybe with session IDs or the name or maybe a little bit
 * > context with the summary"*
 *
 * The **choice** cannot be built today and pretending otherwise would be the
 * worst outcome of the two. `CreateSessionInput` carries `resume?: boolean` and
 * nothing else, and the flag it turns into is `--continue` (or `codex resume
 * --last`) — a flag that means *the newest one*, with no id to hand it. Wiring
 * `claude --resume <id>` through means a field on `CreateSessionInput`, a branch
 * in `host-core.ts`'s `startSession` and a second argument list in
 * `providers.ts`. A picker that offered nine conversations and silently opened
 * the newest one every time is exactly the kind of lie this app has twice
 * refused to ship.
 *
 * The **identity** is available and is most of the answer: `insights:list`
 * enumerates the transcripts, so the dialog can say which conversation the
 * resume will land on rather than leaving somebody to find out afterwards.
 *
 * A zero-byte file is not a conversation. The CLI opens a transcript before it
 * has a turn to put in it, and `--continue` aimed at an empty one does not open
 * an empty session — it errors and the tab dies. `newestConversation` in
 * `main/transcript.ts` skips them for that reason, and skipping them here too
 * is what makes this section agree with what will actually happen.
 */
export interface Conversation {
  sessionId: string
  modifiedAt: number
  bytes: number
}

export function parseConversations(raw: unknown): Conversation[] {
  if (!Array.isArray(raw)) return []

  const conversations: Conversation[] = []
  for (const entry of raw) {
    if (typeof entry !== 'object' || entry === null) continue
    const { sessionId, modifiedAt, bytes } = entry as {
      sessionId?: unknown
      modifiedAt?: unknown
      bytes?: unknown
    }
    if (typeof sessionId !== 'string' || sessionId === '') continue
    if (typeof bytes !== 'number' || bytes <= 0) continue
    conversations.push({
      sessionId,
      modifiedAt: typeof modifiedAt === 'number' ? modifiedAt : 0,
      bytes,
    })
  }
  // Sorted here rather than trusted: the main process concatenates two stores
  // and re-sorts, but a build that stops doing so must not silently rename the
  // conversation this dialog says will be continued.
  return conversations.sort((a, b) => b.modifiedAt - a.modifiedAt)
}

/**
 * Enough of a session id to tell two apart, and short enough to sit on a row.
 *
 * Declared in `session-title.ts` and re-exported here, where this dialog's
 * callers import it from. It moved when the sidebar needed the same eight
 * characters as its last resort for two rows carrying one name — the same
 * operation on the same shape of id, and two copies of it would be two places
 * to change when a session id stops being a UUID.
 */
export { shortSessionId }

/** What the Continue row says about the conversation it will land on. */
export function conversationLine(
  conversations: readonly Conversation[],
  now: number,
): string | null {
  const newest = conversations[0]
  if (!newest) return null
  const when = relativeTime(newest.modifiedAt, now)
  return when === '' ? shortSessionId(newest.sessionId) : `${when} · ${shortSessionId(newest.sessionId)}`
}

/**
 * The one line that explains why there is no picker, and only when there is
 * something to explain.
 *
 * Silent for a folder with one conversation in it: a sentence about the others
 * when there are no others is the kind of clause that turns a five-row panel
 * into a wall of text.
 */
export function olderConversationsLine(conversations: readonly Conversation[]): string | null {
  const older = conversations.length - 1
  if (older < 1) return null
  const plural = older === 1 ? 'conversation' : 'conversations'
  return `${older} older ${plural} here. Resume always takes the newest.`
}

/* ------------------------------------------------------------ the account -- */

/**
 * What the main process knows about a login, narrowed off the bridge.
 *
 * `profiles:signin` reads it — it runs the agent's own `auth status` command and
 * caches the answer for 30 seconds. `unknown` is a real state and is never
 * folded into `signed-out`: the two send a person to different places, which is
 * the argument `main/profiles-signin.ts` makes at length.
 */
export interface SignInView {
  state: 'signed-in' | 'signed-out' | 'unknown' | 'unsupported'
  /** The address the CLI named. Null when it named none — Codex never does. */
  account: string | null
  plan: string | null
}

export function parseSignIn(raw: unknown): SignInView | null {
  if (typeof raw !== 'object' || raw === null) return null
  const { state, account, plan } = raw as { state?: unknown; account?: unknown; plan?: unknown }
  if (
    state !== 'signed-in' &&
    state !== 'signed-out' &&
    state !== 'unknown' &&
    state !== 'unsupported'
  ) {
    return null
  }
  return {
    state,
    account: typeof account === 'string' && account !== '' ? account : null,
    plan: typeof plan === 'string' && plan !== '' ? plan : null,
  }
}

/**
 * The line under "Login", which is an address rather than a sentence.
 *
 * > *"Login default, instead of just saying default because nobody now knows
 * > which one is default. So there should be a default and then next to it we
 * > can have an email so we know which one is default currently"*
 *
 * The row used to read "Which Claude login this session should run as." — a
 * sentence restating the word above it, printed where the answer belongs. The
 * pop-up button beside it said `Default`, which is the *name of the profile*
 * and tells you nothing about whose account it is.
 *
 * Every branch here is something the CLI said. Nothing is inferred: an agent
 * that reports no address (Codex prints none, by design — reading its
 * credential file to decorate a row is a trade this app does not make) gets its
 * plan instead, and a login the probe could not read says so rather than
 * guessing "signed in".
 */
export function loginLine(report: SignInView | null): string | null {
  if (report === null) return null
  switch (report.state) {
    case 'signed-in':
      if (report.account) return report.plan ? `${report.account} · ${report.plan}` : report.account
      return report.plan ?? 'Signed in'
    case 'signed-out':
      return 'Not signed in'
    case 'unknown':
      return 'Sign-in state unknown'
    // The Login row is already disabled with `isolationNotice` explaining why,
    // and a second sentence saying the same thing is one line too many.
    case 'unsupported':
      return null
  }
}

/**
 * The line under "Login", given what the pop-up beside it now says.
 *
 * `loginLine` was written when the pop-up said `Default`: the address had
 * nowhere else to be, so it went here. The pop-up names the account now, and
 * printing the same twenty-three characters twice, four centimetres apart, is
 * the duplication this panel spent a pass removing everywhere else.
 *
 * So when the pop-up is already showing the address, the line says the part the
 * pop-up has no room for — that the login is live, and on which plan. Every
 * other case keeps the whole line, and they are not edge cases: an agent that
 * names no address (Codex), a login that could not be read, an empty list where
 * the pop-up falls back to "the agent's own login". The address is on screen in
 * exactly one place in all of them.
 */
export function loginHint(report: SignInView | null, optionLabel: string | null): string | null {
  const line = loginLine(report)
  if (line === null) return null
  const shown = report?.state === 'signed-in' && report.account !== null && optionLabel === report.account
  if (!shown) return line
  return report?.plan ? `Signed in · ${report.plan}` : 'Signed in'
}

/**
 * One line of the Login pop-up, and which row is allowed to wear an address.
 *
 * `profileLoginLabel` decides what a login is *called*; this decides who has
 * been asked. Exactly one probe is in flight at a time in this dialog — the
 * effect below runs `profiles:signin` for the login the resolver settled on,
 * because that is the one the row above the pop-up is describing — so the
 * report belongs to that row and to no other. Handing it to every option would
 * put one account's address against three different logins.
 *
 * The alternative was to probe the whole list the way the account chip's menu
 * does when it opens. It is the wrong trade here: a spawn of each agent's CLI
 * every time this dialog opens, to learn an address for two rows nobody has
 * selected — and for Codex, whose CLI never prints one, to learn nothing at
 * all. Choosing a different login re-runs the probe for that login, so the row
 * that matters always has its address a moment later.
 */
export function loginOptionLabel(
  profile: ProfileView,
  selectedId: string | null | undefined,
  report: SignInView | null,
): string {
  const mine = profile.id === selectedId
  return profileLoginLabel(profile, mine ? (report ?? undefined) : undefined)
}

/**
 * Is this login the one a session gets when nobody chooses?
 *
 * Answered by calling `ProfilePicker`'s own badge rule rather than restating it,
 * because the rule has a case that is easy to miss and expensive to get wrong:
 * a null `defaultProfileId` does not mean "no default", it means the *system*
 * profile — the user's own install — so with nothing set the system row is
 * still the default. Two spellings of that would let this dialog offer "Make
 * default" for a login that already is one.
 */
export function isDefaultLogin(snapshot: SnapshotView, profile: ProfileView | undefined): boolean {
  if (!profile) return false
  return profileBadges(profile, snapshot, null, undefined).includes('Default')
}

/**
 * Can the Conversation section name the conversation, for this login?
 *
 * `insights:list` reads the *default* config directory (plus the per-device
 * homes a paired phone writes to). A profile is a different `CLAUDE_CONFIG_DIR`
 * and therefore a different transcript store, which nothing on the bridge can
 * enumerate — so naming "the last conversation" while a non-default login is
 * selected would name a conversation from somebody else's history.
 *
 * The answer is a fact about which store will be read, not a capability, so it
 * is silence rather than an error: the row falls back to saying that the agent
 * picks its own most recent conversation, which is true in every case.
 */
export function transcriptsAreReadable(
  profiles: readonly ProfileView[],
  profileId: string | null | undefined,
): boolean {
  if (!profileId) return true
  const profile = profiles.find((entry) => entry.id === profileId)
  // An id the list does not have is a list that has moved on under us; claiming
  // to know its store would be worse than declining to.
  return profile?.system === true
}

/* -------------------------------------------------------------- providers -- */

/**
 * Decorate detected provider rows with the one fact `session-start` needs and
 * `ProviderPicker` does not carry: whether this agent has a login the app can
 * point at a different config directory.
 *
 * `isolationNotice` is that rule, and it lives with the profiles UI. Null means
 * profiles apply; any string is the reason they do not.
 */
export function toStartProviders(rows: readonly ProviderRow[]): StartProvider[] {
  return rows.map((row) => ({
    id: row.id,
    label: row.label,
    available: row.available,
    canResume: row.canResume,
    supportsProfiles: isolationNotice(row.id) === null,
  }))
}

/** Provider ids this build knows about, for validating the stored memory. */
const KNOWN_PROVIDERS: readonly ProviderId[] = PROVIDER_OPTIONS.map((option) => option.id)

/** A snapshot with nothing in it, so the state has a stable identity to reset to. */
const EMPTY_SNAPSHOT: SnapshotView = { profiles: [], defaultProfileId: null, projectDefaults: {} }

/** How many recent projects are worth listing before it stops being a shortlist. */
const MAX_RECENT = 8

/**
 * Narrow a project list to what somebody typed.
 *
 * Against the name *and* the path, because the two answer different questions —
 * "terminaldeck" finds it by what it is called, "Projects/" finds everything
 * under one parent — and against the whole list rather than the shortlist,
 * which is the entire point. With nine folders open the ninth was unreachable
 * from this panel: the list is capped at {@link MAX_RECENT}, and the only other
 * route was Browse, which is a system dialog for a folder the app has never
 * seen.
 *
 * Case-insensitive, and no fuzzy matching: this project has a fuzzy matcher for
 * the command palette, where you are guessing at a verb. A folder is something
 * you already know the name of.
 */
export function matchProjects(
  projects: readonly RecentProject[],
  query: string,
): RecentProject[] {
  const needle = query.trim().toLowerCase()
  if (needle === '') return [...projects]
  return projects.filter(
    (project) =>
      project.name.toLowerCase().includes(needle) || project.path.toLowerCase().includes(needle),
  )
}

/**
 * What the Project section actually draws: the rows, whether a filter is worth
 * a line of the panel, and how many folders are still out of sight.
 *
 * Pulled out as a function because it is the part with decisions in it, and
 * because the effect that loads the project list does not run under
 * `react-dom/server` — a render test of the dialog sees an empty list no matter
 * what, so the only way to pin the nine-projects case is to pin it here.
 */
export function projectShortlist(
  projects: readonly RecentProject[],
  filter: string,
  max = MAX_RECENT,
): { filtering: boolean; shown: RecentProject[]; hidden: number } {
  // The field appears at the first project the cap can hide, and not before: a
  // search box over a list that is entirely on screen is a control with nothing
  // to do.
  const filtering = projects.length > max
  const matched = filtering ? matchProjects(projects, filter) : [...projects]
  return { filtering, shown: matched.slice(0, max), hidden: Math.max(0, matched.length - max) }
}

/* ------------------------------------------------------------ project row -- */

/**
 * One folder in the shortlist, and the way out of the list.
 *
 * A component of its own rather than JSX inside the map, for the reason the
 * rest of this file keeps pulling things out: the project list arrives in an
 * effect and effects do not run under `react-dom/server`, so a rendered dialog
 * has *no* project rows in it and nothing about a row can be pinned through the
 * dialog. Rendered directly, all of it can be.
 *
 * The confirm strip only appears for a folder with sessions running in it,
 * because removing a project closes them — the store kills each pty — and that
 * is a different kind of action from forgetting a row.
 */
export function ProjectRow({
  project,
  radioName,
  selected,
  liveSessions,
  confirming,
  onSelect,
  onAskRemove,
  onRemove,
  onKeep,
}: {
  project: RecentProject
  radioName: string
  selected: boolean
  liveSessions: number
  confirming: boolean
  onSelect(): void
  onAskRemove(): void
  onRemove(): void
  onKeep(): void
}) {
  return (
    <div className="ns-project-row">
      <label className="ns-project" data-selected={selected}>
        <input
          type="radio"
          name={radioName}
          value={project.path}
          checked={selected}
          onChange={onSelect}
        />
        <span className="ns-project-name">{project.name}</span>
        {/* The path is the identity — two folders can share a name. */}
        <span className="ns-project-path" title={project.path}>
          {project.path}
        </span>
      </label>

      {confirming ? (
        <span className="ns-project-confirm" role="group" aria-label={`Remove ${project.name}`}>
          <span className="ns-caveat">
            Close {liveSessions} session{liveSessions === 1 ? '' : 's'}?
          </span>
          <button type="button" className="ns-project-btn danger" onClick={onRemove}>
            Remove
          </button>
          <button type="button" className="ns-project-btn" onClick={onKeep}>
            Keep
          </button>
        </span>
      ) : (
        <button
          type="button"
          className="ns-project-btn"
          aria-label={`Remove ${project.name} from this list`}
          // Said on the control rather than as a line under the list, because
          // it is the one thing somebody hesitates over before pressing it.
          title="Remove from this list — the folder is not deleted"
          onClick={liveSessions > 0 ? onAskRemove : onRemove}
        >
          Remove
        </button>
      )}
    </div>
  )
}

/* ----------------------------------------------------------- agent choice -- */

interface AgentChoicesProps {
  rows: readonly ProviderRow[]
  /** Radio group name. Two dialogs can be mounted at once; their rows must not join. */
  radioName: string
  /** The section heading, for the group's accessible name. */
  labelledBy: string
  selected: ProviderId | null
  onSelect(id: ProviderId): void
  /** Opens the Add-an-agent form in place of this dialog's body. */
  onAdd(): void
  /** Forgets an added agent. Only ever called for a `custom:` id. */
  onRemove(id: ProviderId): void
}

/**
 * Which agent runs, as a list of rows with a plus at the end.
 *
 * A component of its own for the same reason `AccountProviderList` is one, and
 * it is mechanical rather than stylistic: the dialog around it is a `Modal`,
 * `Modal` renders through `createPortal`, and `react-dom/server` refuses a
 * portal — so the dialog itself cannot be rendered in a test and everything
 * inside it would be checked by reading the source instead of by looking. This
 * project has shipped two bugs that type-checked cleanly and were visibly wrong
 * on screen. `NewSessionDialog.agents.test.tsx` mounts this.
 */
export function AgentChoices({
  rows,
  radioName,
  labelledBy,
  selected,
  onSelect,
  onAdd,
  onRemove,
}: AgentChoicesProps) {
  return (
    <div className="ns-agents" role="radiogroup" aria-labelledby={labelledBy}>
      {rows.map((row) => (
        <label
          key={row.id}
          className="ns-agent"
          data-selected={row.id === selected}
          data-available={row.available}
        >
          <input
            type="radio"
            name={radioName}
            value={row.id}
            checked={row.id === selected}
            disabled={!row.available}
            onChange={() => onSelect(row.id)}
          />
          <span className="ns-mark" aria-hidden="true" />
          <span className="ns-agent-text">
            <span className="ns-agent-label">
              {row.label}
              {!row.available && <span className="ns-tag">Not installed</span>}
            </span>
            <span className="ns-hint">{row.reason ?? row.description}</span>
            {!row.available && row.install && <code className="ns-install">{row.install}</code>}
          </span>
          {isCustomProviderId(row.id) && (
            /*
             * Offered on an agent this machine added and on nothing else: a
             * shipped agent is part of the build, and a Remove beside it would
             * be a control that either does nothing or does something nobody
             * asked for.
             *
             * Both attributes are load-bearing. `type="button"`, because this
             * sits inside the form that starts a session and an unqualified
             * button in a form submits it — pressing Remove would have started
             * one. `preventDefault`, because a `<label>` forwards clicks to its
             * control, so removing an agent would also select the row being
             * removed on the way out.
             */
            <button
              type="button"
              className="ns-agent-remove"
              onClick={(event) => {
                event.preventDefault()
                event.stopPropagation()
                onRemove(row.id)
              }}
            >
              Remove
            </button>
          )}
        </label>
      ))}

      {/*
        The plus, at the end of the list rather than in the dialog's header — it
        belongs to the list, because it is how the list gets longer, and a
        control in the header would sit beside Project.

        Inside the `radiogroup` and deliberately so: arrowing down the agents and
        arriving at "Add an agent" is the sequence somebody who has not found
        what they want is already performing. It is a `<button>`, so it is not
        one of the options; it is the thing after them.
      */}
      <button type="button" className="ns-agent ns-agent-add" onClick={onAdd}>
        <span className="ns-add-mark" aria-hidden="true">
          +
        </span>
        <span className="ns-agent-text">
          <span className="ns-agent-label">Add an agent</span>
          <span className="ns-hint">Any other command-line agent on this machine.</span>
        </span>
      </button>
    </div>
  )
}

/* ------------------------------------------------------------- component -- */

interface Props {
  open: boolean
  /** Preselected folder — normally whichever project is in front. */
  projectPath?: string | null
  onClose(): void
  /**
   * Hand off the decided launch. The dialog does not spawn anything itself:
   * creating the session, adding the project and sending the first prompt are
   * all the workspace's job, and it is the one holding the session store.
   */
  onStart(request: SpawnRequest): void | Promise<void>
}

export function NewSessionDialog({ open, projectPath, onClose, onStart }: Props) {
  const [selectedPath, setSelectedPath] = useState<string | null>(projectPath ?? null)
  const [chosenProvider, setChosenProvider] = useState<ProviderId | null>(null)
  const [chosenProfileId, setChosenProfileId] = useState<string | null>(null)
  const [chosenResume, setChosenResume] = useState<boolean | null>(null)
  const [prompt, setPrompt] = useState('')
  const [remember, setRemember] = useState(true)
  /** What has been typed into the folder filter. Only drawn when it is needed. */
  const [filter, setFilter] = useState('')

  const [projects, setProjects] = useState<RecentProject[]>([])
  const [detected, setDetected] = useState<unknown>(null)
  const [snapshot, setSnapshot] = useState<SnapshotView>(EMPTY_SNAPSHOT)
  const [defaultProvider, setDefaultProvider] = useState<ProviderId | null>(null)
  const [defaultProfileId, setDefaultProfileId] = useState<string | null>(null)
  const [memory, setMemory] = useState<StartMemory>({})
  const [error, setError] = useState<string | null>(null)
  const [starting, setStarting] = useState(false)
  /**
   * The dialog is off-screen because a system panel is up. See `Modal`'s
   * `hidden` prop for why nothing in the page can be stacked above an NSWindow.
   */
  const [browsing, setBrowsing] = useState(false)
  /** Past conversations in the selected folder. Null until the bridge answers. */
  const [conversations, setConversations] = useState<Conversation[] | null>(null)
  /** What the agent's own `auth status` said about the selected login. */
  const [signIn, setSignIn] = useState<SignInView | null>(null)
  /** A project row waiting for its Remove to be confirmed, because it is busy. */
  const [confirmRemove, setConfirmRemove] = useState<string | null>(null)

  /**
   * The agents this machine added, and the form that adds one.
   *
   * > *"There should be a plus button to add, with the big list of type of AI
   * > agents to connect — not only Codex, not only Claude Code."*
   *
   * The gallery is the other half of that and it lives in
   * `shared/agent-catalog.ts`. This is the half that cannot be shipped in a
   * build: the agent released last week, or the wrapper script in somebody's own
   * `bin`. It is state on this dialog because this dialog is where a person
   * chooses an agent, and an Add that lived in Settings would be two screens for
   * one thought.
   */
  const [added, setAdded] = useState<readonly CustomAgent[]>([])
  /**
   * The form, in place of the whole dialog rather than inside it.
   *
   * Not a second `Modal`: `Modal` binds Escape to `window`, so a dialog opened
   * from a dialog dismisses both — the Add-account dialog was deleted over
   * exactly that, and the note at the bottom of `ProviderPicker.tsx` records it.
   * And not inline in the Agent section either, because this dialog *is* a
   * `<form>` and a form inside a form is markup the browser silently discards.
   */
  const [addingAgent, setAddingAgent] = useState(false)
  const [agentDraft, setAgentDraft] = useState<CustomAgentDraft>(EMPTY_DRAFT)
  const [agentProblems, setAgentProblems] = useState<CustomAgentProblems>({})
  const [agentBusy, setAgentBusy] = useState(false)

  const profiles = snapshot.profiles
  /**
   * The session list, when this dialog is mounted inside the app.
   *
   * Null in `.harness/` and in the render tests, where there is no provider —
   * hence `useOptionalStore`. It is needed for one thing only: removing a
   * project has to go through the same code path the sidebar's ✕ uses, or the
   * two lists disagree until the next launch.
   */
  const store = useOptionalStore()

  const formId = useId()
  const ids = useId()
  const formRef = useRef<HTMLFormElement>(null)
  /** Retires replies still in flight from a previous open. See ProfilePicker. */
  const ticket = useRef(0)

  const providerRows = useMemo(() => buildProviderRows(detected, added), [detected, added])
  const addFormId = `${formId}-add-agent`
  const startProviders = useMemo(() => toStartProviders(providerRows), [providerRows])

  const resolution = useMemo(
    () =>
      resolveStart(
        {
          providers: startProviders,
          profiles,
          memory,
          defaultProvider,
          defaultProfileId,
          cols: DEFAULT_COLS,
          rows: DEFAULT_ROWS,
        },
        {
          projectPath: selectedPath,
          provider: chosenProvider,
          profileId: chosenProfileId,
          resume: chosenResume ?? undefined,
          firstPrompt: prompt,
        },
      ),
    [
      startProviders,
      profiles,
      memory,
      defaultProvider,
      defaultProfileId,
      selectedPath,
      chosenProvider,
      chosenProfileId,
      chosenResume,
      prompt,
    ],
  )

  // What the dialog paints as selected is what the resolver decided, never the
  // raw click — see the module note.
  const decided = resolution.ok ? resolution.request : null
  const activeRow = providerRows.find((row) => row.id === decided?.provider)
  const resumeState = resumeAvailability(activeRow)
  const profileNotice = isolationNotice(decided?.provider)

  /* ------------------------------------------------------------- loading -- */

  useEffect(() => {
    if (!open) return
    let cancelled = false
    ticket.current += 1

    // Reset on open rather than on close: leaving the last visit's answers on
    // screen while a fresh detection is in flight is how a session gets started
    // against an agent that has since been uninstalled.
    setSelectedPath(projectPath ?? null)
    setChosenProvider(null)
    setChosenProfileId(null)
    setChosenResume(null)
    setPrompt('')
    setRemember(true)
    setFilter('')
    setDetected(null)
    setError(null)
    setStarting(false)
    setBrowsing(false)
    setConfirmRemove(null)
    setSignIn(null)
    setConversations(null)
    setMemory(readStartMemory(KNOWN_PROVIDERS))
    // Back to the agent list, and empty. A half-typed agent left over from last
    // time is the dialog opening on unfinished work with nothing to say how it
    // got there.
    setAddingAgent(false)
    setAgentDraft(EMPTY_DRAFT)
    setAgentProblems({})
    setAgentBusy(false)

    const bridge = profileBridge()
    const api = startBridge()

    if (api?.listProjects) {
      void api.listProjects().then(
        (list) => {
          if (!cancelled) setProjects(parseRecentProjects(list))
        },
        () => {
          // An unreadable project list still leaves Browse, which is the only
          // control that can reach a folder the app has never seen anyway.
          if (!cancelled) setProjects([])
        },
      )
    } else {
      setProjects([])
    }

    if (api?.detectProviders) {
      void api.detectProviders().then(
        (found) => {
          if (!cancelled) setDetected(found)
        },
        // Detection failing leaves every agent selectable — buildProviderRows
        // fails open, and locking the user out of the case we can least diagnose
        // would be worse than letting a spawn fail loudly.
        () => {
          if (!cancelled) setDetected(null)
        },
      )
    }

    if (api?.listAgents) {
      void api.listAgents().then(
        (list) => {
          if (!cancelled) setAdded(parseCustomAgents(list))
        },
        () => {
          // No added agents is a correct first paint and a correct fallback: the
          // four shipped ones are still there, and this dialog still works.
          if (!cancelled) setAdded([])
        },
      )
    }

    if (api?.getPreferences) {
      void api.getPreferences().then(
        (stored) => {
          if (!cancelled) setDefaultProvider(normalizePreferences(stored).defaultProvider)
        },
        () => {
          if (!cancelled) setDefaultProvider(null)
        },
      )
    } else {
      setDefaultProvider(null)
    }

    if (bridge?.listProfiles) {
      const mine = ticket.current
      void bridge.listProfiles().then(
        (found) => {
          if (!cancelled && mine === ticket.current) setSnapshot(parseSnapshot(found))
        },
        () => {
          if (!cancelled && mine === ticket.current) setSnapshot(EMPTY_SNAPSHOT)
        },
      )
    } else {
      setSnapshot(EMPTY_SNAPSHOT)
    }

    return () => {
      cancelled = true
      ticket.current += 1
    }
  }, [open, projectPath])

  // The per-project profile default is resolved in the main process, so the
  // precedence rules for profiles stay in one place and are tested there.
  // Re-run per project: picking a different folder can change the answer.
  useEffect(() => {
    if (!open) return
    const bridge = profileBridge()
    if (!bridge?.resolveProfile) {
      setDefaultProfileId(null)
      return
    }

    let cancelled = false
    const mine = ticket.current
    void bridge.resolveProfile({ projectPath: selectedPath }).then(
      (profile) => {
        if (cancelled || mine !== ticket.current) return
        setDefaultProfileId(parseProfile(profile)?.id ?? null)
      },
      () => {
        if (!cancelled && mine === ticket.current) setDefaultProfileId(null)
      },
    )

    return () => {
      cancelled = true
    }
  }, [open, selectedPath])

  /*
   * Which conversation "Continue" will land on.
   *
   * Only asked for the folder that is actually selected, and only while the
   * store the enumeration reads is the store the session will write to — see
   * `transcriptsAreReadable`. Re-run per folder and per login, because both
   * change the answer, and per provider because a Codex session's history is in
   * a store nothing here can list.
   */
  useEffect(() => {
    if (!open) return
    const cwd = selectedPath
    const api = startBridge()
    if (
      !cwd ||
      !api?.listSessionInsights ||
      decided?.provider !== 'claude' ||
      !transcriptsAreReadable(profiles, decided?.profileId)
    ) {
      setConversations(null)
      return
    }

    /*
     * `cancelled` alone, with no `ticket` — unlike the loads inside the open
     * effect above.
     *
     * The ticket exists to retire replies from a *previous open*, and it works
     * there because that effect re-runs on every open. This one keys on the
     * folder, the agent and the login instead, so a ticket bumped by the open
     * effect while this reply was in flight would throw the answer away and
     * nothing would ever ask again: the deps have not changed, so the effect
     * does not re-run. That is exactly what happened the first time this was
     * written — the login row came back blank on the second opening — and the
     * cleanup below already covers the case the ticket was there for.
     */
    let cancelled = false
    void api.listSessionInsights(cwd).then(
      (list) => {
        if (!cancelled) setConversations(parseConversations(list))
      },
      () => {
        // A store that cannot be read is not "no conversations" — saying so
        // would talk somebody out of a resume that would have worked. Null puts
        // the row back to the sentence that is true either way.
        if (!cancelled) setConversations(null)
      },
    )

    return () => {
      cancelled = true
    }
  }, [open, selectedPath, decided?.provider, decided?.profileId, profiles])

  /*
   * Whose account the selected login is.
   *
   * Read-only — `profiles:signin` runs the agent's own `auth status` and caches
   * it for 30 seconds in the main process, so flipping between two logins costs
   * one probe each and nothing after that.
   */
  useEffect(() => {
    if (!open) return
    const api = startBridge()
    const profileId = decided?.profileId
    const provider = decided?.provider
    if (!profileId || !provider || !api?.profileSignIn || profileNotice !== null) {
      setSignIn(null)
      return
    }

    // `cancelled` alone — see the note on the conversations effect above.
    let cancelled = false
    void api.profileSignIn(profileId, { provider }).then(
      (report) => {
        if (!cancelled) setSignIn(parseSignIn(report))
      },
      () => {
        if (!cancelled) setSignIn(null)
      },
    )

    return () => {
      cancelled = true
    }
  }, [open, decided?.profileId, decided?.provider, profileNotice])

  /* ------------------------------------------------------------- actions -- */

  const browse = useCallback(async () => {
    const api = startBridge()
    if (!api?.pickProjectFolder) {
      setError('Could not open the folder picker.')
      return
    }
    /*
     * Step aside for the system panel, and come back with the answer.
     *
     * `showOpenDialog` opens an NSOpenPanel as a sheet on the window — a native
     * window above every pixel the renderer can draw — and it is smaller than
     * this dialog, so the two were on screen together with the panel's own
     * buttons landing across the agent cards. There is no z-index for that. The
     * dialog is hidden rather than closed, so every choice already made is
     * still here when the panel goes away, whether a folder was picked or not.
     */
    setBrowsing(true)
    try {
      const path = await api.pickProjectFolder()
      if (!path) return
      setProjects((prev) => withProject(prev, path))
      setSelectedPath(path)
    } catch {
      setError('Could not open the folder picker.')
    } finally {
      setBrowsing(false)
    }
  }, [])

  /**
   * Forget a folder.
   *
   * > *"An accidental project — `untitled folder` — got created and is now
   * > permanent."*
   *
   * It was not quite permanent: the sidebar's project header carries a ✕ that
   * calls the same store method. But it is a hover-revealed glyph among three
   * others, labelled *Close project*, which reads as "close the thing that is
   * open" rather than "take this out of the list" — and this panel, where the
   * offending row is actually being looked at, had no way out at all.
   *
   * Routed through the renderer store rather than straight at the bridge,
   * because the sidebar draws its own copy of the project list: calling
   * `deck.removeProject` alone forgets the folder in the main process and
   * leaves the sidebar showing it until the next launch. The bridge is the
   * fallback for a dialog mounted with no store around it — the harness, and
   * the render tests.
   */
  const removeProject = useCallback(
    (path: string) => {
      setConfirmRemove(null)
      setProjects((prev) => prev.filter((project) => project.path !== path))
      if (selectedPath === path) setSelectedPath(null)
      if (store) {
        store.removeProject(path)
        return
      }
      void startBridge()?.removeProject?.(path)?.catch(() => {
        // Forgetting failed in the main process, so the row will be back on the
        // next open. Nothing has been lost and nothing needs saying about it.
      })
    },
    [selectedPath, store],
  )

  /**
   * Send the draft, and let the main process have the last word.
   *
   * The form complains as it is typed and this hands the same draft over anyway,
   * because the check that decides it cannot be made in a renderer: whether the
   * command resolves on this machine's login PATH. That refusal comes back keyed
   * by field, so "there is no such program" lands under Command beside "that has
   * a pipe in it" — from where the person is sitting those are the same kind of
   * answer about the same box.
   */
  const addAgent = useCallback(async () => {
    const api = startBridge()
    if (!api?.addAgent) {
      setAgentProblems({ command: 'This build cannot add agents.' })
      return
    }
    setAgentBusy(true)
    try {
      const outcome = parseAddOutcome(await api.addAgent(agentDraft))
      if (!outcome.ok) {
        setAgentProblems(outcome.problems)
        return
      }
      if (api.listAgents) setAdded(parseCustomAgents(await api.listAgents()))
      // Detection is asked again with it: the handler merges the added agents
      // into the answer, so without this the new row would sit there greyed out
      // until the dialog was closed and opened.
      if (api.detectProviders) setDetected(await api.detectProviders().catch(() => null))
      // Select what was just added. Adding an agent from this dialog is almost
      // always the first step of starting a session on it.
      setChosenProvider(outcome.id)
      setAgentDraft(EMPTY_DRAFT)
      setAgentProblems({})
      setAddingAgent(false)
    } catch (cause) {
      setAgentProblems({
        command: cause instanceof Error ? cause.message : 'That agent could not be added.',
      })
    } finally {
      setAgentBusy(false)
    }
  }, [agentDraft])

  /**
   * Forget an added agent.
   *
   * Nothing is done to a session already running on it — that is a live process
   * with somebody's work in it, and a row leaving a picker is not a reason to
   * kill one. What it does mean is that such a session will not be restored on
   * the next launch, which is what happens when any agent is uninstalled.
   */
  const removeAgent = useCallback(
    async (id: ProviderId) => {
      const api = startBridge()
      if (!api?.removeAgent) return
      await api.removeAgent(id).catch(() => undefined)
      if (api.listAgents) setAdded(parseCustomAgents(await api.listAgents()))
      // Only when the row that was showing is the row that went. Clearing on
      // every removal would move the selection out from under somebody who
      // removed a different agent.
      setChosenProvider((current) => (current === id ? null : current))
    },
    [],
  )

  /** Make the selected login the one every new session gets by default. */
  const makeDefaultLogin = useCallback(async () => {
    const api = startBridge()
    const profileId = decided?.profileId
    if (!api?.setDefaultProfile || !profileId) return
    try {
      await api.setDefaultProfile(profileId)
      const bridge = profileBridge()
      if (bridge?.listProfiles) setSnapshot(parseSnapshot(await bridge.listProfiles()))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not change the default login.')
    }
  }, [decided?.profileId])

  const submit = useCallback(
    async (event: FormEvent) => {
      event.preventDefault()
      if (!resolution.ok || starting) return
      setStarting(true)

      if (remember) {
        const next = rememberStart(memory, resolution.request)
        setMemory(next)
        writeStartMemory(next)
      }

      try {
        await onStart(resolution.request)
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : 'Could not start that session.')
        setStarting(false)
      }
    },
    [memory, onStart, remember, resolution, starting],
  )

  // Enter in a textarea is a newline, so the dialog needs its own confirm
  // chord — the same one the keymap already documents for every dialog.
  const promptKeys = useCallback((event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key !== 'Enter' || !(event.metaKey || event.ctrlKey)) return
    event.preventDefault()
    formRef.current?.requestSubmit()
  }, [])

  const { filtering, shown: recent, hidden } = projectShortlist(projects, filter)
  const confirmChord = formatChord('mod+enter')

  const activeProfile = profiles.find((profile) => profile.id === decided?.profileId)
  const account = loginLine(signIn)
  /*
   * What the pop-up is showing for the selected login, so the line beside it
   * does not say the same thing. `activeProfile` is undefined while the list is
   * still loading or when the resolver settled on nothing, and the pop-up is
   * showing its placeholder then — which is not an address, so the line keeps
   * the whole answer.
   */
  const hint = loginHint(
    signIn,
    activeProfile ? loginOptionLabel(activeProfile, decided?.profileId, signIn) : null,
  )
  const canMakeDefault =
    decided?.profileId != null &&
    profileNotice === null &&
    activeProfile !== undefined &&
    !isDefaultLogin(snapshot, activeProfile)

  // `conversations` is null whenever the store cannot be enumerated honestly —
  // a Codex session, a non-default login, a bridge that did not answer — and
  // the row falls back to the sentence that holds in every one of those cases.
  const lastConversation = conversations && conversationLine(conversations, Date.now())
  const olderConversations = conversations && olderConversationsLine(conversations)

  return (
    /*
     * No standing description under the title.
     *
     * It read "Pick what runs, where, and as whom", which is a sentence naming
     * the three headings directly underneath it — Project, Agent, Login. The
     * budget in `settings/sections/copy-length.test.tsx` exists because this
     * app grows walls of text one defensible clause at a time, and a subtitle
     * that repeats the headings is the first clause of one.
     */
    <Modal
      open={open}
      title={addingAgent ? 'Add an agent' : 'New session'}
      onClose={onClose}
      size="lg"
      hidden={browsing}
      footer={
        addingAgent ? (
          <>
            {/* Back to the list, not out of the dialog. Cancelling a form should
                undo the step that opened it and no more; closing everything would
                also throw away the folder and the login already chosen. */}
            <button
              type="button"
              className="modal-btn"
              onClick={() => {
                setAddingAgent(false)
                setAgentProblems({})
              }}
            >
              Back
            </button>
            <button
              type="submit"
              form={addFormId}
              className="modal-btn primary"
              disabled={agentBusy}
            >
              {agentBusy ? 'Checking…' : 'Add agent'}
            </button>
          </>
        ) : (
          <>
            <span className="ns-footer-hint">{confirmChord} to start</span>
            <button type="button" className="modal-btn" onClick={onClose}>
              Cancel
            </button>
            <button
              type="submit"
              form={formId}
              className="modal-btn primary"
              disabled={!resolution.ok || starting}
            >
              {starting ? 'Starting…' : 'Start session'}
            </button>
          </>
        )
      }
    >
      {addingAgent ? (
        <AddAgentForm
          formId={addFormId}
          draft={agentDraft}
          problems={agentProblems}
          busy={agentBusy}
          onChange={(patch) => {
            setAgentDraft((previous) => ({ ...previous, ...patch }))
            // A field's complaint goes the moment that field is edited. Leaving
            // it up has somebody reading "not on your PATH" about a command they
            // have already corrected.
            setAgentProblems((previous) => {
              const next = { ...previous }
              for (const key of Object.keys(patch) as Array<keyof CustomAgentDraft>) {
                delete next[key]
              }
              return next
            })
          }}
          onSubmit={() => {
            void addAgent()
          }}
        />
      ) : (
      <form id={formId} ref={formRef} className="ns" onSubmit={submit}>
        {error && (
          <p className="ns-error" role="alert">
            {error}
          </p>
        )}

        {/*
          What is wrong, and what the resolver quietly changed — at the top,
          with the error, rather than under the last section.

          These used to sit above the Remember checkbox, at the foot of a panel
          that is taller than the window it opens in. So the one state where
          Start session is disabled put its only explanation off-screen: a dead
          primary button and, to see why, a scroll nobody has a reason to make.
          A form says what is wrong where a form says things, which is the top.
        */}
        {!resolution.ok && <p className="ns-problem">{resolution.problem.message}</p>}

        {resolution.notices.length > 0 && (
          <ul className="ns-notices">
            {resolution.notices.map((notice) => (
              <li key={notice.code} className="ns-notice">
                {notice.message}
              </li>
            ))}
          </ul>
        )}

        {/* ------------------------------------------------------- project -- */}

        <section className="ns-section">
          <div className="ns-section-head">
            <h3 className="ns-section-title" id={`${ids}-project`}>
              Project
            </h3>
            <button type="button" className="ns-link" onClick={() => void browse()}>
              Browse…
            </button>
          </div>

          {/* Only past the cap — see `filtering`. A search field over a list
              that is entirely on screen is a control with nothing to do. */}
          {filtering && (
            <input
              type="search"
              className="ns-filter"
              value={filter}
              placeholder={`Filter ${projects.length} folders`}
              aria-label="Filter projects"
              onChange={(event) => setFilter(event.target.value)}
            />
          )}

          {recent.length === 0 ? (
            <p className="ns-empty">
              {filter.trim() === ''
                ? 'No recent projects. Browse for a folder to run the session in.'
                : 'No folder matches that. Browse for one instead.'}
            </p>
          ) : (
            <div className="ns-projects" role="radiogroup" aria-labelledby={`${ids}-project`}>
              {recent.map((project) => (
                <ProjectRow
                  key={project.path}
                  project={project}
                  radioName={`${formId}-project`}
                  selected={project.path === selectedPath}
                  liveSessions={store?.sessionsForProject(project.path).length ?? 0}
                  confirming={confirmRemove === project.path}
                  onSelect={() => setSelectedPath(project.path)}
                  onAskRemove={() => setConfirmRemove(project.path)}
                  onRemove={() => removeProject(project.path)}
                  onKeep={() => setConfirmRemove(null)}
                />
              ))}
            </div>
          )}

          {/* Said out loud rather than left to a scrollbar: a list that quietly
              stops at eight is a list somebody keeps scrolling for a folder
              that is not in it. */}
          {hidden > 0 && (
            <p className="ns-caveat">{hidden} more — narrow the filter, or Browse.</p>
          )}

          {selectedPath && !recent.some((project) => project.path === selectedPath) && (
            <p className="ns-chosen-path" title={selectedPath}>
              {selectedPath}
            </p>
          )}
        </section>

        {/* -------------------------------------------------------- agent -- */}

        <section className="ns-section">
          <h3 className="ns-section-title" id={`${ids}-agent`}>
            Agent
          </h3>

          <AgentChoices
            rows={providerRows}
            radioName={`${formId}-agent`}
            labelledBy={`${ids}-agent`}
            selected={decided?.provider ?? null}
            onSelect={setChosenProvider}
            onAdd={() => setAddingAgent(true)}
            onRemove={(id) => void removeAgent(id)}
          />
        </section>

        {/* ------------------------------------------------------ profile -- */}

        <section className="ns-section">
          <div className="ns-row">
            <div className="ns-row-text">
              <label className="ns-row-label" htmlFor={`${ids}-profile`}>
                Login
              </label>
              {/* The config directory used to be printed here whenever a login
                  was resolved, so the line under "Login" was
                  `/Users/apple/.claude` — the mechanism, in a panel that is
                  otherwise about decisions, and unreadable as an answer to
                  "which login is this". Then it was the sentence "Which Claude
                  login this session should run as", which is the word above it
                  in a full stop's worth of extra words.

                  What is here now is the answer: the address the agent's own
                  `auth status` reported for the selected login — or, once the
                  pop-up beside it started naming that account itself, the half
                  of the answer the pop-up cannot carry. See `loginHint`.
                  Nothing at all while the probe is in flight — a placeholder
                  that becomes an email a moment later is a line that has to be
                  read twice. */}
              {(profileNotice ?? hint) !== null && (
                <span className="ns-hint" title={account ?? undefined}>
                  {profileNotice ?? hint}
                </span>
              )}
            </div>
            {canMakeDefault && (
              <button
                type="button"
                className="ns-link"
                // The other half of what was asked for: seeing which login is
                // the default is no use without being able to change it from
                // the same row. Only offered when it would do something — the
                // login that already is the default gets no button.
                onClick={() => void makeDefaultLogin()}
              >
                Make default
              </button>
            )}
            <span className="ns-select-wrap">
              <select
                id={`${ids}-profile`}
                className="ns-select"
                value={decided?.profileId ?? ''}
                disabled={profileNotice !== null || profiles.length === 0}
                onChange={(event) => setChosenProfileId(event.target.value || null)}
              >
                {/* An empty value must have an option of its own. Without one
                    the browser falls back to *displaying the first profile*
                    while the value is '', so a Codex session would show
                    "Work" next to a label saying which login it runs as.

                    It said "Default", which was the same slug the rows below
                    were printing and not even true of this case: the value is
                    empty because no account was resolved at all — the list is
                    empty or could not be read — and what the session will
                    actually run as is whatever login the agent already has. */}
                {decided?.profileId == null && (
                  <option value="">
                    {profileNotice ? 'Not applicable' : 'The agent’s own login'}
                  </option>
                )}
                {profiles.map((profile) => (
                  <option key={profile.id} value={profile.id}>
                    {/* The address on the selected row, which is the row the
                        one probe in flight was run for. See the function. */}
                    {loginOptionLabel(profile, decided?.profileId, signIn)}
                  </option>
                ))}
              </select>
            </span>
          </div>

          {/* The standing caveat that used to live here — "A login you have not
              used before asks you to sign in here" — is gone, and the line above
              is why. It was a sentence covering the case where the app did not
              know whether a login had been used; the row now reports that case
              as a fact, `Not signed in`, on the login it actually applies to.
              A general warning next to a specific answer is one line of the
              five this panel was told to cut. */}
        </section>

        {/* ------------------------------------------------ fresh / resume -- */}

        <section className="ns-section">
          <h3 className="ns-section-title" id={`${ids}-history`}>
            Conversation
          </h3>

          <div className="ns-choices" role="radiogroup" aria-labelledby={`${ids}-history`}>
            <label className="ns-choice" data-selected={!decided?.resume}>
              <input
                type="radio"
                name={`${formId}-history`}
                checked={!decided?.resume}
                onChange={() => setChosenResume(false)}
              />
              <span className="ns-mark" aria-hidden="true" />
              <span className="ns-agent-text">
                {/* No second line. It said "A new conversation with no prior
                    context", which is the two words above it spelled out. */}
                <span className="ns-agent-label">Start fresh</span>
              </span>
            </label>

            <label
              className="ns-choice"
              data-selected={decided?.resume === true}
              data-available={resumeState.enabled}
            >
              <input
                type="radio"
                name={`${formId}-history`}
                checked={decided?.resume === true}
                disabled={!resumeState.enabled}
                onChange={() => setChosenResume(true)}
              />
              <span className="ns-mark" aria-hidden="true" />
              <span className="ns-agent-text">
                <span className="ns-agent-label">Continue the last conversation</span>
                {/*
                  Which one.

                  > *"which conversation will it bring? …So we know which one
                  > session we are going to continue because we might have
                  > multiple sessions before."*

                  It said "Picks up the most recent session in this folder",
                  which restates the flag without answering the question. When
                  the transcripts can be enumerated this is the conversation
                  itself — when it was last written to, and the head of its
                  session id, with the whole id in the row's title because that
                  is what you would paste into `claude --resume`. When they
                  cannot be, it falls back to the sentence that is true in every
                  case rather than naming a conversation from the wrong store.
                */}
                <span className="ns-hint" title={conversations?.[0]?.sessionId}>
                  {resumeState.reason ??
                    lastConversation ??
                    'The agent picks up its own most recent conversation here.'}
                </span>
              </span>
            </label>
          </div>

          {/* Why there is no picker, said once, and only when there is more than
              one conversation to pick between. `CreateSessionInput` carries a
              boolean and the flag it becomes means "the newest one" — see the
              note on `Conversation`. */}
          {resumeState.enabled && olderConversations && (
            <p className="ns-caveat">{olderConversations}</p>
          )}
        </section>

        {/* ------------------------------------------------- first prompt -- */}

        <section className="ns-section">
          <label className="ns-row-label" htmlFor={`${ids}-prompt`}>
            First message <span className="ns-optional">optional</span>
          </label>
          <textarea
            id={`${ids}-prompt`}
            className="ns-prompt"
            rows={2}
            value={prompt}
            placeholder="What should it start on?"
            onChange={(event) => setPrompt(event.target.value)}
            onKeyDown={promptKeys}
          />
          {/* Why Enter is submit in an agent prompt is the agent's business,
              not this dialog's. That a multi-line paste will arrive flattened
              is the part that changes what somebody types. */}
          <p className="ns-hint">Sent once the agent is ready. Line breaks become spaces.</p>
          {decided?.title && (
            <p className="ns-preview">
              Tab will be titled <strong>{decided.title}</strong>
            </p>
          )}
        </section>

        <label className="ns-remember">
          <input
            type="checkbox"
            checked={remember}
            onChange={(event) => setRemember(event.target.checked)}
          />
          {/* No second line. It read "The next session in this folder opens
              with the same agent, login and history", which is the label again
              with the three sections named — and it was the last 34px keeping
              the panel taller than the window it opens in. */}
          <span className="ns-agent-label">Remember these choices for this project</span>
        </label>
      </form>
      )}
    </Modal>
  )
}
