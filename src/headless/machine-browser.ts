/**
 * The server's own browser, as the phone's window screen sees it.
 *
 * `src/main/remote/browser-control.ts` is the host half of every
 * `browser.window.*` frame — list, open, navigate, back, close, bind, isolate,
 * photograph, record — and it reaches the machine through one small object,
 * {@link MachineBrowserDeps}, with no Electron type in it. Its header says why:
 *
 * > *"This has to work on a server with no Electron `app`, no window and nobody
 * > at the keyboard — 'this should be directly synced to the headless one'."*
 *
 * This file is that object, built over the two things a headless host already
 * has: `HeadlessDriveHost`, which is the tab authority for a real Chromium of
 * this machine's own, and `BrowserDrive`, which is the engine that steers and
 * photographs a page. Nothing is re-implemented — every verb below is one call
 * into one of those two, or into `browser-binding.ts`, which is the store both
 * the desktop and this host mint `B1` from.
 *
 * It exists as a module rather than as a block inside `host.ts` for one reason
 * that is worth the file: **the deps a server cannot supply are the interesting
 * part**, and each of them is a decision with a cause that has to be written
 * down next to it rather than four lines into an options object.
 *
 * ## Absence is the switch, and here is what is absent and why
 *
 * `browser-control.ts` makes a missing dep a sentence rather than a throw, so a
 * limit shows on the phone as a line under the window list instead of a dead
 * screen. Two are missing here, and neither is an omission:
 *
 *  - **`recorder`.** The click recorder is a preload the Electron `session`
 *    injects (`browser-record-preload.ts`, installed by `browser-profiles.ts`
 *    and `browser-isolation.ts`) and collected in `browser-view.ts`, which is a
 *    `WebContentsView` file. The CDP side has the delivery mechanism —
 *    `HeadlessDriveHost.armGuestPreload` and its one host binding — and nothing
 *    wired to it, so there is no flow to read. The panel says *"This machine's
 *    browser cannot record a click flow"*, which is true today and is a smaller
 *    lie than a Record button that collects nothing.
 *  - **`machineId`.** Empty, because these windows are on *this* machine. That
 *    is the field's documented meaning and not a shortcut.
 *
 * `repartition` was the third, and is not any more — see below.
 *
 * ## The door, and the sentinel that used to stand in for it
 *
 * `HeadlessDriveHost` opens Chromium targets through three doors, and only two
 * of them produce a window this app can ever close again. `openTab` is the
 * copilot's own tab: it mints no shell id, so nothing is written into
 * `byBrowserTab`, and `closeWindow` — which is keyed on that map — answers
 * `false` for it forever. {@link ServerWindows.openForSession} mints
 * `browser:<epoch-ms>:<uuid>` and binds it to a session.
 * {@link ServerWindows.openWindow} mints one and binds it to nothing, and it is
 * the door this file uses.
 *
 * That third door is new, and until it existed this module went through the
 * session one with a session id of `''` and undid the attach in the same
 * breath — because a window the phone opens belongs to nobody until somebody
 * binds it: *"Nothing is chosen by default. Not the focused session, not the
 * newest, not the only one."* The sentinel row was harmless and the id-recovery
 * dance around it was not: the session door answers a sentence rather than an
 * id, so the id had to be read back out of the binding store by diffing it, and
 * two opens in flight would each find both rows. The hack was written down here
 * rather than left to become the design, and it is gone: `openWindow` answers
 * the id it minted, so there is no sentinel, no diff and no queue of one.
 *
 * ## Isolated windows and profiles work here now, and what each one is
 *
 * Both used to be refusals in {@link open}, and both were true when they were
 * written: the only door hard-coded `isolate: false` and the default profile, so
 * this file could not have honoured either without lying about the result. That
 * is exactly the half of Asad's sentence a server was missing — *"Making a
 * browsing session into an isolated or shared one … We don't have profiles like
 * we have in the Mac desktop application of the browser."*
 *
 *  - **Isolated** is a `Target.createBrowserContext` — a jar that lives in
 *    memory and dies with the window, which is what an Electron partition with
 *    no `persist:` prefix is on the desktop.
 *  - **A profile** is a second Chromium process, launched against
 *    `<userData>/Partitions/<profileId>`. The host refuses an id that is not one
 *    this machine mints and one that is not in its own profile list, so a tap
 *    cannot create a jar nothing will ever list; its sentence comes back through
 *    {@link MachineBrowserDeps.whyNotOpen} rather than being replaced here.
 *
 * And `repartition` follows from the same door: converting a window between the
 * two is closing the page and opening another at the same address **under the
 * same window id**, which is what `HeadlessDriveHost.repartitionWindow` does.
 * The id is the binding key `B2` is minted from, so it is the one thing that
 * must not change.
 *
 * ## What a picture costs on a server, and why it is refused rather than cut
 *
 * `BrowserDrive.screenshot` is the only masked capture there is: it runs the
 * secret-rect script, paints password and one-time-code fields out of the raw
 * frame *before* the PNG exists (`browser-png.ts`), and writes the full
 * resolution to disk. There is no second, smaller encode on this side — the
 * desktop's preview is `nativeImage.resize`, an Electron call, and this process
 * has no image library and must not grow one to make a thumbnail. So the file
 * itself is handed back as the preview: `browser-control.ts` sends it when it
 * fits inside the wire's 47 KB and otherwise answers with a sentence naming the
 * file on disk and pointing at the route with no ceiling — *"take a screenshot
 * and send to the session (whatever session we want to send)"* — which is the
 * half of the feature he actually asked for and the half that has no size limit
 * at all.
 */

