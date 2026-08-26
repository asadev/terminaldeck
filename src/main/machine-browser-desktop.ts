import { normalizeUrl } from './browser-url'
import type { PickedElement } from './browser-driver'
import type { RecordedStep } from './browser-steps'
import {
  machineBrowser,
  type CapturedShot,
  type HostSession,
  type MachineBrowser,
  type MachineBrowserDeps,
  type OpenWindow,
} from './remote/browser-control'

/*
 * Re-exported rather than re-declared. `CapturedShot` and `HostSession` are two
 * of the eight things {@link DesktopBrowserAccess} is made of, so a caller
 * implementing that interface needs their names — and a second declaration of
 * either here is a shape that can drift from the one the wire actually carries.
 */
export type { CapturedShot, HostSession } from './remote/browser-control'

/**
 * The desktop half of *"the machine's own browser, driven from the phone"*.
 *
 * `remote/browser-control.ts` is the host-side of every `browser.window.*`
 * frame, and it reaches the machine through {@link MachineBrowserDeps} and
 * nothing else — its header says why, at length: the same module has to serve a
 * server with no Electron in it. This file is the Electron app's answer to that
 * interface. `src/headless/host.ts` writes the other one over its own Chromium,
 * and neither knows the other exists.
 *
 * ## The one fact about this app that shapes every method below
 *
 * **The desktop's browser windows belong to the renderer, not to this process.**
 * A window is a *pane* in the shell — one row in the sidebar, one page — minted
 * by `App.tsx` as `browser:<epoch-ms>:<seq>`; the `WebContentsView` inside it is
 * created by `browser:create` and wears a `randomUUID()` of its own. So there
 * are two ids for what a person calls one window, and they are not
 * interchangeable:
 *
 *  - the **window id** is the pane's shell tab id. It is the binding key, it is
 *    what `B2` is minted from, and it lasts the whole life of the window.
 *  - the **view id** is the page currently inside it. It is what steers, and it
 *    is re-minted underneath a window that has not moved — the isolation switch
 *    closes the view and opens another at the same address.
 *
 * `browser-binding.ts` chose the first as its key for exactly that reason, and
 * `OpenWindow.id` carries the same rule in as many words: *"neither may be a
 * view id"*. Every method here therefore does the same two steps — find the
 * pane by its window id, then resolve the view inside it — and a window whose
 * page has not arrived yet answers with a sentence rather than steering
 * something else. That beat is real: the shell tab id exists the moment the
 * renderer mints it, and `browser:window-opened` carries the view a beat later,
 * which is the whole reason `paneView` waits.
 *
 * ## What the desktop can serve, and the two things it cannot
 *
 * Asad's list, on the browser screen:
 *
 * > *"like recording the clicks flow, creating a screenshot and sending it to
 * > the session (whatever session we want to send, take a screenshot and send to
 * > the session) … Making a browsing session into an isolated or shared one …
 * > We don't have an option to connect any browsing window to any session, so
 * > the session knows which browsing window it is working on."*
 *
 * Listing, opening, navigating, back/forward/reload, closing, binding to a
 * session, the recorder and both screenshot routes are all here and all reach
 * the same code the window's own buttons reach. Two clauses do not, and the
 * reason is the same for both, so it is written once:
 *
 * **Nothing in the main process can re-partition or isolate a pane.** A page's
 * session is fixed when the `WebContentsView` is constructed, so converting one
 * is a close-and-reopen — `BrowserWorkspace.toggleIsolation` in the renderer,
 * reached from a button and from nowhere else. There is no channel into it:
 * `LINK_TAB_CHANNEL` carries `{ url, requestId, sessionId?, machineId? }` and
 * has no room for a partition or a profile, and `browser:create` needs a
 * renderer `event.sender` to attach the view to and to be claimed by — a view
 * this process created for itself would be laid out by nobody, sized 0×0, and
 * unreachable from any strip, which is *"a tab you did not open and cannot
 * account for"*, the object this app refuses to produce.
 *
 * So {@link MachineBrowserDeps.repartition} is **absent**, which is the switch
 * `browser-control.ts` reads to answer Isolate with a sentence instead of a
 * pretence; and an `open` asking for an isolated window or a named profile is
 * refused through {@link MachineBrowserDeps.whyNotOpen} rather than quietly
 * given a shared one in whichever profile happens to be switched on. A window
 * that says it is isolated and is not is a cookie jar somebody trusted.
 *
 * ## `resize` is absent on purpose, and it is the one absence that is a rule
 *
 * `browser.window.size` asks a machine to lay a window's page out in the
 * rectangle the phone is going to draw it into, so what arrives is the page at
 * 100% instead of at whatever ratio two unrelated numbers happened to make:
 *
 * > *"it opens a very big page then it compares to the normal size… it should
 * > always open to the normal size."*
 *
 * A headless host supplies it (`src/headless/machine-browser.ts`). **This one
 * must not**, and the difference is not a limit of the desktop — it is the
 * decision `browser-cdp.ts` already wrote down in one line when it put
 * `Emulation.setDeviceMetricsOverride` on `DENIED_METHODS` for every caller on
 * the Electron transport: *"Changes the viewport under a person who may be
 * reading the page."*
 *
 * On a headless host nobody is. There is no window, no screen and nobody at the
 * keyboard, and the viewport is simply the size of the hole a phone is about to
 * draw a picture into. On a desktop the page is a `WebContentsView` on
 * somebody's screen: they may be halfway down it, mid-form, mid-sentence, and a
 * phone in another room reflowing it under them is the app acting on its own —
 * the class of behaviour that whole file exists to make impossible. It is also
 * not a thing this file could route around if it wanted to: reflowing a pane is
 * a layout the renderer owns, and the emulation route into it is the dead end
 * `BrowserDrive.showWindow` records having spent an afternoon on.
 *
 * So {@link MachineBrowserDeps.resize} is left off this deps object, and
 * `browser-control.ts` reads the absence and answers Size with one sentence —
 * *"This machine's browser lays its own windows out, so this one cannot be
 * resized from here."* — rather than a control that takes a tap and changes
 * nothing. Somebody widening the allow-list for the headless transport must not
 * quietly widen it here; the two tables are separate and
 * `browser-cdp.test.ts` asserts each pair is disjoint.
 *
 * ## Pointing at one thing, declared here and wired in `index.ts`
 *
 * `browser.window.pick` — the tap that says *change this* on a window the phone
 * is only watching — needs one script run inside the page, and on the desktop
 * the only thing that runs scripts in a pane is the drive, which this file
 * cannot reach. So {@link DesktopBrowserAccess.pick} is declared here and
 * `index.ts` supplies it, exactly as it already supplies
 * {@link DesktopBrowserAccess.closePane} out of the same drive. This is the
 * entry it supplies, and the two paragraphs under it are why it is shaped that
 * way — read the one beside it in `index.ts` for the same argument from the
 * other end:
 *
 * ```ts
 * pick: async ({ id, viewId, name, x, y, up }) => {
 *   const drive = browserDrive()
 *   if (drive === null) throw new Error(NO_DRIVE_TO_PICK)
 *   return drive.pickAt(x, y, up, { key: boundKey(id), viewId, browserTabId: id, name })
 * },
 * ```
 *
 * Two details of that entry are load-bearing and were got wrong once. It is
 * supplied **unconditionally**, and resolves the drive on each call, because
 * `machineBrowserHere()` is composed hundreds of lines before the drive is
 * published — supplying it only where a drive already exists would have left
 * the feature silently dead on every boot. And a null drive is a fact about the
 * whole app, not about one window: `BrowserDrive.slotFor` mints a slot the first
 * time a window is named, so a window nobody has ever driven picks fine. The
 * sentence is therefore *"this app has no browser running"*, which the phone
 * shows as *"B2 could not be looked at: this app has no browser running."*
 *
 * A headless host needs no such line: its `MachineBrowser` is built over the
 * drive already.
 *
 * The id discipline the switch demands is nevertheless already true here and
 * costs nothing: the desktop's binding is keyed on the pane, and the isolation
 * switch replaces only the view inside it, so a window converted at the keyboard
 * keeps its number and its slot while `browser:window-opened` re-reports the new
 * view id through `windowMoved`. When a route into the renderer exists, this
 * file supplies `repartition` by asking for it and answering with the new view
 * id; nothing about the window id has to change for that to be safe.
 *
 * ## Why the seam below has no Electron in it
 *
 * {@link DesktopBrowserAccess} is eight small functions over plain data. That is
 * not tidiness — it is what lets `machine-browser-desktop.test.ts` drive every
 * refusal, every id mapping and both screenshot routes over three arrays,
 * without an `app`, a window or a `WebContentsView`. `index.ts` supplies the
 * real ones out of `knownWindows()`, `browserTabContents()`, `openBarePane()`,
 * `captureBrowserView()` and the drive, each of which is the same function the
 * window's own buttons go through. There is deliberately no second window map, no
 * second screenshots folder and no second recorder here: a second copy of any of
 * those is how the pane bar and the phone come to disagree about the page an
 * agent is steering.
 */

