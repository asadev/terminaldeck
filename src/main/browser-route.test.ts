import { beforeEach, describe, expect, it } from 'vitest'
import { attach, resetForTests } from './browser-binding'
import { routeOpen, type OpenedReply, type RouteDeps, type SteerablePage } from './browser-route'

/**
 * Where a URL goes, and the sentence that comes back with it.
 *
 * Both halves are pinned together on purpose. The route is what the shim acts
 * on and the sentence is what an agent reads, and an answer that routes
 * correctly while saying the wrong thing is worse than one that fails: Claude
 * maps exit 0 to success, so a `tab` answer with nothing behind it has the model
 * believing a page is on screen that nobody can see.
 */

/** A page that navigates without complaint. */
function willingPage(record: string[]): SteerablePage {
  return {
    isDestroyed: () => false,
    loadURL: (url: string) => {
      record.push(url)
      return Promise.resolve(null)
    },
    once: () => undefined,
    off: () => undefined,
  }
}

/** A page whose own `beforeunload` asks to keep its document. */
function busyPage(record: string[]): SteerablePage {
  let refuse: ((event: { preventDefault(): void }) => void) | null = null
  return {
    isDestroyed: () => false,
    loadURL: (url: string) => {
      record.push(url)
      // Electron reports the page's refusal on the same turn the navigation is
      // attempted, which is what makes this decision the page's own rather than
      // a guess about the URL.
      refuse?.({ preventDefault: () => undefined })
      return Promise.reject(new Error('ERR_ABORTED'))
    },
    once: (_event, listener) => {
      refuse = listener
      return undefined
    },
    off: () => {
      refuse = null
      return undefined
    },
  }
}

function deps(over: Partial<RouteDeps> = {}): RouteDeps {
  return {
    pageFor: () => null,
    knowsSession: () => true,
    openWindow: (): Promise<OpenedReply> => Promise.resolve({ tabId: 'browser:new:1' }),
    ...over,
  }
}

beforeEach(() => {
  resetForTests()
})

describe('a URL from a session', () => {
  it('lands in the lowest-numbered window and names it', async () => {
    const navigated: string[] = []
    attach({ sessionId: 's1', browserTabId: 'a', viewId: 'view-a' })
    attach({ sessionId: 's1', browserTabId: 'b', viewId: 'view-b' })

    const answer = await routeOpen(
      { url: 'https://example.com/', sessionId: 's1' },
      deps({ pageFor: (id) => (id === 'view-a' ? willingPage(navigated) : null) }),
    )

    expect(answer).toEqual({ route: 'tab', line: 'Opened in B1 — Terminal Deck.' })
    expect(navigated).toEqual(['https://example.com/'])
  })

  it('opens a window and says it is new when the session has none', async () => {
    const asked: Array<{ n: number }> = []
    const answer = await routeOpen(
      { url: 'https://example.com/', sessionId: 's1' },
      deps({
        openWindow: (request) => {
          asked.push({ n: request.n })
          return Promise.resolve({ tabId: 'browser:1:1' })
        },
      }),
    )

    // The number is reserved before the window is asked for, so the sentence and
    // the window that arrives cannot disagree.
    expect(asked).toEqual([{ n: 1 }])
    expect(answer).toEqual({
      route: 'tab',
      line: 'Opened in B1 — Terminal Deck (new window, attached to this session).',
    })
  })

  it('leaves a page that says it has unfinished work alone, and opens another', async () => {
    const navigated: string[] = []
    attach({ sessionId: 's1', browserTabId: 'a', viewId: 'view-a' })

    const answer = await routeOpen(
      { url: 'https://example.com/next', sessionId: 's1' },
      deps({ pageFor: () => busyPage(navigated) }),
    )

    // His rule, read literally: *"it depends if the thing is done and saved…"*
    // The page is the only thing that knows, and this is the page saying so.
    expect(answer.route).toBe('tab')
    expect(answer.line).toContain('B2')
  })

  it('goes to the machine for an id this app never started', async () => {
    const answer = await routeOpen(
      { url: 'https://example.com/', sessionId: 'stranger' },
      deps({ knowsSession: () => false }),
    )

    expect(answer.route).toBe('system')
    expect(answer.line).toContain('default browser')
  })

  it('goes to the machine when the window refuses, in the window’s own words', async () => {
    const answer = await routeOpen(
      { url: 'https://example.com/', sessionId: 's1' },
      deps({ openWindow: () => Promise.resolve({ refused: 'the browser is switched off' }) }),
    )

    expect(answer).toEqual({ route: 'system', line: 'the browser is switched off' })
  })

  it('opens a second window when one is asked for outright', async () => {
    const navigated: string[] = []
    attach({ sessionId: 's1', browserTabId: 'a', viewId: 'view-a' })

    const answer = await routeOpen(
      { url: 'https://example.com/', sessionId: 's1', newWindow: true },
      deps({ pageFor: () => willingPage(navigated) }),
    )

    expect(navigated, 'the attached window must not be touched').toEqual([])
    expect(answer.line).toContain('B2')
  })
})
