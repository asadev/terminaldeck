import { useCallback, useEffect, useRef, useState } from 'react'
import { useOneMenu } from '../../shell/one-menu'
import { dictationGuidance, speechSupport } from './dictation'
import './DictateButton.css'

/**
 * The microphone.
 *
 * It does not record, and it does not pretend to. `dictation.ts` carries the
 * measurements: in this Electron the Web Speech API starts and then goes
 * permanently silent — no audio, no result, and, fatally, no error — so a
 * recording state here would be a spinner that never resolves and a level meter
 * with nothing to meter.
 *
 * What it does instead is the mechanical half of dictation that this app is
 * actually in a position to do: put the caret in the composer, so the moment
 * the user starts macOS Dictation the words land in the right box. The tooltip
 * says so before the click, which is what keeps the button honest.
 */

interface Props {
  /** Focus the composer. Called before the guidance is shown, not after. */
  onFocusComposer: () => void
  disabled?: boolean
}

export function DictateButton({ onFocusComposer, disabled = false }: Props) {
  const [open, setOpen] = useState(false)
  const hostRef = useRef<HTMLDivElement>(null)
  const [userAgent, setUserAgent] = useState('')

  // Read in an effect rather than at render: this component is rendered to
  // static markup in tests, where there is no navigator at all.
  useEffect(() => {
    if (typeof navigator !== 'undefined') setUserAgent(navigator.userAgent)
  }, [])

  const close = useCallback(() => setOpen(false), [])

  // The window's one-menu-at-a-time rule — see `one-menu.ts`. This popover is
  // the tallest thing on the composer's row and it overlapped the Options panel
  // beside it.
  useOneMenu(open, close)

  useEffect(() => {
    if (!open) return
    const onKey = (event: KeyboardEvent): void => {
      if (event.key === 'Escape') {
        event.stopPropagation()
        close()
      }
    }
    const onDown = (event: MouseEvent): void => {
      const host = hostRef.current
      if (host && event.target instanceof Node && !host.contains(event.target)) close()
    }
    document.addEventListener('keydown', onKey, true)
    document.addEventListener('mousedown', onDown)
    return () => {
      document.removeEventListener('keydown', onKey, true)
      document.removeEventListener('mousedown', onDown)
    }
  }, [open, close])

  const guidance = dictationGuidance(userAgent)
  const support = speechSupport()

  return (
    <div className="dc-host" ref={hostRef}>
      {open ? (
        <div className="dc-pop" role="dialog" aria-label="Dictation">
          <p className="dc-summary">{guidance.summary}</p>
          <ol className="dc-steps">
            {guidance.steps.map((step) => (
              <li key={step}>{step}</li>
            ))}
          </ol>
          <p className="dc-why">
            {support === 'missing'
              ? 'This window has no speech recognition of its own.'
              : guidance.reason}
          </p>
        </div>
      ) : null}

      <button
        type="button"
        className={`cc-tool${open ? ' cc-tool-on' : ''}`}
        disabled={disabled}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label="Dictate using macOS Dictation"
        title="Dictate — focuses this box for macOS Dictation"
        onClick={() => {
          // Focus first: if dictation is already running, the words have
          // somewhere to go the instant this is clicked.
          onFocusComposer()
          setOpen((was) => !was)
        }}
      >
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" aria-hidden="true">
          <rect x="9" y="3" width="6" height="11" rx="3" strokeWidth="1.7" />
          <path d="M5 11a7 7 0 0 0 14 0M12 18v3" strokeWidth="1.7" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  )
}
