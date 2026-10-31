import { rmSync } from 'node:fs'
import type { Cookie, IpcMain, IpcMainInvokeEvent } from 'electron'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The seam where the human gesture and the credential meet.
 *
 * Everything below is about *who may ask* and *what they are believed about*.
 * The arithmetic is tested in `browser-worker-pool.test.ts` and the cookie
 * mechanics in `browser-session-lift.test.ts`; this file exists for the four
 * refusals that would each be a real hole:
 *
 *  - a page in the browser asking this process to copy his session,
 *  - an Isolated tab being lifted from, whose session is about to stop existing,
 *  - a frame being handed a seed for an origin it merely *claimed* to be on,
 *  - and a lift being written back into the profile it came from.
 */

const box = vi.hoisted(() => {
  const { mkdtempSync: make } = require('node:fs') as typeof import('node:fs')
  const { tmpdir: tmp } = require('node:os') as typeof import('node:os')
  const { join: j } = require('node:path') as typeof import('node:path')
  return { dir: make(j(tmp(), 'td-workers-ipc-')), contents: null as unknown, pages: [] as unknown[] }
})

vi.mock('electron', () => {
  const made = new Map<string, unknown>()
  return {
    app: { getPath: () => box.dir, userAgentFallback: 'test' },
    // `box.pages` so the ask-inbox tests can put a live page into a profile's
    // jar; every other test leaves it empty, which is what the literal [] was.
    webContents: { getAllWebContents: () => box.pages },
    session: {
      fromPartition: (partition: string) => {
        if (!made.has(partition)) {
          made.set(partition, {
            partition,
            setPermissionRequestHandler: () => undefined,
            setPermissionCheckHandler: () => undefined,
            registerPreloadScript: () => 'id',
            setUserAgent: () => undefined,
            on: () => undefined,
            cookies: { get: async () => [], set: async () => undefined },
          })
        }
        return made.get(partition)
      },
    },
  }
})

vi.mock('./app-log', () => ({
  logger: { debug: () => undefined, info: () => undefined, warn: () => undefined, error: () => undefined },
}))

vi.mock('./browser-tab', () => ({
  browserTabContents: (id: unknown) => (id === 'view-1' ? box.contents : null),
}))

const { registerBrowserWorkerIpc } = await import('./browser-workers-ipc')
const { GUEST_SEED_CHANNEL } = await import('./browser-seed-preload')
const { ensureWorkers, resetWorkersForTests, workerList } = await import('./browser-workers')
const { resetProfilesForTests, sessionForPartition, DEFAULT_PARTITION } = await import('./browser-profiles')
const { forgetAllLifts, forgetAllSeeds, injectLift, liftSummaries } = await import(
  './browser-session-lift'
)
const { fileLiftRequest, listLiftRequests, peekLiftRequest, resetLiftRequestsForTests } = await import(
  './browser-lift-requests'
)

/** One signed-in cookie, with a value nobody would type by accident. */
const SESSION_COOKIE = {
  name: 'sessionid',
  value: 'the-actual-token',
  domain: 'shop.example.com',
  hostOnly: true,
  path: '/',
  secure: true,
  httpOnly: true,
  session: true,
  sameSite: 'lax',
} as unknown as Cookie

/** An `ipcMain` that only remembers what was registered on it. */
function bench() {
  const handlers = new Map<string, (event: IpcMainInvokeEvent, ...args: unknown[]) => unknown>()
  const ipc = {
    handle: (channel: string, handler: (event: IpcMainInvokeEvent, ...args: unknown[]) => unknown) => {
      handlers.set(channel, handler)
    },
    on: () => undefined,
  } as unknown as IpcMain
  registerBrowserWorkerIpc(ipc)
  return {
    call: async (channel: string, event: unknown, ...args: unknown[]): Promise<unknown> => {
      const handler = handlers.get(channel)
      if (!handler) throw new Error(`no handler for ${channel}`)
      return handler(event as IpcMainInvokeEvent, ...args)
    },
  }
}

/** The app's own window: not a guest session, so `fromAppWindow` lets it in. */
function fromWindow(): unknown {
  return { sender: { session: { notAProfile: true } } }
}

beforeEach(() => {
  resetProfilesForTests()
  resetWorkersForTests()
  forgetAllLifts()
  forgetAllSeeds()
  resetLiftRequestsForTests()
  box.contents = null
  box.pages = []
})

afterEach(() => {
  rmSync(box.dir, { recursive: true, force: true })
})

