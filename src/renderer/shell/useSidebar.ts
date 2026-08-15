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
   * Open a view in the window. Picking the one already open closes it again.
   *
   * It used to un-collapse the sidebar as a side effect. That has to go with
   * the peek: opening a view from a *peeked* sidebar would have pinned it, so
   * glancing at the rail and clicking one row would permanently rearrange the
   * window — a gesture writing a preference, which is the one thing the two
   * states exist to keep apart.
   */
  const selectPanel = useCallback((next: PanelId) => {
    setPanel((current) => (current === next ? null : next))
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
