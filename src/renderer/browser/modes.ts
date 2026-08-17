/**
 * Inspect, Record and Draw, and the rule that never more than one is on.
 *
 * ## The bug this is
 *
 * The guest scripts contradict each other by design, and both of them are
 * right. The inspector swallows every click — `preventDefault`,
 * `stopImmediatePropagation` — so that pointing at a link does not navigate away
 * from the link. The recorder deliberately ignores every event while the
 * inspector's overlay is in the document, because a click the page never
 * received is not a step in any flow anybody could replay.
 *
 * What was missing was anything stopping both modes being switched on at once.
 * The toolbar happily allowed it, and the guest then resolved the contradiction
 * in silence: the inspector ate the clicks and the recorder skipped them. On
 * camera on 2026-08-16 that is a Flow counter stuck at `Flow (1)` — the opening
 * `Go <url>` and nothing else — across roughly forty clicks, with the in-page
 * RECORDING badge showing the whole time. *"I don't know if it is working fine
 * or not… it is keep moving to element automatically. Let's see if I stop, but
 * there is nothing. So I think it's not working fine."*
 *
 * So the modes are made exclusive, at the one place that knows about all of
 * them. The guard inside the recorder stays exactly as it is: it is correct
 * behaviour for a state this now prevents, and defence in depth costs nothing.
 *
 * ## Why Draw is in here rather than beside it
 *
 * *"So this draw option we need to have also, and we can send it to the agent
 * like this."* Draw puts a canvas over the page and, to be seen at all, parks
 * the native view underneath it — `overlay-watch.ts` is the essay on why there
 * is no third option. A parked page cannot be inspected and cannot be recorded,
 * because it is not receiving any input at all. So a third mode that could be on
 * alongside the other two would recreate the *exact* fault above, one release
 * after it was fixed: a badge saying RECORDING over a page nobody can click.
 *
 * Making it a third value in the same rule, instead of a third boolean somewhere
 * else, is what makes that impossible rather than merely unlikely. It is also
 * what keeps the instruction line honest — {@link modeHint} can only ever return
 * one sentence, because only one mode can be on. He asked for that in those
 * words: only one instruction strip on screen at a time.
 */

export interface BrowserModes {
  inspecting: boolean
  recording: boolean
  /**
   * A canvas is over the page and the page is parked behind it.
   *
   * Renderer-only, unlike the other two: there is nothing to tell the guest,
   * because the guest is not being shown. That asymmetry is the reason this is
   * a state the workspace holds rather than one read back off a tab.
   */
  drawing: boolean
}

export type BrowserMode = 'inspect' | 'record' | 'draw'

/** The field each mode owns, so the rule below can be written once. */
const FIELD: Record<BrowserMode, keyof BrowserModes> = {
  inspect: 'inspecting',
  record: 'recording',
  draw: 'drawing',
}

/**
 * What the modes become when one of them is toggled.
 *
 * Turning one **on** turns the others off. Turning one **off** leaves the others
 * exactly as they were — a Stop on the recorder must not quietly switch
 * inspection on, and there is no state in which that would be what anyone meant.
 */
export function toggleMode(current: BrowserModes, mode: BrowserMode): BrowserModes {
  const field = FIELD[mode]
  const on = !current[field]
  // Written as an assignment rather than a computed key in a literal, because a
  // computed key whose type is a union widens the whole object's type and the
  // compiler stops checking that all three fields are there.
  const next: BrowserModes = on ? { inspecting: false, recording: false, drawing: false } : { ...current }
  next[field] = on
  return next
}

/** Everything that actually has to change, so a no-op costs no IPC. */
export function modeChanges(
  current: BrowserModes,
  next: BrowserModes,
): { inspect?: boolean; record?: boolean; draw?: boolean } {
  const changes: { inspect?: boolean; record?: boolean; draw?: boolean } = {}
  if (current.inspecting !== next.inspecting) changes.inspect = next.inspecting
  if (current.recording !== next.recording) changes.record = next.recording
  if (current.drawing !== next.drawing) changes.draw = next.drawing
  return changes
}

/**
 * The one instruction sentence on screen, or none.
 *
 * *"Only one instruction strip on screen at a time."* There used to be two: a
 * line under the toolbar and the bottom panel's *"Turn on Inspect, then click
 * something in the page"*, which told him to do the thing he was already doing.
 * A third mode would have been a third chance to get that wrong, so the decision
 * is made here, once, from the mode state — and since the modes are exclusive by
 * construction, this returns one string or none. There is no arrangement of
 * arguments that produces two.
 *
 * Inspect's sentence goes the moment a capture exists, because the popup that
 * opens over the element is a better instruction than any line of text — and
 * the page is about to be replaced by that popup anyway, so nothing on screen
 * moves when the line leaves.
 *
 * Draw's does **not** go when the first mark lands, and that was found by
 * looking rather than by reasoning. The line sits above the stage, so removing
 * it makes the stage taller — and in draw mode the stage is holding a
 * photograph of the page under the user's pointer. Hiding the line mid-drawing
 * jumped the frozen page up by the height of a line of text between the first
 * stroke and the second. Draw mode keeps its sentence for its whole life: the
 * layout never moves, and the one thing worth having permanently on screen while
 * a page is parked is how to get it back.
 */
export function modeHint(modes: BrowserModes, state: { hasCapture: boolean }): string {
  if (modes.inspecting && !state.hasCapture) return 'Click any element in the page. Escape stops.'
  if (modes.drawing) return 'Drag on the page to mark it. Escape leaves without saving.'
  return ''
}
