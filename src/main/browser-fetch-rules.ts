/**
 * What a page may fetch, per kind of thing — and what "cheaply" means for each.
 *
 * ## Three answers, not two
 *
 * Every request-control feature in every browser automation library offers two:
 * let it through, or abort it. Both are wrong for harvesting, and the wrong one
 * is the one everybody reaches for. `browser-placeholder.ts` carries the number
 * — 16,498 floor plans lost to *blocking images to go faster*, because blocking
 * an image stops the lazy-loader that was going to reveal the next image's URL.
 *
 * So there are three:
 *
 *  - **allow** — the ordinary thing. The request goes to the network.
 *  - **block** — the request fails, and the page is told so. Honest, fast, and
 *    it costs you every URL that would have been revealed by the load.
 *  - **fulfill** — the request is answered out of this process with something
 *    valid and empty. No byte crosses the network, the page's `onload` fires,
 *    the observer advances, and the next URL appears in the DOM where the crawl
 *    can read it.
 *
 * `fulfill` is the reason this file exists. `block` is kept because it is
 * sometimes exactly right — a tracking script, a video that would otherwise
 * stream — and because a control that only offers the clever option is a
 * control somebody works around.
 *
 * ## The document is not on the list, deliberately
 *
 * Seven kinds are addressable — image, media, font, stylesheet, script, xhr,
 * fetch — and the page's own HTML is not one of them. A rule that could block
 * or cheaply answer the document would be a rule that empties the page you came
 * to read, and there is no version of that anybody wants. Leaving it out of the
 * vocabulary is stronger than defaulting it to `allow`: `browser-cdp.ts`
 * additionally refuses an interception pattern that names `Document` at the
 * channel, so a later edit here cannot reach it either.
 *
 * ## What `fulfill` costs, per kind, stated rather than discovered
 *
 * A cheaply-answered request is a *lie to the page*, and each kind believes a
 * different thing:
 *
 *  - `image` — an actual transparent PNG at the size the page expects. The one
 *    kind where fulfilling is nearly free: layout, `naturalWidth`, `onload` and
 *    lazy-loading all behave. This is what the feature is for.
 *  - `stylesheet` — an empty sheet. The page renders unstyled. Text, links and
 *    the DOM are untouched, which is all a harvest reads, but a screenshot of
 *    that page is not what the page looks like.
 *  - `font` — an empty body. The browser gives up on the face and falls back to
 *    a system font. Visually different, structurally identical.
 *  - `media` — an empty body. A `<video>` fires `error`, not `loadedmetadata`.
 *    A player that waits for metadata before revealing anything will wait for
 *    ever; use `allow` there.
 *  - `script` — an empty script that parses and does nothing. **This is the one
 *    that will quietly ruin a scrape.** On a modern site the code that reveals
 *    the data *is* the script; fulfilling it leaves a shell. It is offered
 *    because a caller may know exactly which scripts they mean, and it is
 *    described here so nobody reaches for it as a speed-up.
 *  - `xhr` / `fetch` — an empty JSON object. Also self-defeating in the
 *    ordinary case: `browser-capture-store.ts` exists precisely because those
 *    responses are where the data is. Offered for completeness, defaulted off,
 *    and never applied by anything this app decides on its own.
 */

/* -------------------------------------------------------------- the kinds -- */

/**
 * The resource kinds a rule may name.
 *
 * Lower case, and deliberately not Chromium's spelling: these are written by a
 * model into a tool call, and `XHR` versus `xhr` versus `Xhr` is a refusal
 * nobody learns anything from. {@link cdpResourceType} does the translation at
 * the one place it is needed.
 */
export const RESOURCE_KINDS = [
  'image',
  'media',
  'font',
  'stylesheet',
  'script',
  'xhr',
  'fetch',
] as const

export type ResourceKind = (typeof RESOURCE_KINDS)[number]

export const RULE_ACTIONS = ['allow', 'block', 'fulfill'] as const

export type RuleAction = (typeof RULE_ACTIONS)[number]

