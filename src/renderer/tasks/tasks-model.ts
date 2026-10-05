/**
 * CRM tasks, as the window reads them: the agents, the connections, and the
 * read-only mirror of the work in hand.
 *
 * The main process owns all of it (`src/main/tasks/`). The renderer tsconfig
 * cannot see `src/main`, so the shapes are restated here and every answer that
 * crosses the bridge is read field by field rather than cast — the arrangement
 * `ai-apps-setup.ts` and `board.ts` already use.
 *
 * Two words are kept apart on purpose. A **status** belongs to the CRM and is
 * shown exactly as the CRM spells it. Queued, running and exited are this app's
 * own **process states**; they are never called a status anywhere on screen.
 */

import { BRAND } from '../../shared/brand'

/* ---------------------------------------------------------------- shapes -- */

/** Terminal Deck's own states, never a CRM status. */
export type ProcessState = 'queued' | 'running' | 'exited' | 'idle'

export interface AgentProfile {
  id: string
  name: string
  role: string
  /** Which coding agent runs it; null for the app's default. */
  provider: string | null
  account: string | null
  model: string | null
  /** One of {@link EFFORT_CHOICES}; null leaves the agent's own. */
  effort: string | null
  /** Put at the top of every brief this agent is given. */
  instructions: string | null
  /** Asked of the agent in its brief — a preference, not an enforcement. */
  toolsPreferred: string[]
  toolsAvoided: string[]
  /** Asked for by name; nothing is installed. */
  skills: string[]
  /** Refused by Claude Code itself (`--disallowedTools`). Owner-chosen; never filled from the requests above. */
  blockedTools: string[]
  /** Claude Code started with every skill off. */
  skillsOff: boolean
  maxConcurrent: number
  /** 0: no limit. */
  maxRunMinutes: number
  /** 0: closed at once. */
  keepAliveMinutes: number
  /** Null: Hoot checks the result. */
  verifyCommand: string | null
}

export interface StatusConfig {
  statuses: string[]
  initial: string
  completed: string
  onStarted: string | null
  onVerified: string | null
  onBlocked: string | null
}

export interface CrmConnection {
  keyId: string
  /** The owner's name for this CRM; null on one made before names. */
  name: string | null
  enabled: boolean
  eventsUrl: string | null
  hasEventsSecret: boolean
  statuses: StatusConfig
  hootIdentity: string | null
  /** CRM identity → agent id. */
  identities: Record<string, string>
  allowedSenders: string[]
  folders: string[]
  maxHops: number
}

export interface TaskRow {
  id: string
  keyId: string
  externalTaskId: string
  title: string
  /** The agent's name, or Hoot. */
  agent: string
  project: string
  crmStatus: string
  process: ProcessState
  keepOpenUntil: number | null
  verified: boolean | null
  updatedAt: number
  /** Made here, with no CRM: editable on the Tasks page. */
  local: boolean
  /** `none`, `me`, `hoot`, or an agent's id. */
  assignee: string
  instructions: string
  /** The agent that handed it to you, while you have it. */
  handedFrom: string | null
  notes: TaskNote[]
  /* The CRM's task fields (the reference CRM's task table), for a local task. */
  priority: string | null
  startDate: string | null
  dueDate: string | null
  startTime: string | null
  dueTime: string | null
  labels: string[]
  /** A board, or category, of your own naming; null for none. */
  board: string | null
  taskType: 'task' | 'milestone'
  estimateMinutes: number | null
  archivedAt: number | null
  /** Set while in the Trash. */
  deletedAt: number | null
  completedAt: number | null
  position: number | null
  /** How often it comes back, the CRM's coarse frequency; null = one-off. */
  recurrence: string | null
  createdAt: number
}

/** One line of a local task's own record. */
export interface TaskNote {
  at: number
  by: string
  kind: string
  text: string
}

export interface TasksState {
  agents: AgentProfile[]
  connections: CrmConnection[]
  keys: TasksKey[]
  tasks: TaskRow[]
  /** Your deleted tasks, newest first — kept whole until restored. */
  trash: TaskRow[]
  outbox: { pending: number; undelivered: number }
  /** The statuses a local task can have. */
  localStatuses: string[]
}

