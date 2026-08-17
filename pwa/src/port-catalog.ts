/**
 * Turning a wall of ports into a few groups, from facts rather than from guesses.
 *
 * Asad, on the list as it was: *"I can already see a big list of local hosts. So
 * it should not be like that… I think they are different categories also. So
 * maybe we can categorize and we can keep some in the list and we can keep some
 * folded… so we don't see a lot of jargon, unnecessary ones."* He was holding a
 * phone when he said it, and the phone app grew `Ports/PortCatalog.swift` that
 * night. This is the same rule book for the browser client, because the wall he
 * objected to is the same wall — `localhostScreen` in `main.ts` drew a flat list
 * of every port and then a second flat list of dev servers underneath it.
 *
 * ## This is a port of the rules, not of the code
 *
 * Every decision below is the one `PortCatalog.swift` makes, and the two files
 * are meant to agree: a person who names port 3000 on their phone and then opens
 * this page on a laptop should find the same six headings in the same order, with
 * the same three folded. What is *not* shared is a line of code — Swift and
 * TypeScript cannot import each other and a generated file would be a build step
 * nobody would keep alive. `port-catalog.test.ts` pins the table below so the two
 * can only drift on purpose.
 *
 * ## Every group is derived from something the wire actually carries
 *
 * There are exactly three inputs, and no fourth is invented:
 *
 *  1. **`LocalPort`** — a port number, the name of the process holding it, and
 *     `guessed`, which says the port answers but nothing could name its owner.
 *     `dev-ports.ts` on the desktop is deliberate about this: it *refuses* to
 *     guess which framework is behind a port, and this file does not do the
 *     guessing on its behalf. A process name is a fact about a process, not a
 *     claim about a page.
 *  2. **`DevServerReport`** — a project folder the machine granted this browser,
 *     and the port its dev server is proven to be accepting on. This is the only
 *     input that can say *what a port is serving*, because the desktop started it.
 *  3. **The endpoint this browser is connected on**, plus this product's own
 *     binary name. Those two are how a port that belongs to the desktop app
 *     itself is recognised instead of being offered as somebody's dev server.
 *
 * What is **not** here: no table of "3000 means Next, 5173 means Vite", no
 * inference from a port number to a framework, no list of ports somebody else's
 * machine is expected to have. A port number is a number a person chose.
 *
 * ## The six groups
 *
 * | Group | Derived from | Open by default |
 * |---|---|---|
 * | **Named by you** | this browser's own `PortBook` has a name for it | yes |
 * | **Dev servers** | a `DevServerReport` for a granted folder | yes |
 * | **Web servers** | the process is one of the runtimes `dev-ports.ts` ranks first | yes |
 * | ***the product itself*** | the port this page dialled, or the app's own binary | no |
 * | **Other services** | a named process that is none of the above | no |
 * | **Unidentified** | `guessed` — it answers, nothing could name it | no |
 *
 * The last three are the pile he was complaining about, and they are closed
 * rather than hidden: `wslrelay` on three ports is genuinely uninteresting until
 * the day it is the thing you are looking for.
 *
 * ## Naming a port promotes it, and that is the whole "keep some in the list"
 *
 * *"we can keep some in the list and we can keep some folded"*. Rather than a
 * second pin/hide control alongside the rename, the name **is** the pin: a port
 * with a name is lifted to the top group whatever it was derived into. It is one
 * gesture with one meaning — *this one matters and here is why* — and it cannot
 * get out of step with itself the way a pinned-but-unnamed row could.
 *
 * ## One row per server, never two
 *
 * A dev server this browser started shows up twice if nothing joins them: once as
 * `myproject` from `dev.state`, and once as `3000 · node` from `ports`. They are
 * the same server, and the join is a fact rather than a heuristic —
 * `DevServerReport.port` is a port the desktop **dialled and got an answer on**.
 * So a `ready` report claims its port, the port row is dropped, and the merged
 * row carries both the project's name and the address.
 */

import { BRAND } from '../../src/shared/brand'
import { DEV_CAPTION } from './dev-server'
import type { DevServerReport, LocalPort } from './protocol-client'

/**
 * Which pile a row lands in.
 *
 * The declaration order is the order the sections are drawn in, so it goes from
 * "this is why you opened the screen" to "this is the noise".
 */
export const PORT_CATEGORIES = ['named', 'devServer', 'web', 'app', 'other', 'unnamed'] as const

export type PortCategory = (typeof PORT_CATEGORIES)[number]

