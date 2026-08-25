import { readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { describe, expect, it } from 'vitest'
import { boundKey, BrowserDrive, type DriveTarget } from './browser-driver'
import type { BrowserFrameFrame } from './remote/protocol'
import { frontTab, screencastOver, type CastDrive, type CastWindow } from './screencast-host'

/**
 * The live view, from the window name a phone sends to the click that lands on
 * the page — with nothing faked but the browser.
 *
 * The chain this exercises is the whole of what was missing: `screencastOver`
 * resolves a name to a slot, hands it to a **real** `BrowserDrive`, which makes
 * a **real** `PageCast`, which sends `Page.startScreencast` down a fake page and
 * turns its `Page.screencastFrame` events back into `browser.frame`s. Only the
 * page is a stand-in, which is the property that matters here: every layer
 * under this had a passing test before this feature was reachable at all, and
 * not one of them noticed that no host had ever passed a `screencast`.
 *
 * The fake page is deliberately a second copy of `browser-driver.test.ts`'s
 * rather than an export from it — the same argument
 * `session-drives-server-browser.test.ts` makes about sharing a CDP fake: a fake
 * shared between two files is a fake that grows a flag for one of them, and what
 * this file is about is what reaches the wire, not how convincingly it is
 * answered.
 *
 * What it cannot prove is that a real Chromium answers `Page.startScreencast`
 * with frames of the shape `readMetadata` accepts, and that a real
 * `WebContentsView` debugger delivers the event at all under Electron. Both are
 * the live lane's, on hardware. What is provable with no browser in the room is
 * that the name resolves to the right slot, the frames carry the name back, the
 * ack gates the next one, a tap reaches the page as CDP input, and a socket that
 * closed stops the screencast on the machine.
 */

/* ------------------------------------------------------------- fake page -- */

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
  return {
    page,
    sent,
    fire: (method: string, params: Record<string, unknown>) => handler?.(method, params),
    has: (method: string) => sent.some((entry) => entry.method === method),
    last: (method: string) => [...sent].reverse().find((entry) => entry.method === method),
  }
}

/** The smallest thing `jpegSize` reads a width and a height out of. */
function jpeg(width: number, height: number): string {
  return Buffer.from([
    0xff, 0xd8, 0xff, 0xc0, 0x00, 0x11, 0x08,
    (height >> 8) & 0xff, height & 0xff, (width >> 8) & 0xff, width & 0xff,
    0x03, 0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01, 0xff, 0xd9,
  ]).toString('base64')
}

function screencastFrame(scrollY = 0) {
  return {
    data: jpeg(800, 600),
    sessionId: 7,
    metadata: {
      offsetTop: 0,
      pageScaleFactor: 1,
      deviceWidth: 800,
      deviceHeight: 600,
      scrollOffsetX: 0,
      scrollOffsetY: scrollY,
    },
  }
}

/* -------------------------------------------------------------------- rig -- */

const PANE = 'browser:1755:3'
const TARGET: DriveTarget = {
  key: boundKey(PANE),
  viewId: 'view-1',
  browserTabId: PANE,
  name: 'B1',
}

/** One window open on the machine, over one fake page. */
function machine(windows?: () => readonly CastWindow[] | Promise<readonly CastWindow[]>) {
  const fp = fakePage()
  const drive = new BrowserDrive({
    openTab: async () => null,
    contentsFor: () => fp.page as never,
    publish: () => undefined,
    now: () => 1_000,
  })
  const host = screencastOver({
    drive,
    windows:
      windows ??
      (() => [
        { window: PANE, target: TARGET, url: 'https://example.com/', title: 'Example' },
      ]),
  })
  return { fp, drive, host }
}

/** Every frame one watcher was sent, in order. */
function sink(): { frames: BrowserFrameFrame[]; emit: (frame: BrowserFrameFrame) => void } {
  const frames: BrowserFrameFrame[] = []
  return { frames, emit: (frame) => frames.push(frame) }
}

/* ------------------------------------------------------------- the strip -- */

