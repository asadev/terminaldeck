import type { ReactNode } from 'react'
import { chordFor } from '../keymap'

interface Props {
  title: string
  /** A quiet second line: the project path, or what the view is for. */
  subtitle?: string | null
  sidebarCollapsed: boolean
  onToggleSidebar(): void
  /** Right-aligned, view-specific controls. */
  children?: ReactNode
}

const SIDEBAR_GLYPH =
  'M4.8 5.2h14.4a1.4 1.4 0 0 1 1.4 1.4v10.8a1.4 1.4 0 0 1-1.4 1.4H4.8a1.4 1.4 0 0 1-1.4-1.4V6.6a1.4 1.4 0 0 1 1.4-1.4zM9.8 5.2v13.6'

/**
 * The unified toolbar: one row over the content, and the only chrome above it.
 *
 * It replaces a title bar with a tab strip in it *and* a separate bar that held
 * one segmented control. Apple puts the view's name on the left of a toolbar
 * and its actions on the right, and the empty space between them drags the
 * window — which is the whole reason the old title bar existed.
 */
export function WindowToolbar({
  title,
  subtitle,
  sidebarCollapsed,
  onToggleSidebar,
  children,
}: Props) {
  return (
    <header className="toolbar" data-sidebar-collapsed={sidebarCollapsed || undefined}>
      <div className="toolbar-lead">
        <button
          type="button"
          className="toolbar-btn"
          onClick={onToggleSidebar}
          aria-label={sidebarCollapsed ? 'Show sidebar' : 'Hide sidebar'}
          aria-pressed={!sidebarCollapsed}
          title={`${sidebarCollapsed ? 'Show' : 'Hide'} sidebar${
            chordFor('view.sidebar') ? ` (${chordFor('view.sidebar')})` : ''
          }`}
        >
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
          >
            <path d={SIDEBAR_GLYPH} />
          </svg>
        </button>
        <div className="toolbar-heading">
          <h1 className="toolbar-title">{title}</h1>
          {subtitle && <p className="toolbar-subtitle">{subtitle}</p>}
        </div>
      </div>

      {/* The draggable middle. Everything either side of it is a control. */}
      <div className="toolbar-drag" />

      <div className="toolbar-actions">{children}</div>
    </header>
  )
}
