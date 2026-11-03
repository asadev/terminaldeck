/**
 * What the task flow reports, kept as project knowledge.
 *
 *  - `delegated`, `reassigned`, `stalled`: a line of task history.
 *  - `finished`: the worker's result, as a **claim**, with its summary. A newer
 *    claim for the same task replaces an older one.
 *  - `verified`: the review's result, **verified**, with its evidence and the
 *    time it was checked — replacing the claim, and any older result of the task.
 *  - `rejected`: the claim is superseded by a line of history that says why.
 *
 * This is the only place in the app that writes `verified`, and it writes it
 * only for a `verified` event — which the task engine raises from its review and
 * nothing else. A worker reaches knowledge through `knowledge.note`, which can
 * only make claims (`book.ts`).
 *
 * A review that names no evidence does not make a record verified: the shared
 * definition is that `verified` rests on named evidence. The acceptance is kept
 * as history instead and the result stays a claim, so the brief says honestly
 * that nobody wrote down what it was checked against.
 *
 * Every record keeps the event's own time, not the time it was written, and an
 * event delivered twice is written once.
 */

import type { KnowledgeProvenance, KnowledgeRecord, TaskKnowledgeEvent } from '../../shared/agent-stack'
import type { KnowledgeBook } from './book'
import { MAX_STATEMENT_CHARS } from './store'

/** The subject a task's history and its result are kept under. */
export function taskSubject(taskId: string): string {
  return `task ${taskId}`
}

function fit(text: string): string {
  const trimmed = text.trim()
  return trimmed.length > MAX_STATEMENT_CHARS ? `${trimmed.slice(0, MAX_STATEMENT_CHARS - 1).trimEnd()}…` : trimmed
}

function said(summary: string | undefined): string {
  return summary !== undefined && summary.trim() !== '' ? summary.trim() : ''
}

/** The record as the event describes it, stamped with the event's time. */
function build(
  book: KnowledgeBook,
  event: TaskKnowledgeEvent,
  real: string,
  kind: 'task-history' | 'result',
  statement: string,
  provenance: KnowledgeProvenance,
): KnowledgeRecord {
  const record = book.claim(event.project, real, { kind, subject: taskSubject(event.taskId), statement: fit(statement), provenance })
  return { ...record, createdAt: event.at }
}

function provenanceOf(event: TaskKnowledgeEvent, source: KnowledgeProvenance['source']): KnowledgeProvenance {
  return {
    source,
    taskId: event.taskId,
    ...(event.goalId ? { goalId: event.goalId } : {}),
    ...(event.agentId ? { agentId: event.agentId } : {}),
    ...(event.sessionId ? { sessionId: event.sessionId } : {}),
  }
}

/** Has this event already been written? Same kind, subject, statement and time. */
function already(records: readonly KnowledgeRecord[], next: KnowledgeRecord): boolean {
  return records.some(
    (record) =>
      record.kind === next.kind &&
      record.subject === next.subject &&
      record.statement === next.statement &&
      record.createdAt === next.createdAt &&
      record.status === next.status,
  )
}

export function noteTaskEvent(book: KnowledgeBook, event: TaskKnowledgeEvent): void {
  const real = book.projectOf(event.project)
  const records = book.store.records(real)
  const subject = taskSubject(event.taskId)
  const results = records.filter((record) => record.kind === 'result' && record.subject === subject && record.status !== 'superseded')
  const summary = said(event.summary)
  const to = event.agentId ? ` to ${event.agentId}` : ''

  const history = (statement: string, source: KnowledgeProvenance['source'] = 'task', supersedes?: string): KnowledgeRecord | null => {
    const next: KnowledgeRecord = {
      ...build(book, event, real, 'task-history', statement, { ...provenanceOf(event, source), evidence: event.evidence }),
      ...(supersedes === undefined ? {} : { supersedes }),
    }
    if (already(records, next)) return null
    book.commit(real, next)
    return next
  }

  switch (event.kind) {
    case 'delegated':
      history(`Delegated “${event.title}”${to}.${summary ? ` ${summary}` : ''}`)
      return
    case 'reassigned':
      history(`Reassigned “${event.title}”${to}.${summary ? ` ${summary}` : ''}`)
      return
    case 'stalled':
      history(`“${event.title}” stalled.${summary ? ` ${summary}` : ''}`)
      return
    case 'finished': {
      const next = build(book, event, real, 'result', `${event.title}: ${summary || 'finished, with no summary given.'}`, {
        ...provenanceOf(event, 'task'),
        evidence: event.evidence,
      })
      if (already(records, next)) return
      book.commit(real, next)
      for (const old of results.filter((record) => record.status === 'claim')) {
        book.retire(real, old.id, 'a newer result was claimed for the same task', next.provenance, next.id)
      }
      return
    }
    case 'verified': {
      const claim = results.filter((record) => record.status === 'claim').sort((a, b) => b.createdAt - a.createdAt)[0]
      if ((event.evidence ?? []).filter((item) => item.trim() !== '').length === 0) {
        history(
          `Review accepted the result of “${event.title}” without naming evidence, so it stays a claim.${summary ? ` ${summary}` : ''}`,
          'review',
        )
        return
      }
      const statement = summary ? `${event.title}: ${summary}` : (claim?.statement ?? `${event.title}: verified.`)
      const next: KnowledgeRecord = {
        ...build(book, event, real, 'result', statement, { ...provenanceOf(event, 'review'), evidence: event.evidence }),
        status: 'verified',
        verifiedAt: event.at,
        ...(claim === undefined ? {} : { supersedes: claim.id }),
      }
      if (already(records, next)) return
      book.commit(real, next)
      // The claim it checked, and any older result of this task — the review is now what is known.
      for (const old of results) book.retire(real, old.id, 'verified by review', next.provenance, next.id)
      return
    }
    case 'rejected': {
      const claims = results.filter((record) => record.status === 'claim')
      const reasons = summary || 'no reasons were given.'
      // The history line names the claim it answers, so the chain reads claim → rejection.
      const newest = [...claims].sort((a, b) => b.createdAt - a.createdAt)[0]
      const next = history(`Review rejected the result of “${event.title}”: ${reasons}`, 'review', newest?.id)
      if (next === null) return
      for (const old of claims) book.retire(real, old.id, `rejected by review: ${reasons}`, next.provenance, next.id)
      return
    }
  }
}
