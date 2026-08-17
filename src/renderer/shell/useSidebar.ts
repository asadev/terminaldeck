import { useCallback, useEffect, useRef, useState } from 'react'
import { isPanelId, type PanelId } from './panels'

const WIDTH_KEY = 'deck.sidebar.width'
const COLLAPSED_KEY = 'deck.sidebar.collapsed'
const PANEL_KEY = 'deck.sidebar.panel'
const MIN = 220
const MAX = 380
const DEFAULT = 264

/**
 * How long the peeked sidebar waits after the pointer leaves before sliding
 * back.
 *
 * This is a grace period, not a poll: the pointer crosses the sidebar's edge
 * on its way to a row near that edge, and without the grace the panel closes
 * under the cursor mid-reach. Long enough to survive a diagonal, short enough
 * that a deliberate move away feels immediate. There is no matching delay on
 * the way in — the reveal strip is eight pixels wide, so arriving on it is
 * already a deliberate act, and a delay there would make the panel feel stuck.
 */
export const PEEK_CLOSE_MS = 160

function readNumber(key: string, fallback: number): number {
  const raw = Number(localStorage.getItem(key))
  return Number.isFinite(raw) && raw >= MIN && raw <= MAX ? raw : fallback
}

/**
 * Which view the window shows after somebody asks for one.
 *
 * A one-line function with a name, because the line it replaces was a bug and
 * a bug this shape has to stay killed. See `selectPanel` for the whole account;
 * the short version is that this used to answer `null` when the requested view
 * was already open, and every navigation in the app — including the Files
 * page's own "open this file" — went through it.
 *
 * Pure and exported so it can be pinned: there is no DOM in this project's
 * tests, so a hook cannot be driven, and the decision has to live somewhere a
 * test can reach it.
 */
export function panelAfterSelect(current: PanelId | null, asked: PanelId): PanelId {
  return current === asked ? current : asked
}

/**
 * The sidebar's width, whether it is pinned, whether it is being peeked at, and
 * which view it has selected.
 *
 * `panel` is nullable, and that is the whole shape of the shell: null means the
 * window is showing whatever session or page you have open, and a PanelId means
 * the sidebar has taken the window over with one of its views.
 *
 * ## Pinned, peeked, and why they are two states
 *
 * `collapsed` is a *preference* — "I do not want the sidebar taking up room" —
 * and it is persisted. `peeking` is a *gesture* — "show it to me for a second"
 * — and it is not. Reaching for the left edge of the window slides the sidebar
 * out over the content; taking the pointer away puts it back; clicking the
 * arrow in its gutter pins it, which is to say clears the preference. That is
 * the behaviour of the app this was modelled on, and the reason it works is
 * that the transient state never writes to the persistent one: a mouse passing
 * over the edge on its way somewhere else must not change what the window looks
 * like the next time it is opened.
 *
 * Persisted to localStorage rather than the main-process store: this is window
 * chrome, it changes on every frame of a drag, and round-tripping that through
 * IPC would be wasteful.
 */
