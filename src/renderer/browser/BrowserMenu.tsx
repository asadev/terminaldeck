import { AnchoredPopup } from './AnchoredPopup'
import type { AccountsApi } from './accounts-bridge'
import type { Box } from './popup-anchor'

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

  return (
    <AnchoredPopup anchor={anchor} label="Browser menu" onClose={onClose}>
      <div className="bw-menu">
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
