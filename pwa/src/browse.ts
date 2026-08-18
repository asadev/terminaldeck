/**
 * Where an address typed on this screen can honestly be opened, and how.
 *
 * ## The complaint this file answers
 *
 * > *"I still cannot open the localhost of any of them, so there is no reason to
 * > give the list here… Maybe we can have one browse bar here and something to
 * > browse it, or maybe another kind of link to open in our normal browser."*
 *
 * The list was never the problem. A list of ports on a machine somewhere else is
 * a genuinely useful thing to be told — it is most of why anybody opens this
 * screen from a phone — and it read as pointless because **nothing on it went
 * anywhere**. So this file is the going-somewhere half: the rule for which
 * destinations exist for a given browser on a given pairing, and the rule for
 * turning what somebody types into an address.
 *
 * ## Two destinations, and neither one is a guess
 *
 * A browser tab cannot serve a page on `127.0.0.1` — no API, in any browser, and
 * `localhost.ts` writes down at length the three routes around that which were
 * considered and rejected. What is left is not a consolation prize; it is two
 * real places a page can land, and the whole design here is that **each one is
 * offered only when it can actually act**, which is the standing rule this
 * product is judged on.
 *
 *   - {@link BROWSE_MACHINE} — the page opens **on the machine**, in its own
 *     browser, over the sealed channel. This is `web.open`, it already exists on
 *     the wire, and it works from a phone on another continent. It is offered
 *     when the machine advertised `web`, which it withholds when it has no
 *     window to open one in, so this is never a button that discovers it does
 *     not function.
 *   - {@link BROWSE_HERE} — the page opens **in this browser**, as an ordinary
 *     new tab, because the address really does resolve from here. This is the
 *     *"another kind of link to open in our normal browser"* half, and it is the
 *     one that needs a rule, below.
 *
 * ## When "in this browser" is true, and when it is a lie
 *
 * `http://localhost:3000` typed into any browser means *this device's* port
 * 3000. On the laptop the machine is running on, that is the machine and the
 * link works. On a phone in a café, paired through the relay to a desktop in
 * another country, it is the phone — which is serving nothing — and a link
 * offering it is precisely the fake control this product keeps being told off
 * for. So the option exists only where the client can say *why* the address
 * resolves, and there are exactly two such cases:
 *
 *   1. **A direct pairing.** This page was served by the very process it talks
 *      to, so the host in the address bar *is* the machine — `100.64.0.3:8090`,
 *      `192.168.1.9:8090`, `127.0.0.1:8090`, whatever it happens to be. Every
 *      other port on that host is that machine's port, reachable by exactly the
 *      route this page arrived over. Certain, and it needs nothing from the wire.
 *   2. **A page served over loopback.** The address bar says `localhost` or
 *      `127.0.0.1`, so this browser is talking to a server on the device it is
 *      running on, and every other port on that loopback belongs to that same
 *      device. What this does **not** prove is that the device is the paired
 *      machine — it is not, for somebody running the web client at home against
 *      an office desktop — which is why the option is named *"this device"* and
 *      never *"the machine"*. It does what it says, and on the overwhelmingly
 *      common shape of this case, a person sitting at their own computer with
 *      both halves on it, the two are the same thing.
 *
 * Anything else — `https://app.terminaldeck.dev` on a phone, a LAN address that
 * did not serve this page — gets no such option at all, because there is nothing
 * true to say about it. That is a deliberate loss: somebody on the hosted client
 * *sitting at their own machine* is not offered a link that would have worked.
 * The alternative is offering it to everybody on the hosted client, almost all
 * of whom are on a phone, and watching it fail — and one dead control is worth
 * more damage here than one missing convenience.
 *
 * There is no DOM in this file, and no `window`: `location` arrives as the two
 * fields that are actually read. That is what lets every rule above be a value a
 * test can ask for rather than something only a paired browser could exercise.
 */

import type { DeckEndpoint } from './endpoint'

/** The two places a page can land. Not an enum — these are read in copy. */
export const BROWSE_MACHINE = 'machine'
export const BROWSE_HERE = 'here'

