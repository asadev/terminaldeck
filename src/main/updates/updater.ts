/**
 * In-app updates: the main-process half.
 *
 * ## The contract
 *
 * Check → notify → **the user chooses** → download with progress → install on
 * quit or on an explicit "restart now". Nothing installs itself behind the
 * user's back, and the two settings that enforce that are set in one place at
 * the top of `wire()`:
 *
 *   - `autoDownload = false`, so finding an update only ever produces a
 *     sentence in the panel. electron-updater's default is `true`, which would
 *     spend a user's tethered connection on 119 MB they did not ask for.
 *   - `autoInstallOnAppQuit = true`, which is *not* a contradiction. It is the
 *     "install on quit" half of the contract and it only has anything to
 *     install after `download()` was called explicitly. Verified against the
 *     shipped `electron-updater@6.8.9`: `MacUpdater` reads this flag
 *     (MacUpdater.js:220, :248) and hands the staged update to Squirrel.Mac,
 *     which swaps the bundle after the app exits.
 *
 * `quitAndInstall()` appears exactly once in this file, inside `installNow()`,
 * which is reachable only from the `update:install` channel. Tests assert the
 * call count is zero on every other path — registering the IPC, finding an
 * update, downloading one, a failed download, six hours of timers — which is
 * as close to "no other path reaches it" as a test can get.
 *
 * ## Why `unsupported` is a first-class state
 *
 * Every current build of this app is unsigned, and an unsigned macOS app
 * cannot update itself. Squirrel.Mac — the framework Electron's native
 * `autoUpdater` drives, which `MacUpdater` sits on top of — refuses to replace
 * a bundle it cannot verify a code signature for. `electron-builder.yml` sets
 * `identity: null` because there is no Developer ID on the build machine, so
 * electron-builder signs nothing at all.
 *
 * That claim was checked against the real bundle rather than taken from the
 * config, because the config describes an intention and the bundle is the
 * artifact. `codesign -dv "/Applications/Terminal Deck.app"` reported:
 *
 *     Format=app bundle with Mach-O thin (arm64)
 *     CodeDirectory v=20400 … flags=0x20002(adhoc,linker-signed)
 *     Signature=adhoc
 *     TeamIdentifier=not set
 *     Sealed Resources=none
 *
 * `Signature=adhoc` and `TeamIdentifier=not set` are the signature Apple's
 * linker put on Electron itself, not a Developer ID signature over this app.
 * `Sealed Resources=none` is the part this module can detect without shelling
 * out to `codesign`: a bundle with sealed resources has a
 * `Contents/_CodeSignature/CodeResources` file, and Terminal Deck.app has no
 * `Contents/_CodeSignature` directory at all. Three Developer ID-signed apps on
 * the same disk were checked as a control — Vibeyard (team 5FTPLDMFRS), Google
 * Chrome (EQHXZ8M8AV) and Visual Studio Code (UBF8T346G9) — and all three have
 * that file and a team identifier. So the marker separates the two cases on
 * real evidence, and it is a `statSync` rather than a subprocess on a path the
 * app runs from.
 *
 * The failure this avoids is specific. Without the check, an unsigned build
 * would check happily, find a release, download 119 MB, and then die inside
 * Squirrel with an opaque error — after spending the bandwidth. Reporting
 * `unsupported` up front, with a sentence the panel prints verbatim, costs the
 * user nothing and tells them the true next step: download it from Releases.
 *
 * ## What is injected and why
 *
 * `UpdaterLike` is the slice of `electron-updater`'s `autoUpdater` this module
 * uses. It is injected rather than imported, for two reasons that matter:
 * touching the real one reaches GitHub over the network, and merely reading
 * `autoUpdater` from the package constructs a `MacUpdater`, which `require`s
 * `electron` — neither of which exists under vitest. Nothing in this file
 * imports `electron` or `electron-updater` at runtime; the two type-only
 * imports below are erased. The environment facts the module needs
 * (`isPackaged`, `execPath`, the feed path) arrive the same way, from
 * `src/main/index.ts`, which is the only place allowed to know about Electron.
 *
 * A test proves the seam still fits the real class by assigning an `AppUpdater`
 * to it — a compile-time check, so the type cannot drift without the build
 * failing, and still nothing is loaded.
 */

