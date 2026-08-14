import { BRAND } from '@shared/brand'
import { chordFor, detectMac } from '../keymap'

interface Props {
  onOpenProject(): void
  /** Pinned in tests and screenshots; production sniffs the window. */
  isMac?: boolean
}

/**
 * The first thing anybody sees, and it used to print two keys that do not
 * exist on a Windows machine: `<kbd>⌘</kbd> <kbd>O</kbd>`, hand-typed. The
 * chords now come out of `keymap.ts` for the platform this window is running
 * on, and a chord the keymap no longer binds drops out of the sentence rather
 * than being printed as a key nothing answers to.
 */
export function EmptyState({ onOpenProject, isMac = detectMac() }: Props) {
  const open = chordFor('project.open', isMac)
  const fresh = chordFor('session.new', isMac)
  const hints = [
    open === null ? null : { chord: open, text: 'to open' },
    fresh === null ? null : { chord: fresh, text: 'for a new session' },
  ].filter((hint): hint is { chord: string; text: string } => hint !== null)

  return (
    <div className="empty-state">
      <div className="empty-mark" aria-hidden="true">
        <svg width="44" height="44" viewBox="0 0 24 24" fill="none" stroke="currentColor">
          <path d="M4 17l6-6-6-6" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
          <path d="M12 19h8" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
      </div>
      <h1>{BRAND.name}</h1>
      <p>{BRAND.tagline}.</p>
      <button type="button" className="btn-primary" onClick={onOpenProject}>
        Open a project
      </button>
      {hints.length > 0 && (
        <p className="empty-hint">
          {hints.map((hint, index) => (
            <span key={hint.chord}>
              {index > 0 && ' · '}
              <kbd>{hint.chord}</kbd> {hint.text}
            </span>
          ))}
        </p>
      )}
    </div>
  )
}
