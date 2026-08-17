/**
 * The grouping rules, pinned against the phone's.
 *
 * Two clients now derive the same six groups from the same three inputs, in two
 * languages that cannot import each other. What holds them together is this file
 * and `ios/Tests/PortCatalogTests.swift` asking the same questions — so the table
 * in `port-catalog.ts` is not documentation of an intention, it is a thing that
 * fails when somebody changes it on one side only.
 *
 * The rule these tests exist to defend, above all the others: **no group is ever
 * derived from a port number**. `dev-ports.ts` refuses to guess which framework
 * is behind a port and neither client may do the guessing on its behalf, because
 * a port number is a number a person chose. Two of the cases below check that
 * directly, with 3000 and 5173 landing wherever their *process* puts them.
 */

import { describe, expect, it } from 'vitest'
import { BRAND } from '../../src/shared/brand'
import {
  PORT_CATEGORIES,
  categoryTitle,
  directAppPorts,
  foldedByDefault,
  isOwnProcess,
  isWebRuntime,
  portRowDetail,
  portRowTitle,
  secondAction,
  sections,
} from './port-catalog'
import type { DevServerReport, LocalPort } from './protocol-client'

function port(number: number, process: string, guessed = false): LocalPort {
  return { port: number, process, guessed }
}

function dev(folder: string, status: DevServerReport['status'], extra: Partial<DevServerReport> = {}): DevServerReport {
  return { folder, status, ...extra }
}

describe('the six groups', () => {
  it('goes from why you opened the screen to the noise, and folds the noise', () => {
    // The declaration order is the draw order, so it is the thing to assert.
    expect([...PORT_CATEGORIES]).toEqual(['named', 'devServer', 'web', 'app', 'other', 'unnamed'])
    expect(PORT_CATEGORIES.filter(foldedByDefault)).toEqual(['app', 'other', 'unnamed'])
  })

  it('calls the app’s own group by the product’s name', () => {
    // Not "this app". A browser paired with three machines is answering *which
    // program on that machine* is holding the port — and the name is read from
    // the one place it lives.
    expect(categoryTitle('app')).toBe(BRAND.name)
    expect(categoryTitle('unnamed')).toBe('Unidentified')
  })

  it('never sorts a port into a group by its number', () => {
    const grouped = sections({
      ports: [port(3000, 'wslrelay'), port(5173, 'node'), port(8080, 'unknown', true)],
      devServers: [],
    })
    // 3000 is the number everybody associates with a dev server and it is held by
    // a relay here, so it is "other". 5173 is Vite's number and is `node` here, so
    // it is a web server — on the process, not on the number.
    expect(grouped.map((section) => section.category)).toEqual(['web', 'other', 'unnamed'])
    expect(grouped[0].rows[0].port).toBe(5173)
    expect(grouped[1].rows[0].port).toBe(3000)
    expect(grouped[2].rows[0].port).toBe(8080)
  })

  it('recognises the runtimes as prefixes, because the scanners spell them differently', () => {
    // `python3` from lsof, `node.exe` already stripped by tasklist but sometimes
    // carrying a suffix. Matching exactly would put half of them in "Other".
    expect(isWebRuntime('python3')).toBe(true)
    expect(isWebRuntime('NODE')).toBe(true)
    expect(isWebRuntime('nodemon')).toBe(true)
    expect(isWebRuntime('wslrelay')).toBe(false)
  })

  it('knows the product’s own process under both of its spellings', () => {
    expect(isOwnProcess(BRAND.name)).toBe(true)
    expect(isOwnProcess(BRAND.name.replace(' ', ''))).toBe(true)
    expect(isOwnProcess(BRAND.id)).toBe(true)
    expect(isOwnProcess('node')).toBe(false)
  })

  it('puts the socket this page is connected on in the app’s group, before the runtime name', () => {
    /*
     * The load-bearing ordering. A desktop running headless *is* a node process,
     * so on a direct pairing the client's own control socket would otherwise be
     * offered under "Web servers" — a row describing the thing that drew it.
     */
    const grouped = sections({
      ports: [port(8443, 'node')],
      devServers: [],
      appPorts: [8443],
    })
    expect(grouped).toHaveLength(1)
    expect(grouped[0].category).toBe('app')
  })
})

describe('naming a port', () => {
  it('lifts it to the top group whatever it was derived into', () => {
    const grouped = sections({
      ports: [port(2019, 'wslrelay'), port(2222, 'wslrelay')],
      devServers: [],
      names: { 2222: 'WSL relay — ssh' },
    })
    expect(grouped.map((section) => section.category)).toEqual(['named', 'other'])
    expect(grouped[0].rows[0].port).toBe(2222)
  })

  it('leads with the name and moves the address to the second line', () => {
    const named = sections({ ports: [port(3210, 'node')], devServers: [], names: { 3210: 'Client billing' } })
    expect(portRowTitle(named[0].rows[0])).toBe('Client billing')
    expect(portRowDetail(named[0].rows[0])).toBe('localhost:3210 · node')

    const plain = sections({ ports: [port(3210, 'node')], devServers: [] })
    expect(portRowTitle(plain[0].rows[0])).toBe('localhost:3210')
    expect(portRowDetail(plain[0].rows[0])).toBe('node')
  })

  it('says nothing about a process the machine could not name', () => {
    // `guessed` means the port answers and nothing could name its owner. Printing
    // the literal string `unknown` would be a field dump; omitting the line is the
    // honest reading.
    const grouped = sections({ ports: [port(9000, 'unknown', true)], devServers: [] })
    expect(portRowDetail(grouped[0].rows[0])).toBeNull()
  })
})

