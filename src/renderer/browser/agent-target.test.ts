import { describe, expect, it } from 'vitest'
import { readSessions, resolveAgentSessions, resolveTarget, whyDisabled } from './agent-target'

/**
 * "It will just randomly send to anyone whatever I say here."
 *
 * He is describing the old behaviour exactly: every send from the browser went
 * to `activeSessionId`, whichever session happened to be focused behind the
 * page. His rules, and one case each:
 *
 *   - nothing is chosen to begin with;
 *   - the button stays grey until something is;
 *   - the choice sticks until he changes it;
 *   - a session that has died is not a target.
 */

const LIVE = [
  { id: 'a', cwd: '/Users/apple/Projects/terminaldeck', provider: 'claude', exitCode: null },
  { id: 'b', cwd: '/Users/apple/Projects/terminaldeck', provider: 'shell', exitCode: null },
  { id: 'c', cwd: '/Users/apple/Projects/science-locus', provider: 'claude', exitCode: null },
]

describe('readSessions', () => {
  it('numbers within a project, the way the rail does', () => {
    // So the picker says the same words as the row he would otherwise click.
    expect(readSessions(LIVE).map((session) => session.label)).toEqual([
      'terminaldeck · Session 1',
      'terminaldeck · Session 2',
      'science-locus · Session 1',
    ])
  })

  it('reads a dead session as dead', () => {
    const rows = readSessions([{ id: 'a', cwd: '/x', provider: 'claude', exitCode: 0 }])
    expect(rows[0].ended).toBe(true)
  })

  it('survives anything at all coming back across the bridge', () => {
    expect(readSessions(null)).toEqual([])
    expect(readSessions('nope')).toEqual([])
    expect(readSessions([null, 7, {}, { id: '' }])).toEqual([])
  })

  it('numbers a session with no folder in its own group', () => {
    const rows = readSessions([
      { id: 'a', cwd: '/x/one', provider: 'shell', exitCode: null },
      { id: 'b', cwd: '', provider: 'shell', exitCode: null },
    ])
    expect(rows.map((row) => row.label)).toEqual(['one · Session 1', 'Session 1'])
  })
})

describe('resolveTarget', () => {
  const sessions = readSessions(LIVE)

  it('is nothing until something is chosen', () => {
    // The whole point. Not the first, not the only one, not the newest.
    expect(resolveTarget('', sessions)).toBeNull()
  })

  it('is the chosen session once one is', () => {
    expect(resolveTarget('b', sessions)?.label).toBe('terminaldeck · Session 2')
  })

  it('is nothing when the chosen session has gone', () => {
    expect(resolveTarget('zzz', sessions)).toBeNull()
  })

  it('is nothing when the chosen session has exited', () => {
    // His case: "if that session dies, I need to select again another session."
    const dead = readSessions([{ id: 'a', cwd: '/x', provider: 'claude', exitCode: 1 }])
    expect(resolveTarget('a', dead)).toBeNull()
  })
})

describe('whyDisabled', () => {
  const sessions = readSessions(LIVE)

  it('says which of the reasons it is', () => {
    expect(whyDisabled('', sessions, true)).toMatch(/Choose a session/)
    expect(whyDisabled('', [], true)).toMatch(/No sessions are open/)
    expect(whyDisabled('', [], false)).toMatch(/cannot list your sessions/)
    expect(whyDisabled('gone', sessions, true)).toMatch(/gone/i)
  })

  it('names the session that exited, rather than saying "a session"', () => {
    const dead = readSessions([{ id: 'a', cwd: '/x/proj', provider: 'claude', exitCode: 0 }])
    expect(whyDisabled('a', dead, true)).toContain('proj · Session 1')
  })

  it('says nothing at all once a send would work', () => {
    expect(whyDisabled('a', sessions, true)).toBe('')
  })
})

describe('resolveAgentSessions', () => {
  const complete = {
    listSessions: () => Promise.resolve([]),
    writeToSession: () => undefined,
    onSessionCreated: () => () => undefined,
    onSessionExit: () => () => undefined,
  }

  it('accepts a preload that has all four', () => {
    expect(resolveAgentSessions(complete)).not.toBeNull()
  })

  it('refuses one missing any single method, rather than half-working', () => {
    for (const absent of Object.keys(complete)) {
      const partial: Record<string, unknown> = { ...complete }
      delete partial[absent]
      expect(resolveAgentSessions(partial), `accepted a bridge without ${absent}`).toBeNull()
    }
  })

  it('refuses nothing at all', () => {
    expect(resolveAgentSessions(null)).toBeNull()
    expect(resolveAgentSessions(undefined)).toBeNull()
    expect(resolveAgentSessions('deck')).toBeNull()
  })
})