describe('the tab strip a phone is shown', () => {
  it('lists what the machine has open and says which of them is being cast', async () => {
    const { fp, host } = machine()
    const watcher = sink()

    const before = await host.surfaces()
    expect(before).toEqual([
      { window: PANE, url: 'https://example.com/', title: 'Example', live: false },
    ])

    await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 800,
      quality: 50,
      emit: watcher.emit,
    })
    expect(fp.has('Page.startScreencast')).toBe(true)

    // `live` is what draws the Stop control in the PWA and what tells a second
    // device the page is already on somebody's screen.
    expect(await host.surfaces()).toEqual([
      { window: PANE, url: 'https://example.com/', title: 'Example', live: true },
    ])
  })

  it('answers an empty strip rather than throwing when the machine has no browser', async () => {
    // A daemon whose Chromium never started: the shell's own window list throws
    // rather than answering. `browser.surfaces` still has to be answered — the
    // phone asked a question, and "nothing open" is the true answer here.
    const { host } = machine(() => {
      throw new Error('the browser on this machine could not be started')
    })
    expect(await host.surfaces()).toEqual([])
  })

  it('refuses a window that closed between the strip being drawn and the row being tapped', async () => {
    const { fp, host } = machine(() => [])
    const result = await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 800,
      quality: 50,
      emit: () => undefined,
    })
    expect(result.ok).toBe(false)
    expect(result.reason).toContain('not open on this machine any more')
    // And nothing was started on the machine on the strength of a name it does
    // not have.
    expect(fp.has('Page.startScreencast')).toBe(false)
  })
})

/* --------------------------------------------------------------- the cast -- */

describe('watching a window, and the backpressure that keeps a slow phone alive', () => {
  it('streams the page back under the name the phone asked for', async () => {
    const { fp, host } = machine()
    const watcher = sink()

    const result = await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 640,
      quality: 40,
      emit: watcher.emit,
    })
    expect(result.ok).toBe(true)
    expect(fp.last('Page.startScreencast')?.params).toMatchObject({
      format: 'jpeg',
      quality: 40,
      maxWidth: 640,
    })

    fp.fire('Page.screencastFrame', screencastFrame())

    expect(watcher.frames).toHaveLength(1)
    const frame = watcher.frames[0]
    // The `t` is the only thing this module adds. Everything else is the cast's
    // own — a frame rewritten on the way out is a frame whose geometry no longer
    // matches the one the viewer measures its next tap against.
    expect(frame.t).toBe('browser.frame')
    expect(frame.window).toBe(PANE)
    expect(frame.seq).toBe(1)
    expect(frame.w).toBe(800)
    expect(frame.dw).toBe(800)
    expect(frame.masked).toBeUndefined()
    expect(frame.data.length).toBeGreaterThan(0)
  })

  it('holds the next frame until the phone says it drew the last one', async () => {
    const { fp, host } = machine()
    const watcher = sink()
    await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 800,
      quality: 50,
      emit: watcher.emit,
    })

    fp.fire('Page.screencastFrame', screencastFrame(0))
    fp.fire('Page.screencastFrame', screencastFrame(120))
    // One in flight per watcher. The second frame is held, not queued — a phone
    // on a train sees fewer, current frames rather than a backlog growing toward
    // the socket ceiling.
    expect(watcher.frames).toHaveLength(1)

    host.ack({ watcherId: 'conn-1', window: PANE, seq: 1 })
    expect(watcher.frames).toHaveLength(2)
    expect(watcher.frames[1].scrollY).toBe(120)

    // An ack naming a frame this watcher is not holding is a duplicate or one
    // that crossed a newer send; it must not release anything.
    fp.fire('Page.screencastFrame', screencastFrame(240))
    host.ack({ watcherId: 'conn-1', window: PANE, seq: 1 })
    expect(watcher.frames).toHaveLength(2)
    host.ack({ watcherId: 'conn-1', window: PANE, seq: 2 })
    expect(watcher.frames).toHaveLength(3)
  })

  it('gives two connections watching one page two independent ack chains', async () => {
    const { fp, host } = machine()
    const fast = sink()
    const slow = sink()
    await host.watch({ watcherId: 'conn-1', window: PANE, maxWidth: 800, quality: 50, emit: fast.emit })
    await host.watch({ watcherId: 'conn-2', window: PANE, maxWidth: 800, quality: 50, emit: slow.emit })

    fp.fire('Page.screencastFrame', screencastFrame(0))
    expect(fast.frames).toHaveLength(1)
    expect(slow.frames).toHaveLength(1)

    // One phone draws and asks for more; the other has not. The one that acked
    // gets the next frame and the one that did not is not held up by it — and
    // neither can ack the other's.
    host.ack({ watcherId: 'conn-1', window: PANE, seq: 1 })
    fp.fire('Page.screencastFrame', screencastFrame(60))
    expect(fast.frames).toHaveLength(2)
    expect(slow.frames).toHaveLength(1)
  })
})

