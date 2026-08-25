import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { attach, ownerOf, resetForTests, sessionRemoved, view, windowsOf } from '../main/browser-binding'
import { boundKey, type DriveTarget } from '../main/browser-driver'
import type { HostSession, MachineBrowser } from '../main/remote/browser-control'
import type { ServerMessage } from '../main/remote/protocol'
import { serverMachineBrowser, type ServerPage, type ServerWindows } from './machine-browser'

/**
 * The server's browser, as the phone's window screen drives it.
 *
 * ## What this is here to catch
 *
 * Every control on that screen already existed — `browser-control.ts` has
 * carried the whole `browser.window.*` family since it was written — and a
 * headless host advertised none of them, because it built no `MachineBrowser`
 * and `server.ts` reads that object's *presence* to decide whether to offer
 * `browser.control` at all. Asad, twice: *"I don't see any of them."* So the
 * failure this file guards is not a broken verb, it is a verb wired to nothing,
 * and the assertions are correspondingly about what reaches the layer under the
 * module rather than about the shape of what comes back.
 *
 * The fakes are the browser and only the browser. `browser-binding.ts` is the
 * **real** store underneath — the same one the desktop mints `B1` from and the
 * same one the hook answer is composed from — because half of what this module
 * does is bookkeeping in it: a window the phone opens must end up owned by
 * nobody, a window it binds must end up owned by a session with a number an
 * agent will read, and a window whose page has gone must not leave a row
 * pointing at it. None of that is observable against a fake store.
 *
 * `host.test.ts` proves the other half — that `createHeadlessHost` actually
 * builds one of these and hands it over — which is the join that was missing.
 */

/* ---------------------------------------------------------------- fakes -- */

/** One page, remembering every address it was sent to. */
class FakePage implements ServerPage {
  loading = false
  /** The page claims unfinished work, so `navigateGuarded` refuses. */
  unfinished = false
  readonly went: string[] = []

  constructor(
    private address: string,
    private name = '',
  ) {}

  url(): string {
    return this.address
  }

  title(): string {
    return this.name
  }

  isLoading(): boolean {
    return this.loading
  }

  async loadURL(url: string): Promise<void> {
    this.went.push(url)
    this.address = url
  }

  async navigateGuarded(url: string): Promise<'navigated' | 'unfinished'> {
    if (this.unfinished) return 'unfinished'
    this.went.push(url)
    this.address = url
    return 'navigated'
  }

  rename(name: string): void {
    this.name = name
  }
}

/**
 * The tab authority, faked at exactly the methods the module uses.
 *
 * Both doors are line-for-line stand-ins for `HeadlessDriveHost`'s. `openWindow`
 * mints a `browser:<epoch>:<uuid>` shell id, registers it so `closeWindow` can
 * find it, and attaches it to **nothing** — which is the whole point of that
 * door and the reason the sentinel session is gone. `openForSession` mints one
 * and binds it, because that is the door an agent's `browser_open` arrives
 * through and this module has to list what it leaves behind.
 */
class FakeBrowser implements ServerWindows {
  readonly pages = new Map<string, FakePage>()
  /** Shell tab id → view id, exactly as the real host's `byBrowserTab` is. */
  readonly byTab = new Map<string, string>()
  readonly opened: string[] = []
  /** What each open asked for, so a test can see the jar reach the authority. */
  readonly jars: Array<{ isolate: boolean; profileId: string | undefined }> = []
  /** Every back/forward this was asked for. */
  readonly moves: Array<{ viewId: string; move: 'back' | 'forward' }> = []
  /** Every repartition this was asked for. */
  readonly repartitions: Array<{ browserTabId: string; isolate: boolean }> = []
  /** Set to make Chromium refuse to start, with a sentence of its own. */
  refusal: string | null = null
  /** Set to make a history move refuse, the way a window with no history does. */
  noHistory: string | null = null
  /** Set to make a repartition fail, leaving the window where it was. */
  cannotRepartition = false
  private seq = 0

