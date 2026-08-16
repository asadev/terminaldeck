import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { portSummary, readPorts, StartPage, type StartPageBridge } from './StartPage'

/**
 * The recording of 2026-08-16: a new tab on Windows opened onto Chromium's red
 * "connection refused" document. These pin the page that stands in its place —
 * the ports that are genuinely listening, and an address field for everything
 * else.
 *
 * There is no DOM in this project's test run, so effects do not fire: the render
 * cases below are the *loading* state by construction, which is the right thing
 * to hold to a contract anyway — it is what a person sees first.
 */

const noPorts: StartPageBridge = { devPorts: async () => [] }

describe('readPorts', () => {
  it('reads what the main process actually sends', () => {
    expect(
      readPorts([
        { port: 5037, process: 'adb', guessed: false },
        { port: 57211, process: 'Terminal', guessed: false },
      ]),
    ).toEqual([
      { port: 5037, process: 'adb', guessed: false },
      { port: 57211, process: 'Terminal', guessed: false },
    ])
  })

  it('puts the ports nobody could name last, then orders by number', () => {
    const rows = readPorts([
      { port: 9000, process: '', guessed: true },
      { port: 5173, process: 'node', guessed: false },
      { port: 3000, process: 'node', guessed: false },
    ])
    expect(rows.map((row) => row.port)).toEqual([3000, 5173, 9000])
  })

  it('survives anything at all coming back across the bridge', () => {
    // The channel is typed `unknown` on purpose, so this is the only guard.
    expect(readPorts(null)).toEqual([])
    expect(readPorts('nope')).toEqual([])
    expect(readPorts([null, 7, { port: 'x' }, { port: -1 }, {}])).toEqual([])
  })

  it('takes a numeric string, because JSON is not a type system', () => {
    expect(readPorts([{ port: '3000', process: 'node' }])).toEqual([
      { port: 3000, process: 'node', guessed: false },
    ])
  })
})

describe('portSummary', () => {
  it('reads the way the operating system named it', () => {
    // "5037 adb" and "57211 Terminal" are literally what `lsof -nP -iTCP
    // -sTCP:LISTEN` printed on the machine this was written on, which is why
    // nothing here prettifies or maps the name through a table of frameworks.
    expect(portSummary({ port: 5037, process: 'adb', guessed: false })).toBe('5037 adb')
    expect(portSummary({ port: 57211, process: 'Terminal', guessed: false })).toBe('57211 Terminal')
  })

  it('says the port alone rather than inventing a name for it', () => {
    expect(portSummary({ port: 9000, process: '', guessed: true })).toBe('9000')
  })
})

describe('the new-tab page', () => {
  const html = renderToStaticMarkup(<StartPage onOpen={() => undefined} bridge={noPorts} />)

  it('offers an address field, so a new tab is never a dead end', () => {
    expect(html).toContain('aria-label="Address"')
    expect(html).toContain('Open')
  })

  it('does not claim anything failed', () => {
    expect(html).toContain('Open a page')
    expect(html).not.toContain('did not open')
  })
})

describe('the page that replaces Chromium’s error document', () => {
  const html = renderToStaticMarkup(
    <StartPage
      onOpen={() => undefined}
      bridge={noPorts}
      failure={{
        message: 'Nothing is listening on localhost:3000. Start the server, then reload.',
        url: 'http://localhost:3000/',
      }}
      onRetry={() => undefined}
    />,
  )

  it('shows the written sentence rather than a Chromium constant', () => {
    expect(html).toContain('Nothing is listening on localhost:3000')
    expect(html).not.toContain('ERR_')
  })

  it('keeps the address field, which is the way out of a failed page', () => {
    expect(html).toContain('aria-label="Address"')
  })

  it('offers to try the same address again, naming it', () => {
    expect(html).toContain('http://localhost:3000/')
    expect(html).toMatch(/Try .* again/)
  })

  it('hides Try again rather than disabling it when there is no way to retry', () => {
    const noRetry = renderToStaticMarkup(
      <StartPage
        onOpen={() => undefined}
        bridge={noPorts}
        failure={{ message: 'It broke.', url: 'http://localhost:3000/' }}
      />,
    )
    expect(noRetry).not.toMatch(/Try .* again/)
  })
})

describe('a build with no port discovery', () => {
  it('says so instead of showing an empty list forever', () => {
    // Effects do not run here, so this is asserted through the branch that is
    // reachable in static markup: the page must never render a bare list with
    // no explanation of why it is empty.
    const html = renderToStaticMarkup(<StartPage onOpen={() => undefined} bridge={noPorts} />)
    expect(html).toContain('Looking for dev servers')
  })
})
