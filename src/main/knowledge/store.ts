/**
 * Project knowledge on disk: one folder per project, one markdown file per
 * record, and nothing else that a record depends on.
 *
 * The layout is the shared one in `shared/agent-stack.ts` — `<userData>/knowledge/
 * <projectKey>/` holding `project.json` and `<id>.md` — because the memory view
 * reads these files like any other memory note and this module is their only
 * writer. A record file is flat front matter (the copilot's own reader,
 * `parseFrontMatter`, never a YAML parser) and the statement as its body, so a
 * person opening one in an editor reads the claim before anything else.
 *
 * ## Nothing disappears without a line saying why
 *
 * Superseding rewrites the old file with `status: superseded` and leaves it where
 * it is; the replacement names it in `supersedes`. Deleting is a separate,
 * explicit act that needs a reason, and the whole record goes into the project's
 * `log.jsonl` before the file is removed — so "who took that out, and what did
 * it say" always has an answer. The log is beside the records rather than in a
 * shared place for the same reason the records are: a project's folder is its
 * isolation boundary.
 *
 * ## Isolation, and the one way across it
 *
 * Every call names a project, and the project is reduced to its real path before
 * anything is read, so two spellings of one folder are one project and a folder
 * that only *looks* like another is not. Crossing between projects is a list in
 * `shares.json` and nothing else; a missing or unreadable list means nothing
 * crosses. This module writes that list only when told to — whether it may is
 * asked of a consent function one layer up (`book.ts`).
 */

import { createHash, randomBytes } from 'node:crypto'
import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, unlinkSync } from 'node:fs'
import { basename, isAbsolute, join, relative, resolve } from 'node:path'
import {
  KNOWLEDGE_DIR,
  KNOWLEDGE_KEYS,
  KNOWLEDGE_PROJECT_FILE,
  KNOWLEDGE_SHARES_FILE,
  type KnowledgeKind,
  type KnowledgeProvenance,
  type KnowledgeRecord,
  type KnowledgeSource,
  type StoredKnowledgeStatus,
} from '../../shared/agent-stack'
import { writeFileAtomic } from '../atomic-write'
import { parseNote } from '../memory/note'

/** The append-only change log in each project's folder: supersedes, deletes, shares. */
export const KNOWLEDGE_LOG_FILE = 'log.jsonl'

export const KNOWLEDGE_KINDS: readonly KnowledgeKind[] = ['goal', 'architecture', 'decision', 'constraint', 'task-history', 'result']
export const STORED_STATUSES: readonly StoredKnowledgeStatus[] = ['claim', 'verified', 'superseded']
export const KNOWLEDGE_SOURCES: readonly KnowledgeSource[] = ['owner', 'hoot', 'worker', 'task', 'review']

/**
 * Bounds on what one record may hold. A record is a fact a brief carries, not a
 * document: a statement past a few thousand characters is a report, and belongs
 * in a file the record names as evidence.
 */
export const MAX_SUBJECT_CHARS = 120
export const MAX_STATEMENT_CHARS = 4000
export const MAX_EVIDENCE_ITEMS = 20
export const MAX_EVIDENCE_CHARS = 300

export const DAY_MS = 86_400_000

const ID = /^[A-Za-z0-9][A-Za-z0-9-]{0,63}$/

/** A thing a caller asked for that cannot be done, in a sentence it can act on. */
export class KnowledgeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'KnowledgeError'
  }
}

/* ------------------------------------------------------------ projects -- */

/**
 * The path a project is known by: its real path, or — for a folder that is not
 * there any more — the resolved spelling, so its records stay readable.
 *
 * Absolute only. A relative project would resolve against whatever this
 * process's working folder happens to be, which is a different project on every
 * launch.
 */
export function realProject(project: string): string {
  if (typeof project !== 'string' || project.trim() === '' || !isAbsolute(project)) {
    throw new KnowledgeError(`a project is named by its absolute folder path, not ${JSON.stringify(project)}`)
  }
  const resolved = resolve(project)
  try {
    return realpathSync(resolved)
  } catch {
    return resolved
  }
}

/** The first 16 hex characters of the SHA-256 of the project's real path. */
export function projectKey(real: string): string {
  return createHash('sha256').update(real).digest('hex').slice(0, 16)
}

/* ------------------------------------------------------- one record file -- */

/** Whitespace collapsed to one line, cut at `max` with an ellipsis. */
export function oneLine(text: string, max: number): string {
  const flat = text.replace(/\s+/g, ' ').trim()
  return flat.length > max ? `${flat.slice(0, max - 1).trimEnd()}…` : flat
}

/**
 * A front matter value as written. `parseFrontMatter` strips one pair of
 * surrounding quotes, so a value that starts and ends with one is given an
 * extra pair — and reads back exactly as it was.
 */
