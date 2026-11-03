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

/**
 * The whole of what the field is told, decided in one place.
 *
 * Three of the four cases below were already written down — in a long comment
 * over the JSX that computed them, which is where the fourth one was missing
 * from. With the picker on `Office PC` and a tab that had been nowhere, that JSX
 * asserted `This machine` about a page that does not exist:
 *
 *   > *"Why it is saying this machine? Since I click on Office PC, it is showing
 *   > this machine still."*
 *
 * It vanished as soon as a real Office PC page loaded, which is exactly why it
 * survived: the bar is only wrong while there is nothing on it to check it
 * against. So the rule is a function now, for the reason every rule in this
 * folder is one — this project's test run has no DOM, and a rule inside a render
 * tree is a rule nothing can hold.
 *
 * Four states, and no fifth:
 *
 *  - picker on this computer, page on this computer → nothing. The field is only
 *    the link, exactly as he asked.
 *  - picker and page on the same other machine → nothing, unless the tunnel had
 *    to take a different number, in which case the origin port alone: `:5199`.
 *    `servedMark` below does that subtraction.
 *  - picker naming one machine, page served by another (or by this computer) →
 *    the page's own machine, by name. The disagreement is the truth he asked to
 *    keep, and it is news, so it is written out.
 *  - **no page at all** → nothing. Nothing was fetched, so there is nobody to
 *    name, and naming one is asserting a fact about a page that does not exist.
 */
export interface BarServed {
  /**
   * What machine actually served the page in the address bar, read back off the
   * URL by `servedBy`, or null when no tunnel of this window's did.
   */
  page: { machineId: string; machineName: string; port: number; localPort: number; sameNumber: boolean } | null
  /** The machine the picker beside the field names. `''` is this computer. */
  picked: string
  /**
   * True when the tab is showing this app's own start page rather than a site —
   * `onStartPage` in `BrowserWorkspace.tsx`, which is the same predicate that
   * decides whether a native view is composited at all. Passed rather than
   * inferred from the URL so the chip and the page can never disagree about
   * whether there *is* a page.
   */
  blank: boolean
  /** What this computer is called. See `hereName` in `machines/types.ts`. */
  here: string
}

/** What the address field should say, or null for "nothing to add". */
export function barServed(input: BarServed): ServedBy | null {
  if (input.page !== null) {
    return {
      name: input.page.machineName,
      port: input.page.port,
      localPort: input.page.localPort,
      sameNumber: input.page.sameNumber,
      // Whether the picker beside the field is already saying this machine's
      // name. `servedMark` subtracts what it says from what is drawn.
      agrees: input.page.machineId === input.picked,
    }
  }
  /*
   * No tunnel served this page, which is two different situations and only one
   * of them is a fact.
   *
   * With the picker on another machine and a *site* on screen, this computer
   * fetched it, and the disagreement is the truth he asked to keep: *"we always
   * need a truth. So we will not know the truth if we remove from inside where
   * it is exactly running."*
   *
   * With nothing on screen there is no fetch to attribute. A start page is this
   * app's own document and a failed load is Chromium's — neither was served by
   * anybody, so naming a machine for it is inventing a fact about a page that
   * does not exist.
   */
  if (input.picked === '' || input.blank) return null
  // No port, because there is no tunnel to have one: `${here}:0` would be a
  // number invented to fill a slot.
  return { name: input.here, port: null, localPort: 0, sameNumber: true, agrees: false }
}

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
