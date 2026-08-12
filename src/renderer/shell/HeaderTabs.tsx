import { StatusDot } from '../components/StatusDot'
import { KIND_ICON, type TabKind, type WorkspaceTab } from './workspace-tabs'

interface Props {
  tabs: WorkspaceTab[]
  activeId: string | null
  onSelect(id: string): void
  onClose(id: string): void
  onOpen(kind: TabKind): void
}

/**
 * The single tab strip in the window header.
 *
 * Sits in the title bar so the traffic lights and the tabs share one row, the
 * way a browser does — the window chrome is where "which window am I looking
 * at" belongs.
 */
export function HeaderTabs({ tabs, activeId, onSelect, onClose, onOpen }: Props) {
  return (
    // Two containers on purpose: the strip scrolls, the new-tab button does
    // not. With the button inside the scroller its dropdown was clipped by
    // `overflow-x: auto` and never appeared.
    <div className="header-tabs">
      <div className="header-tabs-strip" role="tablist" aria-label="Open tabs">
        {tabs.map((tab) => (
        <div
          key={tab.id}
          role="tab"
          tabIndex={0}
          aria-selected={tab.id === activeId}
          className={`htab${tab.id === activeId ? ' active' : ''}`}
          onClick={() => onSelect(tab.id)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              onSelect(tab.id)
            }
          }}
          onAuxClick={(e) => {
            if (e.button === 1 && tab.closable) onClose(tab.id)
          }}
        >
          {tab.kind === 'session' && tab.status ? (
            <StatusDot status={tab.status} />
          ) : (
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
              <path d={KIND_ICON[tab.kind]} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          )}
          <span className="htab-label">{tab.label}</span>
          {tab.closable && (
            <button
              type="button"
              className="htab-close"
              aria-label={`Close ${tab.label}`}
              onClick={(e) => {
                e.stopPropagation()
                onClose(tab.id)
              }}
            >
              <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor">
                <path d="M6 6l12 12M18 6L6 18" strokeWidth="2.6" strokeLinecap="round" />
              </svg>
            </button>
          )}
          </div>
        ))}
      </div>

      {/* Two buttons rather than a plus menu: the thing you want to open is
          one click, and the icons say which is which. */}
      <div className="htab-new">
        <button
          type="button"
          className="htab-new-button"
          aria-label="New session"
          title="New session (⌘T)"
          onClick={() => onOpen('session')}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor">
            <path d={KIND_ICON.session} strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
        <button
          type="button"
          className="htab-new-button"
          aria-label="New browser tab"
          title="New browser tab"
          onClick={() => onOpen('browser')}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor">
            <path d={KIND_ICON.browser} strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      </div>
    </div>
  )
}
