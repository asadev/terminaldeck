import { describe, expect, it } from 'vitest'
import { containsQuote, needleOf, normalizeLine, stripAnsi } from './quote-match'

const ESC = '\u001b'
const BEL = '\u0007'

/**
 * The check that decides whether a quote can be shown at all.
 *
 * Every case below is either a real line off this machine or the exact shape of
 * a defect that was measured live. The two marked so were both found by driving
 * a real tour against a real pty and watching honest stops get dropped — which
 * is the class of bug this file exists to stop coming back, because it fails
 * *quietly*: the tour still plays, it is just shorter than it should be, and
 * nothing on screen says which half of the check was wrong.
 */
describe('normalising a line', () => {
  it('collapses the padding a terminal writes to the column width', () => {
    expect(normalizeLine('done' + ' '.repeat(105))).toBe('done')
  })

  it('turns stray control characters into a space rather than keeping them', () => {
    expect(normalizeLine(`a${'\u0001'}b`)).toBe('a b')
  })

  it('does not fold case, because ERROR and error are different events', () => {
    expect(normalizeLine('ERROR')).not.toBe(normalizeLine('error'))
  })

  it('takes the first non-empty line as the needle, cut to the needle length', () => {
    expect(needleOf('\n\n  the failing line  \nand more')).toBe('the failing line')
    expect(needleOf('x'.repeat(200))).toHaveLength(64)
  })

  it('has no needle for a quote with nothing printable in it', () => {
    expect(needleOf('   \n\t\n')).toBe('')
  })
})

describe('stripping what a terminal never showed', () => {
  it('removes a colour run', () => {
    expect(stripAnsi(`${ESC}[32m+${ESC}[m`)).toBe('+')
  })

  it('removes a window-title sequence, payload and all', () => {
    // Claude Code sets its title on almost every turn, so this is the common
    // case rather than the exotic one.
    expect(stripAnsi(`${ESC}]0;a title${BEL}ready`)).toBe('ready')
  })

  it('removes a title terminated by a string terminator rather than a bell', () => {
    expect(stripAnsi(`${ESC}]2;t${ESC}\\ready`)).toBe('ready')
  })

  it('removes the two-character escapes', () => {
    expect(stripAnsi(`${ESC}(Bplain`)).toBe('plain')
  })

  it('leaves text that merely looks like an escape alone', () => {
    expect(stripAnsi('cost [32m per token')).toBe('cost [32m per token')
  })
})

describe('finding a quote in a haystack', () => {
  it('finds a line that is really there', () => {
    const screen = 'running tests\n✖ a token issued at the boundary has not expired yet (0.4ms)\n'
    expect(containsQuote(screen, '✖ a token issued at the boundary has not expired yet')).toBe(true)
  })

  it('refuses a line that was never there', () => {
    const screen = '✖ one test failed\n'
    expect(containsQuote(screen, 'All 24 tests passed in 1.2 seconds')).toBe(false)
  })

  it('matches on the first line only, so a repaint that ate the tail still counts', () => {
    // Real behaviour of every agent CLI: the head of a passage survives and the
    // last lines are overwritten. Dropping the stop over line four would lose a
    // real thing to a cosmetic difference.
    const screen = 'the heading is here\nsomething else entirely\n'
    expect(containsQuote(screen, 'the heading is here\nline two\nline three')).toBe(true)
  })

  it('refuses a quote whose first line was never there, whatever else matches', () => {
    const screen = 'line two\nline three\n'
    expect(containsQuote(screen, 'the heading is here\nline two')).toBe(false)
  })

  it('finds a line a CLI redrew in place with a bare carriage return', () => {
    // A pty carries `\r` with no `\n` when a spinner rewrites its own line, so
    // splitting on newlines alone glues two logical lines into one string.
    expect(containsQuote('spinner...\rfinal answer here', 'final answer here')).toBe(true)
  })

  it('never matches an empty quote', () => {
    expect(containsQuote('anything at all', '   ')).toBe(false)
  })

  /*
   * MEASURED DEFECT. `deck-control/tour.ts` verifies a `screen` quote against the
   * retained pty scrollback, which is what the process *wrote* rather than what
   * xterm *drew*. On a real tour against a real shell, every uncoloured line
   * matched and every coloured one was dropped as "not there" — so the tour lost
   * exactly the stops worth showing, because the interesting lines are the ones
   * a CLI colours. The fix is that the caller strips first; this pins that the
   * two halves fit together.
   */
  it('needs the escapes stripped first, and matches once they are', () => {
    const raw = ` package.json      |  2 ${ESC}[32m+${ESC}[m${ESC}[31m-${ESC}[m\n`
    const quote = ' package.json      |  2 +-'
    expect(containsQuote(raw, quote)).toBe(false)
    expect(containsQuote(stripAnsi(raw), quote)).toBe(true)
  })
})
