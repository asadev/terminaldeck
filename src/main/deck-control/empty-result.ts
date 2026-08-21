/**
 * The difference between "it worked" and "it worked and produced nothing".
 *
 * ## Why a whole module for one boolean
 *
 * Because every number behind this round of work is the same failure wearing a
 * different hat, and the hat is always "success":
 *
 *  - 48,473 assets skipped by a resume ledger keyed on URL, during a
 *    re-download that was happening *because the files were bad*. It exited
 *    reporting success.
 *  - Three scripts that reported success while doing nothing at all.
 *  - 7% of a dataset shipped as complete, because nothing compared it against
 *    the total the page itself had stated.
 *
 * None of those was a crash and none produced an error. Each was a call that
 * returned, carried no complaint, and was believed. A caller — a model, a shell
 * script, a person reading a log — cannot act on a difference nobody encoded,
 * and "zero rows" is *not* self-evidently a problem: a filter that legitimately
 * matches nothing looks identical in the result to a filter that was never
 * applied.
 *
 * So the result says which it was. Not the exit code — the exit code belongs to
 * whatever runs the crawl, and by the time a process exits the information is
 * gone. The **result shape**: `empty` is on every result this module wraps, and
 * `emptyReason` is a sentence naming what produced nothing and what would
 * change it.
 *
 * ## The rule
 *
 * `empty` is `true` exactly when the call produced no rows, matched no
 * requests, captured no responses — and it is `false` otherwise, always
 * present, never inferred from the absence of a field. `emptyReason` is
 * non-empty exactly when `empty` is true. A reader that only ever checks one of
 * the two is still right.
 *
 * ## What this is not
 *
 * It is not an error and it does not throw. A capture that found nothing is a
 * true answer about a page, and turning it into a refusal would make a legible
 * outcome indistinguishable from a rule that said no. `Refused` is for "you may
 * not"; this is for "you may, and here is what you got, and it was nothing".
 */

export interface Emptiness {
  /** True when this call produced nothing. Always present. */
  empty: boolean
  /**
   * Why it was empty, and what would change it. Empty string when it was not.
   *
   * Written for the reader who has to decide what to do next, so it names the
   * cause rather than restating the count: *"no request matched the rules — the
   * page may not have loaded any images yet"* is actionable, *"0 requests"* is
   * not.
   */
  emptyReason: string
}

/**
 * Judge a result, and say so on it.
 *
 * `produced` is whatever this call is *for* — rows written, requests matched,
 * responses captured. A call with several such counts sums the ones that would
 * each independently make it worthwhile; see `browser-network-tool.ts`, where a
 * run that fulfilled no requests but captured forty responses is not empty.
 */
export function withEmptiness<T extends object>(
  value: T,
  verdict: { produced: number; whenNone: string },
): T & Emptiness {
  const empty = verdict.produced <= 0
  return {
    ...value,
    empty,
    emptyReason: empty ? verdict.whenNone : '',
  }
}

/**
 * The same judgement for the action-log summary.
 *
 * The summary is what a person skims, so an empty run has to be visible there
 * too — a log full of rows that all read `stopped B2` with no way to tell the
 * productive ones apart is a log that has to be opened one row at a time.
 */
export function emptySummary(produced: number): { empty: boolean } {
  return { empty: produced <= 0 }
}
