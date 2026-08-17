import { describe, expect, it } from 'vitest'
import type { ProtocolErrorCode, RemoteSession, ServerMessage } from './protocol-client'
import {
  formatSince,
  noticeAfter,
  sessionTone,
  shortenPath,
  sortSessions,
  statusLabel,
  statusTone,
} from './sessions'

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

/**
 * The sentence above the list, and the frame that has to end it.
 *
 * This exists because a screenshot of a *successful* pairing showed the pairing
 * instructions — "Paired. Approve this device in the desktop app, then
 * reconnect" — sitting above a live list of two running sessions, on the dev
 * build and on app.terminaldeck.dev alike. Nothing had failed. Every frame was
 * handled correctly on its own; what was missing was the frame that says the
 * complaint is over.
 */
describe('the notice above the session list', () => {
  const welcome = (): ServerMessage => ({
    t: 'welcome',
    protocol: 1,
    deviceId: 'd',
    deviceName: 'This browser',
    token: null,
    sessions: [],
    capabilities: [],
  })

  const refusal = (code: ProtocolErrorCode, message: string): ServerMessage => ({ t: 'error', code, message })

  it('is cleared by a welcome, which is the whole bug', () => {
    const pairing = 'Paired. Approve this device in the desktop app, then reconnect.'
    expect(noticeAfter(pairing, welcome(), 'Mac')).toBeNull()
  })

  it('is cleared by a welcome whatever the last refusal was, not just the pairing one', () => {
    /*
     * Narrowing this to the pairing sentence is the tempting fix and the wrong
     * one. A `welcome` is a socket that got through and a session list restated
     * from scratch, so *every* complaint a previous connection was still
     * carrying is stale — and a special case for one string is a special case
     * that goes out of date the day somebody rewords it on the desktop.
     */
    expect(noticeAfter('That did not reach the Mac.', welcome(), 'Mac')).toBeNull()
    expect(noticeAfter(null, welcome(), 'Mac')).toBeNull()
  })

  it('shows the desktop’s own words for a refusal', () => {
    expect(noticeAfter(null, refusal('unauthorized', 'That folder is not shared.'), 'Mac')).toBe(
      'That folder is not shared.',
    )
  })

  it('rewrites only unknown-session, and in this client’s noun', () => {
    // The one code whose wire wording is aimed at a client rather than a person.
    expect(noticeAfter(null, refusal('unknown-session', 'no such session'), 'PC')).toBe(
      'That session is no longer running on the PC.',
    )
  })

  it('leaves the notice alone for every frame that says nothing about it', () => {
    /*
     * The default, asserted rather than assumed. Output frames arrive by the
     * hundred while a terminal is open, and a notice that quietly vanished on
     * the next byte of output would be a report nobody could read in time.
     */
    const standing = 'That session is no longer running on the Mac.'
    expect(noticeAfter(standing, { t: 'output', id: 'a', data: 'x' }, 'Mac')).toBe(standing)
    expect(noticeAfter(standing, { t: 'sessions', sessions: [] }, 'Mac')).toBe(standing)
    expect(noticeAfter(standing, { t: 'pong' }, 'Mac')).toBe(standing)
  })
})
