/**
 * The other machines, as the **browser panel** needs them.
 *
 * ## The complaint this answers
 *
 * From the recorded review of 2026-08-18, looking at the in-app browser with a
 * PC connected in the sidebar:
 *
 *   > *"When I click on browser there is no way for me to find all the localhost
 *   > pages of the remote device. I should be able to see the available whole
 *   > ports, and I should be able to type and reach the devices which are not
 *   > here on this device but they are from the other remote device."*
 *
 *   > *"Maybe give a drop down next to somewhere here with the bar, to choose
 *   > which device we are talking to right now."*
 *
 * and the sentence that governs the whole item:
 *
 *   > *"Keep the same one browser window for every device — remote device, local
 *   > device, all should have the same type of same browser window with the same
 *   > tabs, everything. **Shape of the application should not be changing for
 *   > local and remote devices.**"*
 *
 * So there is no second browser and no second kind of tab. There is one address
 * bar, and a picker beside it that decides **which machine the word `localhost`
 * means**. A port over there is turned into an ordinary `http://` address on
 * this machine by `machines:reach` — see `src/main/localhost-reach.ts`, which
 * carries the argument for why a URL is the only answer that keeps the shape.
 *
 * ## Why this file exists rather than `renderer/machines/types.ts`
 *
 * The narrowing does live there and is imported here rather than rewritten: two
 * readers of one wire drift, and this panel would be the one that drifted. What
 * cannot be shared is the **bridge**. `MachinesBridge` lists eighteen methods
 * and resolves to `null` if a preload is missing any one of them — right for a
 * settings panel that pairs, renames and forgets machines, and wrong here,
 * where a preload missing `renameMachine` would silently cost the browser its
 * port list for no reason at all. This asks for the four methods it actually
 * calls.
 *
 * It also reads `window.deck` itself rather than being handed machines by the
 * window, which is the same arrangement `bridge.ts`, `draw-bridge.ts` and
 * `accounts-bridge.ts` in this folder already use. A prop would mean the panel
 * could only ever be given machines by one host component; this way any host
 * that mounts a browser gets the same browser.
 */

import type { DevPort } from './StartPage'
import {
  asView,
  machineNoun,
  type MachineLinkState,
  type MachinesView,
  type RemotePort,
} from '../machines/types'

/**
 * The four channels this panel calls.
 *
 * Named `*Bridge*` on purpose: `src/preload/contract.test.ts` reads every
 * interface in the renderer whose name contains it and fails the build when the
 * preload has stopped exposing one of these. That guard is why a panel calling
 * `browserClaim` against a preload exposing `browserViewClaim` is caught here
 * rather than in a screenshot.
 */
export interface BrowserMachinesBridge {
  listMachines(): Promise<unknown>
  onMachinesState(cb: (view: unknown) => void): () => void
  /** Ask that machine again what is listening on it. The answer arrives on the state push. */
  refreshMachinePorts(id: string): Promise<unknown>
  /** Give one of its ports an address on this machine, or say why not. */
  reachOnMachine(id: string, port: number): Promise<unknown>
}

const MACHINE_METHODS = [
  'listMachines',
  'onMachinesState',
  'refreshMachinePorts',
  'reachOnMachine',
] as const

/**
 * The bridge, or null when this build's preload predates remote localhost.
 *
 * Null is a real state and not a defensive habit: 0.4.0 shipped with
 * `machines:reach` in the main process and nothing in the renderer calling it,
 * so a window running against an older preload is a thing that exists on
 * somebody's disk today. The picker is simply absent then — never drawn and
 * refusing, which is the control this project has a standing rule against.
 */
export function resolveMachinesApi(host?: unknown): BrowserMachinesBridge | null {
  const source =
    host ?? (typeof window === 'undefined' ? undefined : (window as unknown as { deck?: unknown }).deck)
  if (typeof source !== 'object' || source === null) return null
  const record = source as Record<string, unknown>
  for (const method of MACHINE_METHODS) {
    if (typeof record[method] !== 'function') return null
  }
  return source as BrowserMachinesBridge
}

/* ------------------------------------------------------------ the choices -- */

/** The picker's value for "this machine", which is the one it starts on. */
export const THIS_MACHINE = ''

