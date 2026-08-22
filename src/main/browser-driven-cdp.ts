import { inflateSync } from 'node:zlib'
import { attachBlockWatch, type BlockWatchDeps, type BlockWatchTarget } from './browser-block-watch'
import type { CdpEvent } from './browser-cdp-pipe'
import type { DrivenPage } from './browser-driver'
import type { RawFrame } from './browser-png'
import { readPngSize } from './marked-image'
import { isNavigationAllowed } from './browser-url'

/**
 * The CDP half of the {@link DrivenPage} seam: one Chromium target, spoken to
 * over a `--remote-debugging-pipe`, dressed as a page the driver can steer
 * without knowing it is not Electron.
 *
 * ## Why this file is the other implementation
 *
 * `browser-driver.ts` used to reach for a `WebContents`, `nativeImage` and
 * `wc.debugger` directly. Route B needs that same engine on a headless Linux
 * server driving a real headless Chromium *over CDP*, so the driver became
 * transport-agnostic and every Electron-shaped operation moved behind
 * {@link DrivenPage}. `browser-driven-electron.ts` is the desktop's
 * implementation; this is the server's. Nothing here imports Electron — it is
 * one of the files the headless closure walks — and everything it does is a
 * frame on the one pipe `browser-cdp-pipe.ts` multiplexes.
 *
 * ## The doors, method by method
 *
 * Each method is the CDP spelling of the operation the driver used to do inline:
 *
 *  - `send` is the raw transport door. The driver screens every command through
 *    `browser-cdp.ts` *before* calling it — the same contract the Electron door
 *    has — so this only tags the command with its session and hands it to the
 *    pipe. It does not screen again.
 *  - `loadURL`/`navigateGuarded` are `Page.navigate`, and here — unlike the
 *    desktop, where `loadURL` runs through `will-navigate` — `Page.navigate` is
 *    the only door, so `isNavigationAllowed` is applied *in this file* before the
 *    frame is sent. A browser-initiated navigate walks past every page guard;
 *    this is the guard.
 *  - `runInIsolatedWorld` is the single read door. It runs only in a world made
 *    by `Page.createIsolatedWorld` — never the main world, ever — so a script
 *    cannot see or be seen by the page, and there is no path from a value to the
 *    main world's globals. The world's context id is memoized and dropped on
 *    navigation, because a new document is a new context.
 *  - `capture` is `Page.captureScreenshot`, decoded from PNG back to the raw
 *    RGBA {@link RawFrame} the driver masks and re-encodes in `browser-png.ts`.
 *    A headless target always composites, so the desktop's "no visible surface"
 *    retry is unnecessary here — the first capture succeeds.
 */

/**
 * The little of `browser-cdp-pipe.ts`'s `CdpPipe` this file uses.
 *
 * A structural interface rather than the class so a test can drive the page with
 * a scripted pipe, and so this file depends on the shape of the transport rather
 * than its construction — the pipe is spawned and handed in by the launcher and
 * the headless host, never made here. `CdpPipe` satisfies it as written.
 */
export interface CdpTransport {
  command(command: { method: string; params?: unknown; sessionId?: string }): Promise<unknown>
  on(sessionId: string | undefined, listener: (event: CdpEvent) => void): () => void
  onClose(listener: (error?: Error) => void): () => void
}

/** What a CDP page needs to know about the target it drives. */
export interface CdpPageInit {
  /** The target this page is, as `Target.createTarget` returned it. */
  targetId: string
  /** The URL the target was created at, so `url()` answers before the first navigation. */
  url?: string
  /** The isolated world the drive's scripts run in. Defaults to a fixed name. */
  worldName?: string
}

/** The default isolated world for the drive's own scripts. */
const DRIVE_WORLD = 'terminaldeck-drive'

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null
}

function asRecord(value: unknown): Record<string, unknown> {
  return isRecord(value) ? value : {}
}

/* --------------------------------------------------------------- the PNG -- */

