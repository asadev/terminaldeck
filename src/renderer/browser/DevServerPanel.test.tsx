import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  DevServerPanel,
  DevServerRow,
  mergeRow,
  projectName,
  readDevServer,
  readDevServers,
  type DevServerView,
} from './DevServerPanel'

/**
 * What this panel must never do is show a link to a server that is not there.
 *
 * There is no DOM in this project's test run, so effects do not fire and the
 * panel renders empty by construction — which is why the pieces that carry the
 * decisions are pure and exported. The two that would matter if somebody
 * rewrote this badly are {@link mergeRow}, where the tidier-looking
 * `{...old, ...new}` leaves a dead address under a live row, and
 * {@link readDevServers}, where a folder with no dev script has to become no row
 * rather than a disabled one.
 */

const IDLE: DevServerView = {
  folder: '/Users/asad/Projects/shop',
  status: 'idle',
  script: 'dev',
  command: 'pnpm run dev',
}

const READY: DevServerView = {
  ...IDLE,
  status: 'ready',
  sessionId: 's1',
  port: 5173,
  url: 'http://localhost:5173',
}

function markup(row: DevServerView): string {
  return renderToStaticMarkup(<DevServerRow row={row} onOpen={() => {}} onStart={() => {}} />)
}

describe('the four rows a person has to be able to tell apart', () => {
  it('idle shows the exact command it will run, and a button', () => {
    const html = markup(IDLE)
    // Nobody should have to trust this app about what it ran.
    expect(html).toContain('pnpm run dev')
    expect(html).toContain('Start')
    expect(html).toContain('aria-label="Start shop"')
    // And it is not offering a link yet.
    expect(html).not.toContain('localhost')
  })

  it('starting shows the server’s own latest line, not a phrase this app made up', () => {
    const note = 'VITE v7.1.0  ready in 412 ms'
    const html = markup({ ...IDLE, status: 'starting', sessionId: 's1', note })
    expect(html).toContain(note)
    expect(html).toContain('bw-dev-spinner')
    // Nothing to press while it is working.
    expect(html).not.toContain('<button')
  })

  it('starting with nothing printed yet still says it is working', () => {
    const html = markup({ ...IDLE, status: 'starting', sessionId: 's1' })
    expect(html).toContain('Starting')
    expect(html).toContain('role="status"')
  })

  it('ready is a link to the port that was proved, and says so', () => {
    const html = markup(READY)
    expect(html).toContain(':5173')
    expect(html).toContain('aria-label="Open shop on localhost port 5173"')
    expect(html).toContain('running')
  })

  it('a ready row with no url falls back to the idle row rather than a dead link', () => {
    // Belt and braces against a main process that ever sent an incomplete
    // `ready`. A row that says "running" and opens nothing is worse than a row
    // that offers to start it.
    const html = markup({ ...READY, url: undefined })
    expect(html).toContain('Start')
    expect(html).not.toContain(':5173')
  })

  it('failed shows the sentence the main process wrote and offers another go', () => {
    const message = 'Nothing accepted a connection within 90 seconds. The command is still running.'
    const html = markup({ ...IDLE, status: 'failed', sessionId: 's1', message })
    expect(html).toContain(message)
    expect(html).toContain('Try again')
  })

  it('every row carries its whole folder, so two projects named the same are tellable apart', () => {
    expect(markup(IDLE)).toContain('title="/Users/asad/Projects/shop"')
    expect(markup(READY)).toContain('title="/Users/asad/Projects/shop"')
  })
})

