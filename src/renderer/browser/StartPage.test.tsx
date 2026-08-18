import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import {
  offersDevServers,
  portSummary,
  readPorts,
  splitOwnPorts,
  StartPage,
  type PortSource,
  type StartPageBridge,
} from './StartPage'

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
      { port: 5037, process: 'adb', guessed: false, ours: false },
      { port: 57211, process: 'Terminal', guessed: false, ours: false },
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
      { port: 3000, process: 'node', guessed: false, ours: false },
    ])
  })
})

describe('portSummary', () => {
  it('reads the way the operating system named it', () => {
    // "5037 adb" and "57211 Terminal Deck" are literally what
    // `lsof -nP -iTCP -sTCP:LISTEN -FpcRtn` printed on the machine this was
    // written on, which is why nothing here prettifies or maps the name through
    // a table of frameworks. The column form of the same scan clamps the second
    // one to `Terminal`, and eight rows of that is the list he was shown.
    expect(portSummary({ port: 5037, process: 'adb', guessed: false, ours: false })).toBe('5037 adb')
    expect(
      portSummary({ port: 57211, process: 'Terminal Deck', guessed: false, ours: true }),
    ).toBe('57211 Terminal Deck')
  })

  it('says the port alone rather than inventing a name for it', () => {
    expect(portSummary({ port: 9000, process: '', guessed: true, ours: false })).toBe('9000')
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

/**
 * The nine-port list from the 2026-08-16 recording, eight of them this app's
 * own and all eight reading `Terminal`. He clicked one and got a black page
 * saying "that is not how to ask" — our pairing server refusing a plain GET.
 *
 * The rule is one line, so it is held to one line: a port this app is holding
 * is never a page.
 */
describe('splitOwnPorts', () => {
  const rows = readPorts([
    { port: 5037, process: 'adb', guessed: false, ours: false },
    { port: 8443, process: 'Terminal Deck', guessed: false, ours: true },
    { port: 9444, process: 'Electron', guessed: false, ours: true },
    { port: 5173, process: 'node', guessed: false, ours: false },
  ])

  it('offers only the ports that are not ours', () => {
    expect(splitOwnPorts(rows).open.map((row) => row.port)).toEqual([5037, 5173])
  })

  it('keeps our own, so the list is not lying by omission', () => {
    // Folded away rather than deleted. They really are listening, and a list
    // that silently drops rows cannot be reconciled with `lsof`.
    expect(splitOwnPorts(rows).ours.map((row) => row.port)).toEqual([8443, 9444])
  })

  it('says nothing about ownership when the main process did not', () => {
    // An older main process sends no `ours` at all. Everything stays offered,
    // which is exactly how this page behaved before the field existed.
    const old = readPorts([{ port: 3000, process: 'node', guessed: false }])
    expect(splitOwnPorts(old).ours).toEqual([])
    expect(splitOwnPorts(old).open).toHaveLength(1)
  })
})

/**
 * The list, when it is about another machine.
 *
 * *"When I click on browser there is no way for me to find all the localhost
 * pages of the remote device. I should be able to see the available whole
 * ports."*
 *
 * The page is the same page — same heading, same address field, same rows, same
 * card — with the machine's name where "this machine" used to be. That sameness
 * is the requirement rather than a nicety: *"shape of the application should not
 * be changing for local and remote devices."*
 */
describe('the start page, listing another machine', () => {
  const source: PortSource = {
    name: 'office-pc',
    ports: [
      { port: 5173, process: 'node', guessed: false, ours: false },
      { port: 8080, process: '', guessed: true, ours: false },
    ],
    open: () => undefined,
    refresh: () => undefined,
  }

  const html = renderToStaticMarkup(
    <StartPage onOpen={() => undefined} bridge={noPorts} source={source} />,
  )

  it('names the machine the list is about, instead of claiming it is this one', () => {
    expect(html).toContain('Listening on office-pc right now')
    expect(html).not.toContain('Listening on this machine')
  })

  it('draws that machine’s ports as the same rows a local port gets', () => {
    expect(html).toContain(':5173')
    expect(html).toContain(':8080')
    expect(html).toContain('port only')
    expect(html).toContain('aria-label="Open port 5173 node on office-pc"')
  })

  it('keeps the address field, which is the other half of what he asked for', () => {
    // *"…and I should be able to type and reach the devices which are not here
    // on this device."* The field is the same one; where it resolves is the
    // picker's business, in the toolbar above.
    expect(html).toContain('aria-label="Address"')
  })

  it('offers a rescan, because nothing over there watches its own port table', () => {
    expect(html).toContain('Scan again')
  })

  it('says nothing is listening on that machine, naming it', () => {
    const empty = renderToStaticMarkup(
      <StartPage onOpen={() => undefined} bridge={noPorts} source={{ ...source, ports: [] }} />,
    )
    expect(empty).toContain('Nothing is listening on office-pc')
  })

  it('waits rather than claiming nothing is listening before it has answered', () => {
    // Null and `[]` are two different facts. A machine that has not been asked
    // yet must not be reported as a machine with no dev server.
    const asking = renderToStaticMarkup(
      <StartPage onOpen={() => undefined} bridge={noPorts} source={{ ...source, ports: null }} />,
    )
    expect(asking).toContain('Asking office-pc what it is serving')
    expect(asking).not.toContain('Nothing is listening')
  })

  it('does not offer to start a dev server here for a list that is over there', () => {
    // Every row in that panel is a folder on *this* disk with a script this
    // process would run. Pressing Start would spawn a server on the wrong
    // computer, and there is no verb on the wire for starting one on the right
    // one — so the honest amount to show is none.
    //
    // Asserted through the rule rather than through the markup: that panel
    // fills itself from an effect, and effects do not run here, so a static
    // render is empty either way and would pass whatever this file said.
    expect(offersDevServers(source)).toBe(false)
    expect(offersDevServers(null)).toBe(true)
  })
})