/**
 * What the section header says.
 *
 * A function rather than a record literal because one of the six is the product's
 * own name, which lives in exactly one place in this repo and is read from it —
 * the standing rule in `brand.ts`. The name rather than "this app", because a
 * browser paired with three machines is answering the question *which program on
 * that machine is holding the port*.
 */
export function categoryTitle(category: PortCategory): string {
  switch (category) {
    case 'named':
      return 'Named by you'
    case 'devServer':
      // The caption `dev-server.ts` already wrote for this list when it was a
      // section of its own, rather than a second spelling of it here. The two
      // headings are the same heading; the list simply moved.
      return DEV_CAPTION
    case 'web':
      return 'Web servers'
    case 'app':
      return BRAND.name
    case 'other':
      return 'Other services'
    case 'unnamed':
      return 'Unidentified'
  }
}

/**
 * Whether the group starts closed.
 *
 * The three that start closed are the three whose rows are, on a normal machine,
 * things nobody opened the screen to look at. It is a *starting* position and not
 * a rule: `PortBook` remembers the first time somebody disagrees, per machine,
 * because a WSL box where `wslrelay` is the whole point is a real machine.
 */
export function foldedByDefault(category: PortCategory): boolean {
  return category === 'app' || category === 'other' || category === 'unnamed'
}

/**
 * One row on the localhost screen.
 *
 * Either a listening port, or a project's dev server, or — when the two are the
 * same server — both. `dev` and `entry` are never both null.
 */
export interface LocalhostRow {
  /** What is listening, when something is. Null for a dev server that is not up. */
  entry: LocalPort | null
  /** The project behind it, when this machine has told us about one. */
  dev: DevServerReport | null
  /** This browser's name for this port, or null. */
  name: string | null
  category: PortCategory
  /**
   * The port, from whichever half of the row knows it. Null only for a dev
   * server that has not come up — which is exactly the row whose whole point is
   * that there is no port yet.
   */
  port: number | null
  /**
   * Stable across a refresh, so the DOM node for a row can be found again by the
   * thing that opened its menu. Keyed on the folder for a dev server, because its
   * port changes when Vite takes 5174 instead of 5173.
   */
  id: string
}

export interface LocalhostSection {
  category: PortCategory
  rows: LocalhostRow[]
}

/**
 * The row's second action — what the `…` beside it offers.
 *
 * A value rather than a `switch` inside the render, because this is the answer to
 * *"what do start and stop do in each of the five states"* and that answer has to
 * be checkable without a paired machine and a project on it. The renderer turns
 * each case into a button; this decides which case it is.
 *
 * | row | second action | why |
 * |---|---|---|
 * | dev server, `idle` | **Start** | `dev.start`, and the press is the consent |
 * | dev server, `starting` | **Open session** | watch it come up; a second start would be a second start |
 * | dev server, `ready` | **Open session** | where it is running — and where Ctrl-C stops it |
 * | dev server, `failed` | **Try again** | `dev.start` re-reads the folder, so a fixed `package.json` is picked up |
 * | dev server, `no-dev-script` | *nothing* | there is no row at all; see `sections` |
 * | a plain listening port | **Copy address** | nothing on the wire can start or stop "whatever is on 2019" |
 *
 * `starting` and `ready` fall back to `none` when the report carries no session,
 * which the protocol says cannot happen — both states are defined to have one.
 * Drawing a control that would have nowhere to go is worse than drawing none, so
 * the impossible case is handled rather than forced.
 */
export type PortRowAction =
  /** `dev.start` for a project that is not running. */
  | { kind: 'start'; folder: string }
  /**
   * `dev.start` again for one that failed. A different word on the button: the
   * row already carries the reason, and this is the deliberate second press.
   */
  | { kind: 'retry'; folder: string }
  /**
   * Open the ordinary session the dev server runs in. **This is also how one is
   * stopped** — Ctrl-C is on the key bar in there, and there is no stop verb on
   * the wire because there is no separate kind of process.
   */
  | { kind: 'openSession'; id: string }
  /** Put `http://localhost:<port>` on the clipboard. */
  | { kind: 'copyAddress'; port: number }
  /** Nothing to offer. */
  | { kind: 'none' }

/**
 * Runtimes that usually *are* serving a page.
 *
 * `LIKELY_DEV` from `dev-ports.ts`, mirrored — the same list the desktop already
 * uses to decide which ports to print first, so this client's grouping and the
 * desktop's ordering agree about what looks like a web server. It changes when
 * that list changes.
 *
 * Matched as a prefix rather than exactly, because the same runtime is spelled
 * several ways by the two scanners: `python` and `python3`, and on Windows `node`
 * comes back from `tasklist` with the `.exe` already taken off but a version
 * suffix sometimes still attached.
 */
