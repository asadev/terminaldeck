import { readSizeHint, type SizeHint, type SizeSource } from './browser-capture-script'
import { keptHeaders, type CaptureStore, type CaptureSummary } from './browser-capture-store'
import {
  actionFor,
  cdpResourceType,
  cheapBodyFor,
  cheapHeaders,
  interceptedKinds,
  kindOfResourceType,
  type FetchRules,
  type ResourceKind,
} from './browser-fetch-rules'
import { placeholderPng } from './browser-placeholder'

/**
 * One page's network, armed: what it may fetch, and what it fetched.
 *
 * ## What this is and what it deliberately is not
 *
 * It is not a crawler. Asad was explicit about the seam — *"Don't build a full
 * scraping framework inside a terminal app. The browser should expose these
 * capabilities cleanly; the orchestration can live outside."* — so there is no
 * queue here, no frontier, no politeness delay and no retry policy. There is
 * one page, two capabilities attached to it, and a set of counts honest enough
 * that whatever is orchestrating from outside can decide what to do next.
 *
 * The two capabilities are the two halves of the same failure:
 *
 *  - **Request control** (`browser-fetch-rules.ts`) so that going faster does
 *    not mean going blind. 16,498 floor plans were lost to images being
 *    blocked, because a blocked image is a lazy-loader that never advances.
 *  - **Passive capture** (`browser-capture-store.ts`) because the data is
 *    almost never in the HTML; it is in the JSON the page fetched for itself.
 *
 * ## The rule that governs every line of the paused-request path
 *
 * **A paused request must always be answered.** `Fetch.enable` takes requests
 * out of the network stack and gives them to this process; a request this code
 * throws on, forgets, or returns early from is a request that never completes,
 * which is a page that never finishes loading and a tool call that hangs until
 * something else times out. So {@link onPaused} has a `catch` whose only job is
 * to continue the request, the failure of *that* is counted, and the count is
 * in the result — because the one thing worse than a page that hangs is a page
 * that hangs while the caller is told everything went well.
 *
 * ## Why bodies are read on `loadingFinished` and not one event earlier
 *
 * The trap in passive capture is that Chromium's response buffer is small and
 * evicts, so `getResponseBody` fails if you ask late — and a crawl that asks on
 * demand, later, asks late every time. The instinct is therefore to ask as
 * early as possible, which is `Network.responseReceived`. That is *too* early:
 * at `responseReceived` only the headers have arrived, and the call answers
 * "No data found for resource with given identifier" for anything that has not
 * finished streaming.
 *
 * `Network.loadingFinished` is the first moment the body exists and is
 * therefore the eager moment. Between it and the next navigation — which clears
 * the buffer — is the whole window, and this asks inside it, on the event, for
 * every response, whether or not anybody has asked for the data yet. The buffer
 * is also enlarged when the domain is enabled, which is the other half: see
 * {@link BUFFER}.
 *
 * And when it fails anyway, the entry is still written, with `bodyState: 'lost'`
 * and Chromium's own sentence. A capture that silently has holes in it is the
 * exact class of failure this work exists to end.
 */

/* ---------------------------------------------------------------- the wire -- */

/**
 * Everything this needs from the page, and nothing else.
 *
 * An interface rather than a `WebContents`, for the reason `DriveHost` gives one
 * file over: the piece that decides whether a dangerous call happens cannot be
 * exercisable if it constructs its own Electron objects. Every command goes out
 * through `BrowserDrive.send`, which screens it in `browser-cdp.ts` — this class
 * has no other way to reach Chromium and is not allowed one.
 */
export interface NetworkTransport {
  send(method: string, params?: Record<string, unknown>): Promise<Record<string, unknown>>
  /** Subscribe to this page's debugger events. Returns the unsubscribe. */
  onEvent(handler: (method: string, params: Record<string, unknown>) => void): () => void
  /** Ask the page how big it expects the image at this URL to be. */
  sizeOf(url: string): Promise<unknown>
  now(): number
}

/**
 * How much response body Chromium keeps for us, and why it is raised.
 *
 * The defaults are a few megabytes total, which is a DevTools-sized number: a
 * person clicks one request and looks at it. A page being harvested makes
 * hundreds, and the earliest ones — which on a listing page are the ones with
 * the data — are evicted before the page has finished loading. Raising the
 * buffer is the difference between capturing a page's API traffic and capturing
 * the tail of it.
 *
 * These are Chromium's own caps on its own memory; they bound a buffer, not an
 * allocation this process makes. The bytes that reach *this* process are bounded
 * separately and visibly by `CaptureBounds`.
 */
