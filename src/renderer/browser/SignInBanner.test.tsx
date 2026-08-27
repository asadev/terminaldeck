import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import type { UiPlatform } from '../platform'
import { readSignInTrouble, type AccountsApi, type SignInTrouble } from './accounts-bridge'
import {
  SignInBanner,
  bringBackNote,
  bringBackOffer,
  importOutcome,
  type HandoverStage,
} from './SignInBanner'

/**
 * One question: does this band ever offer a Windows user a button that cannot
 * do anything?
 *
 * It used to. Nothing in the path that raises the band is platform-dependent —
 * Google refuses embedded browsers by user agent, the handover is
 * `shell.openExternal`, and the preload wires the cookie-import channel with no
 * platform gate — so every gate this component had was satisfied on a machine
 * where the work behind the second button is not implemented and, per
 * `cookie-import.ts`, cannot be. A Windows user pressed it and was told
 * *"Nothing came back. Make sure you finished signing in, in the same browser
 * profile"*: blamed for a feature that was never built for them.
 *
 * ## Every platform here is forced, never measured
 *
 * The machine this suite runs on is a Mac, and `detectPlatform()` reads
 * `navigator` — which under Node answers `Node.js/22`, i.e. `'other'`. A test
 * that let the component find its own platform would therefore be checking one
 * arbitrary third answer and nothing about either shipping platform. So the
 * platform is passed in at every call site below, which is the shape
 * `notification-check.ts`, `RemoteSection.tsx` and `MachineLinks.test.tsx`
 * already use, and the mac and windows answers are pinned side by side.
 *
 * ## Why the decision is checked as a function and the drawing as markup
 *
 * There is no DOM in this project's test run, so effects do not fire and a
 * button that only appears after a click on another button is unreachable from
 * a static render — `DevServerPanel.test.tsx` states the same limit and takes
 * the same way out. {@link bringBackOffer} is therefore where the whole matrix
 * is checked, including the states a render cannot reach, and the markup cases
 * check that the component actually asks it: on Windows the sentence is drawn
 * and the button's own words appear nowhere in the output, at the one stage a
 * server render can produce.
 */

const TROUBLE: SignInTrouble = {
  kind: 'refused',
  headline: 'Google will not accept this sign-in from inside an app',
  // The real sentence from `browser-signin.ts`, kept verbatim because its tail
  // is half of why the correction has to be visible immediately: it promises
  // the round trip on every platform.
  detail:
    'Google blocks sign-ins from browsers embedded in other programs, and there is nothing this app can change to be allowed. Finish it in the browser you already use, then bring the signed-in session back here.',
  domains: ['google.com', 'accounts.google.com', 'youtube.com'],
}

/** A preload that wired everything, which is what every shipped build is. */
const WIRED: AccountsApi = {
  browserSignInHandover: async () => null,
  importBrowserCookies: async () => ({ imported: 0, message: '' }),
}

const STAGES: HandoverStage[] = ['idle', 'handed', 'importing', 'done']

function markup(platform: UiPlatform, api: AccountsApi = WIRED): string {
  return renderToStaticMarkup(
    <SignInBanner
      trouble={TROUBLE}
      api={api}
      url="https://accounts.google.com/signin/rejected"
      onDismiss={() => {}}
      platform={platform}
    />,
  )
}

