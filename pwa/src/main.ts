/**
 * The client itself: six screens, one socket, and no pretending.
 *
 * It was three — pair → sessions → terminal — and that sentence stayed at the
 * top of this file for a while after it stopped being true, which is worth a
 * line of its own because a header that lies is read by everybody and checked by
 * nobody. What is here now:
 *
 *   pair ─────────► sessions ──► terminal
 *                   localhost
 *                   settings ──► machines
 *
 * Three of them are the tab strip — Sessions, Localhost, Settings. `terminal` is
 * pushed from a session row and `machines` from Settings, and the strip stays up
 * on `machines` as well, which is why `LISTING_SCREENS` has four entries and not
 * three: a person one screen deep inside Settings has not left it, and every tab
 * going unmarked reads as having fallen out of the app. `pair` is where a
 * browser with no credential lands — and also where it comes back to when
 * somebody adds a *second* machine, which is why it is reachable from inside the
 * app rather than only before it.
 *
 * **One socket, still, and that is a decision rather than a leftover.** This
 * client can be paired with several machines and talks to exactly the one you
 * are looking at; the phones hold a connection to every machine at once because
 * they deliver alerts, and a browser tab that is closed is not running, so there
 * is nothing a second socket here could be for. `machines.ts` carries the whole
 * argument.
 *
 * The connection is owned here and lives across every screen, because a phone
 * loses it constantly and re-establishing it must not cost the user their place.
 *
 * The rule everything below serves: the banner tells the truth about the
 * connection at all times, and a terminal that is not live is dimmed, has a
 * still cursor, and refuses keys instead of swallowing them.
 */

// xterm's stylesheet first, ours second. Its rules and ours land on the same
// specificity — `.xterm .xterm-viewport` against `.terminal .xterm-viewport` —
// so the order in this file is the only thing that decides, and in the other
// order xterm painted a black gutter down the side of the terminal.
import '@xterm/xterm/css/xterm.css'
import './styles.css'

import { BRAND } from '../../src/shared/brand'
import {
  BROWSE_HERE,
  BROWSE_MACHINE,
  NOWHERE_TO_OPEN,
  browseTargets,
  destinationSentence,
  parseAddress,
  shortAddress,
  type BrowseTarget,
  type BrowseWhere,
} from './browse'
import { Connection, type ConnectionState, type SocketLike } from './connection'
import {
  GO_AND_LOOK,
  NO_COPILOT,
  SAY_TIMEOUT_MS,
  copilotStep,
  deskState,
  grantSentence,
  secondsLeft,
  unavailableSentence,
  type CopilotAction,
  type CopilotState,
} from './copilot'
import {
  ANSWER_PROVENANCE,
  answerSummary,
  browserScanClock,
  createScanRunner,
  isScanning,
  scanAnswer,
  scanPlan,
  statusSentence,
  type AnswerSession,
  type ScanRunner,
  type ScanState,
  type ScanStop,
} from './copilot-scan'
import {
  SCAN_ATTRIBUTE,
  focusRect,
  mountScanField,
  watchScanInterruption,
  type FieldReading,
  type InterruptionWatch,
  type ScanFieldHandle,
} from './scan-field'
import {
  CREDENTIAL_EXPLANATION,
  credentialHeadline,
  type CredentialNotice,
} from './credential'
import {
  DIRECT,
  hostKeyBytes,
  loadDeviceIdentity,
  type DeckEndpoint,
  type RelayEndpoint,
} from './endpoint'
import {
  NO_DEV,
  devRowView,
  devStep,
  devWaitingSentence,
  devserverOffered,
  type DevAction,
  type DevState,
} from './dev-server'
import { deviceStanding, devicesOffered, fingerprintText, lastSeenSentence } from './devices'
import {
  INSTALL_COMMAND,
  checkFields,
  runSignIn,
  type FieldFault,
  type SignInFailure,
  type SignInFields,
  type SignInMethod,
} from './add-server'
import { MAX_WATCH_WINDOWS, WATCH_UNAVAILABLE, WatchCanvas, watchOffered } from './browser-view'
import { folderOffer, foldersAfter, noFoldersSentence, pickerRows } from './folders'
import { machineNoun, readHostPlatform, type HostPlatform } from './host-platform'
import { createKeyBar, type KeyBarHandle } from './keybar'
import {
  CHECK_PATIENCE_MS,
  NO_LOCALHOST,
  PUBLIC_ADDRESS_ANSWER,
  checkSentence,
  localhostOffered,
  openSentence,
  webOfferedHere,
  localhostStep,
  noPortsSentence,
  stalePortsSentence,
  type LocalhostAction,
  type LocalhostState,
} from './localhost'
import {
  MACHINES_FOOTNOTE,
  clearBook as clearMachineBook,
  cleanNickname,
  currentMachine,
  endpointSummary,
  forgetMachine,
  lastReachedSentence,
  loadMachines,
  machineById,
  machineId,
  machineLabel,
  machineLabels,
  MAX_NICKNAME_LENGTH,
  NO_MACHINES,
  renameMachine,
  saveBook,
  selectMachine,
  withCredential,
  withHostName,
  withMachine,
  type MachineBook,
  type StoredMachine,
} from './machines'
import { ChatComposer, ChatView } from './chat-view'
import { infoDot } from './info-dot'
import { SessionBar } from './session-bar'
import { SessionControls } from './session-controls'
import { ServerSettings } from './server-settings'
import { watchPhysicalKeyboard, type KeyBarFit, type MatchMedia } from './physical-keyboard'
import {
  clearPairing,
  describeDevice,
  REMEMBERED_TTL_MS,
  renewed,
  savePairing,
  type StoredCredential,
} from './pair'
import {
  NAMING_FOOTNOTE,
  categoryTitle,
  directAppPorts,
  portRowDetail,
  portRowTitle,
  secondAction,
  sections as portSections,
  type LocalhostRow,
  type LocalhostSection,
} from './port-catalog'
import { MAX_NAME_LENGTH, PortBook } from './port-book'
import {
  canGoLarger,
  canGoSmaller,
  largerText,
  readTextSize,
  smallerText,
  textSizeLabel,
  writeTextSize,
} from './text-size'
import { VERSION } from './version'
import { clientIsAhead, hostKindNoun } from './host-version'
import { normaliseCode } from '../../src/shared/short-code'
import { asCodeField } from './code-field'
import { browserStores, purgeRetired, type Remember } from './remember'
import { relaySocket } from './relay-socket'
/*
 * The desktop's own backfill, imported rather than reimplemented.
 *
 * `src/renderer/components/terminal-backfill.ts` is where the argument lives —
 * xterm yields to the renderer every 12 ms while a large write drains, so every
 * intermediate scroll position is painted — and it has no imports, no DOM types
 * and no React in it precisely so that the other client can use it. Two copies
 * of one policy is how the desktop ends up fixed and the phone does not, which
 * is the whole shape of tonight's review.
 */
import { holdUntilFilled, QUIET_MS, type Backfill } from '../../src/renderer/components/terminal-backfill'
import { lookupMachine } from './rendezvous'
import {
  chunkInput,
  type DevServerReport,
  type DeviceRosterRow,
  type HostKind,
  type RemoteSession,
  type ServerMessage,
} from './protocol-client'
import {
  closeOffered,
  closeQuestion,
  formatSince,
  noticeAfter,
  sessionTone,
  shortenPath,
  sortSessions,
  statusLabel,
} from './sessions'
import { createTerminal, type TerminalHandle } from './terminal'
import { Upload, promptWord, transferLine } from './upload'
import {
  THEME_COLOR,
  THEME_ICON,
  nextChoice,
  readChoice,
  resolveAppearance,
  stampAppearance,
  themeTitle,
  watchSystemAppearance,
  writeChoice,
  type Appearance,
  type SystemAppearance,
  type ThemeChoice,
} from './theme'

/**
 * Where a *direct* connection answers.
 *
 * Same origin as this page, always: on this route the client is served by the
 * very process it then talks to, so there is nothing to configure and no way to
 * point a paired browser at a different machine by editing a field.
 *
 * This used to be the only route, which meant this client worked for exactly one
 * kind of person — somebody already running Tailscale, because that is what
 * terminates the TLS on the address it is served from. It is now the fallback.
 * The relay is the product's network and `relay-socket.ts` is how this client
 * reaches it; `endpoint.ts` decides which of the two a given pairing is.
 */
// Kept in step with `WS_PATH` in src/main/remote/server.ts by hand, because
// that module is main-process code — importing it here would drag node:http
// into a browser bundle. It belongs in protocol.ts, where both sides could
// import it; see the handoff note.
const SOCKET_PATH = '/ws'

function socketUrl(location: Location): string {
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${scheme}//${location.host}${SOCKET_PATH}`
}

/**
 * The screens, and why `localhost` is one of them rather than a panel.
 *
 * A person on this page is doing one of two things — driving a session, or
 * looking at what the machine is serving — and on a phone those cannot share a
 * viewport. So it is a screen, reached from the same strip of tabs the session
 * list is, and it appears only when the desktop advertised `localhost`. See
 * `localhost.ts` for what that screen can honestly do from a browser tab and
 * what it deliberately does not pretend to.
 */
type Screen =
  | 'copilot'
  | 'pair'
  /**
   * Sign in to a server, which is the other way a machine gets into this book.
   *
   * Its own screen rather than a mode of the pair screen, because the two ask
   * for different things from different people. Pairing is six digits read off
   * a desktop by somebody standing at it; this is an address and a login, for a
   * machine with no screen and nobody near it. A single screen that switched
   * between them would be a form whose fields change under the person filling
   * it in.
   */
  | 'add-server'
  | 'sessions'
  | 'localhost'
  | 'settings'
  | 'machines'
  | 'devices'
  | 'browser'
  | 'terminal'

/** One watchable surface, as the host reports it in `browser.surfaces.rows`. */
type WatchSurface = { window: string; url: string; title: string; live: boolean }

/**
 * The tabs, and why Machines is not one of them.
 *
 * The phone answered this first and the answer is followed rather than
 * re-litigated — see the header of `ios/TerminalDeck/Screens/DeckTabs.swift`, which
 * records him asking for four pills and then moving Machines off the bar a minute
 * later because pairing a machine is something done once, and a strip of tabs is
 * for the screens somebody moves between all day.
 *
 * So: Copilot, Sessions, Localhost, Settings — and Machines is a screen pushed
 * from Settings, reached by a chevron row that says how many are paired. The one
 * place this client differs is that the strip stays visible on the Machines
 * screen, which is the same call the phone makes ("Pill should be on here only on
 * the homepage or machines or settings") for the same reason: a person who has
 * pushed one screen deep has not left the app.
 *
 * **Copilot is leftmost**, and that supersedes the three-tab arrangement rather
 * than being added beside it: *"A fourth pill, and the copilot goes leftmost —
 * Copilot · Sessions · Localhost · Settings"*, said about the phone after he had
 * looked at it with the copilot in place. It is drawn only when the welcome
 * carried a copilot for *this* device, which never happens for a guest — see
 * `CopilotState.offered`.
 */
const LISTING_SCREENS: readonly Screen[] = [
  'copilot',
  'sessions',
  'localhost',
  'settings',
  'machines',
  'devices',
  'browser',
]

/**
 * Text on its way into the terminal rather than into the DOM.
 *
 * Everything printed between brackets by this client is written into an
 * emulator that executes what it is given, so a string that came off the socket
 * has its escapes taken away first. The desktop does not put remote text in its
 * refusals today; that is a property of the other side of the wire, and this is
 * the side that pays if it changes.
 */
function plain(text: string): string {
  // Escaped, never literal: a raw control byte in a character class is
  // invisible in every diff, which is the trap protocol.ts documents.
  return text.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 200)
}

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className?: string,
  text?: string,
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag)
  if (className !== undefined) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

/** The one namespace an SVG child has to be made in. Spelled once, here. */
const SVG_NS = 'http://www.w3.org/2000/svg'

/**
 * The appearance icon, as an element.
 *
 * `createElementNS`, not `createElement`, and that is the whole reason this
 * helper exists rather than three lines at the call site: an `<svg>` built with
 * `createElement` lands in the HTML namespace, where it is an unknown inline
 * element that lays out as text and paints nothing. It type-checks, it appears
 * in the DOM inspector spelled correctly, and the header simply has a gap in it
 * — the exact class of failure this repo's rule about looking at a change is
 * written for.
 *
 * The geometry comes from `theme.ts` as data. What is decided here is the frame
 * around it: a 24-unit viewBox drawn at 16px, `currentColor` so the glyph is the
 * header's ink in both themes without a hex value living outside the tokens, and
 * `aria-hidden` because the button around it already carries the whole name and
 * a second one would have a screen reader say it twice.
 */
/**
 * A paperclip, in the same 24-unit frame and the same stroke as the theme glyph.
 *
 * A glyph and no word, which is the standing rule this round — *"don't put any
 * single statement in anywhere… smart people knows how it works"* — and it is
 * also what the two native clients do: iOS puts *Send Photo or Video* behind an
 * `ellipsis.circle`, Android behind an icon, and neither writes a sentence on
 * the terminal explaining that a terminal takes files.
 */
function clipIcon(): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('width', '16')
  svg.setAttribute('height', '16')
  svg.setAttribute('fill', 'none')
  svg.setAttribute('stroke', 'currentColor')
  svg.setAttribute('stroke-width', '1.8')
  svg.setAttribute('stroke-linecap', 'round')
  svg.setAttribute('stroke-linejoin', 'round')
  svg.setAttribute('aria-hidden', 'true')
  const path = document.createElementNS(SVG_NS, 'path')
  path.setAttribute(
    'd',
    'M20.5 11.5 11.9 20a5 5 0 0 1-7.1-7.1l8.6-8.5a3.3 3.3 0 0 1 4.7 4.7l-8.6 8.5a1.7 1.7 0 0 1-2.3-2.3l7.9-7.9',
  )
  svg.append(path)
  return svg
}

/**
 * The mode toggle's glyph — and it draws **where you are going**, not where you are.
 *
 * His correction, in as many words, and it reverses what was built the night
 * before: *"chat icon should be when I am on the terminal mode. And when I am on
 * the chat mode, then it should show the terminal icon, so I can switch to that
 * one instead of what I am on right now."*
 *
 * So `mode` is the *destination*: `'chat'` draws a speech bubble and takes you to
 * the conversation; `'terminal'` draws a prompt and takes you back.
 */
function modeIcon(mode: 'chat' | 'terminal'): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('width', '16')
  svg.setAttribute('height', '16')
  svg.setAttribute('fill', 'none')
  svg.setAttribute('stroke', 'currentColor')
  svg.setAttribute('stroke-width', '1.8')
  svg.setAttribute('stroke-linecap', 'round')
  svg.setAttribute('stroke-linejoin', 'round')
  svg.setAttribute('aria-hidden', 'true')
  if (mode === 'chat') {
    const bubble = document.createElementNS(SVG_NS, 'path')
    bubble.setAttribute('d', 'M21 12a8 8 0 0 1-8 8H8l-5 3 1.4-4.2A8 8 0 1 1 21 12Z')
    svg.append(bubble)
    return svg
  }
  const box = document.createElementNS(SVG_NS, 'rect')
  box.setAttribute('x', '3')
  box.setAttribute('y', '4')
  box.setAttribute('width', '18')
  box.setAttribute('height', '16')
  box.setAttribute('rx', '2')
  const prompt = document.createElementNS(SVG_NS, 'path')
  prompt.setAttribute('d', 'm7 10 3 2.5L7 15M12.5 15H17')
  svg.append(box, prompt)
  return svg
}

function themeIcon(choice: ThemeChoice): SVGSVGElement {
  const svg = document.createElementNS(SVG_NS, 'svg')
  svg.setAttribute('viewBox', '0 0 24 24')
  svg.setAttribute('width', '16')
  svg.setAttribute('height', '16')
  svg.setAttribute('fill', 'none')
  svg.setAttribute('stroke', 'currentColor')
  svg.setAttribute('stroke-width', '1.8')
  svg.setAttribute('stroke-linecap', 'round')
  svg.setAttribute('stroke-linejoin', 'round')
  svg.setAttribute('aria-hidden', 'true')
  for (const part of THEME_ICON[choice]) {
    const node = document.createElementNS(SVG_NS, part.el)
    for (const [name, value] of Object.entries(part.attrs)) node.setAttribute(name, value)
    svg.append(node)
  }
  return svg
}

/**
 * One consent argument, as a line somebody reads before deciding.
 *
 * `args` is `Record<string, unknown>` on the wire because a tool declares its own
 * shape, so this has to render a value it has never seen. Objects and arrays are
 * shown as JSON rather than as `[object Object]`, which is the one rendering that
 * would hide the very thing being approved — the path a write is about, the text
 * about to be typed into somebody's session.
 *
 * Bounded, because it lands on a screen a decision is made on, and everything
 * here goes through `plain` at the call site like every other string that came
 * off this socket. A value too long to show is cut with an ellipsis rather than
 * silently truncated: a person who cannot see all of an argument needs to know
 * that, and the machine's own screen has the whole of it.
 */
function describeArg(value: unknown): string {
  if (value === null) return 'null'
  if (typeof value === 'string') return cut(value)
  if (typeof value === 'number' || typeof value === 'boolean') return String(value)
  try {
    return cut(JSON.stringify(value) ?? String(value))
  } catch {
    // A circular structure, which nothing on this wire produces and which must
    // not be the reason a consent sheet fails to draw.
    return '(cannot be shown here — look at the machine)'
  }
}

/** 240 characters of an argument, and a mark saying there was more. */
function cut(text: string): string {
  return text.length <= 240 ? text : `${text.slice(0, 240)}…`
}

/**
 * The scan's answer, restated as a question for the copilot.
 *
 * Put into the message box rather than sent, always. What reaches the copilot has
 * to be something the person read and pressed Send on — a client that composed a
 * message and dispatched it would be spending somebody's tokens on a sentence
 * they never saw, which is exactly the kind of thing the consent gate exists to
 * stop happening elsewhere.
 *
 * It carries the same facts the card shows and adds no claim of its own: the
 * session, the reason, the note. The copilot is on the machine and can read those
 * sessions for itself; what it cannot do is know which ones this browser was just
 * looking at.
 */
function answerAsQuestion(answer: readonly AnswerSession[]): string {
  const lines = ['I am looking at these sessions. What should I deal with first?']
  for (const session of answer) {
    for (const line of session.lines) {
      if (!line.shown) continue
      lines.push(line.note === '' ? `- ${session.title}: ${line.why}` : `- ${session.title}: ${line.why} — ${line.note}`)
    }
  }
  return lines.join('\n')
}

class Deck {
  private readonly root: HTMLElement
  private readonly header = element('header', 'header')
  private readonly back = element('button', 'header__back', '‹')
  private readonly title = element('h1', 'header__title')
  private readonly subtitle = element('p', 'header__subtitle')
  private readonly banner = element('div', 'banner')
  private readonly bannerText = element('span', 'banner__text')
  private readonly bannerAction = element('button', 'banner__action', 'Retry now')
  /**
   * The appearance, as **one icon** in the header rather than three pills.
   *
   * > *"On the top header bar I still see the same three separate — Auto, Light,
   * > Dark. You can just give one small icon for switching."*
   *
   * It is the same control the marketing site's header grew a few hours before
   * he said that, and the same idea rather than the same code: one button
   * cycling system → light → dark, showing the state it is in. The three pills
   * were an honest reading of "three states need three affordances" and they
   * were wrong about where the space goes — a header on a 390px phone has one
   * job, which is the title of the thing you are looking at, and the appearance
   * is a control somebody touches twice in the life of an install.
   *
   * A button rather than a `<div>` of buttons, so a keyboard reaches it in one
   * tab stop and a screen reader is told one thing. What it is on and what a
   * press does are both in `themeTitle`, because a cycling icon has exactly one
   * way of being unreadable and that is a label that could mean either.
   *
   * Part of the chrome and not of a screen, for the same reason the tab strip
   * is: it has to survive every screen it is drawn over, and it has to be
   * reachable before pairing — the pair screen is the first thing a new reader
   * sees, and it is a whole screen of paper or charcoal with nothing else on it.
   * Being one 28px button rather than three pills is also what lets it stay in
   * the header **inside a terminal on a phone**, which the strip could not: the
   * stylesheet used to delete it at that width to save the session's title.
   */
  private readonly appearanceButton = element('button', 'appearance')
  /**
   * Send a file into the session on screen. One glyph, in the header.
   *
   * In the header rather than in the key bar, and that is not decoration: the key
   * bar is deleted outright where there is a real keyboard — `physical-keyboard.ts`
   * — so a control living there would vanish on the laptop, which is the case
   * where somebody most obviously has a file to send. The header is the one piece
   * of chrome a terminal keeps in every configuration.
   *
   * Absent rather than disabled when the machine did not advertise `upload`,
   * following the same rule as New session and the port list: a control whose
   * only function is to explain that it does not function is a fake feature.
   */
  private readonly attachButton = element('button', 'appearance')
  /**
   * Terminal ⇄ chat, in the header beside the paperclip.
   *
   * In the header rather than in the session bar because it is not a *reading*
   * about the session, it is the thing you press to change what you are looking
   * at — the same class of control the paperclip is, on the same session.
   *
   * Absent rather than disabled when the machine did not advertise `chat`,
   * following the rule the paperclip and New session already follow: a control
   * whose only function is to explain that it does not function is a fake
   * feature.
   */
  private readonly modeButton = element('button', 'appearance')
  /**
   * The picker, and the only reason it is a permanent node.
   *
   * A file input has to be in the document when it is clicked or Safari refuses
   * the gesture, and it must not be replaced between the tap and the `change` or
   * the event lands on a node nobody is listening to. It is never seen: the tap
   * target is the button above.
   */
  private readonly fileField = element('input')
  /**
   * Where a machine's request for a GitHub login is reported.
   *
   * A sibling of the content rather than part of a screen, because it has to be
   * readable from the terminal as well as from the session list — a `git push`
   * is asked for from inside a session, which is exactly where somebody is
   * looking when it happens.
   */
  private readonly credentialCard = element('section', 'ask')
  /**
   * The two places this client can be when it is not in a terminal.
   *
   * A strip rather than a menu, and a sibling of the content rather than part of
   * a screen, because it has to survive both of the screens it switches between
   * — a control that is redrawn by the thing it selects cannot show which thing
   * is selected. It is empty and hidden entirely against a desktop that does not
   * advertise `localhost`: one tab is not a choice, and the standing rule here is
   * that a control with one option is not drawn as one.
   */
  private readonly tabs = element('nav', 'tabs')
  private readonly content = element('main', 'content')
  /**
   * A sentence that has been said and will stop being said.
   *
   * The only floating thing in this client, and it is here rather than inside a
   * screen for the same reason the tab strip is: it is raised by a control on a
   * row that the very next frame from the desktop will rebuild, and a message
   * living inside that row would disappear with it before anybody read it.
   *
   * `aria-live` rather than a role, because it is an aside — nothing here is ever
   * the only place something is said, and a screen reader should mention it
   * without abandoning what the reader was on.
   */
  private readonly toast = element('div', 'toast')

  private connection: Connection | null = null
  private state: ConnectionState = { phase: 'offline', detail: 'Not connected.', retryAt: null, attempts: 0 }
  /**
   * How this browser reaches the machine it is paired with.
   *
   * Held beside the credential rather than read off the connection, for the same
   * reason `hostPlatform` is: the pair screen has no socket by definition, and
   * the credential is written from more than one place. `DIRECT` until something
   * says otherwise, which is both the unpaired state and the state of every
   * browser that paired before the relay existed.
   */
  private endpoint: DeckEndpoint = DIRECT
  /**
   * The two places a pairing can live, and the rule about which.
   *
   * See `remember.ts`. Resolved once, because probing `localStorage` on a
   * browser that refuses it throws and the fallback has to be the same object
   * every time — a store that was memory on one call and real on the next would
   * lose a credential between writing it and reading it back.
   */
  private readonly stores = browserStores()
  /**
   * How long this pairing is meant to last, as the person answered it.
   *
   * `this-tab` is the default and it is the safe one. The premise of a browser
   * client is the computer you do not own, and the question is asked before
   * anything is written — so an unanswered state cannot exist, and if one
   * somehow did it would be the one that leaves nothing behind.
   *
   * Seeded from the pairing already in storage when there is one, so somebody
   * re-pairing a browser they had remembered is not asked to decide the same
   * thing twice. `forget` puts it back, because that is the person saying this
   * is not their machine any more.
   */
  private remember: Remember = 'this-tab'
  /**
   * This browser's own X25519 identity, as the machine knows it.
   *
   * Loaded once at startup rather than per connection. It is what
   * `isKnownDevice` on the machine matches every reconnect against, so a client
   * that generated a fresh one per socket would pair successfully and then be
   * refused by its own next attempt.
   *
   * Made in memory when there is none stored, and written only when a pairing
   * is — into the store that pairing chose. Opening this page on a borrowed
   * computer and closing it again leaves nothing.
   */
  private deviceKeys = loadDeviceIdentity(this.stores)
  /** Set while a typed code is being looked up at the relay. */
  private looking = false
  private screen: Screen = 'pair'
  private sessions: RemoteSession[] = []
  private activity = new Map<string, number>()
  /**
   * Every machine this browser is paired with, and which one it is talking to.
   *
   * This used to be a single `StoredCredential`, and the whole of `machines.ts`
   * exists to explain why one was not enough once the phone grew a Machines
   * screen. Everything that reads "the credential" below now reads
   * `this.credential`, which is the current machine's — so the connection, the
   * banner, the session list and the terminal are untouched by the change. What
   * moved is only the answer to *which* machine.
   */
  private book: MachineBook = NO_MACHINES
  /**
   * The names this browser has given ports, and the groups it has folded, per
   * machine. See `port-book.ts`; the grouping that reads it is `port-catalog.ts`.
   *
   * Made in the constructor rather than here because it needs `this.stores`, and a
   * field initialiser cannot see another field that is declared after it.
   */
  private readonly portBook: PortBook
  /**
   * How big the terminal's characters are. See `text-size.ts`, which owns the
   * bounds and says why a browser needs this control when a phone barely does.
   */
  private textSize: number
  private attachedId: string | null = null
  /** True once an `attach` has gone out for `attachedId` on this connection. */
  private attachSent = false
  private terminal: TerminalHandle | null = null
  /**
   * What keeps a session's replay off the screen until it is whole.
   *
   * Made with the terminal and torn down with it. Null between the two, and
   * every write goes through {@link writeTerminal} rather than through the
   * handle, so there is one door and it cannot be bypassed by the next thing
   * that wants to print a line.
   */
  private backfill: Backfill | null = null
  private keybar: KeyBarHandle | null = null
  private terminalScreen: HTMLElement | null = null
  /**
   * The three chips a session has on a Mac — usage, context, account.
   *
   * Held beside the terminal rather than inside it because it outlives no
   * session: built with the pane, fed by the router, dropped by
   * `destroyTerminal`. See `session-bar.ts` for why nothing new is on the wire.
   */
  private sessionBar: SessionBar | null = null
  /**
   * The session's control cluster — model, effort, fast mode, permission.
   *
   * Same lifecycle as the bar above for the same reasons, and the same finding
   * behind it: the frames (`controls.read` / `controls.apply`) have been on the
   * wire since 0.5.0 and this client never sent one. See `session-controls.ts`.
   */
  private sessionControls: SessionControls | null = null
  /**
   * The same session read as a conversation rather than as a screen.
   *
   * Held beside the terminal, not instead of it: switching modes must not tear
   * down a pty's emulator and replay its scrollback, which is what "rebuild the
   * pane" would mean. Both exist; one is in the document.
   */
  private chatView: ChatView | null = null
  /**
   * The box under the conversation.
   *
   * Held beside `chatView` rather than inside it for the reason the key bar is
   * held beside the terminal: it leaves the document every time the mode
   * changes, and a `querySelector` on the way back finds nothing.
   */
  private chatComposer: ChatComposer | null = null
  /** Which of the two is on screen. The terminal is always the one you land on. */
  private chatMode = false
  /** Answers this client is waiting for, by request id. */
  private readonly chatAsked = new Set<string>()
  private chatRid = 0
  private chatTailTimer: number | null = null
  /** Set while a message needs saying on the sessions screen. */
  private notice: string | null = null
  /**
   * The last GitHub login a machine asked this browser for, until it is
   * dismissed.
   *
   * Kept rather than flashed: the person who needs to read it may have been
   * looking at the terminal when the push failed, and a toast that had already
   * gone would leave them with a git error and no explanation anywhere.
   */
  private credentialAsk: CredentialNotice | null = null
  /**
   * What kind of machine this client is paired to.
   *
   * Held here rather than read off the connection, because the screens that most
   * need it are drawn when there is no connection to ask: the pair screen has no
   * socket by definition, and the session list is painted from the stored
   * credential before the first frame arrives. Seeded from that credential on
   * launch, replaced by every `welcome`, and reset only when the machine is
   * deliberately forgotten.
   */
  private hostPlatform: HostPlatform = 'unknown'
  /**
   * What the desktop said it can do beyond protocol v1, from its last welcome.
   *
   * Nothing is offered that is not in here. A `create` sent to a host that
   * never advertised one is refused by its parser and the socket goes with it,
   * so a hopeful button is a broken client rather than an optimistic one.
   */
  private capabilities: string[] = []
  /**
   * The live view. One {@link WatchCanvas} per window being watched, the tab
   * strip the host last reported, and the size-observers that renegotiate width
   * on a rotation. All three leave with the socket — a screencast is
   * per-connection on the host, so a reconnect starts fresh rather than assuming
   * a subscription the host has already dropped. `main.ts` owns the mounting; the
   * canvas owns the paint/ack loop and the coordinate math. See `browser-view.ts`.
   */
  private readonly browserCanvases = new Map<string, WatchCanvas>()
  private readonly browserObservers = new Map<string, ResizeObserver>()
  private browserSurfaces: readonly WatchSurface[] = []
  private browserRid = 0
  /**
   * The build the connected host said it is running, and which shell serves it,
   * from its last `welcome`. Connection-only, like {@link capabilities}: a
   * version is a fact about the machine answering right now, not one to seed from
   * storage and show stale before a socket is up. Empty and null are "not
   * connected, or an older host that never said" — the Settings row draws
   * nothing rather than a guess.
   */
  private hostAppVersion = ''
  private hostKind: HostKind | null = null
  /**
   * The "This server" section of the Settings screen — the two settings this
   * machine owns rather than this browser. Built once and app-global (it is a
   * screen section, not a per-session cluster), it reads the socket and the
   * capability list lazily, so constructing it before the connection exists is
   * fine. It draws nothing over a machine whose welcome did not name `settings`.
   */
  private readonly serverSettings = new ServerSettings({
    send: (message) => this.connection?.send(message) === true,
    capabilities: () => this.capabilities,
  })
  /**
   * The folders this device may start a session in, or null when the desktop
   * has never said.
   *
   * Null is not "none" and the two must not be folded together here either —
   * see `folders.ts`, which owns the whole rule. Replaced by `foldersAfter` on
   * every frame, so the pushed update lands without a reconnect.
   */
  private folders: string[] | null = null
  /** Set between asking for a session and being told about one. */
  private awaitingCreate = false
  /** Set while the folder list under New session is open. */
  private picking = false
  /** What the machine is serving, and the check in flight. See `localhost.ts`. */
  private localhost: LocalhostState = NO_LOCALHOST
  /**
   * What is typed in the browse bar.
   *
   * Held here rather than read off the input at press time, for the reason every
   * other in-progress value in this class is: the desktop pushes `ports` and
   * `dev.state` unprompted, and each one rebuilds this screen. A half-typed
   * address living only in the DOM would be erased by the machine answering a
   * question somebody asked before they started typing.
   */
  private browseText = ''
  /**
   * Which device the bar opens on, once somebody has said.
   *
   * Null means "whatever the first available one is", which is not the same as a
   * stored `machine`: the set of destinations changes underneath this — a socket
   * drops, a machine that opens pages is swapped for one that does not — and a
   * remembered choice that is no longer on offer has to fall back rather than
   * leave the bar pointed at nothing. `browseTarget` is the only reader and it
   * does that falling back in one place.
   */
  private browseWhere: BrowseWhere | null = null
  /** One row per project that can be served, and the start in flight. See `dev-server.ts`. */
  private dev: DevState = NO_DEV
  /**
   * The appearance, as the person answered it and as it is painted.
   *
   * Two fields rather than one, because they are two different facts: `system`
   * is a real answer and is not a palette. See `theme.ts`, which owns the whole
   * question and explains why the resolution happens here rather than in a
   * media query.
   */
  private themeChoice: ThemeChoice = 'system'
  private appearance: Appearance = 'dark'
  /** The `prefers-color-scheme` subscription, so a machine can change its mind. */
  private systemAppearance: SystemAppearance | null = null
  /** The timer behind `CHECK_PATIENCE_MS`, or null when nothing is being checked. */
  private checkTimer: number | null = null
  /**
   * Names the tunnels this client opens, and never repeats one.
   *
   * A counter rather than a random string, because the ids only have to be
   * unique against *this* connection — the desktop tears its hub down when the
   * socket goes — and a counter is the version a test can predict. It never
   * resets, so a reconnect cannot reuse an id the desktop is still holding.
   * `ID_RE` on the far side accepts it: a letter, then letters, digits and
   * hyphens.
   */
  private checks = 0
  /**
   * Whether the person reading this has an Esc key of their own.
   *
   * Watched rather than read once — an iPad leaves its keyboard mid-session. See
   * `physical-keyboard.ts`, which owns the whole question and explains why the
   * signal is the input hardware and not the user agent.
   */
  private keyboard: KeyBarFit | null = null
  /** The strip the key bar sits in, so its visibility can follow the hardware. */
  private keybarDock: HTMLElement | null = null
  /**
   * The row whose actions are showing, by `LocalhostRow.id` or machine id.
   *
   * One at a time and held here rather than on the row, because the list is
   * rebuilt from scratch on every frame the desktop pushes — a flag living in the
   * DOM would be wiped by the next `ports` answer, which on this screen arrives
   * while somebody's finger is still on the button.
   */
  private openRow: string | null = null
  /**
   * The session whose Close is waiting for a second press, by id.
   *
   * The confirmation he asked for — *"close the session (with a confirmation)"*
   * — lives in the list rather than in a dialog, and this is what makes it two
   * steps. Held here for the reason {@link openRow} is: this list is rebuilt from
   * scratch whenever the machine pushes a `sessions` frame, so a flag kept in the
   * DOM would be wiped mid-decision by a status change on some unrelated row.
   *
   * Cleared on the `closed` answer, on a refusal, and on leaving the screen.
   * Never on a timer: a question that withdraws itself is a question somebody
   * answers by accident the next time they look.
   */
  private closing: string | null = null
  /**
   * The device roster, from the last `devices.rows` or `devices.changed`.
   *
   * Only meaningful over a host that advertised `devices`, which it does only to
   * one of the owner's own devices. Rebuilt whole on every answer and push —
   * there is nothing to merge, the far end sends the current list — so nothing
   * here has to remember what it last held.
   */
  private deviceRoster: DeviceRosterRow[] = []
  /** rids of `devices.list`/`devices.revoke` this client is still waiting on. */
  private readonly devicesAsked = new Set<string>()
  private devicesRid = 0
  /**
   * The device whose Remove is waiting for a second press, by id.
   *
   * The same two-step the session Close uses, and for the same reason it is held
   * here rather than in the DOM: a `devices.changed` push rebuilds this list
   * mid-decision. Removing a device — especially this one, which is sign-out — is
   * a thing done once and regretted, so it asks twice.
   */
  private removing: string | null = null
  /** The port being renamed, and the text so far. See `port-book.ts`. */
  private renamingPort: number | null = null
  /** The machine being renamed, by id. */
  private renamingMachine: string | null = null
  /** What a rename field holds. Kept here so a redraw does not empty it. */
  private renameText = ''
  /**
   * A message that has been said and will stop being said.
   *
   * Copying an address is silent by nature; without this the action feels broken
   * even when it worked. The same two and a half seconds the phone waits.
   */
  private toastText: string | null = null
  private toastTimer: number | null = null
  /**
   * Set while the pair screen was reached from the Machines screen rather than by
   * having no machines at all.
   *
   * It is the difference between a first run and adding a second machine, and the
   * only thing it changes is whether there is a way back — a person part-way
   * through pairing a second machine must be able to abandon it without being
   * stranded on a screen that looks like they have been signed out.
   */
  private pairingAnother = false

