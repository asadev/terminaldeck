/**
 * The tab authority for a server: a real Chromium of this machine's own, driven
 * over CDP, standing in for everything the desktop's renderer does when the
 * copilot asks for a browser.
 *
 * ## What this replaces, and why it can
 *
 * On the desktop a driven page is a `WebContentsView` the renderer built, sitting
 * in the tab strip where a person can see and close it — so `DriveHost.openTab`
 * (`browser-drive-ipc.ts`) *asks the window* for one and gets a shell tab id
 * back, and `browser-tab.ts`/`browser-popup.ts` make the object. There is no
 * window here and no renderer to ask. So this module is the tab authority
 * itself: it launches Chromium once (per profile), opens targets in it, and
 * hands the driver a {@link DrivenPage} spoken to over the pipe. The long
 * comment in `src/headless/host.ts` where the copilot is declined names exactly
 * this — "a `WebContentsView` created in the main process would be a page that
 * exists, is doing things, and cannot be found" is the desktop's reason for
 * going through the renderer, and it does not hold on a server whose browser has
 * no strip to be missing from and whose windows are numbered by the same
 * {@link browser-binding} store the desktop uses.
 *
 * ## Why background targets are not a problem here
 *
 * `DriveHost.showWindow` is a success no-op on this host, and that is the pivot
 * that makes Route B beat Electron-under-Xvfb. The desktop needs `showWindow`
 * because a background `WebContentsView` has a 0×0 viewport and drops input
 * (measured, see `browser-driver.ts`'s `showWindow` header). Under real headless
 * Chromium every target composites independently and CDP `Input.*` reaches any
 * target regardless of front/back, so the whole background-input-dropped defect
 * vanishes and a fleet of targets can be driven at once.
 *
 * ## Two doors that open a window, and one jar per profile
 *
 * {@link HeadlessDriveHost.openWindow} mints a shell id and attaches it to
 * nothing; {@link HeadlessDriveHost.openForSession} mints one and binds it to a
 * session. For a while only the second existed, so the phone's New Window went
 * through it with a session id of `''` and undid the attach immediately — a
 * sentinel `machine-browser.ts` wrote down as a hack rather than leaving it to
 * become the design. Both take a profile and an isolation flag now, and neither
 * is a new mechanism: an isolated window is the throwaway
 * `Target.createBrowserContext` this host has always made, and a *profile* is a
 * whole second Chromium process against `<userData>/Partitions/<profileId>`,
 * which is what `browsers` has been a map for since it was written. One process
 * per persistent jar is not an implementation detail — it is the only
 * arrangement in which a jar survives a restart, since a browser context does
 * not and `--profile-directory` cannot be chosen per target over CDP.
 *
 * ## Electron-free, and checked
 *
 * Nothing here imports Electron, and `src/headless/seam.test.ts` walks the graph
 * from the headless entries through `host.ts` into this file and would fail on a
 * single runtime `electron` import. The launch and the pipe are behind seams
 * (`launch`) so a test drives a fake Chromium and a fake `CdpPipe` — this module
 * never downloads a browser or spawns a debugger in a test, per the wave-2 house
 * rules.
 */

import { randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { userDataDir } from './platform/paths'
import { logger } from './app-log'
import { screenHistoryEntry } from './browser-cdp'
import { isNavigationAllowed } from './browser-url'
import {
  DEFAULT_PROFILE_ID,
  headlessProfileDir,
  isProfileId,
  ownProfileStorage,
  profilesFile,
  readStoredProfiles,
} from './browser-profile-storage'
import type { CdpEvent } from './browser-cdp-pipe'
import { cdpDrivenPage, type CdpTransport } from './browser-driven-cdp'
import { launchChromium } from './browser-chromium-launch'
import { installChromium } from './browser-chromium-install'
import {
  CDP_GUEST_WORLD,
  cdpGuestDispatchExpression,
  installCdpGuestPreload,
  parseGuestBinding,
  type GuestMessage,
} from './browser-preload-cdp'
import { installCdpDownloads, type CdpDownloadChannel, type CdpDownloadHandle } from './browser-downloads-cdp'
import { cdpAssetFetchFor, type AssetOpen, type CdpAssetChannel } from './browser-asset-session-cdp'
import {
  attach,
  slotName,
  windowClosed,
  type BoundWindow,
} from './browser-binding'
import { captureDir } from './browser-capture-store'
import { blockShotDirFor } from './browser-scrape-paths'
import {
  captureBoundsOf,
  fetchRulesOf,
  scrapeSettingsFor,
} from './browser-scrape-settings'
import type { DriveHost, DrivenPage } from './browser-driver'
import type { DriveStatus } from './browser-drive'

/**
 * The channel the desktop's `DriveStatus` rides, restated here as a literal.
 *
 * It is `browser-drive-ipc.ts`'s `DRIVE_STATE_CHANNEL`, and it is copied rather
 * than imported for the reason this whole file exists: that module reaches
 * Electron at its first line, so importing one string from it would drag the
 * renderer bridge into the headless bundle. Both ends agree on the string; the
 * seam test is what keeps them from having to agree on the module.
 */
export const HEADLESS_DRIVE_STATE_CHANNEL = 'browser:drive-state'

/*
 * The default profile's id used to be inlined here, with a paragraph explaining
 * that `browser-profiles.ts` reaches Electron at its first line and so could not
 * be imported. That reason still holds and the copy is gone: the literal — and
 * the partition string, and the directory both host shapes put a profile in —
 * now live in `browser-profile-storage.ts`, which has no Electron in it and is
 * imported above. There was a second copy of the *directory*, in `server.ts`,
 * and it was wrong; see that module's header for what it cost.
 */

/* ------------------------------------------------------------- the launch -- */

/** A launched browser, reduced to the things this host holds it by. */
export interface HeadlessBrowserHandle {
  /** The CDP channel, framed. `CdpPipe` is the production one. */
  transport: CdpTransport
  /** Stop the browser process. The pipe closing does not do this — the launcher owns the child. */
  stop(): void
  /**
   * The process has ended. `ChromiumHandle.whenGone`, passed straight through.
   *
   * Here because {@link HeadlessDriveHost.releaseProfile} has to know that a
   * browser is *gone* rather than that it was asked to go: emptying a profile
   * directory out from under a live Chromium is not a clear — on Windows the
   * unlink fails and on POSIX the running browser can write its in-memory jar
   * straight back — and a phone that was told the profile was empty in either
   * case is the defect `browser-profile-storage.ts` exists to end.
   *
   * Optional because the launch is a seam and a scripted one has no process to
   * report the death of. Absent means the stop is taken at its word and the
   * directory check afterwards is the only proof; `defaultLaunch` always
   * provides it, so nothing in production rests on that.
   */
  whenGone?: Promise<string>
}

/** Resolve, launch and wrap a Chromium for one profile, or say why it could not. */
export type LaunchBrowser = (input: {
  userDataDir: string
  extensionDirs: readonly string[]
}) => Promise<{ ok: true; handle: HeadlessBrowserHandle } | { ok: false; why: string }>

/**
 * The production launch: the installed pinned Chromium, over `--remote-debugging-pipe`.
 *
 * `installChromium` is idempotent and honours `TERMINALDECK_CHROMIUM_PATH` for an
 * air-gapped side-load; a missing binary comes back as a named error rather than
 * a crash, exactly the discipline `platform/paths.ts` keeps. The default is
 * fetch-on-first-run — the `terminaldeck browser install` step primes it, and a
 * server that never ran it pays the download here on first drive.
 */
const defaultLaunch: LaunchBrowser = async ({ userDataDir: dir, extensionDirs }) => {
  const install = await installChromium()
  if (!install.ok) return { ok: false, why: install.why }

  /*
   * `launchChromium` is the confirmed launch: it does not return until the
   * browser has answered `Browser.getVersion` on the pipe, the process has died,
   * or a bounded timeout has fired. That used to be this function's job, done
   * here after a synchronous launch that reported a pid and called it success —
   * and a Chromium about to die on its first instruction has a pid. It moved one
   * layer down so that *no* caller can hold an unconfirmed browser, not just
   * this one.
   */
  const launched = await launchChromium({
    executablePath: install.path,
    userDataDir: dir,
    extensionDirs,
  })
  if (!launched.ok) return { ok: false, why: launched.why }
  if (!launched.sandbox.sandbox) {
    // Stated, every time, wherever it happens. A dropped security boundary that
    // is never mentioned is the thing `sandboxDecision` exists to prevent.
    logger.warn('browser', `Chromium is running without its sandbox: ${launched.sandbox.why}`)
  }

  return {
    ok: true,
    handle: {
      transport: launched.transport,
      stop: () => launched.handle.close(),
      whenGone: launched.handle.whenGone,
    },
  }
}

/**
 * Re-exported from `browser-chromium-launch.ts`, where it now lives.
 *
 * It moved because it is part of what a launch *is*, not something a caller
 * remembers to do afterwards — a browser nobody confirmed is the defect this
 * whole path was built around. Kept named here because the readiness race is
 * this host's contract with its browser and is asserted as such in
 * `browser-headless-host.test.ts`.
 */
export { confirmReady } from './browser-chromium-launch'

/* -------------------------------------------------------------- the deps -- */

export interface HeadlessDriveHostDeps {
  /** Where profiles, captures and downloads live. Defaults to `userDataDir()`. */
  userData?: string
  /** Epoch ms. Injected so a test can freeze it. */
  now?: () => number
  /**
   * Push the drive's banner state at the attached devices.
   *
   * Absent on a build with no fanout — a no-op — which is honest: a server with
   * nobody connected has no banner to draw. The desktop hands its renderer's
   * `send`; `src/headless/host.ts` hands the relay's per-device push.
   */
  publish?: (status: DriveStatus) => void
  /** Resolve + launch Chromium. Injected for tests; defaults to {@link defaultLaunch}. */
  launch?: LaunchBrowser
  /**
   * Unpacked extension directories to load into a profile's browser, by profile id.
   *
   * Real Chromium loads these with `--load-extension`; the shim
   * (`browser-extension-compat.ts`) is still injected so the catalogue's
   * verdicts match. Empty for a profile with none.
   */
  extensionDirsFor?: (profileId: string) => readonly string[]
  /**
   * A guest page reported something — an element clicked while inspecting, a
   * login form found. Routed here from `Runtime.bindingCalled`; the consumer is
   * the inspection surface, which on a server is a connected device.
   *
   * Absent means the messages are dropped, which is what a server with no
   * inspection surface should do rather than hold them.
   */
  onGuestMessage?: (input: { targetId: string; message: GuestMessage }) => void
}

/* -------------------------------------------------------- internal state -- */

/** One launched browser process and everything opened inside it. */
interface BrowserInstance {
  handle: HeadlessBrowserHandle
  downloads: CdpDownloadHandle | null
}

/** The host's own session onto a target's guest world, for the inspection bridge. */
interface GuestBridge {
  sessionId: string
  /** The guest world's execution context, once Chromium has reported it. */
  contextId?: number
  send(method: string, params: Record<string, unknown>): Promise<Record<string, unknown>>
}

/** One open target, and the facts the `DriveHost` answers about it. */
interface Target {
  targetId: string
  profileId: string
  /** The in-memory context an isolated target lives in, disposed with it. `''` for the default context. */
  browserContextId: string
  page: DrivenPage
  /** The renderer-equivalent shell id, for a window attached to a session. `''` for the copilot's own tab. */
  browserTabId: string
  isolated: boolean
}

function asRecord(value: unknown): Record<string, unknown> {
  return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : {}
}

/* --------------------------------------------------------------- the host -- */

/**
 * The server's `DriveHost`. One per host process; `src/headless/host.ts` builds
 * it and hands it to `new BrowserDrive(...)`.
 */
export class HeadlessDriveHost implements DriveHost {
  /**
   * The allow-list axis. Every command the driver screens for a page of this
   * host is checked against `CDP_ALLOWED` rather than the Electron tables — see
   * `DriveHost.transport` and `screenCommand`.
   */
  readonly transport = 'cdp' as const

  private readonly userData: string
  private readonly nowFn: () => number
  private readonly publishFn: (status: DriveStatus) => void
  private readonly launch: LaunchBrowser
  private readonly extensionDirsFor: (profileId: string) => readonly string[]
  private readonly onGuestMessage: ((input: { targetId: string; message: GuestMessage }) => void) | null

  /** One browser per profile, launched on first use. */
  private readonly browsers = new Map<string, Promise<BrowserInstance>>()
  /** The reason the last launch or tab failed, for {@link whyNoTab}. */
  private lastFailure: string | null = null

  /** Settled instances, filled as each launch resolves, for the synchronous {@link browserFor}. */
  private readonly settledBrowsers = new Map<string, BrowserInstance>()
  /** The guest bridge for each armed target, by target id. */
  private readonly guests = new Map<string, GuestBridge>()
  /** Every open target, by its id (which is also the driver's view id). */
  private readonly targets = new Map<string, Target>()
  /** Shell tab id → target id, for the two verbs that take a `browserTabId`. */
  private readonly byBrowserTab = new Map<string, string>()

  /** Stop answering for this process's profile directories. Called by {@link stop}. */
  private readonly disownStorage: () => void

  constructor(deps: HeadlessDriveHostDeps = {}) {
    this.userData = deps.userData ?? userDataDir()
    this.nowFn = deps.now ?? Date.now
    this.publishFn = deps.publish ?? (() => {})
    this.launch = deps.launch ?? defaultLaunch
    this.extensionDirsFor = deps.extensionDirsFor ?? (() => [])
    this.onGuestMessage = deps.onGuestMessage ?? null
    /*
     * Say, process-wide, that this host is what holds a profile's files open.
     *
     * `browserProfilesFor` in `remote/server.ts` serves the phone's Clear, and
     * it is four hundred lines away from any browser: on a server it used to
     * rebuild the directory from the partition string and delete a path that has
     * never existed, answer with a fresh profile list, and leave every cookie in
     * place. It now asks the module that owns the directory, and on this host
     * that module's answer comes from here — the same object that chose the
     * `--user-data-dir` and is holding the Chromium that has those files open.
     * Registered in the constructor rather than at the first launch because a
     * profile that has never been launched still has a directory, and "there is
     * nothing there" is an answer this host is entitled to give.
     */
    this.disownStorage = ownProfileStorage({
      directoryFor: (profileId) =>
        isProfileId(profileId) ? headlessProfileDir(this.userData, profileId) : null,
      release: (profileId) => this.releaseProfile(profileId),
    })
  }

  /* ----------------------------------------------------------- the browser -- */

  /**
   * The profile directory for one profile id.
   *
   * `<userData>/Partitions/<profileId>` so each profile's jar, localStorage and
   * cache persist on disk exactly as `browser-profiles.ts` describes — one
   * long-lived `--user-data-dir` process per persistent profile. The default
   * profile keeps its own directory under the same root; its partition name is
   * unchanged, which matters to the desktop and not here.
   *
   * The path itself is `browser-profile-storage.ts`'s, not this file's. It was
   * this file's, and a second statement of it in `server.ts` — reached by a
   * phone pressing Clear — named a directory that has never existed on any
   * machine. One place says where a profile's bytes are; everything else asks.
   */
  private profileDir(profileId: string): string {
    return headlessProfileDir(this.userData, profileId)
  }

  /**
   * Why this host will not open a window in that profile, or null when it will.
   *
   * Two refusals, and the first is a security check rather than tidiness. The id
   * arrives from a phone, and every id becomes the last segment of a
   * `--user-data-dir`; `isProfileId` is the same shape `partitionFor` insists on
   * in `browser-profiles.ts` — *"`fromPartition` will happily create a directory
   * for **any** string — including one with a path separator in it"* — and the
   * consequence over this wire is a browser launched somewhere else on the disk.
   * The refused id is never echoed back, because at that point it is somebody
   * else's text rather than a profile name.
   *
   * The second is the roster: a profile this machine does not have would
   * otherwise be *minted* by opening a window in it — a new empty jar on a
   * server, created by a tap, listed by nothing.
   */
  private profileRefusal(profileId: string): string | null {
    if (!isProfileId(profileId)) {
      return 'that is not a profile this machine mints.'
    }
    const raw = ((): string | null => {
      try {
        return readFileSync(profilesFile(this.userData), 'utf8')
      } catch {
        // A machine that has never been asked has one profile and it is the
        // default. `readStoredProfiles` says so; this only has to not throw.
        return null
      }
    })()
    const stored = readStoredProfiles(raw)
    if (!stored.profiles.some((profile) => profile.id === profileId)) {
      return 'that is not a profile on this machine.'
    }
    return null
  }

  /** Where a finished download waits under its GUID before the move. */
  private downloadsDir(): string {
    return join(this.userData, 'downloads')
  }

  /**
   * The browser for a profile, launched at most once.
   *
   * Held as a promise so two calls that race the first launch wait on the one
   * process rather than starting two. A launch that fails rejects and is not
   * cached, so the next call tries again — a browser that failed to install once
   * may install on the retry that primed it.
   */
  private ensureBrowser(profileId: string): Promise<BrowserInstance> {
    const existing = this.browsers.get(profileId)
    if (existing !== undefined) return existing
    const started = this.startBrowser(profileId)
    this.browsers.set(profileId, started)
    started.then(
      // Recorded for the synchronous {@link browserFor}, which every caller
      // reaches only while holding a target — and a target is cached after this
      // has resolved, so the record is always there by then.
      (instance) => this.settledBrowsers.set(profileId, instance),
      // Drop a failed launch so it is retried rather than remembered as broken.
      () => this.browsers.delete(profileId),
    )
    return started
  }

  private async startBrowser(profileId: string): Promise<BrowserInstance> {
    const result = await this.launch({
      userDataDir: this.profileDir(profileId),
      extensionDirs: this.extensionDirsFor(profileId),
    })
    if (!result.ok) {
      // A named error, never a crash — the tool turns it into a sentence the
      // agent can read, the same posture `openTab` returning null takes.
      throw new Error(`the server's browser could not start: ${result.why}`)
    }
    /*
     * Two browser-level subscriptions, and they are not the same subscription.
     *
     * `setAutoAttach` multiplexes every target's session on the one pipe by
     * sessionId — the thing that makes a single `--remote-debugging-pipe` enough
     * for every tab.
     *
     * `setDiscoverTargets` is what makes Chromium emit `Target.targetInfoChanged`
     * at the browser level, and `browser-driven-cdp.ts` reads a page's title out
     * of exactly that event and nowhere else. Without it `page.title()` is the
     * empty string for the entire life of every target on a server — measured
     * against a real Chromium 146 on 2026-08-22: with auto-attach alone,
     * `Target.targetInfoChanged` arrived **zero** times over a full navigation to
     * a page whose title Chromium was perfectly willing to report when asked
     * directly; with discovery on, six. The title is the label a phone draws for
     * a tab, so the whole browser feature looked, on a server, like a list of
     * blank rows.
     *
     * They are separate calls because they are separate domains' switches, and
     * enabling one has never implied the other. Best-effort, like the rest of the
     * arming: a browser that refuses discovery still drives, it just cannot say
     * what its tabs are called.
     */
    await result.handle.transport
      .command({
        method: 'Target.setAutoAttach',
        params: { autoAttach: true, flatten: true, waitForDebuggerOnStart: false },
      })
      .catch(() => undefined)
    await result.handle.transport
      .command({ method: 'Target.setDiscoverTargets', params: { discover: true } })
      .catch(() => undefined)
    const downloads = this.armDownloads(result.handle.transport)
    return { handle: result.handle, downloads }
  }

  /**
   * Arm downloads for a browser: pin `allowAndName` at the host's downloads dir
   * and feed the ledger from `Browser.downloadWillBegin` / `downloadProgress`.
   *
   * Best-effort — a browser that refuses the arming still drives; the ledger just
   * gains no rows for it, which the download tool reports rather than inventing.
   */
  private armDownloads(transport: CdpTransport): CdpDownloadHandle | null {
    const channel: CdpDownloadChannel = {
      send: (method, params) => transport.command({ method, params }),
      on: (method, handler) =>
        transport.on(undefined, (event: CdpEvent) => {
          if (event.method === method) handler(asRecord(event.params))
        }),
    }
    try {
      return installCdpDownloads({ channel, downloadsDir: this.downloadsDir() })
    } catch {
      return null
    }
  }

  /* ----------------------------------------------------------- the targets -- */

  /**
   * Open a target for the given profile, in a fresh in-memory context when
   * `isolate`, and cache the page the driver will steer.
   *
   * Returns null on any failure, publishing the reason — the `DriveHost.openTab`
   * contract: the tool says "no browser to open" rather than inventing a tab.
   */
  private async makeTarget(input: {
    url: string
    isolate: boolean
    profileId: string
    browserTabId: string
  }): Promise<Target | null> {
    let browser: BrowserInstance
    try {
      browser = await this.ensureBrowser(input.profileId)
    } catch (error) {
      this.publishError(error)
      return null
    }
    const transport = browser.handle.transport

    let browserContextId = ''
    if (input.isolate) {
      // A throwaway jar that dies with the context — the server's equivalent of
      // the desktop's in-memory partition.
      const created = asRecord(
        await transport
          .command({ method: 'Target.createBrowserContext', params: { disposeOnDetach: true } })
          .catch(() => ({})),
      )
      if (typeof created.browserContextId === 'string') browserContextId = created.browserContextId
    }

    const created = asRecord(
      await transport
        .command({
          method: 'Target.createTarget',
          params: {
            url: input.url,
            ...(browserContextId === '' ? {} : { browserContextId }),
          },
        })
        .catch(() => ({})),
    )
    const targetId = created.targetId
    if (typeof targetId !== 'string' || targetId === '') {
      this.publishError(new Error('the server’s browser did not open a page'))
      return null
    }

    const page = cdpDrivenPage(transport, { targetId, url: input.url })
    const target: Target = {
      targetId,
      profileId: input.profileId,
      browserContextId,
      page,
      browserTabId: input.browserTabId,
      isolated: input.isolate,
    }
    this.targets.set(targetId, target)
    if (input.browserTabId !== '') this.byBrowserTab.set(input.browserTabId, targetId)
    return target
  }

  /* --------------------------------------------------------- DriveHost API -- */

  async openTab(input: { url: string; isolate: boolean }): Promise<string | null> {
    // The copilot's own tab has no shell id — its number is never minted, the
    // way `OWN_TARGET` has an empty `browserTabId` on the desktop.
    const target = await this.makeTarget({
      url: input.url,
      isolate: input.isolate,
      profileId: DEFAULT_PROFILE_ID,
      browserTabId: '',
    })
    return target?.targetId ?? null
  }

  contentsFor(tabId: string): DrivenPage | null {
    const target = this.targets.get(tabId)
    if (target === undefined) return null
    if (target.page.isGone()) {
      this.forget(tabId)
      return null
    }
    return target.page
  }

  publish(status: DriveStatus): void {
    this.publishFn(status)
  }

  now(): number {
    return this.nowFn()
  }

  /**
   * A shell id for a window this host can find again.
   *
   * `browser:<epoch-ms>:<uuid>` — the same shape the renderer mints on the
   * desktop, and the thing that separates a window from a target: a target id
   * belongs to Chromium and is re-minted whenever the page is re-opened
   * somewhere else, while this is the binding key `B2` is drawn from and must
   * outlive every one of those moves.
   */
  private mintTabId(): string {
    return `browser:${this.nowFn()}:${randomUUID().slice(0, 8)}`
  }

  /**
   * Open a window this host holds, attached to nothing.
   *
   * ## Why this exists
   *
   * `openForSession` below was, for a while, the only door that minted a shell
   * id — so `machine-browser.ts` called it with a session id of `''` and undid
   * the attach in the same breath, and wrote down in its own header that the
   * sentinel was a hack waiting for this method:
   *
   * > *"`HeadlessDriveHost` wants an `openWindow` that mints and registers a
   * > shell id **without** attaching it to anything, at which point the two lines
   * > below become one and the sentinel goes away. Written down here because a
   * > hack nobody records is a hack that becomes the design."*
   *
   * A window a phone opens belongs to nobody until somebody binds it — *"Nothing
   * is chosen by default. Not the focused session, not the newest, not the only
   * one"* — and a door that attaches first is a door that has to be corrected,
   * over a store where a correction is visible to an agent mid-turn.
   *
   * ## And why it takes a profile and an isolation flag
   *
   * Because the old door hard-coded both, which is what made *"making a browsing
   * session into an isolated or shared one"* and *"we don't have profiles like we
   * have in the Mac desktop application"* untrue on a server rather than merely
   * unfinished. Both are real here and neither is a new mechanism:
   *
   *  - **Isolated** is `Target.createBrowserContext` — an in-memory jar that dies
   *    with the target, which is what an Electron partition with no `persist:`
   *    prefix is on the desktop. {@link makeTarget} has always known how.
   *  - **A named profile** is a *second Chromium process*, launched by
   *    {@link ensureBrowser} against `<userData>/Partitions/<profileId>`. Not a
   *    `--profile-directory`, which selects a profile inside one user-data
   *    directory and cannot be chosen per target — CDP's `Target.createTarget`
   *    names a browser context, never a profile — and not a browser context,
   *    which is exactly the thing that does *not* persist. One process per jar is
   *    what makes a jar survive a restart, and this host has held its browsers in
   *    a map keyed by profile id since it was written.
   */
  async openWindow(input: {
    url: string
    isolate: boolean
    /** Absent means the default profile, the one every build before profiles used. */
    profileId?: string
  }): Promise<{ ok: true; browserTabId: string; viewId: string } | { ok: false; why: string }> {
    const profileId = input.profileId === undefined || input.profileId === '' ? DEFAULT_PROFILE_ID : input.profileId
    const refusal = this.profileRefusal(profileId)
    if (refusal !== null) {
      return { ok: false, why: `This server's browser cannot open a window there: ${refusal}` }
    }
    const browserTabId = this.mintTabId()
    const target = await this.makeTarget({
      url: input.url,
      isolate: input.isolate,
      profileId,
      browserTabId,
    })
    if (target === null) {
      // The host watched its own Chromium fail and has the real sentence — a
      // missing library names the packages that fix it. Taken here rather than
      // left for a later `whyNoTab`, because it answers about *this* open.
      return { ok: false, why: this.whyNoTab() ?? "the server's browser did not open a window." }
    }
    return { ok: true, browserTabId, viewId: target.targetId }
  }

  async openForSession(input: {
    url: string
    sessionId: string
    newWindow?: boolean
    machineId?: string
  }): Promise<{ line: string; attached: boolean }> {
    // A window a session can see and hand back: a target attached to that
    // session in the same `browser-binding` store the desktop mints B1/B2 from,
    // so a window opened on the server means the same thing to the phone. The
    // agent's own `browser_open` arrives here; the phone's New Window does not,
    // and has not since {@link openWindow} existed.
    const browserTabId = this.mintTabId()
    const target = await this.makeTarget({
      url: input.url,
      isolate: false,
      profileId: DEFAULT_PROFILE_ID,
      browserTabId,
    })
    if (target === null) {
      return {
        line: 'the server could not open a browser window for this session.',
        attached: false,
      }
    }
    const window: BoundWindow = attach({
      sessionId: input.sessionId,
      machineId: input.machineId ?? '',
      browserTabId,
      viewId: target.targetId,
      url: input.url,
    })
    return { line: `Opened ${slotName(window.n)} on the server`, attached: true }
  }

  /**
   * Back or forward, over the one protocol call that moves through history.
   *
   * ## What was here instead
   *
   * A refusal. `Page.navigateToHistoryEntry` was on the CDP deny-list because it
   * names an entry id rather than an address, so `isNavigationAllowed` — *"the
   * only guard there is"* on this transport — had nothing to screen, and
   * `machine-browser.ts` answered *"this server's browser cannot go back"* while
   * Reload worked. Two of the three most-used controls on a browser screen.
   *
   * ## The check that replaces it, in full
   *
   * The entry is not trusted from anywhere; it is **read out of the page's own
   * history in this process, immediately before it is used**. `Page.getNavigationHistory`
   * answers the entry list and the index the page is at; the neighbour in the
   * asked-for direction is the only entry this will ever name, and its address is
   * put through `isNavigationAllowed` — the same allow-list a typed URL passes —
   * before the move is sent. So the guard is doing exactly what it does for a
   * navigation: screening the address the page is about to be at. `screenHistoryEntry`
   * then screens the call itself, so the frame that goes on the wire cannot
   * carry a URL alongside the id.
   *
   * What it still cannot do is verify an entry id in the abstract: an id is a
   * slot in one target's history, meaningless to any other target and unknowable
   * to a pure screen. That is why this method exists at all rather than a wider
   * allow-list — the id never comes from a caller, and there is no path by which
   * one could.
   */
  async historyMove(
    viewId: string,
    move: 'back' | 'forward',
  ): Promise<{ moved: true } | { moved: false; why: string }> {
    const target = this.targets.get(viewId)
    if (target === undefined || target.page.isGone()) {
      return { moved: false, why: 'this server is no longer holding that window' }
    }
    const page = target.page
    try {
      // The history read is a page-session command, so the page has to be
      // attached. Idempotent, and left attached: the drive attaches and detaches
      // around its own actions and a detach here could land in the middle of one.
      await page.attach()
      const history = asRecord(await page.send('Page.getNavigationHistory', {}))
      const entries = Array.isArray(history.entries) ? history.entries : []
      const at = typeof history.currentIndex === 'number' ? history.currentIndex : -1
      const wanted = move === 'back' ? at - 1 : at + 1
      if (at < 0 || wanted < 0 || wanted >= entries.length) {
        return { moved: false, why: `that window has nothing to go ${move} to` }
      }
      const entry = asRecord(entries[wanted])
      const entryId = entry.id
      if (!isNavigationAllowed(entry.url)) {
        // A page cannot talk Chromium into a `file:` entry from an http
        // document, so this is a refusal that should never fire — which is
        // precisely why it is here rather than assumed. The address is screened
        // on the way out of the history exactly as it would be on the way in.
        return {
          moved: false,
          why: `that window's previous page is not an address this app will open`,
        }
      }
      const verdict = screenHistoryEntry({ entryId })
      if (!verdict.ok) return { moved: false, why: verdict.reason }
      await page.send('Page.navigateToHistoryEntry', { entryId })
      return { moved: true }
    } catch (error) {
      const said = error instanceof Error ? error.message : 'it did not say why'
      return { moved: false, why: `that window could not go ${move}: ${said}` }
    }
  }

  /**
   * Move an open window's page into the other kind of cookie jar, keeping the
   * window.
   *
   * Isolation is fixed when a page is constructed — `browser-isolation.ts` is
   * emphatic about it, and it is a property of Chromium rather than a choice —
   * so this is what the desktop's `BrowserWorkspace.toggleIsolation` does: close
   * the view, open another at the same address. The **window id does not
   * change**, because it is the binding key `B2` is minted from and *"a
   * renumbered window makes an agent point confidently at the wrong page, and it
   * does it within a turn"*.
   *
   * The new target is opened *before* the old one is closed, so a repartition
   * that fails leaves the window exactly as it was rather than closing somebody's
   * page and reporting a failure.
   */
  async repartitionWindow(
    browserTabId: string,
    isolate: boolean,
  ): Promise<{ viewId: string } | null> {
    const oldId = this.byBrowserTab.get(browserTabId)
    const old = oldId === undefined ? undefined : this.targets.get(oldId)
    if (oldId === undefined || old === undefined) return null

    // Where the page is now. A target that has not navigated yet reports its
    // opening address; anything the guard would refuse becomes a blank page
    // rather than a refusal, since the person asked to change the jar and not to
    // stay on the page.
    const at = old.page.url()
    const url = isNavigationAllowed(at) ? at : 'about:blank'

    const fresh = await this.makeTarget({
      url,
      isolate,
      profileId: old.profileId,
      browserTabId: '',
    })
    if (fresh === null) return null

    await this.closeTarget(old)
    this.forget(oldId)

    fresh.browserTabId = browserTabId
    this.byBrowserTab.set(browserTabId, fresh.targetId)
    return { viewId: fresh.targetId }
  }

  async closeWindow(browserTabId: string): Promise<boolean> {
    const targetId = this.byBrowserTab.get(browserTabId)
    if (targetId === undefined) {
      // Still tell the binding store — a window row must not outlive the target.
      windowClosed(browserTabId)
      return false
    }
    const target = this.targets.get(targetId)
    if (target !== undefined) await this.closeTarget(target)
    this.forget(targetId)
    windowClosed(browserTabId)
    return true
  }

  /**
   * Close one target in Chromium, and the throwaway context an isolated one
   * lives in.
   *
   * The context goes with the target rather than being left behind: an isolated
   * jar that outlived its only page would be storage nothing can name and
   * nothing will ever close, which is the leak `Target.createBrowserContext` is
   * denied for on the desktop transport. Best-effort — a target that has already
   * gone is the ordinary case here, not a failure.
   */
  private async closeTarget(target: Target): Promise<void> {
    const transport = this.browserFor(target.profileId)?.handle.transport
    if (transport === undefined) return
    await transport
      .command({ method: 'Target.closeTarget', params: { targetId: target.targetId } })
      .catch(() => undefined)
    if (target.browserContextId !== '') {
      await transport
        .command({
          method: 'Target.disposeBrowserContext',
          params: { browserContextId: target.browserContextId },
        })
        .catch(() => undefined)
    }
  }

  /**
   * Bring a window to the front — a success no-op on this host.
   *
   * See the class header: every headless target composites and accepts input
   * regardless of front/back, so there is no hidden 0×0 viewport to raise. The
   * desktop's `showWindow` exists only to defeat that, and its absence here is
   * the measured reason a 16-worker fleet is drivable at once.
   */
  async showWindow(_browserTabId: string): Promise<boolean> {
    return true
  }

  captureFolder(input: { viewId: string; runId: string }): string | null {
    const profileId = this.profileOf(input.viewId)
    if (profileId === null) return null
    return captureDir(this.userData, profileId === '' ? 'isolated' : profileId, input.runId)
  }

  blockCapture(viewId: string): { dir: string; on: boolean } | null {
    const profileId = this.profileOf(viewId)
    if (profileId === null) return null
    const id = profileId === '' ? 'isolated' : profileId
    // The panel's store wins for a real profile, exactly as the desktop resolves
    // it; an isolated target has no stored settings, so its camera is on.
    const on =
      profileId === ''
        ? true
        : scrapeSettingsFor(this.userData, profileId).checks.screenshotOnBlock !== false
    return { dir: blockShotDirFor(this.userData, id), on }
  }

  scrapeDefaults(viewId: string): {
    rules: ReturnType<typeof fetchRulesOf>
    capture: boolean | null
    bounds: ReturnType<typeof captureBoundsOf>
    blockShots: boolean | null
  } | null {
    const profileId = this.profileOf(viewId)
    if (profileId === null || profileId === '') return null
    const settings = scrapeSettingsFor(this.userData, profileId)
    return {
      rules: fetchRulesOf(settings),
      capture: settings.capture.on,
      bounds: captureBoundsOf(settings),
      blockShots: settings.checks.screenshotOnBlock,
    }
  }

  /* --------------------------------------------------- profile-cookied fetch -- */

  /**
   * The profile-cookied `AssetOpen` for one open target.
   *
   * A single-URL `Network.getCookies` read off that target's own page, replayed
   * onto an undici fetch — the server's stand-in for the desktop's implicit
   * partition jar, behind the same seam `browser-asset-fetch.ts` already takes.
   * Null when the target is gone. The page must be attached (it is while the
   * drive is harvesting), because the cookie read is a page-session command.
   */
  assetOpenFor(viewId: string): AssetOpen | null {
    const target = this.targets.get(viewId)
    if (target === undefined || target.page.isGone()) return null
    const channel: CdpAssetChannel = {
      send: (method, params) => target.page.send(method, (params ?? {}) as Record<string, unknown>),
    }
    return cdpAssetFetchFor({ channel })
  }

  /* ---------------------------------------------------------- guest bridge -- */

  /**
   * Deliver the guest preload to a target and route its messages back.
   *
   * The server's equivalent of the desktop's `wireGuestEvents`: over CDP there
   * is no preload path, so this re-delivers `GUEST_PRELOAD_SOURCE` via
   * `Page.addScriptToEvaluateOnNewDocument` + `Runtime.addBinding`
   * (`installCdpGuestPreload`), then routes the guest's `__deckGuest` calls —
   * which arrive as `Runtime.bindingCalled` — through {@link parseGuestBinding}
   * to {@link HeadlessDriveHostDeps.onGuestMessage}. The host opens its own
   * session to the target so the bridge is independent of the drive's session.
   *
   * Called by the inspection surface when it wants a target's guest reporting;
   * the surface itself — a connected device asking to inspect — is where this
   * bridge's other end lands, and is the follow-up this mechanism waits for.
   */
  async armGuestPreload(viewId: string): Promise<boolean> {
    const target = this.targets.get(viewId)
    if (target === undefined || target.page.isGone()) return false
    if (this.guests.has(viewId)) return true
    const transport = this.browserFor(target.profileId)?.handle.transport
    if (transport === undefined) return false

    const attached = asRecord(
      await transport
        .command({ method: 'Target.attachToTarget', params: { targetId: viewId, flatten: true } })
        .catch(() => ({})),
    )
    const sessionId = attached.sessionId
    if (typeof sessionId !== 'string' || sessionId === '') return false

    const bridge: GuestBridge = {
      sessionId,
      send: (method, params) =>
        transport.command({ method, params, sessionId }).then((result) => asRecord(result)),
    }
    this.guests.set(viewId, bridge)

    transport.on(sessionId, (event: CdpEvent) => {
      const params = asRecord(event.params)
      if (event.method === 'Runtime.bindingCalled') {
        // Guest → main: `__deckGuest(json)` routed to the same handlers
        // `wireGuestEvents` wires on the desktop.
        const message = parseGuestBinding(params.name, params.payload)
        if (message !== null) this.onGuestMessage?.({ targetId: viewId, message })
        return
      }
      if (event.method === 'Runtime.executionContextCreated') {
        // Learn the guest world's context so {@link dispatchToGuest} can name it
        // rather than the page's main world.
        const context = asRecord(params.context)
        if (context.name === CDP_GUEST_WORLD && typeof context.id === 'number') {
          bridge.contextId = context.id
        }
        return
      }
      if (event.method === 'Runtime.executionContextsCleared') {
        bridge.contextId = undefined
      }
    })

    // Runtime on so bindingCalled and executionContextCreated fire; Page on so
    // the on-new-document script takes. Both best-effort — a target that refuses
    // one is reported by the install's own failure rather than here.
    await bridge.send('Runtime.enable', {}).catch(() => undefined)
    await bridge.send('Page.enable', {}).catch(() => undefined)
    try {
      await installCdpGuestPreload(bridge)
      return true
    } catch {
      this.guests.delete(viewId)
      return false
    }
  }

  /**
   * Send one main → guest message, the mirror of {@link armGuestPreload}'s
   * inbound routing.
   *
   * `GUEST_INSPECT` / `GUEST_LOGIN_FILL` on the desktop go over `webContents.send`;
   * here they are a `Runtime.evaluate` of {@link cdpGuestDispatchExpression} in
   * the guest world's own execution context — never the page's main world, the
   * same property the drive's reads keep — with arguments carried as JSON so
   * there is no path from a value to executable text. Best-effort: a target with
   * no guest bridge armed, or none navigated far enough for the world to exist
   * yet, simply does nothing, which is what the desktop's `send` to a gone
   * window does.
   */
  async dispatchToGuest(viewId: string, channel: string, args: readonly unknown[]): Promise<void> {
    const bridge = this.guests.get(viewId)
    if (bridge === undefined || bridge.contextId === undefined) return
    await bridge
      .send('Runtime.evaluate', {
        expression: cdpGuestDispatchExpression(channel, args),
        contextId: bridge.contextId,
        returnByValue: true,
      })
      .catch(() => undefined)
  }

  /* ------------------------------------------------------------- teardown -- */

  /**
   * How long a stopped Chromium gets to actually be gone.
   *
   * `handle.stop()` is `child.kill()`, which is a signal rather than an
   * ending — the process is gone a tick or two later, and until it is, its
   * profile directory is a set of open file handles. Generous, because the only
   * caller is a person emptying a profile from their phone and the alternative
   * to waiting is telling them their sign-ins are gone while the browser that
   * holds them is still running.
   */
  private static readonly STOP_TIMEOUT_MS = 10_000

  /**
   * Let go of one profile: close its windows, stop its browser, and say whether
   * the process is really gone.
   *
   * The `release` half of `browser-profile-storage.ts`'s owner contract, and the
   * reason that contract exists. A phone's *Clear this profile* deletes a
   * directory, and deleting a directory Chromium has open is not a clear: on
   * Windows the unlink fails outright, and on macOS and Linux it succeeds while
   * the running browser keeps the jar it already has in memory and writes it
   * back. Either way the person is signed in and has been told they are not.
   *
   * So the browser is ended first and the ending is **waited for**, not
   * requested. `released: false` stops the clear before a single file is
   * removed, which is the honest answer: nothing was emptied, and the profile
   * has a browser in it.
   *
   * The windows go with it, through the same `windowClosed` a close performs, so
   * no binding row is left pointing at a target that no longer exists — *"an
   * agent steering a window that is not there"*.
   */
  private async releaseProfile(profileId: string): Promise<{ released: boolean; why: string }> {
    for (const [targetId, target] of [...this.targets]) {
      if (target.profileId !== profileId) continue
      const browserTabId = target.browserTabId
      this.forget(targetId)
      if (browserTabId !== '') windowClosed(browserTabId)
    }

    const pending = this.browsers.get(profileId)
    this.browsers.delete(profileId)
    this.settledBrowsers.delete(profileId)
    if (pending === undefined) {
      return { released: true, why: 'no browser was running for that profile' }
    }

    let instance: BrowserInstance
    try {
      instance = await pending
    } catch {
      // The launch that never came up has no process and no open files.
      return { released: true, why: 'that profile never started a browser' }
    }
    instance.downloads?.dispose()
    instance.handle.stop()

    const whenGone = instance.handle.whenGone
    if (whenGone === undefined) {
      // A scripted launch has no child to die. Taken at its word; the directory
      // check after the removal is what the answer actually rests on, and
      // `defaultLaunch` always reports.
      return { released: true, why: '' }
    }
    const gone = await Promise.race([
      whenGone.then(() => true),
      new Promise<boolean>((resolve) => {
        const timer = setTimeout(() => resolve(false), HeadlessDriveHost.STOP_TIMEOUT_MS)
        timer.unref?.()
      }),
    ])
    if (!gone) {
      return {
        released: false,
        why: "the server's browser for that profile was asked to stop and had not stopped",
      }
    }
    return { released: true, why: '' }
  }

  /**
   * Stop every browser this host launched.
   *
   * The host's own lifecycle owns the child processes — the pipe closing never
   * kills them, so this is the one place they end. Idempotent.
   */
  async stop(): Promise<void> {
    // Answer for no directories once the browsers are going. A registration
    // that outlived its host would tell a clear to wait for a process that has
    // already ended.
    this.disownStorage()
    const instances = [...this.browsers.values()]
    this.browsers.clear()
    this.settledBrowsers.clear()
    this.targets.clear()
    this.byBrowserTab.clear()
    this.guests.clear()
    for (const pending of instances) {
      try {
        const instance = await pending
        instance.downloads?.dispose()
        instance.handle.stop()
      } catch {
        /* A browser that never came up has nothing to stop. */
      }
    }
  }

  /* -------------------------------------------------------------- helpers -- */

  private forget(targetId: string): void {
    const target = this.targets.get(targetId)
    this.targets.delete(targetId)
    this.guests.delete(targetId)
    if (target !== undefined && target.browserTabId !== '') {
      this.byBrowserTab.delete(target.browserTabId)
    }
  }

  /** The profile a view belongs to: `''` for an isolated target, the id else, null when unknown. */
  private profileOf(viewId: string): string | null {
    const target = this.targets.get(viewId)
    if (target === undefined) return null
    return target.isolated ? '' : target.profileId
  }

  /** The already-launched browser for a profile, or undefined before it is up. Never launches. */
  private browserFor(profileId: string): BrowserInstance | undefined {
    return this.settledBrowsers.get(profileId)
  }

  private publishError(error: unknown): void {
    const message = error instanceof Error ? error.message : 'the server’s browser is unavailable'
    // Kept as well as published. The banner is what a *person* watching a device
    // sees; `whyNoTab` is what the copilot is told when its `openTab` came back
    // null, and without it the driver falls back to a sentence about a Settings
    // pane this machine does not have. See `browser-driver.ts`.
    this.lastFailure = message
    // The banner carries the reason so a connected device shows why nothing
    // moved rather than a spinner that never resolves.
    this.publishFn({ state: 'idle', tabId: null, step: message, prompt: '', url: '' })
  }

  /**
   * Why the last {@link openTab} produced nothing — the `DriveHost` half of the
   * same message the banner got.
   *
   * Cleared on read, because it answers about *that* failure: a stale reason
   * attached to a later, unrelated null would be a worse answer than none.
   */
  whyNoTab(): string | null {
    const why = this.lastFailure
    this.lastFailure = null
    return why
  }
}