/**
 * A PNG from `Page.captureScreenshot`, decoded to tightly packed RGBA.
 *
 * The desktop's capture arrives as a raw bitmap already; the server's arrives as
 * a PNG, and the driver's masking works on RGBA, so it is decoded here. Only the
 * shapes a Chromium screenshot actually is are handled — 8-bit, non-interlaced,
 * colour type 2 (RGB) or 6 (RGBA) — and anything else throws rather than
 * returning a buffer of the wrong shape, for the same reason `browser-png.ts`
 * throws: a screenshot that never appears is a bug report, and one that appears
 * wrong is not noticed. The size is read from the file's own `IHDR` via
 * `marked-image.ts`, never taken on the protocol's word.
 */
export function decodePngToRgba(bytes: Buffer): RawFrame {
  const size = readPngSize(bytes)
  if (size === null) throw new Error('the screenshot was not a PNG this can read')

  // IHDR payload begins at byte 16 (8 signature + 4 length + 4 type). Width and
  // height are the first eight bytes and already read; depth and colour type
  // follow.
  const bitDepth = bytes[24]
  const colourType = bytes[25]
  const interlace = bytes[28]
  if (bitDepth !== 8) throw new Error('the screenshot was not 8-bit, which this cannot read')
  if (interlace !== 0) throw new Error('the screenshot was interlaced, which this cannot read')
  if (colourType !== 2 && colourType !== 6) {
    throw new Error('the screenshot was not RGB or RGBA, which this cannot read')
  }
  const channels = colourType === 6 ? 4 : 3

  // Concatenate every IDAT chunk, then inflate once. Chunk layout: 4-byte
  // length, 4-byte type, payload, 4-byte CRC.
  const idat: Buffer[] = []
  let offset = 8
  while (offset + 8 <= bytes.length) {
    const length = bytes.readUInt32BE(offset)
    const type = bytes.toString('latin1', offset + 4, offset + 8)
    const start = offset + 8
    const end = start + length
    if (end + 4 > bytes.length) break
    if (type === 'IDAT') idat.push(bytes.subarray(start, end))
    if (type === 'IEND') break
    offset = end + 4
  }
  if (idat.length === 0) throw new Error('the screenshot had no image data')

  const raw = inflateSync(Buffer.concat(idat))
  const { width, height } = size
  const stride = width * channels
  // One filter byte in front of each scanline.
  if (raw.length < height * (stride + 1)) {
    throw new Error('the screenshot decoded to fewer bytes than its size claims')
  }

  const rgba = Buffer.allocUnsafe(width * height * 4)
  const line = Buffer.alloc(stride) // the current unfiltered scanline
  const prior = Buffer.alloc(stride) // the one above it, for Up/Average/Paeth
  let src = 0
  for (let y = 0; y < height; y++) {
    const filter = raw[src]
    src += 1
    for (let x = 0; x < stride; x++) {
      const value = raw[src + x]
      const a = x >= channels ? line[x - channels] : 0 // the byte to the left
      const b = prior[x] // the byte above
      const c = x >= channels ? prior[x - channels] : 0 // the byte above-left
      let recon: number
      switch (filter) {
        case 0:
          recon = value
          break
        case 1:
          recon = value + a
          break
        case 2:
          recon = value + b
          break
        case 3:
          recon = value + ((a + b) >> 1)
          break
        case 4:
          recon = value + paeth(a, b, c)
          break
        default:
          throw new Error('the screenshot used a PNG filter this cannot read')
      }
      line[x] = recon & 0xff
    }
    src += stride

    const rowStart = y * width * 4
    for (let x = 0; x < width; x++) {
      const from = x * channels
      const to = rowStart + x * 4
      rgba[to] = line[from]
      rgba[to + 1] = line[from + 1]
      rgba[to + 2] = line[from + 2]
      rgba[to + 3] = channels === 4 ? line[from + 3] : 0xff
    }
    line.copy(prior)
  }

  // A headless target reports its device-pixel resolution in the buffer itself;
  // the CSS scale a mask needs is re-derived from the viewport in
  // `browser-png.ts`, never from this, so 1 is the honest informational value.
  return { data: rgba, width, height, scale: 1 }
}

/** PNG's Paeth predictor, byte-wise. */
function paeth(a: number, b: number, c: number): number {
  const p = a + b - c
  const pa = Math.abs(p - a)
  const pb = Math.abs(p - b)
  const pc = Math.abs(p - c)
  if (pa <= pb && pa <= pc) return a
  if (pb <= pc) return b
  return c
}