/* ------------------------------------------------------------------ seam -- */

/** One browser pane the shell has reported — `knownWindows()`, narrowed. */
export interface DesktopPane {
  /** The shell tab id. The binding key, and the id every frame names. */
  id: string
  /** The page inside it, or null before the window has reported one. */
  viewId: string | null
  /** What the window last said it was showing. */
  url: string
  title: string
}

/**
 * The live page inside one view.
 *
 * Structural rather than a `WebContents`, so this module can be read and tested
 * without Electron. `index.ts` adapts the real one; the methods are exactly the
 * four the desktop's own `browser:navigate`, `browser:back`, `browser:forward`
 * and `browser:reload` perform.
 */
export interface DesktopPage {
  /**
   * Where the page is, as the **main process** knows it.
   *
   * Never the page's own claim about its address. This string reaches an agent's
   * prompt in a screenshot line, and a page that can lie about where it is must
   * not also get to name the site somebody is told they are looking at — the
   * rule `browser-view.ts` and `browser-tab.ts` both keep at their own guest
   * boundaries.
   */
  url: string
  loading: boolean
  /**
   * The profile whose cookie jar this page is in, or `''` for an Isolated one.
   *
   * The same spelling `browserTabProfile` uses and for the same reason it uses
   * it: an isolated tab is nobody's profile, its partition lives in memory and
   * dies with the window, so it has no name to wear. The empty string is
   * therefore load-bearing here — it is what {@link OpenWindow.isolated} is
   * derived from — rather than a missing value.
   */
  profile: string
  go(url: string): void
  back(): void
  forward(): void
  reload(): void
}

