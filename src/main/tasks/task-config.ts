/**
 * What the owner set up for CRM tasks: the agents Hoot can hand work to, and
 * the CRM connections allowed to send work at all.
 *
 * ## Why a file of its own and not the settings store
 *
 * The settings store is a flat map of short values. An agent is a record with
 * eight fields and there can be several; a connection carries a signing secret.
 * So both live in `<userData>/remote/task-config.json`, 0600 and atomic through
 * `secret-file.ts`, beside the access keys whose ids the connections are keyed
 * by.
 *
 * ## The CRM is the task master
 *
 * Nothing here is a task. A task exists because a CRM said so (`task-api.ts`);
 * this file only says *who may say so* and *who does the work*. Every
 * connection starts switched off, with nobody allowed to send and no folder to
 * work in, so a key made for some other purpose never becomes a way to run
 * agents by accident.
 *
 * ## Statuses belong to the CRM
 *
 * A connection carries the CRM's own statuses, spelt exactly as it spells them,
 * and which one each thing that happens here sets. Terminal Deck has no task
 * statuses of its own; queued, running and exited are its process states and
 * are never sent as a status. The default list is the reference CRM's: To-Do
 * (the default), Working on it, In Progress, Done (the only
 * completed one) and Stuck. "Working on it" and "In Progress" are distinct and
 * this app never chooses between them by its own reasoning — the connection
 * names which one, if any, a started task gets.
 */

import { existsSync, readFileSync } from 'node:fs'
import { isAbsolute, join, resolve } from 'node:path'
import { writeSecretFile } from '../remote/secret-file'
import { newWebhookSecret, webhookUrlProblem } from '../deck-control/notify-webhook'
import { EFFORT_LEVELS } from '../agent-controls'

export const TASK_CONFIG_FILE = 'task-config.json'

export const MAX_AGENTS = 20
export const MAX_AGENT_CONCURRENT = 5
export const MAX_MINUTES = 24 * 60
export const DEFAULT_RUN_MINUTES = 60
export const DEFAULT_KEEP_ALIVE_MINUTES = 30
export const MAX_SENDERS = 20
export const MAX_FOLDERS = 20
export const MAX_STATUSES = 20
export const DEFAULT_MAX_HOPS = 3
export const MAX_HOPS = 5
export const MAX_INSTRUCTIONS_CHARS = 8_000
export const MAX_TOOL_NAMES = 30
export const MAX_SKILLS = 20

/* ------------------------------------------------------------------ types -- */

/** One worker Hoot can hand a task to. */
export interface AgentProfile {
  /** Stable, lower-case: what a CRM identity maps to. */
  id: string
  /** What Hoot calls it and the board shows. Unique, ignoring case. */
  name: string
  /** Free text: builder, reviewer, tester, researcher… */
  role: string
  /** Which coding agent runs it; null for the app's default. */
  provider: string | null
  /** Which of that agent's logins, by name or id; null for its default. */
  account: string | null
  /** Set on the session right after it starts; null leaves the agent's own choice. */
  model: string | null
  /** Effort level, set the same way as the model. Null leaves the agent's own. */
  effort: string | null
  /** Standing instructions, put at the top of every brief this agent is given. */
  instructions: string | null
  /**
   * Tools the agent is asked to prefer, and to avoid. A preference written into
   * its brief, never an enforcement: what the agent may actually do is still
   * decided by its own permission prompts and settings, which this changes nothing in.
   */
  toolsPreferred: string[]
  toolsAvoided: string[]
  /** Skills the agent is asked to use, by name. Nothing is installed; Claude Code finds its own by name. */
  skills: string[]
  /** Tasks it may run at once. */
  maxConcurrent: number
  /** Longest a run may take before it is stopped and the task is Stuck. 0: no limit. */
  maxRunMinutes: number
  /** How long a finished session stays open to continue in. 0: closed at once. */
  keepAliveMinutes: number
  /** Run in the project after a finished turn; exit 0 is a verified completion. Null: Hoot verifies. */
  verifyCommand: string | null
}