/**
 * What `fulfill` used to be called, still accepted and never written.
 *
 * The word was `cheap` until 2026-08-21, and it was the odd one out on an axis:
 * `allow` and `block` name what happens to the request, `cheap` named what it
 * cost. Nobody could guess from the vocabulary that the third one is the option
 * that saves a lazy-loading page — which is why `scraping-view.ts` had to carry
 * a whole sentence explaining the difference — and `fulfill` is both the honest
 * name for it and the word every routing library already uses, so a model
 * writing a `browser.network` call reaches for the right one first.
 *
 * Read, not written: {@link readFetchRules} accepts a stored recipe or an older
 * caller that still says `cheap`, and everything this process emits — rule
 * echoes, counters, summaries — says `fulfill`.
 */
const ACTION_ALIASES: Readonly<Record<string, RuleAction>> = Object.freeze({ cheap: 'fulfill' })

/** A rule per kind. Absent means `allow`, which is what a browser does anyway. */
export type FetchRules = Partial<Record<ResourceKind, RuleAction>>

const KIND_SET = new Set<string>(RESOURCE_KINDS)
const ACTION_SET = new Set<string>(RULE_ACTIONS)

/**
 * Chromium's name for one of ours.
 *
 * Used to build the `Fetch.enable` patterns, which is the *narrowing* that
 * keeps this feature cheap: interception is armed only for the kinds a rule
 * actually names, so a page with an image rule pauses its images and nothing
 * else. Pausing everything and deciding afterwards would put every request on a
 * round trip through this process, including the document.
 */
export function cdpResourceType(kind: ResourceKind): string {
  switch (kind) {
    case 'image':
      return 'Image'
    case 'media':
      return 'Media'
    case 'font':
      return 'Font'
    case 'stylesheet':
      return 'Stylesheet'
    case 'script':
      return 'Script'
    case 'xhr':
      return 'XHR'
    case 'fetch':
      return 'Fetch'
  }
}

/**
 * One of ours for Chromium's, or null.
 *
 * Null for every type no rule can name — `Document`, `WebSocket`, `Ping`,
 * `Preflight`, `Other` and the rest. A paused request whose type lands here is
 * continued untouched, because a request this file has no opinion about must
 * not be answered by it. That branch should be unreachable while the patterns
 * narrow correctly, and it exists because "unreachable" and "cannot happen" are
 * different claims when a page is on the other end.
 */
export function kindOfResourceType(type: unknown): ResourceKind | null {
  if (typeof type !== 'string') return null
  const lower = type.toLowerCase()
  return KIND_SET.has(lower) ? (lower as ResourceKind) : null
}

/** What to do with a request of this kind. Unnamed kinds are allowed. */
export function actionFor(kind: ResourceKind | null, rules: FetchRules): RuleAction {
  if (kind === null) return 'allow'
  return rules[kind] ?? 'allow'
}

/** The kinds that need intercepting at all: everything not left alone. */
export function interceptedKinds(rules: FetchRules): ResourceKind[] {
  return RESOURCE_KINDS.filter((kind) => (rules[kind] ?? 'allow') !== 'allow')
}

/* ------------------------------------------------------------ the reading -- */

export interface ReadRules {
  rules: FetchRules
  /** Keys that are not a resource kind. The caller is told, by name. */
  unknownKinds: string[]
  /** Kinds given something that is not an action, as `kind: value`. */
  badActions: string[]
}

/**
 * Narrow a rules object off a tool call.
 *
 * Nothing is silently dropped, and `cheap` is the one word that is quietly
 * corrected rather than refused — see {@link ACTION_ALIASES}, which is the
 * whole of that mercy. A model that writes `images` for `image`, or
 * `abort` for `block`, has the shape right and one word wrong — exactly the
 * mistake `deck-control/schema.ts` was written for one layer up — and the
 * whole cost of getting it wrong here is a page that behaves normally while the
 * caller believes it is being harvested cheaply. So both mistakes come back
 * named, and `browser-network-tool.ts` refuses on either.
 */
