import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  SWARM_MIN_CELL_WIDTH,
  SwarmGrid,
  shouldRequestFocus,
  swarmColumns,
  swarmRows,
  type SwarmSession,
} from './SwarmGrid'

/**
 * There is no DOM environment in this project's test setup, so the component
 * cases render to static markup. That still pins the parts most likely to rot
 * silently: the grid tracks, the focus marker and the accessible cell header.
 */

const sessions: SwarmSession[] = [
  { id: 's1', title: 'terminaldeck', status: 'working' },
  { id: 's2', title: 'science-locus', status: 'input' },
  { id: 's3', title: 'engineerings-pk', status: 'idle' },
]

function render(props: Partial<Parameters<typeof SwarmGrid>[0]> = {}): string {
  return renderToStaticMarkup(
    <SwarmGrid
      sessions={sessions}
      activeSessionId="s2"
      onFocusSession={() => {}}
      renderCell={({ session }) => <i>{`terminal:${session.id}`}</i>}
      {...props}
    />,
  )
}

describe('swarmColumns', () => {
  it('keeps the grid square when width allows', () => {
    const wide = 4000
    expect(swarmColumns(1, wide)).toBe(1)
    expect(swarmColumns(2, wide)).toBe(2)
    expect(swarmColumns(4, wide)).toBe(2)
    expect(swarmColumns(5, wide)).toBe(3)
    expect(swarmColumns(9, wide)).toBe(3)
    expect(swarmColumns(10, wide)).toBe(4)
    expect(swarmColumns(16, wide)).toBe(4)
  })

  it('drops columns rather than showing unreadable slivers', () => {
    // 700px fits two 320px cells, so a nine-session swarm stops at two
    // columns instead of the three a square grid would ask for.
    expect(swarmColumns(9, 700)).toBe(2)
    expect(swarmColumns(9, 640)).toBe(2)
    expect(swarmColumns(9, 639)).toBe(1)
    expect(swarmColumns(4, 500)).toBe(1)
  })

  it('never goes below one column, however cramped', () => {
    expect(swarmColumns(9, 50)).toBe(1)
    expect(swarmColumns(2, 1)).toBe(1)
  })

  it('never has more columns than sessions', () => {
    expect(swarmColumns(2, 5000)).toBe(2)
    expect(swarmColumns(3, 5000)).toBe(2)
  })

  it('assumes width is not the constraint until it has been measured', () => {
    // First paint has no measurement; guessing one column would reflow every
    // terminal a frame later.
    expect(swarmColumns(9, 0)).toBe(3)
    expect(swarmColumns(9, Number.NaN)).toBe(3)
    expect(swarmColumns(9, -100)).toBe(3)
  })

  it('honours a custom minimum cell width', () => {
    expect(swarmColumns(4, 800, 200)).toBe(2)
    expect(swarmColumns(4, 800, 400)).toBe(2)
    expect(swarmColumns(4, 800, 500)).toBe(1)
    expect(swarmColumns(4, 800, 0)).toBe(2)
  })

  it('handles an empty swarm', () => {
    expect(swarmColumns(0, 1000)).toBe(1)
    expect(swarmRows(0, 1)).toBe(0)
  })

  it('rounds rows up so no session is left off the grid', () => {
    expect(swarmRows(9, 3)).toBe(3)
    expect(swarmRows(5, 3)).toBe(2)
    expect(swarmRows(7, 3)).toBe(3)
    expect(swarmRows(3, 0)).toBe(0)
  })

  it('always has room for every session', () => {
    for (let count = 1; count <= 40; count++) {
      for (const width of [0, 300, 640, 1280, 1920, 3840]) {
        const columns = swarmColumns(count, width)
        expect(columns * swarmRows(count, columns)).toBeGreaterThanOrEqual(count)
        expect(columns).toBeGreaterThanOrEqual(1)
        if (width >= SWARM_MIN_CELL_WIDTH) {
          expect(width / columns).toBeGreaterThanOrEqual(SWARM_MIN_CELL_WIDTH)
        }
      }
    }
  })

  // Regression: the gutters between columns used to be counted as usable cell
  // width, so a "fitting" column count handed out cells under the minimum.
  it('pays for the gutters between columns out of the width', () => {
    // 960px minus two 6px gutters is 948, which is three 316px slivers.
    expect(swarmColumns(9, 960, SWARM_MIN_CELL_WIDTH, 6)).toBe(2)
    expect(swarmColumns(9, 972, SWARM_MIN_CELL_WIDTH, 6)).toBe(3)
    expect(swarmColumns(9, 640, SWARM_MIN_CELL_WIDTH, 6)).toBe(1)
    expect(swarmColumns(9, 646, SWARM_MIN_CELL_WIDTH, 6)).toBe(2)
  })

  it('never sizes a cell below the minimum, gutters included', () => {
    for (let count = 1; count <= 40; count++) {
      for (const width of [0, 300, 640, 960, 1280, 1920, 3840]) {
        for (const gap of [0, 6, 24]) {
          const columns = swarmColumns(count, width, SWARM_MIN_CELL_WIDTH, gap)
          expect(columns).toBeGreaterThanOrEqual(1)
          expect(columns * swarmRows(count, columns)).toBeGreaterThanOrEqual(count)
          if (width >= SWARM_MIN_CELL_WIDTH && columns > 1) {
            const cell = (width - (columns - 1) * gap) / columns
            expect(cell).toBeGreaterThanOrEqual(SWARM_MIN_CELL_WIDTH)
          }
        }
      }
    }
  })

  it('treats a nonsense gap as no gap rather than poisoning the maths', () => {
    expect(swarmColumns(9, 960, SWARM_MIN_CELL_WIDTH, Number.NaN)).toBe(3)
    expect(swarmColumns(9, 960, SWARM_MIN_CELL_WIDTH, -50)).toBe(3)
    expect(swarmColumns(9, 960, SWARM_MIN_CELL_WIDTH, Number.POSITIVE_INFINITY)).toBe(3)
  })
})