/* -------------------------------------------------------------- the taps -- */

describe('driving the window that is being watched', () => {
  it('sends a tap to the page the frames came from', async () => {
    const { fp, host } = machine()
    const watcher = sink()
    await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 400,
      quality: 50,
      emit: watcher.emit,
    })
    fp.fire('Page.screencastFrame', screencastFrame())

    const result = await host.input({
      watcherId: 'conn-1',
      window: PANE,
      frame: {
        t: 'browser.input',
        window: PANE,
        // The frame the coordinates were measured against. The host maps them
        // with *that* frame's scale, which it still holds.
        seq: watcher.frames[0].seq,
        mouse: { type: 'down', x: 80, y: 40, clicks: 1 },
      },
    })

    expect(result.ok).toBe(true)
    const dispatched = fp.last('Input.dispatchMouseEvent')
    expect(dispatched).toBeDefined()
    expect(dispatched?.params).toMatchObject({ type: 'mousePressed', button: 'left', clickCount: 1 })
  })

  it('refuses a tap at a window this connection is not watching', async () => {
    const { fp, host } = machine()
    const result = await host.input({
      watcherId: 'conn-1',
      window: PANE,
      frame: { t: 'browser.input', window: PANE, seq: 1, mouse: { type: 'down', x: 1, y: 1 } },
    })
    expect(result.ok).toBe(false)
    expect(result.reason).toContain('not being watched')
    // The gap this closes is a watch that was *refused* — the server's own set
    // says the device asked, and only this side knows the machine never started.
    expect(fp.has('Input.dispatchMouseEvent')).toBe(false)
  })
})

/* ------------------------------------------------------------ letting go -- */

describe('a watcher going away', () => {
  it('stops the screencast when the last watcher unwatches', async () => {
    const { fp, host } = machine()
    await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 800,
      quality: 50,
      emit: () => undefined,
    })
    await host.unwatch({ watcherId: 'conn-1', window: PANE })

    expect(fp.has('Page.stopScreencast')).toBe(true)
    expect(await host.surfaces()).toEqual([
      { window: PANE, url: 'https://example.com/', title: 'Example', live: false },
    ])
  })

  it('drops every cast a closed socket was holding', async () => {
    const { fp, host } = machine()
    const watcher = sink()
    await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 800,
      quality: 50,
      emit: watcher.emit,
    })
    expect(fp.has('Page.startScreencast')).toBe(true)

    // What `server.ts` calls from the socket's `closed` handler. Without it a
    // phone that walked into a tunnel left `Page.startScreencast` armed on
    // somebody's computer for the life of the process.
    await host.dropWatcher('conn-1')

    expect(fp.has('Page.stopScreencast')).toBe(true)
    expect(await host.surfaces()).toEqual([
      { window: PANE, url: 'https://example.com/', title: 'Example', live: false },
    ])

    // And nothing that arrives afterwards can be mistaken for the watcher that
    // left: an ack releases nothing and a tap does not reach the page.
    const before = fp.sent.length
    host.ack({ watcherId: 'conn-1', window: PANE, seq: 1 })
    const late = await host.input({
      watcherId: 'conn-1',
      window: PANE,
      frame: { t: 'browser.input', window: PANE, seq: 1, mouse: { type: 'down', x: 1, y: 1 } },
    })
    expect(late.ok).toBe(false)
    expect(fp.sent.length).toBe(before)
  })

  it('leaves the other connection casting when one of two sockets closes', async () => {
    const { fp, host } = machine()
    const staying = sink()
    await host.watch({ watcherId: 'conn-1', window: PANE, maxWidth: 800, quality: 50, emit: () => undefined })
    await host.watch({ watcherId: 'conn-2', window: PANE, maxWidth: 800, quality: 50, emit: staying.emit })

    await host.dropWatcher('conn-1')

    // A watcher id is a connection id, so two sockets from one phone are two
    // watchers; closing one must not take the other's picture away.
    expect(fp.has('Page.stopScreencast')).toBe(false)
    fp.fire('Page.screencastFrame', screencastFrame())
    expect(staying.frames).toHaveLength(1)
    expect(await host.surfaces()).toEqual([
      { window: PANE, url: 'https://example.com/', title: 'Example', live: true },
    ])
  })
})