const BUFFER = {
  maxTotalBufferSize: 256 * 1024 * 1024,
  maxResourceBufferSize: 32 * 1024 * 1024,
  /** Request bodies. Recorded nowhere; kept small deliberately. */
  maxPostDataSize: 0,
}

/**
 * How long a paused image waits for the page to say how big it is.
 *
 * Generous against an idle renderer answering a `querySelectorAll` — which is
 * the ordinary case, and takes a millisecond or two — and short enough that a
 * page busy enough to miss it is not held up. On expiry the placeholder is 1×1
 * and the run's `sized.unknown` count goes up, so a page that consistently
 * misses this is visible rather than mysterious.
 */
export const SIZE_PROBE_MS = 300

/**
 * How many requests may be in flight before this stops remembering them.
 *
 * The map is keyed on an id Chromium mints and is emptied as responses land, so
 * in ordinary use it holds tens. The cap is for the page that opens a thousand
 * streams and never closes them: an unbounded map fed by a website is a leak
 * with a nice name. What is dropped is counted and appears in the shortfall.
 */
const MAX_INFLIGHT = 5_000

/* ---------------------------------------------------------------- the tally -- */

export interface RuleCounts {
  /** Requests taken out of the network stack and decided here. */
  paused: number
  /** Continued to the network — a kind with no rule, or one this could not decide. */
  allowed: number
  blocked: number
  cheap: number
  /**
   * Paused requests this could not answer at all.
   *
   * Non-zero means a page somewhere is still waiting, and that is the loudest
   * number in this object. It happens when the channel shuts underneath a
   * paused request — the person took the page, or the window closed.
   */
  stuck: number
  /** Where the placeholders' dimensions came from. See `browser-capture-script.ts`. */
  sized: Record<SizeSource | 'unknown', number>
  /** Placeholders whose height was derived from a ratio rather than stated. */
  derivedHeights: number
  /** Placeholders the page asked to be bigger than this app will build. */
  clamped: number
}

function emptyRuleCounts(): RuleCounts {
  return {
    paused: 0,
    allowed: 0,
    blocked: 0,
    cheap: 0,
    stuck: 0,
    sized: { attributes: 0, srcset: 0, box: 0, none: 0, unknown: 0 },
    derivedHeights: 0,
    clamped: 0,
  }
}

/** One request seen on the wire, waiting for its response to finish. */
interface Pending {
  url: string
  method: string
  kind: string
  status: number
  mimeType: string
  headers: Record<string, string>
  sawResponse: boolean
}

export interface ArmOptions {
  rules: FetchRules
  /** Null when this run is not capturing — rules only. */
  capture: {
    store: CaptureStore
    /** Which kinds' bodies are kept. Everything else is recorded as `not-requested`. */
    bodyKinds: ReadonlySet<string>
  } | null
}

export interface NetworkStatus {
  armed: boolean
  suspended: boolean
  rules: FetchRules
  counts: RuleCounts
  capture: CaptureSummary | null
  /** Live counts while a capture is running; the summary is written at stop. */
  captured: ReturnType<CaptureStore['snapshot']> | null
  /**
   * Requests forgotten because too many were open at once.
   *
   * Each one is a response that will never appear in the manifest, so it is a
   * hole — and holes are reported. Non-zero means the page had more than
   * {@link MAX_INFLIGHT} requests in flight and the capture is incomplete by
   * that many.
   */
  dropped: number
}

/* --------------------------------------------------------------- the engine -- */

export class PageNetwork {
  private armed = false
  private suspended = false
  private rules: FetchRules = {}
  private capture: ArmOptions['capture'] = null
  private off: (() => void) | null = null
  private counts = emptyRuleCounts()
  private readonly inflight = new Map<string, Pending>()
  private droppedInflight = 0
  /** URL → what the page said, so a grid of forty identical cards asks once. */
  private readonly sizes = new Map<string, SizeHint | null>()
  private readonly asking = new Map<string, Promise<SizeHint | null>>()

  constructor(private readonly wire: NetworkTransport) {}

  get isArmed(): boolean {
    return this.armed
  }

