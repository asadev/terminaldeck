import { randomUUID } from 'node:crypto'
import type { IpcMain, IpcMainEvent } from 'electron'
import { readCaptureRect, browserTabContents } from './browser-tab'
import { GUEST_PICK_AT_CHANNEL, GUEST_PICKED_CHANNEL } from './browser-preload'
import { composeAgentContext, parseCapture } from './selector'

/**
 * Annotate in the browser: which element is under a point of a frozen page.
 *
 * ## Why this exists beside Inspect's click
 *
 * Annotate starts the way Inspect always did — the page is live, the element
 * under the pointer is outlined, and a click on it is captured with a
 * photograph of the page. From there it differs: the page stays frozen under
 * that photograph, and the person points at more things *on the photograph*,
 * each with its own note, before anything is sent. A photograph has no DOM, so
 * each of those later points is asked of the real page, which is still loaded
 * underneath and simply not being composited.
 *
 * The guest answers with the same description a click produces (see
 * `GUEST_PICK_AT_CHANNEL` in `browser-preload.ts`), and it is parsed here by the
 * same `parseCapture` — so the selector an agent is given for the second
 * element is built by exactly the rules that built the first.
 *
 * ## Units
 *
 * The window sends a point in the view's own pixels — what it measured the
 * photograph against. A page this app has zoomed out to fit
 * (`browser-fit.ts`) lays itself out in CSS pixels that are larger than that,
 * so the point is divided by the zoom factor before the page is asked. The
 * rectangle comes back in CSS pixels, the same unit a click's capture uses, so
 * the window converts both the same way.
 *
 * ## Channel
 *
 * - `browser:annotate-pick` (invoke, tabId, x, y) → the capture, or null for a
 *   point on nothing, a page that did not answer, or a tab that is gone.
 */

/** How long a page gets to answer. It is one `elementFromPoint`; a page that takes longer is busy. */
const ANSWER_MS = 2_000

interface Waiting {
  contentsId: number
  resolve(payload: unknown): void
}

export function registerBrowserAnnotateIpc(ipcMain: IpcMain): void {
  const waiting = new Map<string, Waiting>()

  ipcMain.on(GUEST_PICKED_CHANNEL, (event: IpcMainEvent, payload: unknown) => {
    const nonce =
      typeof payload === 'object' && payload !== null ? (payload as Record<string, unknown>).nonce : undefined
    if (typeof nonce !== 'string') return
    const entry = waiting.get(nonce)
    // Only from the contents that was asked, and only its top frame. A nonce is
    // unguessable, but an embedded frame answering for its parent would still
    // be a different page's element under the same address.
    if (!entry || entry.contentsId !== event.sender.id) return
    try {
      if (event.senderFrame === null || event.senderFrame !== event.sender.mainFrame) return
    } catch {
      return
    }
    waiting.delete(nonce)
    entry.resolve(payload)
  })

  ipcMain.handle('browser:annotate-pick', async (_event, tabId: unknown, x: unknown, y: unknown) => {
    const wc = browserTabContents(tabId)
    if (!wc || wc.isDestroyed()) return null
    if (typeof x !== 'number' || typeof y !== 'number' || !Number.isFinite(x) || !Number.isFinite(y)) return null
    const zoom = wc.getZoomFactor() || 1
    const nonce = randomUUID()
    const payload = await new Promise<unknown>((resolve) => {
      const timer = setTimeout(() => {
        waiting.delete(nonce)
        resolve(null)
      }, ANSWER_MS)
      waiting.set(nonce, {
        contentsId: wc.id,
        resolve: (value) => {
          clearTimeout(timer)
          resolve(value)
        },
      })
      wc.send(GUEST_PICK_AT_CHANNEL, { x: Math.max(0, x / zoom), y: Math.max(0, y / zoom), nonce })
    })
    if (payload === null || (payload as Record<string, unknown>).none === true) return null
    // The address from our own view, never the page's — the same rule the
    // click capture follows, for the same reason.
    const capture = parseCapture(payload, wc.getURL())
    if (!capture) return null
    return {
      ...capture,
      context: composeAgentContext(capture),
      pageImage: '',
      rect: readCaptureRect((payload as Record<string, unknown>).rect),
    }
  })
}
