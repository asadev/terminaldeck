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

describe('closeWarning for a terminal on a server', () => {
  /*
   * The sentence is written around the fear rather than around the act.
   *
   * Somebody pressing ✕ on a row that belongs to a live server is not worried
   * about losing a scrollback. They are worried that they have just stopped
   * their website — which is exactly what the word "close" beside a server's
   * name suggests to a person who does not know better, and is the same argument
   * the *Forget this server* control is written around one file over. So what is
   * still running is said in the second clause, where it will be read.
   */
  it('says what it leaves running, on one terminal', () => {
    const warning = closeWarning('idle', 1, 'server')
    expect(warning.headline).toBe('This closes the terminal on that server.')
    expect(warning.detail).toContain('Nothing else on the server is touched')
    expect(warning.detail).toContain('open another terminal whenever you like')
  })

  it('counts them when there is more than one, and still says it', () => {
    const warning = closeWarning('working', 3, 'server')
    expect(warning.headline).toBe('This closes 3 terminals on that server.')
    expect(warning.detail).toContain('Nothing else on the server is touched')
  })

  it('never tells somebody they are closing a project or a machine', () => {
    /*
     * The three group subjects share one dialog and differ only in their nouns,
     * and getting them crossed is how a confirmation stops being read: a
     * project's close takes its folder off the rail, a machine's leaves it
     * paired, and a server's leaves a live machine running exactly as it was.
     */
    for (const count of [1, 4]) {
      const warning = closeWarning('idle', count, 'server')
      expect(warning.headline).not.toMatch(/project|machine/i)
      expect(warning.detail).not.toMatch(/project|stays connected/i)
    }
  })

  it('leaves the other three subjects saying what they always said', () => {
    // A fourth subject that changed the other three would be a regression this
    // file could not see, because every assertion above is about the new one.
    expect(closeWarning('idle', 2, 'machine').headline).toContain('machine')
    expect(closeWarning('idle', 2, 'project').headline).toContain('project')
    expect(closeWarning('working', 1).headline).toBe('This session is still working.')
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
