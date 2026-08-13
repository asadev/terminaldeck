import { describe, expect, it } from 'vitest'
import type { RemoteSession } from './protocol-client'
import { formatSince, sessionTone, shortenPath, sortSessions, statusLabel, statusTone } from './sessions'

function session(patch: Partial<RemoteSession> = {}): RemoteSession {
  return {
    id: 'a',
    title: 'terminaldeck',
    cwd: '/Users/asad/Projects/terminaldeck',
    provider: 'claude',
    status: 'idle',
    exitCode: null,
    ...patch,
  }
}

describe('the status dot', () => {
  it('knows the desktop’s own vocabulary', () => {
    expect(statusTone('working')).toBe('working')
    expect(statusTone('input')).toBe('input')
    expect(statusTone('Completed')).toBe('completed')
  })

  it('draws a status it has never seen as neutral instead of failing', () => {
    // The vocabulary belongs to the desktop's session layer. Pinning it here
    // would mean a status added there arrives on the phone as a broken row.
    expect(statusTone('reviewing')).toBe('unknown')
    expect(statusLabel(session({ status: 'reviewing' }))).toBe('reviewing')
  })

  it('says what an exit code means, including the zero', () => {
    expect(statusLabel(session({ exitCode: 0 }))).toBe('Finished')
    expect(statusLabel(session({ exitCode: 130 }))).toBe('Exited (130)')
  })

  it('lets an exit code outrank the status the session died holding', () => {
    // A finished session keeps reporting `idle`, and drawing it with the same
    // dot as a session that is alive and quiet erases the only distinction
    // this list exists to make. Caught by looking at the rendered list.
    expect(statusTone(session({ status: 'idle', exitCode: 0 }).status)).toBe('idle')
    expect(sessionTone(session({ status: 'idle', exitCode: 0 }))).toBe('exited')
    expect(sessionTone(session({ status: 'working' }))).toBe('working')
  })
})

describe('last activity', () => {
  const now = 1_700_000_000_000

  it('prints nothing at all when nothing is known', () => {
    // The wire carries no activity timestamp yet. An empty cell is honest; the
    // moment the list arrived, printed as the moment the session last moved,
    // is not.
    expect(formatSince(now, null)).toBeNull()
    expect(formatSince(now, 0)).toBeNull()
  })

  it('reads in the units a person thinks in', () => {
    expect(formatSince(now, now - 5_000)).toBe('just now')
    expect(formatSince(now, now - 4 * 60_000)).toBe('4m ago')
    expect(formatSince(now, now - 3 * 3_600_000)).toBe('3h ago')
    expect(formatSince(now, now - 2 * 86_400_000)).toBe('2d ago')
  })

  it('never rounds a real gap down to nothing', () => {
    expect(formatSince(now, now - 61_000)).toBe('1m ago')
    expect(formatSince(now, now - 119_000)).toBe('1m ago')
  })

  it('survives a clock that disagrees with the desktop', () => {
    // Phone clocks drift, and a future timestamp must not render as "-3m ago".
    expect(formatSince(now, now + 60_000)).toBe('just now')
  })
})

describe('the order rows appear in', () => {
  it('puts what needs a human first and what has finished last', () => {
    const rows = sortSessions(
      [
        session({ id: 'done', title: 'done', exitCode: 0 }),
        session({ id: 'idle', title: 'idle' }),
        session({ id: 'asking', title: 'asking', status: 'input' }),
      ],
      new Map(),
    )
    expect(rows.map((row) => row.id)).toEqual(['asking', 'idle', 'done'])
  })

  it('breaks ties on what moved most recently', () => {
    const rows = sortSessions(
      [session({ id: 'old', title: 'old' }), session({ id: 'new', title: 'new' })],
      new Map([
        ['old', 1_000],
        ['new', 2_000],
      ]),
    )
    expect(rows.map((row) => row.id)).toEqual(['new', 'old'])
  })

  it('falls back to the title, so the order does not shuffle between renders', () => {
    const rows = sortSessions([session({ id: 'b', title: 'zeta' }), session({ id: 'a', title: 'alpha' })], new Map())
    expect(rows.map((row) => row.title)).toEqual(['alpha', 'zeta'])
  })

  it('does not mutate the list it was given', () => {
    const original = [session({ id: 'b', title: 'zeta' }), session({ id: 'a', title: 'alpha' })]
    sortSessions(original, new Map())
    expect(original.map((row) => row.id)).toEqual(['b', 'a'])
  })
})

describe('folder paths on a narrow screen', () => {
  it('keeps the two parts that identify the project', () => {
    expect(shortenPath('/Users/asad/Projects/terminaldeck')).toBe('…/Projects/terminaldeck')
  })

  it('leaves a short path alone', () => {
    expect(shortenPath('/tmp')).toBe('/tmp')
    expect(shortenPath('/Users/asad')).toBe('/Users/asad')
  })

  it('uses a tilde when the desktop said where home is', () => {
    expect(shortenPath('/Users/asad/code', '/Users/asad')).toBe('~/code')
  })
})