import { existsSync } from 'node:fs'
import type { IpcMain } from 'electron'
import type { ProgressInfo, UpdateDownloadedEvent, UpdateInfo } from 'electron-updater'
import { appWindowFocus, type FocusSource } from './window-focus'

/* ------------------------------------------------------------------ state -- */

/**
 * What the panel renders, as a discriminated union.
 *
 * The shape is deliberately closed: the UI switches on `phase` and every arm
 * carries exactly what that arm needs to draw itself. There is no "is there an
 * update" boolean to reconcile with a version string that might be stale, and
 * no field that is meaningful in one phase and leftover in another.
 */
export type UpdateState =
  /** No update pending. `checkedAt` is null until the first check finishes. */
  | { phase: 'idle'; checkedAt: number | null }
  | { phase: 'checking' }
  /** Found, not fetched. Nothing has been downloaded in this state. */
  | { phase: 'available'; version: string; notes: string | null; sizeBytes: number | null }
  | { phase: 'downloading'; version: string; percent: number; bytesPerSecond: number }
  /** Staged on disk. Installs on quit, or now if the user says so. */
  | { phase: 'ready'; version: string }
  | { phase: 'error'; message: string }
  /** This build cannot update itself, and `reason` is the sentence to show. */
  | { phase: 'unsupported'; reason: string }

/** The channel the main process pushes {@link UpdateState} on. */
export const UPDATE_STATE_CHANNEL = 'update:state'

/* ------------------------------------------------------- the injected half -- */

/**
 * The part of `electron-updater`'s `autoUpdater` this module drives.
 *
 * Written as overloads rather than one generic method so that a plain object
 * literal in a test can satisfy it, and so that each listener's payload is
 * named by the type the real emitter passes. `update-cancelled`, `login` and
 * `appimage-filename-updated` are absent because nothing here subscribes to
 * them; a seam should be the surface actually used, not a copy of the class.
 */
export interface UpdaterLike {
  autoDownload: boolean
  autoInstallOnAppQuit: boolean
  on(event: 'checking-for-update', listener: () => void): unknown
  on(event: 'update-available', listener: (info: UpdateInfo) => void): unknown
  on(event: 'update-not-available', listener: (info: UpdateInfo) => void): unknown
  on(event: 'download-progress', listener: (progress: ProgressInfo) => void): unknown
  on(event: 'update-downloaded', listener: (event: UpdateDownloadedEvent) => void): unknown
  on(event: 'error', listener: (error: Error) => void): unknown
  checkForUpdates(): Promise<unknown>
  downloadUpdate(): Promise<unknown>
  quitAndInstall(): void
}

/**
 * The facts about *this* running build that decide whether updating is
 * possible. Passed in rather than read from `electron` so the whole decision is
 * a pure function of its arguments.
 */
export interface UpdateEnvironment {
  /** `process.platform`. */
  platform: NodeJS.Platform
  /** `app.isPackaged`. */
  isPackaged: boolean
  /** `process.execPath` — the bundle it sits inside is the one being checked. */
  execPath: string
  /** Where electron-builder writes the feed: `resourcesPath/app-update.yml`. */
  feedConfigPath: string
}

/**
 * The way to update a build Squirrel will not touch.
 *
 * Squirrel.Mac refuses to replace a bundle it cannot verify a signature for,
 * which is every unsigned build — including this one. That is a limit of
 * Squirrel, not of updating: the feed, the archive and its sha512 are all
 * public, and replacing an app bundle is a move. This is that path, injected so
 * the state machine below does not care which one is in use.
 *
 * Supplied only on macOS today. When it is absent the verdict stands and the
 * panel says so, which is the honest answer rather than a silent no-op.
 */