import { readFile } from 'node:fs/promises'
import { ownerOf, slotName, view, windowClosed } from '../main/browser-binding'
import { boundKey, type DriveTarget } from '../main/browser-driver'
import { BLANK_URL, normalizeUrl } from '../main/browser-url'
import { DEFAULT_PROFILE_ID } from '../main/browser-profile-storage'
import {
  machineBrowser,
  type CapturedShot,
  type HostSession,
  type MachineBrowser,
  type MachineBrowserDeps,
  type OpenWindow,
} from '../main/remote/browser-control'

/**
 * The profile a window opens into when the phone names none.
 *
 * `browser-profile-storage.ts`'s, which is the electron-free statement of
 * `browser-profiles.ts`'s `DEFAULT_PROFILE_ID` — the id whose partition predates
 * the profiles feature and holds every sign-in made before it existed. A file
 * that spelled it for itself would be a fourth copy of a string that decides
 * which cookie jar somebody's window opens in.
 */
const DEFAULT_PROFILE = DEFAULT_PROFILE_ID

/* ------------------------------------------------------------------ deps -- */

/**
 * The tab authority, as this file needs it.
 *
 * A structural interface rather than `HeadlessDriveHost` itself, for the reason
 * `CdpTransport` is one in `browser-driven-cdp.ts`: a test drives these methods
 * with no Chromium in the room, and this module then depends on the shape of the
 * authority rather than on its construction. `HeadlessDriveHost` satisfies it as
 * written.
 */
/**
 * One live page, as this file steers it.
 *
 * Five methods out of `DrivenPage`'s twenty, named here rather than imported
 * whole for the reason the interface above is structural: this module reads a
 * window's address and title and sends it to another one, and it has no business
 * being able to dispatch input, run script or take a debugger. `DrivenPage`
 * satisfies it, so `HeadlessDriveHost.contentsFor` fits with nothing in between.
 */
export interface ServerPage {
  url(): string
  title(): string
  isLoading(): boolean
  /** Straight to an address. `Page.navigate`, screened by `isNavigationAllowed`. */
  loadURL(url: string): Promise<void>
  /** The same, after the page's own `beforeunload` has been asked. */
  navigateGuarded(url: string): Promise<'navigated' | 'unfinished'>
}

