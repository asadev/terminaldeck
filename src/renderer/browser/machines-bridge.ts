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
  STATE_LABEL,
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
  /**
   * Take that address back, so the number means this computer again.
   *
   * **Optional, and deliberately not in {@link MACHINE_METHODS}.** The rule this
   * file was written around is that a preload missing one method must not cost
   * the browser its port list: a build whose preload predates this can still
   * choose a machine, list its ports and open them. What it cannot do is move a
   * page *home* off a tunnel that kept the port number — so that one gesture
   * says it could not, and nothing else changes.
   */
  releaseOnMachine?(id: string, port: number): Promise<unknown>
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
   * Null when an address can be resolved on it, or the machine's state in the
   * app's own two or three words for it.
   *
   * A **label**, never a sentence. It used to be a sentence, on the argument
   * that a greyed row saying nothing is worse than one that explains itself —
   * and the explanation grew to three lines under a row in a dropdown, which is
   * the habit this project has been deleting all week:
   *
   *   > *"don't put any single statement in anywhere … We want simplicity. Let
   *   > the smart people use it. Smart people knows how it works."*
   *
   * The row still says why it is greyed, because *"we always need a truth"* —
   * it says it in {@link STATE_LABEL}'s words, which is what the Machines panel
   * has always called the same state, so there is one vocabulary for a machine's
   * condition rather than two.
   */
  unreachable: string | null
  /**
   * Folders that machine has said it will take a file into, or null.
   *
   * `null` and `[]` are different answers, exactly as they are on
   * `MachineLinkState.folders`, which this is copied straight off: `null` is
   * *that machine never said* — a server, or a build older than the field — and
   * `[]` is *somebody chose no folders for this device*, which is a real state
   * with a real remedy on the other keyboard.
   *
   * It is here for the downloads destination picker, which offers these as the
   * folders a download may be delivered into. The far machine decides for itself
   * whether to accept one — `storeForFolder` in `remote/server.ts` — so this list
   * is what to *offer*, never a claim about what will be allowed.
   */
  folders: string[] | null
  /**
   * The longer reason, when there is one that the label cannot carry — the
   * relay's own words for an `error`, a server's own words for a refusal.
   *
   * **Never drawn.** It is the row's `title` and nothing else, which is the same
   * bargain the toolbar struck when its buttons lost their captions: *"when I
   * hover, it should show the title … Instead of this line, show only the
   * name."* A machine that says `Cannot connect` and a person who wants to know
   * what the relay actually said are two different needs, and only the first of
   * them belongs on a screen.
   */
  detail: string | null
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
 * The machine's state, when that state means an address cannot be typed at it —
 * or null when it can.
 *
 * Read in two places: at the end of its own row in the picker, and in the notice
 * band when a machine that was chosen goes away underneath somebody. Both are
 * next to the machine's name, so the label does not repeat it.
 *
 * `STATE_LABEL` is the Machines panel's own wording for these five states, not a
 * second set written for this menu. A machine that says **Connecting** in the
 * sidebar and something else in a dropdown is two vocabularies for one fact.
 */
function unreachableFor(link: MachineLinkState | null): string | null {
  if (link === null) return STATE_LABEL.offline
  if (link.state !== 'online') return STATE_LABEL[link.state]
  /*
   * Online, and still not offering its ports.
   *
   * One cause now, where there used to be two. The other was a **guest**: a
   * device lent a folder was told nothing was listening anywhere, because a
   * port could not be attributed to a folder and the safe end of "every port or
   * none" was none. Asad hit it from his own Mac, connected to his PC as a
   * guest, and it is fixed on the far side rather than described on this one —
   * `localhostAllowed` and `grantedPorts` in `src/main/remote/server.ts`. A
   * guest now reaches the ports its own grant covers, so a machine that reaches
   * this line is genuinely running a build older than that rule.
   */
  if (!link.capabilities.includes('localhost')) return 'Older build'
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
      unreachable: unreachableFor(link),
      folders: link?.folders ?? null,
      // Only an `error` has anything to add: the other four states are fully
      // described by their label, and repeating one in a tooltip would be the
      // sentence coming back through a different door.
      detail: link?.state === 'error' ? (link.reason ?? null) : null,
    }
  })
}