export interface ManualStrategy {
  /** The newest release, or null when it is not newer than the running one. */
  check(): Promise<{ version: string; notes: string | null; sizeBytes: number | null } | null>
  /** Download and verify. Resolves once the bytes are proven and unpacked. */
  download(
    version: string,
    onProgress: (percent: number, bytesPerSecond: number) => void,
  ): Promise<{ ok: true } | { ok: false; message: string }>
  /** Swap the bundle and relaunch. Only reachable from `ready`. */
  install(version: string): Promise<{ ok: true } | { ok: false; message: string }>
}

export interface UpdaterDeps {
  updater: UpdaterLike
  /** Used instead of Squirrel when this build cannot be updated by Squirrel. */
  manual?: ManualStrategy
  environment: UpdateEnvironment
  /** Push a state to the renderer. `src/main/index.ts` supplies the window. */
  broadcast: (channel: string, state: UpdateState) => void
  /** Injected so a test can describe a bundle without creating one on disk. */
  fileExists?: (path: string) => boolean
  now?: () => number
  /**
   * What counts as "the user came back", and how to stop listening.
   *
   * Defaults to Electron's `browser-window-focus`. Injected so the tests can
   * drive the trigger by hand, and so a caller with a better signal — a single
   * window it already tracks, say — can supply that instead.
   */
  onFocus?: FocusSource
}

/* ---------------------------------------------------------------- support -- */

/** Either this build can update itself, or here is the sentence saying why not. */
export type SupportVerdict = { supported: true } | { supported: false; reason: string }

/**
 * The app bundle `execPath` runs from, or null when it is not inside one.
 *
 * `lastIndexOf` rather than `indexOf`, so a helper executable nested inside
 * another bundle's `Contents` resolves to the bundle it actually sits in
 * rather than to the outer one. That is not the bundle an update would replace
 * — Squirrel swaps the outer `.app` — but it is the right one to ask about a
 * signature, because it is the bundle whose signature this executable is
 * running under. In practice the main process's `execPath` is the outer
 * bundle's own binary, so the two coincide; the rule only matters if that ever
 * stops being true.
 */
export function macBundleRoot(execPath: string): string | null {
  const marker = execPath.lastIndexOf('.app/')
  return marker === -1 ? null : execPath.slice(0, marker + '.app'.length)
}

/**
 * The file whose presence means the bundle carries a real, sealed signature.
 *
 * See the module header for the `codesign` output this is derived from, and for
 * the three signed apps it was checked against.
 */
export function codeSignaturePath(bundleRoot: string): string {
  return `${bundleRoot}/Contents/_CodeSignature/CodeResources`
}

const DEV_BUILD_REASON =
  'This is a development build — it runs from source, so there is nothing to update. ' +
  'Packaged builds check GitHub releases for a newer version.'

const UNSIGNED_REASON =
  'This build is not code-signed, so it cannot install its own updates: macOS applies ' +
  'updates through Squirrel.Mac, which refuses to replace an app it cannot verify a ' +
  'signature for. Download the new version from Releases and replace the app by hand.'

const NO_FEED_REASON =
  'This build was packaged without a release feed, so there is nowhere to check. ' +
  'Download new versions from Releases.'

/**
 * Whether this build can update itself, and the sentence to show when it cannot.
 *
 * Order is deliberate: a development build is the common case and says so
 * plainly; the signature comes next because it is the blocker nothing else can
 * work around — a perfectly configured feed on an unsigned bundle still cannot
 * install — and the missing feed last, because it is the one a rebuild fixes.
 *
 * The signature test only runs on darwin. Windows and Linux have their own
 * rules (electron-updater verifies the publisher itself on Windows, AppImage
 * needs no signature at all), and this project builds neither today —
 * `electron-builder.yml` targets mac arm64 only. Claiming an unsigned Windows
 * build could not update would be inventing a limit nobody has measured.
 */
