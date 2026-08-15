import './ModeSwitch.css'

/**
 * The one control in the top-right of the window: what is the window doing.
 *
 * It replaces four separate things that had accumulated up there — a
 * Terminal/Chat segmented control, a swarm button, a session-details button and
 * a command-palette button — which is a toolbar that had become a shelf. Three
 * of those four are not modes at all: they open a dialog, or a page. Only the
 * first was ever answering the question the top-right of a window is for.
 *
 * So this is a segmented control with three segments and nothing beside it. The
 * shape is the promise: a segmented control means "the same work, shown
 * differently", and all three of these are views of the sessions you already
 * have open. Nothing here creates anything, nothing here opens a dialog, and
 * every segment is a word rather than a glyph — a row of unlabelled icons is
 * exactly the thing this window was asked to stop doing.
 */

/** How a single session is shown. Held per session, because it is a preference
    about that conversation rather than about the window. */
export type SessionViewMode = 'terminal' | 'chat'

/**
 * What fills the window.
 *
 * `split` is not a third way of showing one session — it is several sessions at
 * once — which is why it is in this union rather than in `SessionViewMode`. The
 * two are joined here, at the control, because to the person using the app they
 * are one question with three answers.
 */
export type WorkspaceMode = SessionViewMode | 'split'

export interface ModeSwitchProps {
  mode: WorkspaceMode
  onChange(mode: WorkspaceMode): void
  label?: string
}

/**
 * Three segments, no fourth.
 *
 * Split is offered whatever you have open, including with a single session:
 * splitting is how you make room for the *next* agent, so the pane that appears
 * beside your terminal says so and offers to start one. Disabling it until a
 * second session exists would hide the control at exactly the moment it is
 * useful, and a control that comes and goes is one people stop trusting.
 */
const MODES: ReadonlyArray<{ id: WorkspaceMode; label: string; hint: string }> = [
  { id: 'terminal', label: 'Terminal', hint: 'The session exactly as it runs' },
  { id: 'chat', label: 'Chat', hint: 'The same session as prompts and replies' },
  { id: 'split', label: 'Split', hint: 'Two sessions side by side' },
]

export function ModeSwitch({
  mode,
  onChange,
  label = 'What this window is showing',
}: ModeSwitchProps) {
  return (
    <div className="mode-switch" role="group" aria-label={label}>
      {MODES.map((entry) => {
        const active = entry.id === mode
        return (
          <button
            key={entry.id}
            type="button"
            className={active ? 'ms-option ms-on' : 'ms-option'}
            // A pressed state, not a tab: `role="tab"` promises arrow-key
            // navigation between the segments, which this does not implement,
            // and a promise a control does not keep is worse than no promise.
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