export interface TasksResult {
  ok: boolean
  message: string | null
  state: TasksState | null
  /** A new signing secret, on the one answer that made it. Shown once. */
  secret: string | null
  /** A new CRM's own access key, on the one answer that made it. Shown once. */
  key?: string | null
}

/** An access key as the CRM picker sees it. */
export interface TasksKey {
  id: string
  name: string
  /** Made for a CRM: it only sends tasks. */
  crmOnly: boolean
  /** The AI app last seen using it, if any. */
  lastApp: string | null
}

/** One thing a picker offers. */
export interface InventoryChoice {
  value: string
  label: string
  where: string
}

/** What is installed for an agent's Claude Code account. */
export interface AgentInventory {
  account: string
  tools: InventoryChoice[]
  skills: InventoryChoice[]
}

export function toInventory(raw: unknown): AgentInventory | null {
  const r = record(raw)
  if (!r || !Array.isArray(r.tools) || !Array.isArray(r.skills)) return null
  const choices = (list: unknown[]): InventoryChoice[] =>
    list.flatMap((entry) => {
      const e = record(entry)
      const value = text(e?.value)
      return value === null ? [] : [{ value, label: text(e?.label) ?? value, where: text(e?.where) ?? '' }]
    })
  return { account: text(r.account) ?? 'Default', tools: choices(r.tools), skills: choices(r.skills) }
}

/* ---------------------------------------------------------------- limits -- */

/** The main process's own limits (`task-config.ts`), so a form can say them first. */
export const LIMITS = {
  maxConcurrent: 5,
  maxMinutes: 24 * 60,
  defaultRunMinutes: 60,
  defaultKeepAliveMinutes: 30,
  maxHops: 5,
  defaultHops: 3,
} as const

/** The effort levels a session's own control takes (`agent-controls.ts`), and the label each shows. */
export const EFFORT_CHOICES: ReadonlyArray<{ id: string; label: string }> = [
  { id: 'low', label: 'Low' },
  { id: 'medium', label: 'Medium' },
  { id: 'high', label: 'High' },
  { id: 'xhigh', label: 'Extra high' },
  { id: 'max', label: 'Max' },
  { id: 'ultracode', label: 'Ultracode' },
  { id: 'auto', label: 'Auto' },
]

/** The reference CRM's five statuses, which a new connection starts with. */
export const DEFAULT_CRM_STATUSES: StatusConfig = {
  statuses: ['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck'],
  initial: 'To-Do',
  completed: 'Done',
  onStarted: 'Working on it',
  onVerified: 'Done',
  onBlocked: 'Stuck',
}

/* ---------------------------------------------------------------- bridge -- */

/**
 * What the Tasks pane and the Overview mirror need from `window.deck`. The
 * names are the preload's: `contract.test.ts` matches every `*Bridge`
 * interface against what it exposes.
 */
export interface TasksBridge {
  tasksState(): Promise<unknown>
  tasksAgentSave(agent: unknown): Promise<unknown>
  tasksAgentRemove(id: string): Promise<unknown>
  tasksConnectionSave(keyId: string, patch: unknown): Promise<unknown>
  tasksConnectionRemove(keyId: string): Promise<unknown>
  tasksConnectionCreate(input: { name: string; confirmed: boolean }): Promise<unknown>
  tasksInventory(agent: { provider: string | null; account: string | null }): Promise<unknown>
  tasksCloseSession(taskId: string): Promise<unknown>
  tasksLocalCreate(input: unknown): Promise<unknown>
  tasksLocalUpdate(id: string, patch: unknown): Promise<unknown>
  tasksLocalReply(id: string, text: string): Promise<unknown>
  tasksLocalDelete(id: string): Promise<unknown>
  tasksLocalRestore(id: string): Promise<unknown>
  /** One call of the task popup's (`src/shared/crm/detail-contract.ts`): a name and its arguments. */
  tasksLocalDetail(fn: string, args: unknown[]): Promise<unknown>
  onTasksChanged(callback: () => void): () => void
}