/* ----------------------------------------------------- the drive-less host -- */

describe('a host whose browser is not there', () => {
  /** The shape `src/main/index.ts` builds when `browserDrive()` answers null. */
  const refusing: CastDrive = {
    startCast: async () => ({ ok: false, reason: 'this app has no browser running' }),
    stopCast: async () => undefined,
    ackCast: () => undefined,
    castInput: async () => ({ ok: false, reason: 'this app has no browser running' }),
    handoverHolding: () => ({ asking: false, prompt: '', taker: null }),
    takeHandover: async () => ({ ok: false, reason: 'this app has no browser running' }),
    handBackHandover: async () => ({ ok: false, reason: 'this app has no browser running' }),
    dropWatcher: async () => undefined,
  }

  it('answers a sentence and remembers no cast', async () => {
    const host = screencastOver({
      drive: refusing,
      windows: () => [{ window: PANE, target: TARGET, url: '', title: '' }],
    })

    const result = await host.watch({
      watcherId: 'conn-1',
      window: PANE,
      maxWidth: 800,
      quality: 50,
      emit: () => undefined,
    })
    expect(result.ok).toBe(false)

    // A refused watch is not a cast. The row must not claim to be live, and an
    // input arriving on the strength of the phone having asked must be refused
    // here even though the server's own `watching` set says it asked.
    expect((await host.surfaces())[0].live).toBe(false)
    const late = await host.input({
      watcherId: 'conn-1',
      window: PANE,
      frame: { t: 'browser.input', window: PANE, seq: 1, mouse: { type: 'down', x: 1, y: 1 } },
    })
    expect(late.ok).toBe(false)
    expect(late.reason).toContain('not being watched')
  })

  it('does not throw when a watcher that never watched anything is dropped', async () => {
    const host = screencastOver({ drive: refusing, windows: () => [] })
    await expect(host.dropWatcher('conn-9')).resolves.toBeUndefined()
    await expect(
      Promise.resolve(host.unwatch({ watcherId: 'conn-9', window: PANE })),
    ).resolves.toBeUndefined()
  })
})

/* ------------------------------------------------------------- front tab -- */

describe("the drive's own tab, which has no window id to wear", () => {
  it('has no row until the front tab holds a page', () => {
    const front = frontTab(() => null)
    expect(front.row()).toBeNull()
  })

  it('labels the row with the page the tab is on', () => {
    const front = frontTab(() => ({ url: 'https://www.google.com/', title: 'Google' }))
    front.opened({ url: 'https://www.google.com/', title: 'Google' })
    expect(front.row()).toEqual({
      window: '',
      target: null,
      url: 'https://www.google.com/',
      title: 'Google',
    })
  })

  /**
   * The defect this read exists to close, in both of its shapes.
   *
   * The row used to be labelled from what `open` answered, kept while the
   * *origin* still matched. So a link followed **inside** one site left the
   * address showing the page you started at — the first assertion — and a link
   * to **another** site degraded to a bare origin with no path — the second.
   * Asad found it from the other end: *"I cannot touch the URL."* An address bar
   * that can be edited and shows the wrong address is worse than one that
   * cannot.
   */
  it('follows the page inside a site and across to another one', () => {
    let page = { url: 'https://www.google.com/', title: 'Google' }
    const front = frontTab(() => page)
    front.opened(page)

    page = { url: 'https://www.google.com/search?q=deck', title: 'deck - Google Search' }
    expect(front.row()?.url).toBe('https://www.google.com/search?q=deck')
    expect(front.row()?.title).toBe('deck - Google Search')

    page = { url: 'https://news.example.com/story/1', title: 'A story' }
    expect(front.row()?.url).toBe('https://news.example.com/story/1')
    expect(front.row()?.title).toBe('A story')
  })

  it('says nothing about a blank tab rather than printing an opaque origin', () => {
    // `new URL('about:blank').origin` is the *string* `null`, which is a word a
    // person would be shown if it were passed through as an address.
    const front = frontTab(() => ({ url: 'about:blank', title: '' }))
    expect(front.row()).toEqual({ window: '', target: null, url: '', title: '' })
  })
})