function frontValue(value: string): string {
  const flat = oneLine(value, 4000)
  return /^["'].*["']$/.test(flat) ? `"${flat}"` : flat
}

/**
 * Evidence as stored: one line each, no commas (the list is comma-separated on
 * disk), and a path inside the project written relative to it — so the record
 * still names the right file whichever spelling of the folder wrote it.
 */
export function cleanEvidence(items: readonly string[] | undefined, roots: readonly string[]): string[] {
  const out: string[] = []
  for (const raw of items ?? []) {
    if (typeof raw !== 'string') continue
    let item = oneLine(raw, MAX_EVIDENCE_CHARS).replace(/,/g, ';')
    if (isAbsolute(item)) {
      for (const root of roots) {
        const rel = relative(root, item)
        if (rel !== '' && !rel.startsWith('..') && !isAbsolute(rel)) {
          item = rel
          break
        }
      }
    }
    if (item !== '' && !out.includes(item)) out.push(item)
    if (out.length === MAX_EVIDENCE_ITEMS) break
  }
  return out
}

function iso(ms: number | undefined): string | undefined {
  return ms === undefined || !Number.isFinite(ms) ? undefined : new Date(ms).toISOString()
}

/** The file's text: flat front matter in `KNOWLEDGE_KEYS` order, then the statement. */
export function serializeRecord(record: KnowledgeRecord): string {
  const p = record.provenance
  const values: Record<(typeof KNOWLEDGE_KEYS)[number], string | undefined> = {
    id: record.id,
    kind: record.kind,
    subject: record.subject,
    status: record.status,
    source: p.source,
    task: p.taskId,
    goal: p.goalId,
    agent: p.agentId,
    session: p.sessionId,
    conversation: p.conversationId,
    evidence: p.evidence && p.evidence.length > 0 ? p.evidence.join(', ') : undefined,
    created: iso(record.createdAt),
    verified: iso(record.verifiedAt),
    'stale-after-days': record.staleAfterMs === undefined ? undefined : String(record.staleAfterMs / DAY_MS),
    supersedes: record.supersedes,
  }
  const lines = ['---']
  for (const key of KNOWLEDGE_KEYS) {
    const value = values[key]
    // `parseFrontMatter` drops an empty value, so one is never written.
    if (value !== undefined && value.trim() !== '') lines.push(`${key}: ${frontValue(value)}`)
  }
  lines.push('---', '', record.statement.trim(), '')
  return lines.join('\n')
}

function pick<T extends string>(value: string | undefined, allowed: readonly T[]): T | null {
  return value !== undefined && (allowed as readonly string[]).includes(value) ? (value as T) : null
}

function time(value: string | undefined): number | undefined {
  if (value === undefined) return undefined
  const ms = Date.parse(value)
  return Number.isFinite(ms) ? ms : undefined
}

/**
 * A record file read back, or null when it is not one.
 *
 * The file name is the id — `get` opens `<id>.md` — so a front matter `id` that
 * disagrees with it loses. A file missing its kind, status, source or creation
 * time is not guessed at: it is left out, and the memory view still shows it as
 * the note it is.
 */
export function parseRecord(text: string, file: string, project: string): KnowledgeRecord | null {
  const note = parseNote(text, file)
  const data = note.data
  const id = basename(file).replace(/\.md$/i, '')
  const kind = pick(data.kind, KNOWLEDGE_KINDS)
  const status = pick(data.status, STORED_STATUSES)
  const source = pick(data.source, KNOWLEDGE_SOURCES)
  const createdAt = time(data.created)
  if (!ID.test(id) || kind === null || status === null || source === null || createdAt === undefined || !data.subject) return null
  const provenance: KnowledgeProvenance = { source }
  if (data.task) provenance.taskId = data.task
  if (data.goal) provenance.goalId = data.goal
  if (data.agent) provenance.agentId = data.agent
  if (data.session) provenance.sessionId = data.session
  if (data.conversation) provenance.conversationId = data.conversation
  if (data.evidence) {
    const evidence = data.evidence
      .split(',')
      .map((item) => item.trim())
      .filter((item) => item !== '')
    if (evidence.length > 0) provenance.evidence = evidence
  }
  const record: KnowledgeRecord = {
    id,
    project,
    kind,
    subject: data.subject,
    statement: note.body.trim(),
    status,
    provenance,
    createdAt,
  }
  const verifiedAt = time(data.verified)
  if (verifiedAt !== undefined) record.verifiedAt = verifiedAt
  const days = data['stale-after-days'] === undefined ? Number.NaN : Number(data['stale-after-days'])
  if (Number.isFinite(days) && days > 0) record.staleAfterMs = Math.round(days * DAY_MS)
  if (data.supersedes && ID.test(data.supersedes)) record.supersedes = data.supersedes
  return record
}

/* ---------------------------------------------------------------- the log -- */

export interface KnowledgeLogEntry {
  at: number
  action: 'supersede' | 'delete' | 'share' | 'unshare'
  /** The record acted on, for a supersede or a delete. */
  id?: string
  reason: string
  by: KnowledgeProvenance
  /** The record that replaced it, when one did. */
  replacement?: string
  /** A deleted record's whole file, so a delete is never the end of what it said. */
  record?: string
  /** The other project, for a share. */
  project?: string
}

/* ------------------------------------------------------------- the store -- */

export interface ShareEntry {
  /** Whose records may be read. */
  from: string
  /** The project that may read them. */
  to: string
  at: number
}

export interface KnowledgeStoreOptions {
  userData: string
  /** Mints a record id. Random by default; a test may fix it. */
  newId?: () => string
}

function randomId(): string {
  return `k${randomBytes(5).toString('hex')}`
}

/**
 * The disk, and only the disk: paths, files, the log and the share list.
 *
 * No rules about who may write what live here — a claim, a verification and a
 * supersede are all just files at this level. `book.ts` is where those rules
 * are, and it is the only thing handed to anything outside this folder.
 */
export class KnowledgeStore {
  private readonly root: string
  private readonly newId: () => string

  constructor(options: KnowledgeStoreOptions) {
    this.root = join(options.userData, KNOWLEDGE_DIR)
    this.newId = options.newId ?? randomId
  }

  /** `<userData>/knowledge/<projectKey>` for a project's real path. */
  dirOf(real: string): string {
    return join(this.root, projectKey(real))
  }

  /** An id no record in this project has yet. */
  freshId(real: string): string {
    for (let i = 0; i < 20; i++) {
      const id = this.newId()
      if (!ID.test(id)) throw new KnowledgeError(`${id} is not a usable record id`)
      if (!existsSync(join(this.dirOf(real), `${id}.md`))) return id
    }
    throw new KnowledgeError('could not find an unused record id')
  }

  /** Every record in one project's folder, in file-name order. Unreadable files are left out. */
  records(real: string): KnowledgeRecord[] {
    const dir = this.dirOf(real)
    let names: string[]
    try {
      names = readdirSync(dir)
    } catch {
      return []
    }
    const out: KnowledgeRecord[] = []
    for (const name of names.filter((one) => one.endsWith('.md')).sort()) {
      try {
        const record = parseRecord(readFileSync(join(dir, name), 'utf8'), name, real)
        if (record !== null) out.push(record)
      } catch {
        /* gone between the listing and the read, or not text */
      }
    }
    return out
  }

  read(real: string, id: string): KnowledgeRecord | null {
    if (!ID.test(id)) return null
    try {
      return parseRecord(readFileSync(join(this.dirOf(real), `${id}.md`), 'utf8'), `${id}.md`, real)
    } catch {
      return null
    }
  }

  /** Write one record, atomically, creating the project's folder and `project.json` on first use. */
  write(record: KnowledgeRecord): void {
    if (!ID.test(record.id)) throw new KnowledgeError(`${record.id} is not a usable record id`)
    const dir = this.dirOf(record.project)
    mkdirSync(dir, { recursive: true })
    const marker = join(dir, KNOWLEDGE_PROJECT_FILE)
    if (!existsSync(marker)) writeFileAtomic(marker, `${JSON.stringify({ project: record.project }, null, 2)}\n`)
    writeFileAtomic(join(dir, `${record.id}.md`), serializeRecord(record))
  }

  /** Remove a record's file. Only `book.ts`'s delete calls this, after logging the whole record. */
  unlink(real: string, id: string): void {
    if (!ID.test(id)) return
    unlinkSync(join(this.dirOf(real), `${id}.md`))
  }

  /** The record file's text as it is on disk, for the log entry a delete leaves. */
  rawText(real: string, id: string): string | null {
    if (!ID.test(id)) return null
    try {
      return readFileSync(join(this.dirOf(real), `${id}.md`), 'utf8')
    } catch {
      return null
    }
  }

  appendLog(real: string, entry: KnowledgeLogEntry): void {
    const dir = this.dirOf(real)
    mkdirSync(dir, { recursive: true })
    appendFileSync(join(dir, KNOWLEDGE_LOG_FILE), `${JSON.stringify(entry)}\n`, 'utf8')
  }

  log(real: string): KnowledgeLogEntry[] {
    let text: string
    try {
      text = readFileSync(join(this.dirOf(real), KNOWLEDGE_LOG_FILE), 'utf8')
    } catch {
      return []
    }
    const out: KnowledgeLogEntry[] = []
    for (const line of text.split('\n')) {
      if (line.trim() === '') continue
      try {
        out.push(JSON.parse(line) as KnowledgeLogEntry)
      } catch {
        /* a torn last line from a crash mid-append */
      }
    }
    return out
  }

  /** The share list. Missing or unreadable reads as empty: nothing crosses. */
  shares(): ShareEntry[] {
    try {
      const parsed = JSON.parse(readFileSync(join(this.root, KNOWLEDGE_SHARES_FILE), 'utf8')) as { shares?: unknown }
      if (!Array.isArray(parsed.shares)) return []
      return parsed.shares.filter(
        (entry): entry is ShareEntry =>
          typeof entry === 'object' &&
          entry !== null &&
          typeof (entry as ShareEntry).from === 'string' &&
          typeof (entry as ShareEntry).to === 'string' &&
          typeof (entry as ShareEntry).at === 'number',
      )
    } catch {
      return []
    }
  }

  writeShares(shares: readonly ShareEntry[]): void {
    mkdirSync(this.root, { recursive: true })
    writeFileAtomic(join(this.root, KNOWLEDGE_SHARES_FILE), `${JSON.stringify({ shares }, null, 2)}\n`)
  }
}
