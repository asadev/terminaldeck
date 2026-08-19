import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import { BrowserMenu } from './BrowserMenu'
import { CapturePopup } from './CapturePopup'
import { DeviceBar } from './DeviceBar'
import { PasswordOffer } from './PasswordOffer'
import { SignInBanner } from './SignInBanner'
import { DrawLayer, type DrawSurface } from './DrawLayer'
import { DriveBanner } from './DriveBanner'
import { DrawPanel } from './DrawPanel'
import { RecorderPanel } from './RecorderPanel'
import { ScreenshotPopup } from './ScreenshotPopup'
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
import { anchorInWindow, type Box } from './popup-anchor'
import {
  passwordsAvailable,
  readSignInTrouble,
  resolveAccountsApi,
  signInHelpAvailable,
  type SignInTrouble,
} from './accounts-bridge'
import { useAgentTarget } from './useAgentTarget'
import type { AgentSessionBridge } from './agent-target'
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
import { resolveOmnibox, securityOf } from './omnibox'
import { browserOverlayDom, isCovered, watchOverlays, type Rect as OverlayRect } from './overlay-watch'
import { MachinePicker } from './MachinePicker'
import {
  destinationFor,
  differentPortNote,
  lostMachine,
  machineChoices,
  readMachines,
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
  /** Persist a new start page — the panel's own "set as start page" button. */
  onStartUrl?: (url: string) => void
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
  startUrl = '',
  initialUrl = '',
  onStartUrl,
  bridge,
  sessionBridge,
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
  const agent = useAgentTarget(sessionBridge)
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

  const [sessionOpen, setSessionOpen] = useState(false)
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
  const [flowOpen, setFlowOpen] = useState(false)
  const [trouble, setTrouble] = useState<SignInTrouble | null>(null)
  const [troubleFor, setTroubleFor] = useState('')
  const [offer, setOffer] = useState<{ id: string; origin: string; username: string } | null>(null)
  const [offerNote, setOfferNote] = useState('')
  const accounts = useMemo(() => resolveAccountsApi(), [])
  const [focusToken, setFocusToken] = useState(0)

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
   */
  const [opened, setOpened] = useState<ReachedPort[]>([])
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
   * The toolbar's right-hand action group, which every popup in this panel is
   * now placed against.
   *
   * One anchor for all of them rather than one per button: `anchorPopup` slides
   * a popup back inside the viewport, so anchoring to a cluster that already
   * sits at the right edge lands every popup in the top right corner — which is
   * where he asked for them — without each button having to carry a ref.
   */
  const actionsRef = useRef<HTMLDivElement | null>(null)
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
  const [overlays, setOverlays] = useState<OverlayRect[]>([])
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
       * One panel answers, and only one.
       *
       * A browser page is a row in the sidebar, so several of these components
       * can be mounted at once and the push reaches every one of them. Without
       * the claim, one `browser.open` would open a tab in each panel and the
       * main process would use the first reply — leaving the rest as pages
       * nobody asked for, in panels nobody was looking at.
       */
      if (!claimDriveOpen(request.id)) return
      openNewTab(request.url, false, request.isolate, (tabId) => {
        driveApi.browserDriveOpened?.(request.id, tabId)
      })
    })
  }, [driveApi, openNewTab])

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
      if (alive) setMachineView(machineChoices(readMachines(raw)))
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
      // Said once, when it happens, rather than left to be discovered by a link
      // inside the site going somewhere strange. Set to '' on the ordinary case
      // as well, so a caveat about the last port does not sit above a page it is
      // not true of.
      setPortNote(differentPortNote(answer, machine.name))
      return answer
    },
    [machinesApi, serversApi],
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
    async (machine: MachineChoice, port: number, typed: string): Promise<void> => {
      const answer = await reachPort(machine, port)
      if (!answer) return
      act((a, id) => a.browserNavigate(id, reachedAddress(typed, answer.url)))
    },
    [reachPort, act],
  )

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
      act((a, id) => a.browserNavigate(id, target.url))
    },
    [act, machineId, machines, openThere],
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
   * Measure the toolbar, then open whichever popup was asked for.
   *
   * Measured at the moment of opening rather than kept in state and updated on
   * resize. The toolbar moves whenever the window is resized, the panel becomes
   * half of a split, or a band above it appears — and a stale anchor is a popup
   * pointing at where a button used to be, which is worse than one that is
   * placed a frame later.
   */
  const openAt = useCallback((open: () => void): void => {
    const node = actionsRef.current
    if (node) {
      const box = node.getBoundingClientRect()
      setMenuAnchor({ x: box.x, y: box.y, width: box.width, height: box.height })
    }
    open()
  }, [])

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
      openAt(() => setFlowOpen(true))
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
  const security = securityOf(active?.url ?? '')

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
  const picker =
    machines.length > 0 ? (
      <MachinePicker machines={machines} selected={machineId} onSelect={setMachineId} />
    ) : undefined

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
        security={security}
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
        menuOpen={menuOpen}
        onMenu={() => openAt(() => setMenuOpen((open) => !open))}
        steps={recording.steps.length}
        machinePicker={picker}
        servedBy={
          served && {
            name: served.machineName,
            port: served.port,
            localPort: served.localPort,
            sameNumber: served.sameNumber,
          }
        }
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
      <DriveBanner status={drive} onResume={(carryOn) => driveApi.browserDriveResume?.(carryOn)} />

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
          onCookies={() => setSessionOpen(true)}
          onFlow={recording.steps.length > 0 ? () => openAt(() => setFlowOpen(true)) : undefined}
          onReopen={reopenInActiveProfile}
          onClose={() => setMenuOpen(false)}
        />
      )}

      <SessionModal
        open={sessionOpen}
        bridge={api}
        isolated={active?.isolated === true}
        onClose={() => setSessionOpen(false)}
      />
    </div>
  )
}