const BRIDGE_METHODS: ReadonlyArray<keyof TasksBridge> = [
  'tasksState',
  'tasksAgentSave',
  'tasksAgentRemove',
  'tasksConnectionSave',
  'tasksConnectionRemove',
  'tasksConnectionCreate',
  'tasksInventory',
  'tasksCloseSession',
  'tasksLocalCreate',
  'tasksLocalUpdate',
  'tasksLocalReply',
  'tasksLocalDelete',
  'tasksLocalRestore',
  'tasksLocalDetail',
  'onTasksChanged',
]

/**
 * The bridge as it exists, each method called through its host, for the
 * reason `resolveAiAppsBridge` gives. `globalThis` so both surfaces render to
 * a string in tests.
 */
export function resolveTasksBridge(host?: unknown): Partial<TasksBridge> {
  const source = host ?? (globalThis as unknown as { deck?: unknown }).deck
  if (typeof source !== 'object' || source === null) return {}
  const all = source as Record<string, unknown>
  const bridge: Record<string, unknown> = {}
  for (const name of BRIDGE_METHODS) {
    if (typeof all[name] !== 'function') continue
    bridge[name] = (...args: unknown[]): unknown => (all[name] as (...a: unknown[]) => unknown).apply(all, args)
  }
  return bridge as Partial<TasksBridge>
}

/* ------------------------------------------------------------- narrowing -- */

function record(value: unknown): Record<string, unknown> | null {
  return typeof value === 'object' && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

function text(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null
}

function count(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === 'string') : []
}

function toAgent(raw: unknown): AgentProfile | null {
  const r = record(raw)
  const id = text(r?.id)
  const name = text(r?.name)
  if (!r || id === null || name === null) return null
  return {
    id,
    name,
    role: text(r.role) ?? 'general',
    provider: text(r.provider),
    account: text(r.account),
    model: text(r.model),
    effort: text(r.effort),
    instructions: text(r.instructions),
    toolsPreferred: strings(r.toolsPreferred),
    toolsAvoided: strings(r.toolsAvoided),
    skills: strings(r.skills),
    blockedTools: strings(r.blockedTools),
    skillsOff: r.skillsOff === true,
    maxConcurrent: count(r.maxConcurrent, 1),
    maxRunMinutes: count(r.maxRunMinutes, LIMITS.defaultRunMinutes),
    keepAliveMinutes: count(r.keepAliveMinutes, LIMITS.defaultKeepAliveMinutes),
    verifyCommand: text(r.verifyCommand),
  }
}

function toStatuses(raw: unknown): StatusConfig {
  const r = record(raw)
  const statuses = strings(r?.statuses)
  if (!r || statuses.length === 0) return { ...DEFAULT_CRM_STATUSES, statuses: [...DEFAULT_CRM_STATUSES.statuses] }
  return {
    statuses,
    initial: text(r.initial) ?? statuses[0],
    completed: text(r.completed) ?? statuses[statuses.length - 1],
    onStarted: text(r.onStarted),
    onVerified: text(r.onVerified),
    onBlocked: text(r.onBlocked),
  }
}

function toConnection(raw: unknown): CrmConnection | null {
  const r = record(raw)
  const keyId = text(r?.keyId)
  if (!r || keyId === null) return null
  const identities: Record<string, string> = {}
  for (const [identity, agentId] of Object.entries(record(r.identities) ?? {})) {
    if (typeof agentId === 'string') identities[identity] = agentId
  }
  return {
    keyId,
    name: text(r.name),
    // Only a literal true draws it on: a connection that decides who can run
    // agents here must never be guessed into being switched on.
    enabled: r.enabled === true,
    eventsUrl: text(r.eventsUrl),
    hasEventsSecret: r.hasEventsSecret === true,
    statuses: toStatuses(r.statuses),
    hootIdentity: text(r.hootIdentity),
    identities,
    allowedSenders: strings(r.allowedSenders),
    folders: strings(r.folders),
    maxHops: count(r.maxHops, LIMITS.defaultHops),
  }
}

