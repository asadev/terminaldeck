/**
 * The rules over the store: who may write what, what superseding keeps, and
 * when one project may read another's records.
 *
 * ## Only a review makes anything verified
 *
 * {@link KnowledgeBook.record} and {@link KnowledgeBook.supersede} write claims,
 * whatever they are handed — there is no argument that makes them write
 * `verified`. The one path that does is {@link KnowledgeBook.commit}, which the
 * task flow's review uses (`ingest.ts`) and which `index.ts` does not hand to
 * anybody: the tools, Hoot's and a worker's, are given the claim-writing half
 * only. A worker that says "verified" in its statement has written a claim that
 * says "verified".
 *
 * ## Sharing is asked, never assumed
 *
 * {@link KnowledgeBook.share} goes through the consent function the app hands
 * in, and the default answers no. Nothing here shares at construction, at
 * startup, or as a side effect of anything else; taking a share away needs no
 * question, because it only ever narrows.
 */

import { isAbsolute, resolve } from 'node:path'
import type { KnowledgeKind, KnowledgeProvenance, KnowledgeRecord, KnowledgeView } from '../../shared/agent-stack'
import { fileMtime, viewsOf, type StatusContext } from './status'
import {
  cleanEvidence,
  KNOWLEDGE_KINDS,
  KNOWLEDGE_SOURCES,
  KnowledgeError,
  KnowledgeStore,
  MAX_STATEMENT_CHARS,
  MAX_SUBJECT_CHARS,
  oneLine,
  realProject,
  type KnowledgeLogEntry,
} from './store'

/** Longest reason a supersede, delete or unshare keeps. */
export const MAX_REASON_CHARS = 500

/** One request to let `to` read `from`'s records, put to whoever decides. */
export interface ShareRequest {
  /** Whose records, by real path. */
  from: string
  /** The project that would read them, by real path. */
  to: string
  /** How many records `from` holds right now. */
  records: number
}

/** Says yes or no to a share. The app's own; a test's fake. Absent means no. */
export type KnowledgeConsent = (request: ShareRequest) => Promise<boolean>

export interface ClaimInput {
  kind: KnowledgeKind
  subject: string
  statement: string
  provenance: KnowledgeProvenance
  staleAfterMs?: number
}

export interface SupersedeInput {
  /** Why — required, and kept in the project's log. */
  reason: string
  /** Who is superseding it. */
  by: KnowledgeProvenance
  /** What replaces it, written as a claim. Absent: it is withdrawn with nothing in its place. */
  replacement?: {
    statement: string
    subject?: string
    kind?: KnowledgeKind
    evidence?: string[]
    staleAfterMs?: number
  }
}

export interface ListOptions {
  /** Include records of projects explicitly shared with this one. */
  shared?: boolean
  /** Include superseded records — the history. */
  superseded?: boolean
}

export interface KnowledgeBookOptions {
  userData: string
  now?: () => number
  consent?: KnowledgeConsent
  statMtime?: (path: string) => number | null
  newId?: () => string
}

const refuseAll: KnowledgeConsent = async () => false

function text(value: unknown, what: string, max: number): string {
  if (typeof value !== 'string' || value.trim() === '') throw new KnowledgeError(`${what} is required`)
  if (value.trim().length > max) {
    throw new KnowledgeError(`${what} is ${value.trim().length} characters; at most ${max} — put the rest in a file and name it as evidence`)
  }
  return value.trim()
}

function reasonOf(value: unknown): string {
  if (typeof value !== 'string' || value.trim() === '') throw new KnowledgeError('a reason is required, and is kept in the project’s log')
  return oneLine(value, MAX_REASON_CHARS)
}

function staleAfter(value: unknown): number | undefined {
  if (value === undefined || value === null) return undefined
  if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) throw new KnowledgeError('staleAfterMs must be a positive number')
  return Math.round(value)
}

/** Provenance as stored: a known source, one-line ids, evidence relative to the project. */
function cleanProvenance(provenance: KnowledgeProvenance, roots: readonly string[]): KnowledgeProvenance {
  if (!KNOWLEDGE_SOURCES.includes(provenance.source)) throw new KnowledgeError(`${String(provenance.source)} is not a knowledge source`)
  const out: KnowledgeProvenance = { source: provenance.source }
  const id = (value: string | undefined): string | undefined => {
    const flat = typeof value === 'string' ? oneLine(value, 200) : ''
    return flat === '' ? undefined : flat
  }
  const taskId = id(provenance.taskId)
  const goalId = id(provenance.goalId)
  const agentId = id(provenance.agentId)
  const sessionId = id(provenance.sessionId)
  const conversationId = id(provenance.conversationId)
  if (taskId) out.taskId = taskId
  if (goalId) out.goalId = goalId
  if (agentId) out.agentId = agentId
  if (sessionId) out.sessionId = sessionId
  if (conversationId) out.conversationId = conversationId
  const evidence = cleanEvidence(provenance.evidence, roots)
  if (evidence.length > 0) out.evidence = evidence
  return out
}