describe('one row per server, never two', () => {
  it('joins a ready dev server to the port it is proven to be serving on', () => {
    const grouped = sections({
      ports: [port(5173, 'node'), port(2019, 'wslrelay')],
      devServers: [dev('/w/site', 'ready', { port: 5173, sessionId: 's1', url: 'http://localhost:5173' })],
    })
    // One dev-server row carrying both halves, and no separate `5173 · node`.
    const rows = grouped.flatMap((section) => section.rows)
    expect(rows.filter((row) => row.port === 5173)).toHaveLength(1)
    const joined = rows.find((row) => row.port === 5173)
    expect(joined?.dev?.folder).toBe('/w/site')
    expect(joined?.entry?.process).toBe('node')
    expect(joined?.category).toBe('devServer')
  })

  it('does not let a starting or failed report claim a port', () => {
    /*
     * Only a `ready` report has a proven port. A `starting` one has no port field
     * and a `failed` one must never carry the address of the server that died — so
     * a port row that happens to share the number is a *different* thing and stays
     * on the list in its own right.
     */
    const grouped = sections({
      ports: [port(5173, 'node')],
      devServers: [dev('/w/site', 'failed', { port: 5173, message: 'exited 1' })],
    })
    const rows = grouped.flatMap((section) => section.rows)
    expect(rows).toHaveLength(2)
    expect(rows.some((row) => row.dev !== null && row.entry === null)).toBe(true)
    expect(rows.some((row) => row.dev === null && row.entry !== null)).toBe(true)
  })

  it('gives a named dev server the top group too', () => {
    const grouped = sections({
      ports: [],
      devServers: [dev('/w/site', 'ready', { port: 4321, sessionId: 's1' })],
      names: { 4321: 'The shop' },
    })
    expect(grouped[0].category).toBe('named')
    expect(grouped[0].rows[0].name).toBe('The shop')
  })

  it('never draws a folder with no dev script', () => {
    // It means "there is nothing to press, and there never will be for this
    // folder". A row for it would be a button whose only outcome is a refusal.
    const grouped = sections({ ports: [], devServers: [dev('/w/notes', 'no-dev-script')] })
    expect(grouped).toEqual([])
  })

  it('keeps the order the two lists arrived in', () => {
    // The desktop ranks its ports most-likely-to-be-a-dev-server first. Re-sorting
    // here would throw away the only ordering anybody has an opinion about.
    const grouped = sections({
      ports: [port(5173, 'node'), port(3000, 'bun'), port(8000, 'python3')],
      devServers: [],
    })
    expect(grouped[0].rows.map((row) => row.port)).toEqual([5173, 3000, 8000])
  })
})

describe('what the row’s second control does', () => {
  it('answers all five dev-server states and the plain port', () => {
    const idle = sections({ ports: [], devServers: [dev('/w/a', 'idle')] })[0].rows[0]
    expect(secondAction(idle)).toEqual({ kind: 'start', folder: '/w/a' })

    const failed = sections({ ports: [], devServers: [dev('/w/a', 'failed')] })[0].rows[0]
    expect(secondAction(failed)).toEqual({ kind: 'retry', folder: '/w/a' })

    const starting = sections({ ports: [], devServers: [dev('/w/a', 'starting', { sessionId: 's7' })] })[0].rows[0]
    expect(secondAction(starting)).toEqual({ kind: 'openSession', id: 's7' })

    const ready = sections({
      ports: [],
      devServers: [dev('/w/a', 'ready', { port: 3000, sessionId: 's8' })],
    })[0].rows[0]
    expect(secondAction(ready)).toEqual({ kind: 'openSession', id: 's8' })

    const plain = sections({ ports: [port(2019, 'wslrelay')], devServers: [] })[0].rows[0]
    expect(secondAction(plain)).toEqual({ kind: 'copyAddress', port: 2019 })
  })

  it('offers nothing rather than a control with nowhere to go', () => {
    // The protocol says a running dev server always carries a session. Drawing a
    // button that would have nothing to open is worse than drawing none, so the
    // impossible case is handled rather than forced.
    const ready = sections({ ports: [], devServers: [dev('/w/a', 'ready', { port: 3000 })] })[0].rows[0]
    expect(secondAction(ready)).toEqual({ kind: 'none' })
  })
})

describe('which port belongs to this product', () => {
  it('takes the page’s own port for a direct pairing', () => {
    expect(directAppPorts({ protocol: 'https:', port: '8443' })).toEqual([8443])
    // No explicit port means the scheme's default, which is a fact about the URL
    // rather than an assumption about the machine.
    expect(directAppPorts({ protocol: 'https:', port: '' })).toEqual([443])
    expect(directAppPorts({ protocol: 'http:', port: '' })).toEqual([80])
    expect(directAppPorts({ protocol: 'file:', port: '' })).toEqual([])
  })

  it('claims nothing on a relay pairing, because nothing on this side knows', () => {
    /*
     * The browser dials the relay and the desktop dials out to meet it, so no
     * frame on this side carries the local port the desktop bound. Falling back to
     * the product's default port number would be a guess about somebody's
     * configuration — the exact thing this whole file is built on not making — so
     * the caller passes nothing and the app's group is simply empty.
     */
    const grouped = sections({ ports: [port(8443, 'node')], devServers: [], appPorts: [] })
    expect(grouped[0].category).toBe('web')
  })
})
