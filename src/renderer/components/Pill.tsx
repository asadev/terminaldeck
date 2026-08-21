import type { ReactNode } from 'react'

/**
 * The pill a page uses to switch what it is showing.
 *
 * ## Why there is one of these
 *
 * Asad, asking for pills on the readiness page, 2026-08-21:
 *
 *   > *"So maybe here we also need pills to switch between and see MCP server
 *   > and machine."*
 *
 * The pattern he is pointing at was already two clicks away — Artifacts has
 * *This project's sessions | Every session* and *Made here | Changed*, MCP
 * servers has its folder — and it existed as markup copied between panels
 * rather than as a thing. Three pages each with their own class is how the
 * empty states drifted before `PageEmpty` was written, and the readiness page
 * needing a fourth copy is the moment to stop.
 *
 * So this is the one pill: the same fill, the same height, the same pressed
 * state, and — the half that is easy to leave out of a copy — the same
 * `aria-pressed`, which is what tells somebody reading with a screen reader
 * that these are a choice rather than eight buttons.
 *
 * ## A group, not a radio
 *
 * The row around them is a `role="group"` with a label, not a `radiogroup`.
 * Some of these rows are a genuine one-of-many (which agent the readiness page
 * grades for); others are independent toggles (Artifacts' History switch). One
 * shape that is honest for both beats a role that promises arrow-key semantics
 * this app does not implement.
 */

interface Props {
  /** Whether this pill is the one currently in force. */
  on?: boolean
  /** The hover sentence, where the words alone do not carry it. */
  title?: string
  onClick(): void
  children: ReactNode
}

export function Pill({ on = false, title, onClick, children }: Props) {
  return (
    <button
      type="button"
      className="page-pill"
      // `data-on` for the stylesheet and `aria-pressed` for the reader, both
      // from one prop so a pill cannot look chosen and read as unchosen.
      data-on={on ? 'true' : undefined}
      aria-pressed={on}
      title={title}
      onClick={onClick}
    >
      {children}
    </button>
  )
}

/**
 * A labelled run of pills.
 *
 * The label is for assistive tech only — a visible caption above four words in
 * a row is the standing prose this round removed everywhere — except where a
 * page has two rows of them and the reader has to tell which question each
 * answers, where `lead` puts one quiet word in front.
 */
export function PillRow({
  label,
  lead,
  children,
}: {
  label: string
  lead?: string
  children: ReactNode
}) {
  return (
    <div className="page-pills" role="group" aria-label={label}>
      {lead ? <span className="page-pills-lead">{lead}</span> : null}
      {children}
    </div>
  )
}
