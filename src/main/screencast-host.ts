import { MAX_SURFACES_REPORTED } from './remote/protocol'
import type { BrowserFrameFrame, BrowserInputFrame } from './remote/protocol'
import type { HandoverState, ScreencastHost, ScreencastSurface } from './remote/server'
import type { DriveTarget } from './browser-driver'

/**
 * The live view of this machine's own browser, as a shell hands it to the wire.
 *
 * ## The wire had every frame and neither shell had the engine
 *
 * `browser.watch`, `browser.frame`, `browser.frame.ack`, `browser.input`,
 * `browser.unwatch` and `browser.surfaces` have been on the protocol since
 * wave-3. `PageCast` has held the screencast, the backpressure and the secret
 * mask since the same day. The phone has drawn a viewer for it since it grew
 * `WatchView.swift`, and the PWA a canvas per window since `browser-view.ts`.
 * What none of it had was one object: `RemoteEndpointOptions.screencast` is the
 * switch — `capabilitiesFor` advertises `watch` **exactly when it is present** —
 * and neither `src/headless/host.ts` nor `src/main/index.ts` passed one, so
 * `watch` was never advertised, the phone's *Windows on …* section was empty on
 * every host that ships, and tapping a row showed nothing.
 *
 * Asad, typing an address into the Browser tab against a server and watching it
 * refuse:
 *
 * > *"it should browser and stream here to interact."*
 *
 * This file is the missing object. It decides nothing about permission and
 * touches no socket: `server.ts` re-reads the grant before every frame it
 * writes and before it calls {@link ScreencastHost.input}, and every frame here
 * leaves through the `emit` that server rebuilt for this watch. What this owns
 * is the routing — which slot of {@link CastDrive} a window name means, which
 * watchers are on it, and what the tab strip says.
 *
 * ## Why a name is resolved once, at watch time, and remembered
 *
 * {@link ScreencastHost.ack} is synchronous — it has to be, because it is the
 * whole of the backpressure and a frame must be released on the tick the ack
 * arrives — while the window list a shell can produce is a promise on at least
 * one host. So a cast remembers the {@link DriveTarget} it was started against,
 * and every later `ack`, `input` and `unwatch` for that watcher goes to *that*
 * slot rather than to whatever the name resolves to now. That is not merely
 * convenient: an ack names a frame, the frame came out of one page, and a name
 * that had meanwhile come to mean a different page would release a frame on a
 * page nobody is looking at.
 *
 * ## Why a surface is named by its shell tab id and not by `B2`
 *
 * `RemoteEndpointOptions.screencast` describes the non-empty name as *"a slot
 * name like `B2`"*, and that is what this was written to do first. It cannot be
 * that, and the reason is in `browser-binding.ts`: `B2` is *"a slot **inside one
 * session**"*, allocated per session and per session only, so two sessions each
 * holding two windows both have a `B1` and a `B2`. The watchable set here is
 * per-**machine**, both clients key their viewers on this string —
 * `pwa/src/main.ts` keys `browserCanvases` by it, and `BrowserSurfaceRow` in
 * `ios/.../BrowserWatchWire.swift` makes it the row's `Identifiable` id — so two
 * rows answering to `B1` are two viewers fighting over one canvas and a
 * `browser.input` that lands on whichever page was resolved last.
 *
 * The alternative that was rejected is renaming on collision: `SessionBinding`
 * argues at length that a renumbered window *"makes an agent point confidently
 * at the wrong page"*, and a name that flips the moment a second session
 * attaches would do that to a live watcher mid-cast.
 *
 * So a surface is named by the shell tab id, which is the identity this same
 * protocol family already uses for a window on this machine —
 * `MachineWindow.id`, the id `browser.window.go`, `.act`, `.bind` and `.shot`
 * all address — and the id `boundKey` files a drive slot under. One window is
 * then one string across both browser families and the two lists can be joined
 * without a second mapping. The `browser-binding.ts` rule that an id must never
 * be *printed* is untouched and was checked rather than assumed: neither client
 * draws this field, `surfaceRow` in the PWA labels a row with `title || url ||
 * 'Untitled page'` and `windowRow` in `LocalhostListView.swift` with the title
 * and the URL.
 *
 * The empty string keeps its documented meaning — the drive's own tab, the
 * `OWN_TARGET` convention — because that slot has no shell tab id to wear on a
 * host where `openTab` mints none.
 *
 * What that costs, and the one file that closes it, is written down at
 * {@link frontTab}. It is worth reading before anybody tries to give this row a
 * real id: the empty string is the *symptom* and not the cause, and changing it
 * here alone makes the phone worse rather than better.
 */