/**
 * Has the chosen machine stopped being one an address can be typed at?
 *
 * Null while the selection is still good. Otherwise the machine and its state,
 * because a picker that silently reset itself would be a control changing under
 * somebody's hand, and one that stayed pointed at a machine that had gone would
 * refuse every localhost address until they worked out why.
 *
 * **A name and a label, not a sentence.** It used to add *"Addresses now open on
 * this machine"* to the row's own sentence, which is a statement of what the
 * person can already see happening — the picker in front of them has just
 * snapped back. `differentPortNote` at the bottom of this file was cut to
 * `office-pc:3000 → :53412` for the same reason and this is the same shape.
 *
 * A pure function rather than three conditions inside the effect that owns it,
 * for the reason every rule in this file is: this project's test run has no DOM,
 * so an effect is the one place a rule cannot be held to anything.
 */
export function lostMachine(machines: readonly MachineChoice[], selected: string): string | null {
  if (selected === THIS_MACHINE) return null
  const chosen = machines.find((machine) => machine.id === selected)
  if (chosen && chosen.unreachable === null) return null
  // Forgotten, or never in the list at all — a machine this window has no row
  // for is one it cannot even name.
  if (!chosen) return 'That machine is no longer paired'
  return `${chosen.name} — ${chosen.unreachable}`
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
 * The tunnel standing on the local address a page is about to be opened at.
 *
 * ## Why this exists, and it is not bookkeeping
 *
 * `localhost-reach.ts` keeps the far machine's own port *number* on this
 * computer whenever it was free — rung 1 of its ladder, the ordinary case, and
 * the whole reason a dev server's own redirects survive the trip. The
 * consequence is that while that tunnel is up, `localhost:3100` **here** is the
 * PC's 3100 and there is no address left that means this computer's own.
 *
 * That shipped in 0.9.0 as a control that looked like it worked. Asad moved a
 * page from `Office PC` back to his Mac, the picker took the new name, the page
 * was re-opened at the same `localhost:3100` — which was the tunnel — and
 * Paperclip came back from the PC under a bar reading `Asads-MacBook` in the
 * picker and `Office PC:3100` in the address field:
 *
 *   > *"when i change the machine it should attempt to browse with that machine
 *   > instead of staying on previous one and showing its running there then what
 *   > is the purpose of us if we change from dropdown"*
 *
 * So the port is handed back before the address is used, and this is the rule
 * for which one. A tunnel belonging to the machine being moved *to* is never in
 * the way — asking that machine for the port again gets the same tunnel back,
 * and closing it first would only take the page down and rebuild it.
 *
 * Asked from both sides, which is why it is a rule and not an `if`. Before an
 * address is opened here it answers *whose listener owns that number*; after a
 * far machine has just been given that number it answers *whose did we take it
 * from*, and that one is handed back rather than quietly dropped — a row deleted
 * from the window's list while its tunnel is still answering is a listener no
 * control can see and no badge can name.
 */
export function inTheWay(
  port: number | null,
  next: string,
  opened: readonly ReachedPort[],
): ReachedPort | null {
  if (port === null) return null
  return opened.find((entry) => entry.localPort === port && entry.machineId !== next) ?? null
}

/**
 * What choosing a different machine should do to the page already open.
 *
 * ## Why this is a decision and not a setter
 *
 * The picker used to be a *mode*: it decided where the next thing typed would
 * go and left the page on screen exactly where it was. Asad, with a page from
 * his PC in front of him and the picker switched back to the Mac:
 *
 * > *"if I move it to this machine, it's keeping on the same browser, same
 * > machine. It's not moving to this machine. Same link should be again tried on
 * > the new machine… or it should be unsuccessful here also, because we always
 * > need a truth."*
 *
 * Read as a mode that behaviour is defensible. Read as a control wearing a
 * machine's name, sitting above a page, it *claims* the page is on that machine
 * — and it was not. So the page moves, or the control goes back.
 *
 * ## Why the port is the origin's and not the address bar's
 *
 * The tunnel walks a ladder to keep the number and takes an arbitrary local one
 * when both loopbacks are busy — the case this whole feature is for, the same
 * project running on two computers. `localhost:3001` on this Mac can be
 * `localhost:3000` on the PC, so re-opening the number in the address bar would
 * quietly ask the far machine for a different service.
 *
 * ## Moving *home* is not a navigation on its own
 *
 * Every other branch here is answered by opening an address. `here` is not, and
 * that is what 0.9.0 got wrong: the address it opens is `localhost:<origin
 * port>`, and on the ordinary rung that number **is** the tunnel. So this branch
 * carries `give` — the tunnel the caller has to hand back first — and the caller
 * that ignores it is the caller that navigates to the machine it is leaving. See
 * {@link inTheWay}.
 *
 * ## `refused` is a real outcome and has to stay one
 *
 * `https://stripe.com` belongs to Stripe, not to a computer in this room. There
 * is nothing to move, and a picker that silently kept the new name would be
 * stating something false about the page underneath it. Pure so it can be
 * tested: an effect inside a panel is the one place this project's test run
 * cannot look, and `destinationFor` two functions up exists for the same reason.
 */
export type MachineMove =
  /** It is already there. Re-opening it would only lose its scroll position. */
  | { kind: 'already' }
  /**
   * There is no page yet, so the choice is only a choice.
   *
   * A tab showing the start page has no address, and the picker on it is what it
   * was before it could move anything: where the *next* address opens. Treating
   * that as a failed move made the other machine unreachable from a new tab
   * altogether — the picker snapped straight back and printed a refusal, and the
   * remote machine's port list, which is the entire reason to switch there from
   * a blank tab, could never be reached.
   */
  | { kind: 'choose' }
  /**
   * Open this address on this computer.
   *
   * `give` is the tunnel that has to be handed back first, or null. See
   * {@link inTheWay}: this branch is the one that could not be honoured at all
   * while a tunnel held the number, because the address it opens *was* the
   * tunnel.
   */
  | { kind: 'here'; url: string; give: ReachedPort | null }
  /**
   * Open this port on that machine, carrying the path.
   *
   * No `give`, because nothing has to go back *first*. Asking the new machine
   * for the port opens its own listener, and if the old tunnel is standing on
   * the number the ladder in `localhost-reach.ts` takes the next rung and says
   * so through `sameNumber`. Closing the old one before knowing whether the new
   * machine will answer at all would buy a nicer port number at the price of the
   * page that is still on screen.
   *
   * The displaced listener is given back **afterwards**, once the new one has
   * answered — `reachPort` in `BrowserWorkspace.tsx`, through {@link inTheWay}.
   */
  | { kind: 'there'; machineId: string; port: number; url: string }
  /** Nothing to move. `at` is the machine the page is really on, for putting the picker back. */
  | { kind: 'refused'; at: string }

export function moveFor(
  next: string,
  url: string,
  opened: readonly ReachedPort[],
): MachineMove {
  const here = servedBy(url, opened)
  const at = here?.machineId ?? THIS_MACHINE
  if (next === at) return { kind: 'already' }
  // No address at all is the start page, not a page that refuses to move.
  if (url.trim() === '') return { kind: 'choose' }
  // The port on whichever machine is serving it — see the note above on why
  // this is not the number in the address bar.
  const port = here ? here.port : loopbackPort(url)
  if (port === null) return { kind: 'refused', at }
  if (next === THIS_MACHINE) {
    return {
      kind: 'here',
      url: reachedAddress(url, `http://localhost:${port}/`),
      give: inTheWay(port, next, opened),
    }
  }
  return { kind: 'there', machineId: next, port, url }
}

/**
 * The caveat, when the port numbers could not be kept the same.
 *
 * Empty when they match, which is the ordinary case. `localhost-reach.ts` walks
 * a three-rung ladder to keep the number and takes an arbitrary one only when
 * both loopbacks are already busy on this machine — which is exactly the case
 * this feature is for, somebody with the same project running on two computers,
 * so the caveat is not a rare one and it is not left to be discovered.
 *
 * It used to be two sentences and ~200 characters of it, printed in a bar under
 * the toolbar — the habit he struck out more times than any other:
 *
 *   > *"don't put any single statement in anywhere … We want simplicity. Let the
 *   > smart people use it. Smart people knows how it works."*
 *
 * So it is the arithmetic and nothing else, the same shape the toolbar's own
 * hover was cut down to for this identical fact: `office-pc:3000 → :53412`.
 * Which number is which is the entire content of the paragraph that was here,
 * and a person who can read a port number can read this.
 */
export function differentPortNote(opened: ReachOpened, machineName: string): string {
  if (opened.sameNumber) return ''
  return `${machineName}:${opened.port} → :${opened.localPort}`
}
