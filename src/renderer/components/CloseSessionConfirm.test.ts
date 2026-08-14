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
 * portals through `Modal`. The rule worth protecting is which states are worth
 * interrupting for, because getting it wrong in either direction destroys the
 * dialog: too eager and it gets clicked through, too shy and it never appears
 * when it matters.
 */

const ALL: SessionStatus[] = ['idle', 'working', 'waiting', 'input', 'completed', 'exited']

describe('needsCloseConfirm', () => {
  it('asks about a session that is mid-task', () => {
    expect(needsCloseConfirm('working', true)).toBe(true)
  })

  it('asks about a session blocked on a question', () => {
    expect(needsCloseConfirm('input', true)).toBe(true)
  })

  it('never asks about an idle session', () => {
    expect(needsCloseConfirm('idle', true)).toBe(false)
  })

  it('never asks about a session whose process has exited', () => {
    expect(needsCloseConfirm('exited', true)).toBe(false)
  })

  it('never asks about a completed session', () => {
    expect(needsCloseConfirm('completed', true)).toBe(false)
  })

  it('never asks about `waiting`, which is an empty prompt and not a wait on the user', () => {
    // session-activity.ts classifies a bare `❯` as `waiting`. That is the
    // resting state of every healthy session, so confirming on it would fire on
    // nearly every close.
    expect(needsCloseConfirm('waiting', true)).toBe(false)
  })

  it('asks about nothing once the user has turned it off', () => {
    for (const status of ALL) expect(needsCloseConfirm(status, false)).toBe(false)
  })

  it('covers exactly two of the six statuses', () => {
    expect(ALL.filter((status) => needsCloseConfirm(status, true))).toEqual(['working', 'input'])
    expect(RISKY_STATUSES.size).toBe(2)
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
    for (const status of ['working', 'input'] as SessionStatus[]) {
      expect(closeWarning(status).detail.length).toBeGreaterThan(20)
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
    expect(warning.detail).toContain('project')
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
