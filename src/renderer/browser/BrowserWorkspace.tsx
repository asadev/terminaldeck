import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { hereName } from '../machines/types'
import { AnchoredPopup } from './AnchoredPopup'
import { BrowserMenu } from './BrowserMenu'
import { DownloadsPanel } from './DownloadsPanel'
import { ProfileMenu } from './ProfileMenu'
import { CapturePopup } from './CapturePopup'
import { DeviceBar } from './DeviceBar'
import { PasswordOffer } from './PasswordOffer'
import { SignInBanner } from './SignInBanner'
import { DrawLayer, type DrawSurface } from './DrawLayer'
import { DriveBanner } from './DriveBanner'
import { DrawPanel } from './DrawPanel'
import { RecorderPanel } from './RecorderPanel'
import { ScreenshotPopup } from './ScreenshotPopup'
import { HistoryPanel } from './HistoryPanel'
import { ProfileSettings } from './ProfileSettings'
import { WorkersPanel } from './WorkersPanel'
import { resolveWorkersApi, workersAvailable } from './workers-bridge'
import { SessionModal } from './SessionModal'
import { Toolbar } from './Toolbar'
import {
  modeChanges,
  modeHint,
  toggleMode as nextModes,
  type BrowserMode,
  type BrowserModes,
} from './modes'
import { undoMark, type Mark, type MarkKind } from './marks'
import {
  drawAvailable,
  readFrame,
  readMarkedShot,
  resolveDrawApi,
  type DrawApi,
  type PageFrame,
} from './draw-bridge'
import {
  downloadsAvailable,
  downloadsBadge,
  readDownloadsView,
  resolveDownloadsApi,
  type DownloadsView,
} from './downloads-bridge'
import { anchorInWindow, type Box } from './popup-anchor'
import {
  historyAvailable,
  passwordsAvailable,
  profilesAvailable,
  readProfileState as readProfiles,
  readSignInTrouble,
  readVisitList,
  resolveAccountsApi,
  signInHelpAvailable,
  type HistoryVisit,
  type ProfileState,
  type SignInTrouble,
} from './accounts-bridge'
import { useAgentTarget } from './useAgentTarget'
import type { AgentServerShell, AgentSessionBridge } from './agent-target'
import {
  appCanvasColor,
  humanError,
  missingBridgeMethods,
  recordingAccent,
  resolveBrowserBridge,
  type BrowserBridge,
  type BrowserCapture,
  type BrowserTabState,
  type Bounds,
  type RecordingState,
  type ScreenshotResult,
} from './bridge'
import {
  FIT_ID,
  MOBILE_USER_AGENT,
  fitInto,
  parseDimension,
  presetById,
  sizeFor,
  stepZoom,
  type Orientation,
  type Rect,
  type Size,
} from './devices'
import {
  asIsolationKey,
  isolationAvailable,
  resolveIsolationApi,
  type IsolationApi,
} from './isolation-bridge'
import {
  claimDriveOpen,
  driveAvailable,
  IDLE_DRIVE,
  readDriveOpen,
  readDriveStatus,
  resolveDriveApi,
  type DriveStatus,
} from './drive-bridge'
import { resolveOmnibox } from './omnibox'
import { browserOverlayDom, isCovered, watchOverlays, type Overlay } from './overlay-watch'
import { ConnectSessionButton } from './BindChip'
import { MachinePicker } from './MachinePicker'
import { forgetFrontPage, setFrontPage } from './front-page'
import { forgetWindowMachine, setWindowMachine } from './window-machine'
import {
  destinationFor,
  differentPortNote,
  inTheWay,
  loopbackPort,
  lostMachine,
  machineChoices,
  readMachines,
  moveFor,
  reachedAddress,
  readReach,
  resolveMachinesApi,
  servedBy,
  THIS_MACHINE,
  type MachineChoice,
  type ReachedPort,
  type ReachOpened,
} from './machines-bridge'
import {
  portSourceFor,
  readServerPorts,
  readServers,
  resolveServersApi,
  serverChoices,
  type ServerPortsState,
  type ServerRow,
} from './server-machines'
import { barServed } from './served-mark'
import { StartPage, type PortSource } from './StartPage'
import {
  closeTab as closeInList,
  moveTab,
  newTab,
  openTab,
  tabForId,
  tabTitle,
  withTab,
  withTabId,
  type WorkspaceTab,
} from './tabs'
import './BrowserWorkspace.css'

/* ------------------------------------------------------------------ types -- */

export interface BrowserWorkspaceProps {
  /**
   * Whether this panel is the pane on screen.
   *
   * False hides the *whole* panel — its own chrome as well as the native pages
   * — without tearing anything down. Both halves matter. The panel is a plain
   * in-flow block in `.panes` while terminals are absolutely positioned over
   * it, so a panel that only parked its pages kept painting its toolbar in the
   * gap around the terminal, and pushed a chat view for the same tab clean off
   * the bottom of the window. That is one bug wearing two faces: a session tab
   * that renders the browser forever, and browser chrome ghosting over another
   * tab's terminal.
   */
  visible?: boolean
  /**
   * Park the pages but keep the panel.
   *
   * Separate from `visible` because a dialog is not a tab switch. The pages are
   * native views layered ABOVE the HTML, so every modal opens behind them and
   * has to park them — but the panel itself is what the dialog is over, and
   * hiding that too would blank the workspace behind the dialog.
   */
  parkPage?: boolean
  /**
   * What this page is called, whenever that changes.
   *
   * The panel's own tab strip is gone — a browser page is a row in the sidebar
   * now — so the only place the page's title can be read is that row, and the
   * row is given a label once, at open. Without this every browser row in the
   * sidebar reads "New tab" forever, which is precisely the unusable strip
   * `tabTitle` was written to prevent.
   */
  onTitle?: (title: string) => void
  /**
   * Settings → Browser → Start page: where a new page opens.
   *
   * A prop rather than something read here, because it is a declared setting
   * and the schema is the only place a setting is allowed to live. This panel
   * used to keep its own copy in localStorage, so "Start page" in Settings and
   * "Set as home" in the panel were two controls over two different values and
   * the Settings one changed nothing.
   */
  startUrl?: string
  /**
   * Where *this* page opens, overriding the start page for its first tab only.
   *
   * Set when a link asked for this workspace — a repository in the GitHub
   * panel, a `target="_blank"` in another page. Separate from {@link startUrl}
   * rather than folded into it, because Home and "Set as start page" must keep
   * meaning the start page: a workspace opened on a pull request whose Home
   * button then went back to that pull request would have quietly redefined
   * home for one window.
   *
   * Read once, at mount. Changing it afterwards does nothing on purpose — the
   * address is the page's from that moment on, and a prop that could yank a
   * live page somewhere else is a navigation nobody asked for.
   */
  initialUrl?: string
  /**
   * Whose network this page belongs on — the machine of the session that asked
   * for it, when a session did.
   *
   * Empty, and by default absent, for every page opened from the globe or by a
   * session on this computer.
   *
   * ## What it is for
   *
   * Asad, on the thing he called his biggest problem:
   *
   *   > *"as soon as I tell them open a browser, they just directly go inside my
   *   > PC and they opens. If I tell a remote session to open a browser, they
   *   > open the browser inside wherever they are actually in the main machine,
   *   > not in here in this one."*
   *
   * It collides with a rule he set earlier and which `localhost-reach.ts` quotes
   * as its reason for existing — *"keep the same one browser window for every
   * device… shape of the application should not be changing for local and remote
   * devices"* — and the rule wins. So this does not open a browser process over
   * there. It makes the page in **this** window belong to that machine: the
   * picker points there, so `http://localhost:3000` from a session on his PC is
   * his PC's `3000` through the tunnel, and the machine chip on the tab names
   * his PC because the tunnel is what `servedBy` reads.
   *
   * ## Why it is only a request until the machine answers
   *
   * It is applied when — and only when — that machine turns up in the picker's
   * own list and is reachable. A picker set to a machine this window has not
   * heard of would be reset by `lostMachine` a frame later with *"that machine
   * is no longer paired"*, and, worse, a label naming a machine whose tunnel is
   * not open would be a page claiming to be somewhere it is not. See the effect
   * that consumes it.
   *
   * Read once, at mount, like {@link BrowserWorkspaceProps.initialUrl} above and
   * for the same reason.
   */
  initialMachineId?: string
  /**
   * The shell tab id of the window this panel *is*.
   *
   * This panel had no id of any kind until 2026-08-19, because nothing outside
   * it had ever needed to name one browser window as against another. A session
   * ↔ browser binding needs exactly that: `B2` is a fact about one window, and
   * the only handle that is one-to-one with what a person calls a browser
   * window — and that lasts its whole life — is the id `App.tsx` mints in
   * `newBrowserTab`. The main-process view id underneath is per *page* and is
   * re-minted when the isolation switch closes and reopens the view, so a
   * binding keyed on it would lose its number the first time somebody pressed
   * Isolated.
   *
   * Optional, because a host that has no notion of windows (the tests, a future
   * embedder) is not obliged to invent one; without it this panel simply never
   * reports itself and can never be bound.
   */
  tabId?: string
  /** Persist a new start page — the panel's own "set as start page" button. */
  onStartUrl?: (url: string) => void
  /**
   * Open Settings → Browser, for the ⋯ menu's `Settings` row.
   *
   * A door rather than a copy. Settings → Browser already holds the start page,
   * the cookie controls and the profiles (`settings/sections/BrowserSection`),
   * and the one thing missing was any way to reach it from inside the browser
   * itself — *"then settings we have"*, said while looking at Chrome's own
   * `chrome://settings`. The panel does not know how Settings is opened, which
   * is why this is a prop and not a call: it is the shell's window, and this is
   * a page inside it.
   *
   * Absent on a host with no Settings to open — the harness, an embedder — and
   * then the row is simply not drawn, which is this panel's standing rule for a
   * control that could not do anything.
   */
  onSettings?: () => void
  /**
   * Kept for hosts that still pass it; nothing in this panel calls it.
   *
   * It used to be the only route out of the browser, and it went to
   * `activeSessionId` — whichever session happened to be focused behind the
   * page. That is the "sends to a random session" he reported, and it cannot be
   * fixed from the host: the host does not know which session *this browser
   * window* is meant to talk to, because until 2026-08-16 nothing did. The panel
   * now asks, remembers the answer per window, and writes to that session
   * itself. See `useAgentTarget`.
   *
   * @deprecated Choose a session in the popup instead.
   */
  onSendToAgent?: (text: string) => void
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: BrowserBridge
  /**
   * The session-listing half of the preload, injectable for the same reason.
   *
   * Separate from `bridge` because it is a different subject — these are the
   * app's sessions, not this browser's tabs — and because a preload that has
   * one and not the other should cost the picker rather than the browser.
   */
  sessionBridge?: AgentSessionBridge | null
  /**
   * The terminals this window has open on servers, for the send picker.
   *
   * A prop rather than something this panel reads for itself, because there is
   * nothing to read: a server runs no copy of this app, so a shell on one exists
   * only while this window is holding its connection and the window's own list
   * is the whole of it (`machines/servers/server-sessions.ts` opens with that
   * argument). Without it, the one session running on the very machine serving
   * the page on screen was the one session the picker could not offer — which is
   * what Asad found on 2026-08-21: *"It is not even showing this session, by the
   * way, Office PC session."*
   *
   * Absent is an empty list, which is the honest answer for a host with no
   * servers area and for every test that mounts this panel on its own.
   */
  serverShells?: readonly AgentServerShell[]
  /**
   * Per-tab isolation, which is optional rather than required.
   *
   * Separate from `bridge` because a preload without it should cost one toggle,
   * not the whole browser panel — see `isolation-bridge.ts`.
   */
  isolation?: IsolationApi
  /**
   * Draw mode's two channels, optional for exactly the same reason.
   *
   * Listing them in `BRIDGE_METHODS` would blank the entire browser panel on any
   * build whose preload predates them, which is every build until the one that
   * ships this. `draw-bridge.ts` spells that out.
   */
  draw?: DrawApi
}

const EMPTY_RECORDING: RecordingState = {
  recording: false,
  steps: [],
  text: '',
  line: '',
  truncated: false,
}

/** The parts of a main-process state that belong on a strip entry. */
function patchFrom(state: BrowserTabState): Partial<WorkspaceTab> {
  return {
    id: state.id,
    url: state.url,
    label: state.label,
    title: state.title,
    loading: state.loading,
    canGoBack: state.canGoBack,
    canGoForward: state.canGoForward,
    inspecting: state.inspecting,
    error: state.error,
    // Older main processes did not send this. `=== true` rather than a truthy
    // read, so an absent field means "no error page" instead of `undefined`
    // leaking into a boolean prop.
    failed: state.failed === true,
  }
}

/**
 * Is this tab showing Terminal Deck's own page rather than a website?
 *
 * Two cases, one answer, because the native view has to be hidden for both: a
 * tab that has not been anywhere yet, and a tab whose load failed — where the
 * document in the view is Chromium's red error page and the whole point of the
 * change is that nobody should ever see it.
 */
export function onStartPage(tab: WorkspaceTab): boolean {
  return !tab.url || tab.url === 'about:blank' || tab.failed
}

/** Everything that decides whether a native page is composited right now. */
export interface PageVisibility {
  /** This tab is the one the panel is showing. */
  isActive: boolean
  /** The panel's own tab is the one the window is showing. */
  visible: boolean
  /** An app-level dialog is up. */
  parkPage: boolean
  /** The panel's cookies dialog is up. */
  sessionOpen: boolean
  /** Some HTML surface is over the page's rectangle — see `overlay-watch.ts`. */
  covered: boolean
  /**
   * Draw mode: a canvas is over the page's rectangle.
   *
   * Stated here rather than left to `covered`, and the difference is the whole
   * design of draw mode. `covered` is discovered a frame *after* the surface
   * appears, because it is geometry read by an observer — fine for a tooltip
   * drifting over a page, wrong for this, where the one frame in between is the
   * live website receiving a pointerdown that was meant for the canvas. Parking
   * it from the state that opened the canvas closes that window entirely, which
   * is what "the overlay must not receive the page's input while drawing"
   * actually requires.
   */
  drawing: boolean
  /**
   * A screenshot popup is up.
   *
   * Also technically covered by `covered`, and also not good enough for the same
   * reason. Draw mode ends by parking the page, saving, and opening this popup:
   * without this flag the page unparks for the frame between those two states
   * and the website flashes back over the picture the user is about to send.
   */
  shotOpen: boolean
}

