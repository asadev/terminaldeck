import { useState } from 'react'
import type { AccountsApi, SignInTrouble } from './accounts-bridge'

interface Props {
  trouble: SignInTrouble
  api: AccountsApi
  /** The page it is about, which is what gets handed over. */
  url: string
  onDismiss(): void
}

/**
 * The sign-in that is not going to work, said before it fails.
 *
 * ## What he hit
 *
 * *"Google sign-in refuses."* Google blocks sign-ins from browsers embedded
 * inside other programs, and it does it after the address step, so from the
 * inside it looks like the site breaking rather than the browser being turned
 * away. `browser-signin.ts` reads which of the two states the address is in and
 * carries the measurements; this draws it.
 *
 * ## Why it is a band and not a popup
 *
 * A popup would park the page — a browser page here is a native view composited
 * above the whole renderer, and `overlay-watch.ts` is the standing essay on why
 * nothing HTML can be drawn over it. Parking the sign-in the person is halfway
 * through to tell them about it would be worse than saying nothing. A band in
 * the flow shrinks the page's rectangle instead, so the site reflows once and
 * stays visible, which is the same bargain `DriveBanner` makes two elements
 * above this one.
 *
 * ## Why the handover is two buttons and not one
 *
 * Handing the sign-in out is half a job. The other half is coming back with it,
 * and this app can genuinely do that: `cookie-import.ts` reads a browser
 * profile's cookie database, decrypts it through the OS keychain and writes the
 * cookies for named domains into this browser's session. So the round trip is
 * real — finish the sign-in where nothing is refused, then press the second
 * button and the signed-in session is here. Collapsing both into one button
 * would mean importing before the person had finished signing in, which imports
 * a signed-out session and looks like the feature not working.
 */
export function SignInBanner({ trouble, api, url, onDismiss }: Props) {
  const [stage, setStage] = useState<'idle' | 'handed' | 'importing' | 'done'>('idle')
  const [outcome, setOutcome] = useState('')

  const hand = async (): Promise<void> => {
    await api.browserSignInHandover?.(url)
    setStage('handed')
  }

  const bringBack = async (): Promise<void> => {
    if (!api.importBrowserCookies) return
    setStage('importing')
    const report = await api.importBrowserCookies({ domains: trouble.domains })
    const imported =
      typeof report === 'object' && report !== null
        ? (report as Record<string, unknown>).imported
        : null
    setStage('done')
    setOutcome(
      typeof imported === 'number' && imported > 0
        ? `Brought back ${imported} cookie${imported === 1 ? '' : 's'}. Reload the page.`
        : 'Nothing came back. Make sure you finished signing in, in the same browser profile.',
    )
  }

  return (
    <div className="bw-signin" role="status" data-kind={trouble.kind}>
      <div className="bw-signin-text">
        <strong>{trouble.headline}</strong>
        <span>{trouble.detail}</span>
        {outcome !== '' && <span className="bw-signin-outcome">{outcome}</span>}
      </div>
      <span className="bw-spacer" />
      <button type="button" className="bw-primary" onClick={() => void hand()}>
        {stage === 'idle' ? 'Open in your browser' : 'Open again'}
      </button>
      {/* Only after the first button has been pressed. Offering to bring a
          session back before anybody has been sent to get one is offering to do
          nothing, which is the exact shape of control this review is about. */}
      {stage !== 'idle' && api.importBrowserCookies && (
        <button
          type="button"
          className="bw-text-button"
          disabled={stage === 'importing'}
          onClick={() => void bringBack()}
        >
          {stage === 'importing' ? 'Bringing it back…' : 'I have signed in — bring it back'}
        </button>
      )}
      <button type="button" className="bw-text-button" onClick={onDismiss}>
        Dismiss
      </button>
    </div>
  )
}
