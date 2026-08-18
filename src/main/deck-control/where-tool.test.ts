import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { ActionLog } from './action-log'
import { ConsentBroker } from './consent'
import { DeckControl } from './control'
import { LOCAL_CALLER, type Caller, type DeckSurface } from './surface'
import { PAGE_TEXT_CHARS, WHERE_CALL, readWhere, whereTool, type WherePage } from './where-tool'

/**
 * `app.where`, through the real dispatcher.
 *
 * The failure this tool exists to prevent is a **confident wrong answer** — the
 * copilot describing a screen it cannot see, because it was told in prose that
 * it could. So what is pinned here is mostly the negative space: what it says
 * when there is no window, what it says when there is no page, and that nothing
 * it returns is invented from a value it did not get.
 */

const SURFACE = {
  listSessions: () => [],
  listProjects: () => [],
  appStateRoot: () => '/state',
  copilotRoot: () => '/state/copilot',
  readSettings: () => ({ settings: {}, preferences: {} }),
} as unknown as DeckSurface

const LOCAL: Caller = LOCAL_CALLER

function build(options: { answer?: unknown; page?: WherePage | null } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'where-tool-'))
  const control = new DeckControl({
    surface: SURFACE,
    log: new ActionLog({ dir }),
    consent: new ConsentBroker({ ask: () => false, settled: () => undefined }),
    extraTools: [
      whereTool({
        window: { read: async () => options.answer },
        page: () => options.page ?? null,
      }),
    ],
  })
  return control
}

const WINDOW = {
  title: 'Fix the parser',
  sessionId: 's1',
  pane: 'terminal',
  copilotFront: false,
  driving: true,
  openSessions: ['s1', 's2'],
}

describe('answering "where am I"', () => {
  it('reads the window, not a guess', async () => {
    const result = await build({ answer: WINDOW }).call('app.where', {}, { caller: LOCAL })
    expect(result.ok).toBe(true)
    const value = result.value as { window: Record<string, unknown> }
    expect(value.window.inFront).toBe('Fix the parser')
    expect(value.window.pane).toBe('terminal')
    expect(value.window.sessionId).toBe('s1')
    expect(value.window.driving).toBe(true)
  })

  it('says there is no window rather than reporting a fault', async () => {
    /*
     * This app runs headless, and a copilot started before the first window
     * exists is a real state rather than a broken one. Throwing here would make
     * it report a fault where there is none — and a copilot that thinks the app
     * is broken says so, loudly, to somebody whose app is fine.
     */
    const result = await build({ answer: undefined }).call('app.where', {}, { caller: LOCAL })
    expect(result.ok).toBe(true)
    const value = result.value as { window: null; note: string }
    expect(value.window).toBeNull()
    expect(value.note).toContain('no window')
  })

  it('reads the driven page’s address and text when there is one', async () => {
    const page: WherePage = {
      status: () => ({ url: 'https://example.test/orders' }),
      textAt: async (selector, limit) => {
        // The whole page, not a fragment: "what am I looking at" is the page.
        expect(selector).toBeNull()
        expect(limit).toBe(PAGE_TEXT_CHARS)
        return { found: true, secret: false, text: 'Orders — 3 failed', truncated: false }
      },
    }
    const result = await build({ answer: WINDOW, page }).call('app.where', {}, { caller: LOCAL })
    const value = result.value as { page: { url: string; text: string } }
    expect(value.page.url).toBe('https://example.test/orders')
    expect(value.page.text).toBe('Orders — 3 failed')
  })

  it('withholds a page that is asking for a credential, and says why', async () => {
    /*
     * `secret` is the driver's own judgement — a credential field is on the page
     * — and it is honoured rather than second-guessed here. The URL still comes
     * back, because knowing *which* page somebody is on is the question that was
     * asked; the text is what would carry a password field's neighbours.
     */
    const page: WherePage = {
      status: () => ({ url: 'https://bank.test/login' }),
      textAt: async () => ({ found: true, secret: true, text: '', truncated: false }),
    }
    const result = await build({ answer: WINDOW, page }).call('app.where', {}, { caller: LOCAL })
    const value = result.value as { page: { url: string; text: string | null; why?: string } }
    expect(value.page.url).toBe('https://bank.test/login')
    expect(value.page.text).toBeNull()
    expect(value.page.why).toContain('credential')
  })

  it('says there is no page rather than describing one it cannot see', async () => {
    // The drivable browser owns one tab. The app's other tabs are separate
    // `WebContentsView`s, and reaching into an arbitrary one to lift its text is
    // a much larger grant than "tell me where I am" — the person may have their
    // bank open in the next one.
    const result = await build({ answer: WINDOW }).call('app.where', {}, { caller: LOCAL })
    expect((result.value as { page: null }).page).toBeNull()
  })

  it('is answerable from a paired device, because describing is not driving', async () => {
    /*
     * Driving is refused remotely because it *moves* somebody else's screen.
     * Describing it does not, and a phone asking "what is he looking at" is the
     * same question its own session list already answers in more detail.
     */
    const remote: Caller = {
      kind: 'remote',
      deviceId: 'phone-1',
      tiers: { read: true, act: false, alter: false },
    }
    const result = await build({ answer: WINDOW }).call('app.where', {}, { caller: remote })
    expect(result.ok).toBe(true)
  })
})

describe('the expression the window is asked', () => {
  it('cannot throw on a window that has not published its reader yet', () => {
    /*
     * `executeJavaScript` rejects on a thrown `ReferenceError`, and a window
     * mid-boot has not run `publishWhere()`. The optional call plus the `?? null`
     * is what turns that into the true answer — "nothing to look at yet" —
     * rather than a tool fault.
     */
    expect(WHERE_CALL).toContain('?.()')
    expect(WHERE_CALL).toContain('?? null')
  })
})

describe('narrowing what came back', () => {
  it('drops fields of the wrong shape rather than passing them on', () => {
    expect(readWhere({ title: 'api', sessionId: 42, pane: 'split' })).toEqual({
      title: 'api',
      sessionId: null,
      pane: null,
      copilotFront: false,
      driving: false,
      openSessions: [],
    })
  })

  it('refuses anything that is not an answer at all', () => {
    expect(readWhere(null)).toBeNull()
    expect(readWhere('somewhere')).toBeNull()
    expect(readWhere({})).toBeNull()
  })
})