function toProcess(value: unknown): ProcessState {
  return value === 'running' || value === 'exited' || value === 'idle' ? value : 'queued'
}

function toNote(raw: unknown): TaskNote | null {
  const r = record(raw)
  if (!r || typeof r.text !== 'string') return null
  return { at: count(r.at, 0), by: text(r.by) ?? '', kind: text(r.kind) ?? 'progress', text: r.text }
}

function toTask(raw: unknown): TaskRow | null {
  const r = record(raw)
  const id = text(r?.id)
  if (!r || id === null) return null
  return {
    id,
    keyId: text(r.keyId) ?? '',
    externalTaskId: text(r.externalTaskId) ?? '',
    title: text(r.title) ?? 'Untitled task',
    agent: text(r.agent) ?? BRAND.assistant,
    project: text(r.project) ?? '',
    crmStatus: typeof r.crmStatus === 'string' ? r.crmStatus : '',
    process: toProcess(r.process),
    keepOpenUntil: typeof r.keepOpenUntil === 'number' ? r.keepOpenUntil : null,
    verified: typeof r.verified === 'boolean' ? r.verified : null,
    updatedAt: count(r.updatedAt, 0),
    local: r.local === true,
    assignee: text(r.assignee) ?? 'none',
    instructions: typeof r.instructions === 'string' ? r.instructions : '',
    handedFrom: text(r.handedFrom),
    notes: (Array.isArray(r.notes) ? r.notes : []).map(toNote).filter((note): note is TaskNote => note !== null),
    priority: text(r.priority),
    startDate: text(r.startDate),
    dueDate: text(r.dueDate),
    startTime: text(r.startTime),
    dueTime: text(r.dueTime),
    labels: strings(r.labels),
    board: text(r.board),
    taskType: r.taskType === 'milestone' ? 'milestone' : 'task',
    estimateMinutes: typeof r.estimateMinutes === 'number' ? r.estimateMinutes : null,
    archivedAt: typeof r.archivedAt === 'number' ? r.archivedAt : null,
    deletedAt: typeof r.deletedAt === 'number' ? r.deletedAt : null,
    completedAt: typeof r.completedAt === 'number' ? r.completedAt : null,
    position: typeof r.position === 'number' ? r.position : null,
    recurrence: text(r.recurrence),
    createdAt: count(r.createdAt, 0),
  }
}

export function toTasksState(raw: unknown): TasksState | null {
  const r = record(raw)
  if (!r || !Array.isArray(r.agents) || !Array.isArray(r.connections)) return null
  const outbox = record(r.outbox) ?? {}
  return {
    agents: r.agents.map(toAgent).filter((agent): agent is AgentProfile => agent !== null),
    connections: r.connections.map(toConnection).filter((one): one is CrmConnection => one !== null),
    keys: (Array.isArray(r.keys) ? r.keys : []).flatMap((key) => {
      const k = record(key)
      const id = text(k?.id)
      return id === null ? [] : [{ id, name: text(k?.name) ?? id, crmOnly: k?.crmOnly === true, lastApp: text(k?.lastApp) }]
    }),
    tasks: (Array.isArray(r.tasks) ? r.tasks : []).map(toTask).filter((task): task is TaskRow => task !== null),
    trash: (Array.isArray(r.trash) ? r.trash : []).map(toTask).filter((task): task is TaskRow => task !== null),
    outbox: { pending: count(outbox.pending, 0), undelivered: count(outbox.undelivered, 0) },
    localStatuses: strings(r.localStatuses).length > 0 ? strings(r.localStatuses) : [...DEFAULT_CRM_STATUSES.statuses],
  }
}

export function toTasksResult(raw: unknown): TasksResult {
  const r = record(raw)
  const ok = r?.ok === true
  return {
    ok,
    message: text(r?.message) ?? (ok ? null : 'That did not go through, and the app did not say why.'),
    state: toTasksState(r?.state),
    secret: ok ? text(r?.secret) : null,
    key: ok ? text(r?.key) : null,
  }
}

