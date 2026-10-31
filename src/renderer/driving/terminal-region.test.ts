import { describe, expect, it } from 'vitest'
import {
  cellSize,
  locateQuote,
  MAX_REGION_LINES,
  needleOf,
  normalizeLine,
  regionRect,
  SEARCH_BACK,
  type BufferReader,
  type BufferRegion,
  type TerminalMetrics,
} from './terminal-region'

/**
 * The one geometry in this feature that cannot be measured from a DOM node, so
 * the one that has to be arithmetic — and therefore the one that can be held
 * still by a test.
 *
 * Every number below came off the running app rather than out of the type
 * definitions: a 33-row terminal at a 850x743 `.xterm-screen`, whose rows
 * measure 22.5152 px each. 743 / 33 = 22.5152 exactly, which is the fact the
 * whole mapping rests on.
 */

const REAL: TerminalMetrics = {
  screen: { x: 448, y: 186, width: 850, height: 743 },
  cols: 109,
  rows: 33,
}

const region = (over: Partial<BufferRegion> = {}): BufferRegion => ({
  line: 0,
  lines: 1,
  startCol: 0,
  endCol: 109,
  ...over,
})

describe('the cell size is measured, never assumed', () => {
  it('divides the screen box by the grid', () => {
    const cell = cellSize(REAL)
    expect(cell?.height).toBeCloseTo(22.5152, 4)
    expect(cell?.width).toBeCloseTo(850 / 109, 6)
  })

  /*
   * A hidden tab keeps its terminal mounted under `display: none`, where every
   * rectangle is zero but `cols`/`rows` still hold their last values. Dividing
   * by that is `Infinity` in one direction and zero in the other, and either
   * one puts a box at a coordinate no clip can rescue.
   */
  it('refuses to divide by a pane that is not laid out', () => {
    expect(cellSize({ ...REAL, screen: { x: 0, y: 0, width: 0, height: 0 } })).toBeNull()
    expect(cellSize({ ...REAL, rows: 0 })).toBeNull()
  })
})

describe('scrolling and new output are the same subtraction', () => {
  it('puts the first buffer line at the top row when the terminal is at the top', () => {
    const placed = regionRect(region({ line: 0, lines: 3 }), 0, REAL)
    expect(placed?.rect.y).toBeCloseTo(186, 5)
    expect(placed?.rect.height).toBeCloseTo(22.5152 * 3, 3)
  })

  /*
   * The reader scrolls up: `viewportY` falls, and the same content moves DOWN
   * the screen. Nothing about this case is written anywhere in the source; it
   * falls out of `line - viewportY`, which is the point.
   */
  it('moves a region down when the reader scrolls up', () => {
    const high = regionRect(region({ line: 500 }), 500, REAL)
    const scrolledUp = regionRect(region({ line: 500 }), 490, REAL)
    expect(scrolledUp!.rect.y).toBeGreaterThan(high!.rect.y)
    expect(scrolledUp!.rect.y - high!.rect.y).toBeCloseTo(22.5152 * 10, 3)
  })

  /*
   * New output on a terminal following its tail: `viewportY` rises, so the
   * quoted passage moves UP and eventually off the top. That is not a bug to
   * correct — the content really did move — and the answer is that the box goes
   * with it and then reports itself gone.
   */
  it('carries a region up and off the screen as output arrives', () => {
    const at = (viewportY: number) => regionRect(region({ line: 100, lines: 4 }), viewportY, REAL)
    expect(at(100)!.rect.y).toBeCloseTo(186, 5)

    /*
     * Two of the four lines have gone past the top. The *clipped* rectangle
     * still starts at the pane's own top edge — there is nowhere else for a
     * visible rectangle to start — so what proves the region moved is that it
     * lost two lines of height and its top border, not that its y changed.
     * Asserting on y here is the mistake that makes a passing test of a broken
     * clip.
     */
    expect(at(102)!.rect.y).toBeCloseTo(186, 5)
    expect(at(102)!.rect.height).toBeCloseTo(22.5152 * 2, 3)
    expect(at(102)!.edges.top).toBe(false)
    expect(at(102)!.edges.bottom).toBe(true)

    // All four have gone past the top.
    expect(at(104)).toBeNull()
  })

  it('clips a region that runs past the foot of the pane', () => {
    const placed = regionRect(region({ line: 30, lines: 20 }), 0, REAL)
    expect(placed?.edges.bottom).toBe(false)
    expect(placed!.rect.y + placed!.rect.height).toBeCloseTo(186 + 743, 3)
  })

  it('lands a column at the right x', () => {
    const placed = regionRect(region({ startCol: 10, endCol: 20 }), 0, REAL)
    expect(placed?.rect.x).toBeCloseTo(448 + (850 / 109) * 10, 4)
    expect(placed?.rect.width).toBeCloseTo((850 / 109) * 10, 4)
  })

  /*
   * A resize that changes the font size or the window width changes the screen
   * box and the grid together, so the same region lands correctly with no code
   * that knows a resize happened. This is why the cell size is derived rather
   * than cached.
   */
  it('follows a resize with no state of its own', () => {
    const narrower: TerminalMetrics = {
      screen: { x: 300, y: 186, width: 600, height: 500 },
      cols: 80,
      rows: 24,
    }
    const placed = regionRect(region({ line: 5, lines: 2 }), 0, narrower)
    expect(placed?.rect.y).toBeCloseTo(186 + (500 / 24) * 5, 4)
    expect(placed?.rect.height).toBeCloseTo((500 / 24) * 2, 4)
  })
})