/* ------------------------------------------- a named row on the own slot -- */

/**
 * A surface with a **real name** whose frames come out of the drive's own slot.
 *
 * This is not a hypothetical: it is what the desktop ships. `machineScreencastHere`
 * in `src/main/index.ts` walks `knownWindows()` and gives every row its pane's
 * shell id, then hands `target: null` to the one pane whose view matches
 * `BrowserDrive.ownView()` — because casting the copilot's own page through
 * `bound:<paneId>` would build a second slot on one document, with two batons and
 * two `grantedOrigin`s, and `handover` would curtain one of them while the other
 * kept streaming a password. Every other test in this file pairs a non-empty name
 * with a bound target or an empty name with a null one, so the combination the
 * desktop actually sends had nothing on it.
 *
 * What it pins is the property the fix for Asad's *"there is no way to attach
 * this one too"* rides on: **the name a surface wears and the slot its frames
 * come from are two independent facts**, and nothing in this module or in
 * `BrowserDrive` reads the name to decide where to route. So the day a server's
 * front tab is opened as an ordinary window — see `frontTab` in
 * `screencast-host.ts` for which file that lands in — the strip, the acks, the
 * taps and the handover all keep working with no change here.
 */
describe("a window row whose frames come from the drive's own slot", () => {
  const OWN_PANE = 'browser:1755:9'

  async function deskLikeMachine() {
    const fp = fakePage()
    const drive = new BrowserDrive({
      // The desktop's renderer answers with a view id; the pane's own shell id
      // never reaches this process, which is exactly why the row below carries
      // one and the target does not.
      openTab: async () => 'view-own',
      contentsFor: () => fp.page as never,
      publish: () => undefined,
      now: () => 1_000,
    })
    // There is nothing to cast until the copilot's tab holds a page.
    await drive.open({ url: 'https://example.com/', isolate: false })
    const host = screencastOver({
      drive,
      windows: (): CastWindow[] => [
        { window: OWN_PANE, target: null, url: 'https://example.com/', title: 'Example' },
      ],
    })
    return { fp, drive, host }
  }

  it('streams, acks and takes a tap under the name the window list gave it', async () => {
    const { fp, host } = await deskLikeMachine()
    const watcher = sink()

    const result = await host.watch({
      watcherId: 'conn-1',
      window: OWN_PANE,
      maxWidth: 800,
      quality: 50,
      emit: watcher.emit,
    })
    expect(result.ok).toBe(true)
    expect(fp.has('Page.startScreencast')).toBe(true)

    fp.fire('Page.screencastFrame', screencastFrame())
    expect(watcher.frames).toHaveLength(1)
    // The frame comes back wearing the row's name and not the slot's, which is
    // the whole of what the viewer keys its canvas on.
    expect(watcher.frames[0].window).toBe(OWN_PANE)

    // And the strip agrees with the routing, rather than listing a second name
    // for the same page.
    expect(await host.surfaces()).toEqual([
      { window: OWN_PANE, url: 'https://example.com/', title: 'Example', live: true },
    ])

    host.ack({ watcherId: 'conn-1', window: OWN_PANE, seq: watcher.frames[0].seq })
    fp.fire('Page.screencastFrame', screencastFrame(120))
    expect(watcher.frames).toHaveLength(2)

    const tap = await host.input({
      watcherId: 'conn-1',
      window: OWN_PANE,
      frame: {
        t: 'browser.input',
        window: OWN_PANE,
        seq: watcher.frames[1].seq,
        mouse: { type: 'down', x: 80, y: 40, clicks: 1 },
      },
    })
    expect(tap.ok).toBe(true)
    expect(fp.last('Input.dispatchMouseEvent')?.params).toMatchObject({
      type: 'mousePressed',
      button: 'left',
    })
  })

  it('carries the copilot’s question, and a take, to the own slot under that name', async () => {
    const { drive, host } = await deskLikeMachine()
    const watcher = sink()
    await host.watch({
      watcherId: 'conn-1',
      window: OWN_PANE,
      maxWidth: 800,
      quality: 50,
      emit: watcher.emit,
    })

    // Asked on the own slot — `handover` with no target — and read back under the
    // pane's name. This is the half that matters most: `handover` curtains the
    // cast of the slot it was called on, so a row that could not answer it would
    // put a lock card on a phone with no way to lift it. The window is spelled
    // out for the same reason its neighbours spell it out: a default that
    // outlives the test is a timer holding the runner open.
    const asked = drive.handover('Sign in and then press Done.', 60_000)
    await new Promise((settle) => setTimeout(settle, 0))

    const question = await host.handover(OWN_PANE)
    expect(question.asking).toBe(true)
    expect(question.prompt).toContain('Sign in')
    expect(question.taker).toBeNull()

    expect(await host.take({ watcherId: 'conn-1', window: OWN_PANE })).toEqual({ ok: true })
    expect((await host.handover(OWN_PANE)).taker).toBe('conn-1')

    expect(await host.handBack({ watcherId: 'conn-1', window: OWN_PANE, carryOn: true })).toEqual({
      ok: true,
    })
    expect((await asked).outcome).toBe('resumed')
    expect(await host.handover(OWN_PANE)).toEqual({ asking: false, prompt: '', taker: null })
  })
})

