import './storefront.css'
import { linkProps } from '../link'

/**
 * The honest fallback: **Get it**, for an MCP row this machine cannot run yet.
 *
 * ## Why one store still has this and the other does not
 *
 * It was built for both. Asad, then:
 *
 *   > *"it will all the applications will not be there, there will be only
 *   > install button and it will real time download from the live … or maybe
 *   > only link of the application from github or wherever they can go and
 *   > download it, it will just redirect them and they can install if not
 *   > possible to bring button to install."*
 *
 * Both catalogues refused to draw an Install that cannot work, and both drew
 * *nothing* instead, which reads as a dead end. This was the third answer.
 *
 * The browser store stopped needing it, and the reason is worth stating because
 * it is the difference between the two halves. Asad again, on what it did there:
 *
 *   > *"They click Get and it takes them to the Chrome store … we should not
 *   > offer tools that don't work with our architecture."*
 *
 * An extension that cannot install here cannot install here *ever* — this
 * browser provides the `chrome.*` it provides, and no shopping trip changes
 * that — so the link was sending somebody to a shop whose goods do not fit. The
 * catalogue now holds only what installs, and `browser/ExtensionRow.tsx` draws
 * no link out at all.
 *
 * An MCP row is not like that. *Cannot run* there means a runtime is not on
 * **this machine yet** — `node`, `uvx`, Docker — which is a thing a person can
 * go and change in ten minutes, and the project's own page is where they would
 * start. So this stays, for the store where the destination is genuinely useful.
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