/** The CRM's statuses, and which each thing that happens here sets. */
export interface StatusConfig {
  statuses: string[]
  /** What a new task is in when the CRM says nothing. */
  initial: string
  /** The one status that means completed. */
  completed: string
  /** Set when an agent starts on a task. Null: a comment only. */
  onStarted: string | null
  /** Set after a verified completion. Null: a comment only. */
  onVerified: string | null
  /** Set on a blocker, a question, a failed run or a failed check. Null: a comment only. */
  onBlocked: string | null
}

/** The reference CRM's five statuses. */
export const DEFAULT_CRM_STATUSES: StatusConfig = Object.freeze({
  statuses: ['To-Do', 'Working on it', 'In Progress', 'Done', 'Stuck'],
  initial: 'To-Do',
  completed: 'Done',
  onStarted: 'Working on it',
  onVerified: 'Done',
  onBlocked: 'Stuck',
}) as StatusConfig

/**
 * The statuses of a task made here, with no CRM: the same five, so a task reads
 * the same whichever way it came. Fixed — there is no CRM to match.
 */
export const LOCAL_STATUSES: StatusConfig = DEFAULT_CRM_STATUSES

/** One CRM allowed to send tasks, through one access key. */
export interface CrmConnection {
  /** The access key the CRM authenticates with. */
  keyId: string
  enabled: boolean
  /** Where status changes, comments and delegation requests are posted. */
  eventsUrl: string | null
  /** Signs them, Standard Webhooks style. Generated here, shown to the owner once. */
  eventsSecret: string | null
  statuses: StatusConfig
  /** The CRM identity that means Hoot. */
  hootIdentity: string | null
  /** CRM identity → agent id. Only these, and Hoot, can be assigned work here. */
  identities: Record<string, string>
  /** CRM identities allowed to assign, mention, reply or cancel. Everyone else is refused. */
  allowedSenders: string[]
  /** Project folders work may run in. Anything else is refused. */
  folders: string[]
  /** Agent-to-agent hand-offs on one task tree before it stops and says so. */
  maxHops: number
}

/** A connection as Settings sees it: never the secret itself. */
export type CrmConnectionView = Omit<CrmConnection, 'eventsSecret'> & { hasEventsSecret: boolean }

export class TaskConfigProblem extends Error {}

/* ----------------------------------------------------------------- checks -- */

function text(value: unknown, field: string, max: number): string {
  if (typeof value !== 'string') throw new TaskConfigProblem(`${field} has to be text.`)
  const trimmed = value.trim()
  if (trimmed === '') throw new TaskConfigProblem(`${field} cannot be empty.`)
  if (trimmed.length > max) throw new TaskConfigProblem(`${field} is longer than ${max} characters.`)
  return trimmed
}

function optionalText(value: unknown, field: string, max: number): string | null {
  if (value === undefined || value === null || (typeof value === 'string' && value.trim() === '')) return null
  return text(value, field, max)
}

function whole(value: unknown, field: string, min: number, max: number, fallback: number): number {
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'number' || !Number.isInteger(value) || value < min || value > max) {
    throw new TaskConfigProblem(`${field} has to be a whole number from ${min} to ${max}.`)
  }
  return value
}

function textList(value: unknown, field: string, max: number, maxLength: number): string[] {
  if (value === undefined || value === null) return []
  if (!Array.isArray(value)) throw new TaskConfigProblem(`${field} has to be a list.`)
  const out: string[] = []
  for (const entry of value) {
    const one = text(entry, field, maxLength)
    if (!out.includes(one)) out.push(one)
  }
  if (out.length > max) throw new TaskConfigProblem(`${field} takes at most ${max}.`)
  return out
}

