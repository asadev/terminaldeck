/**
 * Whose session is whose, in the sidebar.
 *
 * A session the copilot started is an ordinary session in every way that
 * matters — same folder, same account, same confinement, same ✕ — and it is not
 * ordinary in one: **nobody in this window asked for it.** A tab that appears
 * under your project heading, in the middle of your own work, with nothing
 * saying where it came from, is the single thing an app that can start
 * processes on its own must not produce. So they are grouped under their own
 * heading, and each row can answer "why does this exist" in one click.
 *
 * The provenance is on the session itself — `SessionMeta.origin` and
 * `originRunId`, written by `deck-control`'s `sessions.start` — rather than kept
 * in a table beside it. The renderer therefore has to invent nothing here; this
 * file only sorts.
 *
 * ## The absence is meaningful, and it is why nothing defaults
 *
 * `origin` is absent on every session a person started, and `shared/types.ts`
 * says in as many words that nothing may read the absence as unknown. So the
 * question asked below is always `origin === 'copilot'` and never
 * `origin !== 'user'`. The difference shows up on the day a third origin exists:
 * the first form leaves it in your own list until somebody decides where it
 * goes, and the second silently sweeps it into the copilot's.
 */

/** The part of a tab this file needs. Structural, so a test can hand it two fields. */
export interface OriginTab {
  id: string
  kind: string
  /** Absent for every session a person started. See the header. */
  origin?: string
  /** The action-log row of the copilot turn that started it, when one did. */
  originRunId?: string
}

/** Did the copilot start this? */
export function startedByCopilot(tab: OriginTab): boolean {
  return tab.kind === 'session' && tab.origin === 'copilot'
}

/**
 * The tabs split into the person's and the copilot's, in one pass.
 *
 * One function returning both halves rather than two predicates called twice,
 * because the halves have to partition: a session that appeared in neither, or
 * in both, is a row missing from the rail or drawn twice in it, and both are
 * failures a reader would have to notice by counting. Returning the pair makes
 * that a property of one function instead of an agreement between two.
 */
export function partitionByOrigin<T extends OriginTab>(
  tabs: readonly T[],
): { mine: T[]; copilot: T[] } {
  const mine: T[] = []
  const copilot: T[] = []
  for (const tab of tabs) (startedByCopilot(tab) ? copilot : mine).push(tab)
  return { mine, copilot }
}

/**
 * The turn that started a session, or null when there is nothing to point at.
 *
 * Null is a real answer and not a defect: a copilot session restored from a
 * previous run of the app carries its `origin` — it is on the session metadata,
 * which survives — while the turn that started it is a row in a log the window
 * has not loaded. The link is then honestly absent rather than drawn as a
 * button that lands on nothing, which is the rule this window holds itself to
 * everywhere else.
 */
export function turnOf(tab: OriginTab): string | null {
  if (!startedByCopilot(tab)) return null
  return typeof tab.originRunId === 'string' && tab.originRunId !== '' ? tab.originRunId : null
}

/**
 * The sessions one copilot turn started.
 *
 * The other direction of the same link, for the copilot's own view: an Activity
 * row can offer to open what it produced. Plural because nothing in the tool
 * surface stops a turn from starting more than one, and a function that assumed
 * one would silently show the first.
 */
export function sessionsFromTurn<T extends OriginTab>(tabs: readonly T[], runId: string): T[] {
  return tabs.filter((tab) => turnOf(tab) === runId)
}