export function updateSupport(
  environment: UpdateEnvironment,
  fileExists: (path: string) => boolean,
): SupportVerdict {
  if (!environment.isPackaged) return { supported: false, reason: DEV_BUILD_REASON }

  if (environment.platform === 'darwin') {
    const bundle = macBundleRoot(environment.execPath)
    // No bundle at all is the same practical answer as an unsigned one: there
    // is nothing Squirrel could swap. Saying "unsigned" is the honest summary.
    if (!bundle || !fileExists(codeSignaturePath(bundle))) {
      return { supported: false, reason: UNSIGNED_REASON }
    }
  }

  if (!fileExists(environment.feedConfigPath)) return { supported: false, reason: NO_FEED_REASON }

  return { supported: true }
}

/* ------------------------------------------------------ reading the feed -- */

/** Release notes are shown to a person; a whole changelog is not a notification. */
export const MAX_NOTES_LENGTH = 4000

/**
 * The release notes as one string, or null when the feed carried none.
 *
 * `releaseNotes` is a string on some providers and an array of
 * `{ version, note }` on others, and either can be null. Whatever comes back is
 * **untrusted text from a network feed** — it is the body of a GitHub release —
 * so it is returned as text and must be rendered as text. Nothing here turns it
 * into markup, and the renderer must not either.
 */
export function readNotes(info: UpdateInfo): string | null {
  const raw = info.releaseNotes
  if (typeof raw === 'string') {
    const trimmed = raw.trim()
    return trimmed === '' ? null : trimmed.slice(0, MAX_NOTES_LENGTH)
  }
  if (Array.isArray(raw)) {
    const joined = raw
      .map((entry) => (typeof entry?.note === 'string' ? entry.note.trim() : ''))
      .filter((note) => note !== '')
      .join('\n\n')
    return joined === '' ? null : joined.slice(0, MAX_NOTES_LENGTH)
  }
  return null
}

/**
 * How many bytes the download will actually be, or null.
 *
 * The zip is chosen, not the first file, because the zip is what gets
 * downloaded on macOS — `electron-builder.yml` ships a dmg beside it and says
 * so in its own comment: "A DMG cannot be applied as an update". Showing the
 * dmg's size next to a progress bar measuring the zip would be a number that
 * never matches what the bar does.
 *
 * `files` is typed as required, but it arrives over the network from a YAML
 * file this app did not write, so it is guarded. A feed with no size is
 * reported as no size — a made-up figure would be worse than a missing one.
 */
export function readSizeBytes(info: UpdateInfo): number | null {
  const files = Array.isArray(info.files) ? info.files : []
  const zip = files.find((file) => typeof file?.url === 'string' && file.url.toLowerCase().endsWith('.zip'))
  const chosen = zip ?? files[0]
  const size = chosen?.size
  return typeof size === 'number' && Number.isFinite(size) && size > 0 ? size : null
}

/* ----------------------------------------------------------- scheduling -- */

/**
 * How long after launch the first check waits.
 *
 * Long enough to be out of the startup path entirely — the window, the restored
 * sessions, the tool probes and the readiness scan all land in the first few
 * seconds, and an HTTPS round trip competing with them is a slower launch for
 * something nobody is waiting on.
 */
export const LAUNCH_DELAY_MS = 20_000