export function useSidebar() {
  const [panel, setPanel] = useState<PanelId | null>(() => {
    const stored = localStorage.getItem(PANEL_KEY)
    return isPanelId(stored) ? stored : null
  })
  const [width, setWidth] = useState(() => readNumber(WIDTH_KEY, DEFAULT))
  const [collapsed, setCollapsed] = useState(() => localStorage.getItem(COLLAPSED_KEY) === '1')
  const [peeking, setPeeking] = useState(false)
  const dragging = useRef(false)
  const peekTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (panel) localStorage.setItem(PANEL_KEY, panel)
    else localStorage.removeItem(PANEL_KEY)
  }, [panel])
  useEffect(() => localStorage.setItem(COLLAPSED_KEY, collapsed ? '1' : '0'), [collapsed])
  useEffect(() => localStorage.setItem(WIDTH_KEY, String(width)), [width])

  const cancelPeekTimer = useCallback(() => {
    if (peekTimer.current === null) return
    clearTimeout(peekTimer.current)
    peekTimer.current = null
  }, [])

  // A timer that outlives the component fires setState into an unmounted tree.
  useEffect(() => cancelPeekTimer, [cancelPeekTimer])

  /**
   * Open a view in the window. Asking for the one already open keeps it open.
   *
   * ## This used to be a toggle, and the toggle was the thrashing
   *
   * `setPanel(current === next ? null : next)` reads as a tidy convenience and
   * it was the whole of the bug Asad recorded — a minute of the window
   * alternating between Files and a terminal, the sidebar highlighting Files
   * while the pane showed a blank shell. In his words: *"if I'm clicking on the
   * files from overview to files, for a second, it brought me to this session…
   * If I double click, it should not move to the other one. It should stay
   * there."*
   *
   * Two things were wrong with it, and only the first is the one people notice.
   *
   *  1. **A double click closed the page it had just opened.** Two clicks on a
   *     row is one gesture as far as a person is concerned, and it landed them
   *     back on a terminal they had not asked for.
   *
   *  2. **Every programmatic navigation went through it too, and one of them
   *     was a loop.** `App.tsx` routes *all* of them through `showPanel`:
   *     Source control handing a changed file to Files, the command palette
   *     opening a file, a dashboard tile, an alert's button — and the Files
   *     page itself, whose tree calls `onOpenFile` for every row you click.
   *     So clicking a file *while already on Files* meant `selectPanel('files')`
   *     with `files` already current, which closed the page and threw the
   *     window back to the session. That is reproducible in three clicks and it
   *     is what the recording caught: the page was not slow, it was leaving.
   *
   * So opening is idempotent, and it is the only meaning this function has.
   * Leaving a view is a separate act with its own name — `clearPanel`, which is
   * what selecting a session or a page in the rail calls — because "show me
   * this" and "stop showing me this" are two intentions and one of them must
   * not be able to happen by accident on the way to the other.
   *
   * It also used to un-collapse the sidebar as a side effect. That went with
   * the peek: opening a view from a *peeked* sidebar would have pinned it, so
   * glancing at the rail and clicking one row would permanently rearrange the
   * window — a gesture writing a preference, which is the one thing the two
   * states exist to keep apart.
   */
  const selectPanel = useCallback((next: PanelId) => {
    setPanel((current) => panelAfterSelect(current, next))
  }, [])

  /** Leave the views and go back to the open session or page. */
  const clearPanel = useCallback(() => setPanel(null), [])

  /** The pointer has reached the left edge, or the sidebar itself. */
  const beginPeek = useCallback(() => {
    cancelPeekTimer()
    setPeeking(true)
  }, [cancelPeekTimer])

  /** The pointer has left. Grace period, then back it goes. */
  const endPeek = useCallback(() => {
    cancelPeekTimer()
    peekTimer.current = setTimeout(() => {
      peekTimer.current = null
      setPeeking(false)
    }, PEEK_CLOSE_MS)
  }, [cancelPeekTimer])

  /** Keep it. The gesture becomes the preference. */
  const pin = useCallback(() => {
    cancelPeekTimer()
    setPeeking(false)
    setCollapsed(false)
  }, [cancelPeekTimer])

  /** Put it away. Also drops any peek, or it would stay on screen unpinned. */
  const collapse = useCallback(() => {
    cancelPeekTimer()
    setPeeking(false)
    setCollapsed(true)
  }, [cancelPeekTimer])

  const startResize = useCallback((event: React.MouseEvent) => {
    event.preventDefault()
    dragging.current = true
    const startX = event.clientX
    const startWidth = readNumber(WIDTH_KEY, DEFAULT)

    const onMove = (e: MouseEvent) => {
      if (!dragging.current) return
      setWidth(Math.min(MAX, Math.max(MIN, startWidth + (e.clientX - startX))))
    }
    const onUp = () => {
      dragging.current = false
      window.removeEventListener('mousemove', onMove)
      window.removeEventListener('mouseup', onUp)
      // Text selection is suppressed for the duration of the drag; restore it.
      document.body.style.userSelect = ''
    }

    document.body.style.userSelect = 'none'
    window.addEventListener('mousemove', onMove)
    window.addEventListener('mouseup', onUp)
  }, [])

  return {
    panel,
    selectPanel,
    clearPanel,
    width,
    collapsed,
    peeking,
    /** On screen right now, pinned or not. This is what the shell renders on. */
    revealed: !collapsed || peeking,
    beginPeek,
    endPeek,
    pin,
    collapse,
    toggleCollapsed: useCallback(() => {
      // The chord and the menu item both come through here, and both mean "the
      // opposite of whatever I can see" — so a peeked sidebar is pinned rather
      // than collapsed, which is what pressing the key while looking at it
      // obviously means.
      if (collapsed) pin()
      else collapse()
    }, [collapsed, pin, collapse]),
    startResize,
  }
}