  async openWindow(input: {
    url: string
    isolate: boolean
    profileId?: string
  }): Promise<{ ok: true; browserTabId: string; viewId: string } | { ok: false; why: string }> {
    this.jars.push({ isolate: input.isolate, profileId: input.profileId })
    if (this.refusal !== null) return { ok: false, why: this.refusal }
    this.opened.push(input.url)
    this.seq += 1
    const viewId = `target-${this.seq}`
    const browserTabId = `browser:1000:${this.seq}`
    this.pages.set(viewId, new FakePage(input.url))
    this.byTab.set(browserTabId, viewId)
    return { ok: true, browserTabId, viewId }
  }

  async historyMove(
    viewId: string,
    move: 'back' | 'forward',
  ): Promise<{ moved: true } | { moved: false; why: string }> {
    this.moves.push({ viewId, move })
    if (this.noHistory !== null) return { moved: false, why: this.noHistory }
    return { moved: true }
  }

  async repartitionWindow(browserTabId: string, isolate: boolean): Promise<{ viewId: string } | null> {
    this.repartitions.push({ browserTabId, isolate })
    if (this.cannotRepartition) return null
    const wasAt = this.byTab.get(browserTabId)
    if (wasAt === undefined) return null
    // A new view under the same window, which is exactly what the real one does:
    // isolation is fixed when a page is constructed, so the page is re-opened.
    const page = this.pages.get(wasAt) as FakePage
    this.pages.delete(wasAt)
    this.seq += 1
    const viewId = `target-${this.seq}`
    this.pages.set(viewId, page)
    this.byTab.set(browserTabId, viewId)
    return { viewId }
  }

  async openForSession(input: {
    url: string
    sessionId: string
  }): Promise<{ line: string; attached: boolean }> {
    this.opened.push(input.url)
    if (this.refusal !== null) return { line: 'nothing opened', attached: false }
    this.seq += 1
    const viewId = `target-${this.seq}`
    const browserTabId = `browser:1000:${this.seq}`
    this.pages.set(viewId, new FakePage(input.url))
    this.byTab.set(browserTabId, viewId)
    attach({ sessionId: input.sessionId, machineId: '', browserTabId, viewId, url: input.url })
    return { line: `Opened B1 on the server`, attached: true }
  }

  async closeWindow(browserTabId: string): Promise<boolean> {
    const viewId = this.byTab.get(browserTabId)
    if (viewId === undefined) return false
    this.byTab.delete(browserTabId)
    this.pages.delete(viewId)
    return true
  }

  contentsFor(viewId: string): ServerPage | null {
    return this.pages.get(viewId) ?? null
  }

  whyNoTab(): string | null {
    return this.refusal
  }

  /** The page behind a shell tab id, for a test that wants to poke at it. */
  pageOf(browserTabId: string): FakePage {
    const viewId = this.byTab.get(browserTabId)
    return this.pages.get(viewId ?? '') as FakePage
  }

  /** The page died in Chromium — a crash, or somebody closing it in the browser. */
  lose(browserTabId: string): void {
    const viewId = this.byTab.get(browserTabId)
    if (viewId !== undefined) this.pages.delete(viewId)
  }
}

/* ------------------------------------------------------------------ rig -- */

let dir = ''
let browser: FakeBrowser
let sessions: HostSession[]
let typed: Array<{ session: string; data: string }>
let shots: DriveTarget[]
let shotFile = ''
let control: MachineBrowser

beforeEach(() => {
  resetForTests()
  dir = mkdtempSync(join(tmpdir(), 'td-machine-browser-'))
  shotFile = join(dir, 'page-1.png')
  // A real file, because the preview the wire is offered is the file itself —
  // there is no resize on a server. See the module header.
  writeFileSync(shotFile, Buffer.from('a small picture'))
  browser = new FakeBrowser()
  sessions = []
  typed = []
  shots = []
  control = serverMachineBrowser({
    windows: browser,
    shots: {
      screenshot: async (target) => {
        shots.push(target as DriveTarget)
        return { path: shotFile, width: 1200, height: 800 }
      },
    },
    sessions: () => sessions,
    write: (session, data) => typed.push({ session, data }),
  })
})

