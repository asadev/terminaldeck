import { afterEach, describe, expect, it } from 'vitest'
import {
  bufferReader,
  clearTerminals,
  findTerminal,
  registerTerminal,
  terminalHostRect,
  terminalMetrics,
  terminalUnavailable,
  viewportLine,
  type DriveBuffer,
  type DriveTerminal,
  type RegisteredTerminal,
} from './terminal-registry'
import type { Rect } from './geometry'

const box = (rect: Rect) => ({
  getBoundingClientRect: () => ({
    left: rect.x,
    top: rect.y,
    width: rect.width,
    height: rect.height,
  }),
})

const NOOP = { dispose: () => undefined }

function entry(
  lines: readonly string[],
  screen: Rect | null = { x: 448, y: 186, width: 850, height: 743 },
  buffer: Partial<DriveBuffer> = {},
): RegisteredTerminal {
  const term: DriveTerminal = {
    cols: 109,
    rows: 33,
    element: {
      querySelector: (selector: string) =>
        selector === '.xterm-screen' && screen !== null ? box(screen) : null,
    } as unknown as HTMLElement,
    buffer: {
      active: {
        type: 'normal',
        viewportY: 0,
        baseY: 0,
        length: lines.length,
        getLine: (index) =>
          index >= 0 && index < lines.length
            ? { translateToString: () => lines[index] }
            : undefined,
        ...buffer,
      },
    },
    onRender: () => NOOP,
    onResize: () => NOOP,
    scrollToLine: () => undefined,
  }
  return { term, host: box({ x: 448, y: 160, width: 868, height: 790 }) as unknown as HTMLElement }
}

afterEach(clearTerminals)

describe('registration', () => {
  it('finds a registered terminal and forgets it on unregister', () => {
    const one = entry(['a'])
    const off = registerTerminal('s1', one)
    expect(findTerminal('s1')).toBe(one)
    off()
    expect(findTerminal('s1')).toBeNull()
  })

  /*
   * React can mount the replacement `TerminalView` for a re-keyed session before
   * it runs the old one's cleanup. An id-keyed delete would then wipe the entry
   * the new component had just written, and the overlay would report the
   * session as having no terminal while one was plainly on screen. The closure
   * checks identity, so a stale cleanup is a no-op.
   */
  it('a stale unregister cannot delete a newer registration', () => {
    const old = entry(['a'])
    const off = registerTerminal('s1', old)
    const fresh = entry(['b'])
    registerTerminal('s1', fresh)
    off()
    expect(findTerminal('s1')).toBe(fresh)
  })
})

describe('what it reports as unavailable', () => {
  it('names a session with nothing mounted', () => {
    expect(terminalUnavailable('nope')).toBe('not-registered')
  })

  /*
   * A hidden tab keeps its terminal mounted under `display: none`, where every
   * rectangle is zero but `cols`/`rows` still hold their last values. That is
   * "not rendered", not "at the origin with no size" — reporting it as geometry
   * would put a box at 0,0.
   */
  it('names a pane that is mounted but not laid out', () => {
    registerTerminal('s1', entry(['a'], { x: 0, y: 0, width: 0, height: 0 }))
    expect(terminalUnavailable('s1')).toBe('not-rendered')
    expect(terminalMetrics('s1')).toBeNull()
  })

  it('names a terminal with no xterm DOM yet', () => {
    registerTerminal('s1', entry(['a'], null))
    expect(terminalUnavailable('s1')).toBe('not-rendered')
  })

  it('names the alternate screen buffer, where there is nothing to anchor to', () => {
    registerTerminal('s1', entry(['a'], { x: 0, y: 0, width: 800, height: 600 }, { type: 'alternate' }))
    expect(terminalUnavailable('s1')).toBe('alternate-buffer')
  })

  it('reports nothing wrong with a normal, rendered terminal', () => {
    registerTerminal('s1', entry(['a']))
    expect(terminalUnavailable('s1')).toBeNull()
  })
})

describe('what it measures', () => {
  it('takes the grid from the terminal and the box from .xterm-screen', () => {
    registerTerminal('s1', entry(['a']))
    expect(terminalMetrics('s1')).toEqual({
      screen: { x: 448, y: 186, width: 850, height: 743 },
      cols: 109,
      rows: 33,
    })
  })

  /*
   * `.xterm-screen` and not `.xterm` or `.xterm-viewport`. The latter two
   * include the scrollbar gutter — measured at 18 px on an 868 px pane — so
   * using either would put every column about a sixth of a cell to the left of
   * where it belongs: invisible at column 0, half a character out by column 100.
   */
  it('measures the screen, not the pane', () => {
    registerTerminal('s1', entry(['a']))
    expect(terminalMetrics('s1')!.screen.width).toBe(850)
    expect(terminalHostRect('s1')!.width).toBe(868)
  })

  it('reads lines back by absolute index and refuses the ones that are gone', () => {
    registerTerminal('s1', entry(['first', 'second']))
    const reader = bufferReader('s1')!
    expect(reader.end).toBe(2)
    expect(reader.cols).toBe(109)
    expect(reader.line(1)).toBe('second')
    expect(reader.line(9)).toBeNull()
    expect(reader.line(-1)).toBeNull()
  })

  it('reports the line at the top of the viewport', () => {
    registerTerminal('s1', entry(['a', 'b', 'c'], undefined, { viewportY: 2 }))
    expect(viewportLine('s1')).toBe(2)
    expect(viewportLine('nope')).toBeNull()
  })
})
