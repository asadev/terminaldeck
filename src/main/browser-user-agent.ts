/**
 * What the embedded browser says it is.
 *
 * ## The measurement this file exists because of
 *
 * He reported, of the in-app browser: *"Google sign-in refuses."* Electron's
 * default user agent names itself:
 *
 *     Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36
 *     (KHTML, like Gecko) Chrome/146.0.7680.216 Electron/41.10.5 Safari/537.36
 *
 * On 2026-08-18 the same OAuth authorisation URL was loaded twice in a real
 * Electron 41.10.5 guest view, once with that string and once with the same
 * string minus the `Electron/41.10.5` token. Google answered differently:
 *
 * | user agent      | flowName            | continue path                     |
 * |-----------------|---------------------|-----------------------------------|
 * | with `Electron` | `GeneralOAuthLite`  | `/signin/oauth/legacy/consent`    |
 * | without         | `GeneralOAuthFlow`  | `/signin/oauth/consent`           |
 *
 * That is Google's embedded-browser detection firing on the token and routing
 * the sign-in down its legacy path — the path that ends in *"this browser or app
 * may not be secure"* rather than a consent screen. The identifier page loads
 * either way, which is why the failure only shows up after somebody has typed
 * their address and feels like the site breaking rather than the browser being
 * refused.
 *
 * ## Why removing the token is honest and not a disguise
 *
 * The remaining string is true in every particular. This *is* Chromium
 * 146.0.7680.216, on macOS, with the same rendering engine and the same feature
 * set — Electron ships an unmodified Chromium content module. What is dropped is
 * the packaging: `Electron/41.10.5` says which shell hosts the engine, and no
 * site has a legitimate rendering decision to make on that. Chrome itself omits
 * the analogous fact.
 *
 * Nothing else is touched. The platform, the engine version and the Chrome
 * version stay exactly as Chromium reports them, because a site that serves
 * different code to old Chrome is entitled to know which Chrome this is, and a
 * spoofed version is how a browser ends up with a rendering bug nobody can
 * reproduce.
 *
 * ## What this does not fix, said plainly
 *
 * Google's check is not only the user agent. If a flow still refuses after this,
 * the answer is not a cleverer string — it is `browser-signin.ts`, which hands
 * the sign-in to the browser the person already uses rather than pretending to
 * try. Escalating the disguise is how an app ends up in an arms race it cannot
 * win and should not be in.
 */

/** The app's own token, and Electron's, as Chromium composes them. */
const SHELL_TOKENS = /\s(?:Electron|terminaldeck|Terminal ?Deck)\/[^\s]+/gi

/**
 * The default user agent with the shell's own tokens removed.
 *
 * Idempotent, and safe on a string that never had them: a browser build that
 * one day reports no Electron token gets the same string back, which is what
 * makes it safe to apply unconditionally at session creation.
 */
export function cleanUserAgent(raw: string): string {
  // Typed as a string and checked anyway, because the one caller reads
  // `app.userAgentFallback` on the path that creates every browser tab. A throw
  // there does not produce a wrong user agent — it produces a browser panel
  // that will not open a page at all, which is a far worse failure than
  // whatever odd value provoked it.
  if (typeof raw !== 'string' || raw === '') return ''
  const stripped = raw.replace(SHELL_TOKENS, '')
  // Chromium composes the string with single spaces; removing a token in the
  // middle leaves two. Left alone it is a *different* user agent from Chrome's
  // on a byte comparison, which is exactly the kind of tell this is removing.
  const tidy = stripped.replace(/\s{2,}/g, ' ').trim()
  return tidy === '' ? raw : tidy
}

/**
 * Does this string still announce the shell?
 *
 * Exported for the test rather than for a caller: the point of the assertion is
 * that a future Electron adding a fourth token fails the suite instead of
 * quietly reintroducing the refusal.
 */
export function namesTheShell(candidate: string): boolean {
  return /\b(?:Electron|terminaldeck|Terminal ?Deck)\//i.test(candidate)
}
