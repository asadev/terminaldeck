import type { NativeImage, WebContents } from 'electron'
import { attachBlockWatch, type BlockWatchDeps } from './browser-block-watch'
import { navigatePage, type SteerablePage } from './browser-route'
import type { DrivenPage } from './browser-driver'
import { maskFrame, type RawFrame } from './browser-png'
import { onWebContentsDestroyed } from './web-contents-teardown'

/**
 * The Electron half of the {@link DrivenPage} seam: one `WebContents`, dressed
 * as a page the driver can steer without knowing it is Electron.
 *
 * ## Why this file is where the Electron went
 *
 * `browser-driver.ts` used to reach for `WebContents`, `nativeImage` and
 * `wc.debugger` directly, which pinned the whole engine to a process that has
 * Chromium compiled into it. Route B needs that same engine to run on a headless
 * Linux server and drive a real Chromium *over CDP*, so the driver became
 * transport-agnostic and the Electron-shaped operations moved behind an
 * interface. This is one implementation of it; `browser-driven-cdp.ts` is the
 * other. Nothing here is in the headless import closure — it is reached only
 * from `browser-drive-ipc.ts`, which is the desktop's wiring.
 *
 * ## The two doors this file is trusted to be the only one of
 *
 * `browser-cdp.test.ts` counts, by reading this source, that there is exactly
 * **one** `wc.debugger.sendCommand` and exactly **one**
 * `wc.executeJavaScriptInIsolatedWorld` in it. That is the structural half of
 * the security argument: the driver screens every command through
 * `screenCommand` before it hands the method to {@link ElectronDrivenPage.send},
 * and it reads the page only through scripts from `browser-drive-script.ts`
 * handed to {@link ElectronDrivenPage.runInIsolatedWorld}. A second call to
 * either primitive, anywhere, would be a second door — so there is one, here,
 * and a test fails when a third appears.
 */

/**
 * The isolated world the drive's scripts run in.
 *
 * A fixed, arbitrary, high number so it cannot collide with world 0 (the page)
 * or with world 1, which is where a preload script's isolated context lives.
 * The guest preload in `browser-preload.ts` runs in that one; sharing a world
 * with it would mean the drive's helpers and the inspector's could see each
 * other's variables, and a name collision would be a bug nobody could
 * reproduce.
 */
const DRIVE_WORLD = 31_017

/**
 * BGRA (what `NativeImage.toBitmap()` hands back) to the RGBA the rest of the
 * pipeline speaks. A copy rather than an in-place swap because the bitmap a
 * `NativeImage` returns is not ours to scribble on.
 */
function bgraToRgba(bgra: Buffer): Buffer {
  const rgba = Buffer.allocUnsafe(bgra.length)
  for (let i = 0; i < bgra.length; i += 4) {
    rgba[i] = bgra[i + 2]
    rgba[i + 1] = bgra[i + 1]
    rgba[i + 2] = bgra[i]
    rgba[i + 3] = bgra[i + 3]
  }
  return rgba
}

class ElectronDrivenPage implements DrivenPage {
  constructor(private readonly wc: WebContents) {}

  url(): string {
    return this.wc.getURL()
  }

  title(): string {
    return this.wc.getTitle()
  }

  isGone(): boolean {
    return this.wc.isDestroyed()
  }

  async loadURL(url: string): Promise<void> {
    // Through `loadURL` and not `Page.navigate`: `Page.navigate` bypasses the
    // `will-navigate` guard entirely (see the header of `browser-cdp.ts`). The
    // rejection is swallowed here exactly as it was in the driver — a failed
    // load leaves the page where it was and the settle wait reports it.
    await this.wc.loadURL(url).catch(() => undefined)
  }

  navigateGuarded(url: string): Promise<'navigated' | 'unfinished'> {
    // A window the person can see gets the courtesy a browser gives: its own
    // `beforeunload` is asked first. `browser-route.ts` holds the whole argument.
    return navigatePage(this.wc as unknown as SteerablePage, url)
  }

  async attach(): Promise<void> {
    this.wc.debugger.attach('1.3')
  }

  detach(): void {
    if (this.wc.debugger.isAttached()) this.wc.debugger.detach()
  }

  isAttached(): boolean {
    return this.wc.debugger.isAttached()
  }

  async send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>> {
    // The one debugger door. Screening happens in the driver's `send()`, before
    // this is ever called — see the class header.
    const result = (await this.wc.debugger.sendCommand(method, params)) as unknown
    return typeof result === 'object' && result !== null ? (result as Record<string, unknown>) : {}
  }