  /**
   * Turn both capabilities on for this page.
   *
   * Idempotent in the sense that arming twice replaces the rules rather than
   * stacking them — `Fetch.enable` called again *replaces* the pattern list,
   * which is Chromium's behaviour and the one this wants.
   */
  async arm(options: ArmOptions): Promise<void> {
    this.rules = options.rules
    this.capture = options.capture
    this.armed = true
    this.suspended = false
    this.listen()
    await this.enable()
  }

  private listen(): void {
    if (this.off !== null) return
    this.off = this.wire.onEvent((method, params) => {
      this.onEvent(method, params)
    })
  }

  private async enable(): Promise<void> {
    if (this.capture !== null) {
      await this.wire.send('Network.enable', { ...BUFFER })
    }
    const kinds = interceptedKinds(this.rules)
    if (kinds.length > 0) {
      /*
       * Narrowed to the kinds a rule actually names.
       *
       * `Fetch.enable` with no patterns pauses **everything**, including the
       * document, and puts every request in the page on a round trip through
       * this process. Patterns keep the cost proportional to what was asked
       * for: an image rule pauses images and nothing else.
       *
       * `requestStage: 'Request'` is stated rather than defaulted, because the
       * other value is `Response`, which is a different and much larger power —
       * and `browser-cdp.ts` refuses it at the channel for exactly that reason.
       */
      await this.wire.send('Fetch.enable', {
        patterns: kinds.map((kind) => ({
          urlPattern: '*',
          resourceType: cdpResourceType(kind),
          requestStage: 'Request',
        })),
      })
    }
  }

  /**
   * Stop intercepting, without ending the run.
   *
   * Called when the baton leaves the agent — a handover, or the page being
   * released. This is not tidiness: `browser-cdp.ts` refuses every command
   * while the person has the page, so an interception left armed across a
   * handover would pause his images and then be unable to answer them. He would
   * be handed a page that never finishes loading, in order to type a password
   * into it.
   *
   * Everything still in flight is written down as `unfinished` with the reason,
   * because a body that will now never be fetched is a hole, and a hole is
   * recorded.
   */
  async suspend(why: string): Promise<void> {
    if (!this.armed || this.suspended) return
    this.suspended = true
    await this.disableQuietly()
    this.flushPending(`capture stopped: ${why}`)
  }

  /** The person handed the page back. Put the rules and the capture back on. */
  async resume(): Promise<void> {
    if (!this.armed || !this.suspended) return
    this.suspended = false
    await this.enable()
  }

  /**
   * End the run: stop intercepting, close the store, answer with everything.
   *
   * The summary is the return value as well as a file, so a disk that would not
   * take `capture-summary.json` has not taken the answer away from the caller.
   */
  async disarm(why = 'the caller stopped it'): Promise<NetworkStatus> {
    if (!this.armed) return this.status()
    await this.disableQuietly()
    this.flushPending(`capture stopped: ${why}`)
    const summary = this.capture === null ? null : this.capture.store.close()
    const status: NetworkStatus = {
      armed: false,
      suspended: false,
      rules: this.rules,
      counts: { ...this.counts, sized: { ...this.counts.sized } },
      capture: summary,
      captured: this.capture === null ? null : this.capture.store.snapshot(),
      dropped: this.droppedInflight,
    }
    this.armed = false
    this.suspended = false
    this.capture = null
    this.rules = {}
    this.off?.()
    this.off = null
    this.inflight.clear()
    this.sizes.clear()
    this.asking.clear()
    this.counts = emptyRuleCounts()
    this.droppedInflight = 0
    return status
  }

  /**
   * The page has gone. Close the books without sending anything.
   *
   * Distinct from {@link disarm} because there is no page to send `Fetch.disable`
   * to, and a command sent to a destroyed WebContents is an unhandled rejection
   * rather than an error anybody sees.
   */
  abandon(why: string): NetworkStatus | null {
    if (!this.armed) return null
    this.flushPending(why)
    const summary = this.capture === null ? null : this.capture.store.close()
    const status: NetworkStatus = {
      armed: false,
      suspended: false,
      rules: this.rules,
      counts: { ...this.counts, sized: { ...this.counts.sized } },
      capture: summary,
      captured: this.capture === null ? null : this.capture.store.snapshot(),
      dropped: this.droppedInflight,
    }
    this.armed = false
    this.capture = null
    this.off?.()
    this.off = null
    this.inflight.clear()
    return status
  }