describe('shouldRequestFocus', () => {
  // Regression: one click fires the pointer-down capture, the focus capture and
  // the header button's click. On the cell that already has focus all three
  // used to reach the host, on every click and every tab into it.
  it('stays quiet about the session that is already focused', () => {
    const calls: string[] = []
    const request = (id: string) => {
      if (shouldRequestFocus('s2', id)) calls.push(id)
    }

    request('s2')
    request('s2')
    request('s2')
    expect(calls).toEqual([])

    request('s1')
    expect(calls).toEqual(['s1'])
  })

  it('still asks when nothing is focused yet', () => {
    expect(shouldRequestFocus(null, 's1')).toBe(true)
  })
})

describe('SwarmGrid', () => {
  it('renders one cell per session with its title and status', () => {
    const html = render()
    expect(html).toContain('terminal:s1')
    expect(html).toContain('terminal:s2')
    expect(html).toContain('terminal:s3')
    expect(html).toContain('science-locus')
    expect(html).toContain('aria-label="Working"')
    expect(html).toContain('aria-label="Needs input"')
  })

  it('marks only the active session as focused', () => {
    const html = render()
    expect(html).toContain('data-focused="true" data-session-id="s2"')
    expect(html).toContain('data-focused="false" data-session-id="s1"')
    expect(html.match(/data-focused="true"/g)).toHaveLength(1)
    expect(html).toContain('aria-current="true"')
  })

  it('lays the grid out before the first measurement', () => {
    // Unmeasured, three sessions take a 2×2 grid with one slot spare.
    const html = render()
    expect(html).toContain('repeat(2, minmax(0, 1fr))')
    expect(html).toContain('data-columns="2"')
    expect(html.match(/swarm-spare/g)).toBeTruthy()
  })

  it('offers a new-session button in leftover slots only when it can act', () => {
    expect(render()).not.toContain('swarm-spare-add')
    expect(render({ onNewSession: () => {} })).toContain('aria-label="New session"')
  })

  it('leaves no spare slots when the grid is exactly full', () => {
    const html = render({ sessions: sessions.slice(0, 2), onNewSession: () => {} })
    expect(html).not.toContain('swarm-spare')
  })

  it('falls back to the empty state with nothing running', () => {
    const html = render({ sessions: [], empty: <p>No sessions</p> })
    expect(html).toContain('No sessions')
    expect(html).toContain('swarm-grid-empty')
    expect(html).not.toContain('swarm-cell')
  })
})
