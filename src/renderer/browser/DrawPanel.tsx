import type { MarkKind } from './marks'

interface Props {
  tool: MarkKind
  markCount: number
  /** False while the composed PNG is being written. */
  ready: boolean
  onTool(tool: MarkKind): void
  onUndo(): void
  onClear(): void
  onSend(): void
  onCancel(): void
}

/** The three shapes, in the order a person reaches for them. */
const TOOLS: Array<{ kind: MarkKind; word: string; title: string }> = [
  { kind: 'free', word: 'Draw', title: 'Freehand — circle the thing' },
  { kind: 'rect', word: 'Box', title: 'A rectangle round a region' },
  { kind: 'arrow', word: 'Arrow', title: 'Point at one thing' },
]

/**
 * The draw controls, in the band the recorder otherwise has.
 *
 * ## Why here and not in a strip of its own
 *
 * *"Only one instruction strip on screen at a time."* The bottom band already
 * exists, and the modes are exclusive — `modes.ts` says why at length — so while
 * you are drawing there is by construction no flow being recorded and nothing
 * for the recorder to put here. Giving draw mode its own bar under the toolbar
 * would have been a third piece of chrome answering the same question, which is
 * the mistake the shell was cleaned up to undo.
 *
 * ## Why there is no session picker on it
 *
 * There is exactly one way to hand an image to an agent in this app, and it is
 * the screenshot popup: a picture, the path, a session picker and a line to
 * type. Send here does not duplicate any of that — it saves the marked frame and
 * opens that popup on it. So the annotated shot travels the same road as an
 * ordinary one, gets the same Reveal, and answers to the same per-window session
 * choice. The ellipsis is the promise that something else is about to ask.
 */
export function DrawPanel({ tool, markCount, ready, onTool, onUndo, onClear, onSend, onCancel }: Props) {
  const empty = markCount === 0

  return (
    <div className="bw-panel">
      <div className="bw-panel-head">
        <span className="bw-draw-tools" role="group" aria-label="What the next drag draws">
          {TOOLS.map((entry) => (
            <button
              key={entry.kind}
              type="button"
              className="bw-text-button"
              title={entry.title}
              aria-pressed={tool === entry.kind}
              data-on={tool === entry.kind || undefined}
              onClick={() => onTool(entry.kind)}
            >
              {entry.word}
            </button>
          ))}
        </span>

        {empty && <span className="bw-muted">Nothing marked yet.</span>}

        <span className="bw-spacer" />

        <button type="button" className="bw-text-button" disabled={empty} onClick={onUndo}>
          Undo
        </button>
        <button type="button" className="bw-text-button" disabled={empty} onClick={onClear}>
          Clear
        </button>
        {/* Leaving is a real action and not only the Escape key. Escape works
            too, and a mode with no visible way out is how people end up force
            quitting an app to get their page back. */}
        <button type="button" className="bw-text-button" onClick={onCancel}>
          Done
        </button>
        <button
          type="button"
          className="bw-primary"
          disabled={empty || !ready}
          title={
            empty
              ? 'Mark something on the page first.'
              : 'Save the marked page, then choose a session to send it to.'
          }
          onClick={onSend}
        >
          {ready ? 'Send…' : 'Saving…'}
        </button>
      </div>
    </div>
  )
}
