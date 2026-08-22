import { appendFileSync, existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import type { DriveState } from './browser-cdp'

/**
 * Photographing the page that said no, at the moment it said it.
 *
 * ## The sentence this is built from
 *
 * > *"You cannot debug a block page you didn't capture."*
 *
 * A run that hits a challenge, a rate limit or a redirect to a sign-in wall
 * usually finds out hours later, from a folder of files that are all 4KB of
 * HTML. By then the page is gone: the challenge has rotated, the cookie has
 * changed, the URL redirects somewhere else, and the only evidence left is a
 * count. The screenshot has to be taken *while it is on the screen*, by the
 * thing that is already looking at it, without anybody asking for it — because
 * nobody is there to ask.
 *
 * ## What counts as a block, and why each signal is here
 *
 * Only evidence the browser already has. Nothing here fetches anything, and
 * nothing here reasons about a site.
 *
 *  - **The status code.** `401`, `403`, `407`, `429`, `451`, `503`. Each is a
 *    server saying no in a different dialect. `503` is on the list because a
 *    front-door that decides you are a robot answers `503` far more often than
 *    it is genuinely out of capacity, and the two are indistinguishable from
 *    here — a picture of one costs nothing and a missing picture of the other
 *    costs the run.
 *  - **A failed navigation.** `did-fail-load` with a real error code: the page
 *    never arrived, and what is on screen is Chromium's own error page.
 *  - **Infrastructure in the URL.** Challenge platforms put their own paths in
 *    the address bar while they hold you. These are *product* markers, not a
 *    site's wording, which is why they can be defaulted: they are the same
 *    string on every site behind that product. The list is still replaceable.
 *  - **The document said so.** A short list of generic verification phrases,
 *    replaceable, and only consulted when the page is small — a challenge page
 *    is a few hundred bytes of text and an article that happens to discuss
 *    verifying humans is not.
 *  - **The navigation ended somewhere else.** A request for a listing page that
 *    finished on a different registrable domain is a sign-in wall or a consent
 *    gate, and it is the one signal that fires on a perfectly ordinary `200`.
 *
 * Every signal that fired is named in {@link BlockVerdict.signals}. That is not
 * decoration either: this thing will sometimes be wrong, and a false positive
 * that says *which rule* fired can be switched off in a sentence, where one that
 * just says `blocked: true` gets the whole feature turned off.
 *
 * ## The one thing it will not do
 *
 * It will not photograph a page while the person has the baton. `browser-cdp.ts`
 * shuts the agent out of **reads as well as writes** during a handover, for the
 * stated reason that a screenshot taken while somebody is typing a password is
 * the leak and you cannot redact what was never produced. An automatic capture
 * that ignored that would be a hole in the guarantee that is *harder* to see
 * than the one it replaced, because nobody asked for the picture. So
 * {@link attachBlockWatch} checks the baton on every event and does nothing
 * unless it says `agent`.
 *
 * And a sign-in wall is exactly the page a person is most likely to be handed.
 * The evidence is still written down when the picture cannot be taken — see
 * {@link BlockShot.note} — so the block is recorded, with the reason there is no
 * image beside it, rather than the whole event disappearing.
 *
 * ## The switch
 *
 * {@link BlockWatchDeps.enabled} is the Scraping panel's *"Screenshot the page
 * when a request is blocked"*, and it is the only way to stop this. Absent means
 * on, which is what every install has had; `browser-block-capture.ts` holds the
 * answer per profile and says why the default cannot be the other one.
 */

/* --------------------------------------------------------------- evidence -- */

export interface BlockEvidence {
  /** Where the navigation was aimed. */
  requestedUrl: string
  /** Where it actually ended up. */
  finalUrl: string
  /** `0` when Chromium did not report one — an in-page navigation, a failure. */
  httpStatus: number
  statusText: string
  title: string
  /** A bounded sample of the document's own text. Empty when it could not be read. */
  text: string
  /** Set when the navigation failed outright. */
  failed: { code: number; description: string } | null
}

export interface BlockRules {
  statuses: readonly number[]
  /** Case-insensitive substrings of the URL. */
  urlMarkers: readonly string[]
  /** Case-insensitive substrings of the document text. */
  bodyMarkers: readonly string[]
  /**
   * Above this many characters of text, {@link BlockRules.bodyMarkers} are not
   * consulted. A challenge page is short; a long page containing the words is a
   * page about challenges.
   */
  bodyMarkerMaxChars: number
  /** Treat ending on a different registrable domain as a block. */
  offSiteRedirect: boolean
}

/**
 * The defaults.
 *
 * The URL markers are the paths those products serve their own interstitials
 * from; they are the same on every site that uses them, which is what makes them
 * defaultable at all. The body markers are the plainest English a challenge
 * writes; they are the weakest signal here, which is why they are gated on
 * length and why every one of them is replaceable.
 */
export const DEFAULT_BLOCK_RULES: BlockRules = Object.freeze({
  statuses: Object.freeze([401, 403, 407, 429, 451, 503]),
  urlMarkers: Object.freeze([
    '/cdn-cgi/challenge-platform/',
    '__cf_chl',
    'challenges.cloudflare.com',
    '/_incapsula_resource',
    '/_sec/cp_challenge',
    'geo.captcha-delivery.com',
    '/px/captcha',
    '/distil_r_captcha',
    '/recaptcha/api2/',
  ]),
  bodyMarkers: Object.freeze([
    'verify you are human',
    'are you a robot',
    'unusual traffic',
    'rate limit exceeded',
    'access denied',
    'checking your browser',
    'enable javascript and cookies to continue',
  ]),
  bodyMarkerMaxChars: 2_000,
  offSiteRedirect: false,
})

export interface BlockVerdict {
  blocked: boolean
  /** Every rule that fired, named. Empty when nothing did. */
  signals: string[]
  /** One line. Empty when nothing fired. */
  reason: string
}

/**
 * The registrable-ish domain of a URL: the last two labels.
 *
 * Deliberately crude, and the crudeness is safe in the direction that matters.
 * There is no public-suffix list in this process, so `a.co.uk` and `b.co.uk`
 * both read as `co.uk` and a redirect between them looks same-site — a *missed*
 * signal, which costs a screenshot. Getting it wrong the other way would fire on
 * every ordinary CDN hop, and a signal that fires constantly is one somebody
 * switches off.
 */
export function siteOf(url: string): string {
  try {
    const host = new URL(url).hostname.toLowerCase()
    const labels = host.split('.')
    return labels.length <= 2 ? host : labels.slice(-2).join('.')
  } catch {
    return ''
  }
}

/** Is this page refusing us? Pure, over evidence the browser already had. */
export function classifyBlock(
  evidence: BlockEvidence,
  rules: BlockRules = DEFAULT_BLOCK_RULES,
): BlockVerdict {
  const signals: string[] = []

  if (evidence.failed !== null && evidence.failed.code !== 0) {
    signals.push(`the navigation failed: ${evidence.failed.description || evidence.failed.code}`)
  }
  if (evidence.httpStatus > 0 && rules.statuses.includes(evidence.httpStatus)) {
    signals.push(`HTTP ${evidence.httpStatus}${evidence.statusText === '' ? '' : ` ${evidence.statusText}`}`)
  }
  const url = `${evidence.finalUrl} ${evidence.requestedUrl}`.toLowerCase()
  for (const marker of rules.urlMarkers) {
    if (marker !== '' && url.includes(marker.toLowerCase())) {
      signals.push(`the address contains ${marker}`)
    }
  }
  const body = evidence.text.toLowerCase()
  if (body !== '' && body.length <= rules.bodyMarkerMaxChars) {
    for (const marker of rules.bodyMarkers) {
      if (marker !== '' && body.includes(marker.toLowerCase())) {
        signals.push(`the page says "${marker}"`)
      }
    }
  }
  if (rules.offSiteRedirect && evidence.requestedUrl !== '' && evidence.finalUrl !== '') {
    const from = siteOf(evidence.requestedUrl)
    const to = siteOf(evidence.finalUrl)
    if (from !== '' && to !== '' && from !== to) {
      signals.push(`the navigation ended on ${to} rather than ${from}`)
    }
  }

  return {
    blocked: signals.length > 0,
    signals,
    reason: signals.length === 0 ? '' : signals.join('; '),
  }
}

/* ---------------------------------------------------------- the capture -- */

export interface BlockShot {
  at: number
  /** The PNG. Empty when a picture could not be taken — see {@link note}. */
  path: string
  /** The evidence, as JSON, beside the picture. Always written. */
  sidecar: string
  evidence: BlockEvidence
  verdict: BlockVerdict
  /** Why there is no picture. Empty when there is one. */
  note: string
}

/** Every block this install has caught, newest last. One line each. */
export function blockLogPath(dir: string): string {
  return join(dir, 'blocks.jsonl')
}

function stamp(at: number, url: string): string {
  const when = new Date(at).toISOString().replace(/[:.]/g, '-')
  let host = ''
  try {
    host = new URL(url).hostname.replace(/[^A-Za-z0-9.-]/g, '')
  } catch {
    host = ''
  }
  return `block-${when}${host === '' ? '' : `-${host}`}`
}

/**
 * Write a block down, with its picture when there is one.
 *
 * The sidecar is written **before** anything can go wrong with the image, and
 * the return value is produced whether or not the image happened. That ordering
 * is the whole reliability argument: a capture that only existed when the
 * screenshot worked would go missing in exactly the conditions that produce
 * blocks — a page mid-navigation, a window that is not composited, a renderer
 * that has already gone.
 */
export async function captureBlock(input: {
  evidence: BlockEvidence
  verdict: BlockVerdict
  dir: string
  /** Masked PNG bytes, or `null` when no picture could be taken. */
  shot: () => Promise<Buffer | null>
  now?: number
}): Promise<BlockShot> {
  const at = input.now ?? Date.now()
  const base = stamp(at, input.evidence.finalUrl || input.evidence.requestedUrl)
  const sidecar = join(input.dir, `${base}.json`)
  const picture = join(input.dir, `${base}.png`)

  let path = ''
  let note = ''
  try {
    mkdirSync(input.dir, { recursive: true })
  } catch (error) {
    note = `the folder for block evidence could not be made: ${
      error instanceof Error ? error.message : 'unknown reason'
    }`
  }

  if (note === '') {
    try {
      const png = await input.shot()
      if (png === null || png.length === 0) {
        note = 'no picture could be taken of this page'
      } else {
        writeFileSync(picture, png)
        path = picture
      }
    } catch (error) {
      note = `the page could not be photographed: ${
        error instanceof Error ? error.message : 'unknown reason'
      }`
    }
  }

  const shot: BlockShot = { at, path, sidecar, evidence: input.evidence, verdict: input.verdict, note }
  try {
    writeFileSync(sidecar, `${JSON.stringify(shot, null, 2)}\n`)
    appendFileSync(blockLogPath(input.dir), `${JSON.stringify(shot)}\n`)
  } catch {
    /*
     * The evidence would not write.
     *
     * Not thrown: this runs off a navigation event, in the middle of somebody
     * else's page load, and an exception here would surface as a broken browser
     * rather than as a missing file. The returned {@link BlockShot} still
     * describes what happened, and the caller's `onCapture` still hears it.
     */
  }
  return shot
}

/** Every block written down in one folder, oldest first. */
export function readBlocks(dir: string): BlockShot[] {
  const path = blockLogPath(dir)
  if (!existsSync(path)) return []
  let text: string
  try {
    text = readFileSync(path, 'utf8')
  } catch {
    return []
  }
  const shots: BlockShot[] = []
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (trimmed === '') continue
    try {
      const parsed = JSON.parse(trimmed) as BlockShot
      if (typeof parsed === 'object' && parsed !== null && typeof parsed.at === 'number') {
        shots.push(parsed)
      }
    } catch {
      // One line, not the log.
    }
  }
  return shots
}