export interface ServerWindows {
  /**
   * Open a window, bound to nothing, and answer the shell id it was given.
   *
   * The door this module opens every window through. It answers the id rather
   * than a sentence, which is the difference that removed the sentinel session
   * and the id-diffing around it — see the header.
   *
   * `ok: false` carries the host's own sentence: a Chromium that would not start
   * names the packages that would fix it, and a profile refusal names the
   * profile. Neither is replaced with a generic line on the way through.
   */
  openWindow(input: {
    url: string
    isolate: boolean
    profileId?: string
  }): Promise<{ ok: true; browserTabId: string; viewId: string } | { ok: false; why: string }>
  /**
   * Open a window and file it under a session.
   *
   * Not called from this module — a window the phone opens belongs to nobody —
   * but part of the same authority, and the door an agent's `browser_open` and a
   * prompt's `open <url>` arrive through. Listed here because {@link list} folds
   * the windows it makes into this module's own map.
   *
   * `attached: false` means Chromium produced nothing; {@link whyNoTab} is then
   * the sentence that says why.
   */
  openForSession(input: {
    url: string
    sessionId: string
    machineId?: string
  }): Promise<{ line: string; attached: boolean }>
  /** False when this host is not holding a window by that id. */
  closeWindow(browserTabId: string): Promise<boolean>
  /** The live page behind a view id, or null once the target has gone. */
  contentsFor(viewId: string): ServerPage | null
  /**
   * Move a window back or forward through its own history.
   *
   * Separate from {@link ServerPage} on purpose: this is two protocol calls —
   * read the history, then name one of its entries — and the entry's address has
   * to be screened between them. That is the tab authority's job, and a page
   * this module could ask to "go back" would be a page this module could ask to
   * navigate without the guard.
   */
  historyMove(
    viewId: string,
    move: 'back' | 'forward',
  ): Promise<{ moved: true } | { moved: false; why: string }>
  /**
   * Re-open a window's page in the other kind of cookie jar, keeping the window.
   *
   * Answers the **new view id** and never a new window id: the window id is the
   * binding key, and a re-minted one would renumber a window an agent is
   * holding. Null when the page could not be re-opened, in which case the window
   * is left exactly as it was.
   */
  repartitionWindow(browserTabId: string, isolate: boolean): Promise<{ viewId: string } | null>
  /** Why the last open produced nothing — a browser that would not start. */
  whyNoTab?(): string | null
}

/**
 * The masked capture, as this file needs it.
 *
 * `BrowserDrive.screenshot` satisfies it; the `masked` count it also answers is
 * for an agent's tool result and has nowhere to go on a window list.
 */
export interface ServerShots {
  screenshot(target?: DriveTarget | null): Promise<{ path: string; width: number; height: number }>
}

/**
 * What a server's machine browser is, on top of the wire's own contract.
 *
 * `castable` is the one addition and it is not part of `MachineBrowser`: only a
 * host that keeps its own windows needs it, and the desktop's does not — every
 * pane there is already a `knownWindows()` row.
 */
export interface ServerMachineBrowser extends MachineBrowser {
  castable(): Promise<readonly { browserTabId: string; viewId: string; url: string; title: string }[]>
}

export interface ServerMachineBrowserDeps {
  windows: ServerWindows
  shots: ServerShots
  /**
   * The sessions on this host, read per verb and never cached — the pickers the
   * phone binds a window to and sends a screenshot to.
   */
  sessions(): readonly HostSession[]
  /**
   * Type into a session. Must be the same call the wire's `input` frame makes,
   * so a screenshot handed to an agent from a phone is not a second way of
   * writing to a pty.
   */
  write(sessionId: string, data: string): void
}

/* ----------------------------------------------------------------- build -- */

/**
 * Build the machine-browser this host advertises `browser.control` for.
 *
 * The returned object is `browser-control.ts`'s, over the deps assembled here;
 * whether to build it at all is `host.ts`'s decision, because that is the file
 * that knows which kind of host this is.
 */