/**
 * The screencast half of `BrowserDrive`, and nothing else it can do.
 *
 * A structural interface rather than the class, for the reason `CdpTransport` is
 * one in `browser-driven-cdp.ts` and `ServerWindows` is one in
 * `src/headless/machine-browser.ts`: the whole of this module is exercised
 * against a real `BrowserDrive` over a fake page in its own test, and a caller
 * reading this signature can see that a live view cannot navigate, read, type or
 * photograph anything — the five methods below are the only reach it has.
 */
export interface CastDrive {
  startCast(input: {
    target?: DriveTarget | null
    watcherId: string
    window: string
    options: { maxWidth: number; quality: number; everyNth?: number }
    emit: (frame: Omit<BrowserFrameFrame, 't'>) => void
  }): Promise<{ ok: boolean; reason?: string }>
  stopCast(target: DriveTarget | null | undefined, watcherId: string): Promise<void>
  ackCast(target: DriveTarget | null | undefined, watcherId: string, seq: number): void
  castInput(
    target: DriveTarget | null | undefined,
    watcherId: string,
    frame: BrowserInputFrame,
  ): Promise<{ ok: boolean; reason?: string }>
  /**
   * Who holds the handover on this slot, and what the agent asked for.
   *
   * Read rather than subscribed, and cheap enough to read per push: it is three
   * fields off a slot the driver already holds. See `BrowserDrive.handoverHolding`.
   */
  handoverHolding(target?: DriveTarget | null): {
    asking: boolean
    prompt: string
    taker: string | null
  }
  takeHandover(
    target: DriveTarget | null | undefined,
    watcherId: string,
  ): Promise<{ ok: boolean; reason?: string }>
  handBackHandover(
    target: DriveTarget | null | undefined,
    watcherId: string,
    carryOn: boolean,
  ): Promise<{ ok: boolean; reason?: string }>
  dropWatcher(watcherId: string): Promise<void>
}

/** One page this machine's browser is holding, as a shell already lists it. */
export interface CastWindow {
  /**
   * The name this surface answers to on the wire.
   *
   * The shell tab id for a window, and the empty string for the drive's own tab.
   * See the header for why an id and not `B2`.
   */
  window: string
  /**
   * The slot to cast, or **null for the drive's own tab**.
   *
   * The shell mints this rather than this module deriving it, because the two
   * hosts learn their windows from different authorities — `knownWindows()`
   * under Electron, the binding store on a daemon — and a slot key guessed here
   * from a list this module did not build is a second spelling of `boundKey`.
   */
  target: DriveTarget | null
  url: string
  title: string
}

export interface ScreencastDeps {
  drive: CastDrive
  /**
   * Every page this machine's browser is holding, read afresh on every call.
   *
   * Never cached here. The one screen this feeds is a list of what is open right
   * now, and a cached copy is how a phone comes to offer a window that closed
   * ten minutes ago — the failure `machine-browser.ts` describes as *"a window
   * that vanished from the phone's list with the page still open"*, arriving from
   * the other direction.
   *
   * A throw is a working state and is answered as an empty strip: a host whose
   * browser could not start has no windows, and that is a true sentence rather
   * than a reason to fail the frame the phone asked for.
   */
  windows(): readonly CastWindow[] | Promise<readonly CastWindow[]>
}

/** One window being cast, and who is watching it. */
interface Cast {
  /** The slot the frames are coming out of. Null is the drive's own tab. */
  target: DriveTarget | null
  watchers: Set<string>
}

