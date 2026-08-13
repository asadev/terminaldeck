/**
 * Turning a session list into something worth looking at on a phone.
 *
 * The list is the screen someone opens while walking, to answer one question:
 * is the thing I left running still going, and does it need me? So the order
 * and the two words next to each row carry the whole feature, and both are
 * derived here rather than in the DOM code, where they could not be tested.
 */

import type { RemoteSession } from './protocol-client'

/**
 * The dot's colour.
 *
 * `RemoteSession.status` is a free-form string on the wire — the vocabulary
 * belongs to the desktop's session layer, and pinning it here would mean a
 * status added there arrives as a crash rather than as a grey dot. The six
 * known ones are the desktop's `SessionStatus` union; anything else is
 * `unknown`, drawn neutral, with the word itself shown beside it.
 */
export type StatusTone = 'working' | 'waiting' | 'input' | 'completed' | 'idle' | 'exited' | 'unknown'

const TONES: Record<string, StatusTone> = {
  working: 'working',
  waiting: 'waiting',
  input: 'input',
  completed: 'completed',
  idle: 'idle',
  exited: 'exited',
}

export function statusTone(status: string): StatusTone {
  return TONES[status.trim().toLowerCase()] ?? 'unknown'
}

/**
 * The tone for a whole row.
 *
 * An exit code outranks the status string. A session that has finished keeps
 * whatever status it last reported — usually `idle` — and drawing it with the
 * same dot as a session that is alive and merely quiet is the one distinction
 * this list exists to make.
 */
export function sessionTone(session: RemoteSession): StatusTone {
  return session.exitCode !== null ? 'exited' : statusTone(session.status)
}

/** What the row says beside the dot. Unknown statuses show their own word. */
export function statusLabel(session: RemoteSession): string {
  if (session.exitCode !== null) return session.exitCode === 0 ? 'Finished' : `Exited (${session.exitCode})`
  switch (statusTone(session.status)) {
    case 'working':
      return 'Working'
    case 'waiting':
      return 'Waiting'
    case 'input':
      return 'Needs input'
    case 'completed':
      return 'Done'
    case 'idle':
      return 'Idle'
    case 'exited':
      return 'Exited'
    default:
      return session.status
  }
}

/**
 * "4m ago", or null when nothing real is known.
 *
 * Null is the important return. The wire carries no activity timestamp today,
 * so for a session this phone has never attached to there is nothing true to
 * print, and the row prints nothing rather than the moment the list arrived
 * dressed up as the moment the session last did something.
 */
export function formatSince(now: number, at: number | null): string | null {
  if (at === null || !Number.isFinite(at) || at <= 0) return null
  const seconds = Math.floor((now - at) / 1000)
  if (seconds < 0) return 'just now'
  if (seconds < 45) return 'just now'
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${Math.max(1, minutes)}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

/**
 * The order rows appear in.
 *
 * Live sessions first, most recently active first within that, and finished
 * ones at the bottom. A phone shows five rows without scrolling, and the one
 * that needs attention has to be in them.
 */
export function sortSessions(sessions: readonly RemoteSession[], activity: ReadonlyMap<string, number>): RemoteSession[] {
  const rank = (session: RemoteSession): number => {
    if (session.exitCode !== null) return 3
    return statusTone(session.status) === 'input' ? 0 : 1
  }
  return [...sessions].sort((a, b) => {
    const byRank = rank(a) - rank(b)
    if (byRank !== 0) return byRank
    const byActivity = (activity.get(b.id) ?? 0) - (activity.get(a.id) ?? 0)
    if (byActivity !== 0) return byActivity
    return a.title.localeCompare(b.title)
  })
}

/** The folder a session is in, shortened for a 375px-wide screen. */
export function shortenPath(cwd: string, home?: string): string {
  const path = home !== undefined && home !== '' && cwd.startsWith(home) ? `~${cwd.slice(home.length)}` : cwd
  const parts = path.split('/').filter((part) => part !== '')
  if (parts.length <= 2) return path
  return `…/${parts.slice(-2).join('/')}`
}