  /**
   * Where the page is, written into the run's own summary.
   *
   * Called by the driver, which is the only thing holding a `WebContents`.
   * Handed in rather than reached for, like everything else this class needs
   * from Chromium.
   */
  notePage(input: { url: string; title: string; armed?: boolean }): void {
    if (this.capture === null) return
    if (input.armed === true) this.capture.store.noteArmed(input.url)
    else this.capture.store.noteStopped(input.url, input.title)
  }

  status(): NetworkStatus {
    return {
      armed: this.armed,
      suspended: this.suspended,
      rules: this.rules,
      counts: { ...this.counts, sized: { ...this.counts.sized } },
      capture: null,
      captured: this.capture === null ? null : this.capture.store.snapshot(),
      dropped: this.droppedInflight,
    }
  }

  private async disableQuietly(): Promise<void> {
    // Best effort, both of them. The ordinary reason either fails is that the
    // page is already gone, which is the state this was trying to reach.
    await this.wire.send('Fetch.disable').catch(() => undefined)
    await this.wire.send('Network.disable').catch(() => undefined)
  }

  /* ------------------------------------------------------------- the events -- */

  private onEvent(method: string, params: Record<string, unknown>): void {
    /*
     * Ignoring a `Fetch.requestPaused` while suspended does **not** hang the
     * page, and that is worth stating because it is the one place where doing
     * nothing looks like the bug this file spends its length avoiding.
     * `suspend()` sends `Fetch.disable`, and disabling the domain continues
     * every request it is holding — including any whose event was already on
     * its way here. There is no request left for this handler to answer.
     */
    if (!this.armed || this.suspended) return
    switch (method) {
      case 'Fetch.requestPaused':
        void this.onPaused(params)
        return
      case 'Network.requestWillBeSent':
        this.onRequest(params)
        return
      case 'Network.responseReceived':
        this.onResponse(params)
        return
      case 'Network.loadingFinished':
        void this.onFinished(params)
        return
      case 'Network.loadingFailed':
        this.onFailed(params)
        return
      default:
        return
    }
  }

  /* -------------------------------------------------------- request control -- */

  private async onPaused(params: Record<string, unknown>): Promise<void> {
    const requestId = text(params.requestId)
    if (requestId === '') return
    this.counts.paused += 1
    try {
      const kind = kindOfResourceType(params.resourceType)
      const action = actionFor(kind, this.rules)
      if (kind === null || action === 'allow') {
        this.counts.allowed += 1
        await this.answer('Fetch.continueRequest', { requestId })
        return
      }
      if (action === 'block') {
        this.counts.blocked += 1
        /*
         * `BlockedByClient` and not `Failed`.
         *
         * The page is told an extension-shaped refusal, which is a thing every
         * site already handles — `Failed` reads as a flaky network and is what
         * triggers the aggressive retry loops that make a blocked crawl slower
         * than an allowed one.
         */
        await this.answer('Fetch.failRequest', { requestId, errorReason: 'BlockedByClient' })
        return
      }
      await this.fulfilCheaply(requestId, kind, request(params))
    } catch {
      /*
       * The last line of defence, and the reason it exists is in the header: a
       * paused request that is never answered is a page that never loads. This
       * runs for anything at all — a probe that threw, a placeholder that would
       * not build, a protocol error — and its own failure is counted rather
       * than swallowed, because a stuck page must not look like a clean run.
       */
      try {
        await this.wire.send('Fetch.continueRequest', { requestId })
        this.counts.allowed += 1
      } catch {
        this.counts.stuck += 1
      }
    }
  }

  /** Send one answer to a paused request, counting a failure to send. */
  private async answer(method: string, params: Record<string, unknown>): Promise<void> {
    try {
      await this.wire.send(method, params)
    } catch {
      this.counts.stuck += 1
    }
  }

