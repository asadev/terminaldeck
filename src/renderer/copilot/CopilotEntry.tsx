import { StatusDot } from '../components/StatusDot'
import { entryDot, entryTooltip, type CopilotStage, type CopilotStateView } from './copilot-model'
import { COPILOT_ACTIVE_ATTR, COPILOT_ROW_ATTR } from '../driving/where'
import { COPILOT_BLURB, COPILOT_ICON, COPILOT_NAME } from './identity'
import './copilot.css'

/**
 * The copilot's home in the sidebar: one row, pinned above everything else.
 *
 * ## Above the session list, and deliberately not in it
 *
 * Asad: *"in the top of the session we will make a copilot… this will be one
 * chat box which is a sticky chat box, maybe, or some proper section for it
 * where we can come and talk to it."* So it sits at the top of the rail, in its
 * own block, before the views you work in and before what you have open.
 *
 * It is a **singleton**, and that is what makes it a different kind of row
 * rather than a session that happens to be first. There is exactly one copilot;
 * there is no ＋ that starts a second and no ✕ that ends this one. A ✕ here
 * would be the same glyph, a few pixels from the session rows, meaning
 * something else entirely — and the rail already carries a long note about how
 * carefully its two existing ✕s had to be told apart. Stopping the copilot is a
 * button in the window this row opens, where the sentence about what stopping
 * costs can sit next to it, and in Settings → Copilot.
 *
 * ## What pressing it does, since 2026-08-17
 *
 * It opens a **window**, not a page. The copilot has always been a real
 * session; what it lacked was the chrome one gets — a pill in the strip, the
 * account chip, the model/effort/fast/connectors cluster — so now it has all of
 * it and this row is simply how you reach it, the way the rail's session rows
 * are how you reach those. The row stays because the copilot is not in the
 * session list: it is one thing, in one place, at the top.
 *
 * ## What the row is allowed to claim
 *
 * A status dot, and only when the caller has actually described a copilot. It
 * is the same `StatusDot` the session rows use, reading its words out of the
 * same table, so the top of the rail does not invent a second colour language
 * directly above the first — see `entryDot` for what each stage maps to.
 *
 * With no `stage`, there is no dot and the tooltip is the plain blurb. That is
 * the honest rendering for a `Sidebar` mounted on its own in a test or the
 * harness: the row is there and it opens the window, and it makes no claim
 * about a copilot nobody has asked about.
 *
 * ## The row is also driving mode's contract with the window
 *
 * Two attributes, `data-copilot-row` and `data-copilot-active`, and neither has
 * a line of CSS behind it. They exist because driving mode has to answer one
 * question that nothing else in the window can: **is the copilot's own page the
 * one in front?** — which decides whether the driving panel is drawn at all, per
 * *"it should not make two split views on its own page."*
 *
 * It is answered here rather than from the tab strip because the copilot is
 * deliberately not in the strip's tab list (`Sidebar.tsx` says so), so this row
 * is the only element in the window that knows. And it is an attribute rather
 * than the `active` class for the reason `focus-target.ts` gives about
 * `data-drive-anchor`: a class is styling and belongs to whoever is working on
 * the rail, whereas an attribute with no styling attached to it is obviously a
 * contract. `where.ts` reads them and `sidebar-copilot.test.tsx` pins them.
 */

interface Props {
  /** What this window knows, or null when nothing has asked. */
  stage?: CopilotStage | null
  state?: CopilotStateView | null
  /** True while the copilot's own window is what the window is showing. */
  active: boolean
  /**
   * What it is called.
   *
   * User data — typed in the setup flow, stored in the copilot's own instruction
   * file, read back by `useCopilotSetup` — so it arrives as a prop rather than
   * from {@link COPILOT_NAME}, which is now only the fallback for a copilot
   * nobody has named. The two must not be confused: the product's name is a
   * constant this repo spells once, and this is the opposite of a constant.
   */
  name?: string
  onOpen(): void
}

export function CopilotEntry({
  stage = null,
  state = null,
  active,
  name = COPILOT_NAME,
  onOpen,
}: Props) {
  // Null for a copilot that is not running, and for a machine that cannot run
  // one. `entryDot` carries the argument: there is no session status that means
  // "no process", and both of the near misses print a word that is not true.
  const dot = stage === null ? null : entryDot(stage)
  return (
    <section className="sb-group sb-pinned" aria-label={name}>
      <button
        type="button"
        className={`sb-row sb-nav sb-copilot${active ? ' active' : ''}`}
        {...{ [COPILOT_ROW_ATTR]: 'copilot' }}
        {...(active ? { [COPILOT_ACTIVE_ATTR]: '' } : {})}
        aria-current={active}
        // The whole sentence, not the label again. A tooltip that repeats what
        // is already on the line is one nobody reads twice — and this is the
        // only place a refusal from the last start attempt is ever shown.
        title={stage === null ? COPILOT_BLURB : `${name} — ${entryTooltip(stage, state)}`}
        onClick={onOpen}
      >
        <svg
          className="sb-glyph"
          width="17"
          height="17"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
          aria-hidden="true"
        >
          <path d={COPILOT_ICON} />
        </svg>
        <span className="sb-label">{name}</span>
        {dot !== null && <StatusDot status={dot} />}
      </button>
    </section>
  )
}
