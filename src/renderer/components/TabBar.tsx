import { useStore } from '../state/store'
import { StatusDot } from './StatusDot'

interface Props {
  onClose(id: string): void
}

export function TabBar({ onClose }: Props) {
  const { sessions, activeSessionId, setActiveSession } = useStore()

  return (
    <div className="tabbar" role="tablist">
      {sessions.map((s, i) => (
        <div
          key={s.id}
          role="tab"
          tabIndex={0}
          aria-selected={s.id === activeSessionId}
          className={`tab${s.id === activeSessionId ? ' active' : ''}`}
          onClick={() => setActiveSession(s.id)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              setActiveSession(s.id)
            }
          }}
          // Middle-click closes, matching every tabbed editor.
          onAuxClick={(e) => {
            if (e.button === 1) onClose(s.id)
          }}
        >
          <StatusDot status={s.status} />
          <span className="tab-label" title={s.cwd}>
            {s.title}
            {i > 0 && <span className="tab-index"> {i + 1}</span>}
          </span>
          <button
            type="button"
            className="tab-close"
            aria-label={`Close ${s.title}`}
            onClick={(e) => {
              e.stopPropagation()
              onClose(s.id)
            }}
          >
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor">
              <path d="M6 6l12 12M18 6L6 18" strokeWidth="2.4" strokeLinecap="round" />
            </svg>
          </button>
        </div>
      ))}
    </div>
  )
}