  /* ---------------------------------------------------------- add a server -- */

  /**
   * What the Add-server form is holding, between renders.
   *
   * Held on the model rather than read off the elements, for the reason
   * `renameText` is: any push from the machine rebuilds this screen's DOM, and a
   * pasted key several kilobytes long is not something to make somebody paste
   * twice because a `sessions` frame arrived while they were typing a username.
   *
   * The secret is in memory for exactly as long as the screen is, and is cleared
   * on the way out — see {@link leaveAddServer}. It is never written to either
   * store: what is worth keeping is the credential the sign-in earns, and an SSH
   * password kept beside it would be a second, far more powerful secret sitting
   * in a browser profile for the sake of saving one typing.
   */
  private addFields: SignInFields = { address: '', username: '', secret: '', method: 'password' }
  /** Which field the form is complaining about, and what it says. */
  private addProblem: FieldFault | null = null
  /** How the machine refused, when it got as far as answering. */
  private addFailure: SignInFailure | null = null
  /** A sign-in is in flight. The submit is disabled and says so. */
  private addingServer = false
  /**
   * Where the back chevron goes from the Add-server screen.
   *
   * The same fact `pairingAnother` carries for the pair screen and for the same
   * reason: a browser with no machines has nowhere to go back to, and a browser
   * that came here from the Machines screen must be able to abandon a
   * half-filled form without looking signed out.
   */
  private addServerFrom: Screen = 'pair'

  /**
   * The one file on its way to the machine, or none.
   *
   * One rather than a list because the desktop serves one upload per connection
   * — `MAX_UPLOADS_PER_CONNECTION` — so a queue here would be a second file
   * whose path appears at the prompt minutes after it was chosen. A second pick
   * while this is set is refused with one line, which is a thing a person can
   * act on; a silent queue is not.
   */
  private upload: Upload | null = null

  /* ------------------------------------------------------------- copilot -- */

  /**
   * The copilot, which arrives with the pairing rather than beside it.
   *
   * `copilot.ts` carries the argument; the short form is that pairing a device
   * as one of his own *is* the authorisation, so there is no code to redeem and
   * nothing held in this browser. A guest's welcome carries no copilot at all,
   * so `offered` is false and the tab is absent rather than drawn and disabled.
   */
  private copilot: CopilotState = NO_COPILOT
  /**
   * What is typed into the message box.
   *
   * Held here rather than left in the DOM for the reason every other in-progress
   * value in this class is: the copilot pushes frames unprompted — a tool row, a
   * chat extension, a state change — and each one rebuilds this screen. A half-
   * typed question living in a textarea would be erased by the copilot doing
   * something, which is the one moment somebody is most likely to be typing.
   */
  private composerText = ''
  /**
   * The panel has been folded away on this visit.
   *
   * Not stored, and undone by opening the Copilot tab. It is a way to get the
   * panel out of the way rather than a preference somebody has to find again —
   * the desktop's own fold dot works the same way and for the same reason.
   */
  private dockFolded = false
  /**
   * Show the scan, or do the work with none of the driving.
   *
   * > *"Interactive mode ON — the visible scan. Interactive mode OFF — it does the
   * > work in the background and returns the final answer normally."*
   *
   * The answer is the same object either way — `scanAnswer` over the same stops —
   * so this decides whether anybody watches it being assembled and nothing else.
   * Held in memory rather than stored: it is a choice about *this* look at the
   * machine, and a tab reloaded is somebody starting again.
   */
  private interactive = true
  /** The plan being played, or an empty list when no scan has run. */
  private scanStops: ScanStop[] = []
  /** The answer, once there is one. Null before the first scan. */
  private answer: AnswerSession[] | null = null
  /** The playhead, made on the first scan and kept for the life of the page. */
  private scan: ScanRunner | null = null
  private scanState: ScanState | null = null
  /** The dots, mounted only while a visible scan is running. */
  private field: ScanFieldHandle | null = null
  /** The watch that hands the screen back the moment somebody touches it. */
  private scanWatch: InterruptionWatch | null = null
  /**
   * Where the copilot lives while it is not on its own screen.
   *
   * A sibling of the content, like the tab strip and the banner, for the same
   * reason: it has to survive the screens it is drawn over. **It is only ever
   * populated when the current screen is not the copilot's own**, which is the
   * layout rule he stated twice:
   *
   * > *"When it is interacting it is making two split views even inside its own
   * > page. It should not make two split views on its own page."*
   */
  private readonly dock = element('aside', 'dock')
  /** The consent sheet, when there is a question this connection may answer. */
  private readonly sheet = element('div', 'sheet')
  /** Redraws the countdown on a waiting confirmation, once a second. */
  private sheetTimer: number | null = null
  /** Unlocks the composer if a sent message is never acknowledged. */
  private sayTimer: number | null = null

  constructor(root: HTMLElement) {
    this.root = root
    document.title = BRAND.name
    this.portBook = new PortBook(this.stores, this.remember)
    this.textSize = readTextSize(this.stores.browser)

    this.back.type = 'button'
    this.back.setAttribute('aria-label', 'Back')
    this.back.addEventListener('click', () => this.goBack())

    // Wired once. `renderAppearance` replaces the icon inside it on every change
    // and never the button itself, so this listener outlives every redraw — the
    // reason the element is a field rather than something a render returns.
    this.appearanceButton.type = 'button'
    this.appearanceButton.addEventListener('click', () => this.cycleTheme())

    /*
     * The picker, wired once and never rebuilt.
     *
     * No `accept`, deliberately. On iOS an unrestricted file input opens the
     * system sheet with *Photo Library*, *Take Photo or Video* and *Choose File*
     * on it — the three routes iOS gives behind two separate menu items — so one
     * control here is the same reach as two there, with nothing written on
     * screen. `multiple` because a person picking four photos meant to send four;
     * they cross one at a time, because the desktop serves one upload per
     * connection.
     *
     * `value` is cleared on every change so that picking the same file twice in a
     * row fires a second `change`. Without it the second pick is silent, which is
     * the exact failure this pass exists to remove.
     */
    this.fileField.type = 'file'
    this.fileField.multiple = true
    this.fileField.hidden = true
    this.fileField.addEventListener('change', () => {
      const picked = Array.from(this.fileField.files ?? [])
      this.fileField.value = ''
      void this.sendFiles(picked)
    })

    this.attachButton.type = 'button'
    this.attachButton.hidden = true
    this.attachButton.setAttribute('aria-label', 'Send a file to this session')
    this.attachButton.title = 'Send a file to this session'
    this.attachButton.append(clipIcon())
    this.attachButton.addEventListener('click', () => this.fileField.click())
    this.modeButton.type = 'button'
    this.modeButton.hidden = true
    this.modeButton.addEventListener('click', () => this.toggleMode())

    const titles = element('div', 'header__titles')
    titles.append(this.title, this.subtitle)
    this.header.append(this.back, titles, this.modeButton, this.attachButton, this.appearanceButton, this.fileField)

    this.bannerAction.type = 'button'
    this.bannerAction.addEventListener('click', () => this.connection?.resume())
    this.banner.append(this.bannerText, this.bannerAction)

    this.toast.hidden = true
    this.toast.setAttribute('aria-live', 'polite')

    this.dock.hidden = true
    this.sheet.hidden = true

    /*
     * The dock sits *inside* a row with the content rather than after it.
     *
     * On a phone there is no room for a column, so `styles.css` lays it out as a
     * strip along the bottom; on a window wide enough it is a real side panel.
     * Either way it is a sibling of `content`, which is what lets the screen
     * underneath keep its own scroll position while the copilot talks over it.
     */
    const body = element('div', 'body')
    body.append(this.content, this.dock)

    root.append(this.header, this.banner, this.credentialCard, this.tabs, body, this.toast, this.sheet)
  }

  /* ------------------------------------------------------------- startup -- */

  start(): void {
    // Before anything is drawn. Everything below paints in whichever appearance
    // this settles on, and a page that renders once in the wrong one and then
    // corrects itself is a flash somebody sees on every visit.
    this.startTheme()

    // The book, or the single pairing every browser that has used this client
    // before is holding. `loadMachines` owns that migration and explains it.
    const found = loadMachines(this.stores, Date.now())
    this.book = found?.book ?? NO_MACHINES
    this.remember = found?.remember ?? 'this-tab'
    // Both follow whichever machine is current. Held as fields rather than read
    // through the book on every access because they are answered before the first
    // socket exists — the pair screen has no connection by definition — and
    // because `welcome` writes `hostPlatform` before the credential is rebuilt.
    this.hostPlatform = this.credential?.hostPlatform ?? 'unknown'
    this.endpoint = this.credential?.endpoint ?? DIRECT
    // The book is written where the pairing chose, so it has to be told which
    // that was before anything can change a name.
    this.portBook.setLifetime(this.remember)
    // Nothing about the copilot is read here any more, and one thing is thrown
    // away: `terminaldeck.copilot.v1` held a credential per machine back when
    // the copilot was a connection of its own, and every browser that ever
    // connected one is still carrying those strings. `remember.ts` says why a
    // secret nothing can use is still worth removing from a computer somebody
    // may not own.
    purgeRetired(this.stores)

    /*
     * Nothing is read out of the URL here any more, and that is a deletion
     * rather than an omission.
     *
     * A pairing token used to arrive in the fragment of a link the desktop drew
     * as a QR code, and `start` took it out of the address bar before deciding
     * anything. There is no link and no QR, so nothing writes that fragment —
     * and a reader for a token nobody mints is a second, unexercised route into
     * the one function that puts a credential on a computer somebody may not
     * own.
     */
    if (this.credential !== null) {
      this.screen = 'sessions'
      this.render()
      this.connect(this.credential.token, this.endpoint)
    } else {
      this.screen = 'pair'
      this.render()
    }

    this.watchKeyboard()
    this.watchViewport()
    this.watchWakeups()
    // Every second, because the banner counts down. Cheap, and it stops the
    // moment there is nothing to count.
    window.setInterval(() => {
      if (this.state.retryAt !== null) this.renderBanner()
    }, 1000)
  }

  /* ------------------------------------------------------------ machines -- */

  /** The machine this browser is talking to, or null when there are none. */
  private get machine(): StoredMachine | null {
    return currentMachine(this.book)
  }

  /**
   * The current machine's credential.
   *
   * A getter rather than the field it used to be, so that every one of the two
   * dozen places below that ask "are we paired" keeps working unchanged while the
   * answer moves from *the* pairing to *this* pairing. Writing one goes through
   * `putCredential`, which knows the difference between renewing the machine on
   * screen and minting one for a machine being added.
   */
  private get credential(): StoredCredential | null {
    return this.machine?.credential ?? null
  }

  /**
   * Which machine the connection is currently pointed at, whether or not this
   * browser has a credential for it yet.
   *
   * The distinction matters exactly once, and it is the case that would otherwise
   * be a real bug: while a *second* machine is being paired, `this.endpoint` is the
   * new machine and `this.machine` is still the old one, so a credential written
   * against "the current machine" would overwrite the pairing somebody is using
   * with a token for a different computer.
   */
  private get dialledId(): string {
    return machineId(this.endpoint)
  }

  /**
   * What the machine being paired called itself, until its row exists.
   *
   * Set by `startPairing` off the rendezvous offer and read once, by
   * `putCredential`. Null for a direct pairing and for every reconnect, where
   * there is no offer and the row already carries whatever it learned the first
   * time — `withMachine` keeps the older name rather than clearing it.
   */
  private dialledName: string | null = null

  /**
   * Put a credential in the book against the machine it is actually for.
   *
   * Adds the machine when it is new — which is what makes "pair another machine" a
   * feature rather than a re-pair — and updates it in place when it is not, which
   * is what makes a renewed credential keep the nickname, the position in the list
   * and, because `port-book.ts` keys on the same id, the names its ports were
   * given.
   */
  private putCredential(credential: StoredCredential): void {
    const id = this.dialledId
    const known = machineById(this.book, id)
    // A machine is never *added* on a credential with no token in it. `welcome`
    // can arrive before `credential` has been redeemed on a route that has not
    // been seen, and a row written from that frame would be a machine in the list
    // that nothing can reconnect to — `loadCredential` refuses an empty token on
    // the way back in, so it would also vanish at the next launch with no
    // explanation. Renewing a machine that already has one is a different thing
    // and is allowed: the token is carried over by the caller.
    if (known === null && credential.token === '') return
    this.book = known === null
      ? withMachine(this.book, { id, nickname: null, hostName: this.dialledName, credential })
      : selectMachine(withCredential(this.book, id, credential), id)
    this.keep()
  }

  /**
   * Talk to another machine.
   *
   * Everything the old machine told this browser goes with it, and that is the
   * whole method. A session list, a folder list, a port list and a capability set
   * are each a statement about *one* desktop, and carrying any of them across
   * would put the previous machine's sessions on screen under the new one's name —
   * which is the same stale truth the offline banner exists to prevent, with a
   * worse failure attached: tapping one of those rows would attach to an id the
   * new machine has never heard of.
   */
  private switchTo(id: string): void {
    const machine = machineById(this.book, id)
    if (machine === null || id === this.book.currentId) return
    this.connection?.stop()
    this.connection = null
    this.book = selectMachine(this.book, id)
    this.keep()

    this.sessions = []
    this.activity.clear()
    this.capabilities = []
    this.hostAppVersion = ''
    this.hostKind = null
    this.folders = null
    this.picking = false
    this.awaitingCreate = false
    this.notice = null
    this.credentialAsk = null
    this.openRow = null
    this.closing = null
    // The roster is one machine's, like everything else here: a different desktop
    // has a different set of devices signed into it, and carrying this one across
    // would list the wrong machine's phones under the new name.
    this.deviceRoster = []
    this.devicesAsked.clear()
    this.removing = null
    this.attachedId = null
    this.destroyTerminal()
    this.forgetLocalhost()
    this.stopAllWatch()
    // The copilot goes with the machine, and it is the sharpest case of the rule
    // this method is: a conversation, a run and a grant are each a statement
    // about *one* desktop, and carrying any of them across would put the previous
    // machine's copilot on screen under the new one's name. Switching back costs
    // nothing — the next welcome from that machine brings its copilot with it,
    // because being paired to it as his own is the whole of the entitlement.
    this.forgetCopilot()

    this.hostPlatform = machine.credential.hostPlatform
    this.state = { phase: 'connecting', detail: `Connecting to ${machineLabel(machine, this.origin)}…`, retryAt: null, attempts: 0 }
    this.screen = 'sessions'
    this.render()
    this.connect(machine.credential.token, machine.credential.endpoint)
  }

  /**
   * Forget one machine, and only that one.
   *
   * The last machine is the interesting case: forgetting it is the old `forget()`
   * in full — every store cleared, the terminal destroyed, back to the pair screen
   * — because a browser with no machines is an unpaired browser. Forgetting one of
   * several is a much smaller event, and the promise the screen makes is that it
   * leaves every other machine alone.
   */
  private forgetMachine(id: string): void {
    if (machineById(this.book, id) === null) return
    const wasCurrent = id === this.book.currentId
    const next = forgetMachine(this.book, id)
    if (next.machines.length === 0) {
      this.forget()
      return
    }
    // Nothing to drop for the copilot. Forgetting a machine used to have to
    // forget a second secret alongside the pairing — the more powerful of the
    // two — and there is now exactly one: the pairing *is* the copilot's
    // authorisation, so the credential that goes with the machine takes the
    // copilot with it.
    this.book = next
    this.keep()
    if (!wasCurrent) {
      this.render()
      return
    }
    // The machine being talked to has just been forgotten, so the socket has to
    // go before anything else — `switchTo` refuses a machine that is already
    // current, and after `forgetMachine` the current id is a different machine.
    this.connection?.stop()
    this.connection = null
    const moved = next.currentId
    this.book = { ...next, currentId: null }
    if (moved !== null) this.switchTo(moved)
  }

  /** The address this page was served from, for the rows that name it. */
  private get origin(): string {
    return window.location.host
  }

  /**
   * Point the connection at a machine, by whichever of the two routes it is.
   *
   * The route decides one thing — what `open` returns — and nothing else.
   * `connection.ts` above it is untouched: the banner, the heartbeat, the
   * backoff, the refusal to buffer a keystroke and the whole pairing-approval
   * dance are the same code whether the bytes went through a relay or straight
   * down a tailnet. That seam is what made giving this client the relay a small
   * change rather than a second client.
   */
  private connect(token: string, endpoint: DeckEndpoint): void {
    this.connection?.stop()
    this.endpoint = endpoint

    let open: ((url: string) => SocketLike) | undefined
    let url = socketUrl(window.location)
    if (endpoint.kind === 'relay') {
      const hostPublicKey = hostKeyBytes(endpoint.hostKey)
      if (hostPublicKey === null) {
        // `asEndpoint` decodes the key before it will call something a relay
        // endpoint, so this is unreachable from storage — and it is checked
        // anyway, because the alternative to a sentence here is a handshake that
        // fails for a reason nobody can see.
        this.state = {
          phase: 'offline',
          detail: `That pairing is missing the ${this.noun}'s key, so nothing can be reached. Pair again.`,
          retryAt: null,
          attempts: 0,
        }
        this.renderBanner()
        return
      }
      const relay = endpoint
      url = relay.url
      open = () =>
        relaySocket({
          relayUrl: relay.url,
          hostId: relay.hostId,
          hostPublicKey,
          deviceKeys: this.deviceKeys,
        })
    }

    this.connection = new Connection({
      url,
      token,
      reach: endpoint.kind,
      open,
      device: describeDevice(navigator.userAgent),
      handlers: {
        onState: (state) => this.onState(state),
        onMessage: (message, activity) => this.onMessage(message, activity),
        onCredential: (credential) => this.onCredential(credential),
        onCredentialAsked: (notice) => this.onCredentialAsked(notice),
      },
    })
    this.connection.start()
  }

  /* --------------------------------------------------------------- theme -- */

  /**
   * Settle the appearance, and keep following the machine if that is the answer.
   *
   * The stored choice comes out of `localStorage` rather than out of whichever
   * store the pairing chose — see `theme.ts`, which explains why a preference and
   * a bearer credential do not belong under the same rule.
   *
   * `matchMedia` is passed rather than reached for, the same way
   * `watchPhysicalKeyboard` takes it: that is what keeps the decision in a file
   * the suite can ask questions of.
   */
  private startTheme(): void {
    this.themeChoice = readChoice(this.stores.browser)
    const media: MatchMedia | undefined =
      typeof window.matchMedia === 'function' ? (query) => window.matchMedia(query) : undefined
    this.systemAppearance = watchSystemAppearance(media, () => {
      // Only while the answer is "follow the machine". A person who chose light
      // has said something this must not overrule, and the listener stays
      // subscribed rather than being torn down and rebuilt as the choice moves.
      if (this.themeChoice === 'system') this.applyAppearance()
    })
    this.applyAppearance()
  }

  /**
   * Paint the resolved appearance everywhere it has to be painted.
   *
   * Three places, and the third is the one that gets forgotten: the document,
   * the browser's own chrome, and **the emulator**. xterm takes a colour object
   * rather than reading the cascade, so a client that stamped the attribute and
   * stopped would leave a dark terminal in a white window — which looks like a
   * bug rather than like a choice, and is the failure this whole feature is
   * judged on.
   */
  private applyAppearance(): void {
    this.appearance = resolveAppearance(this.themeChoice, this.systemAppearance?.dark ?? true)
    stampAppearance(document.documentElement, this.appearance)
    const meta = document.querySelector('meta[name="theme-color"]')
    if (meta !== null) meta.setAttribute('content', THEME_COLOR[this.appearance])
    this.terminal?.setAppearance(this.appearance)
    this.renderAppearance()
  }

  /** The person pressed the icon: on to the next of the three. */
  private cycleTheme(): void {
    this.themeChoice = nextChoice(this.themeChoice)
    writeChoice(this.stores.browser, this.themeChoice)
    this.applyAppearance()
  }

  /**
   * The one icon, redrawn from the one source of truth.
   *
   * No `aria-pressed`. That attribute says a toggle is on or off, and this is
   * one setting with three values — a screen reader told "pressed" here would be
   * announcing a two-state control that does not exist. The whole state is in
   * the name instead, which is what `themeTitle` is for, and the name changes on
   * every press so the change is announced rather than merely painted.
   */
  private renderAppearance(): void {
    const said = themeTitle(this.themeChoice)
    this.appearanceButton.setAttribute('aria-label', said)
    this.appearanceButton.title = said
    this.appearanceButton.replaceChildren(themeIcon(this.themeChoice))
  }

  /**
   * Follow the input hardware, so the key bar is there exactly when it is needed.
   *
   * `matchMedia` is passed rather than reached for, which is what keeps the
   * decision in a file the suite can ask questions of; a browser without it gets
   * `undefined` and keeps the bar. See `physical-keyboard.ts` for why that is the
   * right way to be wrong.
   */
  private watchKeyboard(): void {
    const media: MatchMedia | undefined =
      typeof window.matchMedia === 'function' ? (query) => window.matchMedia(query) : undefined
    this.keyboard = watchPhysicalKeyboard(media, () => this.applyKeyBar())
    this.applyKeyBar()
  }

  /**
   * Show or hide the key row for the hardware that is attached right now.
   *
   * The bar is hidden rather than destroyed. It holds the armed-Ctrl state that
   * `sendInput` folds characters through, and a tablet that leaves its keyboard
   * mid-session must get the row back with the terminal underneath it untouched
   * — rebuilding it would mean rebuilding the emulator, which loses focus and
   * reflows every line of scrollback.
   *
   * The refit is not cosmetic: the terminal is `flex: 1` above the dock, so
   * taking forty-eight pixels away gives it four more rows, and an emulator that
   * has not been told is one whose bottom four lines are painted over.
   */
  private applyKeyBar(): void {
    const dock = this.keybarDock
    if (dock === null) return
    dock.hidden = !(this.keyboard?.wanted ?? true)
    this.terminal?.fit()
  }