function newestFirst(a: KnowledgeRecord, b: KnowledgeRecord): number {
  return b.createdAt - a.createdAt || a.id.localeCompare(b.id)
}

export class KnowledgeBook {
  readonly store: KnowledgeStore
  readonly now: () => number
  private readonly consent: KnowledgeConsent
  private readonly statMtime: (path: string) => number | null

  constructor(options: KnowledgeBookOptions) {
    this.store = new KnowledgeStore({ userData: options.userData, ...(options.newId ? { newId: options.newId } : {}) })
    this.now = options.now ?? Date.now
    this.consent = options.consent ?? refuseAll
    this.statMtime = options.statMtime ?? fileMtime
  }

  private context(): StatusContext {
    return { now: this.now(), statMtime: this.statMtime }
  }

  /** The real path of a project, which every call reduces its argument to first. */
  projectOf(project: string): string {
    return realProject(project)
  }

  /** Projects whose records `project` may read, by real path. */
  sharedInto(project: string): string[] {
    const real = realProject(project)
    return [...new Set(this.store.shares().filter((share) => share.to === real && share.from !== real).map((share) => share.from))]
  }

  /** Projects that may read `project`'s records, by real path. */
  sharedOut(project: string): string[] {
    const real = realProject(project)
    return [...new Set(this.store.shares().filter((share) => share.from === real && share.to !== real).map((share) => share.to))]
  }

  /** One project's own records as views, newest first. */
  ownViews(real: string): KnowledgeView[] {
    return viewsOf(this.store.records(real).sort(newestFirst), this.context())
  }

  /**
   * The records a project may read: its own, and — with `shared` — those of the
   * projects explicitly shared with it. Each view keeps its own `project`, so a
   * reader always knows whose a record is.
   */
  list(project: string, options: ListOptions = {}): KnowledgeView[] {
    const real = realProject(project)
    const views = this.ownViews(real)
    if (options.shared === true) for (const from of this.sharedInto(real)) views.push(...this.ownViews(from))
    return options.superseded === true ? views : views.filter((view) => view.effective !== 'superseded')
  }

  /** One record this project may read — its own, or one shared with it — or null. */
  get(project: string, id: string): KnowledgeView | null {
    const real = realProject(project)
    for (const owner of [real, ...this.sharedInto(real)]) {
      const found = this.ownViews(owner).find((view) => view.id === id)
      if (found !== undefined) return found
    }
    return null
  }

  /** The records `id` replaced, newest first: what was believed before, and before that. */
  history(project: string, id: string): KnowledgeView[] {
    const start = this.get(project, id)
    if (start === null) return []
    const all = new Map(this.ownViews(start.project).map((view) => [view.id, view]))
    const chain: KnowledgeView[] = []
    let next = start.supersedes
    while (next !== undefined && chain.length < 50) {
      const view = all.get(next)
      if (view === undefined || chain.includes(view)) break
      chain.push(view)
      next = view.supersedes
    }
    return chain
  }

  /** The live record that replaced `id`, when one did. */
  supersededBy(project: string, id: string): string | null {
    const real = realProject(project)
    return this.store.records(real).find((record) => record.supersedes === id)?.id ?? null
  }

  /** Write a claim. Never anything else: see the header. */
  record(project: string, input: ClaimInput): KnowledgeView {
    const real = realProject(project)
    const next = this.claim(project, real, input)
    this.commit(real, next)
    return this.viewOf(next)
  }

  /**
   * Replace a record of this project — with a claim, or with nothing — keeping
   * the old one on disk as `superseded` and the reason in the log.
   */
  supersede(project: string, id: string, input: SupersedeInput): { superseded: KnowledgeView; replacement: KnowledgeView | null } {
    const real = realProject(project)
    const reason = reasonOf(input.reason)
    const old = this.store.read(real, id)
    if (old === null) throw new KnowledgeError(`there is no record ${id} in this project’s knowledge`)
    if (old.status === 'superseded') {
      const by = this.supersededBy(real, id)
      throw new KnowledgeError(`${id} is already superseded${by === null ? '' : ` by ${by}`}`)
    }
    const replacement = input.replacement
    const next =
      replacement === undefined
        ? null
        : {
            ...this.claim(project, real, {
              kind: replacement.kind ?? old.kind,
              subject: replacement.subject ?? old.subject,
              statement: replacement.statement,
              provenance: { ...input.by, evidence: replacement.evidence },
              ...(replacement.staleAfterMs !== undefined
                ? { staleAfterMs: replacement.staleAfterMs }
                : old.staleAfterMs !== undefined
                  ? { staleAfterMs: old.staleAfterMs }
                  : {}),
            }),
            supersedes: id,
          }
    this.commit(real, next, { id, reason, by: input.by })
    const superseded = this.store.read(real, id) as KnowledgeRecord
    return { superseded: this.viewOf(superseded), replacement: next === null ? null : this.viewOf(next) }
  }