/**
 * Should this tab's native view be composited?
 *
 * Pulled out of the effect and exported because it is the whole of both bugs
 * this file was changed for, and because an effect is the one place a rule
 * cannot be tested — this project's test run has no DOM, so effects never fire.
 *
 * Every one of these is a hide, and each is a different reason:
 *
 *  - not the active tab, or not the visible panel: an ordinary tab switch;
 *  - `parkPage` / `sessionOpen`: a dialog, which is HTML and would otherwise
 *    open *behind* the website;
 *  - `covered`: a menu, a tooltip or the peeked rail landing on the page —
 *    the same fault as a dialog, but transient, so it is decided by geometry
 *    rather than by a flag;
 *  - `drawing` / `shotOpen`: this panel's own surfaces over the page. Both would
 *    eventually be caught by `covered`, and "eventually" is a frame too late —
 *    see their comments;
 *  - `onStartPage`: there is no page to show, or the only thing in the view is
 *    Chromium's error document.
 */
export function pageVisible(tab: WorkspaceTab, state: PageVisibility): boolean {
  return (
    state.isActive &&
    state.visible &&
    !state.parkPage &&
    !state.sessionOpen &&
    !state.covered &&
    !state.drawing &&
    !state.shotOpen &&
    !onStartPage(tab)
  )
}

function rectOf(node: HTMLElement | null): Rect {
  if (!node) return { x: 0, y: 0, width: 0, height: 0 }
  const box = node.getBoundingClientRect()
  // CSS pixels, which is the unit setBounds() wants.
  return {
    x: Math.round(box.left),
    y: Math.round(box.top),
    width: Math.round(box.width),
    height: Math.round(box.height),
  }
}

const CUSTOM_ID = 'custom'

/** Drop one tab's entry from a per-tab map, without mutating the old one. */
/**
 * A prop that claims to be a URL, or an empty string.
 *
 * The one narrowing that has to happen on this side of the props, because
 * everything downstream of it — the tab draft, the omnibox, the address bar —
 * is written against a string and throws during render if it is handed
 * anything else. See the note on `openAtRef` for the crash this comes from.
 */
