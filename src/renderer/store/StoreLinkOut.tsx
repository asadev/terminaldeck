import './storefront.css'
import { linkProps } from '../link'

/**
 * The honest fallback: **Get it**, for a row this app cannot install.
 *
 * ## Why a store is allowed to list what it cannot install
 *
 * Asad, on both stores at once:
 *
 *   > *"it will all the applications will not be there, there will be only
 *   > install button and it will real time download from the live … or maybe
 *   > only link of the application from github or wherever they can go and
 *   > download it, it will just redirect them and they can install if not
 *   > possible to bring button to install."*
 *
 * Both catalogues already refuse to draw an Install that cannot work — the
 * browser store for an extension it watched failing here, the MCP store for a
 * server whose runtime is not on this machine — and both were right to. What
 * they did instead was draw *nothing*, which is a different mistake with the
 * same cause: the store had two answers, *here it is* and *silence*, and a row
 * with neither a button nor a way onward reads as a dead end.
 *
 * This is the third answer, and it is the one that lets the catalogues hold
 * everything worth holding. The row keeps its measured sentence, keeps its
 * refusal to pretend, and gains one control that does exactly what it says:
 * opens the project's own page, where the person can decide for themselves.
 *
 * ## Where it opens
 *
 * In a tab of this app's own browser, through `renderer/link.ts` — *"currently
 * it's opening a separate window — I want it to use the same window inside
 * Terminal Deck for browser"*, 2026-08-17 — and right-clicking it offers the
 * system browser, which is the same pair of behaviours every other link in this
 * app has. Nothing new is invented for the store's sake, so there is one door
 * out of the renderer and it stays one door.
 *
 * ## Why the label is not "Install"
 *
 * Because pressing it installs nothing, and this app's whole complaint about
 * stores is buttons that look like they do a thing and do another. **Get it**
 * for a row that has somewhere to get, **Open** for one whose link is the
 * project itself rather than a download.
 */

interface Props {
  /** The project's own page. Nothing is drawn for an empty one. */
  url: string
  /** `Get it` when the destination offers the thing; `Open` for a project page. */
  label?: string
  /** Extra words for a screen reader, so twenty "Get it" buttons are not alike. */
  describes: string
}

export function StoreLinkOut({ url, label = 'Get it', describes }: Props) {
  if (!/^https?:\/\//i.test(url)) return null
  return (
    <button
      type="button"
      className="storefront-getit"
      aria-label={`${label} — ${describes}`}
      title={url}
      {...linkProps(url)}
    >
      {label}
    </button>
  )
}