afterEach(() => {
  rmSync(dir, { recursive: true, force: true })
})

/**
 * A profile id shaped the way this app mints them.
 *
 * A UUID, because that is the only other shape `isProfileId` accepts — an id
 * that is not one this app minted becomes the last segment of a
 * `--user-data-dir`, and the authority refuses it before it can.
 */
const PROFILE = '7f2a1c94-3d8e-4b21-9a55-0c6d1e83f4b7'

type Rows = Extract<ServerMessage, { t: 'browser.window.rows' }>

/** The window list out of any answer that is one, or a failure naming what came back. */
function rowsOf(answer: ServerMessage): Rows {
  expect(answer.t, JSON.stringify(answer)).toBe('browser.window.rows')
  return answer as Rows
}

/** Open one window and answer its id — the setup half of most tests below. */
async function openOne(url = 'https://example.com/pricing'): Promise<string> {
  const rows = rowsOf(await control.open({ t: 'browser.window.open', url }))
  expect(rows.windows).toHaveLength(1)
  return rows.windows[0].id
}

/* ----------------------------------------------------------------- open -- */

describe('a window the phone opens on a server', () => {
  it('is minted by the door that can close it again, and belongs to nobody', async () => {
    const id = await openOne()

    // The shell id came from the tab authority, so the authority can find it —
    // a window minted anywhere else could never be closed again.
    expect(browser.byTab.has(id)).toBe(true)

    /*
     * And it was never attached to anything. Nothing is chosen by default:
     * *"not the focused session, not the newest, not the only one"* — so the row
     * carries no slot and no session. This used to be an attach that was undone
     * in the next line, filed under a sentinel session id; the door that mints
     * without binding is what removed both.
     */
    expect(ownerOf(id)).toBeNull()
    expect(windowsOf('', '')).toEqual([])
    const rows = rowsOf(await control.windows())
    expect(rows.windows[0].slot).toBeUndefined()
    expect(rows.windows[0].session).toBeUndefined()
  })

  it('never files a window under a session id, not even for an instant', async () => {
    /*
     * The regression guard for the sentinel. `open` used to call the session
     * door with `sessionId: ''` and `detach` in the same breath, which left one
     * binding row with no windows in it for the life of the process and made the
     * id-recovery a diff of that store. A door that mints without binding is not
     * a smaller version of that — it never touches the store at all.
     */
    await openOne()
    expect(view().sessions).toEqual([])
  })

  it('turns what somebody typed into a URL before anything is opened', async () => {
    await control.open({ t: 'browser.window.open', url: 'example.com/pricing' })
    // Normalized here rather than in the drive under it, because the door this
    // host opens windows through does not normalize and a bare host would reach
    // Chromium as a relative address.
    expect(browser.opened).toEqual(['http://example.com/pricing'])
  })

  it('opens a blank page when no address was given', async () => {
    // `url` absent means *the machine's own start page*, and a server has none.
    // `about:blank` is the one address outside http(s) the navigation guard
    // permits, which is why it is not run through the normalizer.
    await control.open({ t: 'browser.window.open' })
    expect(browser.opened).toEqual(['about:blank'])
  })

  it('opens an isolated window in a jar of its own, rather than refusing', async () => {
    /*
     * *"Making a browsing session into an isolated or shared one"* used to be a
     * refusal here — truthfully, because the only door hard-coded
     * `isolate: false`. The flag now reaches the authority, where it is a
     * throwaway `Target.createBrowserContext`, and the row says which kind of
     * window it is.
     */
    const rows = rowsOf(await control.open({ t: 'browser.window.open', url: 'https://a.test/', isolated: true }))
    expect(browser.jars).toEqual([{ isolate: true, profileId: 'default' }])
    expect(rows.notice).toContain('isolated')
    expect(rows.windows[0].isolated).toBe(true)
  })

  it('opens a window in a named profile, and says which one it is in', async () => {
    // A profile is a second Chromium against `<userData>/Partitions/<id>`. This
    // module's job is only to carry the id there unchanged; the authority is
    // what refuses one this machine does not have.
    const rows = rowsOf(
      await control.open({ t: 'browser.window.open', url: 'https://a.test/', profile: PROFILE }),
    )
    expect(browser.jars).toEqual([{ isolate: false, profileId: PROFILE }])
    expect(rows.windows[0].profile).toBe(PROFILE)
  })

  it('passes on the authority’s refusal of a profile this machine does not have', async () => {
    browser.refusal = "This server's browser cannot open a window there: that is not a profile on this machine."
    const rows = rowsOf(
      await control.open({ t: 'browser.window.open', url: 'https://a.test/', profile: PROFILE }),
    )
    expect(browser.opened).toEqual([])
    expect(rows.notice).toContain('not a profile on this machine')
  })

  it('passes on the browser’s own sentence when Chromium would not start', async () => {
    /*
     * The reason this seam exists: a desktop's `null` means the window declined
     * and has one true sentence, a server's means a browser that could not be
     * started and has a different one for each cause — a missing binary, a
     * missing library, a sandbox refusal. `browser-chromium-launch.ts` writes
     * those, and they name the command that fixes it, so they must reach the
     * phone verbatim rather than being replaced by a generic line.
     */
    browser.refusal = 'libnss3 is not installed on this machine; run apt install libnss3.'
    const rows = rowsOf(await control.open({ t: 'browser.window.open', url: 'https://a.test/' }))
    expect(rows.notice).toContain('apt install libnss3')
  })
})