/**
 * Every block written down anywhere under a root, oldest first.
 *
 * The root itself **and** one level of folders beneath it, because the evidence
 * is filed per profile (`blockShotDirFor`) and `assets.blocks` is asked one
 * question about one browser: *what refused us?* A reader that only looked in
 * the folder it was handed would answer that question with an empty list on
 * every install, which is the failure this whole path exists to prevent — and it
 * would do it silently, because an empty list is what "nothing was blocked"
 * looks like too.
 *
 * The root is read as well as the children, and not for symmetry: installs that
 * photographed blocks before the folder was split by profile wrote their rows
 * there, and dropping them would delete evidence by reorganising a directory.
 *
 * One level, not a walk. Nothing this app writes puts a `blocks.jsonl` deeper
 * than that, and a recursive scan of a folder full of PNGs is a cost paid on
 * every call to find files that are never there.
 */
export function readBlocksUnder(root: string): BlockShot[] {
  const shots = readBlocks(root)
  let entries: { name: string; isDirectory(): boolean }[] = []
  try {
    entries = readdirSync(root, { withFileTypes: true })
  } catch {
    // No root at all is the ordinary state of an install that has never been
    // refused by anything.
    return shots
  }
  for (const entry of entries) {
    if (!entry.isDirectory()) continue
    shots.push(...readBlocks(join(root, entry.name)))
  }
  return shots.sort((left, right) => left.at - right.at)
}