export function cleanAgent(raw: unknown, others: readonly AgentProfile[]): AgentProfile {
  const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
  const id = text(input.id, 'The agent id', 40).toLowerCase()
  if (!/^[a-z0-9][a-z0-9-]*$/.test(id)) {
    throw new TaskConfigProblem('The agent id can only use letters, digits and dashes.')
  }
  const name = text(input.name, 'The agent name', 60)
  if (others.some((other) => other.id !== id && other.name.toLowerCase() === name.toLowerCase())) {
    throw new TaskConfigProblem(`Another agent is already called ${name}.`)
  }
  return {
    id,
    name,
    role: optionalText(input.role, 'The role', 60) ?? 'general',
    provider: optionalText(input.provider, 'The coding agent', 40),
    account: optionalText(input.account, 'The account', 80),
    model: optionalText(input.model, 'The model', 80),
    effort: effortOf(input.effort),
    instructions: optionalText(input.instructions, 'The instructions', MAX_INSTRUCTIONS_CHARS),
    toolsPreferred: textList(input.toolsPreferred, 'Tools to prefer', MAX_TOOL_NAMES, 80),
    toolsAvoided: textList(input.toolsAvoided, 'Tools to avoid', MAX_TOOL_NAMES, 80),
    skills: textList(input.skills, 'The skills', MAX_SKILLS, 80),
    maxConcurrent: whole(input.maxConcurrent, 'Tasks at once', 1, MAX_AGENT_CONCURRENT, 1),
    maxRunMinutes: whole(input.maxRunMinutes, 'Longest run', 0, MAX_MINUTES, DEFAULT_RUN_MINUTES),
    keepAliveMinutes: whole(input.keepAliveMinutes, 'Keep open', 0, MAX_MINUTES, DEFAULT_KEEP_ALIVE_MINUTES),
    verifyCommand: optionalText(input.verifyCommand, 'The check command', 500),
  }
}

function effortOf(value: unknown): string | null {
  const effort = optionalText(value, 'The effort', 20)
  if (effort === null) return null
  if (!EFFORT_LEVELS.some((level) => level.id === effort)) {
    throw new TaskConfigProblem(`The effort has to be one of: ${EFFORT_LEVELS.map((level) => level.id).join(', ')}.`)
  }
  return effort
}

export function cleanStatuses(raw: unknown): StatusConfig {
  if (raw === undefined || raw === null) return { ...DEFAULT_CRM_STATUSES, statuses: [...DEFAULT_CRM_STATUSES.statuses] }
  const input = (typeof raw === 'object' ? raw : {}) as Record<string, unknown>
  const statuses = textList(input.statuses, 'The statuses', MAX_STATUSES, 60)
  if (statuses.length === 0) throw new TaskConfigProblem('Name at least one status.')
  const member = (value: unknown, field: string, nullable: boolean): string | null => {
    if (nullable && (value === undefined || value === null || value === '')) return null
    if (typeof value !== 'string' || !statuses.includes(value)) {
      throw new TaskConfigProblem(`${field} has to be one of: ${statuses.join(', ')}.`)
    }
    return value
  }
  return {
    statuses,
    initial: member(input.initial, 'The initial status', false) as string,
    completed: member(input.completed, 'The completed status', false) as string,
    onStarted: member(input.onStarted, 'The status on start', true),
    onVerified: member(input.onVerified, 'The status on a verified completion', true),
    onBlocked: member(input.onBlocked, 'The status when blocked', true),
  }
}

function cleanFolders(value: unknown): string[] {
  const folders = textList(value, 'The folders', MAX_FOLDERS, 1024)
  for (const folder of folders) {
    if (!isAbsolute(folder)) throw new TaskConfigProblem(`${folder} is not a full folder path.`)
  }
  return folders
}

/* ------------------------------------------------------------------ store -- */

interface StoredFile {
  v: 1
  agents: AgentProfile[]
  connections: CrmConnection[]
}

export interface TaskConfigOptions {
  /** `<userData>/remote`. Null keeps it in memory, for tests. */
  dir: string | null
}

export class TaskConfig {
  private agentsList: AgentProfile[] = []
  private connectionsList: CrmConnection[] = []
  private readonly listeners = new Set<() => void>()

  constructor(private readonly options: TaskConfigOptions) {
    this.load()
  }

  /* ---------------------------------------------------------- agents -- */