/**
 * What replaced the recurring check, and why there is no longer an interval.
 *
 * The old arrangement was a 6-hour `setInterval` that ran for as long as the
 * app did, whether or not anybody was using it. The thing it was really trying
 * to approximate is "has a release appeared since this user last paid
 * attention", and Electron reports the second half of that directly: a window
 * coming to the front is the moment a new version becomes worth knowing about,
 * and it is also the only moment the user could act on one.
 *
 * So the checks are now: once on launch, and whenever the app is brought
 * forward — both real events, neither of them a clock. A machine left running
 * over a weekend with the app in the background makes no requests at all, and
 * the first thing that happens when its owner comes back is a check, rather
 * than the panel showing whatever the last tick found some hours ago.
 *
 * {@link MIN_AUTOMATIC_INTERVAL_MS} is what makes this safe: focus is a cheap
 * event and a user alt-tabbing between two windows would otherwise hammer
 * someone else's API. It was already there for the timers, and it does the
 * whole job here.
 */
export const RECHECK_TRIGGER = 'browser-window-focus'

/**
 * The floor no *automatic* check may go below, whatever the timers do.
 *
 * The interval alone would be enough if it were the only caller, but timers get
 * re-armed and `start()` can be called more than once during a restart, and the
 * thing being hammered is someone else's API. A user pressing "Check now" is
 * not rate limited: they can see the result, they asked for it, and a button
 * that quietly declines to do its job is the dead click this project's own
 * rules forbid.
 */
export const MIN_AUTOMATIC_INTERVAL_MS = 60 * 60 * 1000

/* --------------------------------------------------------------- control -- */

/**
 * A stable identity for a state, used to decide whether to push it.
 *
 * The renderer is told about changes, not about ticks.
 *
 * `bytesPerSecond` is deliberately **not** part of the identity. It is a
 * running average — `transferred / elapsed`, recomputed on every tick by
 * `builder-util-runtime`'s `ProgressCallbackTransform` — so it lands on a
 * different integer nearly every time. Including it made the comparison
 * always-true and the throttle inert. Leaving it out is what makes the promise
 * this comment makes actually hold: at most one message per visible percentage
 * point, carrying the rate measured at the moment that percent was reached.
 *
 * The stream being collapsed is smaller than it sounds: that same transform
 * throttles itself to one callback per 1000 ms (`nextUpdate = now + 1000`), so
 * on a fast connection the percent has usually moved anyway and this changes
 * nothing. It matters on a slow one, which is exactly when a user is watching.
 */
function signature(state: UpdateState): string {
  switch (state.phase) {
    case 'idle':
      return `idle:${state.checkedAt ?? ''}`
    case 'checking':
      return 'checking'
    case 'available':
      return `available:${state.version}:${state.sizeBytes ?? ''}:${state.notes ?? ''}`
    case 'downloading':
      return `downloading:${state.version}:${state.percent}`
    case 'ready':
      return `ready:${state.version}`
    case 'error':
      return `error:${state.message}`
    case 'unsupported':
      return `unsupported:${state.reason}`
  }
}

function messageOf(error: unknown): string {
  if (error instanceof Error && error.message.trim() !== '') return error.message.trim()
  const text = String(error).trim()
  return text === '' ? 'The update check failed for an unknown reason.' : text
}

export interface UpdateController {
  /** The current state. Never throws. */
  state(): UpdateState
  /**
   * Check now. `automatic` checks obey {@link MIN_AUTOMATIC_INTERVAL_MS} and
   * stand down while a download is running; a user-initiated check does not.
   */
  check(options?: { automatic?: boolean }): Promise<UpdateState>
  /** Begin downloading the update the user was shown. */
  download(): Promise<UpdateState>
  /** Install what is already staged. The only caller of quitAndInstall. */
  installNow(): Promise<UpdateState>
  /** Arm the launch check and subscribe to {@link RECHECK_TRIGGER}. Returns immediately. */
  start(): void
  /** Disarm the launch check and drop the subscription. Call from `before-quit`. */
  stop(): void
}

/**
 * Build the controller.
 *
 * Listeners are attached once, here, and every transition in the module goes
 * through `set()` so there is exactly one place that both records the state and
 * pushes it. An unsupported build attaches nothing at all: there is no emitter
 * traffic to react to when no check will ever be started.
 */