export function screencastOver(deps: ScreencastDeps): ScreencastHost {
  /** By window name. Only names a cast was actually started for. */
  const casts = new Map<string, Cast>()

  async function listWindows(): Promise<readonly CastWindow[]> {
    try {
      return await deps.windows()
    } catch (error) {
      console.error('[screencast] this machine could not list its browser windows:', error)
      return []
    }
  }

  function forget(window: string, watcherId: string): void {
    const cast = casts.get(window)
    if (!cast) return
    cast.watchers.delete(watcherId)
    if (cast.watchers.size === 0) casts.delete(window)
  }

  return {
    async watch(input) {
      const found = (await listWindows()).find((window) => window.window === input.window)
      if (!found) {
        // The window closed between the strip being drawn and the row being
        // tapped, which on a phone is an ordinary few seconds. A sentence rather
        // than a throw: `server.ts` drops the watch and the viewer stays empty,
        // and the next `browser.surfaces` shows a list without it.
        return { ok: false, reason: 'that window is not open on this machine any more' }
      }
      const result = await deps.drive.startCast({
        target: found.target,
        watcherId: input.watcherId,
        window: input.window,
        options: {
          maxWidth: input.maxWidth,
          quality: input.quality,
          ...(input.everyNth === undefined ? {} : { everyNth: input.everyNth }),
        },
        // The `t` the driver's frame does not carry, and the only thing added to
        // it. Everything else — the seq, the geometry, the mask — is the cast's
        // own and is passed through untouched, because a frame rewritten on the
        // way out is a frame whose geometry no longer matches the one the
        // viewer will measure its next tap against.
        emit: (frame) => input.emit({ t: 'browser.frame', ...frame }),
      })
      if (!result.ok) return result
      const cast = casts.get(input.window)
      if (cast) {
        // A renegotiation — a viewer that rotated or resized. `PageCast.watch`
        // is idempotent per watcher id and the newest options win; the target
        // stays the one the frames are already coming from.
        cast.watchers.add(input.watcherId)
      } else {
        casts.set(input.window, { target: found.target, watchers: new Set([input.watcherId]) })
      }
      return { ok: true }
    },

    async unwatch(input) {
      const cast = casts.get(input.window)
      // Nothing this module started, so nothing it can stop. Dropped in silence
      // for the reason `server.ts` drops a stale ack: an unwatch that crossed a
      // dropped socket on the wire is a race, not a fault.
      if (!cast) return
      forget(input.window, input.watcherId)
      await deps.drive.stopCast(cast.target, input.watcherId)
    },

    ack(input) {
      const cast = casts.get(input.window)
      if (!cast || !cast.watchers.has(input.watcherId)) return
      deps.drive.ackCast(cast.target, input.watcherId, input.seq)
    },

    async input(input) {
      const cast = casts.get(input.window)
      /*
       * Driving is only ever the other half of watching, and this is where that
       * is true rather than merely intended.
       *
       * `server.ts` already refuses an input naming a window the connection is
       * not watching, and this refuses one naming a window *this side* is not
       * casting. The two are not the same check: the server's set is what a
       * device asked for, this one is what the machine actually started, and the
       * gap between them is a watch that was refused — a page that had gone, or
       * one the person had taken. An input in that gap must not reach the page.
       */
      if (!cast || !cast.watchers.has(input.watcherId)) {
        return { ok: false, reason: 'that window is not being watched on this connection' }
      }
      return deps.drive.castInput(cast.target, input.watcherId, input.frame)
    },

    handover(window): HandoverState {
      const cast = casts.get(window)
      /*
       * A window nobody on this machine is casting has no handover to report.
       *
       * Not the same as *"no handover is outstanding"* in principle — the drive
       * could be holding a question about a page no phone is watching — but it is
       * the same answer, because the only thing that can be done with this frame
       * is take a handover, and taking one requires being a watcher. Answering
       * `asking: true` about a page this side is not casting would put a button on
       * a screen that the tap would then be refused from.
       */
      if (!cast) return { asking: false, prompt: '', taker: null }
      return deps.drive.handoverHolding(cast.target)
    },

    async take(input) {
      const cast = casts.get(input.window)
      /*
       * The same two-set rule `input` above states, and for the same reason: the
       * server's `watching` set is what a device *asked* for, this one is what
       * the machine actually started, and the gap between them is a watch that
       * was refused. Taking a page in that gap would be taking a page whose
       * pixels are going nowhere.
       */
      if (!cast || !cast.watchers.has(input.watcherId)) {
        return { ok: false, reason: 'that window is not being watched on this connection' }
      }
      return deps.drive.takeHandover(cast.target, input.watcherId)
    },

    async handBack(input) {
      const cast = casts.get(input.window)
      if (!cast || !cast.watchers.has(input.watcherId)) {
        return { ok: false, reason: 'that window is not being watched on this connection' }
      }
      return deps.drive.handBackHandover(cast.target, input.watcherId, input.carryOn)
    },

    async surfaces() {
      const windows = await listWindows()
      return windows.slice(0, MAX_SURFACES_REPORTED).map(
        (window): ScreencastSurface => ({
          window: window.window,
          url: window.url,
          title: window.title,
          live: (casts.get(window.window)?.watchers.size ?? 0) > 0,
        }),
      )
    },

    async dropWatcher(watcherId) {
      /*
       * A socket that closed, and the one call that has to reach the machine.
       *
       * `BrowserDrive.dropWatcher` walks every cast it holds, so a phone that
       * went into a tunnel with three windows open leaves nothing behind — and a
       * page no other connection is watching has its `Page.startScreencast`
       * stopped rather than left armed on somebody's computer for the life of
       * the process.
       *
       * The bookkeeping here is cleared **after** the drive has let go, in the
       * same call, so `surfaces` can never report `live: true` about a cast that
       * has already stopped.
       */
      await deps.drive.dropWatcher(watcherId)
      for (const [window, cast] of [...casts]) {
        cast.watchers.delete(watcherId)
        if (cast.watchers.size === 0) casts.delete(window)
      }
    },
  }
}