/**
 * Which of the two kinds of machine a row is.
 *
 * The words are `SERVERS-DESIGN.md` §1.1's, and the discriminator there is
 * mechanical rather than a matter of taste: **a device runs this app at the far
 * end and a server does not.** That is why they are paired two different ways
 * and reached two different ways, and it is the only reason this field exists.
 *
 * It changes exactly one line of behaviour — which bridge is asked for an
 * address — and nothing a person sees. The rows are identical, the sentences
 * are identical, the tabs are identical: *"shape of the application should not
 * be changing for local and remote devices."* A field that started deciding
 * layout would be this browser growing a second kind of machine, which is the
 * thing it was arranged against.
 */
export type MachineKind = 'device' | 'server'

/** One machine as the picker draws it, refusal and all. */
export interface MachineChoice {
  kind: MachineKind
  id: string
  /** What it calls itself. */
  name: string
  /** `Mac`, `PC`, `machine` — never guessed. See `machineNoun`. */
  noun: string
  /** What it says it is serving, in the shape the start page draws a port in. */
  ports: DevPort[]
  /**
   * Null when an address can be resolved on it, or one sentence saying why not.
   *
   * A sentence rather than a boolean because the four reasons are four
   * different things to do about it — connect the machine, wait, approve this
   * one over there, or update the build over there — and a greyed row that says
   * none of them is the control this project keeps deleting.
   */
  refusal: string | null
}

/**
 * The far machine's ports, in the shape the start page already draws.
 *
 * `ours` is false for every row and that is a fact rather than a default: the
 * far machine filters its own listeners out of the list before it sends it —
 * `reserved` in `src/main/remote/tunnel.ts`, fed from `own-ports.ts` — so
 * nothing that arrives here belongs to the app running over there. The fold
 * that hides this app's own ports therefore never appears for a remote machine,
 * because there is nothing in it, which is correct rather than convenient.
 */
export function asDevPorts(ports: readonly RemotePort[]): DevPort[] {
  return ports
    .map((port): DevPort => ({ port: port.port, process: port.process, guessed: port.guessed, ours: false }))
    .sort((a, b) => Number(a.guessed) - Number(b.guessed) || a.port - b.port)
}

/**
 * Why this machine cannot be typed at, or null when it can.
 *
 * Every branch names the machine, because this sentence is read in two places —
 * under its row in the picker, and in the notice band when a machine that was
 * chosen goes away underneath somebody — and a sentence that only made sense
 * under its own row would be a mystery in the band.
 */
function refusalFor(name: string, link: MachineLinkState | null): string | null {
  if (link === null || link.state === 'offline') {
    return `This desktop is not connected to ${name} right now.`
  }
  if (link.state === 'connecting') return `This desktop is still connecting to ${name}.`
  if (link.state === 'awaiting-approval') return `${name} has not approved this desktop yet.`
  if (link.state === 'error') {
    return link.reason ?? `This desktop cannot connect to ${name}.`
  }
  /*
   * Online, and still not offering its ports.
   *
   * Two causes, one sentence, because from here they are genuinely
   * indistinguishable and both are true statements about that machine: it is an
   * older build that never had the capability, or this desktop is a *guest*
   * there rather than one of its owner's own machines. The second is the rule
   * `localhostAllowed` in `src/main/remote/server.ts` enforces — a guest is lent
   * a folder, and a port cannot be attributed to a folder, so a guest is lent no
   * ports at all — and it is stated here in the words of the person reading it
   * rather than in the words of the rule.
   */
  if (!link.capabilities.includes('localhost')) {
    return (
      `${name} is not sharing what it is serving with this desktop. Either it is running an older ` +
      'version, or this desktop is a guest there rather than one of its own machines.'
    )
  }
  return null
}

/**
 * Every machine this desktop is paired to, in the order the picker lists them.
 *
 * Machines that cannot be reached are **kept**, carrying their sentence. That is
 * deliberate and it is the difference between a picker and a list of what is
 * working: a machine that was there this morning and is not now is the single
 * most useful thing this dropdown can say, and dropping the row would leave
 * somebody looking for a computer that had quietly disappeared from a menu.
 *
 * "This machine" is not in here. The picker draws it itself, first, always — it
 * has no id, no link and nothing that can go wrong with it, and giving it a row
 * in this list would mean inventing a `Machine` that does not exist.
 */