/* ----------------------------------------------------------- the watcher -- */

/**
 * The little of a `WebContents` this needs.
 *
 * Structural rather than Electron's own type so the watcher can be driven by a
 * plain `EventEmitter` in a test — which is the only way to assert what it does
 * with a `429`, since a real one would need a real server refusing a real page.
 */
export interface BlockWatchTarget {
  on(event: string, listener: (...args: never[]) => void): unknown
  getURL(): string
  getTitle(): string
}

export interface BlockWatchDeps {
  /**
   * Who holds the page. Nothing is read or photographed unless this is `agent`.
   * See the header: this is the password guarantee, not a preference.
   */
  state(): DriveState
  /** Where the pictures and the sidecars go. */
  dir(): string
  /**
   * Is the camera on for this page?
   *
   * Asked on every settled navigation rather than read once at attach time,
   * because the switch is per profile and a page outlives the moment somebody
   * clicked it — turning it off stops the next picture instead of the next
   * page. Absent means on: a caller that has no opinion gets the behaviour
   * this had before there was a switch, which is the right default — by the
   * time an agent has noticed it was blocked the challenge has rotated and the
   * picture is of something else, so the only useful moment to take one is a
   * moment nobody asked for. See `browser-block-capture.ts` for why the
   * default cannot be off. It is a switch at all because the Scraping panel
   * offers one, and a control that stores a preference nothing reads is a
   * control that looks like it works and does not.
   */
  enabled?(): boolean
  /** A bounded sample of the document's text, or `null` when it cannot be read. */
  text(): Promise<string | null>
  /** A masked PNG of the page, or `null`. */
  shot(): Promise<Buffer | null>
  rules?(): BlockRules
  now?(): number
  /** Told about every capture, so something can say it happened. */
  onCapture?(shot: BlockShot): void
}

