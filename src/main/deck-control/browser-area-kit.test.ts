import { describe, expect, it } from 'vitest'
import type { ToolContext } from './catalogue'
import { actionOf, escalateBy, notASession, profileIdOf } from './browser-area-kit'

describe('reading an action', () => {
  const ACTIONS = ['list', 'delete'] as const

  it('defaults when none is given and refuses an unknown one with the real names', () => {
    expect(actionOf({}, ACTIONS, 'list')).toBe('list')
    expect(actionOf({ action: 'delete' }, ACTIONS, 'list')).toBe('delete')
    expect(() => actionOf({ action: 'remove' }, ACTIONS, 'list')).toThrow('action must be one of: list, delete')
  })

  it('reads an action nobody wrote down as alter, never as the gentle default', () => {
    const tier = escalateBy({ list: 'read', delete: 'alter' } as const, 'list')
    expect(tier({})).toBe('read')
    expect(tier({ action: 'delete' })).toBe('alter')
    expect(tier({ action: 'list ' })).toBe('alter')
    expect(tier({ action: 7 })).toBe('alter')
    // `hasOwnProperty`, so a prototype key is not an action either.
    expect(tier({ action: 'toString' })).toBe('alter')
  })
})

describe('naming a profile', () => {
  const PROFILES = [
    { id: 'default', name: 'Default' },
    { id: 'p2', name: 'Work' },
  ]

  it('takes an id, a name in any case, or nothing for the one switched on', () => {
    expect(profileIdOf('p2', PROFILES, 'default')).toBe('p2')
    expect(profileIdOf(' work ', PROFILES, 'default')).toBe('p2')
    expect(profileIdOf(null, PROFILES, 'p2')).toBe('p2')
  })

  it('refuses a near miss rather than guessing whose logins were meant', () => {
    expect(() => profileIdOf('Wor', PROFILES, 'default')).toThrow('These exist: Default, Work')
  })
})

describe('the session refusal', () => {
  it('refuses a session and lets the copilot through', () => {
    expect(() =>
      notASession({ caller: { kind: 'session', sessionId: 's' } } as unknown as ToolContext, 'browser.history'),
    ).toThrow('browser.history is the browser')
    expect(() => notASession({ caller: { kind: 'local' } } as unknown as ToolContext, 'browser.history')).not.toThrow()
  })
})
