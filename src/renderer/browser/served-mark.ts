/**
 * What the address field says about *where this page really is* — and, just as
 * much, what it does not say because the control beside it already did.
 *
 * ## The two sentences this has to satisfy at once
 *
 * He asked for the truth, having moved a window to his PC and watched it stay
 * put:
 *
 *   > *"we will need to keep this so we know actually where it is running right
 *   > now, or it should be unsuccessful here also, because we always need a
 *   > truth. So we will not know the truth if we remove from inside where it is
 *   > exactly running."*
 *
 * And thirty seconds earlier, about the very same corner of the very same field,
 * he asked for the opposite of a second copy:
 *
 *   > *"since we already have here a selection, why do we show inside the link
 *   > bar also local? Here we have this, so we know, like here also, then here
 *   > also. Why? It doesn't make any sense to keep in both side the same thing."*
 *
 * The first pass kept a mark for every tunnelled page, which meant a window
 * whose picker read `Office PC` drew `Office PC:5199` inside the field about a
 * centimetre away — his sentence about `local`, word for word, with a different
 * word in it.
 *
 * So the mark is **the remainder**: what is true minus what is already on
 * screen. The picker says the machine. The address says the port it was reached
 * on. This says whatever is left, and when nothing is left it draws nothing —
 * which is itself readable, because the mark appearing is what a disagreement
 * looks like.
 *
 *  - picker and page on the same machine, port kept → nothing. Both facts are
 *    already on the bar, twice over.
 *  - picker and page on the same machine, port *not* kept → `:5199`. The origin
 *    port is the one thing neither control can say: the address is showing the
 *    local end of the tunnel, a different number.
 *  - picker naming one machine, page served by another (or by this computer) →
 *    that machine's name. The disagreement is the truth he asked for, and it is
 *    news, so it is written out.
 *
 * The hover carries the whole arithmetic in every case it is drawn, because a
 * tooltip is not on screen until it is asked for.
 */

export interface ServedBy {
  /** The machine actually serving the page. */
  name: string
  /** The port on that machine, or null when this computer fetched the page. */
  port: number | null
  /** The port on this computer the tunnel is listening on. */
  localPort: number
  /** True when the two numbers came out the same, which is the ordinary case. */
  sameNumber: boolean
  /**
   * True when the machine picker beside the field already names this machine.
   *
   * Passed rather than inferred: the picker is the panel's, and this file has no
   * business knowing which machine is selected — only whether it agrees.
   */
  agrees: boolean
}

/** The text drawn in the field, or `''` for "nothing left to say". */
export function servedMark(served: ServedBy | null | undefined): string {
  if (!served) return ''
  if (!served.agrees) return served.port === null ? served.name : `${served.name}:${served.port}`
  if (served.port === null || served.sameNumber) return ''
  return `:${served.port}`
}

/** The hover: the whole arithmetic, for the cases where a mark is drawn. */
export function servedTitle(served: ServedBy | null | undefined): string {
  if (!served || servedMark(served) === '') return ''
  if (served.port === null) return served.name
  return served.sameNumber
    ? `${served.name}:${served.port}`
    : `${served.name}:${served.port} → :${served.localPort}`
}