/* ---------------------------------------------------------------- locating */

function reader(lines: readonly string[], cols = 109): BufferReader {
  return {
    first: 0,
    end: lines.length,
    cols,
    line: (index) => (index >= 0 && index < lines.length ? lines[index] : null),
  }
}

describe('normalising a line', () => {
  it('collapses the padding a terminal writes and the indent a TUI writes', () => {
    expect(normalizeLine('   build   failed   ')).toBe('build failed')
  })

  it('drops control characters a quote may have picked up in transit', () => {
    expect(normalizeLine(`a${String.fromCharCode(7)}b${String.fromCharCode(27)}c`)).toBe('a b c')
  })

  /*
   * Case is deliberately kept. `ERROR` and `error` are different events in a
   * log, and the quote came out of this same buffer, so there is nothing to be
   * tolerant of and folding case could only ever find the wrong line.
   */
  it('keeps case', () => {
    expect(normalizeLine('ERROR')).not.toBe(normalizeLine('error'))
  })

  it('takes the first non-empty line as the needle', () => {
    expect(needleOf('\n\n  the real line  \nand more')).toBe('the real line')
    expect(needleOf('   ')).toBe('')
  })
})

describe('finding a quote in the buffer', () => {
  /*
   * The reason the scan runs backwards, stated as a test.
   *
   * Agent CLIs repaint: the same status line is written dozens of times in one
   * session and only the newest is the one on screen. A forward scan would
   * reliably box the oldest painting — a box in the wrong place, around real
   * text, which is the hardest kind of wrong to notice.
   */
  it('takes the most recent of several identical repaints', () => {
    const lines = ['Running tests', 'noise', 'Running tests', 'noise', 'Running tests']
    expect(locateQuote(reader(lines), 'Running tests')?.line).toBe(4)
  })

  it('matches through the padding a terminal adds', () => {
    const found = locateQuote(reader(['', '   npm test   failed    ', '']), 'npm test failed')
    expect(found?.line).toBe(1)
  })

  it('finds nothing for a quote that is not there', () => {
    expect(locateQuote(reader(['a', 'b']), 'c')).toBeNull()
  })

  it('finds nothing for an empty quote rather than matching every line', () => {
    expect(locateQuote(reader(['a', 'b']), '   ')).toBeNull()
  })

  it('covers the following lines of a multi-line quote', () => {
    const lines = ['head', 'Error: boom', '  at one', '  at two', 'tail']
    const found = locateQuote(reader(lines), 'Error: boom\n  at one\n  at two')
    expect(found).toMatchObject({ line: 1, lines: 3 })
  })

  /*
   * A bordered TUI puts a blank padding row between a heading and its body and
   * the transcript the quote came from does not. Failing the match there would
   * turn a three-line passage into a one-line box for a cosmetic reason.
   */
  it('steps over blank padding rows inside a passage', () => {
    const lines = ['x', 'Error: boom', '', '  at one', 'y']
    expect(locateQuote(reader(lines), 'Error: boom\n  at one')).toMatchObject({
      line: 1,
      lines: 3,
    })
  })

  /*
   * A repaint can truncate the tail of a passage: the first line survives and
   * the last three were overwritten. Boxing what is present beats reporting
   * nothing because line four went missing.
   */
  it('boxes the part that survived when the tail was overwritten', () => {
    const lines = ['Error: boom', '  at one', 'something else entirely']
    const found = locateQuote(reader(lines), 'Error: boom\n  at one\n  at two')
    expect(found).toMatchObject({ line: 0, lines: 2 })
  })

  it('never returns a region taller than the cap', () => {
    const body = Array.from({ length: 200 }, (_, i) => `line ${i}`)
    const quote = body.join('\n')
    const found = locateQuote(reader(body), quote)
    expect(found!.lines).toBeLessThanOrEqual(MAX_REGION_LINES)
  })

  /*
   * Beyond the main process's own 4 000-line retention there is nothing the
   * copilot could have read in order to quote it, so a match further back can
   * only be a coincidence.
   */
  it('does not search past the retention the main process keeps', () => {
    const lines = ['the needle', ...Array.from({ length: SEARCH_BACK + 50 }, () => 'filler')]
    expect(locateQuote(reader(lines), 'the needle')).toBeNull()
  })

  describe('the width of the box', () => {
    /*
     * A 109-column terminal showing a 40-character message must not get a box
     * with 69 columns of highlighted emptiness in it — that reads as a selected
     * row rather than as a pointer at a passage.
     */
    it('hugs the content rather than the terminal', () => {
      const found = locateQuote(reader(['short line']), 'short line')
      expect(found?.endCol).toBe('short line'.length + 1)
    })

    it('takes the longest line of a multi-line passage', () => {
      const lines = ['one', 'a much longer second line']
      const found = locateQuote(reader(lines), 'one\na much longer second line')
      expect(found?.endCol).toBe('a much longer second line'.length + 1)
    })

    it('never exceeds the terminal width', () => {
      const wide = 'x'.repeat(400)
      expect(locateQuote(reader([wide], 80), wide.slice(0, 60))?.endCol).toBe(80)
    })

    it('keeps a floor so a one-word line is not narrower than its own corner', () => {
      expect(locateQuote(reader(['ok']), 'ok')?.endCol).toBe(8)
    })
  })
})