export const WEB_RUNTIMES = [
  'node',
  'bun',
  'deno',
  'python',
  'ruby',
  'php',
  'java',
  'dotnet',
  'caddy',
  'nginx',
] as const

export function isWebRuntime(process: string): boolean {
  const name = process.toLowerCase()
  return WEB_RUNTIMES.some((runtime) => name.startsWith(runtime))
}

/**
 * Whether the desktop half of *this product* is what is holding the port.
 *
 * Two spellings, because two operating systems name the same binary differently
 * and neither is a guess: Windows' `tasklist` reports the executable with `.exe`
 * stripped, which is the product name with its space — and a slug build has no
 * space. Both are read off `BRAND`, which is the only place the name lives.
 *
 * On macOS this almost never fires, and that is a known gap on the desktop rather
 * than a bug here: `parseLsof` splits its columns on whitespace, so a command name
 * containing a space shifts the columns and the row is dropped before it reaches
 * the wire. The app's own listener therefore does not appear in the list on a Mac
 * at all — a *quieter* wrong answer than the one this function exists to prevent,
 * and one that is fixed on the desktop or not at all.
 */
export function isOwnProcess(process: string): boolean {
  const name = process.toLowerCase().replace(/ /g, '')
  return name === BRAND.name.toLowerCase().replace(/ /g, '') || name === BRAND.id.toLowerCase()
}

/**
 * The port this page is talking to the machine on, when it can know it.
 *
 * A *direct* pairing is this client being served by the very process it then
 * talks to — see the note on `DirectEndpoint` — so the port in the address bar is
 * this product's by definition. It is the socket the frame asking the question
 * arrived on.
 *
 * A relay pairing carries no such thing: the browser dials the relay and the
 * desktop dials out to meet it, so nothing on this side knows which local port
 * the desktop bound. That case returns nothing rather than falling back to the
 * product's default port number, because a default is a guess about somebody's
 * configuration and this whole file is built on not making those.
 *
 * `location` is passed rather than read, which is what keeps this a function the
 * suite can ask questions of — the same reason `theme.ts` takes `matchMedia`.
 */
export function directAppPorts(location: { protocol: string; port: string }): number[] {
  if (location.port !== '') {
    const port = Number.parseInt(location.port, 10)
    return Number.isFinite(port) ? [port] : []
  }
  // An address with no explicit port is on its scheme's default, which is a fact
  // about the URL rather than an assumption about the machine.
  switch (location.protocol.toLowerCase()) {
    case 'https:':
      return [443]
    case 'http:':
      return [80]
    default:
      return []
  }
}

export interface SectionInput {
  ports: readonly LocalPort[]
  devServers: readonly DevServerReport[]
  /** See {@link directAppPorts}. Empty for a relay pairing, and that is correct. */
  appPorts?: readonly number[]
  /** Port number → this browser's name for it. See `port-book.ts`. */
  names?: Readonly<Record<number, string>>
}

/**
 * The whole screen's content, grouped and ordered.
 *
 * Pure, and takes its inputs rather than reading the client's state, so every
 * rule in the table above is pinned by a test that needs no DOM and no paired
 * machine — the same reason `localhost.ts` keeps its state machine out of
 * `main.ts`.
 *
 * `names` is a snapshot keyed by port rather than the store itself, so this file
 * never learns which machine it is describing.
 *
 * Order within a section is the order the two lists arrived in: the desktop ranks
 * its ports most-likely-to-be-a-dev-server first and offers its folders
 * most-relevant-first, and re-sorting here would throw away the only ordering
 * anybody has an opinion about. It is the same reason `afterFrame` in
 * `localhost.ts` refuses to sort the port list by number.
 */