/* ------------------------------------------------------------- the page -- */

type Handler<A extends unknown[]> = (...args: A) => void

class CdpDrivenPage implements DrivenPage {
  private readonly targetId: string
  private readonly worldName: string
  private sessionId: string | undefined
  private cachedUrl: string
  private cachedTitle = ''
  private gone = false
  private loading = false
  private worldContextId: number | undefined
  private mainFrameId: string | undefined

  private unsubscribeSession: (() => void) | null = null
  private readonly unsubscribeBrowser: () => void
  private readonly unsubscribeClose: () => void

  private readonly eventHandlers = new Set<(method: string, params: Record<string, unknown>) => void>()
  private readonly settleHandlers = new Set<() => void>()
  private readonly goneHandlers = new Set<() => void>()
  private readonly detachedHandlers = new Set<() => void>()
  private readonly destroyedHandlers = new Map<string, () => void>()

  constructor(
    private readonly transport: CdpTransport,
    init: CdpPageInit,
  ) {
    this.targetId = init.targetId
    this.worldName = init.worldName ?? DRIVE_WORLD
    this.cachedUrl = init.url ?? ''

    // Browser-level events carry no sessionId: a target being destroyed, a
    // target's info changing (its URL and title), a session being detached out
    // from under us. All are keyed to this target or its session.
    this.unsubscribeBrowser = this.transport.on(undefined, (event) => this.onBrowserEvent(event))
    // The pipe itself going — fd EOF, the launcher's child gone — is a page
    // gone, the CDP analogue of `render-process-gone`.
    this.unsubscribeClose = this.transport.onClose(() => this.markGone())
  }

  /* ------------------------------------------------------------- identity -- */

  url(): string {
    return this.cachedUrl
  }

  title(): string {
    return this.cachedTitle
  }

  isGone(): boolean {
    return this.gone
  }

  /* ------------------------------------------------------------ the wire -- */

  async attach(): Promise<void> {
    if (this.sessionId !== undefined) return
    const result = asRecord(
      await this.transport.command({
        method: 'Target.attachToTarget',
        // Flatten mode: this session multiplexes on the one pipe by its
        // sessionId, the same as every other target's.
        params: { targetId: this.targetId, flatten: true },
      }),
    )
    const sessionId = result.sessionId
    if (typeof sessionId !== 'string' || sessionId === '') {
      throw new Error('the target did not return a debugger session')
    }
    this.sessionId = sessionId
    this.unsubscribeSession = this.transport.on(sessionId, (event) => this.onSessionEvent(event))
    // Crashes surface as `Inspector.targetCrashed`, which needs the domain on.
    // Best-effort: a target that refuses it still reports its death through the
    // browser-level `Target.targetDestroyed` this page also listens for.
    await this.transport
      .command({ method: 'Inspector.enable', params: {}, sessionId })
      .catch(() => undefined)
  }

  detach(): void {
    const sessionId = this.sessionId
    if (sessionId === undefined) return
    this.sessionId = undefined
    this.worldContextId = undefined
    if (this.unsubscribeSession) {
      this.unsubscribeSession()
      this.unsubscribeSession = null
    }
    // Fire and forget: the caller may be tearing down a page that has already
    // gone, and a rejection here is the same "already gone" the Electron door
    // swallows.
    void this.transport
      .command({ method: 'Target.detachFromTarget', params: { sessionId } })
      .catch(() => undefined)
  }

  isAttached(): boolean {
    return this.sessionId !== undefined
  }

