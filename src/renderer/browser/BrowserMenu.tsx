import { useEffect, useState } from 'react'
import { AnchoredPopup } from './AnchoredPopup'
import type { AccountsApi } from './accounts-bridge'
import type { Box } from './popup-anchor'
import { foldedActions, groupFor, type FoldedAction } from './toolbar-overflow'

interface Props {
  api: AccountsApi
  anchor: Box
  /** The page the menu is about. Empty when nothing is open. */
  url: string
  /** Settings → Browser → Start page, so the row can say which state it is in. */
  startUrl: string
  /** Absent when the panel has no way to write the setting — the row goes then. */
  onStartUrl?: (url: string) => void
  /** Reopen the recorded flow. Absent when nothing has been recorded. */
  onFlow?: () => void
  /**
   * The cookies dialog — but only in a build with no profile button.
   *
   * Site data is a *profile's* site data, so its home is `ProfileMenu`. That
   * menu only exists when the preload has wired all five profile channels, and
   * on a preload that has not, the dialog would otherwise have no door at all.
   * So this is a fallback and never a second copy: the panel passes it exactly
   * when it is not drawing a profile button, which is the only arrangement in
   * which *"It doesn't make any sense to keep in both side the same thing"*
   * stays true.
   */
  onCookies?: () => void
  onClose(): void
}

/**
 * The ⋯ menu: this page, and this browser.
 *
 * ## What it stopped being
 *
 * It held profiles, saved logins, cookies, the start page and the recorded flow
 * — five things, of which the first three answer *"which of me is this, and what
 * does this browser remember"* and the last two are about the page in front of
 * you. That was one menu doing two jobs, and it was the reason the profile list
 * had nowhere to grow: a profile got one row and a tick, and he read that
 * correctly as nothing.
 *
 *   > *"if I click on profile, there is nothing inside the profile, just the
 *   > name, not like Chrome."*
 *
 * So the first three moved out, to a button of their own on the toolbar with a
 * menu that has room to say what a profile actually holds — `ProfileMenu.tsx`,
 * which is also where the argument for keeping profiles at all is written down.
 * What is left here is one subject: the page.
 *
 * ## And what it stopped saying
 *
 *   > *"I don't want any kind of long descriptions anywhere."*
 *
 * Every row is a verb. The disabled states still carry a short `title`, because
 * a greyed row with no reason is the other complaint from the same review — but
 * a `title` is three or four words now, not a sentence.
 *
 * ## And what it took on
 *
 *   > *"we can have a bigger link bar because when it is smaller, then it
 *   > becomes too small … Let's make these icons smaller and make this maybe
 *   > bigger."*
 *
 * On a narrow panel the toolbar's page actions come off the bar and arrive here,
 * at the top, above the rows about the page — Chrome's answer to the same
 * problem, and the reason he asked for Chrome's ⋮ in the first place. The list
 * is read off the bar rather than passed in, so this menu offers exactly what
 * the bar is not showing and never a second copy of a button you can already
 * see: `toolbar-overflow.ts`.
 */
export function BrowserMenu({
  api,
  anchor,
  url,
  startUrl,
  onStartUrl,
  onFlow,
  onCookies,
  onClose,
}: Props) {
  const isStartPage = url !== '' && url === startUrl

  /*
   * The toolbar buttons this panel's bar could not fit.
   *
   * Read once, when the menu opens, off the group the ⋯ that opened it lives in
   * — the anchor is that button's own rectangle, so it identifies the bar even
   * with two browser panels side by side. Nothing watches for resizes: the menu
   * closes on a click and the bar is measured again the next time it is asked
   * for, which is cheaper and cannot go stale on screen.
   */
  const [folded, setFolded] = useState<FoldedAction<HTMLButtonElement>[]>([])

  useEffect(() => {
    const group = groupFor(document.querySelectorAll<HTMLElement>('.bw-actions'), anchor)
    setFolded(group === null ? [] : foldedActions(group.querySelectorAll('button[data-fold]')))
  }, [anchor])

  return (
    <AnchoredPopup anchor={anchor} label="Browser menu" onClose={onClose}>
      <div className="bw-menu">
        {/* The row *is* the button: pressing it presses the one on the bar, so
            there is no second copy of what Record or Devtools means living in
            this file to fall out of step with the first. */}
        {folded.map((action) => (
          <button
            key={action.label}
            type="button"
            className="bw-menu-item"
            disabled={action.disabled}
            onClick={() => {
              action.button.click()
              onClose()
            }}
          >
            {action.label}
          </button>
        ))}

        {/* Disabled with a reason rather than hidden. There is always a page or
            there is not, and a row that disappears when nothing is open reads as
            the menu changing shape at random. */}
        {onStartUrl && (
          <button
            type="button"
            className="bw-menu-item"
            disabled={url === '' || isStartPage}
            title={url === '' ? 'No page open' : isStartPage ? 'Already the start page' : undefined}
            onClick={() => {
              onStartUrl(url)
              onClose()
            }}
          >
            {isStartPage ? 'Start page' : 'Set as start page'}
          </button>
        )}

        <button
          type="button"
          className="bw-menu-item"
          disabled={url === '' || !api.browserSignInHandover}
          title={url === '' ? 'No page open' : undefined}
          onClick={() => {
            void api.browserSignInHandover?.(url)
            onClose()
          }}
        >
          Open in your browser
        </button>

        {onCookies && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onCookies()
              onClose()
            }}
          >
            Cookies and site data
          </button>
        )}

        {onFlow && (
          <button
            type="button"
            className="bw-menu-item"
            onClick={() => {
              onFlow()
              onClose()
            }}
          >
            Recorded flow
          </button>
        )}
      </div>
    </AnchoredPopup>
  )
}
