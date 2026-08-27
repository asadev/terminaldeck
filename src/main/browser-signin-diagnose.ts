/**
 * Reading what Google is doing to a sign-in, off the address alone.
 *
 * ## Why this is its own file, with no imports
 *
 * `browser-signin.ts` does the same job and more, but it imports `shell` from
 * `electron` as a *value* to run the handover, which keeps the whole module out
 * of the headless closure `src/headless/seam.test.ts` walks. The diagnosis is
 * pure — a `URL` and some string matching, nothing else — and the machine's own
 * headless browser is exactly where it is now needed: when a phone drives that
 * browser and Google refuses, the host has to be able to say so without an
 * Electron under it. So the pure half lives here, imported by both
 * `browser-signin.ts` (which registers the desktop IPC) and
 * `remote/browser-control.ts` (which tells the phone). Splitting it is the only
 * way both callers get it; re-exported from `browser-signin.ts` so every
 * existing `./browser-signin` import keeps working unchanged.
 */

/* ------------------------------------------------------------ diagnosis -- */

export type SignInTroubleKind = 'refused' | 'restricted'

export interface SignInTrouble {
  kind: SignInTroubleKind
  /** One line, in the app's voice, naming what happened. */
  headline: string
  /** Two sentences at most: what it is, and what pressing the button will do. */
  detail: string
  /** The domains a handover should bring back. Never empty. */
  domains: string[]
}

/** Hosts whose sign-in behaviour this module knows something specific about. */
const GOOGLE_HOSTS = /(^|\.)(accounts\.google\.com|accounts\.youtube\.com)$/i

/**
 * What is wrong with this page, when something is.
 *
 * URL-only, and deliberately so. The alternative is reading the page's text and
 * matching English sentences, which breaks the first time somebody's browser is
 * in French and cries wolf the first time a site quotes the phrase in its own
 * help centre. Every signal below is a value Google itself puts in the address:
 *
 *  - `/signin/rejected` — the refusal page, reached after the password step.
 *    This is the *"This browser or app may not be secure. Try using a different
 *    browser"* page, matched by its path so a versioned prefix (`/v3/signin/
 *    rejected`) is caught the same as the bare one.
 *  - `error=disallowed_useragent` — the OAuth error code for the same refusal.
 *    Matched anywhere in the address, not only the top-level query: a refusal
 *    reached through an authorisation URL carries it inside the `continue=`
 *    parameter and, on some flows, in the fragment, and a check pinned to
 *    `url.search` alone would miss both and leave the band silent on the exact
 *    page he was looking at.
 *  - `flowName=GeneralOAuthLite`, or a `/legacy/consent` continuation — the
 *    restricted path an embedded browser is put on *before* it is refused.
 *    Measured on this machine; see the table in `browser-user-agent.ts`.
 *
 * The third is a warning rather than a failure on purpose. It is where the
 * sign-in is going to fail, shown while there is still time to move it
 * somewhere it will not — which is worth more than an accurate obituary.
 *
 * ## What the machine's own browser adds to this
 *
 * The desktop's embedded browser is refused for one thing — the `Electron`
 * token in its user agent, which `browser-user-agent.ts` removes. The machine's
 * *headless* Chromium, the one a phone casts, was refused for two more that no
 * string here can see from the address: `navigator.webdriver` read `true` and
 * the user agent said `HeadlessChrome`. Those are fixed at the launch
 * (`browser-chromium-launch.ts`) and in the user agent, not here — this file
 * still only reads the page Google actually served. It reads it for the phone
 * now as well as the desktop, which is the whole reason it is a file of its own.
 */
export function diagnoseSignIn(rawUrl: string): SignInTrouble | null {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }
  if (!GOOGLE_HOSTS.test(url.hostname)) return null

  // Path, query and fragment together. The refusal signal travels in different
  // parts of the address depending on how the flow reached it, and a check that
  // looked at only one of them was the gap that left the band silent.
  const whole = `${url.pathname}${url.search}${url.hash}`
  const domains = ['google.com', 'accounts.google.com', 'youtube.com']

  if (/\/signin\/rejected/i.test(url.pathname) || /disallowed_useragent/i.test(whole)) {
    return {
      kind: 'refused',
      headline: 'Google will not accept this sign-in from inside an app',
      detail:
        'Google blocks sign-ins from browsers embedded in other programs, and there is nothing this app can change to be allowed. Finish it in the browser you already use, then bring the signed-in session back here.',
      domains,
    }
  }

  if (/flowName=GeneralOAuthLite/i.test(url.search) || /\/legacy\/consent/i.test(whole)) {
    return {
      kind: 'restricted',
      headline: 'Google has put this sign-in on its restricted path',
      detail:
        'It usually still works, and it is also where Google refuses embedded browsers. If it stops after the password step, finish it in the browser you already use and bring the session back.',
      domains,
    }
  }

  return null
}

export interface Handover {
  /** The address to open outside. Always the page the person was looking at. */
  url: string
  /** Cookie domains to import once they are back. */
  domains: string[]
}

/**
 * The plan for handing one page to the system browser.
 *
 * The page's own host is always included, and it goes *first*, because that is
 * the one the import exists for. A handover that brought back only the identity
 * provider's cookies would leave somebody signed into Google and still signed
 * out of the site they were trying to reach — which looks exactly like the
 * handover not working.
 *
 * The registrable-looking parent is added too (`app.example.com` also asks for
 * `example.com`), because session cookies are routinely set one level up. That
 * is a heuristic and is stated as one: it takes the last two labels, which is
 * right for `example.com` and wrong for `example.co.uk`, where it asks for
 * `co.uk` and simply finds nothing. Asking for a domain that has no cookies
 * costs one empty query; missing the domain that has them costs the feature.
 */
export function handoverFor(rawUrl: string, extra: readonly string[] = []): Handover | null {
  let url: URL
  try {
    url = new URL(rawUrl)
  } catch {
    return null
  }
  if (url.protocol !== 'https:' && url.protocol !== 'http:') return null

  const host = url.hostname
  const labels = host.split('.')
  const parent = labels.length > 2 ? labels.slice(-2).join('.') : ''
  const domains: string[] = []
  for (const domain of [host, parent, ...extra]) {
    if (domain !== '' && !domains.includes(domain)) domains.push(domain)
  }
  return { url: url.toString(), domains }
}