  private async fulfilCheaply(
    requestId: string,
    kind: ResourceKind,
    url: string,
  ): Promise<void> {
    this.counts.cheap += 1
    let mimeType: string
    let body: Buffer
    if (kind === 'image') {
      const hint = await this.sizeFor(url)
      const source: SizeSource | 'unknown' = hint === null ? 'unknown' : hint.from
      this.counts.sized[source] += 1
      if (hint?.derivedHeight === true) this.counts.derivedHeights += 1
      /*
       * 1×1 only when nothing stated a size — which is the fallback the design
       * called for and the one this file spends most of its effort avoiding.
       * See `browser-placeholder.ts` for what a 1×1 costs a lazy-loader.
       */
      const made = placeholderPng(hint?.width ?? 1, hint?.height ?? 1)
      if (made.clamped) this.counts.clamped += 1
      mimeType = 'image/png'
      body = made.png
    } else {
      const cheap = cheapBodyFor(kind)
      mimeType = cheap.mimeType
      body = cheap.body
    }
    await this.answer('Fetch.fulfillRequest', {
      requestId,
      responseCode: 200,
      responseHeaders: cheapHeaders(mimeType, body.length),
      body: body.toString('base64'),
    })
  }

  /**
   * How big the page expects this image to be, asked once per URL.
   *
   * Bounded, cached, and de-duplicated across concurrent pauses — a grid of
   * forty cards pointing at one placeholder URL asks the page once. A `null`
   * answer is cached too: an image the DOM cannot account for will not start
   * being accountable on the next request for it.
   */
  private async sizeFor(url: string): Promise<SizeHint | null> {
    if (this.sizes.has(url)) return this.sizes.get(url) ?? null
    const already = this.asking.get(url)
    if (already) return already
    const ask = (async (): Promise<SizeHint | null> => {
      try {
        const raw = await withTimeout(this.wire.sizeOf(url), SIZE_PROBE_MS)
        const hint = readSizeHint(raw)
        this.sizes.set(url, hint)
        return hint
      } catch {
        /*
         * Not cached. A timeout is a fact about how busy the renderer was at
         * this instant, not about the URL, and caching it would make one slow
         * moment during page load poison every later request for that image.
         */
        return null
      } finally {
        this.asking.delete(url)
      }
    })()
    this.asking.set(url, ask)
    return ask
  }

  /* -------------------------------------------------------------- capturing -- */

  private onRequest(params: Record<string, unknown>): void {
    if (this.capture === null) return
    const requestId = text(params.requestId)
    if (requestId === '' || this.inflight.has(requestId)) return
    if (this.inflight.size >= MAX_INFLIGHT) {
      this.droppedInflight += 1
      return
    }
    this.inflight.set(requestId, {
      url: request(params),
      method: text(asRecord(params.request).method) || 'GET',
      kind: text(params.type).toLowerCase(),
      status: 0,
      mimeType: '',
      headers: {},
      sawResponse: false,
    })
  }

  private onResponse(params: Record<string, unknown>): void {
    if (this.capture === null) return
    const requestId = text(params.requestId)
    const pending = this.inflight.get(requestId)
    const response = asRecord(params.response)
    const url = text(response.url)
    const kind = text(params.type).toLowerCase()
    const next: Pending = {
      url: url === '' ? (pending?.url ?? '') : url,
      method: pending?.method ?? 'GET',
      kind: kind === '' ? (pending?.kind ?? '') : kind,
      status: typeof response.status === 'number' ? response.status : 0,
      mimeType: text(response.mimeType),
      /*
       * A named subset, never the whole header block. `set-cookie` on a
       * captured response is a session credential written into a JSON file
       * beside the data, and the data is the thing most likely to be copied
       * somewhere else. See `KEPT_HEADERS`.
       */
      headers: keptHeaders(response.headers),
      sawResponse: true,
    }
    if (pending === undefined && this.inflight.size >= MAX_INFLIGHT) {
      this.droppedInflight += 1
      return
    }
    this.inflight.set(requestId, next)
  }

