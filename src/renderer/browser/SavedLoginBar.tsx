import { useState } from 'react'
import type { AccountsApi } from './accounts-bridge'

export interface SavedLoginOffer {
  /** The browser tab this is about. Several panels can be mounted at once. */
  id: string
  origin: string
  /** Newest first. One entry is the ordinary case; two is why this is a list. */
  usernames: string[]
  /** Did the browser already put one in? */
  filled: boolean
  /** Why it did not, when it did not. Empty when it did. */
  note: string
}

/**
 * "There is a saved login for this site" — said on the page it is about.
 *
 * ## Why this exists at all
 *
 * Two moments, and neither of them had an answer before:
 *
 *  1. **The fill was withheld.** `browser-fill-gate.ts` refuses to fill a page
 *     an agent navigated to or is holding, because a fill an agent can cause is
 *     an agent signing in as the person without ever seeing a password. Refusing
 *     and saying nothing would be resistance with a security label on it: the
 *     person is looking at their own sign-in form, their password is in this
 *     app, and the app declines to mention it.
 *  2. **Two accounts on one site.** The automatic fill picks the most recently
 *     saved, which is the right guess and is sometimes the wrong account. Until
 *     this bar, changing it meant Settings → Browser → Saved passwords → Copy →
 *     click the field → paste: six steps, in a different window, to use a
 *     password this app already had. One press, on the page, instead.
 *
 * ## What is on it
 *
 * The site, the usernames, and one button each. **No password**, and there is no
 * shape on this side that could carry one — {@link SavedLoginOffer} has no field
 * for it, the way `SavedLoginSummary` has none. The press calls
 * `browser-password:fill`, which types it into the page from the main process
 * and answers with a boolean.
 *
 * ## Why it is a block and not a popup
 *
 * The same reason `SignInBanner` is, and it is a fact about this window rather
 * than taste: a browser page is a native view composited above the entire React
 * tree, so nothing drawn in HTML can sit on top of it. As a block it shrinks the
 * page's rectangle instead, the site reflows once, and the form stays visible —
 * which matters more here than anywhere, because the thing it is offering to
 * fill is the field directly below it.
 */
export function SavedLoginBar({
  offer,
  api,
  onDone,
  onDismiss,
}: {
  offer: SavedLoginOffer
  api: AccountsApi
  onDone(message: string): void
  onDismiss(): void
}) {
  const [busy, setBusy] = useState('')
  const site = offer.origin.replace(/^https?:\/\//, '')

  const fill = async (username: string): Promise<void> => {
    if (!api.browserPasswordFill) return
    setBusy(username)
    const done = await api.browserPasswordFill(offer.id, username).catch(() => false)
    setBusy('')
    /*
     * The honest sentence for each outcome, and `false` has one rather than
     * being swallowed. It means the page navigated between the offer and the
     * press, or the sign-in form went away — both real, both invisible, and both
     * indistinguishable from a broken button if nothing is said.
     */
    onDone(
      done === true
        ? `Filled in ${username === '' ? 'the saved login' : username}.`
        : 'That did not go in — the page changed since the sign-in form was found. Reload and try again.',
    )
  }

  return (
    <div className="bw-offer" role="status">
      <div className="bw-signin-text">
        <strong>{offer.filled ? 'Signed in with a saved login' : 'Saved login for this site'}</strong>
        <span>
          {offer.note !== ''
            ? offer.note
            : offer.filled
              ? `${offer.usernames[0] ?? ''} at ${site}. Use a different account if this is the wrong one.`
              : `${site}. It is on this machine, encrypted — nothing is typed until you press.`}
        </span>
      </div>
      <span className="bw-spacer" />
      {/*
        Every saved username, each its own button, rather than a menu behind a
        single "Fill". One account is the ordinary case and gets one button; two
        is the case this bar exists for, and burying the second one behind a
        chevron is how it stays unfound.
      */}
      {offer.usernames.map((username, index) => (
        <button
          key={`${username}|${index}`}
          type="button"
          className={index === 0 && !offer.filled ? 'bw-primary' : 'bw-text-button'}
          disabled={busy !== '' || !api.browserPasswordFill}
          title={`Type this saved login into the form on this page. It is never shown here.`}
          onClick={() => void fill(username)}
        >
          {busy === username ? 'Filling…' : username === '' ? 'Fill saved login' : username}
        </button>
      ))}
      <button type="button" className="bw-text-button" onClick={onDismiss}>
        Not now
      </button>
    </div>
  )
}