  agents(): AgentProfile[] {
    return this.agentsList.map((agent) => ({ ...agent }))
  }

  agent(id: string): AgentProfile | null {
    const found = this.agentsList.find((agent) => agent.id === id)
    return found ? { ...found } : null
  }

  /** By id or by name, ignoring case — how Hoot names one. */
  findAgent(nameOrId: string): AgentProfile | null {
    const wanted = nameOrId.trim().toLowerCase()
    const found = this.agentsList.find((agent) => agent.id === wanted || agent.name.toLowerCase() === wanted)
    return found ? { ...found } : null
  }

  saveAgent(raw: unknown): AgentProfile {
    const agent = cleanAgent(raw, this.agentsList)
    const at = this.agentsList.findIndex((other) => other.id === agent.id)
    if (at < 0 && this.agentsList.length >= MAX_AGENTS) {
      throw new TaskConfigProblem(`There can be at most ${MAX_AGENTS} agents.`)
    }
    if (at < 0) this.agentsList.push(agent)
    else this.agentsList[at] = agent
    this.changed()
    return { ...agent }
  }

  removeAgent(id: string): boolean {
    const before = this.agentsList.length
    this.agentsList = this.agentsList.filter((agent) => agent.id !== id)
    if (this.agentsList.length === before) return false
    // An identity pointing at a removed agent would route work to nobody.
    for (const connection of this.connectionsList) {
      for (const [identity, agentId] of Object.entries(connection.identities)) {
        if (agentId === id) delete connection.identities[identity]
      }
    }
    this.changed()
    return true
  }

  /* ----------------------------------------------------- connections -- */

  connection(keyId: string): CrmConnection | null {
    const found = this.connectionsList.find((connection) => connection.keyId === keyId)
    return found ? structuredClone(found) : null
  }

  connections(): CrmConnectionView[] {
    return this.connectionsList.map(viewOf)
  }

  /**
   * Create or change the connection for one key. A field left out keeps its
   * value; a new one starts off, with nobody allowed and no folders.
   *
   * Returns the signing secret when this call made one, so Settings can show it
   * once; afterwards only `hasEventsSecret` is ever shown.
   */
  saveConnection(keyId: string, raw: unknown): { view: CrmConnectionView; secret: string | null } {
    if (typeof keyId !== 'string' || keyId === '') throw new TaskConfigProblem('Choose an access key first.')
    const input = (typeof raw === 'object' && raw !== null ? raw : {}) as Record<string, unknown>
    const existing = this.connectionsList.find((connection) => connection.keyId === keyId)
    const base: CrmConnection = existing
      ? structuredClone(existing)
      : {
          keyId,
          enabled: false,
          eventsUrl: null,
          eventsSecret: null,
          statuses: cleanStatuses(undefined),
          hootIdentity: null,
          identities: {},
          allowedSenders: [],
          folders: [],
          maxHops: DEFAULT_MAX_HOPS,
        }
    if ('enabled' in input) base.enabled = input.enabled === true
    if ('eventsUrl' in input) {
      const url = optionalText(input.eventsUrl, 'The events address', 2048)
      if (url !== null) {
        const problem = webhookUrlProblem(url)
        if (problem !== null) throw new TaskConfigProblem(problem)
      }
      base.eventsUrl = url
    }
    if ('statuses' in input) base.statuses = cleanStatuses(input.statuses)
    if ('hootIdentity' in input) base.hootIdentity = optionalText(input.hootIdentity, 'The Hoot identity', 200)
    if ('identities' in input) {
      const map = (typeof input.identities === 'object' && input.identities !== null ? input.identities : {}) as Record<
        string,
        unknown
      >
      const identities: Record<string, string> = {}
      for (const [identity, agentId] of Object.entries(map)) {
        const id = text(identity, 'A CRM identity', 200)
        const agent = typeof agentId === 'string' ? this.agentsList.find((one) => one.id === agentId) : undefined
        if (!agent) throw new TaskConfigProblem(`${id} points at an agent that does not exist.`)
        identities[id] = agent.id
      }
      base.identities = identities
    }
    if ('allowedSenders' in input) base.allowedSenders = textList(input.allowedSenders, 'The allowed senders', MAX_SENDERS, 200)
    if ('folders' in input) base.folders = cleanFolders(input.folders)
    if ('maxHops' in input) base.maxHops = whole(input.maxHops, 'Hand-offs', 1, MAX_HOPS, DEFAULT_MAX_HOPS)
    if (base.hootIdentity !== null && base.hootIdentity in base.identities) {
      throw new TaskConfigProblem('The Hoot identity cannot also be an agent’s identity.')
    }
    let secret: string | null = null
    if (base.eventsSecret === null || input.rotateSecret === true) {
      secret = newWebhookSecret()
      base.eventsSecret = secret
    }
    if (existing) Object.assign(existing, base)
    else this.connectionsList.push(base)
    this.changed()
    return { view: viewOf(base), secret }
  }