describe('who may ask for a session to be copied', () => {
  it('refuses a request that did not come from this app’s window', async () => {
    /*
     * Belt over braces, and deliberately so. A page in the browser gets a
     * different and much smaller preload and cannot reach `ipcMain` at all — but
     * the day that stops being true is the day a website could otherwise ask
     * this process to copy his logged-in session into eight profiles. A check
     * that is unreachable today and catastrophic to be missing tomorrow is worth
     * four lines.
     */
    const guest = sessionForPartition(DEFAULT_PARTITION)
    const answer = (await bench().call('browser-worker:lift', { sender: { session: guest } }, {
      viewId: 'view-1',
    })) as { ok: boolean; reason: string }
    expect(answer.ok).toBe(false)
    expect(answer.reason).toContain('did not come from this app')
  })

  it('refuses a page that is not there any more', async () => {
    const answer = (await bench().call('browser-worker:lift', fromWindow(), { viewId: 'gone' })) as {
      ok: boolean
      reason: string
    }
    expect(answer.ok).toBe(false)
    expect(answer.reason).toContain('no page open')
  })

  it('refuses an Isolated tab, whose session is about to stop existing', async () => {
    /*
     * An Isolated tab's partition is in memory and dies with the process, so a
     * session lifted from it is one that will not be valid tomorrow. And the
     * whole point of Isolated is that what happens in it does not travel.
     */
    box.contents = { session: { anonymous: true }, getURL: () => 'https://shop.example.com/' }
    const answer = (await bench().call('browser-worker:lift', fromWindow(), { viewId: 'view-1' })) as {
      ok: boolean
      reason: string
    }
    expect(answer.ok).toBe(false)
    expect(answer.reason).toContain('Isolated')
    expect(liftSummaries()).toHaveLength(0)
  })

  it('takes it from a real profile, and answers in counts and names', async () => {
    /*
     * The page's session has to be the very object `sessionForPartition` hands
     * out, because that is how the profile behind a page is resolved — by
     * identity, not by a partition string, which a `WebContents` does not carry.
     */
    const jar = sessionForPartition(DEFAULT_PARTITION) as unknown as { cookies: unknown }
    jar.cookies = { get: async (): Promise<Cookie[]> => [SESSION_COOKIE] }
    box.contents = {
      session: jar,
      getURL: () => 'https://shop.example.com/',
      executeJavaScriptInIsolatedWorld: async () => {
        // A page that will not run a script — a Chromium error document, or a
        // frame that navigated underneath us. The cookies are still real.
        throw new Error('no script')
      },
    }

    const answer = (await bench().call('browser-worker:lift', fromWindow(), { viewId: 'view-1' })) as {
      ok: boolean
      summary: { cookieNames: string[]; host: string }
    }
    expect(answer.ok).toBe(true)
    expect(answer.summary.host).toBe('shop.example.com')
    expect(answer.summary.cookieNames).toEqual(['sessionid'])
    // The rule the whole feature is built on, asserted on the blob rather than
    // field by field: a value added to the summary one day fails this line.
    expect(JSON.stringify(answer.summary)).not.toContain('the-actual-token')
  })
})

describe('putting a lift into the workers', () => {
  it('refuses an id that has expired rather than reporting a copy of nothing', async () => {
    const answer = (await bench().call('browser-worker:inject', fromWindow(), { liftId: 'nope' })) as {
      ok: boolean
      reason: string
    }
    expect(answer.ok).toBe(false)
    expect(answer.reason).toContain('expired')
  })

  it('never writes a lift back into the profile it came from', async () => {
    /*
     * That profile is already signed in — it is where the session was taken
     * from — so a `set` there is a write of a live credential for no reason at
     * all. Refused rather than skipped in silence, because "0 workers were
     * injected" and "everything worked" must not look the same.
     */
    ensureWorkers(box.dir, 1)
    const [worker] = workerList(box.dir)
    const jar = sessionForPartition(worker.partition) as unknown as { cookies: unknown }
    jar.cookies = {
      get: async (): Promise<Cookie[]> => [SESSION_COOKIE],
      set: async (): Promise<void> => undefined,
    }
    box.contents = {
      session: jar,
      getURL: () => 'https://shop.example.com/',
      executeJavaScriptInIsolatedWorld: async () => {
        throw new Error('no script')
      },
    }
    const desk = bench()
    const lifted = (await desk.call('browser-worker:lift', fromWindow(), { viewId: 'view-1' })) as {
      ok: boolean
      summary: { id: string }
    }
    expect(lifted.ok).toBe(true)

    const answer = (await desk.call('browser-worker:inject', fromWindow(), {
      liftId: lifted.summary.id,
      profileIds: [worker.profileId],
    })) as { ok: boolean; reason: string }
    expect(answer.ok).toBe(false)
    expect(answer.reason).toContain('already signed in')
  })

  it('refuses when there is nowhere to put it', async () => {
    const answer = (await bench().call('browser-worker:inject', fromWindow(), {
      liftId: 'nope',
      profileIds: [],
    })) as { ok: boolean }
    expect(answer.ok).toBe(false)
  })
})

