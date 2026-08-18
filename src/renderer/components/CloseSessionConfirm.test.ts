import { describe, expect, it } from 'vitest'
import {
  canResumeProvider,
  closeWarning,
  CONFIRM_CLOSE_KEY,
  needsCloseConfirm,
  parseConfirmClose,
  RISKY_STATUSES,
} from './CloseSessionConfirm'
import type { SessionStatus } from '@shared/types'

/**
 * Pure logic only — this project has no DOM in its test setup and the dialog
 * portals through `Modal`.
 *
 * The rule worth protecting used to be *which* states are worth interrupting
 * for. It is now that there is no such rule: *"Always ask."* — Asad, 2026-08-17,
 * about closing anything from the side panel. What the status still decides is
 * the **wording**, and these pin both halves, because the failure mode of the
 * change is a dialog that fires on a session that exited an hour ago while
 * telling the reader they are about to lose work.
 */

const ALL: SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']

describe('needsCloseConfirm', () => {
  it('asks about every state there is', () => {
    /*
     * *"Always ask before closing anything from the side panel."*
     *
     * This replaced a rule that asked about `working` and `input` only. The old
     * rule was defensible — a dialog on every close trains the muscle memory
     * that dismisses it — and it lost to the audience: *"mostly non-technical
     * vibe coders"*, for whom a safeguard that only appears in states they
     * cannot name is no safeguard at all. Closing a project used to take four
     * calm agents with no confirmation whatsoever; that is what this fixes.
     */
    for (const status of ALL) expect(needsCloseConfirm(status, true)).toBe(true)
  })

  it('asks about nothing once the user has turned it off', () => {
    for (const status of ALL) expect(needsCloseConfirm(status, false)).toBe(false)
  })

  it('keeps the two costly states named, because the wording still depends on them', () => {
    // `RISKY_STATUSES` stopped deciding *whether* to ask and now decides *what
    // is at stake* — `closeWarning` below is what reads it. Losing the set would
    // lose the distinction between "this agent is mid-edit" and "this terminal
    // has been sitting idle".
    expect([...RISKY_STATUSES].sort()).toEqual(['input', 'working'])
  })
})

describe('parseConfirmClose', () => {
  it('defaults to asking when the key has never been written', () => {
    expect(parseConfirmClose({ theme: 'dark' })).toBe(true)
  })

  it('defaults to asking for a blob that is not an object', () => {
    expect(parseConfirmClose(null)).toBe(true)
    expect(parseConfirmClose('nope')).toBe(true)
    expect(parseConfirmClose(undefined)).toBe(true)
  })

  it('honours an explicit opt-out', () => {
    expect(parseConfirmClose({ [CONFIRM_CLOSE_KEY]: false })).toBe(false)
  })

  it('honours an explicit opt-in', () => {
    expect(parseConfirmClose({ [CONFIRM_CLOSE_KEY]: true })).toBe(true)
  })

  it('ignores a non-boolean value rather than treating it as truthy', () => {
    // `"false"` is truthy, and reading it as "do not ask" would be the exact
    // wrong way round.
    expect(parseConfirmClose({ [CONFIRM_CLOSE_KEY]: 'false' })).toBe(true)
    expect(parseConfirmClose({ [CONFIRM_CLOSE_KEY]: 0 })).toBe(true)
  })
})

describe('closeWarning', () => {
  it('describes a blocked session as a question left unanswered', () => {
    expect(closeWarning('input').headline).toContain('asked you')
  })

  it('describes a busy session as work in progress', () => {
    expect(closeWarning('working').headline).toContain('still working')
  })

  it('always says what is actually lost', () => {
    for (const status of ALL) {
      expect(closeWarning(status).detail.length).toBeGreaterThan(20)
    }
  })

  it('does not claim work is being lost when the process has already gone', () => {
    /*
     * The sharpest case of asking about every state: an exited session has no
     * agent to stop, and telling somebody it does is how a confirmation becomes
     * a thing you click through without reading — which is precisely the
     * objection the old two-state rule was built on. Answering it in the wording
     * rather than by declining to appear is what lets the dialog be universal.
     */
    const gone = closeWarning('exited')
    expect(gone.headline).toContain('already ended')
    expect(gone.detail).not.toContain('agent stops')
  })

  it('describes a calm session as an ending rather than an interruption', () => {
    for (const status of ['idle', 'waiting', 'completed'] as SessionStatus[]) {
      expect(closeWarning(status).headline).toBe('This ends the session.')
    }
  })
})

describe('closeWarning for a whole project', () => {
  it('speaks in the plural once more than one session is going', () => {
    // Closing a project takes every session in it — silently, until this
    // dialog learned to cover that path — and "this session is still working"
    // is the wrong sentence for four of them.
    const warning = closeWarning('working', 4)
    expect(warning.headline).toContain('4 sessions')
    expect(warning.headline).toContain('project')
  })

  it('still describes one session as one session', () => {
    expect(closeWarning('input', 1)).toEqual(closeWarning('input'))
  })
})

describe('canResumeProvider', () => {
  it('is true for the agents with a resume command', () => {
    expect(canResumeProvider('claude')).toBe(true)
    expect(canResumeProvider('codex')).toBe(true)
  })

  it('is false where no resume command was ever verified', () => {
    expect(canResumeProvider('gemini')).toBe(false)
    expect(canResumeProvider('shell')).toBe(false)
  })

  it('is false when the provider is unknown', () => {
    expect(canResumeProvider(undefined)).toBe(false)
  })
})
