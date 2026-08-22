import './store-page.css'

/**
 * A row's logo and its name, once, for every row in the store.
 *
 * ## Why the two are one component
 *
 * Because they are one thing on screen and there are three row files. An
 * extension row, a built-in tool row and an MCP server row each used to open
 * with a bare `<span>` carrying the name, in three different class names, and
 * *"with logos"* would otherwise have been the same twelve lines written three
 * times — which is how the two stores ended up with one search box between them
 * in the first place. `storefront.ts` has the long version of that argument.
 *
 * Artwork arrives through `art` and goes to {@link StoreLogo}, which draws a
 * monogram derived from the name until there is any. So a catalogue with two
 * logos and forty monograms still draws forty-two rows of one shape, and the
 * lane filling the catalogues in has exactly one place to pass the image.
 *
 * ## Pressable only when there is somewhere to go
 *
 * With `onOpen` the name is a button and pressing it opens that row on its own.
 * Without it the name is a `<span>` and looks like one — no hover, no cursor, no
 * underline. Absent rather than disabled, and here it is not ceremony: the two
 * departments render on their own in tests and in the harness, where there is no
 * page to be sent to, and a name that highlighted under the pointer and did
 * nothing is the single defect this window's review keeps returning to.
 */

interface Props {
  name: string
  /** The row's own class for its name, so each department keeps its own type. */
  className: string
  /** Open this row on its own, when there is a page that can show it. */
  onOpen?: () => void
}

export function StoreRowName({ name, className, onOpen }: Props) {
  const label = <span className={className}>{name}</span>
  return (
    <span className="store-rowname">
      {onOpen === undefined ? (
        label
      ) : (
        <button
          type="button"
          className="store-rowname-open"
          onClick={onOpen}
          title={`Open ${name} on its own`}
        >
          {label}
        </button>
      )}
    </span>
  )
}
