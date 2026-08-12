import { useState } from 'react'
import { StatusDot } from '../components/StatusDot'
import { KIND_ICON, type TabKind, type WorkspaceTab } from './workspace-tabs'

interface Props {
  tabs: WorkspaceTab[]
  activeId: string | null
  onSelect(id: string): void
  onClose(id: string): void
  onOpen(kind: TabKind): void
}

const NEW_ITEMS: Array<{ kind: TabKind; label: string; hint: string }> = [
  { kind: 'session', label: 'New session', hint: '⌘T' },
  { kind: 'browser', label: 'New browser tab', hint: '' },
  { kind: 'overview', label: 'Project overview', hint: '' },
  { kind: 'board', label: 'Task board', hint: '' },
]

/**
 * The single tab strip in the window header.
 *
 * Sits in the title bar so the traffic lights and the tabs share one row, the
 * way a browser does — the window chrome is where "which window am I looking
 * at" belongs.
 */
export function HeaderTabs({ tabs, activeId, onSelect, onClose, onOpen }: Props) {
  const [menuOpen, setMenuOpen] = useState(false)

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

      <div className="htab-new">
        <button
          type="button"
          className="htab-new-button"
          aria-label="Open a new tab"
          aria-expanded={menuOpen}
          title="Open a new tab"
          onClick={() => setMenuOpen((open) => !open)}
        >
          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor">
            <path d="M12 5v14M5 12h14" strokeWidth="2" strokeLinecap="round" />
          </svg>
        </button>

        {menuOpen && (
          <>
            {/* Click-away layer: a menu that only closes on re-click strands
                the user behind an invisible panel. */}
            <div className="htab-menu-scrim" onClick={() => setMenuOpen(false)} />
            <div className="htab-menu" role="menu">
              {NEW_ITEMS.map((item) => (
                <button
                  key={item.kind}
                  type="button"
                  role="menuitem"
                  className="htab-menu-item"
                  onClick={() => {
                    setMenuOpen(false)
                    onOpen(item.kind)
                  }}
                >
                  <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
                    <path d={KIND_ICON[item.kind]} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
                  </svg>
                  <span>{item.label}</span>
                  {item.hint && <kbd>{item.hint}</kbd>}
                </button>
              ))}
            </div>
          </>
        )}
      </div>
    </div>
  )
}
