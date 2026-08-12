import type { PanelId } from './panels'
import { PANELS } from './panels'

interface Props {
  active: PanelId
  onSelect(id: PanelId): void
  /** Badge counts keyed by panel, e.g. unread alerts. */
  badges?: Partial<Record<PanelId, number>>
}

/**
 * The icon rail. This exists because every panel we built was previously
 * unreachable — capability with no way in is the same as no capability.
 */
export function ActivityBar({ active, onSelect, badges }: Props) {
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
    </nav>
  )
}