/* ----------------------------------------------------------------- list -- */

describe('the window list', () => {
  it('reads every fact off the live page rather than off anything remembered', async () => {
    const id = await openOne()
    const page = browser.pageOf(id)
    page.rename('Pricing — Example')
    page.loading = true
    await page.loadURL('https://example.com/pricing/enterprise')

    const rows = rowsOf(await control.windows())
    expect(rows.windows[0].title).toBe('Pricing — Example')
    expect(rows.windows[0].url).toBe('https://example.com/pricing/enterprise')
    expect(rows.windows[0].loading).toBe(true)
  })

  it('lists a window a session on this host opened, and keeps it after that session ends', async () => {
    /*
     * The other door. An agent's `browser_open` and `open <url>` at a prompt
     * both reach `openForSession` directly, so those windows arrive in the
     * binding store having never passed through this module — and when the pty
     * goes, `sessionRemoved` drops their rows. A list built from the store alone
     * would lose the window at that moment while the page stayed open in
     * Chromium, which is a page nobody could ever close.
     */
    sessions = [{ id: 'session-1', title: 'Orders' }]
    await browser.openForSession({ url: 'https://example.com/orders', sessionId: 'session-1' })
    const [held] = windowsOf('session-1', '')
    expect(held).toBeDefined()

    const bound = rowsOf(await control.windows())
    expect(bound.windows.map((row) => row.id)).toEqual([held.browserTabId])
    expect(bound.windows[0].slot).toBe('B1')
    expect(bound.windows[0].sessionTitle).toBe('Orders')

    // The session ends and its rows go with it — `sessionRemoved` is the exact
    // call `host.ts` makes on `onSessionRemoved`. The page has not gone.
    sessionRemoved('session-1')
    sessions = []
    const after = rowsOf(await control.windows())
    expect(after.windows.map((row) => row.id)).toEqual([held.browserTabId])
    expect(after.windows[0].slot).toBeUndefined()
  })

  it('drops a window whose page has gone, and takes its binding row with it', async () => {
    sessions = [{ id: 'session-1', title: 'Orders' }]
    const id = await openOne()
    rowsOf(await control.bind({ t: 'browser.window.bind', id, session: 'session-1' }))
    expect(windowsOf('session-1', '')).toHaveLength(1)

    // Closed inside the browser, or died with its tab. Nothing told this module.
    browser.lose(id)
    const rows = rowsOf(await control.windows())
    expect(rows.windows).toEqual([])
    // A binding row outliving the page is an agent steering a window that is
    // not there — the one outcome the store's own header refuses.
    expect(windowsOf('session-1', '')).toEqual([])
  })
})

