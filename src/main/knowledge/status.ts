/**
 * What a reader is told about a record: its stored status, or `stale` /
 * `conflicting` worked out at the moment it is read — with the reason in words.
 *
 * Never written down. A record that said "stale" on disk would itself go out of
 * date the moment its evidence was checked again; worked out on every read from
 * the clock, the evidence files and the record's neighbours, it cannot.
 *
 * Deterministic on purpose: the clock and the file stat are handed in, so a test
 * pins "thirty-one days later" and "this file changed after it was verified"
 * without waiting or touching a real file's time.
 */

import { statSync } from 'node:fs'
import { isAbsolute, relative, resolve } from 'node:path'
import type { KnowledgeKind, KnowledgeRecord, KnowledgeView } from '../../shared/agent-stack'
import { DAY_MS } from './store'

/**
 * How long a record of each kind reads as current, when it does not say.
 *
 * Results and architecture describe code, and code moves: a result a month old
 * or a description of the architecture three months old should be looked at
 * again before anybody builds on it. A constraint or a decision does not expire
 * by itself — "never ship on a red CI" is as true next year — and neither does
 * a goal or a line of task history, which records that something happened. Any
 * record may still set its own `staleAfterMs`.
 */
export const DEFAULT_STALE_AFTER_MS: Readonly<Partial<Record<KnowledgeKind, number>>> = Object.freeze({
  result: 30 * DAY_MS,
  architecture: 90 * DAY_MS,
})

/** Task history accumulates by design; one entry per event is not a disagreement. */
const NEVER_CONFLICTS: ReadonlySet<KnowledgeKind> = new Set(['task-history'])

export interface StatusContext {
  now: number
  /** Modified time of a file, or null when there is no such file. */
  statMtime: (path: string) => number | null
}

export function fileMtime(path: string): number | null {
  try {
    const stat = statSync(path, { throwIfNoEntry: false })
    return stat !== undefined && stat.isFile() ? stat.mtimeMs : null
  } catch {
    return null
  }
}

export function staleAfterOf(record: Pick<KnowledgeRecord, 'kind' | 'staleAfterMs'>): number | null {
  return record.staleAfterMs ?? DEFAULT_STALE_AFTER_MS[record.kind] ?? null
}

/** The conflict key: one subject however it was capitalised or spaced. */
export function subjectKey(subject: string): string {
  return subject.replace(/\s+/g, ' ').trim().toLowerCase()
}

function sameStatement(a: string, b: string): boolean {
  return a.replace(/\s+/g, ' ').trim() === b.replace(/\s+/g, ' ').trim()
}

export function day(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10)
}

/**
 * The file an evidence entry names inside the project, or null.
 *
 * A command, a URL or a path outside the project is not a file this can check
 * and is left alone — never statted, so evidence cannot be used to probe the
 * disk. `src/a.ts:42` is read as `src/a.ts`.
 */
export function evidenceFile(project: string, item: string): string | null {
  const text = item.trim()
  if (text === '' || /^[a-z][a-z0-9+.-]*:\/\//i.test(text)) return null
  const bare = text.replace(/:\d+(?::\d+)?$/, '')
  const full = isAbsolute(bare) ? resolve(bare) : resolve(project, bare)
  const rel = relative(project, full)
  if (rel === '' || rel.startsWith('..') || isAbsolute(rel)) return null
  return full
}

function staleNotes(record: KnowledgeRecord, context: StatusContext): string[] {
  const notes: string[] = []
  const since = record.verifiedAt ?? record.createdAt
  const word = record.verifiedAt === undefined ? 'recorded' : 'verified'
  const limit = staleAfterOf(record)
  if (limit !== null && context.now - since > limit) {
    const days = Math.floor((context.now - since) / DAY_MS)
    notes.push(`${word} ${days} days ago (${day(since)}); a ${record.kind} older than ${Math.round(limit / DAY_MS)} days is re-checked`)
  }
  for (const item of record.provenance.evidence ?? []) {
    const file = evidenceFile(record.project, item)
    if (file === null) continue
    const mtime = context.statMtime(file)
    if (mtime !== null && mtime > since) {
      notes.push(`${relative(record.project, file)} changed after it was ${word} (${day(mtime)} > ${day(since)})`)
    }
  }
  return notes
}

/**
 * Views of one project's records. Conflicts are found only inside the project:
 * a project that reads another's records through a share may legitimately know
 * something different about a subject of the same name.
 */
export function viewsOf(records: readonly KnowledgeRecord[], context: StatusContext): KnowledgeView[] {
  const live = records.filter((record) => record.status !== 'superseded' && !NEVER_CONFLICTS.has(record.kind))
  const bySubject = new Map<string, KnowledgeRecord[]>()
  for (const record of live) {
    const key = subjectKey(record.subject)
    const group = bySubject.get(key)
    if (group === undefined) bySubject.set(key, [record])
    else group.push(record)
  }
  return records.map((record) => {
    if (record.status === 'superseded') return { ...record, effective: 'superseded', notes: [] }
    const others = NEVER_CONFLICTS.has(record.kind)
      ? []
      : (bySubject.get(subjectKey(record.subject)) ?? []).filter(
          (other) => other.id !== record.id && !sameStatement(other.statement, record.statement),
        )
    const conflictNotes = others.map(
      (other) => `disagrees with ${other.id} (${other.status}, ${day(other.verifiedAt ?? other.createdAt)}) on "${record.subject}"`,
    )
    const stale = staleNotes(record, context)
    const effective = conflictNotes.length > 0 ? 'conflicting' : stale.length > 0 ? 'stale' : record.status
    return { ...record, effective, notes: [...conflictNotes, ...stale] }
  })
}