  async send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    // The one raw door. Screened by the driver's `send()` before this is ever
    // called — this only tags the command with the session and hands it to the
    // pipe.
    const result = await this.transport.command({ method, params, sessionId: this.sessionId })
    return asRecord(result)
  }

  onEvent(handler: (method: string, params: Record<string, unknown>) => void): () => void {
    this.eventHandlers.add(handler)
    return () => {
      this.eventHandlers.delete(handler)
    }
  }

  /* ---------------------------------------------------------- navigation -- */

  async loadURL(url: string): Promise<void> {
    // The guard the desktop got from `will-navigate` and the server does not:
    // `Page.navigate` is browser-initiated and walks past every page-level
    // check, so the only `file://`/`javascript:` protection is this one. The URL
    // has already been through `normalizeUrl` in the driver; this is the second
    // lock on the same door.
    if (!isNavigationAllowed(url)) {
      throw new Error(`refused to navigate to ${url}`)
    }
    // A failed load leaves the page where it was and the settle wait reports it,
    // exactly as the Electron door swallows a rejected `loadURL`.
    await this.send('Page.navigate', { url }).catch(() => undefined)
  }

  async navigateGuarded(url: string): Promise<'navigated' | 'unfinished'> {
    if (!isNavigationAllowed(url)) {
      throw new Error(`refused to navigate to ${url}`)
    }
    // `beforeunload` on a real headless target has no person to answer its
    // dialog, so there is no "the person declined" outcome to report; the
    // navigation proceeds. The URL guard is the part that must not be skipped,
    // and it is not.
    await this.send('Page.navigate', { url }).catch(() => undefined)
    return 'navigated'
  }

  /* -------------------------------------------------------------- reading -- */

  async runInIsolatedWorld<T>(code: string): Promise<T> {
    // The one read door. `code` is composed by the driver from a
    // `browser-drive-script.ts` string and JSON args; there is no path from a
    // model's text to page JavaScript, and — the property this file must keep —
    // it runs only in an isolated world, never the main world.
    try {
      return await this.evaluate<T>(code)
    } catch (error) {
      // A context that vanished under a navigation between memoizing it and
      // using it: drop it and make a fresh world once. A second failure is real.
      if (isMissingContext(error)) {
        this.worldContextId = undefined
        return this.evaluate<T>(code)
      }
      throw error
    }
  }

  private async evaluate<T>(code: string): Promise<T> {
    const contextId = await this.ensureWorld()
    const result = asRecord(
      await this.send('Runtime.evaluate', {
        expression: code,
        // The named world, always. Never a call with no context, which Chromium
        // would run in the main world — the one thing this door exists to
        // prevent.
        contextId,
        returnByValue: true,
        awaitPromise: true,
      }),
    )
    const exception = result.exceptionDetails
    if (exception !== undefined && exception !== null) {
      throw new Error(describeException(exception))
    }
    const value = asRecord(result.result).value
    return value as T
  }

  private async ensureWorld(): Promise<number> {
    if (this.worldContextId !== undefined) return this.worldContextId
    const frameId = await this.ensureMainFrame()
    const created = asRecord(
      await this.send('Page.createIsolatedWorld', {
        frameId,
        worldName: this.worldName,
        grantUniveralAccess: false,
      }),
    )
    const contextId = created.executionContextId
    if (typeof contextId !== 'number') {
      throw new Error('the isolated world was not created')
    }
    this.worldContextId = contextId
    return contextId
  }

  private async ensureMainFrame(): Promise<string> {
    if (this.mainFrameId !== undefined) return this.mainFrameId
    const tree = asRecord(await this.send('Page.getFrameTree', {}))
    const frameTree = asRecord(tree.frameTree)
    const frame = asRecord(frameTree.frame)
    const frameId = frame.id
    if (typeof frameId !== 'string' || frameId === '') {
      throw new Error('the target has no main frame to run in')
    }
    this.mainFrameId = frameId
    return frameId
  }

  /* ---------------------------------------------------------- screenshots -- */

  async capture(): Promise<RawFrame> {
    const result = asRecord(await this.send('Page.captureScreenshot', { format: 'png' }))
    const data = result.data
    if (typeof data !== 'string' || data === '') {
      throw new Error('the target returned no screenshot')
    }
    return decodePngToRgba(Buffer.from(data, 'base64'))
  }

  /* --------------------------------------------------------------- life -- */

  isLoading(): boolean {
    return this.loading
  }

  onSettled(handler: () => void): () => void {
    return this.subscribe(this.settleHandlers, handler)
  }

  onGone(handler: () => void): () => void {
    return this.subscribe(this.goneHandlers, handler)
  }

  onDetached(handler: () => void): () => void {
    return this.subscribe(this.detachedHandlers, handler)
  }

  onDestroyed(key: string, handler: () => void): void {
    // Keyed so watching one page from many places is one registration per place,
    // the same shared-registry shape `web-contents-teardown.ts` gives the
    // desktop. If the page is already gone, honour the contract immediately.
    if (this.gone) {
      handler()
      return
    }
    this.destroyedHandlers.set(key, handler)
  }

  watchBlocks(deps: BlockWatchDeps): void {
    attachBlockWatch(new CdpBlockWatchTarget(this), deps)
  }

  private subscribe<A extends unknown[]>(set: Set<Handler<A>>, handler: Handler<A>): () => void {
    set.add(handler)
    return () => {
      set.delete(handler)
    }
  }

  /* ------------------------------------------------------------- events -- */

  private onBrowserEvent(event: CdpEvent): void {
    const params = asRecord(event.params)
    switch (event.method) {
      case 'Target.targetInfoChanged': {
        const info = asRecord(params.targetInfo)
        if (info.targetId !== this.targetId) return
        if (typeof info.url === 'string') this.cachedUrl = info.url
        if (typeof info.title === 'string') this.cachedTitle = info.title
        return
      }
      case 'Target.targetCrashed': {
        if (params.targetId === this.targetId) this.markGone()
        return
      }
      case 'Target.targetDestroyed': {
        if (params.targetId === this.targetId) this.markGone()
        return
      }
      case 'Target.detachedFromTarget': {
        if (params.sessionId === this.sessionId) this.markDetached()
        return
      }
      default:
        return
    }
  }

  private onSessionEvent(event: CdpEvent): void {
    const params = asRecord(event.params)
    switch (event.method) {
      case 'Inspector.targetCrashed':
        this.markGone()
        break
      case 'Page.frameStartedLoading':
        if (this.isMainFrameEvent(params)) this.loading = true
        break
      case 'Page.loadEventFired':
        this.settle()
        break
      case 'Page.frameStoppedLoading':
        if (this.isMainFrameEvent(params)) this.settle()
        break
      case 'Page.frameNavigated': {
        const frame = asRecord(params.frame)
        // The main frame is the one with no parent. A subframe navigating is not
        // a new document for this page.
        if (frame.parentId === undefined) {
          if (typeof frame.id === 'string') this.mainFrameId = frame.id
          if (typeof frame.url === 'string') this.cachedUrl = frame.url
          // A new document is a new context; the memoized world is gone.
          this.worldContextId = undefined
        }
        break
      }
      case 'Runtime.executionContextsCleared':
        this.worldContextId = undefined
        break
      case 'Runtime.executionContextDestroyed': {
        const id = params.executionContextId
        if (typeof id === 'number' && id === this.worldContextId) this.worldContextId = undefined
        break
      }
      default:
        break
    }
    // Then fan out to whoever subscribed — `PageNetwork` is the only caller, and
    // it filters to the `Network.*`/`Fetch.*` events it wants.
    for (const handler of [...this.eventHandlers]) handler(event.method, params)
  }

  private isMainFrameEvent(params: Record<string, unknown>): boolean {
    // `frameStartedLoading`/`frameStoppedLoading` carry only a frameId. Before
    // the main frame is known, treat the event as the main frame's — the first
    // load of a fresh target is the one that matters and there are no subframes
    // yet.
    if (this.mainFrameId === undefined) return true
    return params.frameId === this.mainFrameId
  }

  private settle(): void {
    this.loading = false
    for (const handler of [...this.settleHandlers]) handler()
  }

  private markDetached(): void {
    this.sessionId = undefined
    this.worldContextId = undefined
    if (this.unsubscribeSession) {
      this.unsubscribeSession()
      this.unsubscribeSession = null
    }
    for (const handler of [...this.detachedHandlers]) handler()
  }

  private markGone(): void {
    if (this.gone) return
    this.gone = true
    this.loading = false
    this.unsubscribeBrowser()
    this.unsubscribeClose()
    if (this.unsubscribeSession) {
      this.unsubscribeSession()
      this.unsubscribeSession = null
    }
    for (const handler of [...this.goneHandlers]) handler()
    for (const handler of [...this.destroyedHandlers.values()]) handler()
    this.destroyedHandlers.clear()
    // A gone page is not loading anything; wake anyone waiting for it to settle.
    for (const handler of [...this.settleHandlers]) handler()
  }
}