/* -------------------------------------------------- the wiring, mechanically -- */

/**
 * That the two shells that ship actually pass one — checked in the source,
 * because that is the exact shape of the defect this lane exists to fix.
 *
 * Everything above this line passed before the feature was reachable by anybody.
 * `PageCast` had its own green file, the `browser.*` frames had theirs, the
 * phone drew a viewer and the PWA a canvas — and `grep -rn screencast
 * src/headless/host.ts src/main/index.ts` found nothing, so `capabilitiesFor`
 * never advertised `watch` on any host in this repository. A behavioural test
 * cannot see that: it is an absence in an assembly, and the only thing that
 * catches an absence in an assembly is reading the assembly.
 *
 * The same argument `seam.test.ts` makes about its own import walk — *"a seam
 * nobody checks is a seam that closes again"*.
 */
describe('both shells pass a screencast, and the endpoint carries it', () => {
  const root = resolve(__dirname, '..', '..')
  const source = (file: string): string =>
    readFileSync(join(root, file), 'utf8')
      .replace(/\r\n/g, '\n')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/^[ \t]*\/\/.*$/gm, '')

  it('the desktop hands one to registerRemoteIpc', () => {
    expect(source('src/main/index.ts')).toContain('screencast: machineScreencastHere()')
  })

  it('the headless daemon hands one to registerRemoteIpc', () => {
    expect(source('src/headless/host.ts')).toContain('screencast: screencastOver(')
  })

  it('and both name the grant that watching shares with driving', () => {
    // Without it a device whose browser-windows permission a person unticked
    // keeps the pictures while it loses the clicks: `mayWatchNow` treats an
    // absent grant as "any of the owner's own devices may".
    expect(source('src/main/index.ts')).toContain('drivesWindows:')
    expect(source('src/headless/host.ts')).toContain('drivesWindows:')
  })

  it('and `registerRemoteIpc` forwards both to the endpoint', () => {
    // The road every shell reaches the endpoint by. An option `RemoteIpcDeps`
    // does not name is an option no host can ever pass, whatever it writes.
    const server = source('src/main/remote/server.ts')
    expect(server).toContain('screencast: deps.screencast')
    expect(server).toContain('drivesWindows: deps.drivesWindows')
  })

  it('and a socket that closes reaches dropWatcher', () => {
    // The one call that stops a screencast on the machine when the phone that
    // asked for it is gone. It lives in the endpoint's `closed` handler, beside
    // the credential proxy and the window desk being told the same news.
    expect(source('src/main/remote/server.ts')).toContain(
      'options.screencast?.dropWatcher(connection.id)',
    )
  })
})

