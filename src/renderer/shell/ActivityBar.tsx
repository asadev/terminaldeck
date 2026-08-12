import type { PanelId } from './panels'
import { PANELS } from './panels'

interface Props {
  active: PanelId
  onSelect(id: PanelId): void
  /** Badge counts keyed by panel, e.g. unread alerts. */
  badges?: Partial<Record<PanelId, number>>
  onOpenSettings(): void
  onOpenHelp(): void
}

/**
 * The icon rail. This exists because every panel we built was previously
 * unreachable — capability with no way in is the same as no capability.
 */
export function ActivityBar({ active, onSelect, badges, onOpenSettings, onOpenHelp }: Props) {
  return (
    <nav className="activity-bar" aria-label="Panels">
      {PANELS.map((panel) => {
        const count = badges?.[panel.id] ?? 0
        return (
          <button
            key={panel.id}
            type="button"
            className={`activity-item${panel.id === active ? ' active' : ''}`}
            aria-label={panel.label}
            aria-current={panel.id === active}
            title={`${panel.label}${panel.shortcut ? ` (${panel.shortcut})` : ''}`}
            onClick={() => onSelect(panel.id)}
          >
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
              <path d={panel.icon} strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
            {count > 0 && <span className="activity-badge">{count > 99 ? '99+' : count}</span>}
          </button>
        )
      })}

      {/* Pinned to the bottom, away from the panel list: these open dialogs
          rather than switching the dock, and ⌘, alone was undiscoverable. */}
      <div className="activity-spacer" />
      <button
        type="button"
        className="activity-item"
        onClick={onOpenHelp}
        aria-label="Help"
        title="Help"
      >
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <circle cx="12" cy="12" r="9" strokeWidth="1.7" />
          <path d="M9.5 9.5a2.5 2.5 0 1 1 3.2 2.4c-.6.2-.9.7-.9 1.3v.4" strokeWidth="1.7" strokeLinecap="round" />
          <circle cx="12" cy="17" r="0.9" fill="currentColor" stroke="none" />
        </svg>
      </button>
      <button
        type="button"
        className="activity-item"
        onClick={onOpenSettings}
        aria-label="Settings"
        title="Settings (⌘,)"
      >
        <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <circle cx="12" cy="12" r="3.2" strokeWidth="1.7" />
          <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.7 1.7 0 0 0 8.9 19a1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.7 1.7 0 0 0 4.6 8.9a1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
        </svg>
      </button>
    </nav>
  )
}