/* ---------------------------------------------------------------- mirror -- */

/** The mirror shows only once there is something to mirror, or somewhere it would come from. */
export function showMirror(state: TasksState | null): boolean {
  return state !== null && (state.tasks.length > 0 || state.connections.length > 0)
}

export function processLabel(process: ProcessState): string {
  if (process === 'idle') return ''
  return process === 'running' ? 'Running' : process === 'exited' ? 'Finished' : 'Queued'
}

/* ------------------------------------------------------------ local tasks -- */

/** A local task while it is being typed. */
export interface LocalDraft {
  title: string
  instructions: string
  project: string
  /** `none`, `me`, `hoot`, or an agent's id. */
  assignee: string
  status: string
}

export function localDraftOf(task: TaskRow | null, statuses: readonly string[]): LocalDraft {
  return {
    title: task?.title ?? '',
    instructions: task?.instructions ?? '',
    project: task?.project ?? '',
    assignee: task?.assignee ?? 'none',
    status: task?.crmStatus ?? statuses[0] ?? 'To-Do',
  }
}

/** What `tasks:local-create` / `tasks:local-update` is sent, or what to fix first. */
export function localPayload(draft: LocalDraft): { ok: true; payload: LocalDraft } | { ok: false; message: string } {
  const title = draft.title.trim()
  if (title === '') return { ok: false, message: 'Give the task a title.' }
  const project = draft.project.trim()
  const working = draft.assignee !== 'none' && draft.assignee !== 'me'
  if (working && project === '') return { ok: false, message: 'Choose the project folder the agent should work in.' }
  return { ok: true, payload: { ...draft, title, instructions: draft.instructions.trim(), project } }
}

/** The choices for who has a task: nobody, you, Hoot, then every task agent. */
export function assigneeChoices(agents: readonly AgentProfile[]): Array<{ id: string; label: string }> {
  return [
    { id: 'none', label: 'Unassigned' },
    { id: 'me', label: 'Me' },
    { id: 'hoot', label: BRAND.assistant },
    ...agents.map((agent) => ({ id: agent.id, label: agent.name })),
  ]
}

/** Whole minutes left on a kept-open session, at least 1 while any is left; null when none. */
export function keptOpenMinutes(keepOpenUntil: number | null, now: number): number | null {
  if (keepOpenUntil === null || keepOpenUntil <= now) return null
  return Math.max(1, Math.ceil((keepOpenUntil - now) / 60_000))
}

/* ------------------------------------------------------------ agent form -- */

/** An agent while it is being typed: every field as the input holds it. */
export interface AgentDraft {
  /** Empty for a new agent; the id is made from the name. */
  id: string
  name: string
  role: string
  /** Empty for the app's default. */
  provider: string
  account: string
  model: string
  /** Empty for the agent's own. */
  effort: string
  instructions: string
  /** Picked from what is installed; a saved name not found here is kept. Requests, not enforced. */
  toolsPreferred: string[]
  toolsAvoided: string[]
  skills: string[]
  /** Enforced by Claude Code. Empty and off unless the owner picks them. */
  blockedTools: string[]
  skillsOff: boolean
  maxConcurrent: string
  maxRunMinutes: string
  keepAliveMinutes: string
  verifyCommand: string
}

export function draftOf(agent: AgentProfile | null): AgentDraft {
  return {
    id: agent?.id ?? '',
    name: agent?.name ?? '',
    role: agent?.role ?? '',
    provider: agent?.provider ?? '',
    account: agent?.account ?? '',
    model: agent?.model ?? '',
    effort: agent?.effort ?? '',
    instructions: agent?.instructions ?? '',
    toolsPreferred: [...(agent?.toolsPreferred ?? [])],
    toolsAvoided: [...(agent?.toolsAvoided ?? [])],
    skills: [...(agent?.skills ?? [])],
    blockedTools: [...(agent?.blockedTools ?? [])],
    skillsOff: agent?.skillsOff === true,
    maxConcurrent: String(agent?.maxConcurrent ?? 1),
    maxRunMinutes: String(agent?.maxRunMinutes ?? LIMITS.defaultRunMinutes),
    keepAliveMinutes: String(agent?.keepAliveMinutes ?? LIMITS.defaultKeepAliveMinutes),
    verifyCommand: agent?.verifyCommand ?? '',
  }
}

