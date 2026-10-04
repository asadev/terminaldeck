/**
 * The Stays Fixed page's words and decisions, without React — so a test can
 * read every sentence the page can print.
 */

import { AGENT_ENTRIES } from '../../shared/agent-catalog'
import { STAYS_FIXED_AGENTS } from '../../shared/stays-fixed'
import { relativeTime } from '../components/relative-time'
import type { FixedProgress, FixedResults, FixedVerdict, StaysFixedStatus } from './bridge'

/** "a, b and c". */
export function listWords(items: readonly string[]): string {
  if (items.length <= 1) return items[0] ?? ''
  return `${items.slice(0, -1).join(', ')} and ${items[items.length - 1]}`
}

/**
 * The agents a session can be given the server in, by the names the rest of
 * the app uses for them. Read from the catalogue, so a renamed agent is renamed
 * here too, and from the one shared list `agents.ts` is tested against.
 */
export function agentNames(): string {
  return listWords(
    STAYS_FIXED_AGENTS.map((id) => AGENT_ENTRIES.find((entry) => entry.id === id)?.label ?? id),
  )
}

/** Which colour a verdict wears: data keeps its meaning, per CLAUDE.md. */
export function verdictTone(verdict: FixedVerdict | null): 'positive' | 'warning' | 'critical' | 'muted' {
  if (verdict === 'clean') return 'positive'
  if (verdict === 'differences') return 'warning'
  if (verdict === 'could-not-run') return 'critical'
  return 'muted'
}

/** The big line at the top of a set-up project's page. */
export function headline(status: StaysFixedStatus): string {
  if (status.running) return 'Checking…'
  const last = status.last
  if (!last) return 'Not checked yet.'
  // A check that compared nothing, followed by marking that build as good, is
  // the cold start finishing — and the check's own words ("mark this build as
  // good to start") would then ask for the thing just done.
  // The same after "Mark as good anyway": the differences the check found are
  // the new normal now, and the headline counting them as unasked-for would be
  // the page disagreeing with the button the person just pressed.
  if (markedSinceLastCheck(status)) {
    if (last.verdict === 'differences') return 'Marked as good, with these differences as the new normal.'
    if (last.verdict === 'not-compared') return 'Ready. Run a check after your next change.'
  }
  return last.headline
}

/** The build was marked as good after the last check ran. */
export function markedSinceLastCheck(status: StaysFixedStatus): boolean {
  if (!status.last || !status.reference) return false
  const marked = Date.parse(status.reference.setAt)
  const checked = Date.parse(status.last.at)
  return Number.isFinite(marked) && Number.isFinite(checked) && marked >= checked
}

/** The verdict's colour, as the page draws it now — which a later "mark as good" changes. */
export function statusTone(status: StaysFixedStatus): ReturnType<typeof verdictTone> {
  if (status.running) return 'muted'
  const verdict = status.last?.verdict ?? null
  if ((verdict === 'differences' || verdict === 'not-compared') && markedSinceLastCheck(status)) return 'positive'
  return verdictTone(verdict)
}

/**
 * The quiet line under it: when, and against what.
 *
 * "Compared against 1.0.0" is the fact that makes a clean result mean
 * something, so it is said every time there is one; "no build is marked as
 * good yet" is said when there is not, because that is the reason a check can
 * only ever answer "not compared".
 */
export function subline(status: StaysFixedStatus, now: number): string {
  const parts: string[] = []
  const last = status.last
  if (last && !status.running) {
    const at = Date.parse(last.at)
    if (Number.isFinite(at) && at > 0) parts.push(`Checked ${relativeTime(at, now)}`)
  }
  if (status.reference) {
    const at = Date.parse(status.reference.setAt)
    const when = Number.isFinite(at) && at > 0 ? `, marked ${relativeTime(at, now)}` : ''
    parts.push(`Good build: ${status.reference.name}${when}`)
  } else {
    parts.push('No build is marked as good yet')
  }
  return parts.join(' · ')
}

/** "0:34", "12:05". */
export function elapsed(ms: number): string {
  const seconds = Math.max(0, Math.floor(ms / 1000))
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`
}

/** Who started the running check, as the progress line says it. */
export function startedBy(progress: FixedProgress): string {
  return progress.by === 'you' || progress.by === '' ? 'You started this check' : `${progress.by} started this check`
}

/** Pictures for one difference, or none. */
export function picturesOf(results: FixedResults, id: string): FixedResults['pictures'][string] {
  return results.pictures[id] ?? []
}

/** "1 difference", "3 places". */
export function count(n: number, one: string, many = `${one}s`): string {
  return `${n} ${n === 1 ? one : many}`
}

/** "command-line tools" → "Command-line tools", for a name that starts a line. */
export function sentenceCase(text: string): string {
  return text === '' ? text : `${text[0]?.toUpperCase() ?? ''}${text.slice(1)}`
}