/* ----------------------------------------------------------- navigating -- */

describe('navigating a window', () => {
  it('goes through the page’s own beforeunload, not around it', async () => {
    const id = await openOne()
    rowsOf(await control.go({ t: 'browser.window.go', id, url: 'example.com/contact' }))
    expect(browser.pageOf(id).went).toContain('http://example.com/contact')
  })

  it('says so when the page reports unfinished work instead of navigating over it', async () => {
    const id = await openOne()
    browser.pageOf(id).unfinished = true
    const rows = rowsOf(await control.go({ t: 'browser.window.go', id, url: 'https://a.test/' }))
    expect(rows.notice).toContain('unfinished work')
    expect(browser.pageOf(id).went).not.toContain('https://a.test/')
  })

  it('reloads by sending the page back to where it already is', async () => {
    const id = await openOne('https://example.com/pricing')
    rowsOf(await control.act({ t: 'browser.window.act', id, action: 'reload' }))
    expect(browser.pageOf(id).went).toEqual(['https://example.com/pricing'])
  })

  it('goes back and forward through the window’s own history', async () => {
    /*
     * Both of these used to be refusals — `Page.navigateToHistoryEntry` names an
     * entry id rather than an address, so the navigation guard, *"the only guard
     * there is"* on this transport, had nothing to screen. The guard was not
     * routed around: the authority reads the target's own history and screens
     * the neighbouring entry's URL before naming its id. From here that is one
     * call, against the window's own view.
     */
    const id = await openOne()
    const viewId = browser.byTab.get(id) as string
    for (const action of ['back', 'forward'] as const) {
      const rows = rowsOf(await control.act({ t: 'browser.window.act', id, action }))
      expect(rows.notice, action).toBeUndefined()
    }
    expect(browser.moves).toEqual([
      { viewId, move: 'back' },
      { viewId, move: 'forward' },
    ])
  })

  it('says what the machine said when there is nothing to go back to', async () => {
    // A window on its first page has no earlier entry, and that is a sentence
    // from the machine rather than a dead button.
    const id = await openOne()
    browser.noHistory = 'that window has nothing to go back to'
    const rows = rowsOf(await control.act({ t: 'browser.window.act', id, action: 'back' }))
    expect(rows.notice).toContain('nothing to go back to')
  })
})

/* --------------------------------------------------------- the cookie jar -- */

describe('moving a window between the two kinds of cookie jar', () => {
  it('re-opens the page in the other jar and keeps the window id', async () => {
    /*
     * The property this whole verb is built around: the window id is the binding
     * key `B2` is minted from, and *"a renumbered window makes an agent point
     * confidently at the wrong page, and it does it within a turn"*. So the view
     * id moves and the window id does not.
     */
    const id = await openOne()
    const before = browser.byTab.get(id) as string

    const rows = rowsOf(await control.act({ t: 'browser.window.act', id, action: 'isolate' }))
    expect(browser.repartitions).toEqual([{ browserTabId: id, isolate: true }])
    expect(rows.notice).toContain('isolated')
    expect(rows.windows[0].id).toBe(id)
    expect(browser.byTab.get(id)).not.toBe(before)
    expect(rows.windows[0].isolated).toBe(true)
  })

  it('keeps a bound window pointed at the page it moved to', async () => {
    // `browser-control.ts` tells the binding store the new view id, and this is
    // the half that would otherwise be *"a URL that lands nowhere while the app
    // answers that it landed in B1"*.
    sessions = [{ id: 'session-1', title: 'Orders' }]
    const id = await openOne()
    rowsOf(await control.bind({ t: 'browser.window.bind', id, session: 'session-1' }))

    rowsOf(await control.act({ t: 'browser.window.act', id, action: 'isolate' }))
    const [bound] = windowsOf('session-1', '')
    expect(bound.browserTabId).toBe(id)
    expect(bound.viewId).toBe(browser.byTab.get(id))
    expect(bound.n).toBe(1)
  })

  it('shares an isolated window again, and says so once it has', async () => {
    const id = await openOne()
    rowsOf(await control.act({ t: 'browser.window.act', id, action: 'isolate' }))
    const rows = rowsOf(await control.act({ t: 'browser.window.act', id, action: 'share' }))
    expect(rows.notice).toContain('shared')
    expect(rows.windows[0].isolated).toBeUndefined()
  })

  it('does not report a move the machine could not make', async () => {
    // The window is left exactly as it was — the authority opens the new page
    // before closing the old one — so the answer has to say so rather than
    // redrawing a row that did not change and calling it done.
    const id = await openOne()
    browser.cannotRepartition = true
    const rows = rowsOf(await control.act({ t: 'browser.window.act', id, action: 'isolate' }))
    expect(rows.notice).toContain('could not be isolated')
    expect(rows.windows[0].isolated).toBeUndefined()
  })
})