/* -------------------------------------------------------- the handover -- */

/**
 * The handover, routed by window name.
 *
 * The same rule the input path states, one frame further along: a name is
 * resolved to a slot once, at watch time, and every later call for that watcher
 * goes to *that* slot. A take that resolved the name again could hand somebody a
 * different page from the one they are looking at, which on a login form is the
 * whole of the danger.
 */
describe('answering the copilot’s question from a watched window', () => {
  it('reports nothing about a window this machine is not casting', async () => {
    /*
     * Not the same claim as *no handover is outstanding*, and answered the same
     * way on purpose: the only thing this frame leads to is a take, and a take
     * requires being a watcher. Saying `asking: true` about a page this side is
     * not casting would put a button on a screen the tap would be refused from.
     */
    const { host } = machine()
    expect(await host.handover(PANE)).toEqual({ asking: false, prompt: '', taker: null })
    expect(await host.take({ watcherId: 'conn-1', window: PANE })).toMatchObject({ ok: false })
    expect(await host.handBack({ watcherId: 'conn-1', window: PANE, carryOn: true })).toMatchObject({ ok: false })
  })

  it('carries a take and a hand-back to the slot the watcher is being shown', async () => {
    const { fp, drive, host } = machine()
    const watcher = sink()
    await host.watch({ watcherId: 'conn-1', window: PANE, maxWidth: 800, quality: 50, emit: watcher.emit })

    const asked = drive.handover('Sign in and then press Done.', 60_000, TARGET)
    await new Promise((settle) => setTimeout(settle, 0))

    const question = await host.handover(PANE)
    expect(question.asking).toBe(true)
    expect(question.prompt).toContain('Sign in')
    expect(question.taker).toBeNull()

    expect(await host.take({ watcherId: 'conn-1', window: PANE })).toEqual({ ok: true })
    expect((await host.handover(PANE)).taker).toBe('conn-1')

    // The page is live for the taker again, and its typing reaches the page. The
    // lock card it is holding has to be acked first — the backpressure is one
    // un-acked frame per watcher, and a curtain card is a frame.
    host.ack({ watcherId: 'conn-1', window: PANE, seq: watcher.frames[watcher.frames.length - 1].seq })
    fp.fire('Page.screencastFrame', screencastFrame())
    const last = watcher.frames[watcher.frames.length - 1]
    expect(last.masked).toBeUndefined()
    const typed = await host.input({
      watcherId: 'conn-1',
      window: PANE,
      frame: { t: 'browser.input', window: PANE, seq: last.seq, paste: 'hunter2' },
    })
    expect(typed.ok).toBe(true)
    expect(fp.has('Input.insertText')).toBe(true)

    expect(await host.handBack({ watcherId: 'conn-1', window: PANE, carryOn: true })).toEqual({ ok: true })
    expect((await asked).outcome).toBe('resumed')
    expect(await host.handover(PANE)).toEqual({ asking: false, prompt: '', taker: null })
  })

  it('refuses a take from a connection this side is not casting to', async () => {
    // The two-set rule: `server.ts` refuses a window a connection never asked to
    // watch, and this refuses one this side never started. The gap between them
    // is a watch that was refused, and a take in that gap would be a take of a
    // page whose pixels are going nowhere.
    const { drive, host } = machine()
    const watcher = sink()
    await host.watch({ watcherId: 'conn-1', window: PANE, maxWidth: 800, quality: 50, emit: watcher.emit })
    const asked = drive.handover('Sign in and then press Done.', 60_000, TARGET)
    await new Promise((settle) => setTimeout(settle, 0))

    const stranger = await host.take({ watcherId: 'conn-2', window: PANE })
    expect(stranger.ok).toBe(false)
    expect(stranger.reason).toContain('not being watched on this connection')
    expect((await host.handover(PANE)).taker).toBeNull()

    await host.take({ watcherId: 'conn-1', window: PANE })
    await host.handBack({ watcherId: 'conn-1', window: PANE, carryOn: false })
    expect((await asked).outcome).toBe('stopped')
  })
})
