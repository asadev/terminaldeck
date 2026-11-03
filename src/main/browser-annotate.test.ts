import { describe, expect, it, vi } from 'vitest'
import { GUEST_PICK_AT_CHANNEL, GUEST_PICKED_CHANNEL } from './browser-preload'

/**
 * The main half of Annotate's later picks in the browser.
 *
 * The page is faked down to what the handler touches: an id, a zoom, an
 * address, a main frame, and a `send` that the test answers on the guest's
 * behalf. Everything about *describing* the element is the guest preload's and
 * `selector.ts`'s, and has its own tests; what is checked here is the round
 * trip — the point is divided by the zoom, the answer is matched by its nonce
 * and only from the page that was asked, and a page that says nothing does not
 * hang the window.
 */

const mainFrame = { name: 'main' }
const page = {
  id: 7,
  isDestroyed: () => false,
  getZoomFactor: () => 0.8,
  getURL: () => 'https://shop.example/',
  mainFrame,
  sent: [] as Array<{ channel: string; request: { x: number; y: number; nonce: string } }>,
  answer: null as null | ((request: { x: number; y: number; nonce: string }) => unknown),
  send(channel: string, request: { x: number; y: number; nonce: string }) {
    this.sent.push({ channel, request })
    const reply = this.answer?.(request)
    if (reply !== undefined) setTimeout(() => guestSays(reply, this), 1)
  },
}

vi.mock('./browser-tab', () => ({
  browserTabContents: (id: unknown) => (id === 'tab-1' ? page : null),
  readCaptureRect: (raw: unknown) => raw,
}))

const handlers = new Map<string, (...args: unknown[]) => unknown>()
const listeners = new Map<string, (...args: unknown[]) => void>()
const ipcMain = {
  handle: (channel: string, fn: (...args: unknown[]) => unknown) => void handlers.set(channel, fn),
  on: (channel: string, fn: (...args: unknown[]) => void) => void listeners.set(channel, fn),
}

function guestSays(payload: unknown, from: { id: number; mainFrame: unknown } = page, frame: unknown = mainFrame): void {
  listeners.get(GUEST_PICKED_CHANNEL)?.({ sender: from, senderFrame: frame }, payload)
}

const { registerBrowserAnnotateIpc } = await import('./browser-annotate')
registerBrowserAnnotateIpc(ipcMain as never)
const pick = (tab: unknown, x: unknown, y: unknown): Promise<unknown> =>
  handlers.get('browser:annotate-pick')?.({}, tab, x, y) as Promise<unknown>

const BUTTON = {
  v: 1,
  path: [{ tag: 'button', id: 'pay', idUnique: true, ofTypeCount: 1, nthOfType: 1 }],
  text: 'Pay now',
  attributes: {},
  rect: { x: 10, y: 20, width: 100, height: 30 },
}

describe('which element is under a point of the frozen page', () => {
  it('asks the page in its own CSS pixels and answers a capture', async () => {
    page.answer = (request) => ({ ...BUTTON, nonce: request.nonce })
    const capture = (await pick('tab-1', 80, 40)) as Record<string, unknown>
    // 80 view pixels on a page zoomed to 0.8 is 100 CSS pixels.
    expect(page.sent.at(-1)?.channel).toBe(GUEST_PICK_AT_CHANNEL)
    expect(page.sent.at(-1)?.request.x).toBeCloseTo(100)
    expect(page.sent.at(-1)?.request.y).toBeCloseTo(50)
    expect(capture.selector).toBe('#pay')
    expect(capture.url).toBe('https://shop.example/')
    expect(capture.rect).toEqual({ x: 10, y: 20, width: 100, height: 30 })
  })

  it('answers null for a point on nothing', async () => {
    page.answer = (request) => ({ v: 1, nonce: request.nonce, none: true })
    expect(await pick('tab-1', 1, 1)).toBeNull()
  })

  it('ignores an answer from a frame inside the page, and gives up rather than hang', async () => {
    page.answer = (request) => {
      setTimeout(() => guestSays({ ...BUTTON, nonce: request.nonce }, page, { name: 'ad-frame' }), 1)
      return undefined
    }
    const started = Date.now()
    expect(await pick('tab-1', 1, 1)).toBeNull()
    expect(Date.now() - started).toBeGreaterThanOrEqual(1_900)
  }, 5_000)

  it('refuses a tab that is gone and a point that is not a number', async () => {
    expect(await pick('tab-9', 1, 1)).toBeNull()
    expect(await pick('tab-1', 'left', 1)).toBeNull()
  })
})