  onEvent(handler: (method: string, params: Record<string, unknown>) => void): () => void {
    const listener = (_event: unknown, method: string, params: unknown): void => {
      handler(
        method,
        typeof params === 'object' && params !== null ? (params as Record<string, unknown>) : {},
      )
    }
    this.wc.debugger.on('message', listener)
    return () => {
      try {
        this.wc.debugger.off('message', listener)
      } catch {
        // The page is gone and took its emitter with it. Nothing to remove.
      }
    }
  }

  runInIsolatedWorld<T>(code: string): Promise<T> {
    // The one read door. The code is composed by the driver from a
    // `browser-drive-script.ts` string and JSON args; there is no path from a
    // model's text to page JavaScript.
    return this.wc.executeJavaScriptInIsolatedWorld(DRIVE_WORLD, [{ code }]) as Promise<T>
  }

  async capture(): Promise<RawFrame> {
    const image = await this.wc.capturePage()
    const size = image.getSize()
    return {
      data: bgraToRgba(image.toBitmap()),
      width: size.width,
      height: size.height,
      // `getSize()` and the bitmap are both at device resolution here, so the
      // buffer already is what it is; the CSS scale that places a mask is
      // re-derived from the viewport in `browser-png.ts`, never from this.
      scale: 1,
    }
  }

  isLoading(): boolean {
    return this.wc.isLoading()
  }

  onSettled(handler: () => void): () => void {
    const onStop = (): void => handler()
    this.wc.on('did-stop-loading', onStop)
    this.wc.on('did-fail-load', onStop)
    return () => {
      this.wc.off('did-stop-loading', onStop)
      this.wc.off('did-fail-load', onStop)
    }
  }

  onGone(handler: () => void): () => void {
    const fn = (): void => handler()
    this.wc.on('render-process-gone', fn)
    return () => {
      try {
        this.wc.off('render-process-gone', fn)
      } catch {
        // Already gone. Nothing to remove.
      }
    }
  }

  onDetached(handler: () => void): () => void {
    const fn = (): void => handler()
    this.wc.debugger.on('detach', fn)
    return () => {
      try {
        this.wc.debugger.off('detach', fn)
      } catch {
        // Already gone. Nothing to remove.
      }
    }
  }

  onDestroyed(key: string, handler: () => void): void {
    // Through the shared registry so eleven modules watching one WebContents do
    // not become eleven listeners — see `web-contents-teardown.ts`.
    onWebContentsDestroyed(this.wc, key, handler)
  }

  watchBlocks(deps: BlockWatchDeps): void {
    attachBlockWatch(this.wc, deps)
  }
}

/**
 * The stable {@link DrivenPage} for a WebContents, one wrapper per contents.
 *
 * Memoized because the driver's `watch()` guards against attaching its
 * once-per-page listeners twice by holding the page in a `WeakSet` — which only
 * works if the same page object comes back for the same tab. `browserTabContents`
 * hands back the one live `WebContents` for a tab, so keying the map on it gives
 * one `ElectronDrivenPage` per tab, for as long as the tab lives, and lets both
 * go together when it does.
 */
const wrappers = new WeakMap<WebContents, DrivenPage>()

export function electronDrivenPage(wc: WebContents): DrivenPage {
  const existing = wrappers.get(wc)
  if (existing) return existing
  const page = new ElectronDrivenPage(wc)
  wrappers.set(wc, page)
  return page
}

/**
 * Mask the secret rectangles out of an Electron capture and hand back the PNG.
 *
 * The person-side arming in `browser-profile-arm.ts` captures a page with
 * `wc.capturePage()` and needs the exact same redaction the drive applies. It
 * has a `NativeImage`, not a {@link RawFrame}, so this adapts one to the other —
 * the masking and encoding themselves are `browser-png.ts`'s, shared with the
 * driver so there is one spelling of "paint the password fields out".
 */
export function maskRects(
  image: NativeImage,
  rects: ReadonlyArray<{ x: number; y: number; width: number; height: number }>,
  viewport: { width: number; height: number },
): { png: Buffer; painted: number } {
  const size = image.getSize()
  const frame: RawFrame = {
    data: bgraToRgba(image.toBitmap()),
    width: size.width,
    height: size.height,
    scale: 1,
  }
  return maskFrame(frame, rects, viewport)
}
