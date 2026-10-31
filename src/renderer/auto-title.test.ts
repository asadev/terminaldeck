import { describe, expect, it } from 'vitest'
import { AutoTitler, TITLE_RESCAN_MS, TITLE_WINDOW_BYTES } from './auto-title'

const CWD = '/Users/apple/Projects/terminaldeck'

/** A rule the way a coding CLI draws one, which is what `titleFromOutput` reads. */
const rule = (title: string): string => `\u001b[2m───── ${title} ──────────────\u001b[0m\r\n`

function clock(): { now: () => number; advance: (ms: number) => void } {
  let t = 1_000
  return { now: () => t, advance: (ms) => { t += ms } }
}

describe('AutoTitler', () => {
  it('says nothing about a session it has never seen', () => {
    expect(new AutoTitler().titleFor('s1', CWD)).toBeNull()
  })

  it('reads a title out of the terminal', () => {
    const titler = new AutoTitler()
    titler.record('s1', rule('Wire the notification engine'))
    expect(titler.titleFor('s1', CWD)).toBe('Wire the notification engine')
  })

  it('returns null rather than the folder name', () => {
    // The folder is what the session is already called, so "nothing better than
    // the folder" has to be indistinguishable from "nothing at all" — the
    // caller renames on a non-null answer and does nothing otherwise.
    const titler = new AutoTitler()
    titler.record('s1', 'npm test\r\n  3728 passed\r\n')
    expect(titler.titleFor('s1', CWD)).toBeNull()
  })

  it('does not rescan within the rate limit', () => {
    const time = clock()
    const titler = new AutoTitler(time.now)
    titler.record('s1', rule('First name'))
    expect(titler.titleFor('s1', CWD)).toBe('First name')

    titler.record('s1', rule('Second name'))
    expect(titler.titleFor('s1', CWD)).toBeNull()

    time.advance(TITLE_RESCAN_MS)
    expect(titler.titleFor('s1', CWD)).toBe('Second name')
  })

  it('keeps only the tail of a long-running session', () => {
    const titler = new AutoTitler()
    titler.record('s1', 'x'.repeat(TITLE_WINDOW_BYTES * 2))
    titler.record('s1', rule('Still readable'))
    expect(titler.titleFor('s1', CWD)).toBe('Still readable')
  })

  it('keeps sessions apart', () => {
    const time = clock()
    const titler = new AutoTitler(time.now)
    titler.record('s1', rule('One'))
    titler.record('s2', rule('Two'))
    expect(titler.titleFor('s1', CWD)).toBe('One')
    expect(titler.titleFor('s2', CWD)).toBe('Two')
  })

  it('forgets a closed session', () => {
    const time = clock()
    const titler = new AutoTitler(time.now)
    titler.record('s1', rule('Gone'))
    titler.forget('s1')
    expect(titler.titleFor('s1', CWD)).toBeNull()
  })
})