export function readFetchRules(raw: unknown): ReadRules {
  const out: ReadRules = { rules: {}, unknownKinds: [], badActions: [] }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) return out
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    const kind = key.toLowerCase()
    if (!KIND_SET.has(kind)) {
      out.unknownKinds.push(key)
      continue
    }
    const typed = typeof value === 'string' ? value.toLowerCase() : ''
    const action = ACTION_ALIASES[typed] ?? typed
    if (!ACTION_SET.has(action)) {
      out.badActions.push(`${key}: ${typeof value === 'string' ? value : typeof value}`)
      continue
    }
    out.rules[kind as ResourceKind] = action as RuleAction
  }
  return out
}

/** `image: fulfill, script: block` — for a summary line and the action log. */
export function describeRules(rules: FetchRules): string {
  const parts = RESOURCE_KINDS.filter((kind) => rules[kind] !== undefined).map(
    (kind) => `${kind}: ${rules[kind]}`,
  )
  return parts.length === 0 ? 'none' : parts.join(', ')
}

/* --------------------------------------------------------- the cheap body -- */

export interface CheapBody {
  mimeType: string
  body: Buffer
}

/**
 * What a cheaply-answered request of this kind is handed, images aside.
 *
 * Images are not here: they are built per request at the size the page expects,
 * by `browser-placeholder.ts`, which is the whole point of the feature. What is
 * here is the valid-and-empty answer for everything else, chosen so the page's
 * parser succeeds rather than logging an error that some sites treat as fatal.
 */
export function cheapBodyFor(kind: ResourceKind): CheapBody {
  switch (kind) {
    case 'stylesheet':
      // A comment rather than nothing, so a sheet is a sheet. Zero-length
      // bodies are served by broken origins often enough that some frameworks
      // treat one as a failed load and retry it.
      return { mimeType: 'text/css', body: Buffer.from('/* answered cheaply */\n', 'utf8') }
    case 'script':
      return {
        mimeType: 'text/javascript',
        body: Buffer.from('/* answered cheaply */\n', 'utf8'),
      }
    case 'xhr':
    case 'fetch':
      return { mimeType: 'application/json', body: Buffer.from('{}', 'utf8') }
    case 'font':
      // Genuinely empty. There is no such thing as a valid empty font, so the
      // face fails to decode and the browser falls back — which is the intended
      // outcome and the cheapest way to reach it.
      return { mimeType: 'font/woff2', body: Buffer.alloc(0) }
    case 'media':
      return { mimeType: 'application/octet-stream', body: Buffer.alloc(0) }
    case 'image':
      // Unreachable — the caller builds a sized placeholder instead — and a
      // correct answer rather than a throw, because an interception handler
      // that throws is a page that hangs.
      return { mimeType: 'image/png', body: Buffer.alloc(0) }
  }
}

/**
 * Response headers a cheap answer may carry, and the reason the list is short.
 *
 * `browser-cdp.ts` refuses anything outside this set at the channel — a
 * fulfilled response is a response *this app writes into the page's session*,
 * so `set-cookie` on one would be the app minting a cookie in his logged-in
 * profile, and `location` would be it redirecting him somewhere. Neither is a
 * thing "answer an image cheaply" needs, so neither is a thing it may do.
 *
 * `access-control-allow-origin` is here because a cheaply-answered `fetch()`
 * across origins is checked by CORS like any other response, and one refused by
 * CORS is indistinguishable to the page from a network failure.
 */
export function cheapHeaders(mimeType: string, bytes: number): { name: string; value: string }[] {
  return [
    { name: 'content-type', value: mimeType },
    { name: 'content-length', value: String(bytes) },
    // Never let a cheap answer become the cached answer. A placeholder written
    // into the HTTP cache would still be there on the run that wanted the real
    // image, and that is 62,000 previews all over again in a new disguise.
    { name: 'cache-control', value: 'no-store' },
    { name: 'access-control-allow-origin', value: '*' },
  ]
}
