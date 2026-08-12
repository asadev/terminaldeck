import type { ReactNode } from 'react'

/**
 * The window header: traffic lights on the left, then the tab strip.
 *
 * Tabs live here rather than in a bar below, so sessions and browser windows
 * read as windows of this app the way a browser's tabs do. Only the empty
 * space is draggable — a drag region over a tab would swallow its clicks.
 */
export function TitleBar({ children }: { children?: ReactNode }) {
  return (
    <header className="titlebar">
      <div className="titlebar-gutter" />
      {children}
      <div className="titlebar-drag" />
    </header>
  )
}