export function machineChoices(view: MachinesView): MachineChoice[] {
  return view.machines.map((machine) => {
    const link = view.links.find((one) => one.id === machine.id) ?? null
    const noun = machineNoun(link?.hostPlatform === '' || link === null ? machine.platform : link.hostPlatform)
    const name = machine.name === '' ? `That ${noun}` : machine.name
    return {
      kind: 'device',
      id: machine.id,
      name,
      noun,
      ports: asDevPorts(link?.ports ?? []),
      refusal: refusalFor(name, link),
    }
  })
}

/**
 * Has the chosen machine stopped being one an address can be typed at?
 *
 * Null while the selection is still good. Otherwise the sentence to show, which
 * is the machine's own refusal with what happens next added to it — because a
 * picker that silently reset itself would be a control changing under somebody's
 * hand, and one that stayed pointed at a machine that had gone would refuse
 * every localhost address until they worked out why.
 *
 * A pure function rather than three conditions inside the effect that owns it,
 * for the reason every rule in this file is: this project's test run has no DOM,
 * so an effect is the one place a rule cannot be held to anything.
 */
export function lostMachine(machines: readonly MachineChoice[], selected: string): string | null {
  if (selected === THIS_MACHINE) return null
  const chosen = machines.find((machine) => machine.id === selected)
  if (chosen && chosen.refusal === null) return null
  // Forgotten, or never in the list at all — a machine this window has no row
  // for is one it can say nothing else about.
  const because = chosen?.refusal ?? 'That machine is no longer paired with this one.'
  return `${because} Addresses now open on this machine.`
}

/** Read the whole view off the bridge. An unreadable answer is an empty one. */
export function readMachines(value: unknown): MachinesView {
  return asView(value)
}

/* -------------------------------------------------------------- reaching -- */

/** A port over there, now answering at a URL over here. Mirrors `ReachOpened`. */
export interface ReachOpened {
  ok: true
  url: string
  /** The port on the far machine. */
  port: number
  /** The port on this one. Equal to `port` whenever it could be had. */
  localPort: number
  /** False when the numbers differ — see the caveat `localhost-reach.ts` carries. */
  sameNumber: boolean
}

export interface ReachRefused {
  ok: false
  /** Written for a reader. Shown, never swallowed. */
  message: string
}

export type ReachAnswer = ReachOpened | ReachRefused

/**
 * Narrow whatever came back across the bridge.
 *
 * The channel is typed `unknown`, and the refusal branch matters more than the
 * success one: an answer this cannot read is still an answer somebody clicked
 * for, so it becomes a sentence rather than a silence. That is the whole
 * instruction for this feature — *a refusal is a sentence; show it*.
 */
export function readReach(value: unknown): ReachAnswer {
  if (typeof value !== 'object' || value === null) {
    return { ok: false, message: 'That machine was asked for the port and gave no answer.' }
  }
  const record = value as Record<string, unknown>
  if (record.ok !== true) {
    const message = typeof record.message === 'string' && record.message !== '' ? record.message : ''
    return { ok: false, message: message || 'That port could not be opened, and no reason came back.' }
  }
  const url = typeof record.url === 'string' ? record.url : ''
  const port = typeof record.port === 'number' ? record.port : 0
  const localPort = typeof record.localPort === 'number' ? record.localPort : 0
  if (url === '' || port <= 0 || localPort <= 0) {
    return { ok: false, message: 'That machine answered about the port without saying where to open it.' }
  }
  // `=== true` rather than truthiness: a main process that predates the field
  // must read as "the numbers may differ", which is the answer that makes the
  // window *say* something rather than quietly promise they match.
  return { ok: true, url, port, localPort, sameNumber: record.sameNumber === true }
}

/**
 * Loopback names, as a browser resolves them.
 *
 * Exact hosts only, and `foo.localhost` is deliberately not here. Chromium does
 * resolve it to the loopback, but the tunnel is a byte pipe: the request that
 * arrives on the far machine would carry `Host: 127.0.0.1:<port>`, so a server
 * routing by virtual host would answer with the wrong site rather than with the
 * one that was asked for. A page that loads the wrong thing is worse than one
 * that loads nothing, so a named host is left to resolve where it always did.
 */