/* -------------------------------------------------------------- closing -- */

describe('closing a window', () => {
  it('closes it through the tab authority and says which one went', async () => {
    const id = await openOne()
    const rows = rowsOf(await control.act({ t: 'browser.window.act', id, action: 'close' }))
    expect(browser.byTab.has(id)).toBe(false)
    expect(rows.windows).toEqual([])
    expect(rows.notice).toContain('Closed')
  })

  it('does not report a close this host could not perform', async () => {
    /*
     * `closeWindow` answers `false` for a window it holds no target for, and
     * `browser-control.ts` reads a resolved promise as *"Closed X."* — so
     * swallowing that answer would tell somebody their page had gone while it
     * sat there in front of them.
     */
    const id = await openOne()
    browser.byTab.delete(id)
    const rows = rowsOf(await control.act({ t: 'browser.window.act', id, action: 'close' }))
    expect(rows.notice).toContain('no longer holding')
    expect(rows.notice).not.toContain('Closed')
  })
})

/* -------------------------------------------------------------- binding -- */

describe('binding a window to a session', () => {
  it('gives it the number the agent will read in its next turn', async () => {
    /*
     * *"so the session knows which browsing window it is working on."* This is
     * the whole feature and it is one call: the phone binds into the same store
     * the hook answer is composed from, so nothing else has to be wired for the
     * agent to be told about `B1`.
     */
    sessions = [{ id: 'session-1', title: 'Orders' }]
    const id = await openOne()
    const rows = rowsOf(await control.bind({ t: 'browser.window.bind', id, session: 'session-1' }))

    expect(rows.notice).toContain('B1')
    expect(windowsOf('session-1', '')[0].browserTabId).toBe(id)
    expect(rows.sessions).toEqual([{ id: 'session-1', title: 'Orders', windows: 1 }])
  })

  it('refuses a session this host never listed, whatever the id came from', async () => {
    const id = await openOne()
    const rows = rowsOf(await control.bind({ t: 'browser.window.bind', id, session: 'somebody-elses' }))
    expect(rows.notice).toContain('No session by that name')
    expect(ownerOf(id)).toBeNull()
  })
})

/* ---------------------------------------------------------- photographs -- */

