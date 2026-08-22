import type { CSSProperties, ReactNode } from 'react'

/**
 * The tile a row wears where its logo goes.
 *
 * ## Why there is a component here at all, and not just an `<img>`
 *
 * Asad asked for logos — *"with logos"* — and a store with a logo on some rows
 * and a hole on the others looks broken in a way a store with no logos does not.
 * The catalogues are the place artwork will arrive from, one row at a time, over
 * more than one release; this is what stands in the gap in the meantime, and it
 * is a **monogram**, not a placeholder.
 *
 * A monogram is honest. It is derived from the row's own name, so it is stable
 * across launches, distinct between neighbours, and it never claims to be
 * somebody's brand. A grey box with a broken-image glyph claims a logo failed to
 * load; a question mark claims the app does not know what this is. Neither is
 * true, and both look like a defect. The initial of the thing you are reading
 * about is just the initial of the thing you are reading about.
 *
 * ## The hue is computed, not chosen
 *
 * From the name, so the same tool is the same colour everywhere it appears — the
 * shelf, the detail view, the installed list — and two rows next to each other
 * are almost never the same colour. It is a **tint of the surface**, not a
 * saturated brand colour: these sit in a grid of twenty and a grid of twenty
 * saturated squares is a toy, not a tool. The text on it is the app's own
 * primary colour rather than white, so it reads in either theme without the tile
 * having to know which one it is in.
 *
 * ## When artwork arrives
 *
 * Pass it as `art`. Nothing else changes: the tile keeps its size, its radius
 * and its place in the row, so a catalogue that has one logo and nineteen
 * monograms still draws twenty rows of the same shape. Artwork must be something
 * the app already has on disk or has fetched and checked — this component will
 * not reach for a URL, because a store that fetches an image from a project's
 * own server on every render tells that server who is browsing and when.
 */

interface Props {
  /** The row's name. The monogram and the hue are both taken from it. */
  name: string
  /**
   * Real artwork, when the catalogue has some. An `<img>` or an inline `<svg>`
   * — anything that draws itself inside the tile.
   */
  art?: ReactNode
  /** `lg` for the detail view, where the tile is the first thing on the page. */
  size?: 'sm' | 'lg'
}

/**
 * The one or two letters on the tile.
 *
 * Two when the name is two words — *Dark Reader* is `DR`, which is a better
 * mark than `D` beside *Decentraleyes*. One otherwise, upper-cased, because
 * `se` for `sequential-thinking` reads as a typo. Punctuation and digits are
 * skipped rather than printed: `1Password` would otherwise wear a `1`.
 */
export function monogram(name: string): string {
  const words = name
    .split(/[\s\-_/.]+/)
    .map((word) => word.replace(/[^\p{L}]/gu, ''))
    .filter((word) => word !== '')
  if (words.length === 0) return '·'
  if (words.length === 1) return words[0].slice(0, 1).toUpperCase()
  return (words[0].slice(0, 1) + words[1].slice(0, 1)).toUpperCase()
}

/**
 * A hue in degrees, from the name.
 *
 * A small deterministic hash rather than an index into a palette, because an
 * index has to be kept in step with a list that changes every release and a hash
 * does not. Exported so a test can pin that it is stable — a colour that moved
 * between launches would be worse than no colour, since the whole value of it is
 * recognising a row you have seen before.
 */
export function hueOf(name: string): number {
  let hash = 0
  for (const character of name.toLowerCase()) hash = (hash * 31 + character.charCodeAt(0)) % 360
  return hash
}

export function StoreLogo({ name, art, size = 'sm' }: Props) {
  if (art !== undefined) {
    return (
      <span className="store-logo" data-size={size} aria-hidden="true">
        {art}
      </span>
    )
  }
  return (
    <span
      className="store-logo store-logo-monogram"
      data-size={size}
      /* Decorative: the name is printed beside it in full, and a screen reader
         announcing "D R" before "Dark Reader" is noise. */
      aria-hidden="true"
      style={{ '--store-logo-hue': hueOf(name) } as CSSProperties}
    >
      {monogram(name)}
    </span>
  )
}