/** A stable id from a name: lower case, letters, digits and dashes. Unique among `taken`. */
export function slugFor(name: string, taken: readonly string[] = []): string {
  const base =
    name
      .toLowerCase()
      .normalize('NFKD')
      .replace(/[^a-z0-9]+/g, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 36) || 'agent'
  if (!taken.includes(base)) return base
  for (let n = 2; ; n++) {
    const next = `${base}-${n}`
    if (!taken.includes(next)) return next
  }
}

/** A whole number from a box, or the sentence that says why not. Empty takes the fallback. */
export function wholeFrom(raw: string, field: string, min: number, max: number, fallback: number): number | string {
  const trimmed = raw.trim()
  if (trimmed === '') return fallback
  const value = Number(trimmed)
  if (!Number.isInteger(value) || value < min || value > max) return `${field} has to be a whole number from ${min} to ${max}.`
  return value
}

const orNull = (value: string): string | null => (value.trim() === '' ? null : value.trim())

/** Said wherever an enforced limit meets an agent that cannot keep it. */
export const ENFORCE_ONLY_CLAUDE = 'Only Claude Code can block tools or turn skills off. Clear them, or choose Claude Code.'

/** Trimmed, blanks dropped, first of each kept. */
const unique = (values: readonly string[]): string[] => [...new Set(values.map((value) => value.trim()).filter((value) => value !== ''))]

/** What `tasks:agent-save` is sent, or the sentence that says what to fix first. */
export function agentPayload(
  draft: AgentDraft,
  agents: readonly AgentProfile[],
): { ok: true; payload: AgentProfile } | { ok: false; message: string } {
  const name = draft.name.trim()
  if (name === '') return { ok: false, message: 'Give the agent a name.' }
  const maxConcurrent = wholeFrom(draft.maxConcurrent, 'Tasks at once', 1, LIMITS.maxConcurrent, 1)
  const maxRunMinutes = wholeFrom(draft.maxRunMinutes, 'Longest run', 0, LIMITS.maxMinutes, LIMITS.defaultRunMinutes)
  const keepAliveMinutes = wholeFrom(draft.keepAliveMinutes, 'Keep open', 0, LIMITS.maxMinutes, LIMITS.defaultKeepAliveMinutes)
  for (const value of [maxConcurrent, maxRunMinutes, keepAliveMinutes]) {
    if (typeof value === 'string') return { ok: false, message: value }
  }
  if (draft.provider !== '' && draft.provider !== 'claude' && (unique(draft.blockedTools).length > 0 || draft.skillsOff)) {
    return { ok: false, message: ENFORCE_ONLY_CLAUDE }
  }
  const id = draft.id !== '' ? draft.id : slugFor(name, agents.map((agent) => agent.id))
  return {
    ok: true,
    payload: {
      id,
      name,
      role: draft.role.trim() === '' ? 'general' : draft.role.trim(),
      provider: orNull(draft.provider),
      account: orNull(draft.account),
      model: orNull(draft.model),
      effort: EFFORT_CHOICES.some((choice) => choice.id === draft.effort) ? draft.effort : null,
      instructions: draft.instructions.trim() === '' ? null : draft.instructions.trim(),
      toolsPreferred: unique(draft.toolsPreferred),
      toolsAvoided: unique(draft.toolsAvoided),
      skills: unique(draft.skills),
      blockedTools: unique(draft.blockedTools),
      skillsOff: draft.skillsOff,
      maxConcurrent: maxConcurrent as number,
      maxRunMinutes: maxRunMinutes as number,
      keepAliveMinutes: keepAliveMinutes as number,
      verifyCommand: orNull(draft.verifyCommand),
    },
  }
}

