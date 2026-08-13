import { useCallback, useEffect, useRef, useState } from 'react'
import { isPanelId, type PanelId } from './panels'

const WIDTH_KEY = 'deck.sidebar.width'
const COLLAPSED_KEY = 'deck.sidebar.collapsed'
const PANEL_KEY = 'deck.sidebar.panel'
const MIN = 220
const MAX = 380
const DEFAULT = 264

function readNumber(key: string, fallback: number): number {
  const raw = Number(localStorage.getItem(key))
  return Number.isFinite(raw) && raw >= MIN && raw <= MAX ? raw : fallback
}

/**
 * The sidebar's width, its collapsed state, and which view it has selected.
 *
 * `panel` is nullable now, and that is the whole shape of the new shell: null
 * means the window is showing whatever session or page you have open, and a
 * PanelId means the sidebar has taken the window over with one of its views.
 * The old dock could only ever be *showing* something, which is why the app
 * had a drawer permanently glued to the left of the content.
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
  const dragging = useRef(false)

  useEffect(() => {
    if (panel) localStorage.setItem(PANEL_KEY, panel)
    else localStorage.removeItem(PANEL_KEY)
  }, [panel])
  useEffect(() => localStorage.setItem(COLLAPSED_KEY, collapsed ? '1' : '0'), [collapsed])
  useEffect(() => localStorage.setItem(WIDTH_KEY, String(width)), [width])

  /** Open a view in the window. Picking the one already open closes it again. */
  const selectPanel = useCallback((next: PanelId) => {
    setPanel((current) => (current === next ? null : next))
    setCollapsed(false)
  }, [])

  /** Leave the views and go back to the open session or page. */
  const clearPanel = useCallback(() => setPanel(null), [])

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
    toggleCollapsed: useCallback(() => setCollapsed((c) => !c), []),
    startResize,
  }
}
