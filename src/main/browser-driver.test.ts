import { describe, expect, it } from 'vitest'
import { BrowserDrive, boundKey, describeStep } from './browser-driver'

/**
 * The parts of the driver a test can hold still.
 *
 * The actionability loop, the input dispatch and the isolated-world reads are
 * all facts about a live page, and they are exercised against real websites by
 * `scripts/check-browser-drive.mjs`. What is here is what the driver decides
 * without a page: how it labels a step, and how it lets go of a window the
 * person disconnected.
 *
 * Nothing here needs Electron mocked. The driver stopped importing it when the
 * `DrivenPage` seam was extracted — the Electron half lives in
 * `browser-driven-electron.ts`, and the PNG masking, which used to sit here, is
 * `browser-png.ts`'s and is tested in `browser-png.test.ts`.
 */

describe('what the person sees the drive doing', () => {
  it('names the element the way it is labelled on screen', () => {
    // The only feedback a driven click has: CDP input does not move the OS
    // pointer, and nothing HTML can be drawn over a WebContentsView, so there
    // is no cursor to watch.
    expect(describeStep('click', 'Sign in', '#go')).toBe('clicking “Sign in”')
    expect(describeStep('type', 'Email', 'input#email')).toBe('typing into “Email”')
    expect(describeStep('submit', '', 'form#login')).toBe('submitting form#login')
  })

  it('falls back to the selector when the element has no name', () => {
    expect(describeStep('click', '   ', 'button.icon')).toBe('clicking button.icon')
  })
})

/**
 * Disconnect, from the driver's end.
 *
 *   > *"we should be have a button here to disconnect also, or it should only
 *   > this way."*
 *
 * "Only this way" is what these pin. The relation and the drive are two objects
 * in two modules, and the control is meant to be one act: `browser-binding-ipc`
 * ends the binding and calls in here with the shell tab id, which is the only
 * handle it has. So the key that files a window's slot has to be one spelling
 * and it has to be reachable from a shell tab id alone.
 */
describe('letting go of a window the person disconnected', () => {
  /** Enough `DriveHost` to hold a slot. Nothing here opens or steers a page. */
  const host = {
    openTab: async () => null,
    contentsFor: () => null,
    publish: () => undefined,
    now: () => 1_000,
  }

  const target = (browserTabId: string) => ({
    key: boundKey(browserTabId),
    viewId: `view:${browserTabId}`,
    browserTabId,
    name: 'B1',
  })

  it('files a window under one key, spelled in one place', () => {
    // `browser-tools.ts` mints its targets with this, and `releaseWindow` looks
    // them up with it. Two copies is a drive that keeps running under a key
    // nobody matched.
    expect(boundKey('browser:1:1')).toBe('bound:browser:1:1')
  })

  it('forgets what that window had been granted', () => {
    const drive = new BrowserDrive(host)
    const window = target('browser:1:1')
    drive.noteOriginGranted('https://app.example.com', window)
    expect(drive.originGranted('https://app.example.com', window)).toBe(true)

    drive.releaseWindow('browser:1:1')

    // A window that is nobody's carries nobody's permission. Reconnecting it
    // asks again, which is the point of the control being the truth.
    expect(drive.originGranted('https://app.example.com', window)).toBe(false)
    expect(drive.driving()).toEqual([])
  })

  it('leaves every other window alone', () => {
    const drive = new BrowserDrive(host)
    drive.noteOriginGranted('https://a.example.com', target('browser:1:1'))
    drive.noteOriginGranted('https://b.example.com', target('browser:1:2'))

    drive.releaseWindow('browser:1:1')

    expect(drive.originGranted('https://b.example.com', target('browser:1:2'))).toBe(true)
  })

  it('says nothing about a window it was never holding', () => {
    // The ordinary case: disconnecting a window no agent has ever driven.
    const drive = new BrowserDrive(host)
    expect(() => drive.releaseWindow('browser:9:9')).not.toThrow()
  })
})

/**
 * The cast, wired through the driver (wave-3).
 *
 * The screencast mechanics — backpressure, masking, coordinate mapping — are
 * exercised on the `PageCast` directly in `browser-watch.test.ts`. What is here
 * is the glue the driver owns: that `startCast` claims an idle page and streams
 * its `Page.screencastFrame` events through to the watcher, and that a handover
 * curtains the cast at the source before the baton flips.
 */
