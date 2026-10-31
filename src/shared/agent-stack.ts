/**
 * The shapes the agent stack's parts agree on: goals, project knowledge, memory
 * spaces, task workspaces and the seams the task engine is handed.
 *
 * Types only. Each part owns its own store and logic; this file is where two
 * parts that meet — the task engine and the knowledge it carries into a brief,
 * the memory view and the knowledge it shows — read the same definition.
 */

/* ------------------------------------------------------------------ goals -- */

export type GoalStatus = 'planned' | 'active' | 'achieved' | 'cancelled'

export interface Goal {
  id: string
  title: string
  description: string
  status: GoalStatus
  /** The goal this one serves, or null for a top-level goal. */
  parentId: string | null
  /** The project folder it belongs to, or null for one that spans projects. */
  project: string | null
  createdAt: number
  updatedAt: number
}

/* -------------------------------------------------------------- knowledge -- */

/**
 * What a project knowledge record is about.
 *
 * `task-history` and `result` are written by the task flow itself; the rest by
 * Hoot, a worker, or the owner.
 */
export type KnowledgeKind =
  | 'goal'
  | 'architecture'
  | 'decision'
  | 'constraint'
  | 'task-history'
  | 'result'

/**
 * What is stored on a record. `verified` is set only by a review that names its
 * evidence; everything an agent writes on its own arrives as a `claim`.
 */
export type StoredKnowledgeStatus = 'claim' | 'verified' | 'superseded'

/**
 * What a reader is told. `stale` and `conflicting` are worked out when the
 * record is read — from its age, its evidence files and its neighbours — and are
 * never written down, so they cannot go out of date themselves.
 */
export type KnowledgeStatus = StoredKnowledgeStatus | 'stale' | 'conflicting'

export type KnowledgeSource = 'owner' | 'hoot' | 'worker' | 'task' | 'review'

export interface KnowledgeProvenance {
  source: KnowledgeSource
  taskId?: string
  goalId?: string
  /** The task agent's id, when a worker wrote it. */
  agentId?: string
  /** The app session that wrote it. */
  sessionId?: string
  /** The CLI's own conversation id, when known. */
  conversationId?: string
  /** Files, commands or URLs the statement rests on. */
  evidence?: string[]
}

export interface KnowledgeRecord {
  id: string
  /** The project folder it belongs to — the isolation boundary. */
  project: string
  kind: KnowledgeKind
  /** A short stable key; two live records with one subject and different statements conflict. */
  subject: string
  statement: string
  status: StoredKnowledgeStatus
  provenance: KnowledgeProvenance
  createdAt: number
  verifiedAt?: number
  /** Older than this since `verifiedAt` (or `createdAt`) reads as stale. */
  staleAfterMs?: number
  /** The record this one replaces. */
  supersedes?: string
}

/** A record as a reader gets it: with its worked-out status and why. */
export interface KnowledgeView extends KnowledgeRecord {
  effective: KnowledgeStatus
  /** Plain reasons for `stale` / `conflicting`, empty otherwise. */
  notes: string[]
}

/* ------------------------------------------------------------ memory -- */

/**
 * Whose memory a space is.
 *
 *  - `claude-project`: Claude Code's own `<store>/projects/<encoded folder>/memory/`.
 *  - `codex`: Codex's `$CODEX_HOME/memories/`.
 *  - `hoot`: the copilot's `memory/` folder.
 *  - `knowledge`: this app's project knowledge records, one space per project.
 */
export type MemorySpaceKind = 'claude-project' | 'codex' | 'hoot' | 'knowledge'

export interface MemorySpace {
  id: string
  kind: MemorySpaceKind
  label: string
  /** The folder on disk, real path. */
  root: string
  /** The project folder it serves, when it serves one. */
  project: string | null
  /** The account store it was found under, when there is one. */
  store: string | null
  /**
   * Other project folders whose memory resolves to this same folder on disk.
   * Shown as it is found; this app never creates or removes such a link on its own.
   */
  sharedWith: string[]
}

export interface MemoryNote {
  spaceId: string
  /** Path relative to the space root. */
  path: string
  title: string
  /** Front matter `name`, when there is one — what `[[links]]` resolve against. */
  name: string | null
  description: string | null
  type: string | null
  /** Link targets as written, without `|alias` or `#heading`. */
  links: string[]
  modifiedAt: number
  bytes: number
}

export interface MemorySearchHit {
  spaceId: string
  path: string
  title: string
  score: number
  snippet: string
}

/* ------------------------------------------------------------ workspaces -- */

export type TaskWorkspaceState = 'active' | 'kept' | 'removed'

export interface TaskWorkspace {
  taskId: string
  /** The repository it was made from. */
  repo: string
  /** The working folder made for the task. */
  path: string
  branch: string
  createdAt: number
  state: TaskWorkspaceState
}

/* --------------------------------------------- seams handed to the engine -- */

/** Event the task flow reports so durable knowledge can be kept. */
export interface TaskKnowledgeEvent {
  kind: 'delegated' | 'finished' | 'verified' | 'rejected' | 'reassigned' | 'stalled'
  project: string
  taskId: string
  title: string
  goalId?: string
  agentId?: string
  sessionId?: string
  /** What was claimed (finished) or found (verified/rejected). */
  summary?: string
  evidence?: string[]
  at: number
}

/** Knowledge the task engine pulls into a worker brief or a planning answer. */
export interface KnowledgeForBrief {
  /** Ready-to-include markdown, empty when there is nothing relevant. */
  text: string
  records: KnowledgeView[]
}

export interface KnowledgeProvider {
  forBrief(input: { project: string; query: string; goalId?: string; limit?: number }): Promise<KnowledgeForBrief>
  noteTaskEvent(event: TaskKnowledgeEvent): Promise<void>
}

export interface WorkspaceProvider {
  /** The folder a task should run in: its own workspace when it has one, else null for the project folder. */
  folderFor(task: { id: string; project: string; useWorkspace: boolean }): Promise<string | null>
}

/* ------------------------------------------------- knowledge on disk -- */

/**
 * Where project knowledge lives: `<userData>/knowledge/<projectKey>/`, one
 * folder per project — the isolation boundary — holding `project.json`
 * (`{ "project": "<folder>" }`) and one markdown file per record, `<id>.md`.
 * `projectKey` is the first 16 hex characters of the SHA-256 of the project's
 * real path. Explicit sharing between projects is a list kept beside them in
 * `<userData>/knowledge/shares.json`; with no entry, nothing crosses.
 *
 * A record file is flat front matter (the keys below, `evidence` as a
 * comma-separated list) and the statement as its body. The memory view reads
 * these files like any other memory note; the knowledge store is their writer.
 */
export const KNOWLEDGE_DIR = 'knowledge'
export const KNOWLEDGE_SHARES_FILE = 'shares.json'
export const KNOWLEDGE_PROJECT_FILE = 'project.json'
export const KNOWLEDGE_KEYS = [
  'id',
  'kind',
  'subject',
  'status',
  'source',
  'task',
  'goal',
  'agent',
  'session',
  'conversation',
  'evidence',
  'created',
  'verified',
  'stale-after-days',
  'supersedes',
] as const