export type BrowseWhere = typeof BROWSE_MACHINE | typeof BROWSE_HERE

/**
 * One destination, as the chooser draws it.
 *
 * `label` is the device, not the verb — *"on this Mac"*, *"on this device"* —
 * because the button beside it already says Open and a chooser whose options
 * each repeat the verb reads as two controls doing the same thing.
 */
export interface BrowseTarget {
  where: BrowseWhere
  label: string
  /**
   * The host an address resolves against for {@link BROWSE_HERE}, and null for
   * the machine, which resolves `localhost` on its own side.
   */
  host: string | null
}

/** The two loopback spellings a browser's `location.hostname` can carry. */
const LOOPBACK = new Set(['localhost', '127.0.0.1', '::1', '[::1]'])

/**
 * Whether a hostname names the device the browser is running on.
 *
 * The bracketed IPv6 form is in the set because `location.hostname` strips the
 * brackets and `location.host` does not, and this has been handed both.
 * `127.0.0.2` and the rest of `127/8` are deliberately not matched: they are
 * loopback to the kernel and are not what any dev server binds, and widening
 * this to a subnet test would be inventing certainty out of arithmetic.
 */
export function isLoopbackHost(hostname: string): boolean {
  return LOOPBACK.has(hostname.toLowerCase())
}

/**
 * The host this browser can reach the machine's ports on, or null.
 *
 * The whole of the rule at the top of this file, in one function, so that the
 * screen never decides it twice. Null is the answer that draws no link at all.
 */
export function hostReachableHere(
  location: { hostname: string },
  endpoint: DeckEndpoint,
): string | null {
  if (endpoint.kind === 'direct') return location.hostname
  if (isLoopbackHost(location.hostname)) return location.hostname
  return null
}

/**
 * Every destination this browser has, in the order they are offered.
 *
 * The machine first, always, because it is the one that works from anywhere and
 * because it is what somebody reaching for this screen from a phone means. An
 * empty list is a real answer and the caller draws a disabled bar with a reason
 * rather than a bar that goes nowhere.
 */
export function browseTargets(input: {
  location: { hostname: string }
  endpoint: DeckEndpoint
  /** Whether the machine advertised `web`. See `webOfferedHere`. */
  machineOpens: boolean
  /** What the machine is called on this screen — a nickname, or `Mac`. */
  machineLabel: string
}): BrowseTarget[] {
  const targets: BrowseTarget[] = []
  if (input.machineOpens) {
    targets.push({ where: BROWSE_MACHINE, label: `On ${input.machineLabel}`, host: null })
  }
  const host = hostReachableHere(input.location, input.endpoint)
  if (host !== null) targets.push({ where: BROWSE_HERE, label: 'In this browser', host })
  return targets
}

/**
 * Why the bar cannot go anywhere, said as something to act on.
 *
 * Reached only when {@link browseTargets} is empty, which is one situation and
 * not several: this browser reached the machine through the relay *and* the
 * machine will not open pages for it. Both halves are named because the remedy
 * differs — a headless host has no window and never will, and a desktop that
 * does have one is a build or a pairing away from offering it.
 */
export const NOWHERE_TO_OPEN =
  'This machine will not open pages, and its addresses do not resolve from this browser, so there is nothing to open them in.'

/* ------------------------------------------------------------- addresses -- */

/**
 * What somebody typed, as a URL, or null when it is not one yet.
 *
 * Generous on the way in and strict on the way out, which is the only shape that
 * works for a field somebody types a port number into. `3000` is what a person
 * with a dev server actually thinks the address is, and a bar that refused it
 * until they typed `http://localhost:3000/` would be a bar that made them do the
 * work the bar exists to do.
 *
 * `host` is what a bare port is resolved against, and it is passed rather than
 * defaulted to `localhost`: on the machine's own side `localhost` is right, and
 * for a link in this browser the right host is whichever one this page came from
 * — see `hostReachableHere`, which is where that value is decided.
 *
 * Null for anything that is not yet an address, and the caller disables Open on
 * null rather than guessing. What is deliberately **not** done here is a search:
 * a box that quietly sends what you typed to a search engine when it did not
 * parse is the one behaviour that would take a person's half-typed internal
 * hostname off their machine and put it in somebody's query log.
 */