export function createUpdateController(deps: UpdaterDeps): UpdateController {
  const { updater, environment, broadcast } = deps
  // `existsSync` is the only thing this module reads off the disk, and a test
  // that supplies its own `fileExists` never reaches it.
  const fileExists = deps.fileExists ?? existsSync
  const now = deps.now ?? (() => Date.now())

  const verdict = updateSupport(environment, fileExists)

  // A build Squirrel refuses is still updatable when a manual strategy is
  // supplied — that is the whole point of the seam. The verdict only stands
  // when there is no other way in.
  const manual = deps.manual ?? null
  const usable = verdict.supported || manual !== null

  let current: UpdateState = usable
    ? { phase: 'idle', checkedAt: null }
    : { phase: 'unsupported', reason: verdict.reason }

  /**
   * The live state, read through a call rather than through the binding.
   *
   * The emitter moves `current` from inside `checkForUpdates` and
   * `downloadUpdate`, so a narrowing TypeScript performed before an `await`
   * does not survive it in fact — only in the compiler's model, which assumes
   * a closure variable it cannot see assigned stays put. Reading through a
   * function gets the full union back every time, which is both true and what
   * makes the post-await checks below type-check honestly instead of being
   * silenced.
   */
  const read = (): UpdateState => current

  let lastSignature = signature(current)
  let lastCheckStartedAt = 0
  let launchTimer: ReturnType<typeof setTimeout> | null = null
  let unfocus: (() => void) | null = null

  /** The version the panel is currently talking about, for phases that need it. */
  let pendingVersion: string | null = null

  function set(next: UpdateState): UpdateState {
    current = next
    const nextSignature = signature(next)
    if (nextSignature !== lastSignature) {
      lastSignature = nextSignature
      broadcast(UPDATE_STATE_CHANNEL, next)
    }
    return current
  }

  if (verdict.supported) {
    // The two flags that are the whole "never behind your back" contract.
    updater.autoDownload = false
    updater.autoInstallOnAppQuit = true

    updater.on('checking-for-update', () => {
      set({ phase: 'checking' })
    })

    updater.on('update-available', (info) => {
      pendingVersion = info.version
      set({
        phase: 'available',
        version: info.version,
        notes: readNotes(info),
        sizeBytes: readSizeBytes(info),
      })
    })

    updater.on('update-not-available', () => {
      pendingVersion = null
      set({ phase: 'idle', checkedAt: now() })
    })

    updater.on('download-progress', (progress) => {
      // Rounded here rather than in the renderer so that `signature()` can use
      // it to throttle, and so two clients cannot disagree about the number.
      //
      // Both numbers are checked for finiteness first, and that is not
      // paranoia about the type: `percent` is computed from a Content-Length
      // the server may not have sent, so it arrives as NaN from a real feed,
      // and `Math.max(0, Math.min(100, Math.round(NaN)))` is still NaN. That is
      // exactly how "NaN%" gets onto a progress bar that looks like it clamps.
      const percent = Number.isFinite(progress.percent)
        ? Math.max(0, Math.min(100, Math.round(progress.percent)))
        : 0
      const rate = Number.isFinite(progress.bytesPerSecond)
        ? Math.max(0, Math.round(progress.bytesPerSecond))
        : 0
      set({
        phase: 'downloading',
        version: pendingVersion ?? '',
        percent,
        bytesPerSecond: rate,
      })
    })

    updater.on('update-downloaded', (event) => {
      pendingVersion = event.version
      set({ phase: 'ready', version: event.version })
    })

    // electron-updater reports failures through this event as well as through
    // the promise, and the two do not always both fire. Handling it here is
    // what keeps a background check — whose promise nobody is awaiting — from
    // leaving the panel stuck on "checking" forever.
    updater.on('error', (error) => {
      // An error *event* arriving after the bytes are staged does not un-stage
      // them, so it does not replace `ready`.
      //
      // This rule is narrower than it looks, and the narrowness is the point.
      // It covers only failures that arrive with no `downloadUpdate()` promise
      // still in flight — a nativeUpdater error raised later, during the
      // install on quit. A failure that arrives *through* the promise is
      // handled by `download()` below and does replace `ready`, on purpose:
      // MacUpdater rejects that promise when Squirrel refused the staged
      // bytes, and an update Squirrel refused cannot be installed. Showing
      // "Restart to update" then would be a button that quietly does nothing —
      // `MacUpdater.quitAndInstall()` with `squirrelDownloadedUpdate === false`
      // attaches a listener and returns without quitting. Both paths are
      // pinned by tests; if you change one, change the other.
      if (read().phase === 'ready') return
      set({ phase: 'error', message: messageOf(error) })
    })
  }

  async function check(options?: { automatic?: boolean }): Promise<UpdateState> {
    if (manualInUse()) {
      // Squirrel is not involved, so neither is its feed handling: the release
      // manifest is public and `fetch-update` already parses it.
      if (read().phase === 'downloading') return read()
      set({ phase: 'checking' })
      try {
        const found = await (manual as ManualStrategy).check()
        return found === null
          ? set({ phase: 'idle', checkedAt: now() })
          : set({ phase: 'available', version: found.version, notes: found.notes, sizeBytes: found.sizeBytes })
      } catch (error) {
        return set({ phase: 'error', message: messageOf(error) })
      }
    }

    const before = read()
    if (before.phase === 'unsupported') return before

    const automatic = options?.automatic === true

    // Never interrupt a download or a staged update with a check. Doing so
    // would replace a progress bar the user is watching with "checking".
    if (before.phase === 'downloading' || before.phase === 'ready' || before.phase === 'checking') {
      return before
    }
    if (automatic && lastCheckStartedAt !== 0 && now() - lastCheckStartedAt < MIN_AUTOMATIC_INTERVAL_MS) {
      return before
    }

    lastCheckStartedAt = now()
    // Set here rather than waiting for `checking-for-update`: the emitter fires
    // that event from inside `checkForUpdates`, but a check that throws before
    // reaching it would otherwise leave the panel on its previous state with no
    // sign anything was attempted.
    set({ phase: 'checking' })

    try {
      await updater.checkForUpdates()
    } catch (error) {
      // A failed check is a sentence, not a crash. This is the whole reason
      // `check` returns a state instead of rejecting: it is called from a
      // timer with nobody to catch it.
      return set({ phase: 'error', message: messageOf(error) })
    }

    // The events above have already moved the state to available or idle. If
    // they somehow did not — an updater that resolves without emitting — say
    // the check finished rather than sitting on "checking" forever.
    const after = read()
    if (after.phase === 'checking') return set({ phase: 'idle', checkedAt: now() })
    return after
  }

  /** True when Squirrel is refused and the manual path is doing the work. */
  const manualInUse = (): boolean => manual !== null && !verdict.supported

  async function download(): Promise<UpdateState> {
    if (manualInUse()) {
      const offered = read()
      if (offered.phase !== 'available') return offered
      const version = offered.version
      set({ phase: 'downloading', version, percent: 0, bytesPerSecond: 0 })
      const done = await (manual as ManualStrategy).download(version, (percent, bytesPerSecond) => {
        // Only while this download is still the current one: a check that
        // superseded it must not be overwritten by a late progress event.
        const now = read()
        if (now.phase === 'downloading' && now.version === version) {
          set({ phase: 'downloading', version, percent, bytesPerSecond })
        }
      })
      return done.ok ? set({ phase: 'ready', version }) : set({ phase: 'error', message: done.message })
    }

    // Only from `available`. The panel only offers the button in that phase, so
    // reaching here otherwise is a double click or a stale renderer, and
    // `downloadUpdate()` with nothing to download rejects.
    const offered = read()
    if (offered.phase !== 'available') return offered

    const version = offered.version
    pendingVersion = version
    set({ phase: 'downloading', version, percent: 0, bytesPerSecond: 0 })

    try {
      await updater.downloadUpdate()
    } catch (error) {
      // This wins even when `update-downloaded` has already set `ready`. On
      // macOS the promise settles late by design — `MacUpdater` fires
      // `update-downloaded` first and only resolves once Squirrel has fetched
      // the file through its local proxy — so a rejection here means Squirrel
      // refused the staged bytes, and there is nothing to restart into.
      return set({ phase: 'error', message: messageOf(error) })
    }

    // `update-downloaded` normally lands first and has already set `ready`.
    // Reaching here still downloading means the promise resolved without the
    // event, and a resolved `downloadUpdate()` means the bytes are on disk.
    const after = read()
    if (after.phase === 'downloading') return set({ phase: 'ready', version })
    return after
  }

  async function installNow(): Promise<UpdateState> {
    // The only call to quitAndInstall in this module, and it is unreachable
    // except from a user who pressed a button on a staged update.
    const staged = read()
    if (staged.phase !== 'ready') return staged
    if (manualInUse()) {
      // The swap quits this process itself, so a resolved failure is the only
      // thing that can come back here — a success never returns.
      const done = await (manual as ManualStrategy).install(staged.version)
      return done.ok ? staged : set({ phase: 'error', message: done.message })
    }
    updater.quitAndInstall()
    return staged
  }

  function start(): void {
    // An unsupported build arms nothing. There is no timer, no subscription, no
    // request, and no way for a check to happen by accident.
    if (read().phase === 'unsupported') return
    if (launchTimer !== null || unfocus !== null) return

    launchTimer = setTimeout(() => {
      launchTimer = null
      void check({ automatic: true })
    }, LAUNCH_DELAY_MS)
    // The one timer here may not hold the process open — an update check is
    // never a reason for the app to refuse to exit.
    launchTimer.unref?.()

    // Everything after that first check is event-driven; see RECHECK_TRIGGER.
    unfocus = (deps.onFocus ?? appWindowFocus)(() => {
      void check({ automatic: true })
    })
  }

  function stop(): void {
    if (launchTimer !== null) {
      clearTimeout(launchTimer)
      launchTimer = null
    }
    if (unfocus !== null) {
      unfocus()
      unfocus = null
    }
  }

  return {
    state: () => current,
    check,
    download,
    installNow,
    start,
    stop,
  }
}