describe('a row never outlives its server', () => {
  it('replaces a row rather than merging into it', () => {
    // The session was killed, so the folder is idle again — and the row has to
    // lose the address with it. A merge would leave `:5173` under a row that is
    // offering to start something.
    const rows = mergeRow([READY], IDLE)
    expect(rows).toEqual([IDLE])
    expect(rows[0].url).toBeUndefined()
    expect(rows[0].port).toBeUndefined()
  })

  it('drops the row of a folder that has lost its dev script', () => {
    expect(mergeRow([IDLE], { folder: IDLE.folder, status: 'no-dev-script' })).toEqual([])
  })

  it('leaves other projects alone', () => {
    const other: DevServerView = { folder: '/Users/asad/Projects/api', status: 'idle', command: 'npm run dev' }
    const rows = mergeRow([IDLE, other], { ...IDLE, status: 'starting', sessionId: 's1' })
    expect(rows.map((row) => row.folder)).toEqual(['/Users/asad/Projects/api', '/Users/asad/Projects/shop'])
    expect(rows.find((row) => row.folder === other.folder)).toEqual(other)
  })

  it('keeps the order stable, so a row does not jump when it is pressed', () => {
    const api: DevServerView = { folder: '/p/api', status: 'idle', command: 'npm run dev' }
    const web: DevServerView = { folder: '/p/web', status: 'idle', command: 'npm run dev' }
    const before = mergeRow(mergeRow([], web), api).map((row) => row.folder)
    const after = mergeRow([api, web], { ...api, status: 'starting', sessionId: 's1' }).map((row) => row.folder)
    expect(after).toEqual(before)
  })
})

describe('the panel only exists when there is something behind it', () => {
  it('draws nothing when the preload does not expose the feature', () => {
    // A build whose preload predates this must not paint a control for it —
    // the same negotiation a phone gets from `welcome.capabilities`.
    expect(renderToStaticMarkup(<DevServerPanel onOpen={() => {}} bridge={{}} />)).toBe('')
  })

  it('draws nothing before it has any rows', () => {
    const bridge = { devServers: async () => [], startDevServer: async () => null }
    expect(renderToStaticMarkup(<DevServerPanel onOpen={() => {}} bridge={bridge} />)).toBe('')
  })
})

describe('nothing is trusted to be typed across the bridge', () => {
  it('drops a row with no folder', () => {
    expect(readDevServer({ status: 'idle' })).toBeNull()
    expect(readDevServer({ folder: '', status: 'idle' })).toBeNull()
  })

  it('drops a status this build does not know how to draw', () => {
    // A newer main process that grows a sixth state should produce a missing
    // row in an old window, never a row that lies about which state it is in.
    expect(readDevServer({ folder: '/p', status: 'installing' })).toBeNull()
  })

  it('drops fields of the wrong type rather than rendering them', () => {
    expect(readDevServer({ folder: '/p', status: 'ready', port: 'five', url: 12 })).toEqual({
      folder: '/p',
      status: 'ready',
    })
  })

  it('answers an empty list for anything that is not an array', () => {
    expect(readDevServers(null)).toEqual([])
    expect(readDevServers({ folder: '/p' })).toEqual([])
    expect(readDevServers('nope')).toEqual([])
  })

  it('filters no-dev-script out at the edge, once', () => {
    // Dropped here rather than at render time, so no later branch can forget to.
    const rows = readDevServers([IDLE, { folder: '/q', status: 'no-dev-script' }])
    expect(rows.map((row) => row.folder)).toEqual(['/Users/asad/Projects/shop'])
  })

  it('survives a row that is not an object at all', () => {
    expect(readDevServers([null, 7, 'x', IDLE])).toHaveLength(1)
  })
})

describe('projectName', () => {
  it('takes the last component of a POSIX path', () => {
    expect(projectName('/Users/asad/Projects/shop')).toBe('shop')
  })

  it('takes the last component of a Windows path', () => {
    // The renderer has no `path` module, and this string arrives from a Windows
    // main process as often as from a POSIX one.
    expect(projectName('C:\\Users\\Asad\\Projects\\shop')).toBe('shop')
  })

  it('ignores a trailing separator', () => {
    expect(projectName('/Users/asad/Projects/shop/')).toBe('shop')
  })
})