/** The click-flow recorder, as `browser-view.ts` already keeps it, by view id. */
export interface DesktopRecorderAccess {
  /** What has been collected on that page. Synchronous: it is already in memory. */
  state(viewId: string): { recording: boolean; steps: readonly RecordedStep[] }
  set(viewId: string, on: boolean): void
}

/** Everything this module reaches the desktop's browser through. */
export interface DesktopBrowserAccess {
  /** Every pane the shell holds, bound or not, in the order it lists them. */
  panes(): readonly DesktopPane[]
  /** The page inside a view, or null once it has gone. */
  page(viewId: string): DesktopPage | null
  /**
   * Open a pane belonging to nobody at `url`, and answer its shell tab id.
   *
   * `openBarePane`, which is the route the globe and every link already take —
   * so a window opened from the phone is a row in the sidebar the person can
   * see, name and close, rather than a page in no strip anywhere.
   */
  openPane(url: string): Promise<string | null>
  /**
   * Close a pane through the window that owns it, and say whether it went.
   *
   * Through the renderer rather than by destroying the view here, for the reason
   * `DriveHost.closeWindow` gives: a view torn down underneath a strip that
   * still lists it is the ghost-row failure, and a window that cannot be found
   * is exactly what this feature must not produce.
   */
  closePane(input: { id: string; viewId: string; name: string }): Promise<boolean>
  /** The desktop's own screenshot path — same folder, same filename, same preview. */
  capture(viewId: string): Promise<CapturedShot>
  /**
   * What is at one point on a window's page — the tap that says *change this*.
   *
   * Shaped like {@link closePane} rather than like {@link capture}, and the
   * difference is the reason: this goes through the **drive**, and a drive call
   * names a window by all three of its ids plus the name a person says out loud.
   * `index.ts` mints that target exactly as it does for a close —
   * `drive.pickAt(x, y, up, { key: boundKey(id), viewId, browserTabId: id, name })`
   * — so a pick lands in the *same* slot an agent driving the window uses rather
   * than a second one, and the drive's own refusal (the person has taken the
   * page during a handover) comes back as the sentence it wrote.
   *
   * Optional, on the rule every optional member of `MachineBrowserDeps` follows:
   * a build with no drive wired simply does not have it, and the phone is told
   * so in one sentence instead of being handed an inspect button that answers
   * nothing.
   */
  pick?(input: {
    id: string
    viewId: string
    name: string
    x: number
    y: number
    up: number
  }): Promise<PickedElement>
  /** Absent in a build with no recorder wired; the phone is then told so. */
  recorder?: DesktopRecorderAccess
  /** The sessions a window could be bound to. Read per verb, never cached. */
  sessions(): readonly HostSession[]
  /** `SessionAccess.write` — the same write `session.send` performs. */
  write(sessionId: string, data: string): void
}