  private async onFinished(params: Record<string, unknown>): Promise<void> {
    const capture = this.capture
    if (capture === null) return
    const requestId = text(params.requestId)
    const pending = this.inflight.get(requestId)
    if (pending === undefined) return
    this.inflight.delete(requestId)
    if (capture.store.remaining === 0) return

    const encoded =
      typeof params.encodedDataLength === 'number' && params.encodedDataLength > 0
        ? Math.trunc(params.encodedDataLength)
        : 0

    const base = {
      url: pending.url,
      method: pending.method,
      kind: pending.kind,
      status: pending.status,
      mimeType: pending.mimeType,
      headers: pending.headers,
    }

    if (!pending.sawResponse) {
      capture.store.add({
        ...base,
        bytes: encoded,
        bodyState: 'lost',
        message: 'the response finished without this app ever seeing its headers',
      })
      return
    }

    if (!capture.bodyKinds.has(pending.kind)) {
      capture.store.add({
        ...base,
        bytes: encoded,
        bodyState: 'not-requested',
        message: '',
      })
      return
    }

    /*
     * The compressed size, checked before the body is pulled across.
     *
     * `getResponseBody` on a 200 MB download hands 200 MB to this process
     * before anything gets to have an opinion about it. `encodedDataLength` is
     * what actually came down the wire, so when *that* is already over the
     * per-body bound the answer is settled and the transfer is never made. It
     * is a lower bound on the decoded size, so nothing that would have fitted
     * is refused by it.
     */
    const admits = capture.store.admits(encoded)
    if (encoded > 0 && !admits.ok) {
      capture.store.add({ ...base, bytes: encoded, bodyState: admits.state, message: admits.message })
      return
    }

    try {
      const answer = await this.wire.send('Network.getResponseBody', { requestId })
      const raw = text(answer.body)
      const body =
        answer.base64Encoded === true ? Buffer.from(raw, 'base64') : Buffer.from(raw, 'utf8')
      capture.store.add({ ...base, bodyState: 'saved', message: '' }, body)
    } catch (error) {
      /*
       * Written down rather than dropped, and this is the entire point of the
       * module. Chromium's own sentence goes in the record — "No resource with
       * given identifier found" is an eviction, "No data found for resource" is
       * a redirect or a 204, and a caller that can read the difference can
       * decide whether re-running would help.
       */
      capture.store.add({
        ...base,
        bytes: encoded,
        bodyState: 'lost',
        message: `the browser would not hand back the body: ${message(error)}`,
      })
    }
  }

  private onFailed(params: Record<string, unknown>): void {
    const capture = this.capture
    if (capture === null) return
    const requestId = text(params.requestId)
    const pending = this.inflight.get(requestId)
    if (pending === undefined) return
    this.inflight.delete(requestId)
    if (capture.store.remaining === 0) return
    const why = text(params.errorText)
    capture.store.add({
      url: pending.url,
      method: pending.method,
      kind: pending.kind,
      status: pending.status,
      mimeType: pending.mimeType,
      headers: pending.headers,
      bodyState: 'failed',
      message:
        params.canceled === true
          ? `the request was cancelled${why === '' ? '' : `: ${why}`}`
          : why === ''
            ? 'the request failed and the browser gave no reason'
            : why,
    })
  }

  /**
   * Everything still in flight, written down as unfinished.
   *
   * Called when the run stops for any reason. Each of these is a response whose
   * body will now never be fetched, and every one of them is an entry — a
   * manifest that simply ended while forty requests were open is a manifest
   * with forty invisible holes.
   */
  private flushPending(why: string): void {
    const capture = this.capture
    if (capture === null) {
      this.inflight.clear()
      return
    }
    for (const pending of this.inflight.values()) {
      if (capture.store.remaining === 0) break
      capture.store.add({
        url: pending.url,
        method: pending.method,
        kind: pending.kind,
        status: pending.status,
        mimeType: pending.mimeType,
        headers: pending.headers,
        bodyState: 'unfinished',
        message: why,
      })
    }
    this.inflight.clear()
  }
}

/* --------------------------------------------------------------- helpers -- */

function text(raw: unknown): string {
  return typeof raw === 'string' ? raw : ''
}

function asRecord(raw: unknown): Record<string, unknown> {
  return typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
}

/**
 * The URL of a paused or in-flight request.
 *
 * Only ever the URL. The `request` object on these events also carries
 * `headers`, which on a logged-in page holds `Cookie` and `Authorization` — the
 * literal credentials `browser-session.ts` goes to such lengths to keep out of
 * the renderer. Nothing here reads that field, nothing records it, and
 * `browser-network.test.ts` asserts the absence rather than trusting it.
 */
function request(params: Record<string, unknown>): string {
  return text(asRecord(params.request).url)
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/** Resolve, or give up. A paused request cannot wait on a page that is busy. */
async function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  let timer: NodeJS.Timeout | null = null
  try {
    return await Promise.race([
      promise,
      new Promise<T>((_resolve, reject) => {
        timer = setTimeout(() => reject(new Error('timed out')), ms)
        timer.unref?.()
      }),
    ])
  } finally {
    if (timer !== null) clearTimeout(timer)
  }
}