/**
 * The stable {@link DrivenPage} for a target.
 *
 * A plain constructor rather than the desktop's `WeakMap` memo: the desktop keys
 * its wrapper on the one live `WebContents` a tab hands back, and there is no
 * such shared object here — the headless host owns exactly one page per target
 * and hands out the one it made. The driver's `watch()` still gets one page per
 * tab, because the host does.
 */
export function cdpDrivenPage(transport: CdpTransport, init: CdpPageInit): DrivenPage {
  return new CdpDrivenPage(transport, init)
}

function isMissingContext(error: unknown): boolean {
  if (!(error instanceof Error)) return false
  const message = error.message.toLowerCase()
  return message.includes('context') && (message.includes('cannot find') || message.includes('not found'))
}

function describeException(exception: unknown): string {
  const details = asRecord(exception)
  const thrown = asRecord(details.exception)
  if (typeof thrown.description === 'string' && thrown.description !== '') return thrown.description
  if (typeof details.text === 'string' && details.text !== '') return details.text
  return 'the isolated-world script threw'
}

/* -------------------------------------------------------- the block watch -- */

/**
 * The `BlockWatchTarget` the block watcher wants, built from CDP events.
 *
 * `browser-block-watch.ts` is written against the three Electron `WebContents`
 * signals — `did-navigate` (the only place an HTTP status is), `did-fail-load`
 * (a navigation that never arrived) and `did-stop-loading` (the point the
 * document can be read). This translates the CDP events into those three so the
 * exact same classifier, cooldown and capture ordering run on the server. The
 * status is read from `Network.responseReceived` for the main document when the
 * Network domain is on; when it is not, the body markers and failed-load signals
 * still fire, which is the same graceful degrade the watcher already tolerates.
 */