  removeConnection(keyId: string): boolean {
    const before = this.connectionsList.length
    this.connectionsList = this.connectionsList.filter((connection) => connection.keyId !== keyId)
    if (this.connectionsList.length === before) return false
    this.changed()
    return true
  }

  onChange(listener: () => void): () => void {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  /* --------------------------------------------------------- keeping -- */

  private changed(): void {
    this.flush()
    for (const listener of [...this.listeners]) {
      try {
        listener()
      } catch (error) {
        console.error('[tasks] a config listener threw:', error)
      }
    }
  }

  private file(): string | null {
    return this.options.dir === null ? null : join(this.options.dir, TASK_CONFIG_FILE)
  }

  private flush(): void {
    const file = this.file()
    if (file === null || this.options.dir === null) return
    const state: StoredFile = { v: 1, agents: this.agentsList, connections: this.connectionsList }
    writeSecretFile(this.options.dir, file, `${JSON.stringify(state)}\n`)
  }

  private load(): void {
    const file = this.file()
    if (file === null || !existsSync(file)) return
    try {
      const raw = JSON.parse(readFileSync(file, 'utf8')) as Partial<StoredFile>
      if (raw.v !== 1) return
      const agents: AgentProfile[] = []
      for (const entry of Array.isArray(raw.agents) ? raw.agents : []) {
        try {
          agents.push(cleanAgent(entry, agents))
        } catch (error) {
          console.error('[tasks] skipped an agent that no longer reads:', error)
        }
      }
      this.agentsList = agents
      this.connectionsList = (Array.isArray(raw.connections) ? raw.connections : []).filter(isConnection)
    } catch (error) {
      console.error('[tasks] could not read the task settings; starting empty:', error)
    }
  }
}

function viewOf(connection: CrmConnection): CrmConnectionView {
  const { eventsSecret, ...rest } = structuredClone(connection)
  return { ...rest, hasEventsSecret: eventsSecret !== null }
}

function isConnection(value: unknown): value is CrmConnection {
  if (typeof value !== 'object' || value === null) return false
  const entry = value as Partial<CrmConnection>
  return (
    typeof entry.keyId === 'string' &&
    typeof entry.enabled === 'boolean' &&
    typeof entry.statuses === 'object' &&
    entry.statuses !== null &&
    Array.isArray(entry.statuses.statuses) &&
    typeof entry.identities === 'object' &&
    entry.identities !== null &&
    Array.isArray(entry.allowedSenders) &&
    Array.isArray(entry.folders) &&
    typeof entry.maxHops === 'number'
  )
}

/** Is this folder inside one the connection allows? Exact or nested, never a sibling with a shared prefix. */
export function folderAllowed(connection: Pick<CrmConnection, 'folders'>, folder: string): boolean {
  if (!isAbsolute(folder)) return false
  // Resolved first, so `allowed/../elsewhere` is judged as where it really goes.
  const wanted = resolve(folder)
  return connection.folders.some((allowed) => {
    const base = resolve(allowed)
    return wanted === base || wanted.startsWith(`${base}/`)
  })
}
