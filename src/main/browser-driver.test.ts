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

  /**
   * The whole round trip, over the driver: the copilot asks for a person, a phone
   * says *that person is me*, types, and hands the page back.
   *
   * `browser-watch.test.ts` pins the masking and the two doors on the cast
   * itself. What is here is the glue the driver owns — that a take is refused
   * unless a handover is actually outstanding, that `handBackHandover` routes
   * into the same `resume` the desktop banner calls rather than a second copy of
   * it, and that the agent is refused for the whole of it.
   */
  function driveWithTwoWatchers() {
    const fp = fakePage()
    const drive = new BrowserDrive({
      openTab: async () => null,
      contentsFor: () => fp.page as never,
      publish: () => undefined,
      now: () => 1_000,
    })
    const phone: Array<{ seq: number; masked?: true; prompt?: string; data: string }> = []
    const laptop: Array<{ seq: number; masked?: true; prompt?: string; data: string }> = []
    return { fp, drive, phone, laptop }
  }

  async function bothWatching(rig: ReturnType<typeof driveWithTwoWatchers>) {
    await rig.drive.startCast({
      target,
      watcherId: 'phone',
      window: 'B1',
      options: { maxWidth: 800, quality: 50 },
      emit: (f) => rig.phone.push({ seq: f.seq, masked: f.masked, prompt: f.prompt, data: f.data }),
    })
    await rig.drive.startCast({
      target,
      watcherId: 'laptop',
      window: 'B1',
      options: { maxWidth: 800, quality: 50 },
      emit: (f) => rig.laptop.push({ seq: f.seq, masked: f.masked, prompt: f.prompt, data: f.data }),
    })
  }

  it('lets the phone being asked answer, and keeps the agent shut out while it does', async () => {
    const rig = driveWithTwoWatchers()
    await bothWatching(rig)

    // Nothing to take before anything is asked.
    expect(await rig.drive.takeHandover(target, 'phone')).toMatchObject({ ok: false })
    expect(rig.drive.handoverHolding(target)).toEqual({ asking: false, prompt: '', taker: null })

    const asked = rig.drive.handover('Sign in and then press Done.', 60_000, target)
    await new Promise((r) => setTimeout(r, 0))
    expect(rig.drive.handoverHolding(target)).toMatchObject({ asking: true, taker: null })
    expect(rig.drive.handoverHolding(target).prompt).toContain('Sign in')

    expect(await rig.drive.takeHandover(target, 'phone')).toEqual({ ok: true })
    expect(rig.drive.handoverHolding(target).taker).toBe('phone')
    // A second watcher of the same page cannot take it out from under them.
    expect(await rig.drive.takeHandover(target, 'laptop')).toMatchObject({ ok: false })

    // The taker sees the page; the other watcher does not.
    rig.drive.ackCast(target, 'phone', rig.phone[rig.phone.length - 1].seq)
    rig.drive.ackCast(target, 'laptop', rig.laptop[rig.laptop.length - 1].seq)
    rig.fp.fire('Page.screencastFrame', frame())
    expect(rig.phone[rig.phone.length - 1].masked).toBeUndefined()
    expect(rig.phone[rig.phone.length - 1].data.length).toBeGreaterThan(0)
    expect(rig.laptop[rig.laptop.length - 1].masked).toBe(true)

    // The taker types and it reaches the page; the other watcher's tap does not.
    const typed = await rig.drive.castInput(target, 'phone', {
      t: 'browser.input',
      window: 'B1',
      seq: rig.phone[rig.phone.length - 1].seq,
      paste: 'hunter2',
    })
    expect(typed.ok).toBe(true)
    expect(rig.fp.sent.filter((s) => s.method === 'Input.insertText')).toHaveLength(1)
    const refused = await rig.drive.castInput(target, 'laptop', {
      t: 'browser.input',
      window: 'B1',
      seq: 1,
      mouse: { type: 'down', x: 10, y: 10 },
    })
    expect(refused.ok).toBe(false)
    expect(rig.fp.sent.filter((s) => s.method === 'Input.dispatchMouseEvent')).toHaveLength(0)

    /*
     * And the agent, throughout. The baton never left `human`, so every verb it
     * has is still refused at the mechanism — which is the property the taker was
     * built not to touch.
     */
    await expect(rig.drive.outline(20, 200, target)).rejects.toThrow()
    await expect(rig.drive.probe('#password', target)).rejects.toThrow()

    // Done, carry on: the baton comes back and the blocked call reports `resumed`.
    expect(await rig.drive.handBackHandover(target, 'phone', true)).toEqual({ ok: true })
    expect((await asked).outcome).toBe('resumed')
    expect(rig.drive.handoverHolding(target)).toEqual({ asking: false, prompt: '', taker: null })
    expect(rig.drive.status().state).toBe('agent')

    // The curtain is off for everybody, not only for whoever had taken it.
    rig.drive.ackCast(target, 'laptop', rig.laptop[rig.laptop.length - 1].seq)
    rig.fp.fire('Page.screencastFrame', frame())
    expect(rig.laptop[rig.laptop.length - 1].masked).toBeUndefined()
  })

  it('refuses a hand-back from a watcher that is not the one holding it', async () => {
    /*
     * The one that would be quiet and wrong. Two phones on one page: without this
     * the second could press Done on behalf of the person halfway through typing
     * a password, and the agent would resume driving a half-filled form.
     */
    const rig = driveWithTwoWatchers()
    await bothWatching(rig)
    const asked = rig.drive.handover('Sign in and then press Done.', 60_000, target)
    await new Promise((r) => setTimeout(r, 0))
    await rig.drive.takeHandover(target, 'phone')

    const stolen = await rig.drive.handBackHandover(target, 'laptop', true)
    expect(stolen.ok).toBe(false)
    expect(stolen.reason).toContain('not yours to hand back')
    // Nothing moved: the question is still outstanding and still theirs.
    expect(rig.drive.handoverHolding(target)).toMatchObject({ asking: true, taker: 'phone' })
    expect(rig.drive.status().state).toBe('human')

    await rig.drive.handBackHandover(target, 'phone', true)
    expect((await asked).outcome).toBe('resumed')
  })

  it('ends the drive when the answer is “stop, I’ll take it from here”', async () => {
    /*
     * `carryOn: false` is a refusal to the agent rather than a resume, which is
     * why it releases the slot instead of returning the baton. Routed into the
     * same `resume(false)` the desktop banner calls — a second copy of that
     * sequence here is how the two halves come to disagree about what Done means.
     */
    const rig = driveWithTwoWatchers()
    await bothWatching(rig)
    const asked = rig.drive.handover('Sign in and then press Done.', 60_000, target)
    await new Promise((r) => setTimeout(r, 0))
    await rig.drive.takeHandover(target, 'phone')

    expect(await rig.drive.handBackHandover(target, 'phone', false)).toEqual({ ok: true })
    expect((await asked).outcome).toBe('stopped')
    expect(rig.drive.status().state).toBe('idle')
    expect(rig.drive.handoverHolding(target)).toEqual({ asking: false, prompt: '', taker: null })
  })

  it('curtains a watcher that arrives after the person was handed the page', async () => {
    /*
     * A phone that reconnected mid-handover, or one that rotated. It used to be
     * refused outright — *"the person has this page right now"*, said to the one
     * screen the question was for — which threw the handover away on a rotation
     * and left a reconnecting phone unable to see or answer it.
     */
    const rig = driveWithTwoWatchers()
    const asked = rig.drive.handover('Type the code from your phone.', 60_000, target)
    await new Promise((r) => setTimeout(r, 0))

    const late: Array<{ masked?: true; prompt?: string; data: string }> = []
    const result = await rig.drive.startCast({
      target,
      watcherId: 'phone',
      window: 'B1',
      options: { maxWidth: 800, quality: 50 },
      emit: (f) => late.push({ masked: f.masked, prompt: f.prompt, data: f.data }),
    })
    expect(result.ok).toBe(true)
    // It gets the question, drawn as a lock card — not pixels, and not silence.
    expect(late).toHaveLength(1)
    expect(late[0].masked).toBe(true)
    expect(late[0].data).toBe('')
    expect(late[0].prompt).toContain('Type the code')
    // …and it can now answer it, which is the entire point of letting it watch.
    expect(await rig.drive.takeHandover(target, 'phone')).toEqual({ ok: true })
    await rig.drive.handBackHandover(target, 'phone', true)
    expect((await asked).outcome).toBe('resumed')
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