describe('the driver casts a page and curtains it on handover', () => {
  function fakePage() {
    let handler: ((method: string, params: Record<string, unknown>) => void) | null = null
    const sent: Array<{ method: string; params: Record<string, unknown> }> = []
    const page = {
      url: () => 'https://example.com/',
      title: () => 'Example',
      isGone: () => false,
      loadURL: async () => undefined,
      navigateGuarded: async () => 'navigated' as const,
      attach: async () => undefined,
      detach: () => undefined,
      isAttached: () => true,
      send: async (method: string, params: Record<string, unknown>) => {
        sent.push({ method, params })
        return {}
      },
      onEvent: (h: (method: string, params: Record<string, unknown>) => void) => {
        handler = h
        return () => {
          handler = null
        }
      },
      runInIsolatedWorld: async () => ({ rects: [], viewport: { width: 800, height: 600 } }),
      capture: async () => ({ width: 0, height: 0, rgba: Buffer.alloc(0) }),
      isLoading: () => false,
      onSettled: () => () => undefined,
      onGone: () => () => undefined,
      onDetached: () => () => undefined,
      onDestroyed: () => undefined,
      watchBlocks: () => undefined,
    }
    return { page, sent, fire: (method: string, params: Record<string, unknown>) => handler?.(method, params) }
  }

  function jpeg(width: number, height: number): string {
    return Buffer.from([
      0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08,
      (height >> 8) & 0xff, height & 0xff, (width >> 8) & 0xff, width & 0xff,
      0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xd9,
    ]).toString('base64')
  }

  const target = { key: boundKey('t1'), viewId: 'v1', browserTabId: 't1', name: 'B1' }

  function frame(scrollY = 0) {
    return {
      data: jpeg(800, 600),
      sessionId: 3,
      metadata: { offsetTop: 0, pageScaleFactor: 1, deviceWidth: 800, deviceHeight: 600, scrollOffsetX: 0, scrollOffsetY: scrollY },
    }
  }

  it('claims an idle page, streams a frame, and stops the cast when the watcher leaves', async () => {
    const fp = fakePage()
    const drive = new BrowserDrive({
      openTab: async () => null,
      contentsFor: () => fp.page as never,
      publish: () => undefined,
      now: () => 1_000,
    })
    const frames: Array<{ seq: number; data: string; masked?: true }> = []
    const res = await drive.startCast({
      target,
      watcherId: 'w1',
      window: 'B1',
      options: { maxWidth: 800, quality: 50 },
      emit: (f) => frames.push({ seq: f.seq, data: f.data, masked: f.masked }),
    })
    expect(res.ok).toBe(true)
    expect(fp.sent.some((s) => s.method === 'Page.startScreencast')).toBe(true)

    fp.fire('Page.screencastFrame', frame())
    expect(frames).toHaveLength(1)
    expect(frames[0].masked).toBeUndefined()
    expect(frames[0].data.length).toBeGreaterThan(0)

    await drive.stopCast(target, 'w1')
    expect(fp.sent.some((s) => s.method === 'Page.stopScreencast')).toBe(true)
  })

  it('curtains every watcher of a page when the person is handed it', async () => {
    const fp = fakePage()
    const drive = new BrowserDrive({
      openTab: async () => null,
      contentsFor: () => fp.page as never,
      publish: () => undefined,
      now: () => 1_000,
    })
    const frames: Array<{ masked?: true; prompt?: string; data: string }> = []
    await drive.startCast({
      target,
      watcherId: 'w1',
      window: 'B1',
      options: { maxWidth: 800, quality: 50 },
      emit: (f) => frames.push({ masked: f.masked, prompt: f.prompt, data: f.data }),
    })
    fp.fire('Page.screencastFrame', frame())
    drive.ackCast(target, 'w1', 1)
    const before = frames.length

    // Hand the page to the person. The cast is curtained before the baton flips:
    // stopScreencast is sent, and a lock card is drawn.
    void drive.handover('Type your password here.', 5, target)
    await new Promise((r) => setTimeout(r, 0))
    expect(fp.sent.some((s) => s.method === 'Page.stopScreencast')).toBe(true)
    const curtain = frames[frames.length - 1]
    expect(frames.length).toBeGreaterThan(before)
    expect(curtain.masked).toBe(true)
    expect(curtain.data).toBe('')
    expect(curtain.prompt).toContain('password')
  })
})

/* --------------------------------------- when there is no page, say why not -- */

/**
 * The sentence a copilot is handed when `openTab` came back null.
 *
 * `openTab` returning null means two completely different things depending on
 * which host answered. On the desktop it means the window declined, and the
 * fixed sentence about Settings → Tools is true. On a **headless host** it
 * usually means Chromium could not start on that machine — and that sentence
 * then sends somebody to a Settings pane on a server with no window, while the
 * real answer, a list of missing packages and the command that installs them,
 * went to a banner the copilot never sees.
 */
describe('refusing to drive, with a reason', () => {
  const base = {
    contentsFor: () => null,
    publish: () => undefined,
    now: () => 1_000,
  }

  it('repeats the host reason verbatim when the host has one', async () => {
    const why =
      'Chromium was downloaded and verified, but it cannot run on this machine yet: 13 shared ' +
      'libraries it needs are missing — libatk-1.0.so.0. Install them with: sudo apt-get install -y libatk1.0-0t64'
    const drive = new BrowserDrive({ ...base, openTab: async () => null, whyNoTab: () => why })
    await expect(drive.open({ url: 'https://example.com', isolate: false })).rejects.toThrow(
      /libatk1\.0-0t64/,
    )
    await expect(drive.open({ url: 'https://example.com', isolate: false })).rejects.toThrow(
      /could not be started/,
    )
  })

  it('keeps the window sentence for a host that does not know why', async () => {
    const drive = new BrowserDrive({ ...base, openTab: async () => null })
    await expect(drive.open({ url: 'https://example.com', isolate: false })).rejects.toThrow(
      /Settings → Tools/,
    )
  })

  it('keeps it too when the host has nothing to say this time', async () => {
    const drive = new BrowserDrive({ ...base, openTab: async () => null, whyNoTab: () => null })
    await expect(drive.open({ url: 'https://example.com', isolate: false })).rejects.toThrow(
      /Settings → Tools/,
    )
  })
})