/* ------------------------------------------------------------- front tab -- */

/**
 * The drive's own tab, as a row on the strip.
 *
 * Only a host whose `openTab` mints no shell id needs this — the headless
 * daemon, where a page opened from the phone's address bar lands in the drive's
 * own slot and is therefore in no window list at all. On the desktop `openTab`
 * asks the renderer for a pane, so the copilot's tab is an ordinary row of
 * `knownWindows()` and this is not used.
 *
 * ## Why the label is remembered and the liveness is read
 *
 * `BrowserDrive` publishes exactly one `DriveStatus`, for the slot the banner is
 * about — `showing()` prefers a page the person has been handed, then the
 * newest one an agent touched — so on a host that also runs sessions of its own
 * it is not necessarily the front tab, and labelling this row from it would
 * print the address of a window a session is driving under the name of the one
 * the phone opened. The one read that is addressed at the front tab and nothing
 * else is `origin(OWN_TARGET)`, and an origin is not a title.
 *
 * So the two facts come from the two places that know them. Whether there is a
 * page is read live, every time, off the slot. What to call it is what
 * `BrowserDrive.open` answered when the page was opened — and it is used only
 * while the live origin still matches it, so a tab that has since followed a
 * link to another site degrades to naming that site rather than going on
 * claiming the title of a page it left.
 */
export interface FrontTab {
  /**
   * The front tab was opened at a page.
   *
   * Kept for the one thing a live read cannot answer: a slot that has been
   * *asked* for a page and has not finished loading it yet. Nothing depends on
   * it any more for the address — see {@link frontTab}.
   */
  opened(page: { url: string; title: string }): void
  /** Its row, or null when the front tab holds no page. */
  row(): CastWindow | null
}