/* -------------------------------------------------------------- refusals -- */

/**
 * What an `open` that asked for a partition this process cannot mint is told.
 *
 * Named constants because both of them are answers to a control the phone
 * genuinely draws, and a person who pressed Isolated is owed the reason rather
 * than a window that comes back shared. See the header for why neither is
 * reachable from here.
 */
const NO_ISOLATED_OPEN =
  'This computer opens browser windows in its own window, which cannot mint an isolated partition from here — open it, then use Isolate at the keyboard.'

const NO_PROFILE_OPEN =
  'This computer opens browser windows in the profile it is switched to; choosing another one is done at its keyboard.'

/** What a pane whose page has not arrived — or has gone — is told. */
const NO_PAGE = 'that window has no page in it yet'

/* ----------------------------------------------------------------- build -- */

/**
 * The desktop's `MachineBrowser`, ready to hand to `RemoteEndpointOptions`.
 *
 * Its **presence** is what makes the endpoint advertise `browser.control` at
 * all, so a build that cannot reach a browser must pass nothing rather than one
 * of these that refuses everything — the same negotiation every other capability
 * on that interface gets.
 */
export function desktopMachineBrowser(access: DesktopBrowserAccess): MachineBrowser {
  /**
   * Why the last {@link MachineBrowserDeps.open} produced nothing.
   *
   * Held between the two calls because that is the shape `whyNotOpen` has, and
   * it has that shape because the desktop's `null` and a server's `null` mean
   * different families of thing — see its own doc. Cleared at the top of every
   * open so a stale sentence can never be attached to a later failure.
   */
  let refusal = ''

  const paneOf = (id: string): DesktopPane | null =>
    access.panes().find((pane) => pane.id === id) ?? null

  /**
   * The view inside a window, or a throw carrying the sentence to show.
   *
   * A throw rather than a null because every caller of this is inside a verb
   * that `browser-control.ts` already wraps in a `catch` which turns an error
   * into the window list plus one line — so the sentence lands on the phone
   * either way, and this keeps the verbs to one statement each.
   */
  const viewOf = (id: string): string => {
    const pane = paneOf(id)
    if (!pane || pane.viewId === null) throw new Error(NO_PAGE)
    return pane.viewId
  }

  const pageOf = (id: string): DesktopPage => {
    const page = access.page(viewOf(id))
    if (!page) throw new Error(NO_PAGE)
    return page
  }

  /**
   * Whether a view is recording, for a *row*.
   *
   * Guarded, because this is asked once per window on every list and the
   * recorder only knows views its renderer has claimed. A pane mid-mount, or one
   * whose page has just died, throws from `entryFor` — and a whole window list
   * that fails because one row could not answer a flag would be the screen going
   * blank over a detail nobody asked about.
   */
  const isRecording = (viewId: string): boolean => {
    if (!access.recorder) return false
    try {
      return access.recorder.state(viewId).recording
    } catch {
      return false
    }
  }

  const deps: MachineBrowserDeps = {
    list: async () =>
      access.panes().map((pane): OpenWindow => {
        const page = pane.viewId === null ? null : access.page(pane.viewId)
        const row: OpenWindow = {
          id: pane.id,
          title: pane.title,
          // The main process's address when there is a live page, and the
          // window's last report otherwise — a pane whose view has gone still
          // has a row, and a row with no address is one nobody can identify.
          url: page?.url || pane.url,
          viewId: pane.viewId,
        }
        if (page) {
          if (page.profile === '') row.isolated = true
          else row.profile = page.profile
          if (page.loading) row.loading = true
          if (pane.viewId !== null && isRecording(pane.viewId)) row.recording = true
        }
        return row
      }),

    open: async (input) => {
      refusal = ''
      /*
       * Refused rather than downgraded. Both of these are controls the phone
       * draws, and the honest failure is a sentence: a window handed back as
       * shared when somebody asked for isolated is a cookie jar they think is
       * empty, and one opened in whichever profile is switched on is somebody
       * else's logins.
       */
      if (input.isolated) {
        refusal = NO_ISOLATED_OPEN
        return null
      }
      if (input.profile !== '') {
        refusal = NO_PROFILE_OPEN
        return null
      }
      /*
       * The url goes across untouched, empty included: empty means *this
       * machine's own start page*, and the pane opens at whatever that is. What
       * a non-empty one means is decided by `normalizeUrl` inside
       * `browser:create`, which is the same answer the address bar gets.
       */
      const opened = await access.openPane(input.url)
      if (opened === null) {
        refusal =
          'No window of this app answered, so there was nowhere to put the page — its browser may be switched off in Features.'
      }
      return opened
    },

    whyNotOpen: () => refusal || null,

    go: async (id, url) => {
      /*
       * Normalized here, because this is the layer under the wire and the wire's
       * own module says so: one spelling of *what is a URL*, or the phone's
       * address bar and this app's come to disagree about `example.com`. The
       * page is resolved first so a window with nothing in it says so rather
       * than reporting a bad address.
       */
      const page = pageOf(id)
      const normalized = normalizeUrl(url)
      if (!normalized.ok) throw new Error(normalized.reason)
      page.go(normalized.url)
    },

    history: async (id, move) => {
      const page = pageOf(id)
      if (move === 'back') page.back()
      else if (move === 'forward') page.forward()
      else page.reload()
    },

    close: async (id) => {
      const pane = paneOf(id)
      if (!pane) throw new Error('that window is not open here')
      const went = await access.closePane({
        id: pane.id,
        viewId: pane.viewId ?? '',
        // What the window is called, for the refusal the layer under this
        // composes. Never the id: an id in a sentence is a sentence nobody can
        // act on.
        name: pane.title || pane.url,
      })
      if (!went) throw new Error('the window that holds it did not answer')
    },

    capture: (id) => access.capture(viewOf(id)),

    sessions: () => access.sessions(),

    write: (sessionId, data) => {
      access.write(sessionId, data)
    },
  }

  /*
   * Pointing at one thing, on the same absence-is-the-switch rule as the
   * recorder below. The ids swap here the way they do there — the wire names a
   * window, the drive needs the view inside it and the name a person reads —
   * which is the whole reason this is a wrapper rather than a pass-through.
   *
   * The name comes off the pane rather than being invented, because it is what
   * the drive puts in its own refusals — *"B1 is not open any more"* — and an
   * id in a sentence is a sentence nobody can act on. A pane whose page has not
   * arrived still throws out of `viewOf`, and *that window has no page in it
   * yet* is the right answer for it.
   */
  if (access.pick) {
    const ask = access.pick
    deps.pick = async ({ id, x, y, up }) => {
      const pane = paneOf(id)
      return ask({
        id,
        viewId: viewOf(id),
        name: pane?.title || pane?.url || 'That window',
        x,
        y,
        up,
      })
    }
  }

  /*
   * The recorder, spread on the same rule every optional dep here follows:
   * absent means the phone is told this machine's browser cannot record a click
   * flow, rather than offered a Record button that does nothing. The ids swap
   * here — the wire names a window, `browser-view.ts` keeps its steps per view —
   * which is the whole reason these are two lines rather than a pass-through.
   */
  if (access.recorder) {
    const recorder = access.recorder
    deps.recorder = {
      set: async (id, on) => {
        recorder.set(viewOf(id), on)
      },
      read: async (id) => {
        const state = recorder.state(viewOf(id))
        return { recording: state.recording, steps: state.steps }
      },
    }
  }

  return machineBrowser(deps)
}