export function parseAddress(typed: string, host: string): string | null {
  const text = typed.trim()
  if (text === '') return null

  // Already a URL this can open.
  if (/^https?:\/\//i.test(text)) return normalise(text)

  /*
   * A scheme that is not the web, refused here rather than handed on.
   *
   * The machine checks the scheme again on its own side, and a rule that holds
   * only because of what the far end refuses is not a rule this end has — so
   * `file:`, `javascript:` and `data:` die in this branch.
   *
   * The negative lookahead is the part that took a failing test to find:
   * `localhost:8080` is scheme-shaped to any regex that only looks for a word
   * and a colon, and refusing it would reject the single most ordinary thing
   * anybody types into this field. A colon followed by a digit is a **port**, in
   * every string a person is going to put here; no scheme this could open is
   * spelled that way, and one that is falls through and fails to parse below.
   */
  if (/^[a-z][a-z0-9+.-]*:(?!\d)/i.test(text)) return null

  // A bare port, with or without the colon somebody types out of habit. The
  // upper bound is the protocol's, not a preference: there is no port 70000.
  const bare = /^:?(\d{1,5})(\/.*)?$/.exec(text)
  if (bare !== null) {
    const port = Number.parseInt(bare[1] ?? '', 10)
    if (!Number.isInteger(port) || port < 1 || port > 65535) return null
    return normalise(`http://${bracket(host)}:${port}${bare[2] ?? '/'}`)
  }

  // A host, with or without a port and a path. `http` rather than `https`,
  // because everything this screen is about is a dev server on a loopback and
  // none of them has a certificate; a person who wants TLS types the scheme.
  return normalise(`http://${text}`)
}

/**
 * An IPv6 literal needs its brackets back before it goes into a URL.
 *
 * `location.hostname` hands back `::1` with the brackets stripped, and
 * `http://::1:3000/` is not a URL — it is a parse error that would surface as a
 * dead link rather than as anything anybody could diagnose.
 */
function bracket(host: string): string {
  if (!host.includes(':')) return host
  return host.startsWith('[') ? host : `[${host}]`
}

/**
 * Through the URL parser, or nothing.
 *
 * The parser is the validator: it is the only thing that agrees with what the
 * browser will do with the string, and a hand-written check that disagreed with
 * it would pass addresses the far end then refuses. A path is added when there
 * is none, so what is sent is `http://localhost:3000/` rather than
 * `http://localhost:3000` — the same string the row's Open button sends, which
 * is what stops the two spelling the same page two ways.
 */
function normalise(candidate: string): string | null {
  let url: URL
  try {
    url = new URL(candidate)
  } catch {
    return null
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') return null
  // An address with no host — `http:///foo` parses — reaches nothing.
  if (url.hostname === '') return null
  return url.toString()
}

/**
 * The address as a person should see it back: no scheme, no trailing slash.
 *
 * `http://localhost:3000/` is what goes on the wire and `localhost:3000` is what
 * anybody calls it. Used for the confirmation line and for the field's own value
 * after a row has filled it, so the bar never shows somebody a longer string
 * than the one they typed.
 */
export function shortAddress(url: string): string {
  let parsed: URL
  try {
    parsed = new URL(url)
  } catch {
    return url
  }
  const scheme = parsed.protocol === 'https:' ? 'https://' : ''
  const tail = parsed.pathname === '/' ? '' : parsed.pathname
  return `${scheme}${parsed.host}${tail}${parsed.search}${parsed.hash}`
}

/**
 * What the line under the bar says, given where Open would send it.
 *
 * One sentence, and it names the device rather than describing the mechanism.
 * Somebody reading this screen wants to know which screen the page is about to
 * appear on; how the bytes get there is the whole rest of this product.
 */
export function destinationSentence(target: BrowseTarget, machineLabel: string): string {
  return target.where === BROWSE_MACHINE
    ? `Opens on ${machineLabel}, in its own browser.`
    : 'Opens here, in a new tab of this browser.'
}