/**
 * The drive's own front tab as a row, read **live**.
 *
 * `where` is `BrowserDrive.where(OWN_TARGET)` — the page's URL and title off the
 * `WebContents`, every time.
 *
 * It used to be `origin(OWN_TARGET)` plus what `open` answered when the page was
 * opened, kept while the origin still matched. That is a browser lying about
 * where it is: following a link *inside* a site left the address showing the
 * page you started at, and following one to another site degraded to a bare
 * origin with no path. Asad found it from the other end — *"I cannot touch the
 * URL"* — and an address bar that can be edited but shows the wrong address is
 * worse than one that cannot.
 *
 * A live read makes the remembered pair unnecessary rather than merely stale,
 * which is why it is gone from the row entirely.
 *
 * ## Why this row has no menu on the phone, and where the fix actually lives
 *
 * Asad, filming the Browser tab of a **server** with two rows on it —
 * `google.com`, which is this row, and `iMatch`, which is an ordinary window:
 *
 * > *"this one is attached to this session. Maybe this is the difference, and
 * > this one is not attached to anyone. But there is no way to attach this one
 * > too. So it should be the same case, or all the options should be available
 * > at least."*
 *
 * He is right, and the empty `window` below is the symptom rather than the
 * cause. Everything a person can do to a browser window from a phone —
 * attach, detach, close, archive, back, forward, screenshot, isolate — is a
 * `browser.window.*` frame, and every one of those verbs is resolved by
 * `machineBrowser`'s `find(id)` against `MachineBrowserDeps.list()`. On a server
 * that list is `src/headless/machine-browser.ts`, and it is built from exactly
 * two authorities: the `browser-binding.ts` store, and the `held` map that
 * module writes when **it** opens a window. The drive's own slot is in neither,
 * so the front tab is not merely un-addressable — *it is not in the window list
 * at all*, and there is no id that would put it there.
 *
 * So minting a shell id for this row closes nothing. It would clear the five
 * `rawId === ''` refusals in `remote/protocol.ts`, the frames would parse, and
 * `find` would then miss anyway and answer *"That window is not open any more"*
 * — a control that looks like it works and does not, which is worse than the
 * disabled row with a reason on it that the phone draws today. It also takes
 * something away: `WatchViewerScreen.canNavigate` is `surface.window.isEmpty`,
 * because `web.open` navigates *this exact slot*, so a real id here silently
 * removes the address bar from the one screen that has one.
 *
 * ## The desktop does not have this bug, and that is the shape of the answer
 *
 * There, `web.open` is `openAppLink(mainWindow)` — an ordinary pane with an
 * ordinary shell tab id, in `knownWindows()`, therefore in `browser.window.rows`
 * and bindable like any other. `machineScreencastHere` in `src/main/index.ts`
 * still routes its cast through `OWN_TARGET`, but it does that by matching the
 * **view id** against `BrowserDrive.ownView()` while the row keeps its real
 * `window: tabId`. That is the whole trick: *the name a surface wears and the
 * slot its frames come from are two different facts*, and only the second one
 * has to be the drive's own.
 *
 * A server can have the same property, and it is not this file's line to write:
 * `openUrl` in `src/headless/host.ts` calls `browserDrive.open({ url,
 * isolate: false })`, which is the agent's private tab. Routed through
 * `machineBrowser.open` instead — the same door **New Window** already uses —
 * the page arrives as a real window: `HeadlessDriveHost.openWindow` mints
 * `browser:<epoch>:<uuid>`, registers it in `byBrowserTab` so it can be closed
 * and re-partitioned, files it in `held` so `list()` and `castable()` both carry
 * it, and `castWindows` folds `castable()` into this strip. Listed, bindable,
 * closable **and** watchable, which is all of what he asked for, with nothing
 * new invented anywhere.
 *
 * What is left for this function afterwards is the honest remainder: the tab an
 * **agent** opened with `browser.open` and no target. That one genuinely is not
 * a window on a server — `HeadlessDriveHost.openTab` passes `browserTabId: ''`
 * on purpose — and a row that says so is the truth rather than a gap.
 */
export function frontTab(where: () => { url: string; title: string } | null): FrontTab {
  return {
    opened() {
      // Nothing to remember: the row reads the page itself. Kept as a method so
      // callers that announce an open do not have to know that.
    },
    row() {
      const live = where()
      if (live === null) return null
      const site = originOf(live.url)
      return {
        // Not a name this side chose to withhold: on a server the drive's own
        // slot has no shell tab id to wear, and no id would put it in the
        // window list the `browser.window.*` verbs resolve against. See the
        // header above before changing this — the fix is a routing line in
        // `src/headless/host.ts`, not a string here.
        window: '',
        target: null,
        // A page with no site to name — `about:blank`, a `data:` document, which
        // is what a freshly-made front tab is. The row still belongs on the
        // strip (there is a page, and it can be watched), so it goes out with an
        // empty address and both clients label it untitled rather than printing
        // the word `null` at somebody.
        url: site === OPAQUE_ORIGIN || site === null ? '' : live.url,
        title: live.title,
      }
    },
  }
}

/**
 * What `URL.origin` answers for a page that has no site — `about:blank`, a
 * `data:` document. A string, not the null this file's own absences use, which
 * is exactly the confusion the constant exists to stop.
 */
const OPAQUE_ORIGIN = 'null'

/** An origin, or null for anything `URL` cannot parse at all. */
function originOf(url: string): string | null {
  try {
    return new URL(url).origin
  } catch {
    return null
  }
}
