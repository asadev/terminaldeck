import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { SERVER_ICON } from '../machines/servers/glyph'
import { MACHINE_ICON } from '../shell/workspace-tabs'
import {
  machineMark,
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

  /**
   * The third fact, which servers made possible and machines never could.
   *
   * A paired computer scans its own ports with the same tool this one uses, so
   * it either answers or is offline. A server can be reachable, willing, and
   * have no tool installed for listing what is listening — the probe answers
   * *"this server has no tool installed for listing what is listening"*, and
   * that is a fact about the machine rather than a failure of the app.
   *
   * Drawing it as an empty list would state something different and false: that
   * nothing is running on somebody's server. The whole facts model one folder
   * over exists to keep those two apart, and this is the one place in the
   * browser where the difference reaches a screen.
   */
  it('says why the list is empty rather than saying nothing is listening', () => {
    const why = 'this server has no tool installed for listing what is listening'
    const html = renderToStaticMarkup(
      <StartPage
        onOpen={() => undefined}
        bridge={noPorts}
        source={{ ...source, ports: [], cannot: why }}
      />,
    )
    expect(html).toContain(why)
    expect(html).not.toContain('Nothing is listening')
  })

  it('leaves every path that predates servers exactly as it was', () => {
    // `cannot` is optional and unset everywhere but a server, so an absent one
    // must behave as it did before the field existed.
    const html = renderToStaticMarkup(
      <StartPage onOpen={() => undefined} bridge={noPorts} source={{ ...source, ports: [] }} />,
    )
    expect(html).toContain('Nothing is listening on office-pc')
  })

  /**
   * The other half of the same review, in his words:
   *
   *   > *"list the remote machine's ports with the machine's icon beside them,
   *   > so remote and local are distinguishable at a glance"*
   *
   * The sentence above the list already names the machine, and that was the
   * whole of the fix for a while. It is not enough by the fifth row: what a
   * person reads when they press one is `:5173 node`, which is the same six
   * characters here and in the next room. So the mark is on the **row**, and
   * these hold that it is on every row rather than only on the first.
   */
  it('puts the machine’s mark on every remote row, not just the heading', () => {
    const marks = html.split(`d="${MACHINE_ICON}"`).length - 1
    // Two open ports in the fixture, two marks. A count rather than a
    // `toContain`, because the failure this is guarding against is a mark drawn
    // once above the list — which is exactly the shape the Remote pane rejected
    // in `MachineLinks.tsx`: "a row that borrowed its identity from a heading
    // four rows up is a row that reads as local".
    expect(marks).toBe(2)
  })

  it('draws the mark before the port number, where it is read first', () => {
    // `:5173` means nothing until you know whose 5173 it is, so the order on
    // the row is the order the question is asked in.
    //
    // Against the number's own span rather than against `:5173`, which the
    // address field's placeholder says first — `localhost:5173, or any address`.
    // A bare substring here passed for the wrong reason and then failed for the
    // right one.
    const number = '<span class="bw-start-port-num">:5173</span>'
    expect(html).toContain(number)
    expect(html.indexOf(MACHINE_ICON)).toBeLessThan(html.indexOf(number))
  })

  it('says the machine once, not twice, to a screen reader', () => {
    // The button's label already ends "on office-pc" — the name, which is more
    // than the mark could say. So the mark is hidden rather than labelled, and
    // this fails the moment somebody gives it a `role="img"` and an aria-label.
    expect(html).toContain('aria-label="Open port 5173 node on office-pc"')
    expect(html).toContain('<svg class="bw-start-port-mark"')
    expect(html).not.toContain('aria-label="office-pc"')
  })

  it('wears the server’s mark for a server and the desktop’s for a device', () => {
    // The two are deliberately unalike at a glance — a desktop is a screen on a
    // stand, a server a stack of boxes with a light on each — and the rail
    // already draws them that way. A row here that wore the other one would be
    // naming the wrong computer, which is the failure the mark exists to end.
    const server = renderToStaticMarkup(
      <StartPage onOpen={() => undefined} bridge={noPorts} source={{ ...source, kind: 'server' }} />,
    )
    expect(server).toContain(SERVER_ICON)
    expect(server).not.toContain(MACHINE_ICON)
    expect(SERVER_ICON).not.toBe(MACHINE_ICON)
  })

  /**
   * The rule itself, asserted where a test can see it.
   *
   * The local list is drawn from an effect and effects do not run here, so
   * "this machine's rows carry no mark" is unreachable through a render and
   * would pass whatever this file said. It is held through the function for the
   * same reason `offersDevServers` is, below.
   */
  it('draws no mark at all on this machine’s own list', () => {
    // A mark whose job is "this row is not here" has to be absent when the row
    // *is* here, or it stops meaning anything — and the list a person sees most
    // often is their own.
    expect(machineMark(null)).toBeNull()
    // The fixture sets no `kind`, which is every caller that predates servers:
    // an absent one has to land on a mark rather than on null, because the
    // failure that would matter is a remote row drawn bare.
    expect(machineMark(source)).toBe(MACHINE_ICON)
    expect(machineMark({ ...source, kind: 'device' })).toBe(MACHINE_ICON)
    expect(machineMark({ ...source, kind: 'server' })).toBe(SERVER_ICON)
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
