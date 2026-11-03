import { beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * Where a link opens, pinned from both sides of the trust boundary.
 *
 * The behaviour these cases hold down is the one Asad asked for on 2026-08-17 —
 * *"currently it's opening a separate window — I want it to use the same window
 * inside Terminal Deck for browser"* — plus the thing that must NOT come with
 * it: a website talking the main process into `shell.openExternal('file://…')`.
 *
 * Written against a mocked `electron` because the module has to reach `shell`,
 * `Menu` and `clipboard`, and because a test that really popped a menu would
 * block the run on a native modal.
 */

const opened: string[] = []
const copied: string[] = []
const popped: Array<{ items: FakeItem[]; window: unknown }> = []
const handlers = new Map<string, (event: unknown, ...args: unknown[]) => unknown>()

interface FakeItem {
  label: string
  click?: () => void
}

let fromWebContents: unknown = { isDestroyed: () => false }

vi.mock('electron', () => ({
  shell: {
    openExternal: (url: string) => {
      opened.push(url)
      return Promise.resolve()
    },
  },
  clipboard: { writeText: (text: string) => copied.push(text) },
  Menu: {
    buildFromTemplate: (template: FakeItem[]) => ({
      popup: ({ window }: { window: unknown }) => popped.push({ items: template, window }),
    }),
  },
  BrowserWindow: { fromWebContents: () => fromWebContents },
  ipcMain: {
    handle: (channel: string, listener: (event: unknown, ...args: unknown[]) => unknown) => {
      handlers.set(channel, listener)
    },
  },
}))

const {
  LINK_TAB_CHANNEL,
  canOpenOutside,
  openAppLink,
  openGuestLink,
  openSystemUrl,
  registerLinkIpc,
  routeAppLink,
  routeGuestLink,
  showLinkMenu,
} = await import('./link-open')
const { ipcMain } = await import('electron')

/** A renderer that records what was pushed at it. */
function fakeHost(destroyed = false) {
  const sent: Array<{ channel: string; args: unknown[] }> = []
  return {
    sent,
    contents: {
      isDestroyed: () => destroyed,
      send: (channel: string, ...args: unknown[]) => sent.push({ channel, args }),
    },
  }
}

beforeEach(() => {
  opened.length = 0
  copied.length = 0
  popped.length = 0
  handlers.clear()
  fromWebContents = { isDestroyed: () => false }
})

describe('a link from the app’s own renderer', () => {
  it('opens http and https inside, in a tab of this app', () => {
    expect(routeAppLink('https://github.com/cli/cli/pull/1')).toBe('tab')
    expect(routeAppLink('http://localhost:3000/')).toBe('tab')
  })

  /**
   * The regression this whole change exists for. Before it, `index.ts` denied
   * the window and called `shell.openExternal` for *everything*, so a pull
   * request opened Chrome.
   */
  it('pushes an https link at the renderer instead of launching a browser', () => {
    const host = fakeHost()
    expect(openAppLink(host.contents as never, 'https://github.com/cli/cli')).toBe('tab')
    // An object rather than a bare string since 2026-08-19: the same channel now
    // also carries which session a URL came from, so that a link out of a
    // session can land in the browser window attached to it. A link from the
    // GitHub panel belongs to no session and says so by omission.
    expect(host.sent).toEqual([
      { channel: LINK_TAB_CHANNEL, args: [{ url: 'https://github.com/cli/cli' }] },
    ])
    expect(opened, 'an https link must not reach the system browser').toEqual([])
  })

  it('still sends out what this app cannot render', () => {
    // The app's own code asking for these means it: a mail composer, a Finder
    // reveal, another app's URL scheme.
    expect(routeAppLink('mailto:someone@example.com')).toBe('system')
    expect(routeAppLink('file:///Users/apple/Downloads')).toBe('system')
    expect(routeAppLink('x-github-client://openRepo/x')).toBe('system')

    const host = fakeHost()
    expect(openAppLink(host.contents as never, 'mailto:someone@example.com')).toBe('system')
    expect(host.sent, 'a mailto: is not a page').toEqual([])
    expect(opened).toEqual(['mailto:someone@example.com'])
  })

  it('refuses script and in-process schemes rather than handing them to the OS', () => {
    // These arrive from a network response in the GitHub panel; a scheme check
    // is cheaper than trusting the JSON for ever.
    for (const url of [
      'javascript:alert(1)',
      'vbscript:msgbox(1)',
      'data:text/html,<script>1</script>',
      'blob:https://example.com/x',
      'chrome://settings',
      'devtools://devtools/bundled/x.html',
      'view-source:https://example.com',
      'relative/path',
      '',
    ]) {
      expect(routeAppLink(url), url).toBe('refused')
    }
    expect(openSystemUrl('javascript:alert(1)')).toBe(false)
    expect(opened).toEqual([])
  })

  it('says nothing to a renderer that has gone', () => {
    const host = fakeHost(true)
    expect(openAppLink(host.contents as never, 'https://example.com')).toBe('tab')
    expect(host.sent).toEqual([])
  })
})

describe('a link from an untrusted guest page', () => {
  /**
   * `target="_blank"` used to be answered with *"Blocked a pop-up to X."* over
   * the page. A website may not have a window of Chromium's — no address bar,
   * no navigation gate — but it may have a tab of ours.
   */
  it('opens http and https as a tab of this app', () => {
    const host = fakeHost()
    expect(openGuestLink(host.contents as never, 'https://example.com/x')).toBe('tab')
    expect(host.sent).toEqual([
      { channel: LINK_TAB_CHANNEL, args: [{ url: 'https://example.com/x' }] },
    ])
  })

  /**
   * The half that must never soften. `browser-tab.ts` refuses `file:` on
   * will-navigate, will-frame-navigate and will-redirect so a page cannot walk
   * the view onto the user's disk; a `window.open` that reached
   * `shell.openExternal` would step over all three at once.
   */
  it('never reaches the system browser, whatever the scheme', () => {
    for (const url of [
      'file:///etc/passwd',
      'mailto:someone@example.com',
      'x-github-client://openRepo/x',
      'javascript:alert(1)',
    ]) {
      expect(routeGuestLink(url), url).toBe('refused')
    }

    const host = fakeHost()
    expect(openGuestLink(host.contents as never, 'file:///etc/passwd')).toBe('refused')
    expect(host.sent).toEqual([])
    expect(opened, 'a website must not be able to open anything on the machine').toEqual([])
  })

  it('routes exactly what the browser’s own navigation gate allows', () => {
    // Stated as an equivalence rather than a list, so widening one without the
    // other is a failure here rather than a hole found later.
    for (const url of ['https://a.example/', 'http://b.example/', 'about:blank']) {
      expect(routeGuestLink(url), url).toBe('tab')
    }
  })
})

const labelsOf = (index = -1): string[] => (popped.at(index)?.items ?? []).map((item) => item.label)

/** Press a menu item by label, the way a click does. */
function press(label: string): void {
  const item = popped.at(-1)?.items.find((entry) => entry.label === label)
  expect(item, `no menu item labelled ${label}`).toBeDefined()
  item?.click?.()
}

describe('the way out', () => {
  it('offers to open the link in the system browser, and does', () => {
    expect(showLinkMenu({ isDestroyed: () => false } as never, 'https://example.com/page')).toBe(true)
    expect(popped).toHaveLength(1)
    expect(labelsOf()).toEqual(['Open in System Browser', 'Copy Link'])

    // The real click handler, not a copy written here — this is the whole
    // escape hatch, and it is the one thing in this feature that has to reach
    // `shell.openExternal` on purpose.
    press('Open in System Browser')
    expect(opened).toEqual(['https://example.com/page'])

    press('Copy Link')
    expect(copied).toEqual(['https://example.com/page'])
  })

  it('drops the open item for a scheme the machine cannot be given', () => {
    showLinkMenu({ isDestroyed: () => false } as never, 'about:blank')
    expect(labelsOf(), 'about:blank is not something to hand Launch Services').toEqual(['Copy Link'])
    expect(canOpenOutside('about:blank')).toBe(false)
    expect(canOpenOutside('https://example.com')).toBe(true)
  })

  it('does nothing without a window to pop over, or without a URL', () => {
    expect(showLinkMenu(null, 'https://example.com')).toBe(false)
    expect(showLinkMenu({ isDestroyed: () => true } as never, 'https://example.com')).toBe(false)
    expect(showLinkMenu({ isDestroyed: () => false } as never, '')).toBe(false)
    expect(popped).toEqual([])
  })
})

describe('the ipc channels', () => {
  it('answers link:system by opening on the machine', async () => {
    registerLinkIpc(ipcMain)
    const handler = handlers.get('link:system')
    expect(handler, 'link:system was not registered').toBeTypeOf('function')
    expect(await handler?.({}, 'https://example.com')).toBe(true)
    expect(opened).toEqual(['https://example.com'])
  })

  it('refuses link:system for a scheme that is not a document', async () => {
    registerLinkIpc(ipcMain)
    expect(await handlers.get('link:system')?.({}, 'javascript:alert(1)')).toBe(false)
    expect(opened).toEqual([])
  })

  it('answers link:menu by popping the menu over the sender’s window', async () => {
    registerLinkIpc(ipcMain)
    expect(await handlers.get('link:menu')?.({}, 'https://example.com')).toBe(true)
    expect(popped).toHaveLength(1)
  })

  it('says so rather than throwing when the sender has no window', async () => {
    registerLinkIpc(ipcMain)
    fromWebContents = null
    expect(await handlers.get('link:menu')?.({}, 'https://example.com')).toBe(false)
  })
})