export function serverMachineBrowser(deps: ServerMachineBrowserDeps): ServerMachineBrowser {
  /**
   * Every window this host's browser is holding, by shell id.
   *
   * Learnt from both doors rather than only from this one. A session on the
   * server opens its own windows — the agent's `browser_open`, or `open <url>`
   * at a prompt — and those arrive in the binding store without passing through
   * here at all. {@link list} folds anything it finds there into this map, which
   * is what keeps a page listed after its session ends: `sessionRemoved` drops
   * the binding rows the moment the pty goes, and a window that vanished from
   * the phone's list with the page still open in Chromium would be a window
   * nobody could ever close.
   */
  const held = new Map<string, { viewId: string; isolated: boolean; profile: string }>()

  /** Why the last {@link open} produced nothing, when this file is the reason. */
  let refusal: string | null = null

  function pageFor(id: string): ServerPage {
    const entry = held.get(id)
    const page = entry === undefined ? null : deps.windows.contentsFor(entry.viewId)
    if (page === null) {
      held.delete(id)
      windowClosed(id)
      throw new Error('this server is no longer holding that window')
    }
    return page
  }

  /**
   * The window list, from the pages themselves.
   *
   * The binding store knows which session owns a window and what it is called;
   * only the page knows where it is and what it is loading. So the ids come from
   * the store and this map, and every fact on the row is read off the live page
   * — a title cached anywhere would be the title of whatever the window was
   * showing when something last thought to write it down.
   *
   * A window whose target has gone is dropped here rather than reported as an
   * empty row, and `windowClosed` is told so the binding row cannot outlive the
   * page. That is the same clean-up `act`'s close performs, arriving from the
   * other direction: a page the person closed inside the browser, or one that
   * died with its tab crash, is noticed the next time anybody looks.
   */
  async function list(): Promise<readonly OpenWindow[]> {
    const rows: OpenWindow[] = []
    const seen = new Set<string>()

    const add = (browserTabId: string, viewId: string | null): void => {
      if (seen.has(browserTabId)) return
      seen.add(browserTabId)
      const page = viewId === null || viewId === '' ? null : deps.windows.contentsFor(viewId)
      const known = held.get(browserTabId)
      if (page === null || viewId === null || viewId === '') {
        held.delete(browserTabId)
        windowClosed(browserTabId)
        return
      }
      /*
       * Which jar a window is in is the one fact on this row that the page
       * cannot be asked for — a target does not know whether its browser context
       * is a throwaway, and a profile is a whole other Chromium process. So it is
       * remembered at the moment the window is opened or re-partitioned, and a
       * window that arrived through the session door (an agent's `browser_open`)
       * is what that door makes: shared, in the default profile.
       */
      const entry = known ?? { viewId, isolated: false, profile: DEFAULT_PROFILE }
      entry.viewId = viewId
      held.set(browserTabId, entry)
      const row: OpenWindow = {
        id: browserTabId,
        title: page.title(),
        url: page.url(),
        viewId,
      }
      if (entry.isolated) row.isolated = true
      if (entry.profile !== DEFAULT_PROFILE) row.profile = entry.profile
      if (page.isLoading()) row.loading = true
      rows.push(row)
    }

    for (const binding of view().sessions) {
      // A session on a *paired* machine can hold a row here, and a row can name
      // a page another machine is serving. Neither is a window this host holds,
      // and `contentsFor` would refuse both — this says so before asking, so a
      // remote row is never mistaken for a dead local one and closed.
      if (binding.machineId !== '') continue
      for (const window of binding.windows) {
        if (window.hostMachineId !== '') continue
        add(window.browserTabId, window.viewId)
      }
    }
    for (const [id, entry] of [...held]) add(id, entry.viewId)
    return rows
  }

  /**
   * Open a window, and answer the id it was given.
   *
   * Bound to nothing, in the jar the person asked for. A refusal is a limit of
   * this host's browser rather than a failure, so it answers `null` with a
   * sentence of its own through {@link MachineBrowserDeps.whyNotOpen} — the seam
   * that exists precisely because *"a headless host's [null] means a Chromium
   * that could not start on that machine and has a different one for each
   * cause"*. Every sentence below either comes from the URL normalizer or from
   * the host itself; none is composed here, because the host is the thing that
   * watched its own browser fail.
   */
  async function open(input: {
    url: string
    profile: string
    isolated: boolean
  }): Promise<string | null> {
    refusal = null

    // Empty means the machine's own start page, and a server has none — so it
    // opens where a fresh view already sits. `about:blank` is the one address
    // outside http(s) that `isNavigationAllowed` permits, which is why the
    // normalizer below is not asked about it: it would refuse it.
    let url = BLANK_URL
    if (input.url !== '') {
      const normalized = normalizeUrl(input.url)
      if (!normalized.ok) {
        refusal = normalized.reason
        return null
      }
      url = normalized.url
    }

    const profile = input.profile === '' ? DEFAULT_PROFILE : input.profile
    const outcome = await deps.windows.openWindow({ url, isolate: input.isolated, profileId: profile })
    if (!outcome.ok) {
      refusal = outcome.why
      return null
    }
    held.set(outcome.browserTabId, {
      viewId: outcome.viewId,
      isolated: input.isolated,
      profile,
    })
    return outcome.browserTabId
  }

  /**
   * Move a window's page into the other kind of cookie jar, keeping the window.
   *
   * The window id is unchanged and the view id is not — `browser-control.ts`
   * hands the new one to `windowMoved`, so a binding that names this window
   * still steers the page rather than *"a URL that lands nowhere while the app
   * answers that it landed in B1"*. The local record is updated in the same
   * breath for the same reason: an unbound window has no binding row at all, and
   * this map is the only thing that knows where its page went.
   */
  async function repartition(id: string, isolated: boolean): Promise<{ viewId: string | null } | null> {
    const entry = held.get(id)
    if (entry === undefined) return null
    const moved = await deps.windows.repartitionWindow(id, isolated)
    if (moved === null) return null
    held.set(id, { viewId: moved.viewId, isolated, profile: entry.profile })
    return { viewId: moved.viewId }
  }

  /**
   * Send a window to an address.
   *
   * `navigateGuarded` rather than a bare load, and the difference is the page's
   * own `beforeunload`: this is somebody's open window, possibly with a
   * half-written form in it, and the desktop already gives an attached window
   * that courtesy on this exact path (`BrowserDrive.open`'s attached branch).
   * Nothing here reads the URL or the title to decide — the page's own
   * declaration is the only signal, because a heuristic would silently navigate
   * over work whose owner could never find out what decided that.
   */
  async function go(id: string, url: string): Promise<void> {
    const page = pageFor(id)
    const normalized = normalizeUrl(url)
    if (!normalized.ok) throw new Error(normalized.reason)
    const outcome = await page.navigateGuarded(normalized.url)
    if (outcome === 'unfinished') {
      throw new Error('that page says it has unfinished work on it, so it was not navigated')
    }
  }

  /**
   * Back, forward, reload.
   *
   * Back and forward used to be refusals here, and the reason was real:
   * `Page.navigateToHistoryEntry` names an entry id rather than an address, so
   * `isNavigationAllowed` — *"the only guard there is"* on this transport — had
   * nothing to screen, and routing around it from a phone tap was the one answer
   * that was never available. The guard was not routed around; it was given
   * something to screen. `HeadlessDriveHost.historyMove` reads the target's own
   * `Page.getNavigationHistory`, takes the neighbouring entry, and puts **its
   * URL** through the same allow-list a typed address passes before naming its
   * id. This module asks for a move and is told whether one happened.
   *
   * Reload is a navigation to where the page already is. Not a true reload — a
   * form POST is not re-submitted — and that is the honest half rather than the
   * missing one: nothing about a re-fetch of the current address is a guess.
   */
  async function history(id: string, move: 'back' | 'forward' | 'reload'): Promise<void> {
    const page = pageFor(id)
    if (move === 'reload') {
      const at = page.url()
      if (at === '') throw new Error('that window has not loaded an address yet')
      await page.loadURL(at)
      return
    }
    const entry = held.get(id)
    // Unreachable — `pageFor` above threw for a window this host is not holding
    // — and answered rather than asserted, because the alternative is a phone
    // holding a promise that never settles.
    if (entry === undefined) throw new Error('this server is no longer holding that window')
    const outcome = await deps.windows.historyMove(entry.viewId, move)
    if (!outcome.moved) throw new Error(outcome.why)
  }

  /**
   * Close a window, or say that this host is not holding one.
   *
   * The answer is checked rather than dropped. `closeWindow` reports `false` for
   * an id it has no target for, and `browser-control.ts` reads a resolved
   * promise as *"Closed X."* — so swallowing that would tell somebody their page
   * had gone while it sat there. The store is told either way, by the host on
   * the way through and by the caller afterwards; `windowClosed` on an id nobody
   * holds returns immediately.
   */
  async function close(id: string): Promise<void> {
    const closed = await deps.windows.closeWindow(id)
    held.delete(id)
    if (!closed) throw new Error('this server is no longer holding that window')
  }

  /**
   * Photograph a window, masked, and hand back both the file and the bytes.
   *
   * The target is minted here from the two ids the drive needs — `boundKey` so
   * this lands in the *same* slot an agent driving the window uses, never a
   * second one, and the shell id so `showWindow` has something to raise (a
   * success no-op on this host, and the drive asks for it anyway). The name is
   * the slot the person says out loud, or nothing: `browser:<epoch>:<uuid>` on a
   * screen was a defect once and must not come back through a refusal message.
   */
  async function capture(id: string): Promise<CapturedShot> {
    const entry = held.get(id)
    if (entry === undefined) throw new Error('this server is no longer holding that window')
    const owner = ownerOf(id)
    const window = owner?.windows.find((row) => row.browserTabId === id)
    const target: DriveTarget = {
      key: boundKey(id),
      viewId: entry.viewId,
      browserTabId: id,
      name: window === undefined ? 'That window' : slotName(window.n),
    }
    const shot = await deps.shots.screenshot(target)
    /*
     * The file, read back as the picture that crosses. See the header: there is
     * no resize on this side, so what the wire is offered is the full-resolution
     * masked PNG and `browser-control.ts` decides whether it fits. A file that
     * cannot be read back is an empty preview rather than a failed capture —
     * the shot exists, its path is about to be typed into a session, and losing
     * the thumbnail must not lose that.
     */
    const preview = await readFile(shot.path).catch(() => Buffer.alloc(0))
    return { path: shot.path, width: shot.width, height: shot.height, preview }
  }

  const wired: MachineBrowserDeps = {
    list,
    open,
    whyNotOpen: () => refusal ?? deps.windows.whyNoTab?.() ?? null,
    go,
    history,
    repartition,
    close,
    capture,
    sessions: () => deps.sessions(),
    write: (sessionId, data) => deps.write(sessionId, data),
  }
  /**
   * The windows this module opened, for the thing that casts them.
   *
   * ## Why this exists at all
   *
   * A window a phone opens through **New Window** holds no binding row — that is
   * the whole point of `openWindow`, which mints a shell id and attaches it to
   * nothing. `castWindows` in `host.ts` builds its strip from the front tab plus
   * the binding store, so those windows were *drivable and not watchable*: they
   * appeared in `browser.window.rows`, could be navigated and closed and bound,
   * and tapping one to look at it found no surface. Half a feature, and the half
   * missing was the one Asad asked for in the same breath — *"it should browser
   * and stream here to interact."*
   *
   * Answering it from `held` rather than from a second map is what keeps the two
   * lists honest: `list()` is the only thing that writes there, and it drops a
   * window whose page has gone in the same pass. So a row that is castable is a
   * row that exists, by construction rather than by two maps agreeing.
   *
   * `list()` is called first because `held` is a cache of what the last listing
   * found — reading it cold, before any listing, would answer an empty strip on
   * a machine that has windows open.
   */
  const castable = async (): Promise<
    readonly { browserTabId: string; viewId: string; url: string; title: string }[]
  > => {
    const rows = await list()
    return rows.map((row) => ({
      browserTabId: row.id,
      viewId: row.viewId ?? '',
      url: row.url ?? '',
      title: row.title ?? '',
    }))
  }

  return Object.assign(machineBrowser(wired), { castable })
}