  /** Reconnect early when the OS gives us a reason to think it will work. */
  private watchWakeups(): void {
    window.addEventListener('online', () => this.connection?.resume())
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') this.connection?.resume()
    })
  }

  /* -------------------------------------------------------------- events -- */

  private onState(state: ConnectionState): void {
    const wasOnline = this.state.phase === 'online'
    this.state = state

    // Nothing in flight survives the socket that carried it. A `create` whose
    // answer was on its way when the connection dropped may or may not have
    // started something on the desktop — the next `list` says which — and the
    // one thing this client must not do meanwhile is keep a button spinning
    // against a socket that will never answer it.
    if (state.phase !== 'online') this.awaitingCreate = false
    // Same argument, for the same reason: a port check left spinning against a
    // socket that will never answer it is the lie this client exists not to
    // tell. The port list survives and is labelled as old rather than blanked.
    if (state.phase !== 'online') this.localhostDo({ t: 'offline' })
    // And a dev server left reading "Starting…" against a dead socket. The
    // server itself may well still be starting on the desktop — which is what
    // the re-ask on reconnect below is for.
    if (state.phase !== 'online') this.devDo({ t: 'offline' })
    // And a file half-way across. The desktop deletes its own `.part` when the
    // socket goes, so the only thing left is to stop this end pretending: a
    // progress line frozen at 38% over a dead connection is the silent failure
    // this pass exists to remove.
    if (state.phase !== 'online' && this.upload !== null) {
      this.upload.connectionLost('The connection dropped before that file landed.')
    }
    // The copilot connection goes with the socket that carried it, and that is
    // not a client decision — a `copilot.*` verb is refused until this socket has
    // said hello again, so a screen still drawing a composer would be a control
    // that cannot act. Nothing else is lost: whether this device reaches the
    // copilot is a fact about how it was paired, so the next welcome opens it
    // again without asking anybody for anything.
    if (state.phase !== 'online') {
      this.copilotDo({ t: 'offline' })
      // A scan is a thing being watched, and what it is watching has gone. Held
      // rather than abandoned, so the trace and the answer stay readable.
      if (this.scan !== null && isScanning(this.scan.state())) this.scan.pause('stalled')
    }

    if (state.phase === 'online' && !wasOnline) {
      // Re-attach rather than assume. The desktop kept running while we were
      // gone, so what is on screen is from before the gap; leaving it there
      // under a fresh connection is the lie this whole client is built to avoid.
      if (this.attachedId !== null) {
        this.terminal?.reset()
        // The re-attach replays the whole session again, so the screen is held
        // again — otherwise a reconnect on a phone coming out of a pocket
        // scrolls the afternoon past a second time. A fresh hold rather than the
        // old one: its ceiling is not a budget for a second replay.
        if (this.terminal !== null) {
          this.backfill?.stop()
          this.backfill = holdUntilFilled(this.terminal, this.terminal.element, { quiet: QUIET_MS })
        }
        this.attach(this.attachedId)
      }
      this.connection?.send({ t: 'list' })
      // The ports the desktop was serving before the gap say nothing about the
      // ports it is serving now — a reconnect is the one moment this list is
      // certainly stale, and the screen showing it is the one place that matters.
      if (this.screen === 'localhost') this.localhostDo({ t: 'list' })
      // Same for the projects, and it is also what re-subscribes: the desktop
      // pushes a folder's changes only to connections that have asked about it
      // *on this connection*, so a reconnected client that did not re-ask would
      // draw rows that never change again.
      if (this.screen === 'localhost') this.askDevServers()
    }

    if (state.phase === 'rejected') {
      // The credential is no good. Holding on to it would mean every launch
      // fails the same way with no route back to pairing — and on a computer
      // that is not this person's, it would be a dead secret left in a profile
      // somebody else will open.
      //
      // **Only the machine that refused it.** This used to clear both stores
      // outright, which was right when there was one pairing and is wrong now: a
      // Mac that has revoked this browser says nothing whatsoever about the PC in
      // the next room, and signing somebody out of every machine because one of
      // them was re-imaged would be the client throwing away work it was told
      // nothing about. `forgetMachine` falls through to the full `forget()` when
      // that machine was the only one, which is the old behaviour exactly.
      const refused = this.dialledId
      this.attachedId = null
      // Everything the refused machine told us about itself goes with it. A
      // folder list is a statement about a device this desktop no longer
      // recognises, and drawing a picker from it on the way back to the pair
      // screen would be offering somewhere to start that nothing will start in.
      this.capabilities = []
      this.hostAppVersion = ''
      this.hostKind = null
      this.folders = null
      this.picking = false
      // And what it was serving. A port list is a statement about a machine
      // that no longer recognises this browser, and it must not still be on
      // screen behind the pair form.
      this.forgetLocalhost()
      // And any live view of its browser: the casts are already dead with the
      // socket, and the canvases hold this machine's pages, which a device it no
      // longer trusts should not still be showing.
      this.stopAllWatch()
      // Not merely hidden: the terminal holds this machine's scrollback, and a
      // device that has just been told it is no longer trusted should not still
      // be carrying it around in memory.
      this.destroyTerminal()
      this.sessions = []
      this.activity.clear()
      // Said only when there is somewhere to say it. With one machine this ends
      // on the pair screen, where the banner is already carrying the desktop's
      // own account of the refusal, and a second sentence parked on a session
      // list nobody will see again would be waiting for the next person to pair.
      if (this.book.machines.length > 1) {
        this.notice = `That ${this.noun} no longer recognises this browser, so it has been forgotten.`
      }
      // Which either moves to whatever is left, or — when that machine was the
      // only one — clears every store and lands on the pair screen, exactly as
      // this branch always did.
      this.forgetMachine(refused)
      return
    }

    this.terminal?.setLive(state.phase === 'online')
    this.renderBanner()
    // Every list screen redraws: what they offer — New session, Refresh, Check,
    // the machine rows' own status line — is drawn from the connection.
    if (LISTING_SCREENS.includes(this.screen)) this.renderContent()
  }

  /* ----------------------------------------------------------- localhost -- */

  /**
   * One transition of the localhost machine, and the frames it asked for.
   *
   * The state lives in `localhost.ts` precisely so this method is the only part
   * of it that cannot be tested: everything here is delivery. A frame that does
   * not reach the desktop puts the machine straight back to its offline state
   * rather than leaving a check spinning — `Connection.send` refuses only when
   * the socket is not up, and when it is not up the banner is already saying so
   * in the desktop's own words, which is a better sentence than one composed
   * here would be.
   */
  private localhostDo(action: LocalhostAction): void {
    const step = localhostStep(this.localhost, action)
    if (step.state === this.localhost && step.send.length === 0) return
    this.localhost = step.state

    for (const message of step.send) {
      if (this.connection?.send(message) === true) continue
      this.localhost = localhostStep(this.localhost, { t: 'offline' }).state
      break
    }

    this.armCheckTimer()
    if (this.screen === 'localhost') this.renderContent()
  }

  /**
   * Give up on a check that nothing has answered.
   *
   * Re-armed from scratch on every transition rather than cleared in the two
   * places a check can end, because "the timer matches whatever is in flight" is
   * one rule and "clear it here, and here, and here" is three that drift. A
   * fired timer that names a check which has already finished is ignored by the
   * machine itself, so the worst a stale one costs is a no-op.
   */
  private armCheckTimer(): void {
    if (this.checkTimer !== null) {
      window.clearTimeout(this.checkTimer)
      this.checkTimer = null
    }
    const checking = this.localhost.checking
    if (checking === null) return
    const id = checking.id
    this.checkTimer = window.setTimeout(() => {
      this.checkTimer = null
      this.localhostDo({ t: 'silence', id })
    }, CHECK_PATIENCE_MS)
  }

  /* --------------------------------------------------------- dev servers -- */

  /**
   * One transition of the dev-server machine, and the frames it asked for.
   *
   * `localhostDo`'s twin, and deliberately its twin: the rules live in
   * `dev-server.ts` where the suite can reach them, and everything here is
   * delivery. A frame that does not reach the desktop puts the machine straight
   * back to its offline state rather than leaving a button spinning — the banner
   * is already saying why, in the desktop's own words.
   */
  private devDo(action: DevAction): void {
    const step = devStep(this.dev, action)
    if (step.state === this.dev && step.send.length === 0) return
    this.dev = step.state

    for (const message of step.send) {
      if (this.connection?.send(message) === true) continue
      this.dev = devStep(this.dev, { t: 'offline' }).state
      break
    }

    if (this.screen === 'localhost') this.renderContent()
  }

  /**
   * Ask the desktop about every folder it is offering this device.
   *
   * Sent on arrival at the screen, on reconnect while looking at it, and when
   * the folder list itself changes — never on a timer. After one of these the
   * desktop pushes that folder's changes on its own, so a client with a poll
   * loop would be asking a question that is already being answered.
   */
  private askDevServers(): void {
    if (!devserverOffered(this.capabilities) || this.state.phase !== 'online') return
    this.devDo({ t: 'ask', folders: this.folders ?? [] })
  }

  /**
   * Everything this client knew about what the machine was serving — the ports
   * and the projects both.
   *
   * One method for the two features because they are one screen and one fact:
   * a port list and a dev-server row are each a statement about a machine this
   * browser is no longer talking to, and leaving either on screen behind the
   * pair form is the stale truth this client exists not to tell.
   */
  private forgetLocalhost(): void {
    if (this.checkTimer !== null) {
      window.clearTimeout(this.checkTimer)
      this.checkTimer = null
    }
    this.localhost = NO_LOCALHOST
    this.dev = NO_DEV
    if (this.screen === 'localhost') this.screen = 'sessions'
  }

  /* ------------------------------------------------------------- copilot -- */

  /**
   * Everything on screen about a copilot, taken away.
   *
   * Called when the machine changes and when the pairing goes, and it takes
   * everything, because there is nothing left that is worth keeping: the
   * conversation, the run, the grant, the scan and everything drawn from them
   * are each a statement about a machine this browser is no longer talking to,
   * and the entitlement they hung off was never held here — it is the pairing.
   */
  private forgetCopilot(): void {
    this.copilot = NO_COPILOT
    this.composerText = ''
    this.dockFolded = false
    this.scan?.destroy()
    this.scan = null
    this.scanState = null
    this.scanStops = []
    this.answer = null
    this.endScanVisuals()
    this.armSheetTimer()
    if (this.screen === 'copilot') this.screen = 'sessions'
  }

  /**
   * One copilot transition: run it, put its frames on the wire, keep what it
   * hands back, and redraw.
   *
   * The same shape as `localhostDo` and `devDo` next door, for the same reason:
   * every rule about what may be sent lives in a module a test can reach, and
   * this is the three lines that connect it to a socket. It used to have a
   * fourth job — persisting the credential a `copilot.linked` handed over — and
   * that job went with the separate connection: there is no secret here to put
   * anywhere.
   */
  private copilotDo(action: CopilotAction): void {
    const before = this.copilot
    const step = copilotStep(this.copilot, action)
    this.copilot = step.state
    for (const message of step.send) this.connection?.send(message)
    if (before === this.copilot && step.send.length === 0) return
    // A question this connection may answer arrives as a sheet over everything,
    // so the countdown has to start with it and stop with it — a timer left
    // running is a redraw a second forever on a page nobody is looking at.
    this.armSheetTimer()
    this.armSayTimer()
    this.render()
  }

  /**
   * A confirmation expires into a **refusal**, so the countdown is not decoration.
   *
   * > *"What happens if you say nothing — `expiresAt`. It expires into a refusal,
   * > so a person who walks away has decided rather than deferred, and the
   * > countdown has to be in front of them."*
   *
   * One second is the granularity the number is written at, so anything finer
   * would be redraws nobody can see. The timer exists only while a sheet is up.
   */
  private armSheetTimer(): void {
    const wanted = this.copilot.ask !== null
    if (wanted === (this.sheetTimer !== null)) return
    if (!wanted) {
      if (this.sheetTimer !== null) window.clearInterval(this.sheetTimer)
      this.sheetTimer = null
      return
    }
    this.sheetTimer = window.setInterval(() => this.renderSheet(), 1000)
  }

  /**
   * The floor under a message that is never acknowledged.
   *
   * Armed exactly while `sending` is true, the same shape as the sheet's
   * countdown above and for a stricter reason: `sending` disables the Send
   * button, so a lock that never lifts is a screen with no way forward on it.
   * That is not hypothetical — see {@link SAY_TIMEOUT_MS}, which was written
   * after a phone sat on "Sending…" through four messages and a reload.
   *
   * A timeout rather than an interval: it fires once and the action it dispatches
   * clears `sending`, which brings this back through the false branch.
   */
  private armSayTimer(): void {
    const wanted = this.copilot.sending
    if (wanted === (this.sayTimer !== null)) return
    if (!wanted) {
      if (this.sayTimer !== null) window.clearTimeout(this.sayTimer)
      this.sayTimer = null
      return
    }
    this.sayTimer = window.setTimeout(() => {
      this.sayTimer = null
      this.copilotDo({ t: 'say-timeout' })
    }, SAY_TIMEOUT_MS)
  }

  private onCredential(token: string): void {
    const now = Date.now()
    // The machine this token is *for*, which during a second pairing is not the
    // machine on screen. See `dialledId`.
    const dialled = machineById(this.book, this.dialledId)
    this.putCredential({
      token,
      deviceId: dialled?.credential.deviceId ?? '',
      deviceName: dialled?.credential.deviceName ?? 'This device',
      pairedAt: now,
      hostPlatform: this.hostPlatform,
      // Written with the credential, not after it. The credential is what the
      // next launch reconnects with and the endpoint is where it reconnects to;
      // saving one without the other leaves a browser holding a secret for a
      // machine it can no longer find.
      endpoint: this.endpoint,
      expiresAt: now + REMEMBERED_TTL_MS,
    })
    // Whatever brought this browser to the pair screen is over. Leaving the flag
    // set would leave a back chevron on the session list pointing at a machine
    // list the person has just finished with.
    this.pairingAnother = false
  }

  /**
   * Put the credential where the person said, or nowhere at all.
   *
   * One method rather than a `savePairing` call at each of the two places a
   * credential is minted or refreshed, because the argument that is easy to get
   * wrong is `this.remember` — and a single miss writes a durable secret onto a
   * machine whose owner answered "just for this visit". The device key rides
   * along inside `savePairing` for the same reason.
   */
  private keep(): void {
    saveBook(this.stores, this.remember, this.book)
    const credential = this.credential
    if (credential === null || credential.token === '') return
    // The single-credential record `pair.ts` owns is still written, and it is
    // deliberately a *mirror of the current machine* rather than a second pairing:
    // a shell cached by the service worker before the Machines screen shipped
    // reads that key and nothing else, and `sw.js` does not `skipWaiting`, so one
    // more launch of the old shell is guaranteed. It is also what carries this
    // browser's X25519 key into the same store as the book — see `savePairing`,
    // which is the one function allowed to move the two together.
    savePairing(this.stores, this.remember, credential, this.deviceKeys)
  }

  /**
   * A machine asked this browser for a GitHub login.
   *
   * It has already been acknowledged and refused by the time this runs — see
   * `credential.ts` for why this client cannot hold a token and why refusing is
   * the honest implementation rather than an unfinished one. What is left to do
   * is tell the person, because a refusal nobody sees is indistinguishable from
   * a feature that is broken.
   *
   * The newest question replaces the one on screen rather than stacking. A fetch
   * loop would otherwise fill the page with identical cards, and the second card
   * says nothing the first one did not: the answer is the same every time and
   * the remedy is the same every time.
   */
  private onCredentialAsked(notice: CredentialNotice): void {
    this.credentialAsk = notice
    this.renderCredentialAsk()
  }

  /** What to call the machine on the other end, in a sentence. */
  private get noun(): string {
    return machineNoun(this.hostPlatform)
  }

  private onMessage(message: ServerMessage, activity?: ReadonlyMap<string, number>): void {
    // Before the switch, and deliberately not inside two of its cases. The
    // folder list arrives in `welcome` *and* in a pushed frame, and the failure
    // to design against is a client that reads one of them: the pushed one is
    // what makes a folder removed at the desk disappear from the picker in
    // somebody's hand, rather than at the next launch.
    this.folders = foldersAfter(this.folders, message)
    // And before it, for the same reason: `ports`, `tunnel.opened` and
    // `tunnel.closed` are answers to questions the localhost screen asked, and
    // the switch below has no case for them by design — routing them through a
    // second `case` here would put half of that feature's rules in a file no
    // test can reach. Every other frame leaves the machine untouched and returns
    // the identical object, so this costs one comparison per line of output.
    this.localhostDo({ t: 'frame', message })
    // And `dev.state`, which arrives **unsolicited**: after one `dev.status` for
    // a folder the desktop pushes that folder's every later change, which is why
    // this is here rather than in a `case` that only runs for an answer this
    // client is waiting on. It reads `error` too — a refused start comes back
    // with no folder in it, and the only honest thing to do with one is stop the
    // button spinning.
    this.devDo({ t: 'frame', message })
    // And the notice, for the third time the same reason: what a frame does to
    // the sentence above the session list is a rule, and a rule written inside
    // the switch below is one nothing in this repository can check. It is here
    // rather than in the two `case`s that used to set it because the frame that
    // matters most is `welcome` — the frame that *ends* a notice — and a client
    // that only ever wrote notices was a client that left the pairing
    // instructions sitting over a live session list. See `noticeAfter`.
    this.notice = noticeAfter(this.notice, message, this.noun)
    // And the copilot, for the fourth time the same reason: what a frame does to
    // the copilot is a rule, and a rule written inside the switch below is one
    // nothing in this repository can check. Eight frame types land here and the
    // switch has a case for none of them by design. `welcome` is the exception
    // and is handled separately below, because it is not a copilot *frame*: what
    // it carries has to be turned into a different action, and `copilotStep`
    // would drop it on the floor if it arrived here as one.
    if (message.t !== 'welcome') this.copilotDo({ t: 'frame', message })
    /*
     * And the transfer, which owns four frame types the switch below has a case
     * for none of.
     *
     * Routed by asking the transfer whether the frame was its own rather than by
     * matching `t` here: nothing above this knows which upload ids are whose,
     * and a second copy of that in the router is the copy that goes out of step.
     */
    if (this.upload?.receive(message)) return
    /*
     * And the session bar, which owns four frame types the switch below has a
     * case for none of. Routed by asking it whether the frame was its own, for
     * the reason the transfer above is: `rid` is what tells two panels' answers
     * apart, and a second copy of that mapping in the router is the copy that
     * goes out of step.
     */
    if (this.sessionBar?.receive(message)) return
    /*
     * And the control cluster, which owns two frame types the switch below has
     * a case for none of, routed the same way and for the same reason.
     */
    if (this.sessionControls?.receive(message)) return
    // The two server-owned settings, and the unsolicited push when one changes.
    if (this.serverSettings.receive(message)) return
    /*
     * And the live view, which owns two frame types the switch below has a case
     * for none of. A `browser.frame` is drawn by the canvas for its window and
     * acked from the paint callback — routed by window, never broadcast, so one
     * device's frames cannot reach another. A `browser.surfaces.rows` is the tab
     * strip, kept and redrawn only while it is the screen being looked at; it
     * arrives both as an answer and as an unsolicited push, which is why it is
     * here rather than in a `case` waiting on a request.
     */
    if (message.t === 'browser.frame') {
      void this.browserCanvases.get(message.window)?.onFrame(message)
      return
    }
    if (message.t === 'browser.surfaces.rows') {
      this.browserSurfaces = message.surfaces
      if (this.screen === 'browser') this.renderContent()
      return
    }
    /*
     * And the conversation, routed by `rid` for the reason the transfer and the
     * bar above are: an answer belongs to the request that asked for it, and a
     * router that matched on `t` alone would hand a reply to whichever surface
     * happened to be listening.
     */
    if (message.t === 'chat.rows' && this.chatAsked.delete(message.rid)) {
      if (message.id === this.attachedId) {
        this.chatView?.apply(message.rows, message.reset, message.found)
        // The toggle is taken away when the far machine has looked and found no
        // transcript, so the answer has to be able to change the header.
        this.renderHeader()
      }
      return
    }

    switch (message.t) {
      case 'welcome':
        // Before the credential is rebuilt, because the credential now carries
        // it: this is the one frame that says what the machine is, and every
        // launch after this one reads the answer back out of storage rather
        // than waiting for a socket.
        this.hostPlatform = readHostPlatform(message.hostPlatform)
        this.capabilities = message.capabilities
        // The build the machine at the other end is running, and whether it is a
        // desktop or a headless server. Already stripped and bounded by the wire
        // parser; absent means an older host, which the Settings row reads as
        // "not said" and draws nothing for rather than guessing a number.
        this.hostAppVersion = message.appVersion ?? ''
        this.hostKind = message.hostKind ?? null
        // The machine on the other end can change on a welcome — a re-pair, a
        // switch between two paired hosts — so forget what the last one said and
        // re-read on the next visit to Settings, or now if that is where we are.
        this.serverSettings.renew()
        if (this.screen === 'settings') this.serverSettings.ensureRead()
        {
          // The machine that just said hello, which during a second pairing is
          // not the one on screen. See `dialledId`.
          const dialled = machineById(this.book, this.dialledId)
          this.putCredential(
            renewed(
              {
                token: dialled?.credential.token ?? '',
                deviceId: message.deviceId,
                deviceName: message.deviceName,
                pairedAt: dialled?.credential.pairedAt ?? Date.now(),
                hostPlatform: this.hostPlatform,
                endpoint: this.endpoint,
                expiresAt: dialled?.credential.expiresAt ?? 0,
              },
              // A welcome is the only frame that proves this browser actually
              // reached the machine, which is what the sliding window measures. A
              // socket that merely opened proves nothing — the relay will open one
              // against a host id whose owner revoked this device an hour ago.
              Date.now(),
            ),
          )
          // After the machine is certain to be in the book, and on every
          // connection rather than only at pairing. A machine paired before
          // `hostName` was kept has none, and the offer that would have supplied
          // one is read once, at the desk. See `withHostName`.
          this.book = withHostName(this.book, this.dialledId, message.hostName ?? null)
          this.keep()
        }
        this.applySessions(message.sessions, activity)
        if (this.screen === 'pair') this.screen = 'sessions'
        /*
         * The copilot connection is opened here, on every welcome, and that is
         * the rule rather than an optimisation.
         *
         * `welcome.copilot.open` is *always* false — a session channel does not
         * carry the copilot by existing — so a `copilot.hello` has to go out on
         * every connect and every reconnect. It carries nothing: the socket has
         * already proved which device it is, and the machine reads that device's
         * kind. A client that skipped the frame would draw a Copilot tab whose
         * every frame came back refused.
         *
         * `message.copilot` is the whole of whether there is a copilot here at
         * all — present for one of his own devices, absent for a guest — so it is
         * passed on its own and `capabilities` is not consulted. Two signals for
         * one question is two answers that can differ.
         */
        this.copilotDo({ t: 'welcome', link: message.copilot ?? null })
        // A desktop that offers neither tunnelling nor dev servers — a different
        // machine on the same pairing, or one launched with a narrower `offer` —
        // must not leave this browser sitting on a screen whose every control it
        // would now refuse.
        if (this.screen === 'localhost' && !this.servesLocalhost) this.forgetLocalhost()
        // The same rule for the copilot, and it bites in one more case: a device
        // re-paired as a guest, whose welcome now carries no copilot at all. The
        // tab goes, so the screen it was showing has to go with it.
        if (this.screen === 'copilot' && !this.copilot.offered) this.screen = 'sessions'
        // And the device screen, on the same argument: a device re-paired as a
        // guest is no longer told `devices`, so the screen it may have been on
        // has to close rather than sit there refusing every Remove.
        if (this.screen === 'devices' && !devicesOffered(this.capabilities)) this.screen = 'settings'
        // Kept live: asked again on every welcome while it is on screen, so a
        // reconnect re-subscribes to the push and refreshes the list.
        if (this.screen === 'devices' && devicesOffered(this.capabilities)) this.askDevices()
        // Asked on arrival rather than on the first tap, but only for somebody
        // already looking at it — which is the reconnect case, since the tab is
        // what asks otherwise.
        if (this.screen === 'localhost' && localhostOffered(this.capabilities)) this.localhostDo({ t: 'list' })
        if (this.screen === 'localhost') this.askDevServers()
        // The watch screen, on the same argument as the copilot and device tabs:
        // a device re-paired as a guest is no longer told `watch`, so the screen
        // it may have been on has to close rather than sit there refusing every
        // tap. Its canvases go too — a screencast is per-connection, and this is
        // a new one that may watch nothing.
        if (this.screen === 'browser' && !watchOffered(this.capabilities)) {
          this.stopAllWatch()
          this.screen = 'sessions'
        } else if (this.screen === 'browser') {
          // Still allowed, and this is a fresh connection: the host dropped the
          // old screencast with the old socket, so re-ask the strip and re-watch
          // whatever was on screen so a reconnect refills rather than freezes.
          this.requestSurfaces()
          for (const view of this.browserCanvases.values()) view.watch()
        }
        this.render()
        return

      case 'sessions':
        this.applySessions(message.sessions, activity)
        if (this.screen === 'sessions') this.renderContent()
        return

      case 'folders':
        // The list itself has already been taken, above. What is left is the
        // redraw: the picker on screen is now describing a rule the desktop has
        // stopped enforcing, and every second it stays up is a tap that would
        // be refused. It stays *open* through an ordinary edit, which is the
        // point of the frame — the rows change under the finger.
        //
        // A list that has just been emptied is the exception: there is no
        // picker left to keep open, and leaving the flag set would spring one
        // open by itself the moment a folder was granted again.
        if (message.folders.length === 0) this.picking = false
        if (this.screen === 'sessions') this.renderContent()
        // The dev-server rows are one per *folder*, so this frame is the one
        // that decides which of them may still exist. Re-asking prunes the rows
        // for folders that have gone and picks up any that have arrived — and it
        // is the only way to be subscribed to a new one, since the desktop
        // pushes only about folders this connection has named.
        if (this.screen === 'localhost') this.askDevServers()
        return

      case 'created': {
        this.awaitingCreate = false
        // Put in the list here rather than waiting for a `sessions` frame: the
        // desktop answers the phone that asked with the whole row and tells
        // everybody else with a plain list, so this is the only frame that says
        // *which* of the sessions is the new one. With two sessions in one
        // folder there is no way to guess right.
        if (!this.sessions.some((entry) => entry.id === message.session.id)) {
          this.sessions = [...this.sessions, message.session]
        }
        // A session that has just been started is a session that just did
        // something, and this client watched it happen — the same reason an
        // `output` or a `status` frame stamps the clock rather than leaving the
        // row with no time on it.
        this.activity.set(message.session.id, Date.now())
        // The tap that started it is the tap that opens it.
        this.openSession(message.session.id)
        return
      }

      case 'closed': {
        /*
         * The machine has ended the session this browser asked it to end.
         *
         * The row is removed *here*, on the answer, and never on the tap. Every
         * other list change in this client works the same way and the reason is
         * sharper for this one than for any of them: an optimistic removal over
         * a refusal — a folder taken back a second ago, a session that had
         * already exited — would leave a person looking at a list with a live
         * session missing from it and no way to get it back except a reconnect.
         *
         * The two-step confirm is torn down with it rather than left holding an
         * id that no longer names anything, and the terminal goes if this is the
         * session it was showing: a screen full of a dead session's last paint,
         * with a keyboard under it, is the shape of every "it works sometimes"
         * complaint this review is about.
         */
        this.closing = null
        this.openRow = null
        this.sessions = this.sessions.filter((entry) => entry.id !== message.id)
        this.activity.delete(message.id)
        if (this.attachedId === message.id) this.leaveTerminal()
        else if (this.screen === 'sessions') this.renderContent()
        return
      }

      case 'output':
        if (message.id !== this.attachedId) return
        /*
         * A frame that is **not** a replay ends the hold before it is written.
         *
         * It is the session printing now, so everything held is older than it
         * and has to go on the screen first — and there is no end-of-replay
         * marker on the wire, so this frame and the quiet timer are the only two
         * things that can say the backlog is complete.
         */
        if (message.replay !== true) this.backfill?.release()
        this.writeTerminal(message.data)
        // Replay is scrollback from before this client arrived, so it says
        // nothing about when the session last did something.
        if (message.replay !== true) this.activity.set(message.id, Date.now())
        // The context window moves when the agent writes, so the bar is asked
        // when the writing stops rather than on a clock. See `noteOutput`.
        if (message.replay !== true) this.sessionBar?.noteOutput()
        // And the controls, on the same event: the model line, the effort
        // confirmation and the permission footer only move when the pty writes.
        if (message.replay !== true) this.sessionControls?.noteOutput()
        // And the conversation, on the same event and only while it is the pane
        // on screen. A transcript grows when the agent writes, which is exactly
        // what this frame is.
        if (message.replay !== true && this.chatMode) this.armChatTail()
        return

      case 'status': {
        const session = this.sessions.find((entry) => entry.id === message.id)
        if (session) session.status = message.status
        this.activity.set(message.id, Date.now())
        if (this.screen === 'sessions') this.renderContent()
        return
      }

      case 'exit': {
        const session = this.sessions.find((entry) => entry.id === message.id)
        if (session) session.exitCode = message.exitCode
        if (message.id === this.attachedId) {
          // Bracketed and dim, so it cannot be mistaken for program output.
          this.writeTerminal(`\r\n\x1b[2m[session exited with code ${message.exitCode}]\x1b[0m\r\n`)
        }
        if (this.screen === 'sessions') this.renderContent()
        return
      }

      case 'devices.rows':
        // Routed by `rid`, like the chat above: an answer belongs to the ask
        // that made it, and one with no waiting request — a duplicate, or one
        // that landed after its screen was left — falls on the floor here.
        if (!this.devicesAsked.delete(message.rid)) return
        this.deviceRoster = message.devices
        if (this.screen === 'devices') this.renderContent()
        return

      case 'devices.revoked':
        if (!this.devicesAsked.delete(message.rid)) return
        this.deviceRoster = message.devices
        // The confirm is spent whatever the outcome: the list came back fresh,
        // and a Remove left mid-press over a rebuilt row is a control frozen on
        // a question nobody is still asking.
        this.removing = null
        // A refused revoke — the device was already gone, or named nothing — is
        // the host's own sentence, said where the person is looking.
        if (!message.ok) this.say(plain(message.message))
        if (this.screen === 'devices') this.renderContent()
        return

      case 'devices.changed':
        // Unsolicited, and the whole reason this client names `devices` in its
        // hello: another device paired or was revoked elsewhere, and the roster
        // on screen updates without a reload. Whole list every time, nothing to
        // merge.
        this.deviceRoster = message.devices
        if (this.screen === 'devices') this.renderContent()
        return

      case 'error':
        // A refused request is not going to be followed by a `created`, and a
        // button left reading "Starting…" over a session that will never exist
        // is the same lie as a live-looking cursor over a dead socket.
        this.awaitingCreate = false
        // And a Close that was refused is a Close that is over. The button is
        // sitting there reading "Closing…" and disabled; leaving it would be a
        // control frozen mid-press with the explanation printed above the list
        // it is in. The question goes and the sentence stays.
        this.closing = null
        // The sentence itself was set by `noticeAfter` above; what is left here
        // is where it has to be *said*.
        if (message.code === 'unknown-session') {
          this.leaveTerminal()
          return
        }
        // Said where the user is looking. An in-session refusal — the desktop
        // answers a keystroke for a session this client is no longer attached
        // to with one — arrives while the terminal is on screen, and a notice
        // parked on the sessions list behind it is a keystroke that vanished
        // with no explanation.
        if (this.screen === 'terminal') this.writeTerminal(`\r\n\x1b[2m[${plain(message.message)}]\x1b[0m\r\n`)
        else if (this.screen === 'sessions') this.renderContent()
        return

      default:
        return
    }
  }

  private applySessions(sessions: RemoteSession[], activity?: ReadonlyMap<string, number>): void {
    this.sessions = sessions
    if (activity) for (const [id, at] of activity) this.activity.set(id, at)
  }

  /* -------------------------------------------------------------- render -- */

  private render(): void {
    /*
     * There used to be an `is-terminal` class stamped here, and a width rule in
     * the stylesheet that deleted the appearance control on a phone inside a
     * terminal — because three pills and a session's title would not both fit in
     * 390 points, and on that screen the title is what somebody needs.
     *
     * The appearance control is one 28px icon now, so both fit, and a class that
     * styles nothing is a hook somebody will one day wire a second meaning to.
     * It is gone with the rule it existed for.
     */
    this.renderHeader()
    this.renderBanner()
    this.renderCredentialAsk()
    this.renderTabs()
    this.renderContent()
    this.renderDock()
    this.renderSheet()
    /*
     * Last, and it has to be last.
     *
     * A full render replaces the session list and the copilot's own fleet list
     * with fresh elements, so every mark a running scan had put on a row is gone
     * with the row it was on. Without this, switching screens mid-scan left the
     * playhead pointing at a session nothing on screen was marked as — the hole
     * in the dot field was cut in the right place and the row under it had no
     * ring, which reads as the effect being decorative.
     *
     * It is class toggles only, so it never tears anything down: see `paintScan`
     * for why that distinction is the whole reason this is a second method
     * rather than part of the render.
     */
    this.paintScan()
  }

  /**
   * The strip that switches between the list screens.
   *
   * Sessions, Localhost and Settings — the phone's three, in the phone's order.
   * Before Settings existed the strip was drawn only against a desktop that
   * advertised `localhost`, because two tabs is a choice and one is not; it is now
   * always at least two, so what varies is whether Localhost is among them. The
   * rule is unchanged and so is what a browser paired to an older machine sees:
   * nothing is offered that the desktop did not say it can do.
   *
   * Absent — not disabled — on the pair screen and inside a terminal. Present on
   * Machines, which is pushed from Settings and keeps Settings marked as the
   * current tab: a person one screen deep has not left it.
   */
  private renderTabs(): void {
    const show = LISTING_SCREENS.includes(this.screen) && this.credential !== null
    this.tabs.hidden = !show
    if (!show) {
      this.tabs.replaceChildren()
      return
    }

    const options: Array<{ screen: Screen; label: string }> = [
      // Absent — not disabled — for a device whose welcome carried no copilot,
      // which is every guest and every machine that has none. There is no frame
      // this browser can send that would measure whether that machine has one,
      // and drawing a dark tab would be this client making a claim the machine
      // went out of its way not to make.
      ...(this.copilot.offered ? [{ screen: 'copilot' as Screen, label: 'Copilot' }] : []),
      { screen: 'sessions', label: 'Sessions' },
      ...(this.servesLocalhost ? [{ screen: 'localhost' as Screen, label: 'Localhost' }] : []),
      // Absent — not disabled — for a guest, the same rule the Copilot tab
      // follows: the capability is withheld at the source, so a device that was
      // not told `watch` is not shown a door to it.
      ...(watchOffered(this.capabilities) ? [{ screen: 'browser' as Screen, label: 'Browser' }] : []),
      { screen: 'settings', label: 'Settings' },
    ]
    this.tabs.replaceChildren(
      ...options.map((option) => {
        // Machines is Settings' own screen rather than a fourth place to be, so
        // the strip keeps pointing at Settings while it is open. Without this the
        // pushed screen would leave every tab unmarked, which reads as having
        // fallen out of the app.
        const here =
          this.screen === option.screen ||
          (option.screen === 'settings' && (this.screen === 'machines' || this.screen === 'devices'))
        const tab = element('button', here ? 'tab tab--here' : 'tab', option.label)
        tab.type = 'button'
        // `aria-current` rather than `aria-pressed`: these are two places to be,
        // not two switches, and a screen reader should say "current page".
        if (here) tab.setAttribute('aria-current', 'page')
        tab.addEventListener('click', () => this.goTo(option.screen))
        return tab
      }),
    )
  }

  /**
   * Move between the two list screens.
   *
   * The port list is asked for on arrival rather than kept fresh in the
   * background: a `ports` frame runs a real `lsof` on somebody's machine, and
   * polling it while nobody is looking is the kind of cost that only shows up on
   * a laptop's battery. Asked once, and only when there is a socket — offline,
   * the screen shows the last answer and says how old it is.
   */
  private goTo(screen: Screen): void {
    if (this.screen === screen) return
    // Leaving the watch screen stops every cast: a screencast nobody is looking
    // at is the host's compositor spending itself for nothing, and the strip is
    // asked for again on the way back in.
    if (this.screen === 'browser' && screen !== 'browser') this.stopAllWatch()
    this.screen = screen
    // A menu or a rename field belongs to the row it was opened on, and that row
    // is not on this screen. Left set, the next visit to the screen it came from
    // would arrive with a field already open under somebody's finger.
    this.openRow = null
    // And a half-answered confirmation is abandoned rather than parked. Coming
    // back to Sessions and finding a Close session button already waiting under
    // a thumb would be the app holding a question nobody is still asking.
    this.closing = null
    // Same rule for the device Remove confirmation.
    this.removing = null
    this.renamingPort = null
    this.renamingMachine = null
    // The roster is asked for on arrival, for the reason the dev-server list is:
    // it reads state the host already holds, and the ask is also what this
    // connection has to send to be sure of a fresh list — the `devices.changed`
    // push keeps it current after, but only for a device that was connected when
    // the change happened.
    if (screen === 'devices') this.askDevices()
    // The tab strip is asked for on arrival — it reads state the host already
    // holds, and the ask is also what subscribes this connection to the pushes
    // that follow when a tab opens or closes on the machine.
    if (screen === 'browser' && watchOffered(this.capabilities)) this.requestSurfaces()
    if (
      screen === 'localhost' &&
      this.localhost.ports === null &&
      this.state.phase === 'online' &&
      localhostOffered(this.capabilities)
    ) {
      this.localhostDo({ t: 'list' })
    }
    // The dev-server ask is unconditional on arrival rather than "only if we
    // have no rows", and that is the difference between the two features: a port
    // list is a scan somebody pays for, while `dev.status` reads a `package.json`
    // the desktop has usually already read — and asking is also what subscribes
    // this connection to the pushes.
    if (screen === 'localhost') this.askDevServers()
    // Asked on arrival for the same reason the port list is not: these four
    // frames read state the desktop already holds, and asking is also what
    // subscribes this connection to the pushes that follow. Refused politely by
    // `copilotStep` when the connection is not open, so there is no second
    // condition here to get out of step with the one in that module.
    if (screen === 'copilot') {
      // Opening the tab is what un-folds the panel, which is what makes the fold
      // dot a way to get it out of the way rather than a preference somebody has
      // to go and find again. It matters here rather than in `renderDock` because
      // the dock is not drawn on this screen at all — the layout rule — so this
      // is the only moment the flag can be cleared by a deliberate act.
      this.dockFolded = false
      this.copilotDo({ t: 'attach' })
    }
    this.render()
  }

  /**
   * Whether the second tab has anything behind it.
   *
   * Two capabilities, one screen. `localhost` fills the port list and `devserver`
   * fills the projects below it, and a desktop may advertise either without the
   * other — the public demo box deliberately withholds `localhost` so a stranger
   * is not offered a byte pipe to its loopback. So the tab appears when *either*
   * half can be drawn, and each half checks for itself.
   */
  private get servesLocalhost(): boolean {
    return localhostOffered(this.capabilities) || devserverOffered(this.capabilities)
  }

  /**
   * What a machine asked for, and the sentence the desktop had no way to write.
   *
   * The three facts named here are the same three the approval prompt names on
   * the phones — the repository, the account, and the machine that asked — and
   * that is deliberate: this is the same event, reported by a client that cannot
   * answer it. What replaces the buttons is the explanation and the two routes
   * that do work.
   *
   * Everything variable in it goes through `plain`, like every other string that
   * came off this socket.
   */
  private renderCredentialAsk(): void {
    const ask = this.credentialAsk
    this.credentialCard.hidden = ask === null
    if (ask === null) {
      this.credentialCard.replaceChildren()
      return
    }

    const headline = element(
      'p',
      'ask__headline',
      plain(credentialHeadline(ask, `The ${this.noun}`)),
    )
    const why = element('p', 'ask__why', CREDENTIAL_EXPLANATION)
    const dismiss = element('button', 'button button--quiet', 'Dismiss')
    dismiss.type = 'button'
    dismiss.addEventListener('click', () => {
      this.credentialAsk = null
      this.renderCredentialAsk()
    })
    this.credentialCard.replaceChildren(headline, why, dismiss)
  }

  /**
   * The bar over everything, and the three questions it answers.
   *
   * What this is, where the back chevron goes, and — the part that is new —
   * *which machine you are looking at*. That last one had nowhere to live while
   * there was only one machine; the subtitle simply printed its host id. With
   * several it is the single most important fact on the screen, because every row
   * under it belongs to one of them.
   *
   * So the subtitle becomes a button, and only when there is something to press it
   * for. One machine is not a choice and is not drawn as one — the standing rule
   * in this client, the same one that decides whether the folder picker appears —
   * and the label is the machine's name rather than its address, which is the whole
   * reason `machines.ts` has nicknames.
   */
  private renderHeader(): void {
    const attached = this.sessions.find((session) => session.id === this.attachedId)
    this.back.hidden = this.backTarget() === null
    this.attachButton.hidden = !this.canSendFiles
    this.renderModeButton()
    // The composer asks the same four facts the toggle does, so it is redrawn
    // on the same event: a socket that goes while somebody is mid-sentence must
    // grey the field rather than take the message and drop it.
    this.chatComposer?.render()
    this.title.textContent = BRAND.name
    if (this.screen === 'terminal' && attached) {
      this.title.textContent = attached.title
      this.subtitle.replaceChildren(`${attached.provider} · ${shortenPath(attached.cwd)}`)
      return
    }
    if (this.screen === 'machines') this.title.textContent = 'Machines'
    if (this.screen === 'add-server') this.title.textContent = 'Add a server'
    if (this.screen === 'devices') this.title.textContent = 'Devices'
    if (this.screen === 'settings') this.title.textContent = 'Settings'
    if (this.screen === 'copilot') this.title.textContent = 'Copilot'

    const machine = this.machine
    if (machine === null) {
      this.subtitle.replaceChildren('Not paired')
      return
    }
    // Named by the person, or by the route it is actually on. Printing
    // `location.host` for a relay pairing was true of this page and false of the
    // machine — the browser can be served from anywhere now, and a subtitle that
    // reads like an address is read as one.
    const label = machineLabel(machine, this.origin)
    if (this.book.machines.length < 2 || this.screen === 'machines') {
      this.subtitle.replaceChildren(label)
      return
    }
    const switcher = element('button', 'header__machine', label)
    switcher.type = 'button'
    switcher.setAttribute('aria-label', `${label} — choose a machine`)
    switcher.addEventListener('click', () => this.goTo('machines'))
    // The chevron is a separate node so the name can ellipsise without taking the
    // affordance with it. A nickname is up to twenty-four characters and a phone
    // header is not. It is the same turned `›` the group headers use rather than a
    // `⌄`, for the same measured reason: the two glyphs sit on different baselines
    // in this face and the downward one hangs visibly below the text it follows.
    this.subtitle.replaceChildren(switcher, element('span', 'header__machine-mark', '›'))
  }

  /**
   * Where the back chevron goes from here, or null when it is not drawn.
   *
   * One function rather than a `hidden` rule beside a click handler, because those
   * are two statements of one fact and they have already been one negation apart
   * once — `.header__back[hidden]` carries a comment about the time the chevron
   * sat on the pair screen pointing at nothing.
   */
  private backTarget(): Screen | null {
    if (this.screen === 'terminal') return 'sessions'
    if (this.screen === 'machines') return 'settings'
    if (this.screen === 'devices') return 'settings'
    // The pair screen has a way back only when it was reached deliberately from
    // the Machines screen. A browser with no machines has nowhere to go back to,
    // and a chevron there would be the bug that rule exists to prevent.
    if (this.screen === 'pair' && this.pairingAnother && this.book.machines.length > 0) return 'machines'
    // The Add-server screen always has a way back, because it is always reached
    // from somewhere: the pair screen on a fresh browser, the Machines screen on
    // one that already has machines. Which of the two is remembered rather than
    // inferred, so the chevron returns to the screen the person actually left.
    if (this.screen === 'add-server') return this.addServerFrom
    return null
  }

  /** The chevron was pressed. Leaving a terminal is its own operation. */
  private goBack(): void {
    const target = this.backTarget()
    if (target === null) return
    if (this.screen === 'terminal') {
      this.leaveTerminal()
      return
    }
    if (this.screen === 'add-server') {
      this.leaveAddServer()
      this.goTo(target)
      return
    }
    if (this.screen === 'pair') {
      // Abandoning a half-finished second pairing. The connection was pointed at
      // whatever the typed code found, so it goes back to the machine that was
      // being used — anything else leaves a socket dialling a machine this
      // browser has no credential for.
      this.pairingAnother = false
      const current = this.book.currentId
      this.screen = target
      this.render()
      if (current !== null && this.dialledId !== current) {
        this.book = { ...this.book, currentId: null }
        this.switchTo(current)
      }
      return
    }
    this.goTo(target)
  }

  private renderBanner(): void {
    const { phase, detail, retryAt } = this.state
    this.banner.className = `banner banner--${phase}`

    let text = detail
    if (retryAt !== null && (phase === 'waiting' || phase === 'pending')) {
      const seconds = Math.max(0, Math.ceil((retryAt - Date.now()) / 1000))
      text = seconds > 0 ? `${detail} Retrying in ${seconds}s.` : `${detail} Retrying…`
    }
    this.bannerText.textContent = text

    // A retry button on a state retrying cannot fix — or with no connection
    // behind it at all — is a button that does nothing when pressed.
    this.bannerAction.hidden =
      this.connection === null || phase === 'rejected' || phase === 'incompatible' || phase === 'connecting'
  }

  private renderContent(): void {
    switch (this.screen) {
      case 'terminal':
        this.showTerminalScreen()
        return
      case 'pair':
        this.content.replaceChildren(this.pairScreen())
        return
      case 'add-server':
        this.content.replaceChildren(this.addServerScreen())
        return
      case 'localhost':
        this.content.replaceChildren(this.localhostScreen())
        return
      case 'settings':
        this.content.replaceChildren(this.settingsScreen())
        return
      case 'machines':
        this.content.replaceChildren(this.machinesScreen())
        return
      case 'devices':
        this.content.replaceChildren(this.devicesScreen())
        return
      case 'sessions':
        this.content.replaceChildren(this.sessionsScreen())
        return
      case 'copilot':
        this.content.replaceChildren(this.copilotScreen())
        return
      case 'browser':
        this.content.replaceChildren(this.browserScreen())
        return
    }
  }

  /* --------------------------------------------------------- live view -- */

  /**
   * The watch screen: the machine's open pages as a strip, and a canvas for each
   * one being watched.
   *
   * The tab strip is data — `browser.surfaces.rows`, not pixels — because it is
   * our own UI; only the page *contents* are a screencast. A guest is never sent
   * a frame and never offered this tab, so reaching it at all means the host said
   * yes; the sentence for a withheld capability is here only for the edge where a
   * reconnect narrowed what this device may do while the screen was open.
   *
   * The canvases are reused across renders rather than rebuilt: each carries a
   * `WatchCanvas` with its listeners and its last-drawn frame, so re-appending
   * the same node moves it into the fresh screen without tearing the stream down.
   */
  private browserScreen(): HTMLElement {
    const screen = element('div', 'screen screen--watch')
    if (!watchOffered(this.capabilities)) {
      screen.append(element('p', 'note note--plain', WATCH_UNAVAILABLE))
      return screen
    }

    if (this.browserSurfaces.length === 0) {
      const note =
        this.state.phase === 'online'
          ? `Asking the ${this.noun} which pages it has open…`
          : `Reconnecting to the ${this.noun} to show its open pages…`
      screen.append(element('p', 'note note--plain', note))
    } else {
      const strip = element('ul', 'watch-strip')
      for (const surface of this.browserSurfaces) strip.append(this.surfaceRow(surface))
      screen.append(strip)
    }

    const stage = element('div', 'watch-stage')
    for (const view of this.browserCanvases.values()) stage.append(view.element)
    if (this.browserCanvases.size > 0) screen.append(stage)
    return screen
  }

  /** One row of the tab strip: what the page is, and whether it is being watched. */
  private surfaceRow(surface: WatchSurface): HTMLElement {
    const row = element('li', 'watch-row')
    const label = element('div', 'watch-row__label')
    label.append(element('span', 'watch-row__title', surface.title || surface.url || 'Untitled page'))
    if (surface.url !== '') label.append(element('span', 'watch-row__url', surface.url))
    row.append(label)

    const watching = this.browserCanvases.has(surface.window)
    const action = element('button', 'watch-row__action', watching ? 'Stop' : 'Watch')
    action.type = 'button'
    action.addEventListener('click', () =>
      watching ? this.stopWatch(surface.window) : this.startWatch(surface.window),
    )
    row.append(action)
    return row
  }

  /**
   * Start watching one window: mount a canvas, then ask the host to stream it.
   *
   * The watch is sent *after* the canvas is in the DOM, because the width it
   * negotiates is the canvas's own laid-out width — asked before it is on screen,
   * that width is zero. A `ResizeObserver` renegotiates it when the box changes,
   * which is what a rotation or a split-screen resize is.
   */
  private startWatch(window: string): void {
    if (this.browserCanvases.has(window)) return
    if (this.browserCanvases.size >= MAX_WATCH_WINDOWS) return
    const canvas = element('canvas', 'watch-canvas')
    // Focusable, so a hardware keyboard drives the page rather than the tab.
    canvas.tabIndex = 0
    const view = new WatchCanvas({ window, canvas, send: (message) => this.connection?.send(message) === true })
    view.attach()
    this.browserCanvases.set(window, view)
    if (typeof ResizeObserver !== 'undefined') {
      const observer = new ResizeObserver(() => view.onResize())
      observer.observe(canvas)
      this.browserObservers.set(window, observer)
    }
    // Mount first (so the canvas has a width), then negotiate the stream.
    if (this.screen === 'browser') this.renderContent()
    view.watch()
  }

  /** Stop watching one window: drop the stream, the canvas and its observer. */
  private stopWatch(window: string): void {
    const view = this.browserCanvases.get(window)
    if (view === undefined) return
    view.unwatch()
    view.dispose()
    this.browserCanvases.delete(window)
    this.browserObservers.get(window)?.disconnect()
    this.browserObservers.delete(window)
    if (this.screen === 'browser') this.renderContent()
  }

  /**
   * Stop every cast — on leaving the screen, on a disconnect, on a machine that
   * no longer offers the view.
   *
   * A screencast is per-connection on the host and is dropped when the socket
   * closes, so holding canvases past that point would be canvases waiting on
   * frames that will never come; re-entering the screen asks again from scratch.
   */
  private stopAllWatch(): void {
    for (const [window, view] of this.browserCanvases) {
      view.unwatch()
      view.dispose()
      this.browserObservers.get(window)?.disconnect()
    }
    this.browserCanvases.clear()
    this.browserObservers.clear()
  }

  /** Ask the host for its open pages — the tab strip, as data. */
  private requestSurfaces(): void {
    this.browserRid += 1
    this.connection?.send({ t: 'browser.surfaces', rid: `sf-${this.browserRid}` })
  }

  /**
   * Pair, from the one thing a person can be holding: six digits.
   *
   * There used to be three shapes in this field — a `terminaldeck://pair?…`
   * link, a tailnet link with the token in its fragment, and a code — and a
   * function whose job was to tell them apart. Two of the three are gone, and
   * what is left is not a paste target at all: it is six digits read off the
   * other screen. `rendezvous.ts` explains why looking them up at a relay is
   * safe against a relay that would like to answer in the machine's place.
   *
   * ## The field is `inputmode="numeric"` and it is the point
   *
   * Half the argument for digits is what a phone puts under them. `type="text"`
   * with a numeric inputmode rather than `type="number"`: a number input strips
   * leading zeros, offers a spinner, and on some browsers refuses a paste that
   * is not a valid number — and `000042` is a perfectly good pairing code that
   * all three of those would destroy.
   *
   * It submits itself on the sixth digit. There is nothing to decide after it —
   * a code is exactly six long, so a button press at that point is a tap that
   * asks a question with one possible answer.
   */
  private pairScreen(): HTMLElement {
    // `screen--form`, which caps the column far tighter than the list screens
    // do. A six-digit field and a full-width primary button stretched across a
    // 27" monitor is not "using the window", it is a form nobody can aim at —
    // see the width rules at the foot of styles.css.
    const screen = element('div', 'screen screen--form')

    /*
     * A title, an ⓘ, and the field. Five sentences used to stand between them.
     *
     * A lead paragraph, a numbered list of three steps, a label over the field
     * and a two-sentence footer about codes and sealing — on a screen whose only
     * act is typing six digits. *"Don't put any single statement in anywhere…
     * We want simplicity. Let the smart people use it. Smart people knows how it
     * works."* Nothing is lost: every word of it is behind the ⓘ, which is where
     * he said an explanation goes — *"just if somewhere it's very required, give
     * the i icon like other ones, information icon in the settings, same way."*
     *
     * The heading stays neutral on a fresh install by design: nothing has
     * answered yet, so nothing here may claim to know what kind of computer is
     * at the other end. It sharpens to "Mac" or "PC" the moment one does — which
     * for a re-pair is immediately, because the stored credential remembers.
     */
    const days = Math.round(REMEMBERED_TTL_MS / 86_400_000)
    const heading = element('div', 'screen__heading')
    heading.append(
      element('h2', undefined, `Pair with your ${this.noun}`),
      infoDot(
        'pairing',
        `${BRAND.name} on the ${this.noun} shows a six-digit code; type it here. The ${this.noun} does ` +
          'not need to be on the same network. A code is good for one minute and one use, and pairing ' +
          `alone does not grant access — the ${this.noun} still asks somebody to approve this browser. ` +
          'Everything between the two is sealed end to end; the relay that carries it holds no key and ' +
          'cannot read a session.' +
          // The sentence that used to be a paragraph of its own under the field
          // on a second pairing. It is the same fact — `remember` is one field
          // and one store, so a second machine cannot be remembered differently
          // from the first — and Settings is still the one place it changes.
          (this.book.machines.length === 0
            ? ''
            : this.remember === 'this-browser'
              ? ` This ${this.noun} will be remembered in this browser too, until you unpair it or ` +
                `${days} days pass without using it. Settings is where that changes.`
              : ' This pairing will end when you close this tab, like the machine you are already ' +
                'paired with. Settings is where that changes.'),
      ),
    )
    screen.append(heading)

    // Every attribute, and the reasoning for each, is in `code-field.ts` — where
    // a test can reach it. Nothing in this file can be rendered by the suite, so
    // a keypad decision written here is one that nothing checks.
    const input = asCodeField(element('input'))
    // The label a screen reader needs, and which the screen does not: a field
    // this size on a screen with one act on it is not ambiguous to look at.
    input.setAttribute('aria-label', `The six digits shown on the ${this.noun}`)
    // One class, and the presentation lives in the sheet with the rest of it.
    // It used to borrow `.button--quiet` and then patch three inline styles on
    // top, which meant the one field on the screen wore the *secondary* ink and
    // no stylesheet could be held to it.
    input.className = 'code-field'
    screen.append(input)

    // Asked once per browser, not once per machine.
    //
    // The question is about *this computer* — whether a credential may outlive the
    // tab — and it is answered on the first pairing. Asking it again while adding a
    // second machine would be asking somebody to re-decide something they have
    // already decided, on a screen where the honest answer is "the same as last
    // time"; worse, the two answers cannot differ, because `remember` is one field
    // and one store. So the second time it is *stated* instead, with the one place
    // it can be changed named.
    // Only the choice, and only the first time. What the answer already is, on a
    // second pairing, is in the ⓘ above — it was a paragraph on the screen and
    // it is not a decision, so it is not a thing the screen has to carry.
    if (this.book.machines.length === 0) screen.append(this.rememberChoice())

    const submit = element('button', 'button', this.looking ? 'Looking…' : 'Pair')
    submit.type = 'button'
    submit.disabled = this.looking
    submit.addEventListener('click', () => void this.startPairing(input.value))
    screen.append(submit)

    /*
     * The other door, on the screen that is the empty state of a fresh browser.
     *
     * A code needs somebody standing at the machine to read it off a screen, and
     * a headless server has neither. That machine is reached by signing in to
     * it, and until now there was nowhere in this client to do that — the wire
     * existed and nothing called it. This is the whole of the entry point: one
     * quiet button under the primary one, because pairing is still what most
     * people are here to do and the two must not read as equal choices.
     */
    const signIn = element('button', 'button button--quiet', 'Sign in to a server instead')
    signIn.type = 'button'
    signIn.addEventListener('click', () => this.openAddServer('pair'))
    screen.append(signIn)

    /*
     * Auto-submit, and the guard that makes it safe to have.
     *
     * `input` fires for a paste as well as for a keystroke, so pasting six
     * digits pairs without a tap — which is the common case on a laptop, where
     * the code came through a message. `startPairing` returns immediately while
     * `this.looking` is set, so a seventh `input` event (a character typed into
     * a full field, an autocomplete replacement) cannot start a second lookup.
     */
    input.addEventListener('input', () => {
      const typed = normaliseCode(input.value)
      if (typed === null || this.looking) return
      void this.startPairing(typed)
    })
    // Enter still works, for somebody who typed five digits and a sixth that
    // was rejected — the field is not the only way to ask.
    input.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') void this.startPairing(input.value)
    })

    // The footer that stood here — what a code is worth, and what the relay can
    // and cannot read — is behind the ⓘ above. Same words, one tap away.
    //
    // Focused after the tree is built, by the caller that puts it on screen —
    // see `renderContent`. Focusing an element that is not in the document does
    // nothing, and doing nothing quietly is how the keypad stopped appearing.
    queueMicrotask(() => input.focus())
    return screen
  }

  /**
   * "Is this browser yours?", asked once, before anything is written.
   *
   * ## Why this is on screen at all
   *
   * The iOS and Android clients never ask, and they are right not to: their
   * credential is in the Keychain or the Keystore, on a device that belongs to
   * the person holding it. This one has neither. What it has is storage any
   * script on the origin can read, and a reason to exist that is *specifically*
   * the computer somebody does not own — a work laptop, a machine in a lab, a
   * friend's desktop. A pairing left behind on one of those is a live shell on
   * the owner's machine, sitting in a browser profile, for whoever opens it next.
   *
   * There is no account to sign out of and there must not be. So the only place
   * this can be decided is here, at the one moment the person and the computer
   * are both present, and the honest thing to do is ask rather than guess.
   *
   * ## Why "just for this visit" is the default
   *
   * Because getting it wrong in that direction costs a re-pair, and getting it
   * wrong in the other direction leaves a shell on a stranger's machine. The
   * option that is right for the person's own laptop is one tap away and is
   * spelled out beside it; the option that is safe on every machine is the one
   * that happens if they read nothing at all.
   *
   * Radios rather than a checkbox because both answers get a sentence. A ticked
   * or unticked box explains one state and leaves the reader to infer the other,
   * and the design brief's bar is a screen somebody who has never seen it can
   * read.
   */
  private rememberChoice(): HTMLElement {
    const days = Math.round(REMEMBERED_TTL_MS / 86_400_000)
    const group = element('fieldset', 'remember')
    const legend = element('legend', 'remember__legend')
    legend.append(
      element('span', undefined, 'Is this browser yours?'),
      /*
       * The consequence of each answer, behind the ⓘ rather than under each
       * radio.
       *
       * The choice itself stays on the screen because it *is* a decision, and
       * the two titles are enough to make it: this is the one question on this
       * screen and it has two answers. What was under them was a paragraph each,
       * on the screen he counted five sentences on.
       */
      infoDot(
        'this choice',
        'Just for this visit: the pairing is gone the moment you close this tab — use it on a computer ' +
          `that is not yours. Remember this browser: it stays paired until you unpair it or ${days} days ` +
          'pass without using it, and anyone who uses this browser can open your sessions.',
      ),
    )
    group.append(legend)

    const options: Array<{ value: Remember; title: string }> = [
      { value: 'this-tab', title: 'Just for this visit' },
      { value: 'this-browser', title: 'Remember this browser' },
    ]

    for (const option of options) {
      const row = element('label', 'remember__option')
      const radio = element('input')
      radio.type = 'radio'
      radio.name = 'terminaldeck-remember'
      radio.value = option.value
      radio.checked = this.remember === option.value
      radio.addEventListener('change', () => {
        this.remember = option.value
      })

      const text = element('span', 'remember__text')
      text.append(element('span', 'remember__title', option.title))
      row.append(radio, text)
      group.append(row)
    }
    return group
  }

  /**
   * Turn six typed digits into a connection, or say why not.
   *
   * The wait is the whole reason this is asynchronous — a memory-hard derivation
   * and a round trip to the relay take about a second between them, which is a
   * second with nothing on screen unless the button says so.
   *
   * ## Why a code that is not found still tries this page's own origin
   *
   * Because when this page was served *by the machine itself*, over the tailnet,
   * the address is the origin and there is nothing to look up. That is the one
   * case a rendezvous cannot help with and does not need to: the desktop mints
   * one shape of token for every client, so the same six digits are a legitimate
   * direct token as well as a possible rendezvous.
   *
   * Relay first and origin second, because the relay is the route that works
   * from anywhere and the origin only works when this page came from the
   * machine. Doing it the other way round would send every code to whatever
   * happens to be serving this page.
   *
   * It is two attempts and one sentence. The fallback is invisible unless it
   * works, and if neither reaches anything the banner is the connection's own
   * account of the second attempt rather than a summary written here.
   */
  private async startPairing(typed: string): Promise<void> {
    if (this.looking) return
    const code = normaliseCode(typed)
    if (code === null) {
      this.pairNotice('That is not a pairing code. It is six digits, like 123456.')
      return
    }

    this.looking = true
    this.pairNotice('Looking for that machine…')
    this.renderContent()
    let found: Awaited<ReturnType<typeof lookupMachine>> = null
    try {
      found = await lookupMachine({ code })
    } catch {
      // `lookupMachine` answers null for every ordinary failure, so reaching
      // here means the derivation itself could not run — a browser with no
      // `crypto.getRandomValues`, essentially. Caught rather than left to become
      // an unhandled rejection, because the only visible effect of one of those
      // is a button that stops saying "Looking…" and nothing else happening.
      this.looking = false
      this.renderContent()
      this.pairNotice('This browser could not run the pairing crypto, so nothing was sent.')
      return
    } finally {
      this.looking = false
    }
    this.renderContent()
    /*
     * The name the machine gave itself, held until the credential is written.
     *
     * It cannot travel with the endpoint — an endpoint is an address and is
     * persisted as one — and it cannot be asked for later, because the offer is
     * a one-frame conversation at a rendezvous slot that is gone by then. So it
     * waits here for `putCredential`, which is the moment the machine becomes a
     * row somebody has to be able to identify.
     */
    this.dialledName = found?.name ?? null
    // The code is the pairing token as well as the address, which is the whole
    // shape of this scheme: `device-auth.ts` hashes what was typed and never
    // learns where it was looked up.
    this.connect(code, found?.endpoint ?? DIRECT)
  }

  /** One sentence on the pair screen, in the banner that is already there. */
  private pairNotice(detail: string): void {
    this.state = { phase: 'offline', detail, retryAt: null, attempts: 0 }
    this.renderBanner()
  }

  /* ---------------------------------------------------------- add a server -- */

  /**
   * Open the sign-in form, remembering where it was opened from.
   *
   * The `from` is the only state the screen needs that it cannot work out for
   * itself: a browser with no machines reached it from the pair screen and a
   * browser with several reached it from Machines, and the chevron has to go
   * back to whichever it was rather than to whichever the book implies.
   */
  private openAddServer(from: Screen): void {
    this.addServerFrom = from
    this.addProblem = null
    this.addFailure = null
    this.screen = 'add-server'
    this.render()
  }

  /**
   * Forget the form, and the login in it.
   *
   * Called on the way out by every route — the chevron, and a sign-in that
   * succeeded. The secret is the reason this is a method rather than three
   * assignments at two call sites: a password or a private key left on the model
   * would outlive the screen, sit in memory for the life of the tab, and be
   * there in a heap snapshot of a page anybody can open the dev tools on. It
   * buys nothing to keep — the credential the sign-in earned is what
   * reconnects, and it is stored where the person said it may be.
   */
  private leaveAddServer(): void {
    this.addFields = { address: '', username: '', secret: '', method: 'password' }
    this.addProblem = null
    this.addFailure = null
    this.addingServer = false
  }

  /**
   * Sign in to a machine nobody is standing at.
   *
   * ## Why this screen exists at all
   *
   * Pairing is six digits shown on a desktop, and it works because there is a
   * person at that desktop to read them off it. A headless server has no screen
   * and nobody near it, which is precisely the machine this is for: the login
   * that box already trusts *is* the credential, and `enroll` trades it for a
   * device row without anyone walking anywhere.
   *
   * ## The three fields, and why the first one is a paste rather than a code
   *
   * A first connection to a machine this browser has never met is a Noise **IK**
   * handshake, and IK needs the machine's static public key before it can send
   * its first message. A host id is `BASE32(SHA-256(secret))` — a one-way hash —
   * so no code a person can type carries a key, and a field that took one would
   * be a Sign in button that cannot be implemented. So the machine prints its
   * address and it is pasted here; `server-address.ts` reads every shape one
   * arrives in and says what is missing when it is not one.
   *
   * ## The honest limit, stated on the screen
   *
   * A browser cannot open an SSH connection — there is no such API and there
   * will not be one — so this client cannot install a server on a machine that
   * has none, the way a desktop with a terminal could. It shows the command
   * instead, and only where a missing server is actually the explanation. See
   * `add-server.ts`, which decides that from what the machine said rather than
   * from a guess here.
   */
  private addServerScreen(): HTMLElement {
    const screen = element('div', 'screen screen--form')

    const heading = element('div', 'screen__heading')
    heading.append(
      element('h2', undefined, 'Sign in to a server'),
      infoDot(
        'signing in',
        'A server with no screen cannot show a pairing code, so it prints an address instead — the relay ' +
          'it is reachable at, its host id and its public key. Paste that, then the login on that machine: ' +
          `${BRAND.name} checks it against the machine's own SSH and mints this browser a device of its own. ` +
          'The login is used for that one check and is never stored. Everything between the two ends is ' +
          'sealed; the relay that carries it holds no key and cannot read a session.',
      ),
    )
    screen.append(heading)

    screen.append(
      this.addField({
        label: 'Server address',
        // Multi-line, because an address is a few hundred characters and a
        // terminal wraps it. A single-line field would show a person the last
        // forty characters of what they pasted and nothing else. Four rows fits
        // most of one at a phone width and scrolls for the rest; the field is
        // resizable, which is the honest answer to a value with no fixed length.
        lines: 4,
        value: this.addFields.address,
        placeholder: 'The block the machine printed',
        mono: true,
        field: 'address',
        onInput: (value) => {
          this.addFields.address = value
        },
      }),
    )

    screen.append(
      this.addField({
        label: 'Login',
        value: this.addFields.username,
        placeholder: 'The username you would SSH in as',
        field: 'username',
        onInput: (value) => {
          this.addFields.username = value
        },
      }),
    )

    screen.append(this.addMethodChoice())

    screen.append(
      this.addField({
        label: this.addFields.method === 'password' ? 'Password' : 'Private key',
        // A PEM is several kilobytes and has real newlines in it, so the key
        // method gets a box and the password gets a line. The password is also
        // the one field in this client that is masked, for the obvious reason.
        lines: this.addFields.method === 'key' ? 6 : 0,
        secret: this.addFields.method === 'password',
        mono: this.addFields.method === 'key',
        value: this.addFields.secret,
        placeholder: this.addFields.method === 'password' ? '' : '-----BEGIN OPENSSH PRIVATE KEY-----',
        field: 'secret',
        onInput: (value) => {
          this.addFields.secret = value
        },
      }),
    )

    /*
     * The same question the pair screen asks, on the same terms.
     *
     * It is about *this computer* — whether a credential may outlive the tab —
     * not about which machine is being added, so it is asked once per browser
     * and only while there are no machines. Leaving it off this screen would
     * have meant somebody who reached the product through a server rather than
     * through a desktop was never asked at all, and silently given the answer
     * that makes them sign in again after every tab close.
     */
    if (this.book.machines.length === 0) screen.append(this.rememberChoice())

    const submit = element('button', 'button', this.addingServer ? 'Signing in…' : 'Sign in')
    submit.type = 'button'
    // Disabled only while one is in flight. Every other refusal is a sentence
    // under the field it is about, because a button that greys itself out has
    // told somebody they are wrong without telling them where.
    submit.disabled = this.addingServer
    submit.addEventListener('click', () => void this.submitAddServer())
    screen.append(submit)

    const failure = this.addFailure
    if (failure !== null) {
      // The machine's own words, or this client's account of a channel that
      // closed with none. See `signInFor` and `closeFailure`.
      screen.append(element('p', 'form__failure', failure.message))
      if (failure.install) screen.append(this.installBlock())
    }

    return screen
  }

  /**
   * One labelled field, with the sentence about it underneath when there is one.
   *
   * A single builder rather than three, because the three differ in four
   * attributes and nothing else — and because the thing that must never differ
   * between them is where the error goes. A message printed above one field and
   * below another is a form somebody has to hunt around.
   */
  private addField(spec: {
    label: string
    value: string
    field: FieldFault['field']
    onInput: (value: string) => void
    placeholder?: string
    lines?: number
    mono?: boolean
    secret?: boolean
  }): HTMLElement {
    const block = element('div', 'form__row')
    const id = `add-${spec.field}`
    const label = element('label', 'form__label', spec.label)
    label.htmlFor = id
    block.append(label)

    const multiline = (spec.lines ?? 0) > 1
    const input = multiline ? element('textarea') : element('input')
    input.id = id
    input.className = spec.mono === true ? 'form__field form__field--mono' : 'form__field'
    input.value = spec.value
    if (spec.placeholder !== undefined && spec.placeholder !== '') input.placeholder = spec.placeholder
    if (input instanceof HTMLTextAreaElement) {
      input.rows = spec.lines ?? 3
    } else {
      input.type = spec.secret === true ? 'password' : 'text'
      // A login is not a sentence, and every one of these turns a username into
      // something it is not on the way in.
      input.autocapitalize = 'none'
      input.autocomplete = 'off'
      input.spellcheck = false
    }
    // Held on the model rather than read at submit time, because any frame the
    // machine pushes rebuilds this screen — see `addFields`.
    input.addEventListener('input', () => spec.onInput(input.value))
    block.append(input)

    const problem = this.addProblem
    if (problem !== null && problem.field === spec.field) {
      input.setAttribute('aria-invalid', 'true')
      const said = element('p', 'form__problem', problem.message)
      said.id = `${id}-problem`
      input.setAttribute('aria-describedby', said.id)
      block.append(said)
    }
    return block
  }

  /**
   * Password or private key.
   *
   * Two buttons rather than a select, because there are two and both are worth
   * seeing at once; and it re-renders rather than swapping the field's type in
   * place, because the two fields are genuinely different shapes — a masked line
   * and a six-row box for a PEM.
   *
   * The secret is cleared on the switch. A password typed into the key box would
   * be sent to sshd as a key and refused, spending one of five attempts against
   * the host's limiter to say something this screen already knew.
   */
  private addMethodChoice(): HTMLElement {
    const block = element('div', 'form__row')
    block.append(element('p', 'form__label', 'Prove it with'))
    const row = element('div', 'form__methods')
    const options: Array<{ value: SignInMethod; title: string }> = [
      { value: 'password', title: 'Password' },
      { value: 'key', title: 'Private key' },
    ]
    for (const option of options) {
      const here = this.addFields.method === option.value
      const pick = element('button', here ? 'form__method form__method--here' : 'form__method', option.title)
      pick.type = 'button'
      pick.setAttribute('aria-pressed', here ? 'true' : 'false')
      pick.disabled = here || this.addingServer
      pick.addEventListener('click', () => {
        this.addFields = { ...this.addFields, method: option.value, secret: '' }
        this.addProblem = null
        this.renderContent()
      })
      row.append(pick)
    }
    block.append(row)
    return block
  }

  /**
   * The one-line install, and the sentence that says why it is here.
   *
   * Drawn only when a missing server is actually the explanation — a wrong
   * password does not get one. The limit is stated rather than implied: a
   * browser has no SSH and cannot run this for anybody, which is the whole
   * reason the command is on screen instead of a button.
   */
  private installBlock(): HTMLElement {
    const block = element('div', 'install')
    block.append(
      element(
        'p',
        'install__note',
        `A browser cannot open an SSH connection, so it cannot install ${BRAND.name} on that machine for ` +
          'you. Run this on the machine, then sign in.',
      ),
    )
    const line = element('div', 'install__line')
    line.append(element('code', 'install__command', INSTALL_COMMAND))
    const copy = element('button', 'button button--quiet install__copy', 'Copy')
    copy.type = 'button'
    copy.addEventListener('click', () => void this.copyInstall())
    line.append(copy)
    block.append(line)
    return block
  }

  /** The install command on the clipboard, or the honest word that it is not. */
  private async copyInstall(): Promise<void> {
    try {
      await navigator.clipboard.writeText(INSTALL_COMMAND)
      this.say('Copied the install command')
    } catch {
      // A clipboard write needs a secure context and, in some browsers, a
      // permission. A silent copy that did not happen is indistinguishable from
      // one that did, and the command is on screen to select by hand.
      this.say('This browser would not let the page copy it. Select the line instead.')
    }
  }

  /**
   * Check the form, run the exchange, and say what came back.
   *
   * Nothing is stored until a `welcome` has been earned on the same socket that
   * minted the credential — which is `runSignIn`'s whole sequence — so a machine
   * that mints and then refuses cannot leave a row in the book that nothing can
   * reconnect to.
   */
  private async submitAddServer(): Promise<void> {
    if (this.addingServer) return
    this.addProblem = null
    this.addFailure = null

    const checked = checkFields(this.addFields)
    if (!checked.ok) {
      this.addProblem = checked.problem
      this.renderContent()
      return
    }

    this.addingServer = true
    this.renderContent()

    let outcome: Awaited<ReturnType<typeof runSignIn>>
    try {
      outcome = await runSignIn({
        endpoint: checked.endpoint,
        username: checked.username,
        secret: checked.secret,
        method: checked.method,
        device: describeDevice(navigator.userAgent),
        // This browser's durable identity, not a fresh one: the device row the
        // machine is about to mint is bound to whatever key opens this channel,
        // and the connection that follows has to present the same one.
        deviceKeys: this.deviceKeys,
      })
    } catch {
      // `runSignIn` answers rather than throws for every ordinary failure, so
      // reaching here means the crypto could not run in this browser at all.
      this.addingServer = false
      this.addFailure = {
        ok: false,
        kind: 'fault',
        message: 'This browser could not run the sign-in, so nothing was sent.',
        install: false,
      }
      this.renderContent()
      return
    }

    this.addingServer = false
    if (!outcome.ok) {
      this.addFailure = outcome
      this.renderContent()
      return
    }
    this.finishAddServer(checked.endpoint, outcome)
  }

  /**
   * A signed-in machine becomes an ordinary one.
   *
   * The end state has to be indistinguishable from a pairing, which is why this
   * hands off to {@link switchTo} rather than writing a book and a connection by
   * hand: switching is what clears the previous machine's sessions, folders,
   * capabilities, roster and copilot, and a machine added by a route that forgot
   * one of those would show the last computer's list under the new one's name.
   *
   * The selection is deliberately cleared first. `withMachine` marks a new row
   * current, and `switchTo` refuses a machine that is already current — so
   * without this, adding a server would leave a book pointing at a machine
   * nothing had dialled.
   */
  private finishAddServer(endpoint: RelayEndpoint, outcome: Extract<Awaited<ReturnType<typeof runSignIn>>, { ok: true }>): void {
    const now = Date.now()
    const id = machineId(endpoint)
    const credential: StoredCredential = {
      token: outcome.token,
      deviceId: outcome.deviceId,
      deviceName: outcome.deviceName,
      pairedAt: now,
      // Read off the welcome this sign-in already earned, so the first paint
      // names the machine correctly instead of waiting for the next socket.
      hostPlatform: readHostPlatform(outcome.welcome.hostPlatform),
      endpoint,
      expiresAt: now + REMEMBERED_TTL_MS,
    }
    // The login goes now, before anything is drawn with it still in memory.
    this.leaveAddServer()

    this.book = withMachine(this.book, {
      id,
      nickname: null,
      hostName: cleanNickname(outcome.welcome.hostName ?? null),
      credential,
    })
    this.book = { ...this.book, currentId: null }
    this.keep()
    // Whatever brought this browser here is over, the same way `onCredential`
    // ends a pairing: a back chevron left pointing at the pair screen would be
    // a way back to a form nobody is filling in.
    this.pairingAnother = false
    this.switchTo(id)
  }

  private sessionsScreen(): HTMLElement {
    const screen = element('div', 'screen')
    screen.style.padding = '0'

    if (this.notice !== null) {
      screen.append(element('p', 'empty', this.notice))
    }

    const start = this.startBlock()
    if (start !== null) screen.append(start)

    if (this.sessions.length === 0) {
      screen.append(
        element(
          'p',
          'empty',
          this.state.phase === 'online'
            ? `No sessions are running on the ${this.noun}.`
            : `No sessions to show yet — this list is from the last time the ${this.noun} answered.`,
        ),
      )
    }

    const list = element('ul', 'sessions')
    const now = Date.now()
    for (const session of sortSessions(this.sessions, this.activity)) {
      const row = element('li')
      const button = element('button', 'session')
      button.type = 'button'

      const dot = element('span', `session__dot session__dot--${sessionTone(session)}`)
      const body = element('div', 'session__body')
      body.append(element('div', 'session__title', session.title))

      const since = formatSince(now, this.activity.get(session.id) ?? null)
      const meta = element('div', 'session__meta')
      // The time is only printed when one is actually known — see formatSince.
      meta.append(
        element(
          'span',
          undefined,
          [statusLabel(session), since].filter((part): part is string => part !== null).join(' · '),
        ),
      )
      // Which agent is in there. It was only ever visible from inside the
      // session, under the title, which is the one place somebody already knows
      // — the list is where it decides which row to open.
      if (session.provider !== '') meta.append(element('span', 'session__provider', session.provider))
      body.append(meta)

      // The folder, on its own line and in mono. It used to be the last clause
      // of the meta line, where it was the first thing to be ellipsised away and
      // read as more prose; a path is not prose. The whole value stays reachable
      // from a row that ellipsises, which is what the title is for.
      const where = element('div', 'session__where', shortenPath(session.cwd))
      where.title = session.cwd
      body.append(where)

      button.append(dot, body, element('span', 'session__chevron', '›'))
      button.addEventListener('click', () => this.openSession(session.id))
      /*
       * How the scan finds this row.
       *
       * The focus box is the **measured rectangle of a real row on this page**,
       * re-read every frame, so it follows the list as it scrolls and reflows.
       * Stamped on the button rather than on the `<li>` because the button is
       * what has the row's own bounds — the list item stretches to the column and
       * a hole cut to that would be a band across the screen rather than a box
       * around a session.
       */
      button.setAttribute(SCAN_ATTRIBUTE, session.id)

      /*
       * The row, and beside it the one thing a row can do besides open.
       *
       * Drawn only when the machine advertised `close` — a session layer that
       * cannot end a session never offers the method the capability is derived
       * from, and the public demo box withholds it on purpose — so this is never
       * a control that discovers it does not work. The line is a flex container
       * rather than the row being the whole `<li>`, because the tappable area
       * has to stop before the menu: a 60-point row with a second target inside
       * it is a row people hit the wrong half of.
       */
      const line = element('div', 'session-line')
      line.append(button)
      const closable = this.state.phase === 'online' && closeOffered(this.capabilities)
      if (closable) {
        const open = this.openRow === session.id
        const more = element('button', 'session__more', '···')
        more.type = 'button'
        more.setAttribute('aria-expanded', open ? 'true' : 'false')
        more.setAttribute('aria-label', `Actions for ${session.title}`)
        more.addEventListener('click', () => {
          this.openRow = open ? null : session.id
          // A menu opening is a decision abandoned. Leaving the confirm up while
          // a second row's menu opened would put two live questions on one
          // screen, with one pair of buttons between them.
          this.closing = null
          this.renderContent()
        })
        line.append(more)
      }
      row.append(line)

      if (closable && this.closing === session.id) row.append(this.closeConfirm(session))
      else if (closable && this.openRow === session.id) {
        const menu = element('div', 'port__menu')
        const close = element('button', 'port__menu-item port__menu-item--warn', 'Close session')
        close.type = 'button'
        close.addEventListener('click', () => {
          this.openRow = null
          this.closing = session.id
          this.renderContent()
        })
        menu.append(close)
        row.append(menu)
      }
      list.append(row)
    }
    screen.append(list)
    /*
     * Nothing else. This screen used to end with the lifetime block and a "Forget
     * this Mac" button, and both have moved — the lifetime question to Settings,
     * where it sits with the other things that are about this browser rather than
     * about a session, and Forget onto the machine's own row, where it can name
     * which machine it is about.
     *
     * That is the phone's arrangement and the phone's argument for it: everything
     * that was not a session lived behind one control in a corner, *"which is
     * where features go to be undiscovered"*, and the fix was to give them a
     * screen rather than to leave them at the bottom of this one. A session list
     * that ends in two settings is the same problem upside down.
     */
    return screen
  }

  /**
   * The confirmation, in the row, under the session it is about.
   *
   * ## Why it is here rather than in a dialog
   *
   * He asked for a confirmation by name — *"close the session (with a
   * confirmation)"* — and the interesting question is what a confirmation is
   * *for*. It is not for slowing somebody down; it is so the sentence describing
   * the consequence and the button causing it are read together. A `confirm()`
   * would put that sentence in a browser chrome box that names the *origin*
   * rather than the session, over a list that has scrolled away underneath it —
   * so the one thing a person needs to check, which row this is about, would be
   * the one thing they could no longer see.
   *
   * In the row, the title is directly above the question, the folder is directly
   * above that, and the destructive button is the one furthest from the thumb's
   * resting place. `closeQuestion` composes the sentence in `sessions.ts`,
   * where a test can hold it.
   *
   * ## The two buttons, in this order
   *
   * Cancel first. This list is scrolled with a thumb and the trailing edge is
   * where an accidental tap lands, so the irreversible one goes there only
   * because the whole strip only exists after a deliberate press on Close
   * session in the menu — this is already the second step, and the third would
   * be a control nobody finishes.
   */
  private closeConfirm(session: RemoteSession): HTMLElement {
    const block = element('div', 'session-confirm')
    block.append(element('p', 'session-confirm__ask', closeQuestion(session)))
    const actions = element('div', 'session-confirm__actions')

    const cancel = element('button', 'button button--quiet', 'Cancel')
    cancel.type = 'button'
    cancel.addEventListener('click', () => {
      this.closing = null
      this.renderContent()
    })

    const confirm = element('button', 'button button--danger', 'Close session')
    confirm.type = 'button'
    confirm.addEventListener('click', () => {
      // Sent, and nothing else. The row stays until the machine answers
      // `closed` — see that frame's handler for why an optimistic removal is
      // wrong here in particular. The label changes so the press is visibly
      // acknowledged on a slow link, and the button is disabled so a second
      // press cannot send a second frame about a session that is already going.
      this.connection?.send({ t: 'close', id: session.id })
      confirm.disabled = true
      confirm.textContent = 'Closing…'
      cancel.disabled = true
    })

    actions.append(cancel, confirm)
    block.append(actions)
    return block
  }

  /**
   * Everything the machine is serving, and everything it could serve, on one
   * screen that is not a wall.
   *
   * Asad, opening the phone app: *"I can already see a big list of local hosts. So
   * it should not be like that… we need to fold it in a better way"*, and then the
   * three things that would fix it — rename them, categorise them, and *"I don't
   * see any kind of option here to make anyone up or make anyone activated"*. He
   * then said the same thing about this client in one line: *"I mean web app also,
   * improve according to the new things."*
   *
   * What this screen was: `portsInto` drew every port the desktop named, in one
   * flat list, and `devInto` drew a second flat list of projects underneath it —
   * so a machine serving nine things showed nine identical `2019 · wslrelay` rows
   * and then said "Dev servers" and did it again. Three things happen to it now,
   * and all three are the phone's, ported as rules rather than as code.
   *
   * ## 1. It is grouped, from facts
   *
   * `port-catalog.ts` holds the rules and the reasoning. The short version is that
   * every group is derived from something the wire carries — a process name, a
   * proven dev-server port, the socket this browser is connected on — and the
   * three groups that are noise start folded rather than hidden.
   *
   * ## 2. Rows can be named, and naming one promotes it
   *
   * `port-book.ts` holds the names, in this browser, against the machine and the
   * port. A named port is lifted to the top group, which is the whole of *"we can
   * keep some in the list and we can keep some folded"* — one gesture, one meaning.
   *
   * ## 3. The dev servers are on the same list, joined to their own ports
   *
   * The port list can only ever say what is *already* running; a project whose
   * server is not up is a row with a Start on it. They are one list because they
   * answer one question, and a `ready` dev server is **joined** to its port row
   * rather than drawn beside it — see "one row per server, never two".
   *
   * ## What is deliberately not ported
   *
   * The phone's swipe actions. `.swipeActions` is a `List` affordance that exists
   * on iOS and nowhere in a browser, and hand-rolling a drag here would give a
   * gesture with no rubber band, no interaction with the back gesture at the left
   * edge, and a different depth from every other page the reader has open. What
   * carries across is the *behaviour* — every row has its actions — and in a
   * browser those live behind the `…` he asked for in the same breath: *"maybe
   * three dots and more options and stuff like that"*.
   *
   * ## There is no Stop, and it is not an oversight
   *
   * A dev server runs in an **ordinary session** — the desktop opens a shell in the
   * project folder and types the command into it — so stopping one is Ctrl-C in
   * that session, which is why the wire has no stop verb to send. What this screen
   * will not do is type the interrupt blindly from a button: the desktop decides a
   * folder is `ready` and only stops saying so when the *session* exits, which a
   * Ctrl-C into a shell does not do. The row would go on offering an address for a
   * server that had gone — the one thing `DevServerReport` says a client of that
   * frame must never display. So the action opens the session, with the interrupt
   * one key away on the key bar, and the honest fix is a stop verb on the desktop.
   */
  private localhostScreen(): HTMLElement {
    const screen = element('div', 'screen')
    // Edge to edge, like the session list it sits beside: the rows carry their
    // own gutters so a row highlights across the full width of the column.
    screen.style.padding = '0'
    const online = this.state.phase === 'online'
    const tunnels = localhostOffered(this.capabilities)

    // Which machine's ports these are, first — the same control the sessions and
    // the copilot carry, for the same reason, and drawn above the address bar
    // because *where this goes* is decided by the machine and not by the URL.
    const machines = this.machineSwitch()
    if (machines !== null) screen.append(machines)

    // The bar is the first thing after it, above the list and above Refresh,
    // because it is now what this screen is *for*. The list answers "what is
    // running"; the bar is how you get to it, and a way in that sits under nine
    // collapsed groups is a way in nobody finds.
    screen.append(this.browseBar())

    // Refresh exists only while there is a socket to carry it — the standing rule
    // against a control whose only function is to explain that it does not
    // function — so offline there is no row here at all rather than an empty one,
    // and the sentence under the list says how old it is instead.
    if (online && (tunnels || devserverOffered(this.capabilities))) {
      const heading = element('div', 'localhost__head')
      const refresh = element(
        'button',
        'button button--quiet localhost__refresh',
        this.localhost.listing ? 'Asking…' : 'Refresh',
      )
      refresh.type = 'button'
      refresh.disabled = this.localhost.listing
      refresh.addEventListener('click', () => {
        if (tunnels) this.localhostDo({ t: 'list' })
        // The projects are re-asked too. It is one Refresh over one screen, and a
        // button that refreshed half of what is under it would be the sort of
        // thing somebody presses twice and still does not trust.
        this.askDevServers()
      })
      heading.append(refresh)
      screen.append(heading)
    }

    const groups = this.localhostSections()
    if (groups.length === 0) {
      screen.append(element('p', 'empty', this.nothingServedSentence(online, tunnels)))
    } else {
      for (const section of groups) screen.append(this.sectionBlock(section, online, tunnels))
      // The rule nothing else on screen states — that naming a port is what moves
      // it up — because a folded group is otherwise a thing somebody has to
      // discover twice. It comes before the paragraph about serving because it is
      // about the list, and that one is about the whole feature.
      screen.append(element('p', 'note localhost__note', NAMING_FOOTNOTE))
    }

    const ports = this.localhost.ports
    if (!online && ports !== null && ports.length > 0) {
      screen.append(element('p', 'note localhost__note', stalePortsSentence(this.noun)))
    }

    /*
     * The screen's one footnote, and it is the last thing on purpose.
     *
     * There used to be two paragraphs here, both about what a browser tab cannot
     * do. They were true and they were the wrong quantity: an explanation of a
     * limitation, restated under every visit, on a screen whose complaint was
     * that it did nothing. Now that the bar opens pages, the only question left
     * unanswered is the one he actually asked — *"maybe we can give our domain
     * to them… just like ngrok"* — and `PUBLIC_ADDRESS_ANSWER` is the whole of
     * the answer to it, including the reason, because a limitation nobody can
     * see the shape of is one that gets re-proposed every month.
     *
     * Drawn whenever there is anything on this screen to have addresses at all,
     * and not conditioned on which capability the machine advertised: the
     * question is about the product, not about this machine's build.
     */
    if (groups.length > 0) screen.append(element('p', 'localhost__answer', PUBLIC_ADDRESS_ANSWER))
    return screen
  }

  /**
   * The browse bar: an address, where to open it, and Open.
   *
   * ## Why this exists at all
   *
   * > *"I still cannot open the localhost of any of them, so there is no reason
   * > to give the list here… Maybe we can have one browse bar here and something
   * > to browse it, or maybe another kind of link to open in our normal
   * > browser."*
   *
   * The list was never the problem — knowing what a machine in another country
   * is serving is most of why anybody opens this screen — but a list nothing
   * leads out of reads as decoration, and he is right that it had no reason. So
   * the bar is the reason, and the rows are now ways into it: pressing Open on a
   * row and typing that row's address into the bar are the same action carrying
   * the same URL, through the same `openControl`, answered in the same place.
   * They cannot drift, because there is only one of them.
   *
   * ## Two destinations, and both of them are real
   *
   * `browse.ts` owns which ones exist and why, and the short of it is that
   * neither is a guess. **On the machine** is `web.open` over the sealed channel
   * — the answer that works from a phone anywhere. **In this browser** is an
   * ordinary link, offered only where the client can say *why* the address
   * resolves from here: a direct pairing, or a page this browser was served over
   * loopback. On a phone on the hosted client it is simply not there, because
   * `localhost` on a phone is the phone.
   *
   * ## What it does when it can do nothing
   *
   * It says so, in a sentence, and draws no field. That is the rule this product
   * is judged on and it is worth the extra branch: a bar with a cursor in it that
   * cannot open anything is a worse answer than a line of text explaining that
   * this machine will not open pages.
   */
  private browseBar(): HTMLElement {
    const block = element('div', 'browse')
    const targets = this.browseTargets()
    const target = this.browseTarget()

    if (target === null) {
      // No field, no button, no chooser. There is nothing here that could act, so
      // there is nothing here.
      block.append(element('p', 'browse__none', NOWHERE_TO_OPEN))
      return block
    }

    const line = element('div', 'browse__line')

    const field = element('input')
    field.type = 'text'
    field.className = 'browse__field'
    field.value = this.browseText
    field.placeholder = 'localhost:3000'
    field.setAttribute('aria-label', 'Address to open')
    // A URL keyboard on a phone: no capitals, no autocorrect, and a visible `/`
    // and `.`. A field somebody types `localhost:3000` into and gets `Localhost`
    // back out of is a field they type into twice.
    field.setAttribute('inputmode', 'url')
    field.setAttribute('autocapitalize', 'off')
    field.setAttribute('autocorrect', 'off')
    field.spellcheck = false
    field.enterKeyHint = 'go'

    const go = this.openControl('Open', 'button browse__go', () => this.browseUrl())
    line.append(field)
    if (targets.length > 1) line.append(this.whereChooser(targets, target))
    line.append(go.node)

    field.addEventListener('input', () => {
      this.browseText = field.value
      // The control is refreshed in place rather than by redrawing the screen.
      // A redraw on every keystroke takes the focus and the caret with it, which
      // is the classic way an address bar becomes unusable on a phone.
      go.refresh()
    })
    field.addEventListener('keydown', (event) => {
      if (event.key !== 'Enter') return
      event.preventDefault()
      go.activate()
    })

    block.append(line)
    block.append(element('p', 'browse__note', destinationSentence(target, this.machineName)))

    /*
     * The answer, under the bar — unless the address belongs to a row on the
     * list, in which case `portRow` shows it under the row it is about, so that
     * three ports in nobody has to guess which one "it opened" means.
     *
     * There is no offline branch here on purpose. A spinner that outlives its
     * socket is cleared by `localhostStep`'s `offline` case, which is reached
     * from `onState` the moment the connection drops — and a render is not where
     * state gets fixed. A defensive mutation in here would re-enter this method
     * through `renderContent`, which is a loop that happens to terminate.
     */
    const outcome = this.localhost.openOutcome
    if (outcome !== null && this.rowUrls().indexOf(outcome.url) === -1) {
      block.append(
        element(
          'p',
          outcome.kind === 'opened' ? 'browse__result browse__result--ok' : 'browse__result',
          // Through `plain` like every other string that came off this socket: a
          // refusal is composed on the desktop, and this end is the one that pays
          // if that ever stops being true.
          plain(openSentence(outcome, this.noun)),
        ),
      )
    }
    return block
  }

  /**
   * The device chooser beside the bar, drawn only when there is a choice.
   *
   * > *"Maybe give a drop down next to somewhere here with the bar, to choose
   * > which device we are talking to right now."*
   *
   * A native `<select>` rather than a row of pills, and that is a phone
   * decision: a select opens the platform's own wheel or sheet, which is
   * reachable one-handed and is the control every reader already knows, where a
   * segmented strip of device names would be two 44px targets fighting the
   * address field for a 390px line.
   *
   * Never drawn for one option. That is the same rule the tab strip and the
   * folder picker follow — a control with one choice is not a choice — and the
   * sentence under the bar names the destination in that case instead.
   */
  private whereChooser(targets: readonly BrowseTarget[], current: BrowseTarget): HTMLElement {
    const select = element('select', 'browse__where')
    select.setAttribute('aria-label', 'Where to open it')
    for (const target of targets) {
      const option = element('option', undefined, target.label)
      option.value = target.where
      option.selected = target.where === current.where
      select.append(option)
    }
    select.addEventListener('change', () => {
      // Read back through the two constants rather than trusted as a string: a
      // `<select>`'s value is whatever is in the DOM, and this is the one place a
      // value from the document becomes a value the rest of the screen switches
      // on.
      this.browseWhere = select.value === BROWSE_HERE ? BROWSE_HERE : BROWSE_MACHINE
      // A full redraw here is right where it was wrong for the field: changing
      // the destination changes every row's Open as well as the bar's, since a
      // link in this browser and a frame to the machine are different elements.
      this.renderContent()
    })
    return select
  }

  /**
   * One Open control, as whichever element the destination actually needs.
   *
   * This is the part that could most easily have been faked. Opening **on the
   * machine** is a frame on a socket, so it is a `<button>`; opening **in this
   * browser** is a navigation, so it is an `<a href target="_blank">` — a real
   * link, which is exactly what he asked for (*"another kind of link to open in
   * our normal browser"*) and which a `window.open` from a click handler is not:
   * a link can be middle-clicked, copied, dragged to a bookmark bar and opened
   * in a background tab, and it survives a popup blocker that would have
   * swallowed the scripted call.
   *
   * `url()` is a thunk rather than a value because the bar's address changes as
   * somebody types and the control must follow it without the screen being
   * redrawn — see `refresh`, which is what the input listener calls.
   *
   * `className` is the whole class string rather than a modifier, because the two
   * places this is used want different bases: the bar's Open is a `.button`,
   * which is this client's full-width primary, and a row's Open is a `.port__open`
   * chip that sits inline beside Check. One base for both would put a 44px
   * full-width button inside every port row.
   *
   * A null URL is a control that cannot act, so it is disabled: `disabled` on
   * the button, and on the anchor the href is *removed*, which takes it out of
   * the tab order and stops the click, rather than left pointing at a string
   * that will not parse.
   */
  private openControl(
    label: string,
    className: string,
    url: () => string | null,
  ): { node: HTMLElement; refresh: () => void; activate: () => void } {
    const here = this.browseTarget()?.where === BROWSE_HERE
    const busy = this.localhost.opening

    if (here) {
      const link = element('a', className, label)
      link.target = '_blank'
      // `noreferrer` as well as `noopener`: the page being opened is somebody's
      // own dev server, and it has no business being told which client of this
      // app sent the reader to it.
      link.rel = 'noopener noreferrer'
      const refresh = (): void => {
        const address = url()
        if (address === null) {
          link.removeAttribute('href')
          link.setAttribute('aria-disabled', 'true')
          link.title = 'Type an address first'
          return
        }
        link.href = address
        link.removeAttribute('aria-disabled')
        link.title = `Open ${shortAddress(address)} in a new tab`
      }
      refresh()
      return { node: link, refresh, activate: () => link.click() }
    }

    const button = element('button', className, busy === null ? label : 'Opening…')
    button.type = 'button'
    const activate = (): void => {
      const address = url()
      if (address === null) return
      this.localhostDo({ t: 'open', url: address })
    }
    const refresh = (): void => {
      // Disabled while *any* open is in flight, not just this one's: the desktop
      // takes one at a time, so a live-looking button elsewhere on the screen is
      // a press that produces nothing.
      button.disabled = busy !== null || url() === null
    }
    refresh()
    button.addEventListener('click', activate)
    return { node: button, refresh, activate }
  }

  /** The address in the bar, resolved against the destination's own host. */
  private browseUrl(): string | null {
    const target = this.browseTarget()
    if (target === null) return null
    // `localhost` for the machine, because that is what the address means on its
    // side of the channel; the page's own host for a link in this browser, which
    // is the only host this browser has been shown to reach. See `browse.ts`.
    return parseAddress(this.browseText, target.host ?? 'localhost')
  }

  /** Every address the list can open, so the bar knows which answers are not its own. */
  private rowUrls(): string[] {
    const host = this.browseTarget()?.host ?? 'localhost'
    const urls: string[] = []
    for (const section of this.localhostSections()) {
      for (const row of section.rows) {
        if (row.port === null) continue
        const url = parseAddress(String(row.port), host)
        if (url !== null) urls.push(url)
      }
    }
    return urls
  }

  /** The destinations this browser has right now. See `browse.ts` for the rules. */
  private browseTargets(): BrowseTarget[] {
    return browseTargets({
      location: window.location,
      endpoint: this.endpoint,
      // Offline is not a destination. `web.open` needs the socket, and a bar that
      // stayed live over a dead connection is the lie this client exists to avoid.
      machineOpens: this.state.phase === 'online' && webOfferedHere(this.capabilities),
      machineLabel: this.machineName,
    })
  }

  /**
   * The destination in force, falling back when the chosen one is gone.
   *
   * One reader for `browseWhere`, so the fallback happens in one place: the set
   * of destinations changes underneath this screen — a socket drops and the
   * machine stops being one of them — and a chooser left pointing at a
   * destination that no longer exists is a bar that opens nothing and says
   * nothing about why.
   */
  private browseTarget(): BrowseTarget | null {
    const targets = this.browseTargets()
    const chosen = targets.find((target) => target.where === this.browseWhere)
    return chosen ?? targets[0] ?? null
  }

  /** What the machine is called on this screen: its nickname, or its kind. */
  private get machineName(): string {
    const machine = this.machine
    if (machine === null) return `the ${this.noun}`
    const label = machineLabel(machine, this.origin)
    // A nickname reads as a name; a relay slot id and a bare host do not, so the
    // fallback is the noun the rest of this screen already uses. "Opens on
    // `ABCDEF`, in its own browser" is a sentence nobody can act on.
    return machine.nickname !== null && machine.nickname !== '' ? label : `this ${this.noun}`
  }

  /**
   * The grouped rows, from the two halves this screen is made of.
   *
   * Both halves are gated on their own capability and neither assumes the other.
   * A desktop can advertise `localhost` without `devserver` or the other way round
   * — the public demo box deliberately withholds `localhost`, so a stranger is not
   * offered a byte pipe to its loopback — and the screen is whatever it actually
   * offers.
   *
   * The names are read here rather than inside the catalog, so that file stays a
   * pure function over values and never learns which machine it is describing.
   */
  private localhostSections(): LocalhostSection[] {
    const host = this.machine?.id ?? ''
    const ports = localhostOffered(this.capabilities) ? (this.localhost.ports ?? []) : []
    const devServers = devserverOffered(this.capabilities) ? this.dev.rows : []
    // A `ready` dev server's port is nameable too, even on a machine that does not
    // offer the port list at all: that address came off `dev.state`.
    const nameable = [
      ...ports.map((entry) => entry.port),
      ...devServers.map((row) => row.port).filter((port): port is number => port !== undefined),
    ]
    return portSections({
      ports,
      devServers,
      // Empty for a relay pairing, and that is correct rather than a gap: nothing
      // on this side knows which local port a relayed desktop bound. See
      // `directAppPorts`.
      appPorts: this.endpoint.kind === 'direct' ? directAppPorts(window.location) : [],
      names: this.portBook.namesFor(host, nameable),
    })
  }

  /**
   * Nothing to show, and which of the four reasons it is.
   *
   * A machine that does not offer the capability at all is a different fact from
   * one that offers it and is serving nothing, and both are different from a
   * socket that is down — saying "nothing is running" over a dead connection is a
   * claim nobody checked.
   */
  private nothingServedSentence(online: boolean, tunnels: boolean): string {
    if (tunnels && this.localhost.ports === null) {
      return this.localhost.listing
        ? `Asking the ${this.noun} what is listening…`
        : `The ${this.noun} has not said what it is serving yet.`
    }
    // One sentence for the round trip between arriving here and the first answer,
    // and nothing like it once the answer is "no project here has a dev script".
    if (!tunnels && devserverOffered(this.capabilities) && online && (this.folders?.length ?? 0) > 0) {
      return devWaitingSentence(this.noun)
    }
    return noPortsSentence(this.noun)
  }

  /**
   * One group, and its header, which is also the control that folds it.
   *
   * The whole header is the hit target rather than a chevron beside it, because a
   * 12px chevron is not a touch target and the row is already the shape of one.
   * The count is on it for the same reason the phone's is: a folded group has to
   * be worth opening before anybody opens it, and *"Other services · 9"* answers
   * that where *"Other services ›"* does not.
   */
  private sectionBlock(section: LocalhostSection, online: boolean, tunnels: boolean): HTMLElement {
    const host = this.machine?.id ?? ''
    const folded = this.portBook.isFolded(host, section.category)
    const group = element('section', 'portgroup')

    const head = element('button', 'portgroup__head')
    head.type = 'button'
    head.setAttribute('aria-expanded', folded ? 'false' : 'true')
    head.append(
      // One glyph, turned rather than swapped — see the stylesheet, where the two
      // spellings this used to have are written down along with what they did to
      // the header's baseline.
      element('span', folded ? 'portgroup__mark' : 'portgroup__mark portgroup__mark--open', '›'),
      element('span', 'portgroup__title', categoryTitle(section.category)),
      element('span', 'portgroup__count', String(section.rows.length)),
    )
    head.addEventListener('click', () => {
      this.portBook.setFolded(!folded, host, section.category)
      this.renderContent()
    })
    group.append(head)

    if (!folded) {
      const list = element('ul', 'ports')
      for (const row of section.rows) list.append(this.portRow(row, online, tunnels))
      group.append(list)
    }
    return group
  }

  /**
   * One row, whichever kind it is.
   *
   * The two kinds share a shell — the same list item, the same actions, the same
   * rename field — and differ only in the lines inside it. A second row type
   * saying the same things in a slightly different order is how two halves of one
   * screen end up disagreeing about what `failed` looks like.
   */
  private portRow(row: LocalhostRow, online: boolean, tunnels: boolean): HTMLElement {
    const item = element('li', 'port')
    const port = row.port
    // The address this row opens, against whichever host the current destination
    // resolves — `localhost` on the machine's own side, the page's own host for a
    // link in this browser. Null when there is no port to open or nowhere to open
    // it, and both of those mean the same thing here: no control.
    const target = this.browseTarget()
    const rowUrl =
      port === null || target === null ? null : parseAddress(String(port), target.host ?? 'localhost')

    /*
     * One line carries the row's identity **and** its controls, and that is the
     * shape rather than a saving.
     *
     * The first version put the controls on a line of their own, on the reasoning
     * that a 390px phone cannot hold a label, a Check and a menu at once. Rendered,
     * it was wrong twice over: a port row became 215 points tall, so five of them
     * filled a phone, and at 1440px the menu was stranded a thousand pixels from
     * the row it belongs to. A flexible label between them is what actually solves
     * both — it eats the space on a monitor and gives it up on a phone.
     */
    const line = element('div', 'port__line')
    if (row.dev !== null) this.devHeadInto(line, row)
    else {
      // Mono while the port number is the identity, and the interface face once a
      // name has replaced it. Monospace is a promise that the characters are exact
      // and countable, which is true of `localhost:3000` and not of "client
      // billing app".
      const named = row.name !== null
      line.append(element('span', named ? 'port__label port__label--named' : 'port__label', portRowTitle(row)))
    }

    /*
     * Open it — wherever the bar above says pages open.
     *
     * His complaint, in full: *"I still cannot open the localhost of any of them,
     * so there is no reason to give the list here."* A browser tab cannot serve a
     * tunnel and the three reasons are at the top of `localhost.ts`; what it can
     * do is send the address somewhere that can. This control is `openControl`,
     * the same one the bar uses, so a row and the bar are one action with one
     * answer rather than two features that agree until one of them is changed —
     * and so a row is a link in this browser exactly when the bar is.
     *
     * Before Check, because it is what most people came here to press. Absent
     * entirely when there is nowhere to send it, which is the same rule the bar
     * follows: no destination, no control, and one sentence at the top saying so.
     */
    if (rowUrl !== null) {
      const open = this.openControl('Open', 'port__open', () => rowUrl)
      line.append(open.node)
    }

    // One check at a time, and only with a socket. A second Check pressed while
    // one is running is refused by the machine itself; disabling it is what stops
    // somebody pressing a button that does nothing.
    if (online && tunnels && port !== null) {
      const checking = this.localhost.checking
      const here = checking?.port === port
      const check = element('button', 'port__check', here ? 'Checking…' : 'Check')
      check.type = 'button'
      check.disabled = checking !== null
      check.addEventListener('click', () => {
        this.checks += 1
        this.localhostDo({ t: 'check', port, id: `localhost-${this.checks}` })
      })
      line.append(check)
    }
    if (port !== null) {
      const open = this.openRow === row.id
      const more = element('button', 'port__more', '···')
      more.type = 'button'
      more.setAttribute('aria-expanded', open ? 'true' : 'false')
      more.setAttribute('aria-label', `Actions for ${portRowTitle(row)}`)
      more.addEventListener('click', () => {
        this.openRow = open ? null : row.id
        this.renamingPort = null
        this.renderContent()
      })
      line.append(more)
    }
    item.append(line)

    if (row.dev !== null) this.devLinesInto(item, row)
    else {
      const detail = portRowDetail(row)
      if (detail !== null) item.append(element('p', 'port__detail', detail))
    }

    // The row's own verb, on a line of its own — unlike Check and the menu, which
    // are the same two controls on every row. A Start belongs under the project it
    // will start, at the width its label needs.
    const action = this.rowAction(row)
    if (action !== null) {
      const actions = element('div', 'port__controls')
      actions.append(action)
      item.append(actions)
    }

    if (this.renamingPort !== null && this.renamingPort === port) {
      item.append(
        this.renameField(this.renameText, `localhost:${port} on this ${this.noun}`, MAX_NAME_LENGTH, (value) => {
          this.portBook.setName(value, this.machine?.id ?? '', port)
          this.renamingPort = null
          this.openRow = null
          this.renderContent()
        }),
      )
    } else if (this.openRow === row.id && port !== null) {
      item.append(this.portMenu(row, port))
    }

    // The answer sits under the port it is about. A single result line at the foot
    // of the list would be correct and unreadable: three ports in, nobody can tell
    // which one "it answered" is about.
    const outcome = this.localhost.outcome
    if (outcome !== null && outcome.port === port) {
      item.append(
        element(
          'p',
          outcome.kind === 'answered' ? 'port__result port__result--ok' : 'port__result',
          // Through `plain` like every other string that came off this socket: a
          // refusal is composed on the desktop, and this end is the one that pays
          // if that ever stops being true.
          plain(checkSentence(outcome, this.noun)),
        ),
      )
    }

    // The open's answer, under the same row and beside the check's. Two lines
    // rather than one shared one: a check proved a port answers and an open put a
    // page on somebody's screen, and a row that had done both would otherwise
    // show only whichever finished last.
    //
    // Matched on the **address** rather than on the port, because the bar and the
    // rows now share one open and one answer: an address typed by hand that
    // happens to be a row's own is that row's answer, and one that is not lands
    // under the bar instead.
    const openOutcome = this.localhost.openOutcome
    if (openOutcome !== null && rowUrl !== null && openOutcome.url === rowUrl) {
      item.append(
        element(
          'p',
          openOutcome.kind === 'opened' ? 'port__result port__result--ok' : 'port__result',
          plain(openSentence(openOutcome, this.noun)),
        ),
      )
    }
    return item
  }

  /**
   * The identity of a dev-server row: its state, its name, and the project it is.
   *
   * When the person has named the row's port, their name leads and the project's
   * own name becomes a chip beside it. Replacing one with the other would lose the
   * fact that this row is a project at all.
   */
  private devHeadInto(line: HTMLElement, row: LocalhostRow): void {
    const report = row.dev
    if (report === null) return
    const view = this.devView(report)
    line.append(
      element('span', `dev__dot dev__dot--${view.tone}`),
      element('span', 'dev__name', row.name ?? view.name),
    )
    if (row.name !== null) line.append(element('span', 'dev__project', view.name))
  }

  /**
   * The lines under a dev-server row, in whichever of its five states it is in.
   *
   * Every word is `devRowView`'s and every rule with it; this is delivery. Two of
   * those rules are worth naming where somebody editing the DOM will see them: the
   * rows are whatever the reducer holds, never assembled from `folders` — a folder
   * with no dev script has no row — and `note` is process output, drawn as text
   * through `plain` and never parsed.
   */
  private devLinesInto(item: HTMLElement, row: LocalhostRow): void {
    const report = row.dev
    if (report === null) return
    const view = this.devView(report)
    // The whole path, reachable from a row that shows only the project's name. The
    // same escape hatch the folder picker uses, for the same reason: two checkouts
    // can share a last segment.
    item.title = view.folder
    item.append(element('p', view.exact ? 'dev__line dev__line--exact' : 'dev__line', plain(view.line)))
    if (view.note !== null) item.append(element('p', 'dev__note', plain(view.note)))
    if (view.address !== null) item.append(element('p', 'dev__address', plain(view.address)))
  }

  /** One row's view, asked for by both halves of the row that draws it. */
  private devView(report: DevServerReport): ReturnType<typeof devRowView> {
    return devRowView(report, {
      online: this.state.phase === 'online',
      starting: this.dev.starting === report.folder,
    })
  }

  /**
   * The row's own verb, or nothing.
   *
   * Which one it is lives in `port-catalog.ts`, so the answer to "what does start
   * do in each of the five states" is a value a unit test can read rather than a
   * branch inside a render that only a paired browser with a project on the far
   * machine could exercise. `copyAddress` is the one case that is not a button
   * here — it is in the `…` menu, because a Copy on every row would be the loudest
   * thing on a screen whose whole complaint was noise.
   */
  private rowAction(row: LocalhostRow): HTMLElement | null {
    const action = secondAction(row)
    if (action.kind === 'none' || action.kind === 'copyAddress') return null
    if (this.state.phase !== 'online') return null
    if (action.kind === 'openSession') {
      // Labelled for what it does. It is also how a dev server is stopped — Ctrl-C
      // is on the key bar in there — and calling the button "Stop" would be naming
      // it after the thing the *next* tap does. See this screen's header.
      const open = element('button', 'button button--quiet port__action', 'Open session')
      open.type = 'button'
      open.addEventListener('click', () => this.openSession(action.id))
      return open
    }
    // Not a Start drawn as though nothing had happened, when it is a retry:
    // `dev.start` re-reads the folder, so a `package.json` fixed since the failure
    // is picked up rather than the old answer being replayed.
    const folder = action.folder
    const start = element('button', 'button port__action', action.kind === 'retry' ? 'Try again' : 'Start')
    start.type = 'button'
    // Disabled while *any* start is in flight, not just this row's: the desktop
    // allows one at a time and refuses the second with a sentence, so a live-looking
    // button on the row below is a press that produces an error message rather than
    // a dev server.
    start.disabled = this.dev.starting !== null
    start.addEventListener('click', () => this.devDo({ t: 'start', folder }))
    return start
  }

  /**
   * The three dots he asked for, opened in place.
   *
   * *"maybe three dots and more options and stuff like that"*. A popover would be
   * the desktop's answer; in a page that is a fixed frame with one scrolling region
   * inside it, an absolutely-positioned menu has to be dismissed, repositioned on
   * a resize and kept inside the viewport — three problems, none of which is the
   * feature. Opening in the row costs one row of height and cannot be misplaced.
   */
  private portMenu(row: LocalhostRow, port: number): HTMLElement {
    const menu = element('div', 'port__menu')
    const named = row.name !== null

    const rename = element('button', 'port__menu-item', named ? 'Rename' : 'Name this port')
    rename.type = 'button'
    rename.addEventListener('click', () => {
      this.renamingPort = port
      this.renameText = row.name ?? ''
      this.renderContent()
    })
    menu.append(rename)

    if (named) {
      // Not "delete": nothing on the machine changes and the port stays in the
      // list. It goes back to being called by the process holding it.
      const clear = element('button', 'port__menu-item', 'Clear name')
      clear.type = 'button'
      clear.addEventListener('click', () => {
        this.portBook.setName(null, this.machine?.id ?? '', port)
        this.openRow = null
        this.renderContent()
      })
      menu.append(clear)
    }

    const copy = element('button', 'port__menu-item', 'Copy address')
    copy.type = 'button'
    copy.addEventListener('click', () => {
      this.openRow = null
      void this.copyAddress(port)
    })
    menu.append(copy)
    return menu
  }

  /**
   * `http://localhost:<port>`, on the clipboard, and said out loud.
   *
   * The address is the *machine's* loopback and not this reader's, which is the
   * whole point of the footnote at the bottom of this screen — so what this is for
   * is pasting into a terminal on that machine, or into a message to somebody
   * sitting at it.
   *
   * A clipboard write can be refused: the API needs a secure context and, in some
   * browsers, a permission. A refusal is said rather than swallowed, because a
   * silent copy that did not happen is indistinguishable from one that did.
   */
  private async copyAddress(port: number): Promise<void> {
    const address = `http://localhost:${port}`
    try {
      await navigator.clipboard.writeText(address)
      this.say(`Copied ${address}`)
    } catch {
      this.say(`This browser would not let the page copy ${address}.`)
    }
    this.renderContent()
  }

  /**
   * What this browser is holding and for how long, plus the one press that
   * changes it.
   *
   * The question on the pair screen is answered once, in a hurry, by somebody
   * who is mid-task and standing at a second computer. Leaving it there would
   * make it a decision with no way back: a person who ticked "remember" on a
   * machine they later realised was not theirs would have to unpair and repair,
   * from the desktop, to undo it — and someone who chose "just for this visit"
   * on their own laptop would re-pair every morning without ever finding out
   * why.
   *
   * So it is stated in the sentence that says what it means rather than the name
   * of a setting, and the button is the *action* rather than a toggle: nobody has
   * to work out which way a switch is pointing. Nothing here is a second copy of
   * the state — both halves read `remember`, which is what `loadMachines` found in
   * whichever store answered.
   *
   * It used to sit at the foot of the session list, and it is on the Settings
   * screen now. Same block, same words, one screen over: this is a fact about the
   * browser rather than about the sessions, and a list of somebody's running work
   * is not where a storage decision belongs.
   */
  private lifetimeBlock(): HTMLElement | null {
    if (this.credential === null) return null
    const days = Math.round(REMEMBERED_TTL_MS / 86_400_000)
    const remembered = this.remember === 'this-browser'

    const block = element('section', 'lifetime')
    block.append(
      element(
        'p',
        'lifetime__note',
        remembered
          ? `This browser stays paired until you unpair it, or ${days} days pass without using it.`
          : 'This pairing ends when you close this tab. Nothing is left on this computer.',
      ),
    )

    const change = element(
      'button',
      'button button--quiet',
      remembered ? 'Stop remembering this browser' : 'Remember this browser',
    )
    change.type = 'button'
    change.addEventListener('click', () => {
      this.remember = remembered ? 'this-tab' : 'this-browser'
      // Moves the machines, the mirrored credential *and* this browser's key into
      // the other store and clears the one they came from. The port names go with
      // them: they are the person's own text about a machine, and leaving them in
      // a profile on a computer whose owner has just said "just for this visit" is
      // exactly the residue that answer promises there will not be.
      this.keep()
      this.portBook.setLifetime(this.remember)
      this.renderContent()
    })
    block.append(change)
    return block
  }

  /* ------------------------------------------------------------ settings -- */

  /**
   * The things that belong to this browser rather than to a machine.
   *
   * Three groups and two sentences. Asad on the desktop's settings page: *"we
   * don't need this much of big descriptions under each. The whole page is going
   * to be used just because of the big descriptions."* So each row is a line, and
   * the only prose is the two paragraphs that say something no row can — what
   * changing the text size does to a session that is already open, and the one
   * thing this client genuinely cannot do.
   *
   * ## What is here, and what is deliberately not
   *
   * The phone's Settings has Machines, GitHub, Alerts, Text size and About. Two of
   * those are missing here and neither is an omission:
   *
   *  - **GitHub.** This client refuses a machine's request for a git credential
   *    and says so on a card of its own — see `credential.ts`, which explains at
   *    length why a browser served by the machine that would be asking is the one
   *    place that would be dishonest. A row that opened a sign-in this client will
   *    not complete is the definition of a fake feature.
   *  - **Alerts.** There is no notification path in this client at all, and the
   *    closing paragraph says so rather than a switch pretending otherwise.
   *
   * The appearance is not here either, and that one is a placement rather than an
   * absence: it is in the header, on every screen including the pair screen,
   * because it is the one preference somebody changes *because of what is on the
   * screen right now*. A second copy of it here would be two controls for one
   * setting.
   */
  private settingsScreen(): HTMLElement {
    const screen = element('div', 'screen')
    const paired = this.book.machines.length

    const machines = element('div', 'group')
    const row = element('button', 'setting')
    row.type = 'button'
    row.append(
      element('span', 'setting__title', 'Machines'),
      element('span', 'setting__value', paired === 1 ? '1 paired' : `${paired} paired`),
      element('span', 'setting__mark', '›'),
    )
    row.addEventListener('click', () => this.goTo('machines'))
    machines.append(row)
    screen.append(machines)

    // Devices, but only over a host that advertised the roster — which it does
    // only to one of the owner's own devices. A guest never sees this row,
    // because a guest could not open the screen behind it: the same capability
    // gates the advertisement and the serving.
    if (devicesOffered(this.capabilities)) {
      const devices = element('div', 'group')
      const devicesRow = element('button', 'setting')
      devicesRow.type = 'button'
      const count = this.deviceRoster.length
      devicesRow.append(
        element('span', 'setting__title', 'Devices'),
        element('span', 'setting__value', count === 0 ? 'signed in here' : count === 1 ? '1 signed in' : `${count} signed in`),
        element('span', 'setting__mark', '›'),
      )
      devicesRow.addEventListener('click', () => this.goTo('devices'))
      devices.append(devicesRow)
      screen.append(devices)
    }
    // The two settings this machine owns, over the `settings` capability. Drawn
    // only when the host advertised it (an owner's own device, a host new enough
    // to serve it); a guest or an older desktop gets nothing here rather than a
    // section explaining what it is missing. `ensureRead` asks once per
    // connection; the `settings.changed` push keeps it fresh without a poll.
    if (this.serverSettings.offered()) {
      this.serverSettings.ensureRead()
      screen.append(this.serverSettings.element)
    }

    screen.append(element('p', 'caption', 'Terminal'))
    screen.append(this.textSizeGroup())
    screen.append(
      element(
        'p',
        'note note--plain',
        'A session already open picks this up straight away — the column count is the font, so changing ' +
          `it resizes the session on the ${this.noun}.`,
      ),
    )

    // The machine at the other end, when it said what build it is. A host older
    // than the `appVersion` field, or one this page has not reached, reports
    // nothing and gets no group rather than a row with a blank in it.
    if (this.hostAppVersion !== '') {
      screen.append(element('p', 'caption', 'This server'))
      screen.append(this.serverGroup())
    }

    screen.append(element('p', 'caption', 'This browser'))
    const lifetime = this.lifetimeBlock()
    if (lifetime !== null) screen.append(lifetime)

    screen.append(element('p', 'caption', 'About'))
    screen.append(this.aboutGroup())

    screen.append(
      element(
        'p',
        'note note--plain',
        `This page talks to your own machines. There is no notification server in ${BRAND.name} and there ` +
          'is nowhere for one to send anything — a browser tab that is closed is not running, so a session ' +
          'that needs you is found when you come back rather than announced while you are away.',
      ),
    )
    return screen
  }

  /**
   * Which build the machine at the other end is running, and whether it is a
   * desktop or a headless server.
   *
   * The mirror of {@link aboutGroup} pointed the other way: that row is a fact
   * about this page, this one is a fact about the machine answering it, and until
   * `welcome` grew an `appVersion` there was no honest way to draw it — a browser
   * cannot look at a file the way somebody can look at a downloaded desktop, and
   * before the field it could not ask either. `version.ts` predicted this row in
   * as many words: *"If a `welcome` frame ever grows an app version, that is a
   * second line here and a deliberate one."*
   *
   * Static, and mono where the number is, for the reasons {@link aboutGroup}
   * gives: there is nothing to press. A host is replaced from a desktop or over
   * SSH, never from here, and this protocol carries no update verb to put under a
   * button. The one thing this client says about the gap is the sentence below,
   * and only when it is genuinely true — this page's build strictly ahead of the
   * server's, decided by {@link clientIsAhead}, which stays silent on any pair of
   * numbers it cannot compare rather than nudging on a guess.
   */
  private serverGroup(): HTMLElement {
    const group = element('div', 'group')
    const row = element('div', 'setting setting--static')
    row.append(element('span', 'setting__title', this.machineName))
    const noun = hostKindNoun(this.hostKind)
    const value = noun === null ? this.hostAppVersion : `${this.hostAppVersion} · ${noun}`
    // Mono on the number, like the client's own version and the machine
    // addresses: a value to read character by character and compare, not prose.
    row.append(element('span', 'setting__value setting__value--mono', value))
    group.append(row)

    // The one sentence the pair of versions earns, and only when this page is
    // strictly ahead. Not a button: there is no update verb on this wire, and
    // there is not meant to be — the plane a host is replaced on is a desktop
    // app or an SSH session, not a phone. A sentence says what to do; a button
    // that did nothing would be the fake feature this whole client refuses.
    if (clientIsAhead(VERSION, this.hostAppVersion)) {
      group.append(
        element(
          'p',
          'note note--plain',
          `This page is on ${VERSION} and this server is on ${this.hostAppVersion}. ` +
            'Update this server from a desktop — there is no button here for it, and there is not ' +
            'meant to be: a server is replaced from a desktop app or over SSH, never from a phone.',
        ),
      )
    }
    return group
  }

  /**
   * Which build of this client is on screen.
   *
   * The phone's Settings ends with the same group, for a reason that applies
   * twice as hard here: a browser is the one client nobody can look at a file
   * for. It updates itself while you are not watching, it can be installed to a
   * home screen, and it serves its own shell out of a service-worker cache —
   * which is the classic way a web app ships an update nobody receives.
   * `vite.config.ts` stamps that cache with a content hash *precisely* because
   * that failure is expected, and when it happens the first question anybody
   * asks is which build you are on. Until this row there was no answer anywhere
   * in the client.
   *
   * One row, two facts, and nothing that pretends to be more — see `version.ts`
   * for what this number is and, more importantly, the two things it is not. It
   * is a fact about the page, never about the machine at the other end. The
   * machine's own build is a different row — the "This server" group above,
   * added once `welcome` grew an `appVersion` exactly as `version.ts` predicted —
   * and the two are kept apart on purpose: this one updates when the page
   * reloads, that one when somebody replaces the host from a desktop.
   *
   * Static, with no chevron. There is nowhere to go: an update arrives by
   * reloading, which is a thing browsers already have a button for, and a row
   * that looked pressable and did nothing would be worse than a row that plainly
   * reports.
   */
  private aboutGroup(): HTMLElement {
    const group = element('div', 'group')
    const row = element('div', 'setting setting--static')
    row.append(element('span', 'setting__title', BRAND.name))
    // Mono, like the machine addresses on the Machines screen and the port
    // numbers on Localhost: this is a value to be read character by character
    // and compared against another one somebody has been told, not prose.
    row.append(element('span', 'setting__value setting__value--mono', VERSION))
    group.append(row)
    return group
  }

  /**
   * How big the terminal's characters are.
   *
   * The same setting the phone puts in its Settings, for the same two reasons: it
   * is a property of the person's eyes rather than of one session, and a control
   * you can only reach from inside a session is one that somebody with a
   * nine-pixel terminal cannot read well enough to find.
   *
   * Two buttons and the value, rather than a slider: the range is thirteen whole
   * pixels, every one of them is a distinct answer, and a slider on a phone is a
   * control you cannot land on a specific one of thirteen values with.
   */
  private textSizeGroup(): HTMLElement {
    const group = element('div', 'group')
    const row = element('div', 'setting setting--static')
    row.append(element('span', 'setting__title', 'Text size'))
    row.append(element('span', 'setting__value', textSizeLabel(this.textSize)))

    const stepper = element('span', 'setting__stepper')
    const smaller = element('button', 'setting__step', '−')
    smaller.type = 'button'
    smaller.setAttribute('aria-label', 'Smaller text')
    smaller.disabled = !canGoSmaller(this.textSize)
    smaller.addEventListener('click', () => this.chooseTextSize(smallerText(this.textSize)))

    const larger = element('button', 'setting__step', '+')
    larger.type = 'button'
    larger.setAttribute('aria-label', 'Larger text')
    larger.disabled = !canGoLarger(this.textSize)
    larger.addEventListener('click', () => this.chooseTextSize(largerText(this.textSize)))

    stepper.append(smaller, larger)
    row.append(stepper)
    group.append(row)
    return group
  }

  /**
   * The person moved the size.
   *
   * The emulator is told, and then measured. A font change without a `fit` leaves
   * xterm holding the column count it computed for the old face, which is a
   * terminal drawing eighty columns into a box that now fits sixty — and the
   * machine still sending eighty. The resize frame that follows is what makes the
   * far end agree, and `terminal.ts` clamps it so a size the protocol would refuse
   * cannot close the socket.
   */
  private chooseTextSize(size: number): void {
    if (size === this.textSize) return
    this.textSize = size
    writeTextSize(this.stores.browser, size)
    this.terminal?.setFontSize(size)
    this.terminal?.fit()
    this.renderContent()
  }

  /* ------------------------------------------------------------ machines -- */

  /**
   * Every machine this browser is paired with, on a screen instead of nowhere.
   *
   * Asad on the desktop's equivalent: *"I am not able to edit the name of this
   * account and I don't know where it belongs to… I should be able to edit the
   * account, delete and add."* Same three verbs, here, in one place — and the
   * screen answers the second complaint on every row, because the line under the
   * name is the endpoint and says who can read the session.
   *
   * ## Why only one row has a connection on it
   *
   * The phone holds a socket to every paired machine from launch, because it
   * delivers alerts and a machine nobody is looking at is still a machine that
   * might need you. This client has no notifications and cannot have any, so a
   * second socket would buy nothing and cost a real thing — see the header of
   * `machines.ts`. What the other rows say instead is when this browser last got
   * through, which is a fact rather than a guess: the credential's window is
   * pushed out by `renewed()` on every `welcome`, and a `welcome` is the only frame
   * that proves this browser reached the machine at all.
   */
  private machinesScreen(): HTMLElement {
    const screen = element('div', 'screen')
    const now = Date.now()

    const list = element('ul', 'machines')
    // The same labels the switcher chips get, so the two screens cannot disagree
    // about what a machine is called.
    const labels = machineLabels(this.book.machines, this.origin)
    for (const [at, machine] of this.book.machines.entries()) {
      list.append(this.machineRow(machine, now, labels[at] ?? machineLabel(machine, this.origin)))
    }
    screen.append(list)

    const add = element('button', 'button button--quiet machines__add', 'Pair another machine')
    add.type = 'button'
    add.addEventListener('click', () => {
      this.pairingAnother = true
      this.screen = 'pair'
      this.render()
    })
    screen.append(add)

    // The second way a machine joins this list, beside the first and drawn the
    // same: a server with no screen cannot show a code, and signing in to one is
    // not a lesser route to the same place — it is the only route to that kind of
    // machine. See `addServerScreen`.
    const signIn = element('button', 'button button--quiet machines__add', 'Sign in to a server')
    signIn.type = 'button'
    signIn.addEventListener('click', () => this.openAddServer('machines'))
    screen.append(signIn)

    screen.append(element('p', 'note note--plain', MACHINES_FOOTNOTE))
    return screen
  }

  /**
   * One machine.
   *
   * The name leads because it is what somebody is looking for. The endpoint under
   * it is mono and dimmed because it is data — and here it is also the answer to
   * *"I don't know where it belongs to"*. The status line is a sentence about the
   * row rather than the row itself, so it is quieter than both.
   *
   * Pressing the row switches to that machine; the `···` beside it renames or
   * forgets it. The two are separated because one of them is a thing people do
   * twenty times a day and the other is a thing they do once and regret.
   */
  private machineRow(machine: StoredMachine, now: number, label: string): HTMLElement {
    const item = element('li', 'machine')
    const current = machine.id === this.book.currentId

    const line = element('div', 'machine__line')
    const choose = element('button', 'machine__choose')
    choose.type = 'button'
    choose.append(
      element('span', current ? 'machine__dot machine__dot--here' : 'machine__dot'),
      element('span', 'machine__name', label),
    )
    choose.addEventListener('click', () => {
      if (current) return
      this.switchTo(machine.id)
    })
    line.append(choose)

    const open = this.openRow === machine.id
    const more = element('button', 'port__more', '···')
    more.type = 'button'
    more.setAttribute('aria-expanded', open ? 'true' : 'false')
    more.setAttribute('aria-label', `Actions for ${label}`)
    more.addEventListener('click', () => {
      this.openRow = open ? null : machine.id
      this.renamingMachine = null
      this.renderContent()
    })
    line.append(more)
    item.append(line)

    // Two lines, wrapped, rather than one truncated. The summary is a host id, a
    // relay and how it is protected; cut at either end it loses one of the three,
    // and this is a screen with room — unlike the header, where the same machine
    // is named by its first six characters.
    item.append(element('p', 'machine__where', endpointSummary(machine, this.origin)))
    item.append(element('p', 'machine__state', this.machineState(machine, current, now)))

    if (this.renamingMachine === machine.id) {
      item.append(
        this.renameField(this.renameText, endpointSummary(machine, this.origin), MAX_NICKNAME_LENGTH, (value) => {
          this.book = renameMachine(this.book, machine.id, cleanNickname(value))
          this.renamingMachine = null
          this.openRow = null
          this.keep()
          this.render()
        }),
      )
    } else if (open) {
      const menu = element('div', 'port__menu')
      const rename = element('button', 'port__menu-item', machine.nickname === null ? 'Name this machine' : 'Rename')
      rename.type = 'button'
      rename.addEventListener('click', () => {
        this.renamingMachine = machine.id
        this.renameText = machine.nickname ?? ''
        this.renderContent()
      })
      menu.append(rename)

      // Named, because this menu is opened on a row and a browser paired with
      // three machines is three identical menus.
      const forget = element('button', 'port__menu-item port__menu-item--warn', `Forget ${label}`)
      forget.type = 'button'
      forget.addEventListener('click', () => {
        this.openRow = null
        this.forgetMachine(machine.id)
      })
      menu.append(forget)
      item.append(menu)
    }
    return item
  }

  /**
   * What the row says the machine is doing.
   *
   * Sessions while it is up, because that is the number worth switching for; the
   * connection's own sentence when it is not, because then the session count is
   * history. For a machine this browser is not talking to there is no connection
   * to describe at all, and the honest answer is when it was last reached — never
   * a dot, and never a count from the last time somebody looked.
   */
  private machineState(machine: StoredMachine, current: boolean, now: number): string {
    if (!current) return lastReachedSentence(machine, now)
    if (this.state.phase !== 'online') return this.state.detail
    /*
     * `=== null`, not `=== undefined`.
     *
     * `RemoteSession.exitCode` is `number | null` and `parseSession` writes the
     * field on every row — null while it runs, a number once it has stopped — so
     * the `undefined` test matched nothing and this row said "nothing running"
     * over a machine with two live sessions on it. It is the shape of defect this
     * pass is about: not a feature that is missing, a fact on screen that is
     * false, with nothing to hint at it.
     */
    const running = this.sessions.filter((session) => session.exitCode === null).length
    if (running === 0) return 'nothing running'
    return running === 1 ? '1 session' : `${running} sessions`
  }

  /* ------------------------------------------------------------- devices -- */

  /**
   * Ask the host for the roster.
   *
   * A fresh `rid` each time, remembered so the answer is matched to this ask and
   * a late one to a screen already left falls on the floor — the same routing
   * the chat read uses. Nothing is sent when there is no socket; the screen
   * shows whatever it last held and says it is reconnecting.
   */
  private askDevices(): void {
    const rid = `dev-${(this.devicesRid += 1)}`
    if (this.connection?.send({ t: 'devices.list', rid }) !== true) return
    this.devicesAsked.add(rid)
  }

  /**
   * Remove one device — the second press of the two-step.
   *
   * Removing this device is sign-out: the host drops this very socket, so no
   * answer comes back and the connection simply ends, which the state machine
   * already turns into the disconnected screen. For any other device the
   * `devices.revoked` answer redraws the list. The confirm is cleared on the
   * answer, or here if the socket is gone.
   */
  private sendRevoke(deviceId: string): void {
    const rid = `dev-${(this.devicesRid += 1)}`
    if (this.connection?.send({ t: 'devices.revoke', rid, device: deviceId }) !== true) {
      this.removing = null
      this.renderContent()
      return
    }
    this.devicesAsked.add(rid)
  }

  /**
   * Every device signed in on the host, with the one act this screen has: Remove.
   *
   * There is no approve here, by design — approving is a thing done at the
   * trusted surface — so a pending device shows as waiting and Remove doubles as
   * deny. The row for this very device is marked and its Remove reads "Sign out",
   * because removing yourself is exactly that.
   */
  private devicesScreen(): HTMLElement {
    const screen = element('div', 'screen')
    const now = Date.now()
    const mineId = this.credential?.deviceId ?? null

    if (this.deviceRoster.length === 0) {
      const note =
        this.state.phase === 'online'
          ? 'No devices are signed in here yet.'
          : `Reconnecting to the ${this.noun} to show what is signed in…`
      screen.append(element('p', 'note note--plain', note))
      return screen
    }

    const list = element('ul', 'devices')
    for (const row of this.deviceRoster) list.append(this.deviceRow(row, now, mineId))
    screen.append(list)

    screen.append(
      element(
        'p',
        'note note--plain',
        'Removing a device revokes it and drops it now. To change what a device is — your own or a ' +
          'guest — remove it and pair it again; there is no other way, on purpose.',
      ),
    )
    return screen
  }

  /**
   * One device.
   *
   * The name leads, with a live dot when it has a socket open and a "This device"
   * tag when it is the one you are holding. Under it: what it is (or that it is
   * waiting), when it was last here, and the fingerprint to check against the one
   * it shows. Remove is two steps for the reason the session Close is — a thing
   * done once and regretted — and here the stakes are highest on your own row,
   * which is why that one says "Sign out".
   */
  private deviceRow(row: DeviceRosterRow, now: number, mineId: string | null): HTMLElement {
    const item = element('li', 'device')
    const isThis = mineId !== null && row.id === mineId

    const line = element('div', 'device__line')
    if (row.connected) line.append(element('span', 'device__dot device__dot--live'))
    else line.append(element('span', 'device__dot'))
    line.append(element('span', 'device__name', plain(row.name)))
    if (isThis) line.append(element('span', 'device__tag', 'This device'))
    item.append(line)

    item.append(element('p', 'device__standing', deviceStanding(row)))
    item.append(element('p', 'device__state', lastSeenSentence(row, now)))
    item.append(element('p', 'device__print', fingerprintText(row)))

    if (this.removing === row.id) {
      const actions = element('div', 'device__actions')
      const confirm = element(
        'button',
        'button button--danger device__confirm',
        isThis ? 'Sign this device out' : 'Remove',
      )
      confirm.type = 'button'
      confirm.disabled = this.state.phase !== 'online'
      confirm.addEventListener('click', () => this.sendRevoke(row.id))
      const cancel = element('button', 'button button--quiet device__cancel', 'Cancel')
      cancel.type = 'button'
      cancel.addEventListener('click', () => {
        this.removing = null
        this.renderContent()
      })
      actions.append(confirm, cancel)
      item.append(actions)
    } else {
      const remove = element('button', 'button button--quiet device__remove', isThis ? 'Sign out' : 'Remove')
      remove.type = 'button'
      // Offline, there is no socket to carry the revoke, so the control is drawn
      // back rather than allowed to fail — the same rule the rest of this app
      // follows about a button that would only refuse.
      remove.disabled = this.state.phase !== 'online'
      remove.addEventListener('click', () => {
        this.removing = row.id
        this.renderContent()
      })
      item.append(remove)
    }
    return item
  }

  /* --------------------------------------------------------------- bits -- */

  /**
   * The one field this client has besides the pairing code.
   *
   * Written once and used by both renames, because the two are the same
   * interaction — a name, the thing it is about underneath it, Save and Cancel —
   * and a second copy is how one of them ends up without an Enter handler.
   *
   * `maxLength` is set from the store's own bound rather than left to the cleaner
   * afterwards, so the field cannot show more than will be kept. Saving with the
   * field emptied is how a name is removed; `cleanLabel` folds empty and
   * whitespace onto nothing, which is why there is no separate Clear here.
   */
  private renameField(
    value: string,
    about: string,
    maximum: number,
    save: (value: string) => void,
  ): HTMLElement {
    const block = element('div', 'rename')
    block.append(element('p', 'rename__about', about))

    const field = element('input')
    field.type = 'text'
    field.className = 'rename__field'
    field.value = value
    field.maxLength = maximum
    field.placeholder = 'A name you will recognise'
    field.setAttribute('aria-label', 'Name')
    field.addEventListener('input', () => {
      // Held here rather than read off the element at save time, because a frame
      // pushed by the desktop rebuilds this list — and with it this input — while
      // somebody is still typing into it.
      this.renameText = field.value
    })
    field.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') save(field.value)
      if (event.key === 'Escape') {
        this.renamingPort = null
        this.renamingMachine = null
        this.renderContent()
      }
    })

    const actions = element('div', 'rename__actions')
    const confirm = element('button', 'button rename__save', 'Save')
    confirm.type = 'button'
    confirm.addEventListener('click', () => save(field.value))
    const cancel = element('button', 'button button--quiet', 'Cancel')
    cancel.type = 'button'
    cancel.addEventListener('click', () => {
      this.renamingPort = null
      this.renamingMachine = null
      this.renderContent()
    })
    actions.append(confirm, cancel)

    block.append(field, actions)
    // After the tree is built, by the caller that puts it on screen — focusing an
    // element that is not in the document does nothing, and doing nothing quietly
    // is how the pair screen's keypad stopped appearing once already.
    queueMicrotask(() => {
      field.focus()
      field.select()
    })
    return block
  }

  /* -------------------------------------------------- the copilot on screen -- */

  /**
   * The copilot's own screen, and **no split on it**.
   *
   * He said this twice in one recording, which is why it is stated twice here:
   *
   * > *"When it is interacting it is making two split views even inside its own
   * > page. It should not make two split views on its own page."*
   *
   * So on this screen the copilot *is* the page — the conversation, the scan and
   * the answer all in one column — and {@link renderDock} draws nothing. On any
   * other screen it is the side panel, and only then. The two share
   * {@link copilotBody} so that what is offered cannot drift between them.
   */
  private copilotScreen(): HTMLElement {
    const screen = element('div', 'screen')
    screen.style.padding = '0'
    /*
     * Which machine's copilot, at the top, in his words above `machineSwitch`.
     *
     * It belongs here more than on any other screen: a copilot is *this
     * machine's* agent holding *this machine's* shell, so a conversation read
     * under the wrong machine's name is not a cosmetic error. Everything on this
     * screen is replaced when the switch is pressed — `switchTo` clears the
     * copilot with the machine, and the next welcome brings that machine's own.
     */
    const machines = this.machineSwitch()
    if (machines !== null) screen.append(machines)
    /*
     * One branch, where there used to be two.
     *
     * The other one drew a six-digit field under the heading "Connect the
     * copilot", and it is deleted along with the ceremony behind it: the tab is
     * drawn only for a device whose welcome carried a copilot, and a device
     * whose welcome carried one has it. There is no state in between for a
     * screen to describe — which is the point of the whole change, in his words
     * at the top of `copilot.ts`.
     */
    screen.append(this.copilotBody(false))
    return screen
  }

  /**
   * Whether an act-tier control would do anything if somebody pressed it.
   *
   * Both halves, because both can be false separately. `grant.act` is what the
   * machine allows this device; `link.open` is whether this *socket* has said
   * hello and been answered. One of his own devices holds every tier, so the
   * grant is almost always true and the open flag is the half that matters — and
   * it is false for one round trip on every single connect, which since the
   * connect screen went away is the first thing anybody sees when they open the
   * tab. A composer drawn in that window is a box somebody types into and
   * presses Send on, and `copilotStep` drops the frame on the floor because the
   * connection is not open. That is precisely the defect this whole review is
   * built on, so it is gated in the one place both controls read.
   */
  private get copilotCanAct(): boolean {
    return this.copilot.link.open && this.copilot.link.grant.act
  }

  /**
   * Everything a connected copilot offers, on the screen or in the panel.
   *
   * One builder for both, and `compact` changes only what is *left out* of the
   * panel — never what is offered. A side panel that could do something the
   * screen could not, or the other way round, would be two features wearing one
   * name.
   */
  private copilotBody(compact: boolean): HTMLElement {
    const body = element('div', 'copilot')
    const grant = this.copilot.link.grant

    body.append(this.copilotStatus())
    body.append(this.scanControls())

    const status = this.scanStatusLine()
    if (status !== null) body.append(status)

    const answer = this.answerCard()
    if (answer !== null) body.append(answer)

    /*
     * The fleet, on the copilot's own page, because a scan needs something to
     * point at and this screen has no session list of its own. On any other
     * screen the rows are already there — `sessionsScreen` stamps them with the
     * same attribute — so the panel does not draw a second copy of a list that
     * is on screen behind it.
     *
     * It goes away once there is an answer, and that was found by looking: the
     * card and the list underneath it were printing the same three sessions with
     * the same words, which is the duplication his design rules call out by name.
     * The fleet is the scan's *stage* — it exists to be pointed at — and once the
     * pointing is over the answer is the better version of the same list. It
     * comes back the moment another scan starts.
     */
    if (!compact && (this.answer === null || this.scanRunning)) body.append(this.scanFleet())

    body.append(this.chatBlock(compact))

    const said = grantSentence(grant)
    if (said !== null) body.append(element('p', 'note copilot-note', said))
    if (this.copilotCanAct) body.append(this.composer())

    const waiting = this.pendingRows()
    if (waiting !== null) body.append(waiting)

    if (this.copilot.notice !== null) {
      const notice = element('p', 'note copilot-notice', plain(this.copilot.notice))
      body.append(notice)
    }
    return body
  }

  /**
   * What the copilot is, as two states that are plainly about two things.
   *
   * `desk` is the copilot at the machine — the conversation the person is having
   * there — and `run` is *this browser's own* run, which is the only thing it can
   * talk to. The protocol keeps them apart and so does this: a screen that showed
   * the desk's state on its own Start button would offer to start something that
   * is already running, or refuse to because something unrelated is.
   *
   * ## Why they are chips and not sentences
   *
   * They were sentences, and the pair of them read as a contradiction:
   * *"The copilot is not running at the machine."* in a headline, over
   * *"This browser has its own run"*. Both true, about different copilots, and
   * indistinguishable at a glance. A chip carries its subject before it carries
   * its state — `Machine · stopped`, `This browser · running` — so the two can
   * never be read as one, and neither of them is a statement on a screen that is
   * not allowed any.
   */
  private copilotStatus(): HTMLElement {
    const block = element('div', 'copilot-status')
    const report = this.copilot.report

    const states = element('div', 'copilot-state')
    states.append(this.stateChip('Machine', deskState(report)))
    // Only once the machine has answered. Before that there is no such thing as
    // "this browser's run" to have a state, and a chip reading `none` would be a
    // claim made out of not having asked yet.
    if (report !== null) {
      states.append(this.stateChip('This browser', report.run === null ? 'none' : 'running'))
    }
    block.append(states)

    const facts: string[] = []
    if (report !== null) {
      if (report.profile !== null) facts.push(plain(report.profile))
      // Tokens, never money. This client has never shown a price and
      // `tests/no-cost.test.ts` is the latch that keeps it that way; the context
      // a turn costs is a fact about a conversation rather than a bill.
      if (report.turnTokens > 0) facts.push(`${report.turnTokens.toLocaleString()} tokens a turn`)
      if (report.tools > 0) facts.push(`${report.tools} tools`)
    }
    if (facts.length > 0) block.append(element('p', 'copilot-status__facts', facts.join(' · ')))

    const why = unavailableSentence(report)
    if (why !== null) block.append(element('p', 'copilot-status__why', plain(why)))
    return block
  }

  /**
   * One copilot, and what it is doing.
   *
   * The subject is drawn first and in the quieter ink, because the subject is
   * the whole reason this is a chip rather than a line of prose: two states on
   * one screen are only readable if each says what it is about.
   *
   * `data-state` carries the word to the stylesheet, which is where the dot's
   * colour is decided — the same three-band vocabulary the session list uses,
   * so a reader who knows what amber means in one place knows it here.
   */
  private stateChip(subject: string, state: string): HTMLElement {
    const chip = element('span', 'copilot-state__chip')
    chip.dataset.state = state
    chip.append(element('i', 'copilot-state__dot'), element('b', undefined, subject), element('span', undefined, state))
    return chip
  }

  /**
   * The toggle and the button that starts a scan.
   *
   * The toggle is the whole of *"both modes are required"*, and the promise it
   * makes is that turning it off changes what you **watch** and not what you
   * **get**: the answer is the same function over the same stops either way, and
   * the one field that could differ is handled inside the shared model. So the
   * label says what it does rather than naming a mode — somebody who reads
   * "interactive" has to guess, and the guess is usually that it makes the answer
   * better.
   */
  private scanControls(): HTMLElement {
    const block = element('div', 'copilot-scan')

    const toggle = element('label', 'copilot-toggle')
    const box = element('input')
    box.type = 'checkbox'
    box.checked = this.interactive
    box.addEventListener('change', () => {
      this.interactive = box.checked
      // A scan already running is left running rather than cut off: the switch is
      // about the next one, and stopping the thing somebody is watching in order
      // to honour a preference about watching is the wrong way round.
      this.render()
    })
    toggle.append(box, element('span', undefined, 'Show me the scan'))
    block.append(toggle)

    const running = this.scanRunning
    const button = element('button', 'button copilot-scan__go', running ? 'Stop' : 'Scan the sessions')
    button.type = 'button'
    // Nothing to scan is not a disabled button with no explanation: there is no
    // button at all, and the sentence under it says what is missing.
    button.disabled = !running && this.sessions.length === 0
    button.addEventListener('click', () => (running ? this.stopScan() : this.startScan()))
    block.append(button)

    if (this.sessions.length === 0) {
      block.append(
        element('p', 'copilot-scan__none', `There are no sessions on the ${this.noun} to scan.`),
      )
    }
    return block
  }

  /**
   * The one line under the controls while a scan is running, or null.
   *
   * `statusSentence` composes it, in the shared model, so the desktop and this
   * client say the same thing about the same state — including *why* it stopped,
   * which matters more at machine speed than it did at reading speed: the person
   * will not have seen which of their own gestures did it.
   */
  private get scanRunning(): boolean {
    return this.scanState !== null && isScanning(this.scanState)
  }

  private scanStatusLine(): HTMLElement | null {
    const state = this.scanState
    if (!this.scanRunning || state === null) return null
    const line = element('div', 'copilot-playhead')
    line.append(element('span', 'copilot-playhead__text', statusSentence(state)))
    const resume = element('button', 'button button--quiet copilot-playhead__resume', 'Carry on')
    resume.type = 'button'
    // Drawn always and hidden until it is needed. See `paintScan`: a control that
    // appears between a pointerdown and its own click is a control that cannot be
    // pressed, and this one is pressed at exactly the moment somebody has just
    // touched the screen.
    resume.hidden = state.status !== 'paused'
    resume.addEventListener('click', () => this.scan?.resume())
    line.append(resume)
    const bar = element('div', 'copilot-playhead__bar')
    const fill = element('div', 'copilot-playhead__fill')
    fill.style.width = `${Math.round((state.seen.length / Math.max(1, state.count)) * 100)}%`
    bar.append(fill)
    line.append(bar)
    return line
  }

  /**
   * The fleet the scan walks, on the copilot's own page.
   *
   * Every row carries {@link SCAN_ATTRIBUTE}, which is what the focus box is
   * measured from — a real rectangle around a real row, re-read every frame, so
   * the hole follows the list rather than a remembered position. The row that is
   * currently focused is marked so the ring is drawn in CSS rather than on the
   * canvas: a border a browser paints is crisper than one a canvas does, and it
   * scrolls with the row for free.
   */
  private scanFleet(): HTMLElement {
    const block = element('div', 'copilot-fleet')
    const state = this.scanState
    const here = this.scanRunning && state !== null ? (this.scanStops[state.index]?.sessionId ?? null) : null
    const seen = new Set((state?.seen ?? []).map((index) => this.scanStops[index]?.sessionId))

    for (const stop of this.plannedStops()) {
      const row = element('div', 'copilot-fleet__row')
      row.setAttribute(SCAN_ATTRIBUTE, stop.sessionId)
      if (stop.sessionId === here) row.classList.add('scan-here')
      if (seen.has(stop.sessionId)) row.classList.add('scan-seen')
      row.append(element('span', 'copilot-fleet__why', stop.why))
      const body = element('div', 'copilot-fleet__body')
      body.append(element('div', 'copilot-fleet__title', plain(stop.sessionTitle)))
      // Only when there is something true to put in it. `noteOf` answers empty
      // for a session this browser has no activity of its own for, which is
      // most of them on a fresh page, and the line it used to print there was
      // both a sentence and wrong. See `noteOf`.
      if (stop.note !== '') body.append(element('div', 'copilot-fleet__note', plain(stop.note)))
      row.append(body)
      block.append(row)
    }
    return block
  }

  /**
   * The stops as they would be planned right now.
   *
   * Drawn from the live plan while a scan is running so the list under the focus
   * box cannot reorder itself mid-flight — a session going idle two stops in
   * would otherwise move the row the box is measured from, and the hole would
   * jump to a different session with no explanation.
   */
  private plannedStops(): ScanStop[] {
    if (this.scanStops.length > 0) return this.scanStops
    return scanPlan({
      sessions: this.sessions,
      activity: this.activity,
      started: this.copilot.sessions,
      tools: this.copilot.tools,
      now: Date.now(),
    })
  }

  /**
   * The answer: one structured response, grouped by session.
   *
   * > *"It returns to its own chat and combines everything into one structured
   * > response: this session did this, this session did that. Then it stops, and
   * > he reads at his own pace, in one place."*
   *
   * Every line of it is a fact that came off the wire — the status, the exit code,
   * when the session last did something — and the quoted line, where there is
   * one, is **the machine's own sentence** about the call that started that
   * session, joined through `originRunId`. A stop with nothing to quote draws no
   * quote. See the header of `copilot-scan.ts` for why nothing here is composed.
   */
  private answerCard(): HTMLElement | null {
    const answer = this.answer
    if (answer === null) return null
    const card = element('section', 'answer')
    card.append(element('h3', 'answer__head', 'What the sessions are doing'))
    card.append(element('p', 'answer__count', answerSummary(answer)))

    for (const session of answer) {
      const group = element('div', 'answer__session')
      group.append(element('div', 'answer__title', plain(session.title)))
      for (const line of session.lines) {
        const row = element('div', line.shown ? 'answer__line' : 'answer__line answer__line--missed')
        row.append(element('span', 'answer__why', line.why))
        if (line.note !== '') row.append(element('span', 'answer__note', plain(line.note)))
        // Only when there is one. A stop with no quote is a stop this browser has
        // no line of the machine's own to show, and substituting the folder or
        // the title would produce something that looks like evidence and is not.
        if (line.quote !== '') row.append(element('div', 'answer__quote', plain(line.quote)))
        if (!line.shown) row.append(element('span', 'answer__missed', 'Not reached'))
        group.append(row)
      }
      card.append(group)
    }

    card.append(element('p', 'answer__from', ANSWER_PROVENANCE))

    // The one thing that turns a reading into a conversation, and it exists only
    // when this connection may actually send it. The text is put in the composer
    // rather than sent, so what goes to the copilot is something the person read
    // and pressed send on rather than something this client said on their behalf.
    if (this.copilotCanAct) {
      const ask = element('button', 'button button--quiet answer__ask', 'Ask the copilot about this')
      ask.type = 'button'
      ask.addEventListener('click', () => {
        this.composerText = answerAsQuestion(answer)
        this.render()
      })
      card.append(ask)
    }
    return card
  }

  /** The conversation, oldest first. Empty until a run exists. */
  private chatBlock(compact: boolean): HTMLElement {
    const block = element('div', 'chat')
    const messages = compact ? this.copilot.chat.slice(-6) : this.copilot.chat
    /*
     * An empty conversation is drawn as an empty conversation.
     *
     * Two sentences used to sit here — *"No run from this browser yet. Start one
     * to talk to the copilot on that machine."* and *"Nothing said yet."* — and
     * the first of them narrated a Start button that is on the same screen, two
     * inches below. That is the habit he has now named four times: *"don't put
     * any single statement in anywhere… Let the smart people use it."* The
     * button says what to do; the blank says there is nothing yet.
     */
    for (const message of messages) {
      const bubble = element('div', `chat__bubble chat__bubble--${message.role}`)
      bubble.append(element('div', 'chat__text', plain(message.text)))
      // Said rather than hidden. A cut message is the machine telling this
      // browser there is more of it, and the honest answer is to say where the
      // rest is instead of showing a paragraph that stops mid-sentence.
      if (message.truncated === true) {
        block.append(bubble)
        bubble.append(element('div', 'chat__more', `Cut short here. The whole answer is on the ${this.noun}.`))
        continue
      }
      block.append(bubble)
    }

    const tools = this.toolTrail()
    if (tools !== null) block.append(tools)

    /*
     * What this browser has said and the machine has not said back, at the foot
     * of the conversation where it belongs.
     *
     * The composer reported *Sending…* on its button, which says something is
     * happening and not **what**. The sentence itself was gone — out of the box
     * and not yet in the conversation — for a full round trip through a pty and
     * an agent CLI. So it is drawn here, immediately, and the machine's own row
     * replaces it when it arrives; see `settle` in `copilot.ts`.
     */
    for (const row of this.copilot.outgoing) {
      const bubble = element('div', 'chat__bubble chat__bubble--you chat__bubble--sending')
      bubble.append(element('div', 'chat__text', plain(row.text)))
      bubble.append(element(
        'div',
        row.unacknowledged ? 'chat__unsaid' : 'chat__more',
        // Not "failed". The echo is the agent CLI having taken the turn rather
        // than a network acknowledgement, so silence means unaccounted for —
        // and the row says only that, with the text still there to copy or send
        // again.
        row.unacknowledged ? `The ${this.noun} has not echoed this back.` : 'sending…',
      ))
      block.append(bubble)
    }
    return block
  }

  /**
   * What the copilot has actually done, as it does it.
   *
   * This is the frame that makes a refusal visible: a call the grant did not
   * cover arrives with `outcome: 'refused'` and the machine's own reason, rather
   * than as silence. A gate that denies invisibly is indistinguishable from a
   * gate that was never reached.
   */
  private toolTrail(): HTMLElement | null {
    if (this.copilot.tools.length === 0) return null
    const trail = element('div', 'trail')
    for (const row of this.copilot.tools.slice(-8)) {
      const line = element('div', `trail__row trail__row--${row.outcome}`)
      line.append(element('span', 'trail__tool', plain(row.tool)))
      line.append(element('span', 'trail__detail', plain(row.detail)))
      if (row.refusal !== null) line.append(element('span', 'trail__refusal', plain(row.refusal)))
      trail.append(line)
    }
    return trail
  }

  /**
   * Talking to the copilot. Drawn only when it would work — see
   * {@link copilotCanAct} — because sending is an act and a dead Send button is
   * worse than no Send button.
   */
  private composer(): HTMLElement {
    const block = element('form', 'composer')
    const field = element('textarea', 'composer__field')
    field.value = this.composerText
    field.rows = 2
    field.placeholder = 'Ask the copilot…'
    field.setAttribute('aria-label', 'Message the copilot')
    field.addEventListener('input', () => {
      this.composerText = field.value
    })
    const send = element('button', 'button composer__send', this.copilot.sending ? 'Sending…' : 'Send')
    send.type = 'submit'
    send.disabled = this.copilot.sending || this.copilot.report?.run === null

    block.append(field, send)
    block.addEventListener('submit', (event) => {
      event.preventDefault()
      const text = this.composerText
      /*
       * The box is emptied **only when a bubble appeared**.
       *
       * It used to be emptied first, unconditionally, and then the reducer
       * decided whether to send anything — so a message refused for being too
       * long, or sent while another was still unacknowledged, was wiped out of
       * the textarea and out of the conversation at the same instant. There was
       * nothing left on the screen to retype from. A row in `outgoing` is
       * exactly the receipt for "this went onto the wire", so that is what is
       * asked.
       */
      const before = this.copilot.outgoing.length
      this.copilotDo({ t: 'say', text })
      if (this.copilot.outgoing.length > before) this.composerText = ''
      this.render()
    })

    // Start is here rather than beside the desk's status, because it is what the
    // composer needs in order to work: this device's run is what a message goes
    // to, and a box that could not send until something else was pressed
    // somewhere else is the shape of a control that appears broken.
    if (this.copilot.report?.run === null) {
      const start = element('button', 'button button--quiet composer__start', 'Start a run')
      start.type = 'button'
      const why = unavailableSentence(this.copilot.report)
      // Disabled **with the reason said out loud**, in the machine's own words —
      // it is the only party that knows whether there is an agent installed and
      // signed in. A dead button with no sentence is the defect this review is
      // built on.
      start.disabled = why !== null
      start.addEventListener('click', () => this.copilotDo({ t: 'start' }))
      block.append(start)
    }
    return block
  }

  /**
   * Confirmations waiting at the machine, which this connection may not answer.
   *
   * Watching a question is not judging it, and the row carries no arguments —
   * a device that cannot answer has no decision to make with them. What it is
   * worth is the failure the design named: a dialog on a screen nobody is looking
   * at, timing out in silence two minutes later.
   */
  private pendingRows(): HTMLElement | null {
    const waiting = this.copilot.pending.filter((row) => !row.mine)
    if (waiting.length === 0) return null
    const block = element('div', 'pending')
    for (const row of waiting) {
      const line = element('div', 'pending__row')
      line.append(element('span', 'pending__tool', plain(row.tool)))
      line.append(element('span', 'pending__summary', plain(row.summary)))
      line.append(element('span', 'pending__where', GO_AND_LOOK))
      block.append(line)
    }
    return block
  }

  /* ------------------------------------------------------------- the dock -- */

  /**
   * The copilot on somebody else's screen, and **only** on somebody else's screen.
   *
   * The other half of the layout rule. On the copilot's own page this draws
   * nothing at all — not a collapsed panel, not an empty aside — because the rule
   * is about the page not splitting, and a hidden splitter is still a splitter
   * the first time somebody drags it.
   */
  private renderDock(): void {
    const wanted =
      this.copilot.link.open &&
      this.screen !== 'copilot' &&
      this.screen !== 'pair' &&
      this.screen !== 'add-server' &&
      this.screen !== 'terminal' &&
      !this.dockFolded &&
      (this.scanState !== null || this.answer !== null || this.copilot.chat.length > 0)
    this.dock.hidden = !wanted
    if (!wanted) {
      this.dock.replaceChildren()
      return
    }

    const head = element('div', 'dock__head')
    head.append(element('span', 'dock__name', 'Copilot'))
    /*
     * The dot beside the name is the control, which is his instruction rather
     * than a flourish:
     *
     * > *"The small round dot beside the copilot's name becomes a control — click
     * > it to fold back, and the side panel returns."*
     *
     * Folding is per visit and is undone by opening the Copilot tab, so it is a
     * way to get the panel out of the way rather than a preference to be found
     * and un-set later.
     */
    const fold = element('button', 'dock__dot')
    fold.type = 'button'
    fold.setAttribute('aria-label', 'Fold the copilot away')
    fold.title = 'Fold the copilot away'
    fold.addEventListener('click', () => {
      this.dockFolded = true
      this.render()
    })
    head.append(fold)

    this.dock.replaceChildren(head, this.copilotBody(true))
  }

  /* ------------------------------------------------------------ the sheet -- */

  /**
   * A confirmation this connection may answer, with everything needed to judge it.
   *
   * The part of this feature worth the most care. A consent prompt without enough
   * context becomes a reflex Yes, and a gate that is always answered yes is worse
   * than no gate at all because it looks like protection. So this carries what a
   * person actually needs: what, with which arguments verbatim, raised by whom,
   * and what happens if they say nothing.
   *
   * **Refusing is at least as easy as accepting.** Refuse comes first and is the
   * full-width one; Allow is the quieter of the two. The safe answer must never
   * be the harder gesture.
   */
  private renderSheet(): void {
    const ask = this.copilot.ask
    this.sheet.hidden = ask === null
    if (ask === null) {
      this.sheet.replaceChildren()
      return
    }

    const card = element('div', 'sheet__card')
    card.setAttribute('role', 'dialog')
    card.setAttribute('aria-modal', 'true')
    card.append(element('h2', 'sheet__title', 'The copilot wants to do something'))
    card.append(element('p', 'sheet__summary', plain(ask.summary)))
    card.append(element('p', 'sheet__tool', `${plain(ask.tool)} · ${plain(ask.tier)}`))

    // Whose run raised it, so *my browser's copilot asked for this* and *the
    // machine's copilot asked for this* never read the same.
    card.append(
      element('p', 'sheet__origin', ask.origin === 'window' ? 'Raised at the machine' : 'Raised by this browser’s run'),
    )

    // Every argument, in the tool's own order, verbatim. This is the field that
    // turns a prompt from a shape into a decision.
    const args = element('dl', 'sheet__args')
    for (const [name, value] of Object.entries(ask.args)) {
      args.append(element('dt', undefined, plain(name)))
      args.append(element('dd', undefined, plain(describeArg(value))))
    }
    if (args.childElementCount > 0) card.append(args)

    const left = secondsLeft(ask.expiresAt, Date.now())
    card.append(
      element(
        'p',
        'sheet__countdown',
        left > 0 ? `Refused automatically in ${left}s if nobody answers.` : 'Refusing…',
      ),
    )

    const actions = element('div', 'sheet__actions')
    const refuse = element('button', 'button sheet__refuse', 'Refuse')
    refuse.type = 'button'
    refuse.addEventListener('click', () => this.copilotDo({ t: 'answer', id: ask.id, approved: false }))
    const allow = element('button', 'button button--quiet sheet__allow', 'Allow')
    allow.type = 'button'
    allow.addEventListener('click', () => this.copilotDo({ t: 'answer', id: ask.id, approved: true }))
    actions.append(refuse, allow)
    card.append(actions)

    this.sheet.replaceChildren(card)
  }

  /* -------------------------------------------------------------- the scan -- */

  /**
   * Start one. Two paths, one answer.
   *
   * Interactive off is the whole of the second mode and it is deliberately three
   * lines: the plan is the same plan, the answer is the same function over it,
   * and the only thing that does not happen is the watching. `scanAnswer` takes
   * the flag so that the shared model decides what "not reached" means rather
   * than this method — see its note.
   */
  private startScan(): void {
    const stops = scanPlan({
      sessions: this.sessions,
      activity: this.activity,
      started: this.copilot.sessions,
      tools: this.copilot.tools,
      now: Date.now(),
    })
    this.scanStops = stops
    if (stops.length === 0) return

    if (!this.interactive) {
      this.scanState = null
      this.endScanVisuals()
      this.answer = scanAnswer(stops, false)
      this.render()
      return
    }

    this.answer = null
    if (this.scan === null) {
      this.scan = createScanRunner(browserScanClock(), (state) => this.onScan(state))
    }
    // The field goes up before the first stop rather than on the first arrival,
    // so the page dulls and *then* the box lands — the other order is a flash of
    // clear page under a box that has already moved.
    this.mountField()
    this.scan.play(stops.length)
    this.render()
  }

  /** Ended by hand. What was shown is what the answer reports. */
  private stopScan(): void {
    this.scan?.stop()
  }

  /**
   * One published playhead state.
   *
   * Two jobs, and they are separate on purpose. The first is *recording what was
   * actually shown* — `shownAt` is what makes the summary honest, because it
   * counts what a person saw rather than what was planned. The second is ending:
   * a finished scan takes the field down and composes the answer, and it is the
   * same `scanAnswer` the background path calls.
   */
  private onScan(state: ScanState): void {
    this.scanState = state
    for (const index of state.seen) {
      const stop = this.scanStops[index]
      if (stop !== undefined && stop.shownAt === null) stop.shownAt = Date.now()
    }
    if (state.status === 'finished') {
      this.endScanVisuals()
      this.answer = scanAnswer(this.scanStops, true)
      this.render()
      return
    }
    // `arrive` is dispatched from here rather than from a timer, because arriving
    // *is* being drawn: the box exists once the row it is measured from is on
    // screen, and asking for that measurement is the cheapest honest test of it.
    if (state.status === 'travelling') {
      const stop = this.scanStops[state.index]
      if (stop !== undefined && focusRect(stop.sessionId) !== null) {
        this.scan?.dispatch({ kind: 'arrive', at: performance.now() })
      } else if (stop !== undefined) {
        // A row that is not on this page — the fleet is longer than a phone
        // screen, and the scan walks all of it. Counted as an arrival anyway, so
        // the playhead does not stall on a session somebody would have to scroll
        // to; the field simply draws with no hole, which reads as the machine
        // looking at something off screen. True, and better than a hole cut
        // somewhere arbitrary.
        this.scan?.dispatch({ kind: 'arrive', at: performance.now() })
      }
    }
    this.paintScan()
  }

  /**
   * Update what a running scan changes, and **nothing else**.
   *
   * ## The defect this exists to fix, which was found by looking
   *
   * This method used to be `this.render()`, and a scan was therefore rebuilding
   * the whole screen four times a second. That is wasteful, and the waste was
   * not the problem. The problem was that the interruption watch pauses on
   * `pointerdown` — which fires *before* `click` — so pressing anything during a
   * scan tore the DOM down under the finger, the pressed element was replaced,
   * and the `click` that followed had nothing to land on. Measured: pressing the
   * Sessions tab mid-scan paused the scan, said *"Held — you clicked"*, and
   * stayed on the Copilot screen. Every control in the app was dead for as long
   * as a scan was running, which is the precise failure this whole review is
   * about — a control that cannot act.
   *
   * So a running scan touches only the three things it actually changes: the
   * status line, the bar, and which rows are lit. Everything that appears or
   * disappears — the Stop label, the playhead itself, the answer — changes at a
   * moment that is not mid-gesture (starting, finishing, or a screen change),
   * and those still go through a full render.
   *
   * `querySelectorAll` over the whole frame rather than a held reference,
   * deliberately: the panel and the screen can each be showing a playhead, the
   * full render replaces both whenever it runs, and a cached node would be one
   * detached from the document with no symptom other than a line that stopped
   * counting.
   */
  private paintScan(): void {
    const state = this.scanState
    if (state === null) return
    for (const node of this.root.querySelectorAll('.copilot-playhead__text')) {
      node.textContent = statusSentence(state)
    }
    for (const node of this.root.querySelectorAll<HTMLElement>('.copilot-playhead__fill')) {
      node.style.width = `${Math.round((state.seen.length / Math.max(1, state.count)) * 100)}%`
    }
    // The resume button is drawn once and shown or hidden here, rather than
    // added and removed: an element that appears mid-scan is an element that can
    // appear between a pointerdown and the click it belongs to, which is the
    // same class of bug this method was written for.
    for (const node of this.root.querySelectorAll<HTMLElement>('.copilot-playhead__resume')) {
      node.hidden = state.status !== 'paused'
    }
    // Only while it is moving. A finished scan leaves its trail — which rows were
    // covered is worth keeping under the answer — but nothing is being looked at
    // any more, and a ring left behind would point at a session for no reason.
    const here = isScanning(state) ? (this.scanStops[state.index]?.sessionId ?? null) : null
    const seen = new Set(state.seen.map((index) => this.scanStops[index]?.sessionId))
    /*
     * Every scannable row, wherever it is drawn — the copilot's own list and the
     * session list on the screen behind the panel are the same rows by id, and
     * the machine is looking at *the session*, not at one of two pictures of it.
     * The classes are generic for exactly that reason: a `copilot-fleet__row--`
     * name would have marked the copy on the copilot's page and left the row a
     * person is actually watching unmarked.
     */
    for (const row of this.root.querySelectorAll<HTMLElement>(`[${SCAN_ATTRIBUTE}]`)) {
      const id = row.getAttribute(SCAN_ATTRIBUTE)
      row.classList.toggle('scan-here', id === here)
      row.classList.toggle('scan-seen', seen.has(id ?? ''))
    }
  }

  /** The dots go up, and the screen is handed back the moment anybody touches it. */
  private mountField(): void {
    if (this.field !== null) return
    this.field = mountScanField(this.root, () => this.scanReading())
    this.scanWatch = watchScanInterruption(
      window,
      (reason) => this.scan?.pause(reason),
      () => this.scan?.resume(),
    )
  }

  private endScanVisuals(): void {
    this.field?.destroy()
    this.field = null
    this.scanWatch?.stop()
    this.scanWatch = null
  }

  /**
   * What the field reads, once a frame.
   *
   * The hole is measured from the DOM every time rather than remembered, so it
   * follows a list that scrolls under a thumb. `arrivals` rather than the stop
   * index, because a scan can revisit an index and a surge has to fire every time
   * the machine lands somewhere.
   */
  private scanReading(): FieldReading {
    const state = this.scanState
    if (state === null || !isScanning(state)) {
      return { hole: null, seen: 0, count: 0, arrivals: 0 }
    }
    const stop = this.scanStops[state.index]
    return {
      hole: stop === undefined || state.arrivedAt === null ? null : focusRect(stop.sessionId),
      seen: state.seen.length,
      count: state.count,
      arrivals: state.arrivals,
    }
  }

  /**
   * Say something that will stop being said.
   *
   * Two and a half seconds, the same as the phone's. It is not a notification and
   * must never be used as one: everything that matters — the connection, a refused
   * request, a machine asking for a login — has a surface that stays on screen
   * until it stops being true.
   */
  private say(message: string, hold = false): void {
    this.toastText = message === '' ? null : message
    if (this.toastTimer !== null) window.clearTimeout(this.toastTimer)
    this.toastTimer = null
    // `hold` is for the one caller with a reason to keep a line up: a transfer
    // replaces its own line every acknowledgement and clears it when the path
    // lands, so a two-and-a-half second timer would blank the progress of a file
    // that is still crossing. Everything else expires.
    if (!hold && this.toastText !== null) {
      this.toastTimer = window.setTimeout(() => {
        this.toastTimer = null
        this.toastText = null
        this.renderToast()
      }, 2500)
    }
    this.renderToast()
  }

  private renderToast(): void {
    const message = this.toastText
    this.toast.hidden = message === null
    this.toast.textContent = message ?? ''
  }

  /**
   * New session, and the folders it may start in.
   *
   * Absent rather than disabled in the two cases where it cannot work — a
   * desktop that never advertised `create`, and a socket that is not up. That
   * is the design brief's rule and the repo's: a control whose only function is
   * to explain that it does not function is a fake feature.
   *
   * The third case is different in kind. A desktop that has granted this device
   * *no* folders is not broken and has not lost anything; it will simply refuse
   * every session this phone could ask for. What that state needs is not a
   * button but the sentence naming the machine and the screen where folders are
   * chosen — which is the whole of the bug being fixed here, since the version
   * of this app that showed one unexplained folder had nothing to say about
   * where the list came from either.
   */
  /**
   * Which machine this screen is about, and the other ones.
   *
   * One row of pills, and **one implementation of it**, because he asked for the
   * same control in three places:
   *
   * > *"we have two paired machines, so the way inside the copilot page on the
   * > top we have switch between machines — same switch like the first time we
   * > had. So sessions also, on local also."*
   *
   * *The same switch* is the requirement, not merely *a* switch. Three copies of
   * this loop would be three screens that answer "which machine am I on" in
   * three slightly different ways, and the first one to drift is the one nobody
   * is looking at. The header's own chevron is not that control: it opens the
   * Machines screen, which is where a machine is renamed and forgotten, and a
   * question asked on every screen should not need a screen of its own to
   * answer.
   *
   * Null with fewer than two machines, which is the standing rule against a
   * picker with a single item in it.
   *
   * `busy` is for the one caller that has a reason to freeze it: a `create` in
   * flight is about to open a session on *this* machine, and switching under it
   * would land the answer on a socket that is being torn down.
   */
  private machineSwitch(busy = false): HTMLElement | null {
    if (this.book.machines.length < 2) return null
    const block = element('div', 'start__switch')
    block.append(element('p', 'start__caption', 'On'))
    const row = element('div', 'start__machines')
    // Labelled as a *set*, so two chips can never read the same word. See
    // `machineLabels`: one machine at a time cannot know it has a twin.
    const labels = machineLabels(this.book.machines, this.origin)
    for (const [at, known] of this.book.machines.entries()) {
      const here = known.id === this.book.currentId
      const pick = element(
        'button',
        here ? 'start__machine start__machine--here' : 'start__machine',
        labels[at] ?? machineLabel(known, this.origin),
      )
      pick.type = 'button'
      pick.setAttribute('aria-pressed', here ? 'true' : 'false')
      // The current one is not a control. Pressing it would tear down a live
      // socket and dial the machine it is already on, which is a press that
      // costs a reconnection and changes nothing.
      pick.disabled = here || busy
      pick.addEventListener('click', () => this.switchTo(known.id))
      row.append(pick)
    }
    block.append(row)
    return block
  }

  private startBlock(): HTMLElement | null {
    if (this.state.phase !== 'online' || !this.capabilities.includes('create')) return null

    const block = element('section', 'start')

    /*
     * Which machine, above which folder — the same order and the same place as
     * the desktop's.
     *
     * *"Everything the desktop can do with a remote connection, the browser must
     * do too — open a new session, choose the machine, choose the folder, the
     * same flow. The browser and app side will be the same."*
     *
     * It was already possible and it was not the same flow: switching machines
     * lived on a screen of its own, so starting a session on the other computer
     * meant leaving Sessions, choosing there, coming back, and pressing New
     * session. The machine decides which folders exist, so it belongs above them
     * and in the same block — asking for a folder first and the machine second
     * would mean answering the folder twice.
     *
     * Drawn only when there is more than one, which is the standing rule against
     * a picker with a single item in it. Switching drops the socket and dials the
     * other machine, so the folder list below redraws as *its* list — see
     * `switchTo`, which clears `folders` precisely so that nothing on screen is
     * ever the previous machine's.
     */
    const machines = this.machineSwitch(this.awaitingCreate)
    if (machines !== null) block.append(machines)

    // The platform decides how two spellings of one path are compared — NTFS
    // does not distinguish case and a POSIX filesystem does. See `samePath`.
    const offer = folderOffer(this.folders, this.sessions, this.hostPlatform)
    if (offer.kind === 'none') {
      block.append(element('p', 'start__note', noFoldersSentence(this.noun)))
      return block
    }

    const rows = pickerRows(offer, this.noun)
    const label = this.awaitingCreate ? 'Starting…' : 'New session'

    // One destination is not a choice, so it is not drawn as one — the standing
    // rule against a picker with a single item in it. The folder goes under the
    // button instead of behind it, which puts the thing the old picker never
    // managed to say — *where this is about to start* — on screen before the
    // tap rather than after it.
    if (rows.length === 1) {
      const only = rows[0]
      const button = element('button', 'button', label)
      button.type = 'button'
      button.disabled = this.awaitingCreate
      button.addEventListener('click', () => this.startSession(only.folder))
      block.append(button)
      if (only.path) {
        // "Starts in" in the interface face, the path in mono. A bare path under
        // a button is ambiguous — it reads as easily as "you are here" — and the
        // two words are what make it a promise about the tap.
        const where = element('p', 'start__where')
        const path = element('span', undefined, only.label)
        // The line ellipsises, and a deep path is longer than a phone. The same
        // escape hatch the desktop's folder panel uses, for the same reason: a
        // browser adds no tooltip to overflowing text on its own, and this same
        // client is opened from a keyboard as often as from a phone.
        path.title = only.label
        where.append(element('span', 'start__where-label', 'Starts in'), path)
        block.append(where)
      }
      return block
    }

    const toggle = element('button', 'button', label)
    toggle.type = 'button'
    toggle.disabled = this.awaitingCreate
    toggle.setAttribute('aria-expanded', this.picking ? 'true' : 'false')
    toggle.addEventListener('click', () => {
      this.picking = !this.picking
      this.renderContent()
    })
    block.append(toggle)
    if (!this.picking) return block

    // Two words over the list, because three paths under a button are not
    // self-explanatory to somebody who has never seen this screen — and that is
    // the bar the design brief sets.
    block.append(element('p', 'start__caption', 'Start in'))
    const list = element('ul', 'start__folders')
    for (const row of rows) {
      const item = element('li')
      // The path is mono and the sentence is not: monospace is a promise that
      // the characters are exact and countable, which is true of a path and not
      // of "Wherever the Mac would".
      const choice = element('button', row.path ? 'start__folder start__folder--path' : 'start__folder', row.label)
      choice.type = 'button'
      // Two projects can share a last segment, so the whole value has to stay
      // reachable from a row that ellipsises — see the note on the line above.
      if (row.path) choice.title = row.label
      choice.addEventListener('click', () => this.startSession(row.folder))
      item.append(choice)
      list.append(item)
    }
    block.append(list)
    return block
  }

  /**
   * Ask the desktop for a session.
   *
   * No size travels with it, unlike `attach`. There is no emulator on this
   * screen to measure — the desktop starts at its own default and the attach a
   * frame later carries the real shape, which is the same correction every
   * client makes for a session it did not start.
   */
  private startSession(folder: string | null): void {
    if (this.awaitingCreate) return
    this.picking = false
    this.notice = null
    const sent =
      folder === null ? this.connection?.send({ t: 'create' }) : this.connection?.send({ t: 'create', cwd: folder })
    if (sent !== true) {
      // Said, not swallowed. The refusal above is a socket that went down
      // between the render and the tap, and a button that does nothing at all
      // is indistinguishable from one that is broken.
      this.notice = `That did not reach the ${this.noun}, so nothing was started.`
      this.renderContent()
      return
    }
    this.awaitingCreate = true
    this.renderContent()
  }

  /* ------------------------------------------------------------ terminal -- */

  private openSession(id: string): void {
    if (this.connection === null) return
    this.attachedId = id
    this.attachSent = false
    this.notice = null
    this.screen = 'terminal'
    this.buildTerminal()
    this.render()
    // A frame later, so the terminal has a box to measure. Attaching before
    // that would send a size of zero and then correct it, and the correction
    // reflows scrollback that has already been painted.
    requestAnimationFrame(() => {
      this.terminal?.fit()
      this.attach(id)
      this.terminal?.focus()
    })
  }

  /**
   * Ask for a session, carrying the size the phone actually is.
   *
   * The protocol lets `attach` take cols and rows precisely so the first screen
   * arrives the right shape — both or neither, never one.
   */
  private attach(id: string): void {
    const size = this.terminal?.size()
    const sent =
      size === undefined
        ? this.connection?.send({ t: 'attach', id })
        : this.connection?.send({ t: 'attach', id, cols: size.cols, rows: size.rows })
    this.attachSent = sent === true
    // Only once the attach is on the wire: `usage.read` and `account.read` are
    // authorised by the same per-device reach every keystroke is, and asking for
    // a session this connection has not been given is answered `unknown-session`.
    if (this.attachSent) this.sessionBar?.start()
    // Gated the same way for the same reason: `controls.read` goes through the
    // per-device reach every keystroke does.
    if (this.attachSent) this.sessionControls?.start()
  }

  private leaveTerminal(): void {
    if (this.attachedId !== null) this.connection?.send({ t: 'detach', id: this.attachedId })
    this.attachedId = null
    this.attachSent = false
    this.destroyTerminal()
    this.screen = 'sessions'
    this.connection?.send({ t: 'list' })
    this.render()
  }

  private buildTerminal(): void {
    this.destroyTerminal()

    const terminal = createTerminal(
      {
        onData: (data) => this.sendInput(data),
        onResize: (size) => {
          // Only after the attach has gone out. A resize for a session the
          // server has not given us yet is answered with `unknown-session`.
          if (this.attachedId !== null && this.attachSent) {
            this.connection?.send({ t: 'resize', id: this.attachedId, cols: size.cols, rows: size.rows })
          }
        },
      },
      // Built in the appearance that is on screen, rather than built dark and
      // corrected: xterm paints its first frame from the theme it was constructed
      // with, and a terminal that flashes charcoal before going white is the
      // failure this feature is judged on, in miniature.
      this.appearance,
      // And at the size that was chosen, for exactly the same reason: a terminal
      // that appears at 13px and reflows to 18px one frame later is the same
      // failure with a different property.
      this.textSize,
    )
    const keybar = createKeyBar({ onData: (data) => this.sendInput(data) })

    const dock = element('div', 'keybar-dock')
    dock.append(keybar.element)

    /*
     * The session's own bar, above the terminal.
     *
     * Above rather than in the header because the header is the *machine* — its
     * name, the paperclip, the theme — and these three are about the one session
     * on screen. It draws nothing at all until an answer arrives, and nothing
     * ever if the far machine does not advertise `usage` and `account`, so a
     * desktop older than those capabilities gets a pane that is exactly what it
     * was rather than a row explaining what it is missing.
     */
    const bar = new SessionBar({
      send: (message) => this.connection?.send(message) === true,
      capabilities: () => this.capabilities,
      sessionId: () => this.attachedId,
    })
    this.sessionBar = bar

    /*
     * And the session's controls, under the bar — the phone's copy of the
     * cluster the desktop wears on every pane. It draws nothing until a
     * `controls.reading` answers, nothing over a machine that does not
     * advertise `controls`, and nothing over a plain shell, so an older desktop
     * or a bare zsh gets a pane that is exactly what it was.
     */
    const controls = new SessionControls({
      send: (message) => this.connection?.send(message) === true,
      capabilities: () => this.capabilities,
      sessionId: () => this.attachedId,
    })
    this.sessionControls = controls

    /*
     * The same session as a conversation, built beside the terminal rather than
     * instead of it.
     *
     * Both exist for the life of the pane and one is in the document at a time:
     * rebuilding on every toggle would dispose an emulator and replay a whole
     * scrollback to get back to where somebody already was.
     */
    const chat = new ChatView()
    this.chatView = chat
    /*
     * And somewhere to answer it.
     *
     * The view was read-only when it shipped, which made chat mode a detour:
     * read the answer here, go back to the terminal to type one line. It writes
     * into the session's own pty — the same channel the keyboard uses — so
     * there is one transport and a reply typed here shows up in the terminal
     * view as well. See `ChatComposer` for why it is two writes and not one.
     */
    this.chatComposer = new ChatComposer({
      write: (data) => this.writeToSession(data),
      live: () => this.canReadChat,
    })
    this.chatMode = false

    const screen = element('div', 'terminal-screen')
    screen.append(bar.element, controls.element, terminal.element, dock)

    /*
     * A file dragged onto the terminal, in a browser on a computer.
     *
     * *"any kind of media dropping from your PC to any session should smoothly
     * work"* — and this page is one of the surfaces a PC reaches a session
     * through. It is the same transfer as the picker above it; what a browser
     * hands over here is a `File` with contents and no path, which is exactly
     * what the upload needs and never what the desktop's own drop handler could
     * use.
     *
     * `dragover` has to `preventDefault` or `drop` never fires at all, and
     * without either of them Chromium's default for a dropped file is to
     * **navigate to it** — the whole client replaced by a picture of the photo.
     * `data-drop` is the only feedback: a border, no words.
     */
    screen.addEventListener('dragover', (event) => {
      if (!this.canSendFiles || !event.dataTransfer?.types.includes('Files')) return
      event.preventDefault()
      event.dataTransfer.dropEffect = 'copy'
      screen.dataset.drop = 'on'
    })
    screen.addEventListener('dragleave', (event) => {
      // Only when the pointer has actually left the pane. `dragleave` also fires
      // for every child crossed on the way over it, and clearing on those makes
      // the border strobe under a moving cursor.
      if (event.target === screen) delete screen.dataset.drop
    })
    screen.addEventListener('drop', (event) => {
      delete screen.dataset.drop
      if (!this.canSendFiles) return
      const files = Array.from(event.dataTransfer?.files ?? [])
      if (files.length === 0) return
      event.preventDefault()
      void this.sendFiles(files)
    })

    this.terminal = terminal
    /*
     * Held from the moment the surface exists, before a byte reaches it.
     *
     * `quiet` is passed because this client is always talking to another
     * machine: the run of `replay` frames ends without saying so, so silence is
     * what says the backlog is over. The ceiling inside `holdUntilFilled` is the
     * promise that this can only ever delay a terminal and never hide one.
     */
    this.backfill = holdUntilFilled(terminal, terminal.element, { quiet: QUIET_MS })
    this.keybar = keybar
    this.keybarDock = dock
    this.terminalScreen = screen
    // Before the first paint, so a laptop never sees the row appear and go. It
    // is a fill of the frame's height either way, and a bar that flashes on for
    // one frame reads as a rendering fault rather than as a decision.
    this.applyKeyBar()
    terminal.setLive(this.state.phase === 'online')
  }

  private showTerminalScreen(): void {
    if (this.terminalScreen === null) return
    const chat = this.chatView
    if (chat === null) {
      this.content.replaceChildren(this.terminalScreen)
      return
    }
    /*
     * One of the two is in the pane, and the bar stays above both.
     *
     * The usage, context and account chips are facts about the *session*, not
     * about which way it is being read, so they do not move or disappear when
     * the mode changes.
     */
    const bar = this.sessionBar?.element
    // The control cluster follows the same rule for the same reason: the model
    // a session runs is a fact about the session, whichever way it is read.
    const controls = this.sessionControls?.element
    if (this.chatMode) {
      const composer = this.chatComposer
      composer?.render()
      this.terminalScreen.replaceChildren(
        ...(bar ? [bar] : []),
        ...(controls ? [controls] : []),
        chat.element,
        ...(composer ? [composer.element] : []),
      )
    } else {
      /*
       * The dock comes from the field, never from a `querySelector` on the pane.
       *
       * Switching to chat takes it out of the document, so a lookup on the way
       * back finds nothing and the key bar is gone for the life of the session —
       * which is exactly what the first render of this did, and what looking at
       * it caught. `this.keybarDock` holds the node whether or not it is
       * attached, which is the whole reason the field exists.
       */
      const terminal = this.terminal?.element
      const dock = this.keybarDock
      this.terminalScreen.replaceChildren(
        ...(bar ? [bar] : []),
        ...(controls ? [controls] : []),
        ...(terminal ? [terminal] : []),
        ...(dock ? [dock] : []),
      )
      // The dock's own `hidden` is decided by the keyboard fit, not by the swap.
      this.applyKeyBar()
    }
    this.content.replaceChildren(this.terminalScreen)
  }

  /* -------------------------------------------------------------- files -- */

  /* --------------------------------------------------------------- chat -- */

  /**
   * Whether the conversation can be read from here, right now.
   *
   * The same four facts `canSendFiles` asks and for the same reason: a session
   * on screen, an attach that went out, a socket, and a machine that said it can
   * read a transcript. One place, so the button and the frames cannot disagree
   * about whether the gesture will work.
   */
  private get canReadChat(): boolean {
    return (
      this.screen === 'terminal' &&
      this.attachedId !== null &&
      this.state.phase === 'online' &&
      this.capabilities.includes('chat')
    )
  }

  /**
   * Draw the toggle, or take it away.
   *
   * The glyph is the **destination**, which is his correction rather than a
   * preference: *"chat icon should be when I am on the terminal mode. And when I
   * am on the chat mode, then it should show the terminal icon."* So the icon and
   * the label always name where the press goes.
   *
   * Hidden outright when the far machine has looked and found no transcript for
   * this folder. That is a real state — a session running a shell, an agent that
   * has never written one — and the alternative is a button that opens an empty
   * screen with nothing on it to say why.
   */
  private renderModeButton(): void {
    const empty = this.chatView !== null && this.chatView.hasTranscript === false
    this.modeButton.hidden = !this.canReadChat || (empty && !this.chatMode)
    if (this.modeButton.hidden) return
    const going = this.chatMode ? 'terminal' : 'chat'
    const label = going === 'chat' ? 'Read this session as a conversation' : 'Back to the terminal'
    this.modeButton.setAttribute('aria-label', label)
    this.modeButton.title = label
    this.modeButton.replaceChildren(modeIcon(going))
  }

  /**
   * Ask for the tail once the session has stopped printing.
   *
   * Debounced rather than sent per frame: one answer of an agent CLI is hundreds
   * of `output` frames, and a file read per frame would be hundreds of round
   * trips across a relay for one paragraph.
   */
  private armChatTail(): void {
    if (this.chatTailTimer !== null) clearTimeout(this.chatTailTimer)
    this.chatTailTimer = window.setTimeout(() => {
      this.chatTailTimer = null
      this.askChat(true)
    }, 900)
  }

  /** Swap the pane, and ask for the conversation the first time. */
  private toggleMode(): void {
    if (!this.canReadChat) return
    this.chatMode = !this.chatMode
    if (this.chatMode) this.askChat(false)
    this.showTerminalScreen()
    this.renderHeader()
    if (!this.chatMode) {
      // The emulator was in a hidden subtree and cannot have measured itself
      // while it was. Fitting before the frame lands would size it to zero and
      // reflow scrollback that has already been painted.
      requestAnimationFrame(() => {
        this.terminal?.fit()
        this.terminal?.focus()
      })
    }
  }

  /**
   * Ask for the conversation, or for what has changed since.
   *
   * `tail` false is what opening the view asks; true is what a session going
   * quiet asks. Nothing is asked while the chat pane is not on screen — a
   * terminal somebody is typing into must not be sending a file read across a
   * relay after every burst of output.
   */
  private askChat(tail: boolean): void {
    const id = this.attachedId
    if (id === null || !this.canReadChat) return
    const rid = `chat-${(this.chatRid += 1)}`
    if (this.connection?.send({ t: 'chat.read', rid, id, tail }) !== true) return
    this.chatAsked.add(rid)
  }

  /**
   * Whether a file can be sent from here, right now.
   *
   * Four facts, and every one of them is load bearing: a session on screen, an
   * attach that went out, a socket, and a machine that said it takes uploads.
   * They are asked in one place so the button and the drop handler cannot
   * disagree about whether the gesture will work.
   */
  private get canSendFiles(): boolean {
    return (
      this.screen === 'terminal' &&
      this.attachedId !== null &&
      this.state.phase === 'online' &&
      this.capabilities.includes('upload')
    )
  }

  /**
   * Send what was picked, and type each path at the prompt as it lands.
   *
   * ## Why the path is typed and nothing else
   *
   * It is what iOS does with the path the Mac answers with, what the desktop's
   * own drop handler does, and what every terminal on every platform does with a
   * dropped file. The gesture was the person's, so typing on the back of it is
   * their text rather than an announcement; no Return is sent, because what to do
   * with the file is their decision and the prompt is where they make it.
   *
   * ## Why one at a time
   *
   * The desktop serves one upload per connection. Four photos therefore cross in
   * order and fill the prompt as they go, so a failure part way through leaves
   * the ones that did land on the line — which is true, and more useful than
   * discarding them to keep the gesture atomic.
   */
  private async sendFiles(files: readonly File[]): Promise<void> {
    if (files.length === 0) return
    if (!this.canSendFiles) {
      this.say('That session cannot take a file right now.')
      return
    }
    if (this.upload !== null) {
      // Refused rather than queued: see the field's own note.
      this.say('One file at a time — that one is still going.')
      return
    }
    for (const file of files) {
      const landed = await this.sendOneFile(file)
      if (!landed) return
    }
  }

  /**
   * One file, from the picker to the prompt.
   *
   * Resolves false on every failure — including the ones that never leave this
   * page — because the caller is a gesture somebody made and the only wrong
   * answer is silence.
   */
  private sendOneFile(file: File): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let settled = false
      const finish = (landed: boolean): void => {
        if (settled) return
        settled = true
        this.upload = null
        resolve(landed)
      }
      const upload = new Upload(file, {
        send: (message) => this.connection?.send(message) === true,
        onProgress: (progress) => {
          const line = transferLine(progress)
          // Held while it is crossing and cleared when it lands: the path
          // appearing at the prompt is the success signal, and a line saying it
          // worked would narrate something already on screen.
          this.say(line, progress.phase !== 'failed' && line !== '')
          if (progress.phase === 'failed') finish(false)
        },
        onLanded: (path) => {
          // Through the ordinary input path, so an armed Ctrl on the key bar is
          // spent the way it would be by any other typing, and the chunk cap
          // applies to a long path exactly as it does to a paste.
          this.sendInput(promptWord(path))
          finish(true)
        },
      })
      this.upload = upload
      upload.start()
    })
  }

  private destroyTerminal(): void {
    // First of all, and for the same reason the backfill is: it owns a timer,
    // and one firing into a pane that has gone would ask for a session nothing
    // is attached to.
    this.sessionBar?.destroy()
    this.sessionBar = null
    // For the same reason, and in the same breath: it owns timers of its own.
    this.sessionControls?.destroy()
    this.sessionControls = null
    this.chatView = null
    this.chatMode = false
    this.chatAsked.clear()
    if (this.chatTailTimer !== null) clearTimeout(this.chatTailTimer)
    this.chatTailTimer = null
    // Then the backfill, before the terminal it is holding is disposed: it owns
    // two timers, and one of them firing into a disposed emulator is a throw out
    // of a `setTimeout` that nothing catches.
    this.backfill?.stop()
    this.backfill = null
    this.keybar?.destroy()
    this.terminal?.dispose()
    this.keybar = null
    this.keybarDock = null
    this.terminal = null
    this.terminalScreen = null
  }

  /**
   * Everything this client puts on the terminal, through one door.
   *
   * Output frames, the exit line and an in-session refusal all come through
   * here, so a hold cannot be bypassed by whichever of them is added next. While
   * nothing is held this is exactly `terminal.write`.
   */
  private writeTerminal(data: string): void {
    if (this.backfill !== null) this.backfill.push(data)
    else this.terminal?.write(data)
  }

  /**
   * One keystroke or paste on its way to the desktop.
   *
   * Characters are folded through the key bar's armed modifier first, so a
   * Ctrl tapped on the toolbar combines with the letter typed on the soft
   * keyboard — the only place those two can meet, because the soft keyboard
   * reports no modifier we did not press ourselves.
   */
  private sendInput(data: string): void {
    if (this.attachedId === null) return
    const folded = data.length === 1 && this.keybar !== null ? this.keybar.handleCharacter(data) : data
    this.writeToSession(folded)
  }

  /**
   * Bytes into the session, with no key bar in the way.
   *
   * The composer writes through here rather than through `sendInput`, and the
   * difference is one line: `sendInput` folds a single character through the key
   * bar's armed modifier, which is right for a keystroke and wrong for the
   * carriage return that submits a chat message. A Ctrl left armed on the
   * toolbar would turn that `\r` into something else on its way out — a
   * modifier the person armed for the terminal, applied to a send button they
   * pressed in another view.
   */
  private writeToSession(data: string): void {
    if (this.attachedId === null) return
    for (const chunk of chunkInput(data)) {
      if (!this.connection?.send({ t: 'input', id: this.attachedId, data: chunk })) {
        // Refused rather than queued. Say so where the user is looking instead
        // of letting them believe a keystroke landed.
        //
        // Built from the connection's own sentence rather than from whatever
        // this banner is currently showing: appending to the latter meant every
        // key pressed while the socket was down added another copy of this
        // clause, and someone typing a command into a dead terminal produced a
        // banner of a dozen identical sentences.
        const detail = this.connection?.current().detail ?? this.state.detail
        this.state = { ...this.state, detail: `${detail} That keystroke was not sent.` }
        this.renderBanner()
        return
      }
    }
  }

  /**
   * Forget everything — every machine, and this browser's own identity with it.
   *
   * Reached from the last machine's Forget, and from nowhere else. With several
   * machines the row's Forget is `forgetMachine`, which leaves the others alone;
   * this is the state where there is nothing left to leave alone, and a browser
   * holding no machines is an unpaired browser.
   */
  private forget(): void {
    clearPairing(this.stores)
    clearMachineBook(this.stores)
    this.book = NO_MACHINES
    this.notice = null
    this.openRow = null
    this.closing = null
    this.renamingPort = null
    this.renamingMachine = null
    this.pairingAnother = false
    // Back to the safe answer. The next pairing on this browser asks again, and
    // it must not inherit "remember" from a machine this person has just said is
    // not theirs any more.
    this.remember = 'this-tab'
    this.portBook.setLifetime(this.remember)
    // The route goes with the machine. Keeping a relay endpoint after the user
    // has said "that is not my machine any more" would put its host id under the
    // title on the pair screen.
    this.endpoint = DIRECT
    // Deliberately reset here and deliberately *not* reset on a refusal. This
    // is the user saying "that is not my machine any more", so the next pair
    // screen must not still be naming it; a refused credential, by contrast, is
    // the same computer at the same address telling us something, and keeping
    // its noun makes the re-pair read correctly.
    this.hostPlatform = 'unknown'
    this.capabilities = []
    this.hostAppVersion = ''
    this.hostKind = null
    this.folders = null
    this.picking = false
    this.awaitingCreate = false
    this.forgetLocalhost()
    this.stopAllWatch()
    // One secret now, not two, and `clearPairing`/`clearMachineBook` at the top
    // of this method already took it. A browser somebody has just said is not
    // theirs used to be left holding a second credential — the more powerful
    // one, the one that could change things rather than merely read them — and
    // the way that is guaranteed not to happen again is that there is no second
    // credential to leave behind.
    this.forgetCopilot()
    this.sessions = []
    this.activity.clear()
    this.attachedId = null
    this.destroyTerminal()
    this.connection?.stop()
    this.connection = null
    this.screen = 'pair'
    this.render()
  }

  /* ------------------------------------------------------------ viewport -- */

  /**
   * Keep the frame inside the visual viewport.
   *
   * The soft keyboard on iOS does not shrink the layout viewport, so a bar at
   * the bottom of a full-height frame ends up underneath the keys. The visual
   * viewport is the part actually on screen; sizing to it puts the key bar
   * directly above the keyboard, which is the whole point of having one.
   */
  private watchViewport(): void {
    const viewport = window.visualViewport
    const apply = (): void => {
      if (viewport !== null) {
        this.root.style.height = `${viewport.height}px`
        this.root.style.transform = `translateY(${viewport.offsetTop}px)`
        const keyboard = window.innerHeight - viewport.height - viewport.offsetTop
        // The keyboard already covers the home-indicator strip; padding for it
        // as well lifts the bar visibly off the keys.
        this.root.style.setProperty('--dock-safe', keyboard > 24 ? '0px' : 'env(safe-area-inset-bottom, 0px)')
      }
      this.terminal?.fit()
    }

    if (viewport !== null) {
      viewport.addEventListener('resize', apply)
      viewport.addEventListener('scroll', apply)
    }
    window.addEventListener('resize', apply)
    window.addEventListener('orientationchange', () => requestAnimationFrame(apply))
    apply()
  }
}

/* --------------------------------------------------------------- bootstrap -- */

const root = document.getElementById('app')
if (root !== null) new Deck(root).start()

/**
 * The shell, and only the shell.
 *
 * Registered after load so it never competes with the first paint on a phone
 * that has just been handed a QR code. Failure is silent on purpose: a client
 * that works but cannot be installed offline is fine, and an error dialog about
 * a service worker is not something anyone can act on.
 */
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => undefined)
  })
}
