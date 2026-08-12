import { useCallback, useEffect, useRef, useState } from 'react'
import type { PanelId } from './panels'

const WIDTH_KEY = 'pawl.dock.width'
const COLLAPSED_KEY = 'pawl.dock.collapsed'
const PANEL_KEY = 'pawl.dock.panel'
const MIN = 180
const MAX = 480

function readNumber(key: string, fallback: number): number {
  const raw = Number(localStorage.getItem(key))
  return Number.isFinite(raw) && raw >= MIN && raw <= MAX ? raw : fallback
}

/**
 * Dock width, collapsed state and which panel is showing.
 *
 * Persisted to localStorage rather than the main-process store: this is window
 * chrome, it changes on every frame of a drag, and round-tripping that through
 * IPC would be wasteful.
 */
export function usePanelDock() {
  const [panel, setPanelState] = useState<PanelId>(
    () => (localStorage.getItem(PANEL_KEY) as PanelId | null) ?? 'projects',
  )
  const [width, setWidth] = useState(() => readNumber(WIDTH_KEY, 260))
  const [collapsed, setCollapsed] = useState(() => localStorage.getItem(COLLAPSED_KEY) === '1')
  const dragging = useRef(false)

  useEffect(() => localStorage.setItem(PANEL_KEY, panel), [panel])
  useEffect(() => localStorage.setItem(COLLAPSED_KEY, collapsed ? '1' : '0'), [collapsed])
  useEffect(() => localStorage.setItem(WIDTH_KEY, String(width)), [width])

  /** Clicking the panel you are already on closes the dock, as an IDE does. */
  const selectPanel = useCallback(
    (next: PanelId) => {
      if (next === panel && !collapsed) {
        setCollapsed(true)
        return
      }
      setPanelState(next)
      setCollapsed(false)
    },
    [panel, collapsed],
  )

  const startResize = useCallback((event: React.MouseEvent) => {
    event.preventDefault()
    dragging.current = true
    const startX = event.clientX
    const startWidth = readNumber(WIDTH_KEY, 260)

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
    width,
    collapsed,
    toggleCollapsed: useCallback(() => setCollapsed((c) => !c), []),
    startResize,
  }
}