const LOOPBACK = /^(localhost\.?|127(?:\.\d{1,3}){3}|\[::1\]|::1|0\.0\.0\.0)$/i

/**
 * Which port this address is on, when it is an address on this computer.
 *
 * Null for everything else, and that null is the rule the picker actually
 * implements: **choosing a machine changes what `localhost` means and nothing
 * else.** `example.com` is the same site from either computer, so rerouting it
 * through a tunnel would buy nothing and cost the page its real origin.
 */
export function loopbackPort(url: string): number | null {
  try {
    const parsed = new URL(url)
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null
    if (!LOOPBACK.test(parsed.hostname)) return null
    const port = parsed.port === '' ? (parsed.protocol === 'https:' ? 443 : 80) : Number(parsed.port)
    return Number.isInteger(port) && port >= 1 && port <= 65535 ? port : null
  } catch {
    return null
  }
}

/** What the address bar should do with what was typed, given the chosen machine. */
export type Destination =
  | { kind: 'here'; url: string }
  | { kind: 'there'; machineId: string; port: number; url: string }

/**
 * Where this address opens.
 *
 * Pure and exported because it is the entire behaviour of the picker, and an
 * effect inside a panel is the one place this project's test run cannot look. A
 * change that quietly stopped rerouting `localhost` would leave every render
 * test passing and the feature gone.
 */
export function destinationFor(machineId: string, url: string): Destination {
  if (machineId === THIS_MACHINE) return { kind: 'here', url }
  const port = loopbackPort(url)
  if (port === null) return { kind: 'here', url }
  return { kind: 'there', machineId, port, url }
}

/**
 * The address that was asked for, moved onto the address it was opened at.
 *
 * `localhost:3000/orders?page=2` typed against another machine has to arrive as
 * that machine's `/orders?page=2`, not as its front page. The origin is the only
 * part the tunnel decides; everything to the right of it belongs to whoever
 * typed it.
 */
export function reachedAddress(typed: string, opened: string): string {
  try {
    const from = new URL(typed)
    const to = new URL(opened)
    to.pathname = from.pathname
    to.search = from.search
    to.hash = from.hash
    return to.href
  } catch {
    // An unparseable pair is not worth losing the navigation over: the tunnel's
    // own URL is a page on the machine that was asked for, which is most of what
    // was wanted.
    return opened
  }
}

/* ------------------------------------------------------------- the badge -- */

/** One tunnel this window opened, so a loopback page can name where it comes from. */
export interface ReachedPort {
  machineId: string
  machineName: string
  /** The port on the far machine. */
  port: number
  /** The port on this one, which is what the address bar shows. */
  localPort: number
  sameNumber: boolean
}

/**
 * Which machine is behind the page in the address bar, if any.
 *
 * Answered from the **URL** rather than remembered per tab, and that is what
 * makes it survive a link inside the site, Back, Forward and a reload: those all
 * change the tab's URL without going near the code that opened the tunnel. The
 * address is the evidence; a flag set at navigation time would be a claim that
 * went stale the first time somebody clicked something.
 */
export function servedBy(url: string, opened: readonly ReachedPort[]): ReachedPort | null {
  const port = loopbackPort(url)
  if (port === null) return null
  return opened.find((entry) => entry.localPort === port) ?? null
}

/**
 * The caveat, when the port numbers could not be kept the same.
 *
 * Empty when they match, which is the ordinary case. `localhost-reach.ts` walks
 * a three-rung ladder to keep the number and takes an arbitrary one only when
 * both loopbacks are already busy on this machine — which is exactly the case
 * this feature is for, somebody with the same project running on two computers,
 * so the caveat is not a rare one and it is not left to be discovered.
 */
export function differentPortNote(opened: ReachOpened, machineName: string): string {
  if (opened.sameNumber) return ''
  return (
    `Port ${opened.port} on ${machineName} is being served here on port ${opened.localPort}, because ` +
    `${opened.port} is already in use on this machine. Anything that site writes as an absolute ` +
    `localhost:${opened.port} link will go to this machine’s own port instead.`
  )
}