describe('the seed a worker frame is handed', () => {
  it('is refused outright for a session that is not a worker', async () => {
    ensureWorkers(box.dir, 1)
    const answer = await bench().call(GUEST_SEED_CHANNEL, {
      sender: { session: sessionForPartition(DEFAULT_PARTITION) },
      senderFrame: { url: 'https://shop.example.com/' },
    })
    expect(answer).toBeNull()
  })

  it('is refused for a frame with no origin worth seeding', async () => {
    ensureWorkers(box.dir, 1)
    const [worker] = workerList(box.dir)
    for (const url of ['about:blank', 'file:///etc/passwd', undefined]) {
      const answer = await bench().call(GUEST_SEED_CHANNEL, {
        sender: { session: sessionForPartition(worker.partition) },
        senderFrame: url === undefined ? null : { url },
      })
      expect(answer).toBeNull()
    }
  })

  it('reads the origin off the frame rather than off anything it was told', async () => {
    /*
     * The preload sends no arguments at all, and this is why: the partition is
     * `event.sender.session` and the origin is `event.senderFrame.url`, both of
     * which are Chromium's facts about the frame. A handler that trusted a
     * claimed origin would be one bad Electron release away from handing a token
     * to whoever asked politely — so an extra argument saying otherwise changes
     * nothing about the answer.
     */
    ensureWorkers(box.dir, 1)
    const [worker] = workerList(box.dir)
    await injectLift({
      lift: {
        id: 'l1',
        takenAt: 0,
        expiresAt: Date.now() + 60_000,
        sourceProfileId: 'other',
        sourceProfileName: 'Main',
        host: 'shop.example.com',
        origin: 'https://shop.example.com',
        cookies: [],
        storage: {
          origin: 'https://shop.example.com',
          local: { entries: [['auth', 'tok']], truncated: false },
          session: { entries: [], truncated: false },
        },
      },
      targets: [
        {
          profileId: worker.profileId,
          name: worker.name,
          partition: worker.partition,
          jar: sessionForPartition(worker.partition),
        },
      ],
      register: () => true,
    })

    const desk = bench()
    const wrongFrame = await desk.call(
      GUEST_SEED_CHANNEL,
      {
        sender: { session: sessionForPartition(worker.partition) },
        senderFrame: { url: 'https://evil.example.com/' },
      },
      // A claimed origin, ignored: the handler never reads an argument.
      'https://shop.example.com',
    )
    expect(wrongFrame).toBeNull()

    const right = (await desk.call(GUEST_SEED_CHANNEL, {
      sender: { session: sessionForPartition(worker.partition) },
      senderFrame: { url: 'https://shop.example.com/account' },
    })) as { local: [string, string][] } | null
    expect(right?.local).toEqual([['auth', 'tok']])

    // Once. A confirmation that never arrives would otherwise leave a live
    // credential in the map for the next frame on that origin.
    const again = await desk.call(GUEST_SEED_CHANNEL, {
      sender: { session: sessionForPartition(worker.partition) },
      senderFrame: { url: 'https://shop.example.com/account' },
    })
    expect(again).toBeNull()
  })
})