function asUrl(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function without<T>(map: Record<string, T>, key: string): Record<string, T> {
  if (!(key in map)) return map
  const next = { ...map }
  delete next[key]
  return next
}

/* -------------------------------------------------------------- component -- */

/**
 * A real browser beside the agent: several tabs, each a live Chromium view, on
 * a session that keeps you logged in between restarts.
 *
 * ## The one structural fact everything else follows from
 *
 * The pages are native views owned by the main process, floating *over* this
 * React tree at a rectangle this component reports. So:
 *
 * - the stage below is an empty div whose only job is to be measured;
 * - every panel is laid out around the stage rather than over it, because
 *   nothing here can paint on top of a native layer;
 * - opening the cookies dialog parks the view, or the dialog would open behind
 *   the website;
 * - resizing for a phone means giving the view a 390px rectangle, which makes
 *   the page's own media queries fire. It is a real viewport, not a scaled
 *   picture of a wide one.
 *
 * ## Tabs are created one at a time, on purpose
 *
 * Each tab needs two round trips — create it, then claim it so the extras
 * (zoom, screenshots, the recorder) know which view belongs to which id. The
 * claim resolves to "the newest view nobody has claimed", which is only
 * unambiguous while creation is serialised. `queue` below is what serialises it.
 */
export function BrowserWorkspace({
  visible = true,
  parkPage = false,
  onTitle,
  tabId,
  startUrl = '',
  initialUrl = '',
  initialMachineId = '',
  onStartUrl,
  onSettings,
  bridge,
  sessionBridge,
  serverShells,
  isolation,
  draw,
}: BrowserWorkspaceProps) {
  const api = useMemo(() => bridge ?? resolveBrowserBridge(), [bridge])
  /*
   * One target per browser window, chosen by hand and remembered until changed.
   *
   * Deliberately at the top of the workspace rather than inside each popup: the
   * element popup, the flow panel and the screenshot popup all send to the same
   * place, and that is the whole of "that specific popup from that browser links
   * to one session".
   */
  const agent = useAgentTarget(sessionBridge, serverShells)
  const iso = useMemo(() => isolation ?? resolveIsolationApi(), [isolation])
  const drawApi = useMemo(() => draw ?? resolveDrawApi(), [draw])
  const driveApi = useMemo(() => resolveDriveApi(), [])
  const missing = useMemo(
    () => (bridge ? [] : missingBridgeMethods(typeof window === 'undefined' ? null : (window as unknown as { deck?: unknown }).deck)),
    [bridge],
  )

  const [tabs, setTabs] = useState<WorkspaceTab[]>([])
  const [activeKey, setActiveKey] = useState('')
  const [captures, setCaptures] = useState<Record<string, BrowserCapture>>({})
  const [recordings, setRecordings] = useState<Record<string, RecordingState>>({})
  const [zooms, setZooms] = useState<Record<string, number>>({})
  const [devtools, setDevtools] = useState<Record<string, boolean>>({})

  const [presetId, setPresetId] = useState(FIT_ID)
  const [orientation, setOrientation] = useState<Orientation>('portrait')
  const [customWidth, setCustomWidth] = useState('390')
  const [customHeight, setCustomHeight] = useState('844')
  const [deviceOpen, setDeviceOpen] = useState(false)
  const [mobileUa, setMobileUa] = useState(false)

  /*
   * The cookies dialog, and *whose* cookies.
   *
   * `null` is closed; a string is the profile id whose jar it is showing. It
   * used to be a boolean, because there was only ever one jar it could show —
   * the active one — which is the same limitation that made the profile menu a
   * list of names. Every row can open its own now.
   */
  const [sessionFor, setSessionFor] = useState<string | null>(null)
  const sessionOpen = sessionFor !== null
  const [shot, setShot] = useState<ScreenshotResult | null>(null)
  /*
   * Draw mode, as one nullable object plus what is on it.
   *
   * The frame is the whole mode: non-null means the page is parked, the canvas
   * is up and the toolbar button is lit. Keeping it as one value rather than a
   * boolean beside an image is what makes "drawing with no frame" — a canvas
   * over the app's empty ground with the website hidden behind it —
   * unrepresentable rather than merely unlikely.
   *
   * Not per tab, unlike captures and recordings. A page you have parked is a page
   * you are looking at; switching tabs leaves the mode, which is the same
   * decision the device bar and the cookies dialog already make.
   */
  const [frame, setFrame] = useState<PageFrame | null>(null)
  const [marks, setMarks] = useState<Mark[]>([])
  const [tool, setTool] = useState<MarkKind>('free')
  /** True while the composite is being written, so Send cannot be pressed twice. */
  const [saving, setSaving] = useState(false)
  const surface = useRef<DrawSurface | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  /*
   * Who is holding the page the copilot drives.
   *
   * Held per panel even though the drive is one object in the main process,
   * because a panel that is not the one holding the driven tab still needs to
   * know: `idle` is what makes the banner absent, and an absent banner is how
   * every other browser row in the sidebar stays exactly as it was.
   */
  const [drive, setDrive] = useState<DriveStatus>(IDLE_DRIVE)
  const [copied, setCopied] = useState(false)

  /*
   * Everything that used to live at the bottom of this panel, and the two
   * features he asked for while he was there.
   *
   * *"Remove everything from the bottom. I need a clear view of the websites.
   * Whatever is required should be on the top right corner."* The band under
   * the stage is gone; these four pieces of state are where its contents went.
   *
   *  - `menuAnchor` is the toolbar's action group, measured when a popup opens
   *    rather than kept in state, so a resized window cannot leave a popup
   *    pointing at where a button used to be.
   *  - `flowOpen` is the recorded flow, as a popup. It deliberately does not
   *    open *while* recording: a popup here parks the native page — see
   *    `AnchoredPopup` — so showing the steps live would hide the very website
   *    the person is recording themselves using.
   *  - `trouble` is what Google is doing to a sign-in on this page.
   *  - `offer` is a login a page just submitted, waiting to be saved. The
   *    password itself is never here; see `browser-passwords.ts`.
   */
  const [menuOpen, setMenuOpen] = useState(false)
  const [menuAnchor, setMenuAnchor] = useState<Box>({ x: 0, y: 0, width: 0, height: 0 })
  /*
   * Profiles, which are now a button on the bar rather than a block inside ⋯.
   *
   * *"we can have these profiles over here as icon, so we can switch between
   * profiles also if we want to."* `profileName` is held here only so the
   * button's hover label can say which profile is on — the menu reads the state
   * for itself when it opens, and this is refreshed whenever it closes, so the
   * two cannot disagree for longer than one menu.
   */
  const [profileOpen, setProfileOpen] = useState(false)
  /*
   * The whole stored list, not a name and a map of names.
   *
   * A dialog opened from a row has to be titled with that row, badged with that
   * row's own character, and — for the settings section — handed the row itself
   * to edit. Holding the state once, read in the same pass the active name is
   * read in, is what stops a second round trip leaving a header blank for a
   * frame, and what stops three copies of the same list disagreeing.
   */
  const [profiles, setProfiles] = useState<ProfileState | null>(null)
  /**
   * Whose settings section is open, and whose history is — profile ids, or null.
   *
   * Two states rather than one "what is open", because the section opens the
   * history and expects to still be there behind it.
   */
  const [settingsFor, setSettingsFor] = useState<string | null>(null)
  const [historyFor, setHistoryFor] = useState<string | null>(null)
  /** Earlier addresses matching the draft in the bar. Empty draws no list. */
  const [suggestions, setSuggestions] = useState<readonly HistoryVisit[]>([])
  const [flowOpen, setFlowOpen] = useState(false)
  const [trouble, setTrouble] = useState<SignInTrouble | null>(null)
  const [troubleFor, setTroubleFor] = useState('')
  const [offer, setOffer] = useState<{ id: string; origin: string; username: string } | null>(null)
  const [offerNote, setOfferNote] = useState('')
  const accounts = useMemo(() => resolveAccountsApi(), [])
  /*
   * Worker profiles, on a bridge of their own.
   *
   * Separate from `accounts` for the reason `accounts-bridge.ts` gives about
   * itself: a preload older than this feature contributes what it has, and the
   * panel simply is not offered. A name added to `BRIDGE_METHODS` would blank
   * the whole browser panel on such a build instead.
   */
  const workersApi = useMemo(() => resolveWorkersApi(), [])
  const [workersOpen, setWorkersOpen] = useState(false)
  const [focusToken, setFocusToken] = useState(0)

  /*
   * Downloads.
   *
   * Held here, in the panel, rather than read when the popup opens: the button
   * on the bar is drawn from the same list, and it has to appear the moment a
   * file starts arriving — which is the whole of *"a downloads indicator
   * appears"*. One subscription feeds both, so the bar and the popup cannot
   * disagree about what has happened.
   */
  const downloads = useMemo(() => resolveDownloadsApi(), [])
  const [downloadsView, setDownloadsView] = useState<DownloadsView>(() => readDownloadsView(null))
  const [downloadsOpen, setDownloadsOpen] = useState(false)

  /*
   * ---------------------------------------------------------------------------
   * The machine this address bar is talking to.
   *
   * *"I should be able to type and reach the devices which are not here on this
   * device but they are from the other remote device… maybe give a drop down
   * next to somewhere here with the bar, to choose which device we are talking
   * to right now."*
   *
   * Per **panel**, not per tab. It is a mode for what you are about to type, and
   * a tab already carries where it went — the badge in the address bar reads the
   * machine back off the URL, so a tab opened on another machine keeps saying so
   * however the picker is set afterwards. Per-tab would mean the answer to "which
   * machine am I typing at" changed when you clicked a different tab, which is
   * the shape-changing this whole item is against.
   *
   * `machineView` is subscribed rather than polled. `machines:state` is pushed on
   * every connect, disconnect, session change and port list, which is everything
   * this reads — and a panel that polled a socket layer for it would be the
   * "they make the system heavier" he has objected to by name.
   * ---------------------------------------------------------------------------
   */
  const machinesApi = useMemo(() => resolveMachinesApi(), [])
  const [machineView, setMachineView] = useState<MachineChoice[]>([])
  /**
   * What this computer is called, off the same push the list arrives on.
   *
   * Kept beside the list rather than derived from it because it is not in it —
   * `machineChoices` deliberately holds only the *other* machines, and this
   * computer has no row, no id and no link to fail. It still has a name, and
   * every label on this bar that used to say "This machine" now says it. See
   * `hereName`.
   */
  const [here, setHere] = useState(() => hereName(null))
  const [machineId, setMachineId] = useState(THIS_MACHINE)
  /*
   * The other kind of machine, in the same picker.
   *
   * Two sources rather than one because the two are told apart by how they are
   * reached and by nothing else — a device runs this app at the far end and a
   * server does not, so one pushes its state up a connection this desktop
   * already holds and the other has to be asked. What a person sees is one
   * list: `machines` below is the concatenation, and every rule from that point
   * on — the picker, the refusal under a row, the badge, `destinationFor` —
   * runs over it without knowing which half a row came from.
   */
  const serversApi = useMemo(() => resolveServersApi(), [])
  const [serverList, setServerList] = useState<ServerRow[]>([])
  /**
   * What each server last said, keyed by its id.
   *
   * Empty for a server nobody has chosen, and that absence is the design rather
   * than a gap: §5.4 of the servers design says a server nobody is looking at
   * is not dialled at all, so filling this in for every stored server when a
   * browser tab opens would dial all of them to populate a dropdown nobody had
   * opened. Choosing one is what asks it.
   */
  const [serverPorts, setServerPorts] = useState<Record<string, ServerPortsState>>({})
  /**
   * Every tunnel this window has opened, so a loopback page can name its source.
   *
   * Kept for the life of the panel because the tunnel is: `machines/ipc.ts` holds
   * a listener open until the link drops, so a page opened ten minutes ago still
   * loads. Entries for a machine that has gone are dropped below, in the same
   * effect that gives the picker back — a badge naming a machine whose pages have
   * stopped answering is the one thing worse than no badge.
   *
   * A row leaves this list three ways, and a real close goes with each of them:
   * its machine went, `handBack` gave the port up, or another machine took that
   * number here — and `reachPort` hands the displaced one back in the same
   * breath. A row deleted while its tunnel is still answering would be a
   * listener nobody can see and nobody can name, standing on a number the bar
   * has stopped explaining.
   */
  const [opened, setOpened] = useState<ReachedPort[]>([])
  /**
   * The same list, readable from a callback that must not be rebuilt for it.
   *
   * `reachPort` runs inside a promise that started before the state it has to
   * consult; the same arrangement `tabsRef` and `activeRef` already use further
   * down, for the same reason.
   */
  const openedRef = useRef<ReachedPort[]>([])
  openedRef.current = opened
  /**
   * The caveat about a port number that could not be kept, when there is one.
   *
   * Its own state, and drawn in `.bw-said` rather than `.bw-error`, because it
   * is not a failure: the page opened, and this is the one thing about it that
   * will surprise somebody later. The critical colour is for things that did not
   * work, and a sentence in red about a page that loaded perfectly reads as one
   * that did not — the same argument the "saved, cleared, copied" line already
   * makes two bands down.
   */
  const [portNote, setPortNote] = useState('')

  /**
   * Where the first tab goes: what a link named, or the start page.
   *
   * Read inside the mount effect, which must not re-run when either changes —
   * and captured *once*, unlike the `startUrl` prop, which the Home button
   * reads live so that changing it in Settings takes effect straight away. This
   * one must not follow: a link opened this workspace at one address, and that
   * address stops being anyone's business the moment the page has loaded.
   */
  /*
   * Both props are declared `string` and neither is trusted to be one.
   *
   * Not defensive programming for its own sake — this exact crash was
   * photographed on 2026-08-17. `App.tsx`'s `newBrowserTab` grew a `url`
   * parameter, and two call sites still pass it straight to `onClick`, so a
   * click on "New browser tab" in the sidebar handed a `MouseEvent` in as the
   * address. It travelled as `WorkspaceTab.url`, arrived here as `initialUrl`,
   * became a tab's `draft`, and threw `input.trim is not a function` out of
   * `resolveOmnibox` **during render** — which an error boundary turns into
   * "New tab stopped working" and, because the workspace stays mounted under
   * other panes, into every other pane in the window reporting the same thing.
   *
   * TypeScript cannot catch it: `(url?: string) => void` is assignable to
   * `() => void`, so a handler that ignores its argument and one that reads it
   * are the same type. The fix belongs at the call sites and is being reported
   * there; this is the boundary refusing to render a URL bar around a value
   * that is not a string, which it should do whatever anybody upstream passes.
   */
  const openAtRef = useRef(asUrl(initialUrl) || asUrl(startUrl))

  const stageRef = useRef<HTMLDivElement | null>(null)
  const rootRef = useRef<HTMLDivElement | null>(null)
  /**
   * The toolbar's right-hand action group, which the popups that belong to the
   * group as a whole are placed against.
   *
   * `anchorPopup` slides a popup back inside the viewport, so anchoring to a
   * cluster that already sits at the right edge lands it in the top right corner
   * — which is where he asked for them — without each button carrying a ref.
   */
  const actionsRef = useRef<HTMLDivElement | null>(null)
  /**
   * The two buttons whose menus have to open *at* them, and not at the group.
   *
   *   > *"if I am clicking on three dots, it's opening very far from the three
   *   > dots. It should open just like here."*
   *
   * He was right and the arithmetic says why: `anchorPopup` left-aligns a popup
   * with the box it is given, and the box was the whole action group. With the
   * captions on, that group measured 554 pixels — so the menu opened flush with
   * its *left* edge, most of a toolbar away from the ⋯ it came out of. A group
   * is the correct anchor for a popup about the group and the wrong one for a
   * menu that belongs to one button in it.
   */
  const menuButtonRef = useRef<HTMLButtonElement | null>(null)
  const profileButtonRef = useRef<HTMLButtonElement | null>(null)
  const downloadsButtonRef = useRef<HTMLButtonElement | null>(null)
  const seq = useRef(0)
  /** Serialises create/claim so "the newest unclaimed view" stays unambiguous. */
  const queue = useRef<Promise<void>>(Promise.resolve())
  /**
   * Bumped every time the workspace tears down.
   *
   * Not a boolean. React StrictMode mounts twice in development, so a view
   * created by the first mount can finish being created *after* the second
   * mount has started — and an `alive` flag the remount has already set back to
   * true would wave that orphan straight through, leaving a native view
   * floating over the window with nothing pointing at it.
   */
  const generation = useRef(0)
  /** The pending "Copied" reset, so it can be cancelled rather than leaked. */
  const copyTimer = useRef<number | null>(null)
  const tabsRef = useRef<WorkspaceTab[]>([])
  tabsRef.current = tabs
  const activeRef = useRef('')
  activeRef.current = activeKey
  /**
   * `closeTab`, reachable from the drive-open effect above it.
   *
   * A ref rather than a dependency because `closeTab` is declared several
   * hundred lines further down, and a dependency array is evaluated during
   * render — naming it there is a temporal-dead-zone throw on the first paint,
   * not a lint warning. The same shape `titleRef` uses, for the same reason.
   */
  const closeTabRef = useRef<(key: string) => void>(() => {})

  const active = tabs.find((tab) => tab.key === activeKey) ?? null
  const recording = recordings[activeKey] ?? EMPTY_RECORDING
  const capture = captures[activeKey] ?? null
  const zoom = zooms[activeKey] ?? 1

  const enqueue = useCallback((work: () => Promise<void>): void => {
    queue.current = queue.current.then(work, work).catch(() => undefined)
  }, [])

  /*
   * Report the page's name upwards, so the sidebar row can wear it.
   *
   * The callback is held in a ref rather than depended on. Hosts pass an inline
   * arrow — a fresh function identity every render — and an effect that
   * depended on it would fire on every render, call back into the host, and
   * render again: this shipped for exactly one screenshot run and produced
   * "Maximum update depth exceeded" the moment a browser page opened.
   */
  const titleRef = useRef(onTitle)
  titleRef.current = onTitle
  const pageTitle = active ? tabTitle(active) : ''
  useEffect(() => {
    if (pageTitle) titleRef.current?.(pageTitle)
  }, [pageTitle])

  /*
   * Report this window to the main process: which page it is showing, where,
   * and what it is called.
   *
   * The main process owns the session ↔ browser relation — `main/browser-binding.ts`
   * says why — but it cannot see any of these three facts for itself. The shell
   * tab id is minted in the renderer; the view id is the one `browser:navigate`
   * takes, and it is what lets a URL from a session land in *this* window
   * without a renderer round trip; and the url and title are what the hook
   * answer prints, which is the reason they are only ever what the page said
   * about itself rather than anything derived here.
   *
   * On every change rather than once at mount, because all three change: the
   * page navigates, and the view id is replaced under a window that has not
   * moved when the isolation switch closes and reopens it. A binding holding a
   * stale view id is a URL that lands nowhere while the app answers that it
   * landed in `B1`.
   */
  const boundUrl = active?.url ?? ''
  const boundViewId = active?.id ?? null
  /*
   * Which machine is really behind this page — the fact the URL cannot carry.
   *
   * `servedBy` reads it back off the address against the tunnels this window
   * opened, so it survives a link inside the site, Back and a reload. Sent
   * upwards because a menu in the main process has to be able to group windows
   * by where they are actually running, and because the agent's own context
   * says it: a page on his PC wears a `localhost` address on **this** Mac, and
   * an agent reading that URL alone would conclude the exact opposite of the
   * truth. *"We always need a truth."*
   */
  const boundMachineId = servedBy(boundUrl, opened)?.machineId ?? ''
  const boundMachineName = servedBy(boundUrl, opened)?.machineName ?? ''
  useEffect(() => {
    if (!tabId) return
    window.deck?.browserWindowOpened?.({
      tabId,
      viewId: boundViewId,
      url: boundUrl,
      title: pageTitle,
      machineId: boundMachineId,
      machineName: boundMachineName,
      visible,
    })
    /*
     * And tell the *renderer* the same thing, which until now it was not.
     *
     * Main was told so its two native menus could group windows under machine
     * headings — and they do. Nothing else in the window knew, so the top bar,
     * which after this round is the only place a browser window is listed at
     * all, drew a page running on his PC identically to one running here. Asad:
     * *"Now I don't know if it is actually there or here… we always need a
     * truth."*
     *
     * One line rather than a second effect, because the two facts must never
     * disagree: a menu that says Office PC over a tab that says nothing is the
     * same defect in a smaller costume. See `window-machine.ts`.
     */
    setWindowMachine(
      tabId,
      boundMachineId === '' ? null : { id: boundMachineId, name: boundMachineName },
    )
    /*
     * And say whether this page is the one on screen.
     *
     * `visible` is already the app's exact answer to that — see the prop — so
     * this publishes it rather than deriving a second one. The sidebar is the
     * reader: the copilot's rail panel is drawn only over the page being driven,
     * and until this store existed it had no way to ask, so it sat over the rail
     * on the MCP servers page, on Machines and on a terminal session. See
     * `front-page.ts`.
     */
    setFrontPage(tabId, visible ? { tabId, viewId: boundViewId ?? '' } : null)
  }, [tabId, boundViewId, boundUrl, pageTitle, boundMachineId, boundMachineName, visible])

  /*
   * And take it away when the window goes.
   *
   * Its own effect, keyed on the tab id alone, so it fires on unmount and on a
   * tab id changing under a mounted panel — and *not* on every navigation, which
   * is what a cleanup inside the effect above would have done: it would clear
   * the machine on the way into every url change and set it again immediately
   * after, which is a tab whose machine mark blinks on every link.
   */
  useEffect(() => {
    if (!tabId) return
    return () => {
      forgetWindowMachine(tabId)
      forgetFrontPage(tabId)
    }
  }, [tabId])

  /* -- the device rectangle, recomputed on every layout pass. */
  const deviceSize = useMemo((): Size | null => {
    if (presetId === FIT_ID) return null
    if (presetId === CUSTOM_ID) {
      const width = parseDimension(customWidth)
      const height = parseDimension(customHeight)
      // While either field is mid-edit, keep the last good frame rather than
      // snapping the page to a 3px viewport on the way to 390.
      return width && height ? sizeFor({ width, height }, orientation) : null
    }
    const preset = presetById(presetId)
    return preset ? sizeFor(preset, orientation) : null
  }, [presetId, customWidth, customHeight, orientation])

  const [stage, setStage] = useState<Rect>({ x: 0, y: 0, width: 0, height: 0 })
  const fit = useMemo(() => fitInto(stage, deviceSize), [stage, deviceSize])

  /* -- keep the measured stage rectangle current. */
  useEffect(() => {
    const node = stageRef.current
    if (!node || typeof window === 'undefined') return


    const measure = (): void => {
      const box = rectOf(node)
      // A hidden panel has no box at all. Keeping the last good rectangle means
      // the page comes back exactly where it was on the next tab switch instead
      // of being handed 0x0 for the frame before the observer catches up.
      if (box.width === 0 && box.height === 0) return
      setStage(box)
    }
    measure()

    const observer = new ResizeObserver(measure)
    observer.observe(node)
    // The stage can move without changing size — the sidebar opening, the tab
    // strip wrapping — and a native view left at the old rectangle covers the
    // wrong part of the window.
    window.addEventListener('resize', measure)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', measure)
    }
  }, [tabs.length, deviceOpen, recording.steps.length, notice])

  /*
   * Every HTML surface currently floating over the app.
   *
   * The one lever that exists for "a popup is hiding behind the page". Read
   * `overlay-watch.ts` before touching this — the summary is that a browser page
   * is a NATIVE view composited above the entire renderer, so no z-index, no
   * portal and no stacking context can put HTML on top of it, and hiding the
   * view for as long as something is over it is the only thing Electron offers.
   *
   * Rectangles rather than a boolean, because parking the page for every
   * tooltip would blank a website whenever the pointer rested on a sidebar row.
   * The intersection test below is what keeps it to the ones that actually land
   * on the page.
   */
  const [overlays, setOverlays] = useState<Overlay[]>([])
  useEffect(() => {
    const dom = browserOverlayDom()
    if (!dom) return
    return watchOverlays(dom, setOverlays)
  }, [])
  // `fit.rect`, not `stage`: framed to a phone size the view is a 390px column
  // inside the stage, and an overlay in the empty desk beside it covers nothing.
  const covered = isCovered(fit.rect, overlays)

  /* -- push bounds and visibility. The dialog parks the view: it is a native
        layer, so it would otherwise open behind the website. */
  useEffect(() => {
    if (!api) return
    const bounds: Bounds = fit.rect
    for (const tab of tabs) {
      if (!tab.id) continue
      const isActive = tab.key === activeKey
      if (isActive) api.browserBounds(tab.id, bounds)
      api.browserVisible(
        tab.id,
        pageVisible(tab, {
          isActive,
          visible,
          parkPage,
          sessionOpen,
          covered,
          drawing: frame !== null,
          shotOpen: shot !== null,
        }),
      )
    }
  }, [api, tabs, activeKey, fit, visible, parkPage, sessionOpen, covered, frame, shot])

  /* -- events from the main process, matched to tabs by id. */
  useEffect(() => {
    if (!api) return
    const offState = api.onBrowserState((state) => {
      setTabs((prev) => withTabId(prev, state.id, patchFrom(state)))
    })
    const offElement = api.onBrowserElement((id, next) => {
      const tab = tabForId(tabsRef.current, id)
      if (!tab) return
      setCaptures((prev) => ({ ...prev, [tab.key]: next }))
      /*
       * No `setBottom('capture')` here any more, and its absence is half the
       * flow-recording fix.
       *
       * A capture used to force the bottom strip onto the Element tab. With
       * Inspect and Record both switched on — which the toolbar allowed, and
       * which he did — every click in the page produced a capture, so the panel
       * snapped back to Element on every click while the Flow list stayed at
       * one step. On camera that is *"it is keep moving to element
       * automatically… I think it's not working fine"*: two bugs wearing one
       * symptom.
       *
       * The other half is `toggleRecording` and `toggleInspect` below, which now
       * refuse to be on at once. This half is that a capture no longer competes
       * for a strip at all — it opens its own popup.
       */
    })
    const offProgress = api.onBrowserProgress((id, next) => {
      setTabs((prev) => withTabId(prev, id, { progress: next.fraction }))
    })
    const offRecording = api.onBrowserRecording((id, state) => {
      const tab = tabForId(tabsRef.current, id)
      if (!tab) return
      setRecordings((prev) => ({ ...prev, [tab.key]: state }))
      setTabs((prev) => withTab(prev, tab.key, { recording: state.recording }))
    })
    return () => {
      offState()
      offElement()
      offProgress()
      offRecording()
    }
  }, [api])

  /* -- open a tab: place it in the strip first, then create and claim its view. */
  const openNewTab = useCallback(
    (
      url: string,
      focusAddress = true,
      isolated = false,
      /*
       * Told the id the *main process* minted, once it exists.
       *
       * The key returned below is this panel's own, and the main process has
       * never heard of it — the id it knows arrives asynchronously from
       * `browserCreate`. The drive needs that one, so it is handed over at the
       * moment it lands rather than polled for. Null when the tab could not be
       * opened at all, which the drive reports honestly rather than waiting.
       */
      onCreated?: (tabId: string | null) => void,
      /*
       * A **worker profile** to open this tab in, rather than the profile that
       * is switched on.
       *
       * The last argument and optional, so every existing caller is unchanged.
       * Only the Workers panel passes one, and the main process refuses every
       * id that is not a registered worker — see `workerSession` in
       * `browser-tab.ts`. It has to be decided before `browserCreate` for the
       * same reason `isolationKey` does: a view's session is fixed when it is
       * constructed and cannot be swapped afterwards.
       */
      profileId?: string,
    ): string => {
      if (!api) {
        onCreated?.(null)
        return ''
      }
      seq.current += 1
      const key = `tab-${seq.current}`
      const mine = generation.current
      setTabs((prev) => openTab(prev, newTab(key, url, isolated), activeRef.current))
      setActiveKey(key)
      // Only for a tab the user asked for. Doing it on mount would pull focus
      // out of wherever they were the moment the panel appeared.
      if (focusAddress) setFocusToken((token) => token + 1)

      enqueue(async () => {
        // The partition is fixed when the view is constructed, so the key has to
        // exist before `browserCreate` — it cannot be applied afterwards.
        const isolationKey = isolated
          ? asIsolationKey(await iso.browserIsolationKey?.().catch(() => null))
          : null
        if (isolated && !isolationKey) {
          // Never quietly open a *shared* tab that the strip and the toolbar
          // both label Isolated. That is the one failure mode of this feature
          // that actively misleads.
          setTabs((prev) => prev.filter((tab) => tab.key !== key))
          setNotice('This build could not open an isolated tab, so none was opened.')
          onCreated?.(null)
          return
        }
        setTabs((prev) => withTab(prev, key, { isolationKey }))

        // Invisible until the layout effect has given it a rectangle, or it
        // paints once at whatever the previous tab was using.
        const state = await api.browserCreate({
          url,
          visible: false,
          // The app's own canvas, so an empty view is not a white rectangle in
          // a dark app. Read from `tokens.css` at the moment it is needed — the
          // main process has no stylesheet — and validated there before it
          // reaches a native call. See `browser-background.ts` for why a
          // *loaded* page still gets white.
          background: appCanvasColor(),
          ...(isolationKey ? { isolationKey } : {}),
          ...(profileId ? { profileId } : {}),
        })
        if (generation.current !== mine) {
          await api.browserClose(state.id).catch(() => undefined)
          if (isolationKey) await iso.browserIsolationDispose?.(isolationKey).catch(() => undefined)
          onCreated?.(null)
          return
        }
        const claimed = await api.browserClaim(state.id)
        const factor = claimed.ok ? await api.browserZoom(state.id, null).catch(() => 1) : 1
        setTabs((prev) => withTab(prev, key, patchFrom(state)))
        setZooms((prev) => ({ ...prev, [key]: factor }))
        onCreated?.(state.id)
        if (!claimed.ok) {
          setNotice(
            `The page opened, but its extra controls did not attach (${claimed.reason ?? 'unknown'}). Zoom, screenshots and recording are unavailable for this tab.`,
          )
        }
      })
      return key
    },
    [api, iso, enqueue],
  )

  /* -- the copilot driving: watch the baton, and open the tab when it asks. */
  useEffect(() => {
    if (!driveAvailable(driveApi)) return
    /*
     * Read once, then subscribe.
     *
     * A panel mounted in the middle of a live drive would otherwise show no
     * banner until the next state change — and the state that matters most,
     * `human`, is the one that does not change again until somebody answers
     * the banner they cannot see.
     */
    let live = true
    void driveApi.browserDriveStatus?.().then((raw) => {
      const status = readDriveStatus(raw)
      if (live && status) setDrive(status)
    }).catch(() => undefined)
    const off = driveApi.onBrowserDriveState?.((raw) => {
      const status = readDriveStatus(raw)
      if (status) setDrive(status)
    })
    return () => {
      live = false
      off?.()
    }
  }, [driveApi])

  useEffect(() => {
    if (!driveAvailable(driveApi)) return
    return driveApi.onBrowserDriveOpen?.((raw) => {
      const request = readDriveOpen(raw)
      if (!request) return
      /*
       * The pane it was addressed to answers, and no other one may.
       *
       * A drive-open used to be a broadcast that the first mounted panel took,
       * and with the panel's own tab strip gone that meant a session's window —
       * often the only browser pane open — answering the copilot's `browser.open`
       * and covering the page he was looking at with one in no strip anywhere.
       * Main picks the pane because main is the side that knows which panes are
       * attached to a session; see `DriveOpenRequest.pane`.
       */
      if (request.pane !== null && request.pane !== tabId) return
      /*
       * One panel answers, and only one.
       *
       * A browser page is a row in the sidebar, so several of these components
       * can be mounted at once and the push reaches every one of them. Without
       * the claim, one `browser.open` would open a tab in each panel and the
       * main process would use the first reply — leaving the rest as pages
       * nobody asked for, in panels nobody was looking at.
       */
      if (!claimDriveOpen(request.id)) return
      /*
       * A pane holds one page, and the copilot's pane is not an exception.
       *
       * This panel's own tab strip is gone — a browser page is a row in the
       * sidebar now — so a second page opened in here is a page nobody can
       * reach: no strip lists it, no ✕ closes it, and it goes on running its
       * timers until the pane itself is closed. The copilot reaches this line
       * whenever a page has to be *built* rather than navigated, which is every
       * change of isolation, so leaving the old one would put one unreachable
       * page in the pane per flip.
       *
       * Closed first and reopened, which is the sequence `toggleIsolation`
       * already uses for exactly the same physics: a partition is fixed when a
       * view is constructed, so a switch is a new page or it is nothing.
       *
       * Only when main addressed the request — an unaddressed one is from a
       * main process that predates the pane rule, and closing somebody's page
       * on its say-so is the seizure being fixed, wearing a worse costume.
       */
      if (request.pane !== null) {
        const showing = tabsRef.current.find((entry) => entry.key === activeRef.current)
        if (showing) closeTabRef.current(showing.key)
      }
      openNewTab(request.url, false, request.isolate, (viewId) => {
        driveApi.browserDriveOpened?.(request.id, viewId)
      })
    })
  }, [driveApi, openNewTab, tabId])

  /* -- first tab, and cleanup. */
  useEffect(() => {
    if (!api) return
    if (tabsRef.current.length === 0) openNewTab(openAtRef.current, false)
    return () => {
      generation.current += 1
      for (const tab of tabsRef.current) {
        // An isolated partition holds its cookies in memory for the life of the
        // process, so it has to be thrown away with the tab rather than left to
        // the next quit.
        if (tab.isolationKey) {
          void iso.browserIsolationDispose?.(tab.isolationKey).catch(() => undefined)
        }
        if (!tab.id) continue
        /*
         * Hidden first, and synchronously.
         *
         * `browserVisible` is a `send` — it lands in the main process's queue
         * immediately — where release and close are `invoke`s that resolve
         * whenever the round trip does. Without this line the pane is already
         * showing a terminal while the page is still composited over it, for as
         * many frames as that round trip takes; the effect ordering makes that a
         * flash rather than the permanent version of the same picture, and a
         * flash of somebody's website over their terminal is still the bug.
         *
         * It is not the fix, and must not be mistaken for it: an unmount is the
         * polite path, and the whole point of the main-process rule in
         * `browser-tab.ts` is that the impolite ones — a reload, a crash, a
         * window closing — cannot reach any line in this file.
         */
        api.browserVisible(tab.id, false)
        void api.browserRelease(tab.id).catch(() => undefined)
        void api.browserClose(tab.id).catch(() => undefined)
      }
      // The strip has to go with the views. Leaving it would let a StrictMode
      // remount see tabs it thinks are already open, and skip creating the one
      // real view the panel needs.
      setTabs([])
      setActiveKey('')
    }
  }, [api, iso, openNewTab])

  /* -- acting on the active tab. */
  const act = useCallback(
    (run: (api: BrowserBridge, id: string) => Promise<BrowserTabState>): void => {
      const id = active?.id
      if (!api || !id) return
      // A tab closing under an in-flight call is ordinary, not exceptional: the
      // main process throws for an id it has forgotten, and without this that is
      // an unhandled rejection every time a tab is closed mid-navigation.
      void run(api, id).then(
        (state) => setTabs((prev) => withTabId(prev, state.id, patchFrom(state))),
        () => undefined,
      )
    },
    [api, active?.id],
  )

  /* -- the other machines, and the addresses that resolve on them. */

  useEffect(() => {
    if (!machinesApi) return
    let alive = true
    const take = (raw: unknown): void => {
      if (!alive) return
      const view = readMachines(raw)
      setMachineView(machineChoices(view))
      setHere(hereName(view))
    }
    // One read for the state that already exists, then the push for everything
    // after it. Without the read a panel opened while a machine was already
    // connected would show nothing until that machine next changed.
    void machinesApi.listMachines().then(take).catch(() => undefined)
    const off = machinesApi.onMachinesState(take)
    return () => {
      alive = false
      off()
    }
  }, [machinesApi])

  /*
   * What has been downloaded, pushed rather than polled.
   *
   * One read for the list that already exists — a window opened after a
   * download would otherwise show nothing until the next one — and then the push
   * for everything after it, which is the same shape the machines effect above
   * uses and for the same reason.
   */
  useEffect(() => {
    if (!downloadsAvailable(downloads)) return
    let alive = true
    const take = (raw: unknown): void => {
      if (alive) setDownloadsView(readDownloadsView(raw))
    }
    void downloads.browserDownloads?.().then(take).catch(() => undefined)
    const off = downloads.onBrowserDownloads?.(take)
    return () => {
      alive = false
      off?.()
    }
  }, [downloads])

  /*
   * The servers this app knows, read once.
   *
   * A read and no subscription, unlike the machines above, because the two
   * lists change for different reasons. A paired device goes online and offline
   * by itself and pushes when it does; a server is only ever *added or
   * forgotten by the person*, on a screen in another panel, and this panel is
   * remounted whenever the browser is opened. A push channel for a list that
   * changes when somebody fills in a form would be a second wire to keep in
   * step for no observable difference.
   */
  useEffect(() => {
    if (!serversApi) return
    let alive = true
    void serversApi
      .listServers()
      .then((raw) => {
        if (alive) setServerList(readServers(raw))
      })
      .catch(() => undefined)
    return () => {
      alive = false
    }
  }, [serversApi])

  /**
   * The one list the rest of this panel works from.
   *
   * Memoised rather than built in the render body, and that is load bearing:
   * `lostMachine` runs in an effect that depends on this array, and a fresh
   * array every render would re-run that effect forever.
   */
  const machines = useMemo(
    () => [...machineView, ...serverChoices(serverList, serverPorts)],
    [machineView, serverList, serverPorts],
  )

  /**
   * Give the picker back when the machine it is pointing at goes away.
   *
   * A selection that survived its machine would be an address bar that refused
   * every localhost address with the same sentence until somebody worked out
   * that a dropdown two centimetres away had gone stale. The reason is said out
   * loud, once, in the band this panel already uses for sentences.
   *
   * The tunnels that machine served go with it, for the same reason: the
   * listeners are already closed over in the main process — `machines/ipc.ts`
   * drops them the moment a link leaves `online` — so a badge still naming it
   * would be pointing at a page that has stopped answering.
   */
  useEffect(() => {
    const lost = lostMachine(machines, machineId)
    if (lost === null) return
    setMachineId(THIS_MACHINE)
    setOpened((prev) => prev.filter((entry) => entry.machineId !== machineId))
    // And the caveat about one of its ports, which is a true sentence about a
    // page that has just stopped answering. Watched on a real pair of machines:
    // revoking over there left "port 8090 is being served here on 64830" on
    // screen above a dead tab, under a sentence saying the machine had gone.
    setPortNote('')
    setNotice(lost)
  }, [machineId, machines])

  /*
   * Ask the chosen machine what it is serving, once, on choosing it.
   *
   * The link asks on every welcome and pushes the answer, so there is normally a
   * list already — but "normally" is doing a lot of work there: the machine may
   * have been connected for an hour, and nothing on the far side watches its own
   * process table. Somebody opening this picker has almost always just started
   * something over there, which is the one case a push cannot cover.
   */
  useEffect(() => {
    if (machineId === THIS_MACHINE || !machinesApi) return
    // Devices only. A server id sent down this channel would name no link and
    // be refused, which costs nothing and reads, to the next person, as though
    // the two kinds shared a wire. They do not.
    if (machines.find((one) => one.id === machineId)?.kind === 'server') return
    void machinesApi.refreshMachinePorts(machineId).catch(() => undefined)
  }, [machineId, machines, machinesApi])

  /**
   * Ask a chosen server the same question, which for a server is a dial.
   *
   * Its own effect rather than a branch inside the one above, because the two
   * are not the same act. A device is already connected and this is a nudge; a
   * server is not, and choosing it in this dropdown is the thing that opens a
   * connection to somebody's computer. That deserves to be one legible effect
   * with one comment on it rather than a condition inside another.
   *
   * `asking` is written before the call so the start page says *"Asking … what
   * it is serving"* rather than drawing an empty list for the second and a half
   * a real dial takes — measured against a real server, where the handshake and
   * the probe together are about that.
   */
  const askServer = useCallback(
    (id: string): void => {
      if (!serversApi) return
      setServerPorts((prev) => ({ ...prev, [id]: { state: 'asking' } }))
      void serversApi
        .serverPorts(id)
        .then((raw) => setServerPorts((prev) => ({ ...prev, [id]: readServerPorts(raw) })))
        .catch((cause: unknown) =>
          setServerPorts((prev) => ({
            ...prev,
            [id]: { state: 'refused', message: humanError(cause) },
          })),
        )
    },
    [serversApi],
  )

  useEffect(() => {
    if (machineId === THIS_MACHINE) return
    // Devices are handled above; a server that has already answered is not
    // asked again, because this effect re-runs whenever anything about the
    // list changes and a dial per render is not a question, it is a loop.
    const chosen = machines.find((one) => one.id === machineId)
    if (chosen?.kind !== 'server' || serverPorts[machineId] !== undefined) return
    askServer(machineId)
  }, [askServer, machineId, machines, serverPorts])

  /**
   * Hand a port back to this computer, and say whether it really went.
   *
   * The counterpart of `reachPort` below, and the thing 0.9.0 was missing. The
   * tunnel keeps the far machine's own port *number* here whenever it was free,
   * so while it is up `localhost:3100` on this Mac **is** the PC's 3100 — and
   * moving the page home by navigating to that address fetched it from the PC
   * again, under a picker that had already taken this machine's name.
   *
   * False is a real answer and the caller must act on it: a preload that
   * predates the verb, or a request main would not take. The entry is dropped
   * from `opened` **only** when the listener is actually gone, because the
   * badge in the address field is read off that list and a badge that stopped
   * naming the PC over a page still coming from the PC is the same untruth with
   * the labels swapped.
   */
  const handBack = useCallback(
    async (held: ReachedPort): Promise<boolean> => {
      const owner = machines.find((one) => one.id === held.machineId)
      // A machine with no row is one this window cannot name, and it cannot
      // know which of the two bridges holds the listener either. Refusing is
      // the only answer here that is not a guess about somebody's page.
      if (!owner) return false
      const release =
        owner.kind === 'server' ? serversApi?.releaseOnServer : machinesApi?.releaseOnMachine
      if (!release) return false
      const answer = await release(held.machineId, held.port).catch(() => false)
      if (answer !== true) return false
      // Both halves of the key. Another machine may already have taken that
      // number here — see `reachPort` — and filtering on the number alone would
      // delete the entry describing the page that is on screen right now.
      setOpened((prev) =>
        prev.filter(
          (entry) => entry.machineId !== held.machineId || entry.localPort !== held.localPort,
        ),
      )
      return true
    },
    [machines, machinesApi, serversApi],
  )

  /**
   * Ask the main process for an address on this machine that serves that port.
   *
   * Null on refusal, **after** putting the refusal on screen. Every one of the
   * four ways this can fail is a different sentence written by whichever end
   * knows the answer — the link is down, that machine is no longer serving the
   * port, it never answered, or this machine could not open a local address —
   * and swallowing one would turn a click into nothing at all.
   */
  const reachPort = useCallback(
    async (machine: MachineChoice, port: number): Promise<ReachOpened | null> => {
      /*
       * The one place the two kinds of machine part company, and it is one
       * line: which bridge is asked. Everything after it — the narrowing, the
       * badge, the caveat about a port number that had to change, the tab the
       * page opens in — is the same code for both, because the answer shapes
       * were deliberately made identical in the main process rather than
       * translated here. Two shapes would have been two of everything below.
       */
      const bridge =
        machine.kind === 'server'
          ? serversApi && ((port: number) => serversApi.reachOnServer(machine.id, port))
          : machinesApi && ((port: number) => machinesApi.reachOnMachine(machine.id, port))
      if (!bridge) {
        setNotice('This build cannot reach another machine’s ports.')
        return null
      }
      const answer = readReach(
        await bridge(port).catch((cause: unknown) => ({
          ok: false,
          message: humanError(cause),
        })),
      )
      if (!answer.ok) {
        setNotice(answer.message)
        return null
      }
      /*
       * A listener of this window's that was standing on the same number here
       * is given back, not merely forgotten.
       *
       * Two machines cannot both own `localhost:3100` on this computer, and the
       * ladder in `localhost-reach.ts` will hand the second one the *other*
       * loopback family with the same number rather than refuse. Dropping the
       * displaced row from this list without closing its tunnel leaves a
       * listener no control can see and no badge can name — and the next move
       * home would navigate straight into it, which is the 0.9.0 defect back
       * again by a longer route.
       */
      const displaced = inTheWay(answer.localPort, machine.id, openedRef.current)
      setOpened((prev) => [
        ...prev.filter((entry) => entry.localPort !== answer.localPort),
        {
          machineId: machine.id,
          machineName: machine.name,
          port: answer.port,
          localPort: answer.localPort,
          sameNumber: answer.sameNumber,
        },
      ])
      if (displaced) void handBack(displaced)
      // Said once, when it happens, rather than left to be discovered by a link
      // inside the site going somewhere strange. Set to '' on the ordinary case
      // as well, so a caveat about the last port does not sit above a page it is
      // not true of.
      setPortNote(differentPortNote(answer, machine.name))
      return answer
    },
    [handBack, machinesApi, serversApi],
  )

  /**
   * Open a port on another machine, in this tab, as an ordinary page.
   *
   * The address that comes back is a plain `http://` URL on this machine's
   * loopback, so it goes through `browserNavigate` exactly as anything else
   * does — same tab, same history, same Back button. That sameness is the
   * requirement rather than an implementation detail: *"shape of the application
   * should not be changing for local and remote devices."*
   */
  const openThere = useCallback(
    async (machine: MachineChoice, port: number, typed: string): Promise<boolean> => {
      const answer = await reachPort(machine, port)
      // `reachPort` has already said why in the notice bar. What the answer adds
      // here is whether the caller may keep claiming the page moved — see
      // `moveToMachine`, where a refusal has to put the picker back rather than
      // leave it naming a machine the page is not on.
      if (!answer) return false
      act((a, id) => a.browserNavigate(id, reachedAddress(typed, answer.url)))
      return true
    },
    [reachPort, act],
  )

  /*
   * The machine a session asked this page to be opened on, taken up once its
   * row exists.
   *
   * ## Why it waits, and why it can only fire once
   *
   * The machines view arrives on a push, so the list is empty for the first
   * frames of a pane's life. Setting the picker from the prop at mount would run
   * straight into `lostMachine` above — a selection naming a machine that is not
   * in the list is reset with *"that machine is no longer paired"*, and the page
   * would be back on this computer's network with a sentence blaming the wrong
   * thing. Waiting for the row means the picker is never set to a machine this
   * window cannot name.
   *
   * Once, because after this the machine behind the page is the person's to
   * choose: the picker is a control, and a prop that re-asserted itself would
   * take a page back off them every time the machines list changed.
   *
   * The address is re-opened rather than merely re-labelled, and only when it is
   * a loopback one — `destinationFor` is what decides that, and it is the same
   * function the address bar uses, so a page from a session and a page he typed
   * end up in the same place. Everything else keeps the URL it opened with: a
   * public address is the same page from every machine, and tunnelling it would
   * be a claim rather than a reach.
   */
  const claimedMachine = useRef(initialMachineId === '')
  useEffect(() => {
    if (claimedMachine.current) return
    const found = machines.find((one) => one.id === initialMachineId)
    if (!found) return
    claimedMachine.current = true
    if (found.unreachable !== null) {
      // Said, not swallowed. The page is on this computer's network and the
      // person is looking at a tab that was meant to be somewhere else.
      setNotice(`${found.name} — ${found.unreachable}`)
      return
    }
    setMachineId(found.id)
    const target = destinationFor(found.id, openAtRef.current)
    if (target.kind === 'there') void openThere(found, target.port, target.url)
  }, [initialMachineId, machines, openThere])

  const navigate = useCallback(
    (input: string): void => {
      const resolution = resolveOmnibox(input)
      if (resolution.kind === 'empty') return
      setTabs((prev) => withTab(prev, activeRef.current, { editing: false }))
      /*
       * Which machine this address is for, decided by one pure function.
       *
       * `destinationFor` is the whole behaviour of the picker and it lives in
       * `machines-bridge.ts` so it can be tested: an effect inside a panel is
       * the one place this project's test run cannot look, and a change that
       * quietly stopped rerouting `localhost` would leave every render test
       * passing with the feature gone.
       */
      const target = destinationFor(machineId, resolution.url)
      if (target.kind === 'there') {
        const machine = machines.find((one) => one.id === target.machineId)
        // Refused here rather than sent, because a machine that is not in the
        // list is not one this window can say anything about. The effect above
        // has already put the picker back and said why.
        if (machine) {
          void openThere(machine, target.port, target.url)
          return
        }
      }
      /*
       * With this computer chosen, `localhost:3100` has to mean this computer.
       *
       * The same fact `moveToMachine` runs into from the other direction: a
       * tunnel of this window's that took the same port number owns that address
       * until it is closed, so typing it would open the far machine's page under
       * a picker naming this one. Only a tunnel this window opened is ever given
       * back, and only the one standing on the number being asked for.
       *
       * The navigation happens either way. If the port could not be handed back
       * the address still means that machine — which is what the badge in the
       * field will then say, because the entry stays in `opened`.
       */
      const held = inTheWay(loopbackPort(target.url), machineId, opened)
      if (held !== null) {
        void handBack(held).then(() => act((a, id) => a.browserNavigate(id, target.url)))
        return
      }
      act((a, id) => a.browserNavigate(id, target.url))
    },
    [act, handBack, machineId, machines, opened, openThere],
  )

  const closeTab = useCallback(
    (key: string): void => {
      const tab = tabsRef.current.find((entry) => entry.key === key)
      const result = closeInList(tabsRef.current, key, activeRef.current)
      setTabs(result.tabs)
      setActiveKey(result.activeKey)
      // All four, not just the captures. Keys are minted per tab and never
      // reused, so anything left behind is unreachable and permanent — and a
      // stranded RecordingState holds up to MAX_STEPS steps, so a long session
      // of opening and closing tabs grows without bound for no benefit.
      setCaptures((prev) => without(prev, key))
      setRecordings((prev) => without(prev, key))
      setZooms((prev) => without(prev, key))
      setDevtools((prev) => without(prev, key))

      const isolationKey = tab?.isolationKey ?? null
      if (!api || !tab?.id) {
        // A tab closed before its view existed still minted a partition, and a
        // partition nobody holds a reference to is a cookie jar kept in memory
        // for the rest of the run.
        if (isolationKey) void iso.browserIsolationDispose?.(isolationKey).catch(() => undefined)
        return
      }
      const id = tab.id
      // Off the screen now, not when the queue reaches it. Closing a tab drops
      // it from `tabs` in the same commit, so the effect that pushes visibility
      // will never mention this id again — and the work below is queued behind
      // whatever else the panel has in flight, which on a slow create can be a
      // second or more of a closed page still painted over its replacement.
      api.browserVisible(id, false)
      enqueue(async () => {
        await api.browserRelease(id).catch(() => undefined)
        await api.browserClose(id).catch(() => undefined)
        // After the view is gone, not before: clearing a partition still in use
        // signs the page out on its way to being closed, which shows.
        if (isolationKey) await iso.browserIsolationDispose?.(isolationKey).catch(() => undefined)
      })
    },
    [api, iso, enqueue],
  )

  /**
   * Move this tab between the shared session and one of its own.
   *
   * It reopens the page rather than reconfiguring it, because a WebContents'
   * session is chosen when it is constructed and Electron offers no way to swap
   * it afterwards. So this closes the tab and opens a replacement at the same
   * address, then puts it back where the old one was — a switch that silently
   * moved the tab to the end of the strip would read as a bug in the strip.
   */
  const toggleIsolation = useCallback((): void => {
    const tab = tabsRef.current.find((entry) => entry.key === activeRef.current)
    if (!tab) return
    const index = tabsRef.current.findIndex((entry) => entry.key === tab.key)
    const url = tab.url || tab.draft
    closeTab(tab.key)
    const key = openNewTab(url, false, !tab.isolated)
    if (key !== '') setTabs((prev) => moveTab(prev, key, index))
  }, [closeTab, openNewTab])

  /**
   * Reopen the page that is on screen, in whichever profile is now switched on.
   *
   * **Not a navigation.** A `WebContents`' session is fixed when it is
   * constructed and cannot be swapped afterwards — the physics the Isolated
   * toggle above already lives under — so calling `navigate` here would reload
   * the page in the *old* profile's cookie jar while the menu said it had moved
   * it. That is precisely the kind of control this whole review is about: one
   * that looks like it acted and did not. So the tab is closed and a new one is
   * opened at the same address and put back in the same place in the strip,
   * which is the only arrangement in which the new session is real.
   */
  const reopenInActiveProfile = useCallback((): void => {
    const tab = tabsRef.current.find((entry) => entry.key === activeRef.current)
    if (!tab) return
    const index = tabsRef.current.findIndex((entry) => entry.key === tab.key)
    const url = tab.url || tab.draft
    closeTab(tab.key)
    // Never isolated: an isolated tab belongs to no profile at all, and
    // reopening one "in a profile" would silently move it out of the in-memory
    // partition somebody chose it for.
    const key = openNewTab(url, false, false)
    if (key !== '') setTabs((prev) => moveTab(prev, key, index))
  }, [closeTab, openNewTab])

  closeTabRef.current = closeTab

  /* -- the extras, all of which need the claimed view. */
  const withId = useCallback(
    (run: (api: BrowserBridge, id: string) => Promise<void>): void => {
      const id = active?.id
      if (!api || !id) return
      void run(api, id).catch((cause: unknown) => {
        // `humanError`, not `cause.message`: a rejected invoke arrives wearing
        // the channel name and the word Error twice, and every message these
        // handlers throw was written as a sentence for the person reading it.
        setNotice(humanError(cause))
      })
    },
    [api, active?.id],
  )

  const applyZoom = useCallback(
    (factor: number): void => {
      const key = activeRef.current
      withId(async (a, id) => {
        const applied = await a.browserZoom(id, factor)
        setZooms((prev) => ({ ...prev, [key]: applied }))
      })
    },
    [withId],
  )

  /**
   * Start or stop recording — and turn inspection off if it was on.
   *
   * ## Why they cannot both be on, and why that is the bug
   *
   * The inspector *swallows* the clicks it sees: `browser-preload.ts` calls
   * `preventDefault` and `stopImmediatePropagation` on every one, so pointing at
   * a link does not navigate away from the link. The recorder is the opposite —
   * it watches the user actually using the page, and it deliberately ignores
   * every event while the inspector's overlay is in the document, because a
   * click the page never received is not a step in any flow.
   *
   * Both of those are right. What was missing is that the toolbar let both modes
   * be switched on at once, and the guest then resolved the contradiction
   * silently in the inspector's favour. On camera that is a Flow counter frozen
   * at one step across forty clicks, with the panel snapping back to Element
   * each time — a recorder that says RECORDING, shows its badge in the page, and
   * records nothing.
   *
   * So the two modes are made exclusive here, at the only place that knows both:
   * turning one on turns the other off. The guard inside the guest recorder
   * stays as it is — it is the correct behaviour for a state this can no longer
   * produce, and it costs nothing.
   */
  /**
   * Flip one of the two page modes, and switch the other off if it was on.
   *
   * `modes.ts` holds the rule and says at length why it exists; the short
   * version is that the inspector swallows clicks and the recorder ignores every
   * event while the inspector is up, so "both on" is a recorder that says
   * RECORDING and records nothing. That is what the frozen `Flow (1)` counter
   * was.
   *
   * Inspection is turned off *before* recording is turned on, so there is no
   * instant in which the guest has both. Recording is the noisier of the two —
   * it puts a badge in the page — and having it announce itself while the
   * inspector is still eating clicks is the exact lie being fixed.
   */
  const toggleMode = useCallback(
    (mode: BrowserMode): void => {
      const key = activeRef.current
      const current: BrowserModes = {
        inspecting: active?.inspecting === true,
        recording: recordings[key]?.recording === true,
        drawing: frame !== null,
      }
      const changes = modeChanges(current, nextModes(current, mode))

      /*
       * Draw off is applied here, before the IPC, and draw on is applied after
       * the frame arrives.
       *
       * Leaving the mode has to be instant: it is what Escape does and what the
       * Done button does, and a page that stays parked for a round trip after
       * you asked for it back reads as a hang. Entering cannot be instant,
       * because there is nothing to draw on until the capture comes back — and
       * parking the page first would make that capture fail, since `capturePage`
       * on a hidden view is a hard error on Electron 41.
       */
      if (changes.draw === false) {
        setFrame(null)
        setMarks([])
      }

      withId(async (a, id) => {
        if (changes.inspect === false) {
          const next = await a.browserInspect(id, false)
          setTabs((prev) => withTabId(prev, next.id, patchFrom(next)))
        }
        if (changes.record !== undefined) {
          const state = await a.browserRecord(id, {
            on: changes.record,
            accent: recordingAccent(),
          })
          setRecordings((prev) => ({ ...prev, [key]: state }))
          setTabs((prev) => withTab(prev, key, { recording: state.recording }))
        }
        if (changes.inspect === true) {
          const next = await a.browserInspect(id, true)
          setTabs((prev) => withTabId(prev, next.id, patchFrom(next)))
        }
        if (changes.draw === true) {
          const captured = readFrame(await drawApi.browserFrame?.(id))
          if (!captured) throw new Error('The page could not be captured, so there is nothing to draw on.')
          setMarks([])
          setFrame(captured)
          // The element popup belongs to the mode that just went off, and it is
          // portalled over the whole window — leaving it up would float a panel
          // about a selector over a canvas about a picture.
          setCaptures((prev) => without(prev, key))
        }
      })
    },
    [active?.inspecting, recordings, frame, drawApi, withId],
  )

  const toggleRecording = useCallback(() => toggleMode('record'), [toggleMode])

  /**
   * Save the marked frame, then hand it to the screenshot popup.
   *
   * The two halves of *"we can send it to the agent like this"*. The canvas
   * gives back the exact bitmap on screen, the main process writes it beside the
   * ordinary screenshots, and what comes back is a `ScreenshotResult` — so from
   * here on this is the screenshot path, with the same popup, the same Reveal
   * and the same per-window session choice. There is no second way to send an
   * image, which is the point: a second one is how the two end up disagreeing
   * about which session "the agent" is.
   *
   * The preview is the canvas' own data URL rather than something the main
   * process encodes and sends back. It is the same picture, it is already in
   * memory on this side, and echoing three megabytes of base64 back across the
   * bridge to look at what we just drew would be absurd.
   */
  const sendMarked = useCallback((): void => {
    const png = surface.current?.toPng() ?? ''
    const count = marks.length
    /*
     * The address of the *photograph*, not of the page as it is now.
     *
     * The main process reads the URL again when it writes the file, and that is
     * the right thing for the filename — but it is the wrong thing to tell an
     * agent. The page has been parked behind a canvas for as long as the user
     * has been drawing, and a parked view is still running: a redirect, a
     * router push or a meta refresh in that window would have the agent sent to
     * an address this picture is not of. `frame.url` was read at the instant the
     * pixels were.
     */
    const where = frame?.url ?? ''
    if (!png || count === 0) {
      setNotice('There was nothing to save — the drawing could not be read back.')
      return
    }
    setSaving(true)
    // `withId` for the tab id and, more importantly, for its one error path:
    // a failed save has to become the notice band rather than an unhandled
    // rejection in a console nobody has open.
    withId(async (_api, id) => {
      try {
        const saved = readMarkedShot(await drawApi.browserScreenshotMarked?.(id, png))
        if (!saved) throw new Error('The marked page could not be saved.')
        setShot({ ...saved, url: where || saved.url, preview: png, marks: count })
        setFrame(null)
        setMarks([])
        setNotice(null)
      } finally {
        setSaving(false)
      }
    })
  }, [drawApi, frame?.url, marks.length, withId])

  /**
   * Copy the flow, and admit it when that fails.
   *
   * Two things the obvious three-liner gets wrong. `writeText` rejects rather
   * than throws — most often with NotAllowedError, because this panel's page is
   * a native layer that takes the document's focus away — and an uncaught one is
   * a button that reports success by saying nothing. And the "Copied" label needs
   * a timer, which has to be cancellable: clicking twice would otherwise leave
   * two, and unmounting between click and expiry leaves one running against a
   * component that is gone.
   */
  const copyFlow = useCallback((): void => {
    const text = recordings[activeRef.current]?.text ?? ''
    if (!text || typeof navigator === 'undefined' || !navigator.clipboard) return
    navigator.clipboard.writeText(text).then(
      () => {
        setCopied(true)
        if (copyTimer.current !== null) window.clearTimeout(copyTimer.current)
        copyTimer.current = window.setTimeout(() => {
          copyTimer.current = null
          setCopied(false)
        }, 1500)
      },
      (cause: unknown) => {
        setCopied(false)
        setNotice(
          `Could not copy the flow (${cause instanceof Error ? cause.message : String(cause)}).`,
        )
      },
    )
  }, [recordings])

  useEffect(() => {
    return () => {
      if (copyTimer.current !== null) window.clearTimeout(copyTimer.current)
      copyTimer.current = null
    }
  }, [])

  /**
   * Measure something on the toolbar, then open whichever popup was asked for.
   *
   * Measured at the moment of opening rather than kept in state and updated on
   * resize. The toolbar moves whenever the window is resized, the panel becomes
   * half of a split, or a band above it appears — and a stale anchor is a popup
   * pointing at where a button used to be, which is worse than one that is
   * placed a frame later.
   *
   * `node` is the element to point at; the action group stands in when a caller
   * has nothing more specific, which is the case for the recorded flow — its
   * button is in the middle of the group and a popup hanging off the middle of a
   * toolbar reads as floating.
   */
  const openAt = useCallback((node: HTMLElement | null, open: () => void): void => {
    const target = node ?? actionsRef.current
    if (target) {
      const box = target.getBoundingClientRect()
      setMenuAnchor({ x: box.x, y: box.y, width: box.width, height: box.height })
    }
    open()
  }, [])

  /*
   * Which profile is on, for the toolbar button's hover label.
   *
   * Read once when the panel mounts and again whenever the profile menu closes,
   * which is the only place in the app a profile can be switched. Not
   * subscribed: `browser-profile:*` are plain invokes with no push channel, and
   * inventing a poll for a value that changes when a person clicks a menu is the
   * *"they make the system heavier"* he has objected to by name.
   */
  const readProfileName = useCallback((): void => {
    if (!accounts.browserProfiles) return
    void accounts.browserProfiles().then((raw) => {
      const state = readProfiles(raw)
      if (!state) return
      setProfiles(state)
    })
  }, [accounts])

  useEffect(() => {
    readProfileName()
  }, [readProfileName])

  const activeProfile = profiles?.profiles.find((entry) => entry.id === profiles.activeId) ?? null
  const activeProfileId = activeProfile?.id ?? ''
  const profileName = activeProfile?.name ?? ''
  const profileOf = (id: string) => profiles?.profiles.find((entry) => entry.id === id) ?? null

  /*
   * What the address bar offers while somebody types.
   *
   *   > *"When I type in the top chat bar … if it was before there, it should…
   *   > automatically pre-fill."*
   *
   * Asked of the main process on each keystroke, and deliberately not debounced:
   * the store is in memory over there and the answer is a filter of at most 3000
   * rows, so a delay would only be a delay. What *is* guarded is the round trip
   * arriving late — a `stale` flag, because two keystrokes in flight can land
   * out of order and a list that belongs to the previous character is a list
   * that completes the wrong address.
   *
   * The active profile's history and nobody else's, which is the whole point of
   * a profile. An Isolated tab has no profile at all and gets no suggestions,
   * because it also records none.
   */
  const draft = active?.draft ?? ''
  const draftEditing = active?.editing === true
  const isolatedTab = active?.isolated === true
  useEffect(() => {
    if (!historyAvailable(accounts) || !draftEditing || isolatedTab || activeProfileId === '') {
      setSuggestions([])
      return
    }
    const typed = draft.trim()
    if (typed === '') {
      setSuggestions([])
      return
    }
    let stale = false
    void accounts.browserHistorySuggest?.(activeProfileId, typed).then((raw) => {
      if (!stale) setSuggestions(readVisitList(raw))
    })
    return () => {
      stale = true
    }
  }, [accounts, draft, draftEditing, isolatedTab, activeProfileId])

  /*
   * When recording stops, show what was recorded.
   *
   * This is the whole of why the recorder is no longer a permanent band at the
   * bottom. During a recording the one thing that must stay on screen is the
   * page — a popup here parks the native view — so nothing is shown but a
   * counter on the Stop button. The moment recording ends the page stops
   * mattering and the steps start to, so the popup opens by itself. Nobody has
   * to know it is a popup at all.
   */
  const wasRecording = useRef(false)
  useEffect(() => {
    if (wasRecording.current && !recording.recording && recording.steps.length > 0) {
      openAt(null, () => setFlowOpen(true))
    }
    wasRecording.current = recording.recording
  }, [recording.recording, recording.steps.length, openAt])

  /*
   * Ask the main process what Google is doing to this page's sign-in.
   *
   * Per URL, and only ever a question about the address — `browser-signin.ts`
   * explains why it refuses to read the page's text instead. `troubleFor`
   * remembers which address the answer was about, so a dismissed banner stays
   * dismissed while the person keeps typing into the same page, and comes back
   * if they navigate somewhere that is also in trouble.
   */
  const pageUrl = active?.url ?? ''
  useEffect(() => {
    if (!signInHelpAvailable(accounts) || pageUrl === '') {
      setTrouble(null)
      return
    }
    let alive = true
    // The saved-login note is about the page that was on screen when it was
    // written. Carrying it across a navigation leaves "Saved." sitting over a
    // completely different site, which reads as the app having just done
    // something to *that* one.
    setOfferNote('')
    void accounts.browserSignInDiagnose?.(pageUrl).then((raw) => {
      if (!alive) return
      setTrouble(readSignInTrouble(raw))
      setTroubleFor(pageUrl)
    })
    return () => {
      alive = false
    }
  }, [accounts, pageUrl])

  /*
   * A login a page just submitted, offered for saving.
   *
   * Scoped to this panel's own tabs: several browser panels can be mounted at
   * once — a browser page is a row in the sidebar — and the push reaches every
   * one of them, so without the id check the same offer would appear in every
   * open browser panel in the window.
   */
  useEffect(() => {
    if (!passwordsAvailable(accounts) || !accounts.onBrowserPasswordOffer) return
    return accounts.onBrowserPasswordOffer((id, origin, username) => {
      if (!tabsRef.current.some((tab) => tab.id === id)) return
      setOfferNote('')
      setOffer({ id, origin, username })
    })
  }, [accounts])

  /*
   * A drawing belongs to the page it is a picture of.
   *
   * Switching or closing the tab has to end draw mode, and not only for tidiness:
   * the frame is a photograph of the tab that was open, so a canvas that
   * survived the switch would show the old page over the new one and park the
   * new one to do it. Keyed on the view's id rather than on the strip key so it
   * also fires for a tab that was replaced in place — which is what toggling
   * isolation does.
   */
  useEffect(() => {
    setFrame(null)
    setMarks([])
  }, [active?.id])

  const takeScreenshot = useCallback((): void => {
    withId(async (a, id) => {
      const result = await a.browserScreenshot(id)
      setShot(result)
      setNotice(null)
    })
  }, [withId])

  const toggleMobileUa = useCallback(
    (on: boolean): void => {
      setMobileUa(on)
      withId(async (a, id) => {
        await a.browserUserAgent(id, on ? MOBILE_USER_AGENT : null)
        // The User-Agent is read when a document is requested, so the page in
        // front of you was fetched under the old one until it is asked again.
        await a.browserReload(id)
      })
    },
    [withId],
  )

  /* -- keyboard, scoped to this workspace so nothing global is stolen. */
  const onKeyDown = useCallback(
    (event: KeyboardEvent<HTMLDivElement>): void => {
      const mod = event.metaKey || event.ctrlKey
      // Nothing global is bound here. Ctrl-Tab used to cycle this panel's own
      // tabs and is gone with them: it is `session.next` in KEYMAP, and a
      // handler that swallowed it to cycle a one-tab strip made the documented
      // chord do nothing whenever a page had focus. Cmd-L is the address bar,
      // which nothing else claims.
      if (mod && event.key.toLowerCase() === 'l') {
        event.preventDefault()
        setFocusToken((token) => token + 1)
        return
      }
      if (event.altKey && event.key === 'ArrowLeft') {
        event.preventDefault()
        act((a, id) => a.browserBack(id))
        return
      }
      if (event.altKey && event.key === 'ArrowRight') {
        event.preventDefault()
        act((a, id) => a.browserForward(id))
        return
      }
      if (event.key === 'Escape' && frame) {
        // Before the inspect case, and it can never reach it: the modes are
        // exclusive, so `frame` and `inspecting` are never both set. Ordered
        // this way anyway, because a page parked behind a canvas is the state
        // Escape is most urgently for.
        event.preventDefault()
        setFrame(null)
        setMarks([])
        return
      }
      if (event.key === 'Escape' && active?.inspecting) {
        event.preventDefault()
        act((a, id) => a.browserInspect(id, false))
      }
    },
    [act, active?.inspecting, frame],
  )

  /* -- the unwired case, which is what a half-wired preload actually produces. */
  if (!api) {
    return (
      <div className="bw bw-unwired" data-visible={visible}>
        <p className="bw-unwired-title">The browser is not connected</p>
        <p className="bw-unwired-body">
          The preload bridge is missing {missing.length} method{missing.length === 1 ? '' : 's'} this
          panel calls, so there is nothing to open a page with.
        </p>
        {missing.length > 0 && <code className="bw-unwired-list">{missing.join(', ')}</code>}
      </div>
    )
  }

  const resolution = resolveOmnibox(active?.draft ?? '')

  /*
   * The chosen machine, the page's own machine, and the list the start page draws.
   *
   * Three separate questions and they are answered separately on purpose. The
   * *picker* says where the next address goes; the *badge* says where the page
   * already on screen came from, read back off its URL so it survives a link, a
   * reload and the Back button; the *source* is what a new tab lists. A single
   * "current machine" would have made all three the same answer, and the second
   * one is a fact about a tab while the first is a mode of the window.
   */
  const machine = machines.find((one) => one.id === machineId) ?? null
  const served = servedBy(active?.url ?? '', opened)

  /**
   * Move the page that is open onto another machine — or fail where he can see
   * it.
   *
   * Asad, with a page from his PC on screen and the picker switched back to the
   * Mac:
   *
   * > *"if I move it to this machine, it's keeping on the same browser, same
   * > machine. It's not moving to this machine. Same link should be again tried
   * > on the new machine… or it should be unsuccessful here also, because we
   * > always need a truth."*
   *
   * The picker used to be a *mode* and nothing else: it decided where the next
   * thing he typed would go, and left the page already on screen exactly where
   * it was. Read as a mode that is defensible; read as a control labelled with a
   * machine name, sitting over a page, it says the page is on that machine, and
   * it was not.
   *
   * So it moves the page, and the port it moves is the **origin** port — the one
   * on the machine serving it, which is not the number in the address bar
   * whenever the tunnel had to pick a different one. Path, query and fragment
   * ride along through `reachedAddress`.
   *
   * Moving it **home** is not a navigation on its own, and that is what shipped
   * broken in 0.9.0. The tunnel keeps the far port's own number on this machine
   * whenever it was free, so the address this would navigate to — `localhost:`
   * and that number — was the tunnel itself: the page came back from the PC, the
   * picker kept this Mac's name, and the address field printed `Office PC:3100`
   * beside it. So the port is handed back first, and only then is the address
   * used. See `handBack` and `inTheWay`.
   *
   * Three things can make it impossible, and all three put the picker back
   * rather than leaving it naming a machine the page is not on:
   *
   *  - the page is not a machine's page at all (`https://stripe.com` belongs to
   *    Stripe, not to a computer in this room),
   *  - the far machine refused, which `reachPort` has already said out loud, and
   *  - the port could not be given back, so the address still means that machine.
   */
  const moveToMachine = (next: string): void => {
    if (next === machineId) return
    const current = active?.url ?? ''
    const plan = moveFor(next, current, opened)
    setMachineId(next)
    // `choose` is a tab with no page in it: the picker is only saying where the
    // next address opens, which is what it did before it could move anything.
    if (plan.kind === 'already' || plan.kind === 'choose') return
    if (plan.kind === 'refused') {
      // Back to the machine the page is really on, and three words for why. A
      // picker left naming a machine the page never reached is the untruth this
      // whole change is about — but the reason was a full sentence with its own
      // consequence clause bolted on ("…, so it cannot be moved"), which is the
      // habit he struck out: *"don't put any single statement in anywhere."*
      // The snap-back already says it could not be moved. What it cannot say is
      // why, and that is a noun phrase.
      setMachineId(plan.at)
      setNotice('Not a machine’s page.')
      return
    }
    if (plan.kind === 'here') {
      /*
       * The tunnel is handed back before the address is used, and this is the
       * whole of the 0.9.0 defect.
       *
       * `plan.url` is `localhost:<the port over there>`, and on the ordinary
       * rung that number is exactly what the tunnel took on this machine — so
       * navigating to it fetched the page from the PC again while the picker
       * said this Mac. Once the listener is gone the number means this computer,
       * and the page either loads from it or Chromium says it was refused, which
       * is the answer he asked for: *"it should be unsuccessful here also,
       * because we always need a truth."*
       */
      if (plan.give === null) {
        act((a, id) => a.browserNavigate(id, plan.url))
        return
      }
      const held = plan.give
      void handBack(held).then((gone) => {
        if (!gone) {
          // Nothing moved, so the picker must not say it did. The port is still
          // that machine's, which is the one fact the sentence has to carry.
          setMachineId(held.machineId)
          setNotice(`${held.machineName} is still serving port ${held.localPort} here.`)
          return
        }
        act((a, id) => a.browserNavigate(id, plan.url))
      })
      return
    }
    const target = machines.find((one) => one.id === plan.machineId)
    if (!target) {
      setMachineId(plan.kind === 'there' ? (servedBy(current, opened)?.machineId ?? THIS_MACHINE) : next)
      return
    }
    void openThere(target, plan.port, plan.url).then((moved) => {
      // `reachPort` has already put the reason in the notice bar. What is left
      // is the picker, which must not keep claiming a machine the page is not on.
      if (!moved) setMachineId(servedBy(current, opened)?.machineId ?? THIS_MACHINE)
    })
  }
  /*
   * A server's list has a third state a device's cannot have.
   *
   * A device scans its own ports with the same tool this machine uses, so it
   * either answers or is offline. A server can be reachable, willing, and have
   * no tool installed for listing what is listening — and `null` there means
   * "still asking", so the page waits rather than claiming nothing is running.
   */
  const serverSource = machine?.kind === 'server' ? portSourceFor(serverPorts[machine.id]) : null
  const portSource: PortSource | null =
    machine === null
      ? null
      : {
          name: machine.name,
          /*
           * Which mark the rows wear, and it is passed rather than inferred.
           *
           * `StartPage` draws a machine's own icon beside every port so a remote
           * list is distinguishable from this machine's at a glance — his
           * words: *"with the machine's icon beside them"*. It falls back to the
           * desktop mark when this is absent, which is right for every caller
           * that predates servers, and wrong for a server. This is the one place
           * that knows which it is.
           */
          kind: machine.kind,
          ports: serverSource ? serverSource.ports : machine.ports,
          cannot: serverSource?.cannot ?? null,
          open: (port) => {
            // The address a person would have typed, so that what lands in the
            // bar and in history is the page — not the row that was clicked.
            void openThere(machine, port, `http://localhost:${port}/`)
          },
          refresh: () => {
            // "I have just started something over there", for either kind. A
            // device is nudged down a connection this desktop holds; a server
            // is asked again, which is a fresh probe on the connection it is
            // already holding for the page.
            if (machine.kind === 'server') askServer(machine.id)
            else void machinesApi?.refreshMachinePorts(machine.id).catch(() => undefined)
          },
        }

  /*
   * Absent until there is somewhere else to go.
   *
   * A dropdown whose only entry is "This machine" is chrome answering a question
   * nobody with one computer has asked, and the standing rule in this panel is
   * that a control which cannot do anything is not drawn. With a machine paired
   * it appears, and the browser is still the same browser — one window, one tab
   * strip, one address bar, with a word beside it saying which computer that
   * address is on.
   */
  /*
   * Which machine, and which session — the two facts about this window, side by
   * side.
   *
   * The session control is here rather than in the toolbar's own tree because
   * this panel is what knows the shell tab id, and because the two questions are
   * neighbours: *"from the browser directly, I cannot connect to any session. It
   * should be either here or somewhere."* Handed down as one node so the
   * toolbar's layout decides where the pair sits, exactly as it already did for
   * the picker alone.
   */
  const connect = tabId ? <ConnectSessionButton browserTabId={tabId} /> : null
  const machinePart =
    machines.length > 0 ? (
      <MachinePicker machines={machines} here={here} selected={machineId} onSelect={moveToMachine} />
    ) : null
  const picker =
    connect === null && machinePart === null ? undefined : (
      <>
        {connect}
        {machinePart}
      </>
    )

  /*
   * Which still image stands in for the page while a popup is over it.
   *
   * The capture's own photograph first, because a capture popup is anchored to
   * something on the page and the page has to look unchanged behind it. The
   * screenshot popup reuses the shot it is already showing, which is a picture
   * of the same page by definition. Empty in both cases means the main process
   * could not take one, and then nothing is drawn at all — never a placeholder.
   */
  // Nothing while drawing: the canvas paints its own frame, and a second image
  // of the same page underneath it is a second chance to be a pixel out.
  const frozen = frame ? '' : capture?.pageImage || (shot ? shot.preview : '') || ''

  /*
   * The one instruction sentence, decided in `modes.ts` from the mode state.
   *
   * Read here rather than inline in the JSX so the rule is one testable function
   * instead of three conditions in a tree this project's test run cannot render.
   */
  const hint = modeHint(
    {
      inspecting: active?.inspecting === true,
      recording: recording.recording,
      drawing: frame !== null,
    },
    { hasCapture: capture !== null },
  )

  return (
    <div className="bw" ref={rootRef} data-visible={visible} onKeyDown={onKeyDown}>
      <Toolbar
        tab={active}
        progress={active?.progress ?? 0}
        resolution={resolution}
        focusToken={focusToken}
        onDraft={(value) =>
          setTabs((prev) => withTab(prev, activeKey, { draft: value, editing: true }))
        }
        onEditing={(editing) => setTabs((prev) => withTab(prev, activeKey, { editing }))}
        onSubmit={() => navigate(active?.draft ?? '')}
        onBack={() => act((a, id) => a.browserBack(id))}
        onForward={() => act((a, id) => a.browserForward(id))}
        onReload={() => act((a, id) => a.browserReload(id))}
        onStop={() => act((a, id) => a.browserStop(id))}
        onHome={() => navigate(startUrl)}
        onInspect={() => toggleMode('inspect')}
        onRecord={toggleRecording}
        onScreenshot={takeScreenshot}
        onDevtools={() =>
          withId(async (a, id) => {
            const open = await a.browserDevtools(id)
            setDevtools((prev) => ({ ...prev, [activeKey]: open }))
          })
        }
        devtoolsOpen={devtools[activeKey] === true}
        recording={recording.recording}
        onDraw={drawAvailable(drawApi) ? () => toggleMode('draw') : undefined}
        drawing={frame !== null}
        deviceOpen={deviceOpen}
        onToggleDevice={() => setDeviceOpen((open) => !open)}
        onToggleIsolation={isolationAvailable(iso) ? toggleIsolation : undefined}
        actionsRef={actionsRef}
        menuRef={menuButtonRef}
        profileRef={profileButtonRef}
        downloadsRef={downloadsButtonRef}
        downloadsBadge={downloadsAvailable(downloads) ? downloadsBadge(downloadsView.items) : null}
        downloadsOpen={downloadsOpen}
        onDownloads={
          downloadsAvailable(downloads)
            ? () =>
                openAt(downloadsButtonRef.current, () => {
                  // One popup at a time on this bar, for the reason the ⋯ and the
                  // profile menus already close each other: they are adjacent
                  // buttons and two popups on one anchor stack invisibly.
                  setMenuOpen(false)
                  setProfileOpen(false)
                  setDownloadsOpen((open) => !open)
                })
            : undefined
        }
        menuOpen={menuOpen}
        onMenu={() =>
          openAt(menuButtonRef.current, () => {
            // One menu at a time. They are adjacent buttons sharing one anchor
            // rectangle, so leaving both open would stack two popups on the same
            // pixels with the newer one silently on top of the older.
            setProfileOpen(false)
            setMenuOpen((open) => !open)
          })
        }
        onProfiles={
          profilesAvailable(accounts)
            ? () =>
                openAt(profileButtonRef.current, () => {
                  setMenuOpen(false)
                  setProfileOpen((open) => !open)
                })
            : undefined
        }
        profilesOpen={profileOpen}
        profileName={profileName}
        profileAvatar={activeProfile?.avatar ?? ''}
        /* Earlier addresses, from this profile's own history. The bar draws the
           list and moves through it; where the rows come from and what a press
           means are this panel's business. */
        suggestions={suggestions}
        onPick={(url) => {
          setSuggestions([])
          navigate(url)
        }}
        steps={recording.steps.length}
        machinePicker={picker}
        /*
          Where this page is actually being fetched from — never an absence.

          Asad: *"we always need a truth. So we will not know the truth if we
          remove from inside where it is exactly running. So just be sure we
          always be able to see the truth."*

          The whole rule is `barServed` in `served-mark.ts`, and it is there
          rather than here because a rule inside a render tree is a rule this
          project's DOM-less test run cannot hold — which is how the case it was
          missing survived: with the picker on another machine and a tab that had
          been nowhere, this asserted a machine for a page that does not exist.
          The four states, and the two sentences of his they come out of, are
          written down over that function and in the header of that file.
        */
        servedBy={barServed({
          page: served,
          picked: machineId,
          // A panel with no tab at all is as blank as a tab that has been nowhere.
          blank: active === null || onStartPage(active),
          here,
        })}
      />

      {/*
        Between the toolbar and the stage, deliberately.

        It cannot go over the page: a browser page here is a native child view
        of the window, composited above the entire renderer, and
        `overlay-watch.ts` is the standing essay on why no z-index reaches it.
        As a block in the flow it shrinks the page's rectangle instead of
        covering it, so the site reflows once when a drive starts and not again
        while it runs.
      */}
      {/*
        And only over the page it is actually about.

        The status names the page it describes — `tabId` is the main-process view
        id, the same one a tab here carries — and until now nothing compared
        them, because the drive held exactly one page and `idle` was taken to
        mean "nobody anywhere". A session's agent can now hold several at once,
        so a banner drawn on whatever tab happened to be in front would read
        *"Copilot is driving"* over a page nobody is touching. Photographed on
        2026-08-20, over a window belonging to a different session.

        `IDLE_DRIVE` rather than a conditional render so the banner keeps
        occupying no space in exactly the way it did when nothing was driving.
      */}
      <DriveBanner
        status={drive.tabId !== null && drive.tabId === active?.id ? drive : IDLE_DRIVE}
        onResume={(carryOn) => driveApi.browserDriveResume?.(carryOn)}
      />

      {/*
        The two account bands, in the flow for the same reason `DriveBanner` is:
        a browser page is a native view composited above this entire renderer, so
        nothing HTML can be drawn on top of it. As blocks they shrink the page's
        rectangle instead of covering it, which means the site reflows once when
        one appears and the website stays visible underneath — which is the whole
        point of telling somebody their sign-in is about to be refused.
      */}
      {trouble && troubleFor === pageUrl && (
        <SignInBanner
          trouble={trouble}
          api={accounts}
          url={pageUrl}
          onDismiss={() => setTrouble(null)}
        />
      )}

      {offer && (
        <PasswordOffer
          origin={offer.origin}
          username={offer.username}
          api={accounts}
          onAnswered={(message) => {
            setOffer(null)
            setOfferNote(message)
          }}
        />
      )}

      {offerNote !== '' && (
        <p className="bw-said" role="status">
          {offerNote}
          <button type="button" className="bw-text-button" onClick={() => setOfferNote('')}>
            Dismiss
          </button>
        </p>
      )}

      {/*
        Draw mode's controls, in a strip under the toolbar rather than a popup.

        Two reasons, and neither is taste. Draw mode has already parked the
        native page and put a canvas where it was, so there is no website on
        screen for a strip to shrink — the clear view he asked for is not at
        stake here. And a popup would float over the top right of the canvas,
        which is a part of the picture somebody is trying to draw on.
      */}
      {frame && (
        <div className="bw-strip">
          <DrawPanel
            tool={tool}
            markCount={marks.length}
            ready={!saving}
            onTool={setTool}
            onUndo={() => setMarks(undoMark)}
            onClear={() => setMarks([])}
            onSend={sendMarked}
            onCancel={() => toggleMode('draw')}
          />
        </div>
      )}

      {deviceOpen && (
        <DeviceBar
          presetId={presetId}
          orientation={orientation}
          customWidth={customWidth}
          customHeight={customHeight}
          applied={fit.applied}
          clamped={fit.clamped}
          zoom={zoom}
          mobileUserAgent={mobileUa}
          onPreset={setPresetId}
          onRotate={() =>
            setOrientation((current) => (current === 'portrait' ? 'landscape' : 'portrait'))
          }
          onCustom={(axis, value) => {
            setPresetId(CUSTOM_ID)
            if (axis === 'width') setCustomWidth(value)
            else setCustomHeight(value)
          }}
          onZoom={(delta) => applyZoom(stepZoom(zoom, delta))}
          onResetZoom={() => applyZoom(1)}
          onMobileUserAgent={toggleMobileUa}
        />
      )}

      {/* Only for a failure the page survived — a blocked pop-up, a refused
          scheme. A failed *load* is written across the start page instead, and
          printing it in both places would say the same sentence twice, a
          centimetre apart. */}
      {active?.error && !active.failed && (
        <p className="bw-error" role="status">
          {active.error}
        </p>
      )}

      {notice && (
        <p className="bw-error" role="status">
          {notice}
          <button type="button" className="bw-text-button" onClick={() => setNotice(null)}>
            Dismiss
          </button>
        </p>
      )}

      {/* Not in the band above it, and the colour is the whole reason: that one
          is the critical colour and this page loaded. See `portNote`. */}
      {portNote !== '' && (
        <p className="bw-said" role="status">
          {portNote}
          <button type="button" className="bw-text-button" onClick={() => setPortNote('')}>
            Dismiss
          </button>
        </p>
      )}

      {/*
        One instruction strip, and only while it is the instruction.

        There were two on screen at once: this line under the toolbar, and the
        bottom panel's "Turn on Inspect, then click something in the page to
        capture its selector." The second one told him to do the thing he was
        already doing. The bottom panel that carried it is gone — an element is a
        popup now — and adding a third mode was the obvious way to bring the
        second one back, so the sentence is chosen by `modeHint` rather than by
        conditions written out here. The modes are exclusive, so that function
        can only ever return one string; there is no arrangement of state that
        puts two of these on screen. It goes silent the moment the thing it asked
        for exists, because the popup, or the mark, is the instruction then.
      */}
      {hint && (
        <p className="bw-hint" role="status">
          {hint}
        </p>
      )}

      {/* Deliberately empty: the native view is painted over this rectangle. */}
      <div className="bw-stage" ref={stageRef} data-framed={deviceSize !== null || undefined}>
        {/* The plus this used to point at was in the panel's own tab strip. A
            browser page is a row in the sidebar now, so that is where a second
            one is opened from — and naming the control that exists is the
            difference between an empty state and a dead end. */}
        {tabs.length === 0 && (
          <p className="bw-empty">No page open. Use New browser tab in the sidebar to open one.</p>
        )}
        {/*
          Terminal Deck's own page, on the rectangle the native view would
          otherwise hold. Two occasions, and the second one is the fix for the
          first thing he saw on Windows: a new tab, and a tab whose load failed
          — where without this the user is looking at Chromium's red
          "connection refused" document with no way out of it but the toolbar.
        */}
        {active && onStartPage(active) && (
          <StartPage
            onOpen={(url) => navigate(url)}
            source={portSource}
            failure={
              active.failed && active.error
                ? { message: active.error, url: active.url || active.draft }
                : null
            }
            onRetry={active.failed ? () => act((a, id) => a.browserReload(id)) : undefined}
          />
        )}
        {/*
          The page, held still, while a popup is over it.

          A popup is HTML and the page is a native layer above the whole
          renderer, so the page has to be hidden for the popup to be seen at all
          — `overlay-watch.ts` explains why there is no third option. Hiding it
          on its own leaves the app's empty canvas where the website was, and a
          website that disappears when you click it reads as a crash.

          This is a real photograph of that page, taken by the main process at
          the instant of the click (or, for a screenshot, the shot itself). It
          is drawn on the same rectangle the view occupies, so the page appears
          to freeze rather than to go. Nothing here is reconstructed: when there
          is no image, there is no element, and the canvas shows through as
          before.
        */}
        {frozen && (
          <img
            className="bw-freeze"
            src={frozen}
            alt=""
            aria-hidden="true"
            style={{
              left: fit.rect.x - stage.x,
              top: fit.rect.y - stage.y,
              width: fit.rect.width,
              height: fit.rect.height,
            }}
          />
        )}
        {/*
          Draw mode's canvas, on the page's own rectangle.

          Not over the live page — nothing can be. A browser page is a native
          view composited above this entire renderer, so the arrangement that
          works is the one `overlay-watch.ts` describes: park the view and draw a
          photograph of it. The canvas holds both the photograph and the marks,
          which is also why the PNG that reaches the agent is exactly what was on
          screen — it is this element, read back.

          It replaces `bw-freeze` for the duration rather than sitting on top of
          it: two images of the same page, one of them a JPEG backdrop, would be
          two chances to be a pixel out.
        */}
        {frame && (
          <DrawLayer
            frame={frame}
            marks={marks}
            tool={tool}
            rect={fit.rect}
            origin={stage}
            onMarks={setMarks}
            surface={surface}
          />
        )}
        {deviceSize !== null && tabs.length > 0 && (
          <span
            className="bw-frame"
            aria-hidden="true"
            style={{
              left: fit.rect.x - stage.x,
              top: fit.rect.y - stage.y,
              width: fit.rect.width,
              height: fit.rect.height,
            }}
          />
        )}
      </div>

      {/*
        The two popups, both anchored to something real on the page: the element
        that was clicked, and — for a screenshot, which is of the whole page —
        the top of the page's own rectangle.

        Both are portalled into `<body>`, so `overlay-watch.ts` sees them and the
        native view parks while they are open. That is not incidental: a
        `WebContentsView` composites above the entire renderer, so a popup that
        did *not* park the page would be painted behind the website and could not
        be seen at all. See `AnchoredPopup`.
      */}
      {capture && (
        <CapturePopup
          // Remount per element. The typed line and the "Sent" state belong to
          // the thing that was clicked; carrying them over means the button
          // reads Sent about an element nobody has sent.
          key={[activeKey, capture.selector, capture.url].join('|')}
          capture={capture}
          anchor={anchorInWindow(capture.rect, fit.rect)}
          agent={agent}
          onClose={() =>
            setCaptures((prev) => {
              const next = { ...prev }
              delete next[activeKey]
              return next
            })
          }
        />
      )}

      {shot && (
        <ScreenshotPopup
          key={shot.path}
          shot={shot}
          anchor={{ x: fit.rect.x, y: fit.rect.y, width: fit.rect.width, height: 0 }}
          agent={agent}
          onReveal={(path) => void api.browserRevealScreenshot(path)}
          onClose={() => setShot(null)}
        />
      )}

      {/*
        The recorded flow, as a popup in the top right corner.

        `onCopy` and the session picker come with it unchanged — this is the
        same panel that used to be docked at the bottom, in a place where it is
        not between the person and the website. It opens itself when a recording
        stops and is reachable from the menu afterwards; it is deliberately
        unreachable *during* a recording, because opening it would park the page
        being recorded.
      */}
      {flowOpen && (
        <AnchoredPopup anchor={menuAnchor} label="Recorded flow" onClose={() => setFlowOpen(false)}>
          <RecorderPanel
            state={recording}
            agent={agent}
            onStop={toggleRecording}
            onClear={() =>
              withId(async (a, id) => {
                const state = await a.browserRecordClear(id)
                setRecordings((prev) => ({ ...prev, [activeKey]: state }))
              })
            }
            onCopy={copyFlow}
            copied={copied}
          />
        </AnchoredPopup>
      )}

      {menuOpen && (
        <BrowserMenu
          api={accounts}
          anchor={menuAnchor}
          url={active?.url ?? ''}
          startUrl={startUrl}
          onStartUrl={onStartUrl}
          onSettings={onSettings}
          /* Only where the preload has wired history and the tab belongs to a
             profile. An Isolated tab records nothing, so there would be nothing
             to open — and a row that opens an empty list somebody knows they
             filled is worse than no row. */
          onHistory={
            historyAvailable(accounts) && activeProfileId !== '' && active?.isolated !== true
              ? () => setHistoryFor(activeProfileId)
              : undefined
          }
          onFlow={recording.steps.length > 0 ? () => openAt(null, () => setFlowOpen(true)) : undefined}
          /* Only when there is no profile button to hold it — see `onCookies`
             in `BrowserMenu`. Site data belongs to a profile, and a build that
             cannot switch profiles still has to be able to clear its cookies. */
          onCookies={profilesAvailable(accounts) ? undefined : () => setSessionFor('')}
          /*
             The standing door. The button on the bar comes and goes with the
             list — see `downloadsBadge` — so this is the one place downloads can
             always be reached from, which is what makes the button's absence
             acceptable rather than a feature that hides.
          */
          onDownloads={
            downloadsAvailable(downloads)
              ? () => openAt(menuButtonRef.current, () => setDownloadsOpen(true))
              : undefined
          }
          onClose={() => setMenuOpen(false)}
        />
      )}

      {downloadsOpen && (
        <DownloadsPanel
          api={downloads}
          anchor={menuAnchor}
          view={downloadsView}
          machines={machines}
          here={here}
          onClose={() => setDownloadsOpen(false)}
        />
      )}

      {profileOpen && (
        <ProfileMenu
          api={accounts}
          anchor={menuAnchor}
          /* How many sites have data in a *named* profile. Every partition can
             be enumerated now — `browser-session.ts` takes the id and resolves
             it — which is what lets the menu answer for every row instead of
             the one that happens to be switched on. Absent when the bridge is
             not resolved and the panel is already refusing to draw a page. */
          countSites={
            api ? async (profileId: string) => (await api.browserCookies(profileId)).length : undefined
          }
          onSiteData={(profileId: string) => setSessionFor(profileId)}
          onOpenProfile={(profileId: string) => {
            // The menu closes behind it: the section is a dialog over the same
            // corner, and leaving a popup open underneath one is two surfaces
            // fighting for the same pixels — the arrangement `openAt` exists to
            // prevent between the two menus.
            setProfileOpen(false)
            setSettingsFor(profileId)
          }}
          onReopen={reopenInActiveProfile}
          /* Only where the preload can answer about workers. A row that opened
             a panel with nothing in it would be the dead control this menu was
             rebuilt to be rid of. */
          onOpenWorkers={workersAvailable(workersApi) ? () => setWorkersOpen(true) : undefined}
          onClose={() => {
            setProfileOpen(false)
            readProfileName()
          }}
        />
      )}

      {/*
        Worker profiles, and the one control in this app that copies a login.

        `viewId` is the page in front of the person, which is what makes the
        lift a gesture *on a page they are looking at* rather than an action
        against a site named in a field — see `WorkersPanel.tsx` and
        `browser-session-lift.ts`. With no page open there is nothing to lift
        and the button is absent rather than greyed.
      */}
      <WorkersPanel
        open={workersOpen}
        api={workersApi}
        viewId={active?.id ?? ''}
        pageUrl={active?.url ?? ''}
        onOpenInWorker={(profileId: string) => openNewTab('', false, false, undefined, profileId)}
        onClose={() => setWorkersOpen(false)}
      />

      <SessionModal
        open={sessionOpen}
        bridge={api}
        profileId={sessionFor ?? ''}
        profileName={sessionFor ? (profileOf(sessionFor)?.name ?? profileName) : profileName}
        isolated={active?.isolated === true}
        onClose={() => setSessionFor(null)}
      />

      {/*
        A profile's own section, and its history.

        Both are dialogs rather than popups, and for a reason the popups on this
        bar cannot get around: a menu is anchored to the button that opened it
        and is sized for rows of a few words, and neither a rename field nor a
        day-by-day list of visits is that. They park the page exactly as a popup
        does — see `overlay-watch.ts` — so both are built to be left quickly.
      */}
      <ProfileSettings
        open={settingsFor !== null}
        api={accounts}
        profileId={settingsFor ?? ''}
        onChanged={readProfileName}
        onSiteData={(profileId: string) => {
          setSettingsFor(null)
          setSessionFor(profileId)
        }}
        onHistory={(profileId: string) => {
          setSettingsFor(null)
          setHistoryFor(profileId)
        }}
        onClose={() => setSettingsFor(null)}
      />

      <HistoryPanel
        open={historyFor !== null}
        api={accounts}
        profileId={historyFor ?? ''}
        profileName={historyFor === null ? '' : (profileOf(historyFor)?.name ?? '')}
        profileAvatar={historyFor === null ? '' : (profileOf(historyFor)?.avatar ?? '')}
        /* A row press is a navigation of this tab, through the same door the
           address bar uses — so a machine picker pointing somewhere else is
           still obeyed, and a page that fails still fails in one place. With no
           page open there is no tab to navigate, and `act` would return in
           silence: a press that does nothing. It opens one instead. */
        onOpenUrl={(url: string) => {
          if (active) navigate(url)
          else openNewTab(url, false)
        }}
        onClose={() => setHistoryFor(null)}
      />
    </div>
  )
}
