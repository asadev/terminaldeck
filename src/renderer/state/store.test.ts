import { describe, expect, it } from 'vitest'
import { withReplacedSession, withSessionTitle, type Session } from './store'

/**
 * The rule that makes renaming a session mean anything.
 *
 * A session is titled from three places over its life: the folder name at
 * creation, `AutoTitler` reading the agent's own output on every pause in that
 * output, and — since the rename field in the sidebar — the person using the
 * app. The first two are guesses that improve; the third is not a guess. The
 * only interesting question in the whole feature is what happens when the
 * second arrives after the third, and it arrives *constantly*: `titleFor` runs
 * at most every 250ms for as long as the agent is printing.
 *
 * Pinned here rather than through the provider because this project has no DOM
 * in its test setup, and a rule living inside a `useCallback` inside a context
 * provider is a rule with no test. That is why the function exists apart from
 * the hook that calls it.
 */

const session = (over: Partial<Session> = {}): Session => ({
  id: 's1',
  title: 'terminaldeck',
  cwd: '/Users/apple/Projects/terminaldeck',
  createdAt: 0,
  exitCode: null,
  provider: 'claude',
  projectPath: '/Users/apple/Projects/terminaldeck',
  status: 'idle',
  statusSince: 0,
  ...over,
})

const titleOf = (sessions: Session[], id = 's1'): string | undefined =>
  sessions.find((one) => one.id === id)?.title

describe('a name somebody typed', () => {
  it('replaces whatever the session was called', () => {
    const next = withSessionTitle([session()], 's1', 'Relay handshake', true)
    expect(titleOf(next)).toBe('Relay handshake')
    expect(next[0].namedByUser).toBe(true)
  })

  it('survives the auto-titler, which arrives seconds later and never stops', () => {
    /*
     * The defect this whole flag exists to prevent, and the reason the task
     * called it the substance rather than the polish: without it, a session
     * renamed at 14:00:00 was called something else again by 14:00:03, and the
     * app looked like it had *lost* the name rather than like it had never
     * offered to keep one.
     */
    const named = withSessionTitle([session()], 's1', 'Relay handshake', true)
    const derived = withSessionTitle(named, 's1', 'Fix the parser tests')
    expect(titleOf(derived)).toBe('Relay handshake')
    // The same array back, so the sidebar does not even re-render for it —
    // this runs on every pause in the session's output.
    expect(derived).toBe(named)
  })

  it('holds against every later derivation, not just the next one', () => {
    let sessions = withSessionTitle([session()], 's1', 'Relay handshake', true)
    for (const guess of ['Fix the parser', 'Add the picker', 'terminaldeck', 'Ship 0.2.0']) {
      sessions = withSessionTitle(sessions, 's1', guess)
    }
    expect(titleOf(sessions)).toBe('Relay handshake')
  })

  it('can still be renamed again, by hand', () => {
    const once = withSessionTitle([session()], 's1', 'Relay handshake', true)
    const twice = withSessionTitle(once, 's1', 'Relay handshake, part two', true)
    expect(titleOf(twice)).toBe('Relay handshake, part two')
    expect(twice[0].namedByUser).toBe(true)
  })

  it('latches even when it names the session what it was already called', () => {
    // Typing the folder name into the field on purpose is a rename, and the
    // session must stay named afterwards — otherwise the one name the auto
    // titler is most likely to overwrite is the one somebody chose to keep.
    const next = withSessionTitle([session({ title: 'terminaldeck' })], 's1', 'terminaldeck', true)
    expect(next[0].namedByUser).toBe(true)
  })
})

describe('a title the app worked out for itself', () => {
  it('takes a session that nobody has named', () => {
    const next = withSessionTitle([session()], 's1', 'Fix the parser tests')
    expect(titleOf(next)).toBe('Fix the parser tests')
    expect(next[0].namedByUser).toBeUndefined()
  })

  it('does not rebuild the list when it says what is already there', () => {
    // `AutoTitler` re-derives the same answer for as long as the same heading
    // is on the agent's screen, and mapping the array each time would rebuild
    // every consumer's memo for a no-op.
    const before = [session({ title: 'Fix the parser tests' })]
    expect(withSessionTitle(before, 's1', 'Fix the parser tests')).toBe(before)
  })
})

describe('a session that is not there', () => {
  it('is not invented by retitling it', () => {
    // A title can arrive for a session that has just been closed — the pty's
    // last chunk and the tab's removal race — and the old implementation would
    // simply not match anything. This says so on purpose rather than by luck.
    const before = [session()]
    expect(withSessionTitle(before, 'gone', 'Anything', true)).toBe(before)
    expect(withSessionTitle(before, 'gone', 'Anything')).toBe(before)
  })

  it('leaves its neighbours alone when one of them is renamed', () => {
    const before = [session(), session({ id: 's2', title: 'science-locus' })]
    const next = withSessionTitle(before, 's2', 'Term reports', true)
    expect(titleOf(next, 's1')).toBe('terminaldeck')
    expect(next[0]).toBe(before[0])
  })
})

/**
 * A session replaced in place, which is what switching an account looks like
 * from up here.
 *
 * A CLI is authenticated at spawn, so changing the account under a running agent
 * means stopping the process and starting another — and that produces a new
 * session id for what the person is still calling "this session". Everything
 * they can see is meant to survive it, which is a rule about *position* and
 * *identity* rather than about contents, and therefore invisible to a test that
 * only checks the list holds the right sessions.
 */
describe('one session standing in for another', () => {
  const meta = (over: Partial<Session> = {}): Session => session({ id: 's9', ...over })

  it('takes the old one’s place rather than the end of the list', () => {
    // Remove-then-add produces the right *set* and the wrong *order*, and the
    // difference is invisible until somebody with three sessions switches the
    // account on the first one and watches its row jump to the bottom.
    const before = [session(), session({ id: 's2' }), session({ id: 's3' })]
    const next = withReplacedSession(before, 's1', meta())
    expect(next.map((one) => one.id)).toEqual(['s9', 's2', 's3'])
  })

  it('keeps a name somebody typed', () => {
    const before = [session({ title: 'Relay handshake', namedByUser: true })]
    const next = withReplacedSession(before, 's1', meta({ title: 'terminaldeck' }))
    expect(next[0].title).toBe('Relay handshake')
    expect(next[0].namedByUser).toBe(true)
  })

  it('drops a name the app derived, because it describes output that is gone', () => {
    // `AutoTitler` reads a new one out of the new session's own output within
    // seconds. Carrying the old derivation across would leave a title describing
    // a conversation that is no longer on screen.
    const before = [session({ title: 'Fixing the relay' })]
    const next = withReplacedSession(before, 's1', meta({ title: 'app' }))
    expect(next[0].title).toBe('app')
    expect(next[0].namedByUser).toBeUndefined()
  })

  it('starts the status clock again, because this is a different process', () => {
    const before = [session({ status: 'working', statusSince: 1 })]
    const next = withReplacedSession(before, 's1', meta())
    expect(next[0].status).toBe('idle')
    expect(next[0].statusSince).toBeGreaterThan(1)
  })

  it('invents nothing when the session being replaced has gone', () => {
    // A caller that raced ahead of its own state would otherwise add a second
    // row for a session the window is about to be told about anyway.
    const before = [session()]
    expect(withReplacedSession(before, 'gone', meta())).toBe(before)
  })

  it('does nothing twice', () => {
    const before = [session(), session({ id: 's9' })]
    expect(withReplacedSession(before, 's1', meta())).toBe(before)
  })
})