describe('photographing a window', () => {
  it('takes the picture through the drive slot an agent would use, not a second one', async () => {
    const id = await openOne()
    const answer = await control.shot({ t: 'browser.window.shot', id })

    /*
     * One slot per window. The drive keys its slots on `boundKey(browserTabId)`
     * and so does everything else that steers one, so a screenshot taken from a
     * phone lands in the same slot the session's own `browser_read` uses — a
     * second slot would be a second baton, and the handover that stops an agent
     * mid-password would only stop one of them.
     */
    expect(shots).toHaveLength(1)
    expect(shots[0].key).toBe(boundKey(id))
    expect(shots[0].browserTabId).toBe(id)
    // Never the id. `browser:<epoch>:<uuid>` on a screen was a defect once.
    expect(shots[0].name).not.toContain('browser:')

    expect(answer.t).toBe('browser.shot')
    const shot = answer as Extract<ServerMessage, { t: 'browser.shot' }>
    expect(Buffer.from(shot.png, 'base64').toString()).toBe(readFileSync(shotFile).toString())
  })

  it('sends it to a session with the same two writes the wire’s own input frame makes', async () => {
    /*
     * *"take a screenshot and send to the session (whatever session we want to
     * send)"* — and the route it takes is the desktop's, exactly. Two writes
     * with a gap on the clock, because the CLI classifies a chunk of about 64
     * bytes or more as *pasted text*, where a carriage return is a newline
     * rather than submit: every line this composes carries a path and a size and
     * is well over that, so a single `${line}\r` is a send button that never
     * sends.
     */
    sessions = [{ id: 'session-1', title: 'Orders' }]
    const id = await openOne('https://example.com/pricing')
    const rows = rowsOf(
      await control.shot({ t: 'browser.window.shot', id, session: 'session-1', note: 'why is this red' }),
    )

    expect(typed.map((write) => write.session)).toEqual(['session-1', 'session-1'])
    expect(typed[0].data).toContain('why is this red')
    expect(typed[0].data).toContain(shotFile)
    expect(typed[0].data).toContain('1200 x 800')
    expect(typed[0].data).toContain('https://example.com/pricing')
    // The line is one line: a newline inside it submits the prompt half-written.
    expect(typed[0].data).not.toContain('\n')
    expect(typed[1].data).toBe('\r')
    expect(rows.notice).toContain('Sent')
  })

  it('takes no picture at all for a session that is not running here', async () => {
    // Resolved before the capture rather than after: a file written to somebody's
    // disk for a message that was never going anywhere is the one side effect
    // nobody is present to notice on a server.
    const id = await openOne()
    const rows = rowsOf(await control.shot({ t: 'browser.window.shot', id, session: 'ghost' }))
    expect(shots).toEqual([])
    expect(rows.notice).toContain('No session by that name')
  })
})

/* ------------------------------------------------------- what it cannot -- */

describe('the controls a server’s browser does not have', () => {
  it('says it cannot record a click flow instead of drawing a button that collects nothing', async () => {
    /*
     * The recorder is an Electron `session` preload collected in
     * `browser-view.ts`; the CDP side has the delivery mechanism and nothing
     * wired to it. Absence is the switch: no `recorder` dep, so both the verb
     * and the reader answer with the window list and a sentence.
     */
    const id = await openOne()
    for (const action of ['record.on', 'record.off']) {
      expect(rowsOf(await control.act({ t: 'browser.window.act', id, action })).notice).toContain(
        'cannot record a click flow',
      )
    }
    expect(rowsOf(await control.steps({ t: 'browser.window.steps', id })).notice).toContain(
      'cannot record a click flow',
    )
  })

})

/* ----------------------------------------------------------- the seam -- */

describe('the wiring this lane added stays outside Electron', () => {
  /*
   * `seam.test.ts` is the authority: it walks the whole import graph from both
   * headless entry points and fails on a single runtime `electron` import, and
   * both files below are inside that graph because `host.ts` imports one and
   * `daemon.ts` imports `host.ts`. `host.test.ts` is the second proof and the
   * stronger one — it boots a real headless host under plain Node, where an
   * Electron import anywhere in the graph fails the import rather than an
   * assertion.
   *
   * This is the near check on the two files the lane wrote, kept because a lane
   * that adds an import to `host.ts` is exactly the lane that would notice this
   * failing first, before the graph walk that runs in a different file.
   */
  const withoutComments = (source: string): string =>
    source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^[ \t]*\/\/.*$/gm, '')

  it('imports nothing from electron, in either spelling', () => {
    for (const file of ['machine-browser.ts', 'host.ts']) {
      const source = withoutComments(readFileSync(join(__dirname, file), 'utf8'))
      expect(source, file).not.toMatch(/from\s*['"]electron['"]/)
      expect(source, file).not.toMatch(/require\(\s*['"]electron['"]\s*\)/)
    }
  })
})