export function sections(input: SectionInput): LocalhostSection[] {
  const appPorts = new Set(input.appPorts ?? [])
  const names = input.names ?? {}
  const rows: LocalhostRow[] = []
  /** Ports a dev server has claimed. See "One row per server, never two". */
  const claimed = new Set<number>()

  for (const report of input.devServers) {
    // `no-dev-script` is never a row, and the rule is restated here rather than
    // left to the caller because it belongs to the protocol: it means "there is
    // nothing to press, and there never will be for this folder".
    if (report.status === 'no-dev-script') continue
    // Only a `ready` report has a proven port. A `starting` one has no port field
    // at all and a `failed` one must never carry the address of the server that
    // died — see `DevServerReport` in the desktop's protocol.ts.
    const port = report.status === 'ready' ? (report.port ?? null) : null
    if (port !== null) claimed.add(port)
    const entry = port === null ? null : (input.ports.find((candidate) => candidate.port === port) ?? null)
    const name = port === null ? null : (names[port] ?? null)
    rows.push({
      entry,
      dev: report,
      name,
      category: name === null ? 'devServer' : 'named',
      port: port ?? entry?.port ?? null,
      id: `dev:${report.folder}`,
    })
  }

  for (const entry of input.ports) {
    if (claimed.has(entry.port)) continue
    const name = names[entry.port] ?? null
    rows.push({
      entry,
      dev: null,
      name,
      category: categoryFor(entry, name !== null, appPorts),
      port: entry.port,
      id: `port:${entry.port}`,
    })
  }

  const grouped: LocalhostSection[] = []
  for (const category of PORT_CATEGORIES) {
    const inside = rows.filter((row) => row.category === category)
    if (inside.length > 0) grouped.push({ category, rows: inside })
  }
  return grouped
}

/**
 * What the `…` beside one row offers. The table is on {@link PortRowAction}; this
 * is the only place that decides it.
 */
export function secondAction(row: LocalhostRow): PortRowAction {
  const dev = row.dev
  if (dev !== null) {
    switch (dev.status) {
      case 'idle':
        return { kind: 'start', folder: dev.folder }
      case 'failed':
        return { kind: 'retry', folder: dev.folder }
      case 'starting':
      case 'ready':
        return dev.sessionId === undefined ? { kind: 'none' } : { kind: 'openSession', id: dev.sessionId }
      case 'no-dev-script':
        return { kind: 'none' }
    }
  }
  if (row.entry === null) return { kind: 'none' }
  return { kind: 'copyAddress', port: row.entry.port }
}

/**
 * Which pile one listening port lands in.
 *
 * The order of the tests is the order of the claims' strength, and two of them
 * are load-bearing:
 *
 *  - **The app's own port is checked before the runtime name.** A desktop running
 *    headless is a `node` process, so a machine reached over a direct endpoint
 *    would otherwise offer this browser its own control socket under "Web
 *    servers" — a row that describes the thing that drew it.
 *  - **`guessed` is checked before the runtime name** only for tidiness; a port
 *    with no owner reports its process as `unknown`, which matches no runtime
 *    either way. It is its own group rather than part of "Other" because "we
 *    could not name this" and "this is named and dull" are different facts, and
 *    only one of them might be worth a second look.
 */
function categoryFor(entry: LocalPort, named: boolean, appPorts: ReadonlySet<number>): PortCategory {
  if (named) return 'named'
  if (appPorts.has(entry.port) || isOwnProcess(entry.process)) return 'app'
  if (entry.guessed) return 'unnamed'
  if (isWebRuntime(entry.process)) return 'web'
  return 'other'
}

/* ------------------------------------------------------------------ words -- */

/**
 * The identity line of a plain port row, and which string that is depends on
 * whether anybody has said.
 *
 * With no name the port number leads, and the row is what this screen has always
 * drawn. With a name, the name leads and the address drops to the line underneath
 * beside the process — so the thing he could not tell apart, four rows of
 * `wslrelay`, becomes four different rows without losing what they are.
 */
export function portRowTitle(row: LocalhostRow): string {
  if (row.name !== null) return row.name
  const port = row.port
  return port === null ? 'localhost' : `localhost:${port}`
}

/**
 * The second line: whatever is left that identifies the row.
 *
 * A named row needs the address back, because the name replaced it. An unnamed
 * row already leads with the address, so the process is the only thing left to
 * say — and it is omitted rather than guessed at when the machine could not name
 * it, which is what `guessed` means.
 */
export function portRowDetail(row: LocalhostRow): string | null {
  const entry = row.entry
  if (entry === null) return null
  const address = `localhost:${entry.port}`
  if (row.name !== null) return entry.guessed ? address : `${address} · ${entry.process}`
  return entry.guessed ? null : entry.process
}

/**
 * The one paragraph the grouping itself earns.
 *
 * Asad on the desktop's settings, in the same recording: *"we don't need this
 * much of big descriptions under each."* What earns a line here is the rule
 * nothing else on screen states — that naming a port is what moves it up —
 * because a folded group is otherwise a thing somebody has to discover twice.
 */
export const NAMING_FOOTNOTE =
  'Groups are worked out from the process holding each port. Naming one moves it to the top of the list.'
