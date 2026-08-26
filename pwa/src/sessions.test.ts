import { describe, expect, it } from 'vitest'
import type { ProtocolErrorCode, RemoteSession, ServerMessage } from './protocol-client'
import {
  RENAME_NOTE,
  closeOffered,
  closeQuestion,
  formatSince,
  noticeAfter,
  renameOffered,
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

describe('deleting a session from a browser', () => {
  it('is offered only by a machine that advertised it', () => {
    /*
     * The whole of the negotiation, and it matters more for this verb than for
     * any other: it is not undoable, so a Delete drawn against a host that would
     * refuse it is a control whose outcome a person cannot predict until after
     * they have pressed it.
     */
    expect(closeOffered(['localhost', 'create', 'upload'])).toBe(false)
    expect(closeOffered(['create', 'close'])).toBe(true)
  })

  it('is not implied by being able to start one', () => {
    // The public demo box is exactly this shape: it hands a stranger a shell and
    // withholds the verb that would let them end somebody else's.
    expect(closeOffered(['create'])).toBe(false)
  })

  it('names the session, the consequence and that it is final', () => {
    const asked = closeQuestion(session({ title: 'terminaldeck' }))
    expect(asked).toContain('terminaldeck')
    // The two facts a person is actually deciding on. Asserted as substrings
    // rather than as the whole sentence, so this pins the *content* and leaves
    // the wording free to be improved.
    expect(asked).toContain('stops')
    expect(asked).toContain('does not come back')
  })

  it('calls it deleting, not closing', () => {
    /*
     * This assertion is newer than the sentence it guards, and it is here
     * because the word was picked over the obvious one on purpose:
     *
     * > *"Close might be confusing for the people — they just think okay it will
     * > be just close, soft close or something. But delete, they know that click
     * > it will go away completely."*
     *
     * The wire verb is still `close` — the frame is unchanged and older hosts
     * still answer it — so the only place the decision is visible is this
     * sentence and the buttons that quote it. The word being *absent* is pinned
     * as well as the word being present, because the failure this guards against
     * is somebody restoring the old label while the new one is still written
     * down elsewhere.
     */
    const asked = closeQuestion(session({ title: 'terminaldeck' }))
    expect(asked).toContain('Delete')
    expect(asked).not.toContain('Close')
  })

  it('asks about the row it is on, not about “this session”', () => {
    // A confirmation that could not name what it is about is a confirmation
    // people answer by reflex — and this one is drawn in a list where the row
    // above and the row below look almost identical.
    expect(closeQuestion(session({ title: 'invoices-api' }))).toContain('invoices-api')
    expect(closeQuestion(session({ title: 'invoices-web' }))).toContain('invoices-web')
  })
})

describe('naming a session from a browser', () => {
  it('is offered only by a machine that advertised the verb', () => {
    // An older desktop never sends the name, so the row is absent rather than
    // drawn and refused — the rule every capability in this client follows.
    expect(renameOffered(['localhost', 'create', 'close'])).toBe(false)
    expect(renameOffered(['create', 'close', 'rename'])).toBe(true)
  })

  it('is not implied by being able to end one', () => {
    /*
     * The two are separate methods at the far end and separate answers here.
     * Both directions are real: a host that hands strangers a shell can refuse
     * to end one and still let somebody label the one they are looking at, and a
     * host whose session layer has no writable title cannot take a name however
     * freely it closes things.
     */
    expect(renameOffered(['close'])).toBe(false)
    expect(closeOffered(['rename'])).toBe(false)
  })

  it('says both of the things an empty field cannot say for itself', () => {
    // A name crosses the wire rather than staying in this browser, and saving
    // nothing is an instruction rather than a cancel. Neither is guessable from
    // looking at the box, which is the whole reason this line exists.
    expect(RENAME_NOTE).toContain('Every device')
    expect(RENAME_NOTE).toContain('empty')
    expect(RENAME_NOTE).toContain('folder')
  })
})
