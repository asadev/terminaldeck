import { useState } from 'react'
import { detectPlatform, type UiPlatform } from '../platform'
import type { AccountsApi, SignInTrouble } from './accounts-bridge'

interface Props {
  trouble: SignInTrouble
  api: AccountsApi
  /** The page it is about, which is what gets handed over. */
  url: string
  onDismiss(): void
  /**
   * Which platform to answer as. Defaults to the one this window is running on.
   *
   * A prop with a default rather than a call inside the body, which is the shape
   * `notification-check.ts`, `RemoteSection.tsx` and `PendingApproval.tsx` all
   * use for the same reason: there is no DOM in this project's test run, so a
   * component that reads `navigator` itself can only ever be tested as whatever
   * machine the suite happens to be on — and this whole file is about a
   * difference between two platforms, only one of which anybody here can run.
   */
  platform?: UiPlatform
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
 *
 * ## …and why the second one is not drawn on Windows
 *
 * The paragraph above is kept exactly as it was written, because it is true —
 * on the machine it was written on. It was written on a Mac, and every word of
 * "this app can genuinely do that" stops at the platform line: `cookie-import.ts`
 * decrypts through the **macOS login keychain**, and answers `unsupported` for
 * anything else.
 *
 * Nothing else in this band is platform-dependent, which is what made the fault
 * invisible. `diagnoseSignIn` is pure string-matching on Google's own URL, so
 * the refusal that raises this band happens identically on Windows;
 * `browser-signin:handover` is `shell.openExternal`, which works on Windows; the
 * preload wires `importBrowserCookies` with no platform gate, so the channel is
 * present. Every gate this component had was therefore satisfied on a machine
 * where the work behind the button cannot happen. A Windows user pressed
 * "Open in your browser", signed in, pressed "bring it back" and was told
 * *"Nothing came back. Make sure you finished signing in, in the same browser
 * profile"* — a sentence that blames them for a thing that was never built for
 * them.
 *
 * So the offer is **withdrawn** off macOS and a sentence takes its place. The
 * alternative — building it — was weighed and rejected in `cookie-import.ts`'s
 * header, where the argument belongs: since Chrome 127 the Windows cookie store
 * is sealed to Chrome's own executable, so the DPAPI key path everyone reaches
 * for first would unwrap a key correctly and still decrypt nothing. This is the
 * house rule applied without an exception for a feature we liked: a control that
 * cannot act is absent with its reason stated, never drawn hopefully.
 *
 * The note replaces the button from the moment the band appears rather than
 * after the first press, because the sentence above it — `trouble.detail`, from
 * `browser-signin.ts` — ends with *"then bring the signed-in session back
 * here"*. On Windows that promise is on screen whether this component says
 * anything or not, and the correction is worth less the later it arrives.
 */

/** The four states the handover moves through, in order. */
export type HandoverStage = 'idle' | 'handed' | 'importing' | 'done'

/** What belongs in the place the second button occupies. */
export type BringBack = 'button' | 'note' | 'nothing'

/**
 * Whether to offer the second half of the handover, refuse it out loud, or say
 * nothing at all.
 *
 * Pure and exported because it is the decision this component exists to make and
 * there is no DOM in this project's test run — effects do not fire and a button
 * behind a `useState` set by a click is unreachable from a static render.
 * `DevServerPanel.test.tsx` states the same rule and takes the same way out:
 * the pieces that carry the decisions are pure, so they can be checked over the
 * whole matrix rather than over whichever state a server render happens to reach.
 *
 * The order of the three checks is the argument:
 *
 *  1. **Platform first, before the channel.** A Windows build whose preload is
 *     older than its renderer has two reasons for this button to be missing, and
 *     only one of them is true for every Windows user forever. Reporting the
 *     mismatch there would be reporting the smaller, rarer fact.
 *  2. **The channel second, and silently.** An older preload is a build that was
 *     never shipped — the two halves ship together — so the honest handling is
 *     to draw nothing rather than to explain a mismatch that cannot reach a
 *     user. That is what this component already did, and it is left alone.
 *  3. **Stage last**, which is the original rule and unchanged: offering to
 *     bring a session back before anybody has been sent to get one is offering
 *     to do nothing, which is the exact shape of control this whole band is
 *     about.
 *
 * `platform !== 'mac'` and not `platform === 'windows'`: this mirrors
 * `cookieImportSupported()` in `cookie-import.ts`, which answers `darwin` and
 * nothing else, and the two have to say the same thing or the band and the
 * settings pane contradict each other. It is a copy across the process boundary
 * on purpose — the renderer cannot import from `src/main`, and `platform.ts`
 * makes that argument in full.
 */
export function bringBackOffer(
  platform: UiPlatform,
  stage: HandoverStage,
  wired: boolean,
): BringBack {
  if (platform !== 'mac') return 'note'
  if (!wired) return 'nothing'
  return stage === 'idle' ? 'nothing' : 'button'
}

/**
 * What stands in for the withdrawn button.
 *
 * One sentence, and it has to carry a reason *and* something to do — a refusal
 * that only says no leaves somebody staring at a sign-in they still need.
 *
 * Windows gets the mechanism named, briefly, because "macOS only" on its own
 * reads as an oversight somebody will report again next week, and because a
 * person who knows Chrome is holding its own cookies shut stops looking for the
 * setting that would open them.
 *
 * The tense matters and cost a rewrite. The first draft ended *"carry on in the
 * browser that just opened"*, which is false at the moment this sentence first
 * appears: the note is drawn with the band, before the button beside it has been
 * pressed and before anything has opened. So it says what is true at every
 * stage instead — that the session stays where it is signed in — and offers the
 * one thing that does work in this tab, which is a sign-in that is not Google's.
 *
 * Everything else — Linux, and the Node runtime the tests report as — gets the
 * same offer withdrawn without the Chrome clause, which would be a claim about
 * a browser store this app has not looked at there.
 */
export function bringBackNote(platform: UiPlatform): string {
  if (platform === 'windows') {
    return 'Bringing that session back into this browser works on macOS only — Chrome on Windows locks its cookies to itself — so a sign-in you finish out there stays out there. If the site also offers an email and password, use that here.'
  }
  return 'Bringing that session back into this browser works on macOS only, so a sign-in you finish out there stays out there. If the site also offers an email and password, use that here.'
}

/**
 * What to say once an import has run.
 *
 * The report carries a `message` written by the process that did the work, and
 * this component used to throw it away and read `imported` alone — so every
 * outcome that was not a success became one sentence, *"Nothing came back. Make
 * sure you finished signing in, in the same browser profile"*, whatever had
 * actually happened. That sentence is a guess, and it was wrong for most of the
 * ways an import stops: a denied keychain prompt, a cookie file macOS will not
 * open without Full Disk Access, a profile whose cookies had all expired, and a
 * platform that cannot do this at all each have their own sentence in
 * `cookie-import.ts` and each of them names something different to do.
 *
 * The guess survives only as the fallback for a main process too old to send a
 * message, where there is genuinely nothing better to say.
 *
 * "Reload the page" is appended rather than replacing the report's own sentence,
 * because it is the one instruction this side knows and the main process does
 * not: the cookies are in the session, and the page in front of the person was
 * rendered before they arrived.
 */
export function importOutcome(raw: unknown): string {
  const report = typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
  const imported = typeof report.imported === 'number' ? report.imported : 0
  const message = typeof report.message === 'string' ? report.message.trim() : ''

  if (imported > 0) {
    if (message !== '') return `${message} Reload the page.`
    return `Brought back ${imported} cookie${imported === 1 ? '' : 's'}. Reload the page.`
  }
  if (message !== '') return message
  return 'Nothing came back. Make sure you finished signing in, in the same browser profile.'
}

export function SignInBanner({ trouble, api, url, onDismiss, platform = detectPlatform() }: Props) {
  const [stage, setStage] = useState<HandoverStage>('idle')
  const [outcome, setOutcome] = useState('')

  const offer = bringBackOffer(platform, stage, typeof api.importBrowserCookies === 'function')

  const hand = async (): Promise<void> => {
    await api.browserSignInHandover?.(url)
    setStage('handed')
  }

  const bringBack = async (): Promise<void> => {
    if (!api.importBrowserCookies) return
    setStage('importing')
    const report = await api.importBrowserCookies({ domains: trouble.domains })
    setStage('done')
    setOutcome(importOutcome(report))
  }

  return (
    <div className="bw-signin" role="status" data-kind={trouble.kind}>
      <div className="bw-signin-text">
        <strong>{trouble.headline}</strong>
        <span>{trouble.detail}</span>
        {/* A plain span, styled by `.bw-signin-text span` like the detail above
            it, because this is the same register: something about the situation
            rather than the result of anything the person has done yet. */}
        {offer === 'note' && <span>{bringBackNote(platform)}</span>}
        {outcome !== '' && <span className="bw-signin-outcome">{outcome}</span>}
      </div>
      <span className="bw-spacer" />
      <button type="button" className="bw-primary" onClick={() => void hand()}>
        {stage === 'idle' ? 'Open in your browser' : 'Open again'}
      </button>
      {offer === 'button' && (
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