describe('the second button is never offered where the import cannot run', () => {
  it('is withdrawn on Windows at every stage, wired or not', () => {
    for (const stage of STAGES) {
      for (const wired of [true, false]) {
        expect(bringBackOffer('windows', stage, wired), `${stage}/${wired}`).toBe('note')
      }
    }
  })

  it('is withdrawn on every platform that is not macOS', () => {
    // `'other'` is Linux and it is also what Node answers, so this is the case
    // that would have been silently checked instead of Windows if the platform
    // were read rather than passed. It gets a real answer rather than a
    // fallback: there is no Linux build target and no Linux key path.
    for (const stage of STAGES) {
      expect(bringBackOffer('other', stage, true), stage).toBe('note')
    }
  })

  it('is offered on macOS, but only after somebody has been sent to sign in', () => {
    // The original rule, unchanged: offering to bring a session back before
    // anybody has been sent to get one is offering to do nothing.
    expect(bringBackOffer('mac', 'idle', true)).toBe('nothing')
    for (const stage of ['handed', 'importing', 'done'] as const) {
      expect(bringBackOffer('mac', stage, true), stage).toBe('button')
    }
  })

  it('draws nothing at all on macOS when the preload predates the channel', () => {
    /*
     * Silence rather than a sentence, and the asymmetry with Windows is
     * deliberate. A renderer newer than its preload is a build that was never
     * shipped — the two halves ship in one file — so explaining it would be
     * explaining a state no user can reach. Windows is the opposite: true for
     * every Windows user, forever, until Chrome unwinds app-bound encryption.
     */
    for (const stage of STAGES) {
      expect(bringBackOffer('mac', stage, false), stage).toBe('nothing')
    }
  })
})

describe('what stands in for the withdrawn button', () => {
  it('names Windows’ own reason, so nobody goes looking for a setting', () => {
    const note = bringBackNote('windows')
    expect(note).toMatch(/macOS only/)
    expect(note).toMatch(/Chrome on Windows/)
    // A refusal that only says no leaves somebody staring at a sign-in they
    // still need, so it has to end in something they can do — and in something
    // that is true at the moment it is drawn, which is before the button beside
    // it has been pressed and before any other browser has opened.
    expect(note).toMatch(/email and password/)
    expect(note).not.toMatch(/just opened/)
  })

  it('claims nothing about Chrome on a platform this app has not looked at', () => {
    // Linux, and the Node runtime the tests report as. The offer is still
    // withdrawn — there is no key path — but the Chrome clause would be a
    // statement about a store nothing here has inspected there.
    const note = bringBackNote('other')
    expect(note).toMatch(/macOS only/)
    expect(note).not.toMatch(/Chrome/)
  })
})

describe('the band as it is actually drawn', () => {
  it('shows a Windows user the reason instead of the button', () => {
    const html = markup('windows')
    expect(html).toContain('macOS only')
    expect(html).toContain('Chrome on Windows')
    // The exact words of the control that used to be drawn hopefully. Their
    // absence is the whole fix.
    expect(html).not.toContain('bring it back')
    expect(html).not.toContain('Bringing it back')
  })

  it('still offers the half of the handover that does work on Windows', () => {
    // Withdrawing the round trip must not withdraw the hand-off. Opening the
    // page in the user's own browser is `shell.openExternal`, which works
    // there, and it is the only way past Google's refusal on any platform.
    const html = markup('windows')
    expect(html).toContain('Open in your browser')
    expect(html).toContain('Dismiss')
  })

  it('says none of it on macOS, where the offer is real', () => {
    const html = markup('mac')
    // No note: on a Mac the promise in `trouble.detail` is kept, so a sentence
    // walking it back would be the wrong correction.
    expect(html).not.toContain('macOS only')
    // And no button yet either, at the stage a server render can reach — the
    // stage gate is checked over its whole range in `bringBackOffer` above.
    expect(html).not.toContain('bring it back')
  })

  it('corrects the promise the sentence above it makes', () => {
    /*
     * `trouble.detail` comes from `browser-signin.ts` and ends *"then bring the
     * signed-in session back here"* on every platform. That copy is not this
     * file's to change, and on Windows it is on screen whether this component
     * says anything or not — so the correction is drawn from the moment the
     * band appears rather than after the first press, and it has to sit in the
     * same block of text as the promise it contradicts.
     */
    const html = markup('windows')
    expect(html).toContain('bring the signed-in session back here')
    const promise = html.indexOf('bring the signed-in session back here')
    const correction = html.indexOf('macOS only')
    expect(correction).toBeGreaterThan(promise)
  })
})