/**
 * Save one agent: check the draft here first, then send it. A draft that
 * cannot be sent never reaches the bridge, and answers the same way a refusal
 * from the main process does.
 */
export async function saveAgent(
  bridge: Partial<TasksBridge>,
  draft: AgentDraft,
  agents: readonly AgentProfile[],
): Promise<TasksResult> {
  const checked = agentPayload(draft, agents)
  if (!checked.ok) return { ok: false, message: checked.message, state: null, secret: null }
  if (!bridge.tasksAgentSave) return { ok: false, message: 'This build cannot save agents.', state: null, secret: null }
  return toTasksResult(await bridge.tasksAgentSave(checked.payload))
}

/* ------------------------------------------------------- connection form -- */

/** A connection while it is being typed. Lists are one entry per line. */
export interface ConnectionDraft {
  /** The owner's name for this CRM. Empty: unnamed. */
  name: string
  eventsUrl: string
  hootIdentity: string
  allowedSenders: string
  folders: string
  maxHops: string
  identities: Array<{ identity: string; agentId: string }>
  statuses: string
  initial: string
  completed: string
  /** Empty: a comment only. */
  onStarted: string
  onVerified: string
  onBlocked: string
}

export function connectionDraftOf(connection: CrmConnection): ConnectionDraft {
  const s = connection.statuses
  return {
    name: connection.name ?? '',
    eventsUrl: connection.eventsUrl ?? '',
    hootIdentity: connection.hootIdentity ?? '',
    allowedSenders: connection.allowedSenders.join('\n'),
    folders: connection.folders.join('\n'),
    maxHops: String(connection.maxHops),
    identities: Object.entries(connection.identities).map(([identity, agentId]) => ({ identity, agentId })),
    statuses: s.statuses.join('\n'),
    initial: s.initial,
    completed: s.completed,
    onStarted: s.onStarted ?? '',
    onVerified: s.onVerified ?? '',
    onBlocked: s.onBlocked ?? '',
  }
}

/** Lines of a list box: trimmed, blanks dropped, repeats dropped. */
export function linesOf(raw: string): string[] {
  const out: string[] = []
  for (const line of raw.split('\n')) {
    const trimmed = line.trim()
    if (trimmed !== '' && !out.includes(trimmed)) out.push(trimmed)
  }
  return out
}

/** The patch `tasks:connection-save` is sent for the form's fields, or what to fix first. */
export function connectionPatch(draft: ConnectionDraft): { ok: true; patch: Record<string, unknown> } | { ok: false; message: string } {
  const maxHops = wholeFrom(draft.maxHops, 'The hand-off limit', 1, LIMITS.maxHops, LIMITS.defaultHops)
  if (typeof maxHops === 'string') return { ok: false, message: maxHops }
  const statuses = linesOf(draft.statuses)
  if (statuses.length === 0) return { ok: false, message: 'Name at least one CRM status.' }
  const pick = (value: string, fallback: string): string => (statuses.includes(value) ? value : fallback)
  const optional = (value: string): string | null => (statuses.includes(value) ? value : null)
  const identities: Record<string, string> = {}
  for (const row of draft.identities) {
    const identity = row.identity.trim()
    if (identity === '' && row.agentId === '') continue
    if (identity === '') return { ok: false, message: 'Each agent identity needs its CRM identity id.' }
    if (row.agentId === '') return { ok: false, message: `Choose which agent ${identity} is.` }
    identities[identity] = row.agentId
  }
  return {
    ok: true,
    patch: {
      name: orNull(draft.name),
      eventsUrl: orNull(draft.eventsUrl),
      hootIdentity: orNull(draft.hootIdentity),
      allowedSenders: linesOf(draft.allowedSenders),
      folders: linesOf(draft.folders),
      maxHops,
      identities,
      statuses: {
        statuses,
        initial: pick(draft.initial, statuses[0]),
        completed: pick(draft.completed, statuses[statuses.length - 1]),
        onStarted: optional(draft.onStarted),
        onVerified: optional(draft.onVerified),
        onBlocked: optional(draft.onBlocked),
      },
    },
  }
}
