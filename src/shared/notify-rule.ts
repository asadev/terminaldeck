/**
 * Whether a session's change of status is worth interrupting somebody for.
 *
 * The rule behind the desktop banners (`renderer/notifications.ts`, which has
 * the five rules written out in full) and behind Hoot's moments in the menu bar
 * (`main/hoot-menubar.ts`). It lives here, in `shared/`, so the two run the
 * same function: a session that a banner calls "finished" is a session the
 * menu bar calls finished, and a status that flickers is swallowed by both
 * with the same cooldown. Moved out of the renderer on 2026-10-03 for the
 * menu bar, unchanged; `notifications.ts` re-exports it so nothing else moved.
 */

import type { SessionStatus } from './types'

/** The two states worth interrupting someone for. */
export const NOTIFYING_STATUSES = ['completed', 'input'] as const

export type NotifyingStatus = (typeof NOTIFYING_STATUSES)[number]

export function isNotifyingStatus(status: SessionStatus): status is NotifyingStatus {
  return status === 'completed' || status === 'input'
}

/**
 * How long a session stays quiet after firing.
 *
 * Sized against the activity tracker's 700ms settle window: a genuine second
 * question, asked after the user answered the first, is minutes away, while a
 * repaint-induced flap is under a second. Four seconds swallows every flap and
 * delays no real event.
 */
export const NOTIFY_COOLDOWN_MS = 4000

/* -------------------------------------------------------------------------- */
/* The decision                                                                */
/* -------------------------------------------------------------------------- */

/** Why a status change did not produce a banner. Named so tests read as prose. */
export type SuppressionReason =
  | 'disabled'
  | 'first-sight'
  | 'unchanged'
  | 'not-notifying'
  | 'watching'
  | 'cooldown'

export type NotifyVerdict = { fire: true } | { fire: false; reason: SuppressionReason }

export interface NotifyDecisionInput {
  /** The status just reported. */
  status: SessionStatus
  /** The last status seen for this session, or undefined if it is new to us. */
  previous: SessionStatus | undefined
  /** Has the user turned notifications on? */
  enabled: boolean
  /** Is this session the active tab of a focused window? */
  watching: boolean
  /**
   * When a banner for *this same status* last fired for this session, or null
   * if it never has.
   *
   * Per status rather than per session, because a session that asks a question
   * and then finishes has genuinely done two things and swallowing the second
   * would lose the event the user cares most about. Per status *and remembered
   * separately*, because a single most-recent-fire slot is no cooldown at all:
   * see the caller.
   */
  lastFiredAt: number | null
  now: number
  cooldownMs: number
}

/**
 * Apply the five rules, in the order that makes the cheapest check first and
 * the most surprising one last.
 */
export function decide(input: NotifyDecisionInput): NotifyVerdict {
  if (!input.enabled) return { fire: false, reason: 'disabled' }
  if (input.previous === undefined) return { fire: false, reason: 'first-sight' }
  if (input.previous === input.status) return { fire: false, reason: 'unchanged' }
  if (!isNotifyingStatus(input.status)) return { fire: false, reason: 'not-notifying' }
  if (input.watching) return { fire: false, reason: 'watching' }

  if (input.lastFiredAt !== null && input.now - input.lastFiredAt < input.cooldownMs) {
    return { fire: false, reason: 'cooldown' }
  }

  return { fire: true }
}