class CdpBlockWatchTarget implements BlockWatchTarget {
  private readonly handlers = new Map<string, (...args: never[]) => void>()
  private lastDocument: { url: string; status: number; statusText: string } | null = null

  constructor(private readonly page: CdpDrivenPage) {
    this.page.onEvent((method, params) => this.translate(method, params))
  }

  on(event: string, listener: (...args: never[]) => void): this {
    this.handlers.set(event, listener)
    return this
  }

  getURL(): string {
    return this.page.url()
  }

  getTitle(): string {
    return this.page.title()
  }

  private emit(event: string, args: unknown[]): void {
    const listener = this.handlers.get(event)
    if (listener) (listener as (...a: unknown[]) => void)(...args)
  }

  private translate(method: string, params: Record<string, unknown>): void {
    switch (method) {
      case 'Network.responseReceived': {
        if (params.type !== 'Document') return
        const response = asRecord(params.response)
        this.lastDocument = {
          url: typeof response.url === 'string' ? response.url : '',
          status: typeof response.status === 'number' ? response.status : 0,
          statusText: typeof response.statusText === 'string' ? response.statusText : '',
        }
        return
      }
      case 'Page.frameNavigated': {
        const frame = asRecord(params.frame)
        if (frame.parentId !== undefined) return // subframe
        const url = typeof frame.url === 'string' ? frame.url : ''
        const doc = this.lastDocument && this.lastDocument.url === url ? this.lastDocument : null
        this.emit('did-navigate', [{}, url, doc?.status ?? 0, doc?.statusText ?? ''])
        return
      }
      case 'Network.loadingFailed': {
        if (params.type !== 'Document') return
        // CDP reports a text, not Chromium's numeric code; `-3` is the value the
        // watcher treats as an ordinary aborted navigation, so a genuine failure
        // gets a distinct non-zero code and a cancel is reported as the abort it
        // is.
        const canceled = params.canceled === true
        const errorText = typeof params.errorText === 'string' ? params.errorText : ''
        this.emit('did-fail-load', [{}, canceled ? -3 : -100, errorText, this.getURL(), true])
        return
      }
      case 'Page.loadEventFired':
      case 'Page.frameStoppedLoading':
        this.emit('did-stop-loading', [])
        return
      default:
        return
    }
  }
}