describe('the ask inbox, wired end to end', () => {
  /**
   * The person's half of the lift-request channel: the panel lists asks over
   * `browser-worker:lift-requests`, hears changes on the push, and answers one
   * over `browser-worker:lift-answer`. Approval performs the WHOLE gesture in
   * this process — lift off a live page in the named profile, inject into the
   * named workers, forget — which is why this file owns the test: the desk
   * only ever holds rows, and the row-to-cookies step lives in `handleLiftAnswer`.
   */

  /** A live, signed-in page in the default profile's jar. */
  function signedInPage(): void {
    const jar = sessionForPartition(DEFAULT_PARTITION) as unknown as { cookies: unknown }
    jar.cookies = {
      get: async (): Promise<Cookie[]> => [SESSION_COOKIE],
      set: async () => undefined,
    }
    box.pages = [
      {
        isDestroyed: () => false,
        session: jar,
        getURL: () => 'https://shop.example.com/account',
        executeJavaScriptInIsolatedWorld: async () => {
          throw new Error('no script')
        },
      },
    ]
  }

  /** File one ask through the desk the registration configured. */
  function ask(into: string[] = []): string {
    const filed = fileLiftRequest({ askedBy: 'The session driving B1', from: 'Default', into })
    if (!filed.ok) throw new Error(filed.reason)
    return filed.request.id
  }

  it('registration wires the desk, so an ask resolves against the real profiles', async () => {
    const b = bench()
    ensureWorkers(box.dir, 2)
    const id = ask()
    const listed = (await b.call('browser-worker:lift-requests', fromWindow())) as unknown[]
    expect(listed).toHaveLength(1)
    expect((listed[0] as { id: string }).id).toBe(id)
  })

  it('pushes the inbox to a window that has read it, when an ask arrives', async () => {
    const b = bench()
    ensureWorkers(box.dir, 1)
    const sent: Array<{ channel: string; inbox: unknown }> = []
    const sender = {
      session: { notAProfile: true },
      isDestroyed: () => false,
      send: (channel: string, inbox: unknown) => sent.push({ channel, inbox }),
    }
    await b.call('browser-worker:lift-requests', { sender })
    ask()
    expect(sent).toHaveLength(1)
    expect(sent[0].channel).toBe('browser-worker:lift-request')
    expect(sent[0].inbox).toHaveLength(1)
  })

  it('refuses an answer that did not come from this app’s window', async () => {
    const b = bench()
    ensureWorkers(box.dir, 1)
    const id = ask()
    const guest = sessionForPartition(DEFAULT_PARTITION)
    const answer = (await b.call('browser-worker:lift-answer', { sender: { session: guest } }, {
      requestId: id,
      approve: true,
    })) as { ok: boolean; message: string }
    expect(answer.ok).toBe(false)
    expect(answer.message).toContain('did not come from this app')
    // And the ask is still there: a refused answer answers nothing.
    expect(peekLiftRequest(id)).not.toBeNull()
  })

  it('declines without touching anything, and the row leaves the inbox', async () => {
    const b = bench()
    ensureWorkers(box.dir, 1)
    const id = ask()
    const answer = (await b.call('browser-worker:lift-answer', fromWindow(), {
      requestId: id,
      approve: false,
    })) as { ok: boolean; message: string; count: number | null }
    expect(answer.ok).toBe(true)
    expect(answer.message).toContain('Declined')
    expect(answer.count).toBeNull()
    expect(listLiftRequests()).toHaveLength(0)
    expect(liftSummaries()).toHaveLength(0)
  })

  it('keeps the ask when no page is open in that profile, and says what to do', async () => {
    const b = bench()
    ensureWorkers(box.dir, 1)
    const id = ask()
    const answer = (await b.call('browser-worker:lift-answer', fromWindow(), {
      requestId: id,
      approve: true,
    })) as { ok: boolean; message: string }
    expect(answer.ok).toBe(false)
    expect(answer.message).toContain('No page is open in Default')
    expect(answer.message).toContain('still here')
    // "Not yet", not "no": the person can open the site and press Approve again.
    expect(peekLiftRequest(id)).not.toBeNull()
  })

  it('approving performs the whole gesture: lift, inject, forget, and the row leaves', async () => {
    const b = bench()
    ensureWorkers(box.dir, 2)
    signedInPage()
    const id = ask()
    const answer = (await b.call('browser-worker:lift-answer', fromWindow(), {
      requestId: id,
      approve: true,
    })) as { ok: boolean; message: string; count: number | null }
    expect(answer.ok).toBe(true)
    expect(answer.message).toContain('shop.example.com')
    expect(answer.count).toBeGreaterThan(0)
    // The row is answered, and the lifted session did not outlive the gesture.
    expect(listLiftRequests()).toHaveLength(0)
    expect(liftSummaries()).toHaveLength(0)
    // The rule the whole feature is built on: no value crosses the answer.
    expect(JSON.stringify(answer)).not.toContain('the-actual-token')
  })

  it('answers honestly about an ask that no longer exists', async () => {
    const b = bench()
    const answer = (await b.call('browser-worker:lift-answer', fromWindow(), {
      requestId: 'gone',
      approve: true,
    })) as { ok: boolean; message: string }
    expect(answer.ok).toBe(false)
    expect(answer.message).toContain('already been answered')
  })
})

describe('the panel’s own view', () => {
  it('lists workers with the pace, and never a cookie', async () => {
    ensureWorkers(box.dir, 2)
    const view = (await bench().call('browser-worker:list', fromWindow())) as {
      workers: { name: string }[]
      pace: { maxConcurrent: number }
      lifts: unknown[]
    }
    expect(view.workers.map((row) => row.name)).toEqual(['Worker 1', 'Worker 2'])
    expect(view.pace.maxConcurrent).toBeGreaterThan(0)
    expect(JSON.stringify(view)).not.toContain('cookies')
  })

  it('grows the pool on ensure and never shrinks it', async () => {
    const desk = bench()
    await desk.call('browser-worker:ensure', fromWindow(), 3)
    const view = (await desk.call('browser-worker:ensure', fromWindow(), 1)) as {
      workers: unknown[]
    }
    expect(view.workers).toHaveLength(3)
  })
})