  /**
   * The one way a record leaves: on purpose, with a reason, and with the whole
   * record copied into the log first.
   */
  remove(project: string, id: string, input: { reason: string; by: KnowledgeProvenance }): void {
    const real = realProject(project)
    const reason = reasonOf(input.reason)
    const raw = this.store.rawText(real, id)
    if (raw === null || this.store.read(real, id) === null) throw new KnowledgeError(`there is no record ${id} in this project’s knowledge`)
    this.store.appendLog(real, { at: this.now(), action: 'delete', id, reason, by: input.by, record: raw })
    this.store.unlink(real, id)
  }

  /**
   * Let `to` read `from`'s records — if, and only if, the consent function says
   * yes. Answers whether `to` can read them now.
   */
  async share(from: string, to: string, by: KnowledgeProvenance = { source: 'owner' }): Promise<boolean> {
    const realFrom = realProject(from)
    const realTo = realProject(to)
    if (realFrom === realTo) throw new KnowledgeError('a project already reads its own knowledge')
    if (this.sharedOut(realFrom).includes(realTo)) return true
    const yes = await this.consent({ from: realFrom, to: realTo, records: this.store.records(realFrom).length })
    if (yes !== true) return false
    const at = this.now()
    this.store.writeShares([...this.store.shares(), { from: realFrom, to: realTo, at }])
    this.store.appendLog(realFrom, { at, action: 'share', reason: `shared with ${realTo}`, by, project: realTo })
    return true
  }

  /** Stop `to` reading `from`'s records. Narrows only, so it is not asked. */
  unshare(from: string, to: string, by: KnowledgeProvenance = { source: 'owner' }): boolean {
    const realFrom = realProject(from)
    const realTo = realProject(to)
    const shares = this.store.shares()
    const kept = shares.filter((share) => !(share.from === realFrom && share.to === realTo))
    if (kept.length === shares.length) return false
    this.store.writeShares(kept)
    this.store.appendLog(realFrom, { at: this.now(), action: 'unshare', reason: `no longer shared with ${realTo}`, by, project: realTo })
    return true
  }

  /** The project's change log: supersedes, deletes, shares. */
  changes(project: string): KnowledgeLogEntry[] {
    return this.store.log(realProject(project))
  }

  /**
   * Write a record as given — any status — and, when it replaces one, mark that
   * one superseded and log why.
   *
   * The replacement is written first: a crash between the two writes leaves two
   * live records, which read as a conflict somebody resolves, rather than one
   * superseded record with nothing in its place.
   *
   * For this folder only. `record` and `supersede` reach it with claims;
   * `ingest.ts` reaches it with the review's verified results. Nothing outside
   * `src/main/knowledge/` is handed it.
   */
  commit(real: string, next: KnowledgeRecord | null, replaces?: { id: string; reason: string; by: KnowledgeProvenance }): void {
    if (next !== null) {
      if (next.project !== real) throw new KnowledgeError('a record is written into its own project only')
      this.store.write(next)
    }
    if (replaces !== undefined) this.retire(real, replaces.id, replaces.reason, replaces.by, next?.id)
  }

  /** Mark one record superseded and log it. Already superseded, or not there: nothing to do. */
  retire(real: string, id: string, reason: string, by: KnowledgeProvenance, replacement?: string): void {
    const old = this.store.read(real, id)
    if (old === null || old.status === 'superseded') return
    this.store.write({ ...old, status: 'superseded' })
    this.store.appendLog(real, {
      at: this.now(),
      action: 'supersede',
      id,
      reason: oneLine(reason, MAX_REASON_CHARS),
      by,
      ...(replacement === undefined ? {} : { replacement }),
    })
  }

  /** A record as a reader gets it, worked out against its own project's neighbours. */
  viewOf(record: KnowledgeRecord): KnowledgeView {
    const found = this.ownViews(record.project).find((view) => view.id === record.id)
    return found ?? viewsOf([record], this.context())[0]
  }

  /** A claim, checked and cleaned, not yet written. */
  claim(project: string, real: string, input: ClaimInput): KnowledgeRecord {
    if (!KNOWLEDGE_KINDS.includes(input.kind)) throw new KnowledgeError(`${String(input.kind)} is not a kind of knowledge`)
    const subject = oneLine(text(input.subject, 'subject', MAX_SUBJECT_CHARS * 4), MAX_SUBJECT_CHARS)
    const statement = text(input.statement, 'statement', MAX_STATEMENT_CHARS)
    const roots = [...new Set([real, isAbsolute(project) ? resolve(project) : real])]
    const record: KnowledgeRecord = {
      id: this.store.freshId(real),
      project: real,
      kind: input.kind,
      subject,
      statement,
      status: 'claim',
      provenance: cleanProvenance(input.provenance, roots),
      createdAt: this.now(),
    }
    const limit = staleAfter(input.staleAfterMs)
    if (limit !== undefined) record.staleAfterMs = limit
    return record
  }
}
