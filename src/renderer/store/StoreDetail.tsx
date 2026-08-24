import type { ReactNode } from 'react'
import { StoreRowPlaceIs } from './StoreRowMore'

/**
 * One thing in the store, on its own.
 *
 * ## What this is, and what it deliberately is not
 *
 * It is a **frame**, and by the time it was rendered and looked at, it was a
 * very thin one: the way back, and then the department's own row at full size.
 *
 * That thinness is the design and it was arrived at by deleting two attempts.
 * The first drew a header with the name, the version and a facts strip —
 * *Shelf, Licence, Source, How it runs, Needs* — above the row. Every one of
 * those is **already on the row**: the extension row prints the licence and the
 * download it is pinned to, the server row prints how it runs and what it needs
 * and the exact command it will write. So the page said the same things twice,
 * forty pixels apart, which is the note this app keeps collecting: *"Everywhere
 * you are putting a lot of statements. We don't need to give the statements."*
 * The second attempt dropped the facts and kept the name and the logo, and a
 * screenshot showed **uBlock Origin 1.73.0** printed twice with two copies of
 * the same monogram between them.
 *
 * What is left is the honest shape. The row already **is** the detail — name,
 * version, state, artwork, every fact and the real button. What a person needs
 * on top of it is somewhere to come back to. The row is drawn larger here, by
 * `store-page.css`, so it reads as a page rather than as a list item; that is a
 * size, not a second copy.
 *
 * ## The rule this frame exists to keep
 *
 * `StorePanel.test.tsx` pins something this store earned the hard way:
 *
 *   > *a download row shows URL and fingerprint on this screen, not in a detail
 *   > view*
 *
 * A detail view is a very easy way to break that. You move the awkward facts
 * behind a click, the shelf gets tidy, and the disclosure quietly stops being
 * disclosure. This one cannot: the browsing shelf draws the same
 * `ExtensionRow` / `McpStoreRow` this does, with the same sha256 and the same
 * *Reaches every page you open*. Nothing is hidden behind getting here, which is
 * exactly what makes getting here optional.
 *
 * What it is *for*, then: the store holds forty-odd rows across two departments,
 * and somebody deciding on one of them wants that one on screen without the
 * other thirty-nine. That is a real need and it is the only one this serves.
 *
 * ## The one thing it now tells the row
 *
 * That it is a page. Nothing else — no facts, no header, no second button.
 *
 * The rule above survived a second reading of the shelf and cost it everything:
 * with one representation for both surfaces, every fact that had to be reachable
 * had to be printed where somebody is scanning twenty rows, and the shipped page
 * fit **two rows on a screen**. `store/StoreRowMore.tsx` is what gave the row a
 * second size; this frame is the only thing in the app that knows a row is being
 * read on its own, so this is where that is said.
 *
 * The rule itself is untouched. A shelf row's markup still carries its download
 * URL and its fingerprint — folded, one press away, on the row itself — so the
 * awkward facts have not been moved behind getting here, which is the exact
 * failure `StorePanel.test.tsx` pins against. What this adds is that somebody
 * who *did* come here does not have to press anything.
 */

interface Props {
  /** The shelf or department this was reached from, in its own words. */
  backTo: string
  onBack(): void
  /** The department's own row, at full size. */
  children: ReactNode
}

export function StoreDetail({ backTo, onBack, children }: Props) {
  return (
    <div className="store-detail">
      {/*
        The way back names where it goes — *Back to Passwords* — rather than
        saying "Back". A row can be arrived at from any of sixteen shelves or
        from a search across both departments, so "Back" alone would be a
        control whose behaviour you have to remember rather than read.
      */}
      <button type="button" className="store-detail-back" onClick={onBack}>
        <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
          <path
            d="M14.5 5.5 8 12l6.5 6.5"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
        </svg>
        Back to {backTo}
      </button>
      {/*
        The row, whole and unaltered — and told that here it is the page, which
        is the whole of what this frame says to it. Every department's row is
        wrapped without either department knowing: a prop would have had to be
        threaded through two bodies, two shelf renderers and the harness, and the
        cost of one of them disagreeing is a detail page that folds its own
        detail away.
      */}
      <StoreRowPlaceIs place="page">{children}</StoreRowPlaceIs>
    </div>
  )
}
