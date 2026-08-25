import { MAX_SURFACES_REPORTED } from './remote/protocol'
import type { BrowserFrameFrame, BrowserInputFrame } from './remote/protocol'
import type { ScreencastHost, ScreencastSurface } from './remote/server'
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
  /** The front tab was opened at a page. `BrowserDrive.open` answers this. */
  opened(page: { url: string; title: string }): void
  /** Its row, or null when the front tab holds no page. */
  row(): CastWindow | null
}

export function frontTab(origin: () => string | null): FrontTab {
  let last: { origin: string; url: string; title: string } | null = null
  return {
    opened(page) {
      const at = originOf(page.url)
      last = at === null ? null : { origin: at, url: page.url, title: page.title }
    },
    row() {
      const live = origin()
      if (live === null) return null
      const label = last !== null && last.origin === live ? last : null
      return {
        window: '',
        target: null,
        // An opaque origin is a page with no site to name — a blank tab, which
        // is what a freshly-made front tab is. The row still belongs on the
        // strip (there is a page, and it can be watched), so it goes out with
        // an empty address and both clients label it as untitled rather than
        // printing the word `null` at somebody.
        url: label?.url ?? (live === OPAQUE_ORIGIN ? '' : live),
        title: label?.title ?? '',
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
