import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react'
import { CapturePanel } from './CapturePanel'
import { DeviceBar } from './DeviceBar'
import { RecorderPanel } from './RecorderPanel'
import { SessionModal } from './SessionModal'
import { Toolbar } from './Toolbar'
import {
  appCanvasColor,
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
import { resolveOmnibox, securityOf } from './omnibox'
import { browserOverlayDom, isCovered, watchOverlays, type Rect as OverlayRect } from './overlay-watch'
import { StartPage } from './StartPage'
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
  /** Persist a new start page — the panel's own "set as start page" button. */
  onStartUrl?: (url: string) => void
  /** Receives a single line for the agent. Absent means no session is focused. */
  onSendToAgent?: (text: string) => void
  /** Injectable for tests; defaults to the preload bridge on `window.deck`. */
  bridge?: BrowserBridge
  /**
   * Per-tab isolation, which is optional rather than required.
   *
   * Separate from `bridge` because a preload without it should cost one toggle,
   * not the whole browser panel — see `isolation-bridge.ts`.
   */
  isolation?: IsolationApi
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
  onStartUrl,
  onSendToAgent,
  bridge,
  isolation,
}: BrowserWorkspaceProps) {
  const api = useMemo(() => bridge ?? resolveBrowserBridge(), [bridge])
  const iso = useMemo(() => isolation ?? resolveIsolationApi(), [isolation])
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

  const [bottom, setBottom] = useState<'capture' | 'flow'>('capture')
  const [sessionOpen, setSessionOpen] = useState(false)
  const [shot, setShot] = useState<ScreenshotResult | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [copied, setCopied] = useState(false)
  const [focusToken, setFocusToken] = useState(0)

  /** Read inside the mount effect, which must not re-run when it changes. */
  const homeRef = useRef(startUrl)
  homeRef.current = startUrl

  const stageRef = useRef<HTMLDivElement | null>(null)
  const rootRef = useRef<HTMLDivElement | null>(null)
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
  }, [tabs.length, deviceOpen, bottom, capture, recording.steps.length, shot, notice])

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
        pageVisible(tab, { isActive, visible, parkPage, sessionOpen, covered }),
      )
    }
  }, [api, tabs, activeKey, fit, visible, parkPage, sessionOpen, covered])

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
      setBottom('capture')
    })
    const offProgress = api.onBrowserProgress((id, next) => {
      setTabs((prev) => withTabId(prev, id, { progress: next.fraction }))
    })
    const offRecording = api.onBrowserRecording((id, state) => {
      const tab = tabForId(tabsRef.current, id)
      if (!tab) return
      setRecordings((prev) => ({ ...prev, [tab.key]: state }))
      setTabs((prev) => withTab(prev, tab.key, { recording: state.recording }))
      if (state.steps.length > 0) setBottom('flow')
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
    (url: string, focusAddress = true, isolated = false): string => {
      if (!api) return ''
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
          return
        }
        const claimed = await api.browserClaim(state.id)
        const factor = claimed.ok ? await api.browserZoom(state.id, null).catch(() => 1) : 1
        setTabs((prev) => withTab(prev, key, patchFrom(state)))
        setZooms((prev) => ({ ...prev, [key]: factor }))
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

  /* -- first tab, and cleanup. */
  useEffect(() => {
    if (!api) return
    if (tabsRef.current.length === 0) openNewTab(homeRef.current, false)
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

  const navigate = useCallback(
    (input: string): void => {
      const resolution = resolveOmnibox(input)
      if (resolution.kind === 'empty') return
      setTabs((prev) => withTab(prev, activeRef.current, { editing: false }))
      act((a, id) => a.browserNavigate(id, resolution.url))
    },
    [act],
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

  /* -- the extras, all of which need the claimed view. */
  const withId = useCallback(
    (run: (api: BrowserBridge, id: string) => Promise<void>): void => {
      const id = active?.id
      if (!api || !id) return
      void run(api, id).catch((cause: unknown) => {
        setNotice(cause instanceof Error ? cause.message : String(cause))
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

  const toggleRecording = useCallback((): void => {
    const key = activeRef.current
    const on = !(recordings[key]?.recording ?? false)
    withId(async (a, id) => {
      const state = await a.browserRecord(id, { on, accent: recordingAccent() })
      setRecordings((prev) => ({ ...prev, [key]: state }))
      setTabs((prev) => withTab(prev, key, { recording: state.recording }))
      setBottom('flow')
    })
  }, [recordings, withId])

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
      if (event.key === 'Escape' && active?.inspecting) {
        event.preventDefault()
        act((a, id) => a.browserInspect(id, false))
      }
    },
    [act, active?.inspecting],
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
        onInspect={() => act((a, id) => a.browserInspect(id, !active?.inspecting))}
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
        deviceOpen={deviceOpen}
        onToggleDevice={() => setDeviceOpen((open) => !open)}
        onOpenSession={() => setSessionOpen(true)}
        onToggleIsolation={isolationAvailable(iso) ? toggleIsolation : undefined}
      />

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

      {shot && (
        <p className="bw-shot" role="status">
          Saved {shot.width} x {shot.height} to <code>{shot.path}</code>
          <button
            type="button"
            className="bw-text-button"
            onClick={() => void api.browserRevealScreenshot(shot.path)}
          >
            Reveal
          </button>
          <button type="button" className="bw-text-button" onClick={() => setShot(null)}>
            Dismiss
          </button>
        </p>
      )}

      {active?.inspecting && (
        <p className="bw-hint" role="status">
          Click any element in the page. Escape stops.
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
            failure={
              active.failed && active.error
                ? { message: active.error, url: active.url || active.draft }
                : null
            }
            onRetry={active.failed ? () => act((a, id) => a.browserReload(id)) : undefined}
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

      <div className="bw-bottom">
        <div className="bw-bottom-tabs" role="tablist" aria-label="Browser output">
          <button
            type="button"
            role="tab"
            aria-selected={bottom === 'capture'}
            data-on={bottom === 'capture' || undefined}
            onClick={() => setBottom('capture')}
          >
            Element
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={bottom === 'flow'}
            data-on={bottom === 'flow' || undefined}
            onClick={() => setBottom('flow')}
          >
            Flow{recording.steps.length > 0 ? ` (${recording.steps.length})` : ''}
          </button>
          <span className="bw-spacer" />
          <button
            type="button"
            className="bw-text-button"
            title="Open this page every time"
            disabled={!onStartUrl || !active?.url || active.url === startUrl}
            onClick={() => {
              const url = active?.url
              if (url) onStartUrl?.(url)
            }}
          >
            {active?.url && active.url === startUrl ? 'Start page' : 'Set as start page'}
          </button>
        </div>

        {bottom === 'capture' ? (
          capture ? (
            <CapturePanel
              // Remount per element. `sent` and the instruction field belong to
              // the thing that was clicked, and carrying them over means the
              // button reads "Sent" about an element nobody has sent, with the
              // last element's instruction still in the box.
              key={[activeKey, capture.selector, capture.url].join('|')}
              capture={capture}
              onSend={onSendToAgent}
              onClear={() =>
                setCaptures((prev) => {
                  const next = { ...prev }
                  delete next[activeKey]
                  return next
                })
              }
            />
          ) : (
            <p className="bw-muted bw-bottom-empty">
              Turn on Inspect, then click something in the page to capture its selector.
            </p>
          )
        ) : (
          <RecorderPanel
            state={recording}
            onStop={toggleRecording}
            onClear={() =>
              withId(async (a, id) => {
                const state = await a.browserRecordClear(id)
                setRecordings((prev) => ({ ...prev, [activeKey]: state }))
              })
            }
            onCopy={copyFlow}
            copied={copied}
            onSend={onSendToAgent}
          />
        )}
      </div>

      <SessionModal
        open={sessionOpen}
        bridge={api}
        isolated={active?.isolated === true}
        onClose={() => setSessionOpen(false)}
      />
    </div>
  )
}