/* -------------------------------------------------------------------- ipc -- */

/**
 * Wire the update channels. Call once from `registerIpc()`.
 *
 * - `update:get`      → {@link UpdateState}, the current one
 * - `update:check`    → {@link UpdateState} after a check (never rejects)
 * - `update:download` → {@link UpdateState}, download started
 * - `update:install`  → {@link UpdateState}; quits and installs when staged
 *
 * and pushes {@link UPDATE_STATE_CHANNEL} at the renderer on every change, so
 * the panel subscribes once and never polls.
 *
 * `update:get` is a separate channel from the push on purpose: `update:state`
 * is main → renderer only, and giving a request and an event the same name is
 * how a `handle`/`on` mix-up gets written next.
 */
export function registerUpdateIpc(ipcMain: IpcMain, deps: UpdaterDeps): UpdateController {
  const controller = createUpdateController(deps)

  ipcMain.handle('update:get', (): UpdateState => controller.state())
  // `automatic: false` — this channel is only reachable from a button press, so
  // it is never rate limited.
  ipcMain.handle('update:check', (): Promise<UpdateState> => controller.check({ automatic: false }))
  ipcMain.handle('update:download', (): Promise<UpdateState> => controller.download())
  ipcMain.handle('update:install', (): Promise<UpdateState> => controller.installNow())

  controller.start()
  return controller
}
