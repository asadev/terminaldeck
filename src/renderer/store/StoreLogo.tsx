import { useState } from 'react'
import { STORE_LOGO_ASSETS } from './logo-data'
import './StoreLogo.css'

/**
 * The mark on a store row.
 *
 * ## Why a store needs one at all
 *
 * Asad, looking at both stores:
 *
 *   > *"store must be like a proper store … with logos"*
 *
 * Forty-two rows of name-and-paragraph is a spreadsheet. The mark is what makes
 * it a store: it is how somebody finds Bitwarden without reading, and it is the
 * difference between scanning a shelf and reading a list. Nothing else on the
 * row does that job — the name is set in the same type as every other name, and
 * by the time you have read it you have already done the work the picture was
 * supposed to save you.
 *
 * ## Where the picture comes from
 *
 * `logo-data.ts`, which is inside this app. Never a URL. An `<img>` pointed at a
 * vendor's server is a request to that vendor every time the store opens — an IP
 * address and a referrer handed to twenty companies for the privilege of drawing
 * a 40-pixel square — and it draws nothing at all with no network. A store whose
 * argument is that every byte it offers was pinned in advance cannot then fetch
 * its own furniture at render time. `scripts/store-logos.mjs` fetched each one
 * once, and recorded where from and what it hashed to.
 *
 * ## The row with no mark
 *
 * There will always be one. An extension somebody added from a folder is not in
 * any catalogue and has no logo, and a row another lane adds tomorrow will not
 * have one until the script is next run. Those rows get {@link monogram}: the
 * first letter of the name on one of this app's own `--bind-*` fills, which is
 * the same palette the machine chips use and is guaranteed readable with
 * `--bind-fg` ink on both themes. Four fills, chosen from the row's own id, so
 * a shelf of them is not one colour repeated — and stable, so the same row is
 * the same colour every time it is drawn.
 *
 * It is deliberately not a grey square with a broken-image glyph, and not a
 * generic "extension" icon either: a placeholder that pretends to be a logo is
 * the store-row version of a button that does nothing. A letter on a colour is
 * honestly this app's own drawing, and reads as one.
 */

/** How many fills the monogram chooses between. See `tokens.css` `--bind-*`. */
const MONOGRAM_FILLS = 4

/**
 * Which fill a row without a mark gets, from its own id.
 *
 * A sum of code points rather than anything cleverer: the requirement is only
 * that it is stable and spreads a shelf across four values, and a hash with
 * better avalanche would be a bigger promise than "these two rows are usually
 * different colours". Pure, and pinned by `StoreLogo.test.ts`.
 */
export function monogramFill(id: string): number {
  let total = 0
  for (const point of id) total += point.codePointAt(0) ?? 0
  return (total % MONOGRAM_FILLS) + 1
}

/**
 * The letter a row without a mark wears.
 *
 * The first thing in the name that is a letter or a digit, upper-cased —
 * skipping past the punctuation some of these names start with, so a row called
 * `@scope/thing` wears an S and not an at-sign. `?` when there is nothing at
 * all,
 * which happens only for a row with an empty name and is at least visibly a
 * placeholder rather than a blank square.
 */
export function monogram(name: string): string {
  for (const point of name) {
    if (/[\p{L}\p{N}]/u.test(point)) return point.toUpperCase()
  }
  return '?'
}

interface Props {
  /** The row's display name. Only its first letter is used, for the fallback. */
  name: string
  /** The row's own id, which decides the fallback's colour. */
  id: string
  /** The key into `logo-data.ts`. `''` or unknown falls back to the monogram. */
  logo?: string
}

export function StoreLogo({ name, id, logo }: Props) {
  /* A data URI cannot 404, but it can be a file that does not parse — so the
     fallback is wired to the image's own failure as well as to its absence.
     One state, set once, never read back: a mark that failed to draw will not
     start drawing. */
  const [broken, setBroken] = useState(false)
  const asset = logo === undefined || logo === '' ? undefined : STORE_LOGO_ASSETS[logo]

  if (asset === undefined || broken) {
    return (
      <span
        className="storelogo storelogo-monogram"
        data-fill={monogramFill(id)}
        aria-hidden="true"
      >
        {monogram(name)}
      </span>
    )
  }

  return (
    <span className={asset.plate ? 'storelogo storelogo-plate' : 'storelogo'}>
      {/*
        `alt=""`, deliberately. The name is the next thing in the row and a
        screen reader that said "Bitwarden logo, Bitwarden" would be reading the
        decoration twice. The picture carries nothing the row does not also say
        in words.
      */}
      <img src={asset.src} alt="" draggable={false} onError={() => setBroken(true)} />
    </span>
  )
}
