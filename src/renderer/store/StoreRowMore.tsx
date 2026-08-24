import { createContext, useContext, type ReactNode } from 'react'
import './StoreRowMore.css'

/**
 * The rest of a store row, one press away — and the thing that decides whether
 * it needs pressing at all.
 *
 * ## What was wrong, and it was not the words
 *
 * Every fact a row knew was printed on the shelf. A Dark Reader row, browsing:
 *
 *     Licence    MIT
 *     Project    https://github.com/darkreader/darkreader
 *     Download   https://github.com/darkreader/darkreader/releases/download/…
 *                — 831,273 bytes, exactly
 *     sha256     20e7993eee081577db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64
 *                — the download must match this, or nothing is saved.
 *     Watched working: a plain white test page came back with background rgb(24,
 *     26, 27) and a style.darkreader element injected into it, and its popup
 *     opens and renders. …
 *
 * Four lines of build metadata and a paragraph of measurement, on a shelf
 * somebody is browsing. Measured on the shipped page at 1440px: **two rows fit
 * on a screen** across two columns of twelve. A sixty-four character hash is not
 * something a person reads while choosing an ad blocker. Asad's words for what
 * it should be instead: *"so it feels like a proper store system."*
 *
 * ## Why the facts could not simply move to the detail page
 *
 * Because there is no detail page to move them to. `store/StoreDetail.tsx` draws
 * the **same row component** the shelf does — deliberately, and the rule it
 * keeps is pinned by a test:
 *
 *   > *a download row shows URL and fingerprint on this screen, not in a detail
 *   > view*
 *
 * That rule is right and it is why the shelf was unreadable: with one
 * representation for both surfaces, every fact that had to be reachable had to
 * be printed where somebody is scanning twenty rows. The row had a size problem
 * because it had no second size.
 *
 * This gives it one. The same row, in two places, saying exactly the same
 * things — the shelf folds the long half behind a `summary` that names what is
 * inside it, the detail page draws it open. **Nothing is deleted and nothing
 * moves off the row**: the pinned hash and the measured paragraph are still in
 * the shelf's markup, one press from the row they belong to, which is what the
 * test asserts and what an auditor needs.
 *
 * ## A `details`, not React state
 *
 * The same argument `StorePanel.tsx` already makes for the limits disclosure:
 * it opens and shuts with no JavaScript, so it renders in a test that has no
 * DOM, and its contents are in the markup whether it is open or not. State
 * would have made the fingerprint conditional on a click having happened, which
 * is the one thing this must not be.
 *
 * ## Why the place is a context and not a prop
 *
 * Because the thing that knows is the frame, not the caller. `StoreDetail` is
 * the only surface in the app that means *this row is the page*, and it wraps
 * whatever it was handed. A prop would have to be threaded through both
 * departments' bodies, both shelf renderers and every harness that draws a row —
 * five places to keep in agreement about one fact, and the failure mode of
 * getting it wrong is a detail page that hides its own detail.
 */

export type StoreRowPlace = 'shelf' | 'page'

const Place = createContext<StoreRowPlace>('shelf')

/**
 * Declare what the rows inside this are: a shelf of many, or one on its own.
 *
 * `shelf` is the default and no surface sets it — a row rendered by anything
 * that has not thought about this is a row on a shelf, which is the safe
 * answer, because the folded state is the one that always has a way out of it.
 */
export function StoreRowPlaceIs({
  place,
  children,
}: {
  place: StoreRowPlace
  children: ReactNode
}) {
  return <Place.Provider value={place}>{children}</Place.Provider>
}

/** Which of the two a row is being drawn on. */
export function useStoreRowPlace(): StoreRowPlace {
  return useContext(Place)
}

interface MoreProps {
  /**
   * What is inside, named rather than promised.
   *
   * *"More"* would be the summary this store is not allowed to have: somebody
   * auditing a download has to know from the shelf that the fingerprint is one
   * press behind this line, and a label that will not say what it hides makes
   * them open twenty of them to find out.
   */
  label: string
  children: ReactNode
}

/**
 * The long half of a row: folded on a shelf, open on a page.
 *
 * On a page it is not a shut `details` that happens to be open — it is no
 * `details` at all. A disclosure on a surface that exists to disclose is a
 * control whose only use is to hide the thing you navigated to, and rendering
 * it and looking at it is what settled that: a detail view whose facts arrive
 * behind a triangle is a detail view that is not one.
 */
export function StoreRowMore({ label, children }: MoreProps) {
  const place = useStoreRowPlace()
  if (place === 'page') return <div className="store-more-open-page">{children}</div>
  return (
    <details className="store-more">
      <summary className="store-more-summary">{label}</summary>
      <div className="store-more-body">{children}</div>
    </details>
  )
}