describe('the refusal decodes across the process boundary with its copy intact', () => {
  /*
   * The exact object `diagnoseSignIn` emits for Google's *"this browser or app
   * may not be secure"* page, kept in step with `browser-signin-diagnose.ts` the
   * same way `TROUBLE` above is — the renderer cannot import from `src/main`, so
   * the shape is copied and pinned rather than reached across the boundary.
   */
  const RAW_REFUSED = {
    kind: 'refused',
    headline: 'Google will not accept this sign-in from inside an app',
    detail:
      'Google blocks sign-ins from browsers embedded in other programs, and there is nothing this app can change to be allowed. Finish it in the browser you already use, then bring the signed-in session back here.',
    domains: ['google.com', 'accounts.google.com', 'youtube.com'],
  }

  it('reads the refusal back as a refusal, copy and domains carried through', () => {
    const trouble = readSignInTrouble(RAW_REFUSED)
    expect(trouble?.kind).toBe('refused')
    expect(trouble?.headline).toBe('Google will not accept this sign-in from inside an app')
    expect(trouble?.detail).toContain('nothing this app can change to be allowed')
    expect(trouble?.domains).toContain('accounts.google.com')
  })

  it('reads nothing as trouble unless it truly is one', () => {
    expect(readSignInTrouble(null)).toBeNull()
    expect(readSignInTrouble('signin/rejected')).toBeNull()
    expect(readSignInTrouble({ kind: 'made-up' })).toBeNull()
    // The right kind but no sentence to show is not a usable trouble.
    expect(readSignInTrouble({ kind: 'refused' })).toBeNull()
  })

  it('draws the refusal’s own headline and detail, and the one control that gets past it', () => {
    const html = markup('mac')
    expect(html).toContain('Google will not accept this sign-in from inside an app')
    expect(html).toContain('there is nothing this app can change to be allowed')
    // `shell.openExternal`, the only way past Google's refusal on any platform.
    expect(html).toContain('Open in your browser')
  })
})

describe('what the band says once an import has run', () => {
  it('shows the report’s own sentence rather than a guess about the profile', () => {
    /*
     * The old code read `imported` and threw the message away, so every
     * non-success became *"Nothing came back. Make sure you finished signing
     * in, in the same browser profile"* — advice that is wrong for a denied
     * keychain prompt, wrong for a cookie file macOS will not open, and wrong
     * for a profile whose cookies had all expired. Each of those has its own
     * sentence in `cookie-import.ts`, and each names something different to do.
     */
    const denied =
      'The keychain request was denied, so Chrome’s cookies stayed encrypted. Nothing was imported.'
    expect(importOutcome({ imported: 0, message: denied })).toBe(denied)
    expect(importOutcome({ imported: 0, message: denied })).not.toMatch(/same browser profile/)
  })

  it('keeps the guess only for a main process too old to send a message', () => {
    expect(importOutcome({ imported: 0 })).toMatch(/same browser profile/)
    // Not an object at all — an older channel answering `null`, or a throw
    // turned into a rejection value. Still a sentence, never a crash in render.
    expect(importOutcome(null)).toMatch(/same browser profile/)
    expect(importOutcome('nonsense')).toMatch(/same browser profile/)
  })

  it('adds the one instruction the main process cannot know about', () => {
    // The cookies are in the session; the page in front of the person was
    // rendered before they arrived. Nothing in `cookie-import.ts` knows that.
    const done = 'Imported 12 cookies across 2 sites from Chrome.'
    expect(importOutcome({ imported: 12, message: done })).toBe(`${done} Reload the page.`)
    expect(importOutcome({ imported: 1 })).toBe('Brought back 1 cookie. Reload the page.')
    expect(importOutcome({ imported: 2 })).toBe('Brought back 2 cookies. Reload the page.')
  })
})