/**
 * How long the same address is not photographed twice.
 *
 * A blocked page reloads itself — challenge platforms do it on a timer — and a
 * run that retries produces the same refusal every few seconds. One picture of
 * it is evidence; two hundred is a full disk.
 */
export const BLOCK_SHOT_COOLDOWN_MS = 60_000

/**
 * Watch one page's navigations and capture the ones that were refused.
 *
 * The three events are not interchangeable and all three are needed:
 *
 *  - `did-navigate` is the **only** place the HTTP status is available. It fires
 *    before the document exists, so the status is remembered rather than acted
 *    on.
 *  - `did-fail-load` is the navigation that never arrived.
 *  - `did-stop-loading` is the point at which the document can be read, and it
 *    fires after either of the other two. The judgement is made here, once, with
 *    everything in hand.
 *
 * `did-navigate-in-page` is deliberately ignored: a fragment change is not a
 * server saying anything.
 */
export function attachBlockWatch(wc: BlockWatchTarget, deps: BlockWatchDeps): void {
  const now = deps.now ?? Date.now
  let pending: { requestedUrl: string; httpStatus: number; statusText: string } | null = null
  let failure: { code: number; description: string } | null = null
  const lastShot = new Map<string, number>()

  wc.on('did-navigate', ((
    _event: unknown,
    url: string,
    httpResponseCode?: number,
    httpStatusText?: string,
  ) => {
    pending = {
      requestedUrl: typeof url === 'string' ? url : '',
      httpStatus: typeof httpResponseCode === 'number' ? httpResponseCode : 0,
      statusText: typeof httpStatusText === 'string' ? httpStatusText : '',
    }
    failure = null
  }) as (...args: never[]) => void)

  wc.on('did-fail-load', ((
    _event: unknown,
    errorCode: number,
    errorDescription: string,
    validatedURL: string,
    isMainFrame?: boolean,
  ) => {
    // A subframe that failed is an advert, not a block. Chromium reports
    // `isMainFrame` as `undefined` on some paths, which is treated as the main
    // frame — a needless screenshot is cheaper than a missed one.
    if (isMainFrame === false) return
    /*
     * `-3` is `ERR_ABORTED`, which is what every navigation that was replaced by
     * another one reports. Treating it as a failure would photograph an
     * ordinary redirect chain.
     */
    if (errorCode === -3 || errorCode === 0) return
    failure = {
      code: typeof errorCode === 'number' ? errorCode : 0,
      description: typeof errorDescription === 'string' ? errorDescription : '',
    }
    if (pending === null) {
      pending = {
        requestedUrl: typeof validatedURL === 'string' ? validatedURL : '',
        httpStatus: 0,
        statusText: '',
      }
    }
  }) as (...args: never[]) => void)

  wc.on('did-stop-loading', (() => {
    const held = pending
    const failed = failure
    pending = null
    failure = null
    if (held === null && failed === null) return
    void settle(held, failed)
  }) as (...args: never[]) => void)

  async function settle(
    held: { requestedUrl: string; httpStatus: number; statusText: string } | null,
    failed: { code: number; description: string } | null,
  ): Promise<void> {
    // The baton. Checked here rather than at the top of the listener because the
    // person can take the page between the navigation starting and it settling,
    // and this is the last moment before anything is read.
    if (deps.state() !== 'agent') return
    /*
     * And the profile's own switch, asked at the same moment and for the same
     * reason: it can be turned off between the navigation and the settle.
     * Checked before anything is read, so that "off" costs nothing at all —
     * no text read, no URL, no classification. A switch that still ran the
     * whole machine and threw the answer away would be off in name and on in
     * every measurable way, and the first person to profile a page load would
     * find it.
     */
    if (deps.enabled?.() === false) return

    let finalUrl = ''
    let title = ''
    try {
      finalUrl = wc.getURL()
      title = wc.getTitle()
    } catch {
      // The view has gone. Nothing to photograph and nothing to say about it.
      return
    }

    const rules = deps.rules?.() ?? DEFAULT_BLOCK_RULES
    const at = now()

    /*
     * The text is read on every settled navigation, and it is the only
     * unconditional cost this watcher adds.
     *
     * It cannot be made conditional on the cheap signals without giving up the
     * case that matters most: a challenge page answers `200`, from the site's
     * own domain, at an address with nothing unusual in it. The read is bounded
     * inside the page by `TEXT_SCRIPT`'s own limit, so what crosses the boundary
     * is a couple of kilobytes whatever the document is.
     */
    const text = await deps.text().catch(() => null)

    const evidence: BlockEvidence = {
      requestedUrl: held?.requestedUrl ?? '',
      finalUrl,
      httpStatus: held?.httpStatus ?? 0,
      statusText: held?.statusText ?? '',
      title,
      text: text ?? '',
      failed,
    }
    const verdict = classifyBlock(evidence, rules)
    if (!verdict.blocked) return

    /*
     * `has`, not `?? 0`.
     *
     * A missing entry means *never photographed*, and defaulting it to zero says
     * *photographed at the epoch* — which is inside the cooldown for any clock
     * that does not start in 1970, so the very first picture of a block would be
     * skipped. It only showed up under a test clock, which is the point of
     * having one.
     */
    const key = finalUrl || evidence.requestedUrl
    const last = lastShot.get(key)
    if (last !== undefined && at - last < BLOCK_SHOT_COOLDOWN_MS) return
    lastShot.set(key, at)

    const shot = await captureBlock({
      evidence,
      verdict,
      dir: deps.dir(),
      shot: deps.shot,
      now: at,
    })
    deps.onCapture?.(shot)
  }
}
