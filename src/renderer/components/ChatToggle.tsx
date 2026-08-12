import './ChatToggle.css'

/**
 * Terminal ⇄ Chat, for the session view.
 *
 * Two views of one session, so this is a segmented control rather than a pair
 * of buttons or a tab strip: the shape itself says "the same thing, shown
 * differently", and the strip along the top of the window already means "a
 * different thing".
 */

export type SessionViewMode = 'terminal' | 'chat'

export interface ChatToggleProps {
  mode: SessionViewMode
  onChange: (mode: SessionViewMode) => void
  /** Optional label for the group, read by screen readers. */
  label?: string
}

const MODES: ReadonlyArray<{ id: SessionViewMode; label: string; hint: string }> = [
  { id: 'terminal', label: 'Terminal', hint: 'The session as it runs' },
  { id: 'chat', label: 'Chat', hint: 'Prompts and replies only' },
]

export function ChatToggle({ mode, onChange, label = 'Session view' }: ChatToggleProps) {
  return (
    <div className="chat-toggle" role="group" aria-label={label}>
      {MODES.map((entry) => {
        const active = entry.id === mode
        return (
          <button
            key={entry.id}
            type="button"
            className={active ? 'ct-option ct-on' : 'ct-option'}
            // A toggle, not navigation: aria-pressed says the state, where a tab
            // role would promise arrow-key navigation this does not implement.
            aria-pressed={active}
            title={entry.hint}
            onClick={() => {
              if (!active) onChange(entry.id)
            }}
          >
            {entry.label}
          </button>
        )
      })}
    </div>
  )
}
