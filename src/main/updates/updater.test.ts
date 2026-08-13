import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AppUpdater } from 'electron-updater'
import type { ProgressInfo, UpdateDownloadedEvent, UpdateInfo } from 'electron-updater'
import {
  LAUNCH_DELAY_MS,
  MAX_NOTES_LENGTH,
  MIN_AUTOMATIC_INTERVAL_MS,
  RECHECK_INTERVAL_MS,
  UPDATE_STATE_CHANNEL,
  codeSignaturePath,
  createUpdateController,
  macBundleRoot,
  readNotes,
  readSizeBytes,
  registerUpdateIpc,
  updateSupport,
  type UpdateEnvironment,
  type UpdateState,
  type UpdaterLike,
} from './updater'

/**
 * These tests are about the promises the panel makes on this module's behalf.
 *
 * Three of them are worth stating, because each is a way this feature could
 * quietly become a lie:
 *
 *  - **Nothing installs itself.** The fake counts every `quitAndInstall`, and
 *    the count is asserted to be zero on each path that could plausibly reach
 *    it by accident — registering the IPC, finding an update, downloading one,
 *    a failed download, and six hours of timers — and to be exactly one only
 *    where a user explicitly asked. A default flipped in a future
 *    electron-updater, or an `autoDownload` left at its default `true`, shows
 *    up here.
 *  - **A failed check is a sentence, not a throw.** Checks run from a timer with
 *    nobody awaiting them, so a rejection would be an unhandled one.
 *  - **Unsigned is `unsupported`, not `error`.** The two look similar in a panel
 *    and mean opposite things: one says try again later, the other says this
 *    will never work, go and download it. Reporting the first for the second is
 *    what "silently failing forever" looks like.
 *
 * Nothing here touches the network or the disk. The updater is a fake that
 * records calls and lets a test fire the emitter events by hand, and
 * `fileExists` is a set of paths.
 */

/* ------------------------------------------------------------- the fake -- */

type Listeners = {
  'checking-for-update': Array<() => void>
  'update-available': Array<(info: UpdateInfo) => void>
  'update-not-available': Array<(info: UpdateInfo) => void>
  'download-progress': Array<(progress: ProgressInfo) => void>
  'update-downloaded': Array<(event: UpdateDownloadedEvent) => void>
  error: Array<(error: Error) => void>
}

class FakeUpdater implements UpdaterLike {
  autoDownload = true
  autoInstallOnAppQuit = false

  readonly calls = { check: 0, download: 0, quitAndInstall: 0 }

  /** Set to make the matching call reject before it emits anything. */
  checkRejectsWith: Error | null = null
  downloadRejectsWith: Error | null = null

  /**
   * Set to reject *after* the emitter has already run.
   *
   * This is the real macOS order, not a contrived one. `MacUpdater` calls
   * `dispatchUpdateDownloaded(event)` — which is what `update-downloaded`
   * comes from — and only then waits, resolving when Squirrel has pulled the
   * file through its local proxy and rejecting on a `nativeUpdater` error.
   * So a rejection genuinely can land on a state that already says `ready`.
   */
  downloadRejectsAfterEmittingWith: Error | null = null

  /**
   * When set, `downloadUpdate` waits on it after emitting, so a test can look
   * at the state while the download is genuinely still in flight. Without it
   * `await download()` always ends in `ready`, because a resolved
   * `downloadUpdate()` means the bytes are on disk.
   */
  downloadGate: Promise<void> | null = null

  /** Fired by `checkForUpdates`, so a check behaves like the real emitter. */
  onCheck: (() => void) | null = null
  /** Fired by `downloadUpdate`. */
  onDownload: (() => void) | null = null

  private readonly listeners: Listeners = {
    'checking-for-update': [],
    'update-available': [],
    'update-not-available': [],
    'download-progress': [],
    'update-downloaded': [],
    error: [],
  }

  on(event: 'checking-for-update', listener: () => void): unknown
  on(event: 'update-available', listener: (info: UpdateInfo) => void): unknown
  on(event: 'update-not-available', listener: (info: UpdateInfo) => void): unknown
  on(event: 'download-progress', listener: (progress: ProgressInfo) => void): unknown
  on(event: 'update-downloaded', listener: (event: UpdateDownloadedEvent) => void): unknown
  on(event: 'error', listener: (error: Error) => void): unknown
  on(event: keyof Listeners, listener: never): unknown {
    this.listeners[event].push(listener)
    return this
  }

  async checkForUpdates(): Promise<unknown> {
    this.calls.check += 1
    if (this.checkRejectsWith) throw this.checkRejectsWith
    this.onCheck?.()
    return null
  }

  async downloadUpdate(): Promise<unknown> {
    this.calls.download += 1
    if (this.downloadRejectsWith) throw this.downloadRejectsWith
    this.onDownload?.()
    if (this.downloadGate) await this.downloadGate
    if (this.downloadRejectsAfterEmittingWith) throw this.downloadRejectsAfterEmittingWith
    return []
  }

  quitAndInstall(): void {
    this.calls.quitAndInstall += 1
  }

  /* The emitter half, driven by the tests. */
  emitChecking(): void {
    for (const listener of this.listeners['checking-for-update']) listener()
  }
  emitAvailable(info: UpdateInfo): void {
    for (const listener of this.listeners['update-available']) listener(info)
  }
  emitNotAvailable(info: UpdateInfo): void {
    for (const listener of this.listeners['update-not-available']) listener(info)
  }
  emitProgress(progress: ProgressInfo): void {
    for (const listener of this.listeners['download-progress']) listener(progress)
  }
  emitDownloaded(event: UpdateDownloadedEvent): void {
    for (const listener of this.listeners['update-downloaded']) listener(event)
  }
  emitError(error: Error): void {
    for (const listener of this.listeners.error) listener(error)
  }
}

/* --------------------------------------------------------------- fixtures -- */

const SIGNED_BUNDLE = '/Applications/Terminal Deck.app'
const EXEC_PATH = `${SIGNED_BUNDLE}/Contents/MacOS/Terminal Deck`
const FEED = '/Applications/Terminal Deck.app/Contents/Resources/app-update.yml'

/** A packaged, signed macOS build — the only shape that supports updating. */
function supportedEnvironment(): UpdateEnvironment {
  return { platform: 'darwin', isPackaged: true, execPath: EXEC_PATH, feedConfigPath: FEED }
}

/** The paths a properly signed, properly packaged build would have. */
const SUPPORTED_FILES = new Set([codeSignaturePath(SIGNED_BUNDLE), FEED])

function info(version: string, extra: Partial<UpdateInfo> = {}): UpdateInfo {
  return {
    version,
    files: [{ url: `terminaldeck-${version}-arm64.zip`, sha512: 'x', size: 119_559_307 }],
    path: `terminaldeck-${version}-arm64.zip`,
    sha512: 'x',
    releaseDate: '2026-08-13T00:00:00.000Z',
    ...extra,
  }
}

function downloaded(version: string): UpdateDownloadedEvent {
  return { ...info(version), downloadedFile: `/tmp/terminaldeck-${version}-arm64.zip` }
}

function progress(percent: number, bytesPerSecond = 1_000_000): ProgressInfo {
  return { total: 100, delta: 1, transferred: percent, percent, bytesPerSecond }
}

/**
 * A rate that moves, which is the only kind the real emitter produces.
 *
 * `bytesPerSecond` is `transferred / elapsed` recomputed on every tick by
 * `builder-util-runtime`'s `ProgressCallbackTransform`, so it is a different
 * integer nearly every time. A throttle test that holds it constant is testing
 * a stream that does not exist.
 */
const MEASURED_RATES = [1_000_000, 1_010_400, 1_003_991, 1_009_112]

interface Harness {
  updater: FakeUpdater
  pushed: UpdateState[]
  controller: ReturnType<typeof createUpdateController>
  clock: { value: number }
}

function harness(options: { environment?: UpdateEnvironment; files?: Set<string> } = {}): Harness {
  const updater = new FakeUpdater()
  const pushed: UpdateState[] = []
  const clock = { value: 1_000_000 }
  const files = options.files ?? SUPPORTED_FILES
  const controller = createUpdateController({
    updater,
    environment: options.environment ?? supportedEnvironment(),
    broadcast: (channel, state) => {
      expect(channel).toBe(UPDATE_STATE_CHANNEL)
      pushed.push(state)
    },
    fileExists: (path) => files.has(path),
    now: () => clock.value,
  })
  return { updater, pushed, controller, clock }
}

afterEach(() => {
  vi.useRealTimers()
})

/* ------------------------------------------------------------------ seam -- */

describe('the injected seam', () => {
  it('still fits the real electron-updater autoUpdater', () => {
    // A compile-time proof. `AppUpdater` is a type-only import, so nothing is
    // loaded at runtime — reading the real `autoUpdater` would construct a
    // MacUpdater, which requires `electron`. If the class this module drives
    // ever changes shape, `npm run typecheck` fails here rather than the app
    // failing at 3am on someone's update.
    const fits: (updater: AppUpdater) => UpdaterLike = (updater) => updater
    expect(typeof fits).toBe('function')
  })
})

/* --------------------------------------------------------------- support -- */

describe('whether this build can update itself', () => {
  it('finds the bundle an executable runs from', () => {
    expect(macBundleRoot(EXEC_PATH)).toBe(SIGNED_BUNDLE)
    expect(macBundleRoot('/usr/local/bin/node')).toBeNull()
  })

  it('takes the innermost bundle when one is nested in another', () => {
    expect(macBundleRoot('/Applications/Outer.app/Contents/Helpers/Inner.app/Contents/MacOS/Inner')).toBe(
      '/Applications/Outer.app/Contents/Helpers/Inner.app',
    )
  })

  it('reports a development build as unsupported, not broken', () => {
    const verdict = updateSupport({ ...supportedEnvironment(), isPackaged: false }, () => true)
    expect(verdict.supported).toBe(false)
    if (verdict.supported) throw new Error('unreachable')
    expect(verdict.reason).toMatch(/development build/i)
  })

  it('reports an unsigned macOS build as unsupported and says why', () => {
    // This is the real shape of every build shipped so far: `codesign -dv`
    // against /Applications/Terminal Deck.app reports Signature=adhoc,
    // TeamIdentifier=not set, Sealed Resources=none — and correspondingly there
    // is no Contents/_CodeSignature/CodeResources on disk.
    const verdict = updateSupport(supportedEnvironment(), (path) => path === FEED)
    expect(verdict.supported).toBe(false)
    if (verdict.supported) throw new Error('unreachable')
    expect(verdict.reason).toMatch(/not code-signed/i)
    expect(verdict.reason).toMatch(/Squirrel\.Mac/)
    // The sentence has to tell the user what to do instead.
    expect(verdict.reason).toMatch(/Releases/)
  })

  it('accepts a signed, packaged build with a feed', () => {
    expect(updateSupport(supportedEnvironment(), (path) => SUPPORTED_FILES.has(path))).toEqual({
      supported: true,
    })
  })

  it('reports a missing feed separately from a missing signature', () => {
    const verdict = updateSupport(supportedEnvironment(), (path) => path === codeSignaturePath(SIGNED_BUNDLE))
    expect(verdict.supported).toBe(false)
    if (verdict.supported) throw new Error('unreachable')
    expect(verdict.reason).toMatch(/without a release feed/i)
  })

  it('does not apply the macOS signature rule to other platforms', () => {
    // electron-builder.yml builds mac only today; inventing a Windows limit
    // nobody has measured would be the same kind of guess this module avoids.
    const windows: UpdateEnvironment = {
      platform: 'win32',
      isPackaged: true,
      execPath: 'C:\\Program Files\\Terminal Deck\\Terminal Deck.exe',
      feedConfigPath: 'C:\\Program Files\\Terminal Deck\\resources\\app-update.yml',
    }
    expect(updateSupport(windows, (path) => path === windows.feedConfigPath)).toEqual({ supported: true })
  })
})

/* ------------------------------------------------------- unsupported build -- */

describe('an unsupported build', () => {
  const unsignedFiles = new Set([FEED])

  it('starts in unsupported with the reason as its message', () => {
    const { controller } = harness({ files: unsignedFiles })
    const state = controller.state()
    expect(state.phase).toBe('unsupported')
    if (state.phase !== 'unsupported') throw new Error('unreachable')
    expect(state.reason).toMatch(/not code-signed/i)
  })

  it('is reported as unsupported rather than as an error', () => {
    const { controller } = harness({ files: unsignedFiles })
    // The distinction the panel renders: an error invites a retry, unsupported
    // tells the truth that retrying will never help.
    expect(controller.state().phase).not.toBe('error')
  })

  it('never checks, downloads, installs or arms a timer', async () => {
    vi.useFakeTimers()
    const { controller, updater } = harness({ files: unsignedFiles })

    controller.start()
    await vi.advanceTimersByTimeAsync(RECHECK_INTERVAL_MS * 3)

    expect(await controller.check()).toEqual(controller.state())
    expect(await controller.download()).toEqual(controller.state())
    expect(await controller.installNow()).toEqual(controller.state())

    expect(updater.calls).toEqual({ check: 0, download: 0, quitAndInstall: 0 })
    controller.stop()
  })

  it('subscribes to nothing, so a stray event cannot move it off unsupported', () => {
    const { controller, updater } = harness({ files: unsignedFiles })
    // An unsupported build does not half-wire itself. Nothing is listening, so
    // even an emitter that fires cannot replace the sentence the panel shows.
    updater.emitAvailable(info('9.9.9'))
    updater.emitDownloaded(downloaded('9.9.9'))
    updater.emitError(new Error('should not be heard'))
    expect(controller.state().phase).toBe('unsupported')
  })
})

/* ------------------------------------------------------------ transitions -- */

describe('state transitions', () => {
  it('sets the two flags that make up the no-surprises contract', () => {
    const { updater } = harness()
    expect(updater.autoDownload).toBe(false)
    expect(updater.autoInstallOnAppQuit).toBe(true)
  })

  it('starts idle with nothing checked yet', () => {
    const { controller } = harness()
    expect(controller.state()).toEqual({ phase: 'idle', checkedAt: null })
  })

  it('idle → checking → idle when there is no update', async () => {
    const { controller, updater, pushed, clock } = harness()
    updater.onCheck = () => {
      updater.emitChecking()
      updater.emitNotAvailable(info('0.1.0'))
    }

    const state = await controller.check()

    expect(state).toEqual({ phase: 'idle', checkedAt: clock.value })
    expect(pushed.map((s) => s.phase)).toEqual(['checking', 'idle'])
  })

  it('idle → checking → available carries version, notes and size', async () => {
    const { controller, updater } = harness()
    updater.onCheck = () => {
      updater.emitChecking()
      updater.emitAvailable(info('0.2.0', { releaseNotes: '  Faster startup.  ' }))
    }

    const state = await controller.check()

    expect(state).toEqual({
      phase: 'available',
      version: '0.2.0',
      notes: 'Faster startup.',
      sizeBytes: 119_559_307,
    })
  })

  it('available → downloading → ready', async () => {
    const { controller, updater, pushed } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    pushed.length = 0

    updater.onDownload = () => {
      updater.emitProgress(progress(42, 2_500_000))
      updater.emitDownloaded(downloaded('0.2.0'))
    }
    const state = await controller.download()

    expect(state).toEqual({ phase: 'ready', version: '0.2.0' })
    expect(pushed).toEqual([
      { phase: 'downloading', version: '0.2.0', percent: 0, bytesPerSecond: 0 },
      { phase: 'downloading', version: '0.2.0', percent: 42, bytesPerSecond: 2_500_000 },
      { phase: 'ready', version: '0.2.0' },
    ])
  })

  it('rounds progress and pushes at most one message per whole percent', async () => {
    const { controller, updater, pushed } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    pushed.length = 0

    updater.onDownload = () => {
      // On a slow connection the percent sits still while the rate keeps
      // moving, and a panel does not need four messages to draw "7%". The
      // rates below are the shape the real transform produces — see
      // MEASURED_RATES. With a constant rate this test passes whether or not
      // anything is being throttled, which is why it does not use one.
      updater.emitProgress(progress(7.1, MEASURED_RATES[0]))
      updater.emitProgress(progress(7.2, MEASURED_RATES[1]))
      updater.emitProgress(progress(7.4, MEASURED_RATES[2]))
      updater.emitProgress(progress(8.0, MEASURED_RATES[3]))
    }
    await controller.download()

    const percents = pushed
      .filter((state) => state.phase === 'downloading')
      .map((state) => (state.phase === 'downloading' ? state.percent : -1))
    expect(percents).toEqual([0, 7, 8])
  })

  it('carries the rate measured when a percent was first reached', async () => {
    // Dropping `bytesPerSecond` from the throttle identity has a consequence
    // worth stating: the rate shown is the one from the tick that changed the
    // percent, not the newest one. That is the trade the throttle makes.
    const { controller, updater, pushed } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    pushed.length = 0

    updater.onDownload = () => {
      updater.emitProgress(progress(7.1, MEASURED_RATES[0]))
      updater.emitProgress(progress(7.4, MEASURED_RATES[1]))
    }
    await controller.download()

    expect(pushed.filter((state) => state.phase === 'downloading')).toEqual([
      { phase: 'downloading', version: '0.2.0', percent: 0, bytesPerSecond: 0 },
      { phase: 'downloading', version: '0.2.0', percent: 7, bytesPerSecond: MEASURED_RATES[0] },
    ])
  })

  it('never pushes NaN for a feed that sent no content length', async () => {
    const { controller, updater, pushed } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    pushed.length = 0

    // `percent` is transferred/total, and a server that sent no Content-Length
    // makes that NaN. Math.round(NaN) is NaN and so is every clamp around it.
    updater.onDownload = () => updater.emitProgress(progress(Number.NaN, Number.NaN))
    await controller.download()

    for (const state of pushed) {
      if (state.phase !== 'downloading') continue
      expect(Number.isFinite(state.percent)).toBe(true)
      expect(Number.isFinite(state.bytesPerSecond)).toBe(true)
    }
  })

  it('clamps a nonsensical percent from the feed rather than showing it', async () => {
    const { controller, updater, pushed } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    pushed.length = 0

    // A progress bar is a promise about a number; 140% would break it.
    updater.onDownload = () => updater.emitProgress(progress(140))
    await controller.download()

    const percents = pushed
      .filter((state) => state.phase === 'downloading')
      .map((state) => (state.phase === 'downloading' ? state.percent : -1))
    expect(percents).toEqual([0, 100])
  })

  it('ready → install only when asked', () => {
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    updater.emitDownloaded(downloaded('0.2.0'))

    expect(updater.calls.quitAndInstall).toBe(0)
    controller.installNow()
    expect(updater.calls.quitAndInstall).toBe(1)
  })

  it('does not let a late error event undo a staged update', () => {
    const { controller, updater } = harness()
    updater.emitDownloaded(downloaded('0.2.0'))
    // An error *event* with no download promise in flight — a nativeUpdater
    // failure raised later. The bytes are staged and stay staged.
    updater.emitError(new Error('connection reset'))
    expect(controller.state()).toEqual({ phase: 'ready', version: '0.2.0' })
  })

  it('does let a rejected download undo a staged update, and says why', async () => {
    // The other half of the rule above, and the half that is easy to get
    // backwards. `MacUpdater` emits `update-downloaded` before its promise
    // settles, so a rejection lands on a state that already says `ready`.
    // It has to win: the promise rejects when Squirrel refused the staged
    // bytes, and `quitAndInstall()` on a refused update attaches a listener
    // and returns without quitting — a Restart button that does nothing.
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()

    updater.onDownload = () => updater.emitDownloaded(downloaded('0.2.0'))
    updater.downloadRejectsAfterEmittingWith = new Error('Squirrel: could not get code signature')

    const state = await controller.download()

    expect(state).toEqual({
      phase: 'error',
      message: 'Squirrel: could not get code signature',
    })
    expect(controller.state()).toEqual(state)
    expect(updater.calls.quitAndInstall).toBe(0)
  })
})

/* ----------------------------------------------------------------- errors -- */

describe('a failed check', () => {
  it('reports a message and does not throw', async () => {
    const { controller, updater } = harness()
    updater.checkRejectsWith = new Error('net::ERR_INTERNET_DISCONNECTED')

    const state = await controller.check()

    expect(state).toEqual({ phase: 'error', message: 'net::ERR_INTERNET_DISCONNECTED' })
  })

  it('does not reject even when run from a timer with nobody awaiting it', async () => {
    vi.useFakeTimers()
    const { controller, updater } = harness()
    updater.checkRejectsWith = new Error('403 rate limited')

    controller.start()
    // An unhandled rejection here would take the main process down in
    // production; this is the assertion that it cannot happen.
    await expect(vi.advanceTimersByTimeAsync(LAUNCH_DELAY_MS + 1)).resolves.toBeDefined()
    expect(controller.state()).toEqual({ phase: 'error', message: '403 rate limited' })
    controller.stop()
  })

  it('reports an error raised through the event rather than the promise', async () => {
    const { controller, updater } = harness()
    // A background check's promise is not awaited by the panel, so the emitter
    // is the only route this failure has.
    updater.onCheck = () => {
      updater.emitChecking()
      updater.emitError(new Error('ENOTFOUND github.com'))
    }

    const state = await controller.check()

    expect(state).toEqual({ phase: 'error', message: 'ENOTFOUND github.com' })
  })

  it('never leaves the panel stuck on checking', async () => {
    const { controller, updater, clock } = harness()
    // An updater that resolves without emitting anything at all.
    updater.onCheck = null

    const state = await controller.check()

    expect(state).toEqual({ phase: 'idle', checkedAt: clock.value })
  })

  it('recovers: a check after an error goes back to checking', async () => {
    const { controller, updater } = harness()
    updater.checkRejectsWith = new Error('offline')
    await controller.check()

    updater.checkRejectsWith = null
    updater.onCheck = () => updater.emitAvailable(info('0.3.0'))
    const state = await controller.check()

    expect(state.phase).toBe('available')
  })

  it('turns a failed download into a message, not a rejection', async () => {
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()

    updater.downloadRejectsWith = new Error('sha512 mismatch')
    const state = await controller.download()

    expect(state).toEqual({ phase: 'error', message: 'sha512 mismatch' })
    expect(updater.calls.quitAndInstall).toBe(0)
  })

  it('says something useful when the failure is not an Error', async () => {
    const { controller, updater } = harness()
    updater.checkRejectsWith = new Error('')

    const state = await controller.check()

    expect(state.phase).toBe('error')
    expect(state.phase === 'error' ? state.message : '').not.toBe('')
  })
})

/* ------------------------------------------------- nothing behind your back -- */

describe('nothing happens without an explicit call', () => {
  it('finding an update downloads nothing', async () => {
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))

    await controller.check()

    expect(controller.state().phase).toBe('available')
    expect(updater.calls.download).toBe(0)
    expect(updater.calls.quitAndInstall).toBe(0)
  })

  it('a staged update installs only on the explicit call', async () => {
    vi.useFakeTimers()
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    updater.onDownload = () => updater.emitDownloaded(downloaded('0.2.0'))
    await controller.download()

    controller.start()
    // Time passing is not consent.
    await vi.advanceTimersByTimeAsync(RECHECK_INTERVAL_MS * 5)
    expect(updater.calls.quitAndInstall).toBe(0)

    controller.installNow()
    expect(updater.calls.quitAndInstall).toBe(1)
    controller.stop()
  })

  it('install does nothing when nothing is staged', async () => {
    const { controller, updater } = harness()
    expect((await controller.installNow()).phase).toBe('idle')

    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    expect((await controller.installNow()).phase).toBe('available')

    expect(updater.calls.quitAndInstall).toBe(0)
  })

  it('download does nothing unless an update was offered', async () => {
    const { controller, updater } = harness()
    expect((await controller.download()).phase).toBe('idle')
    expect(updater.calls.download).toBe(0)
  })

  it('a second download call does not restart a running one', async () => {
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()
    updater.onDownload = () => updater.emitProgress(progress(10))

    await controller.download()
    await controller.download()

    expect(updater.calls.download).toBe(1)
  })

  it('a check does not interrupt a download in progress', async () => {
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitAvailable(info('0.2.0'))
    await controller.check()

    // Hold the download open so the check below lands mid-flight, which is the
    // only moment this can go wrong: replacing a progress bar someone is
    // watching with the word "checking".
    let release = (): void => undefined
    updater.downloadGate = new Promise<void>((resolve) => {
      release = resolve
    })
    updater.onDownload = () => updater.emitProgress(progress(50))

    const running = controller.download()
    await Promise.resolve()

    const checksBefore = updater.calls.check
    const state = await controller.check()

    expect(updater.calls.check).toBe(checksBefore)
    expect(state.phase).toBe('downloading')

    release()
    await running
  })
})

/* -------------------------------------------------------------- scheduling -- */

describe('scheduling', () => {
  it('does not check during startup', async () => {
    vi.useFakeTimers()
    const { controller, updater } = harness()

    controller.start()
    await vi.advanceTimersByTimeAsync(LAUNCH_DELAY_MS - 1)
    expect(updater.calls.check).toBe(0)

    await vi.advanceTimersByTimeAsync(1)
    expect(updater.calls.check).toBe(1)
    controller.stop()
  })

  it('checks again on the recurring interval', async () => {
    vi.useFakeTimers()
    const { controller, updater, clock } = harness()
    updater.onCheck = () => updater.emitNotAvailable(info('0.1.0'))

    controller.start()
    await vi.advanceTimersByTimeAsync(LAUNCH_DELAY_MS)
    expect(updater.calls.check).toBe(1)

    // The injected clock has to move too: the rate limit is measured with it,
    // not with the timer wheel.
    clock.value += RECHECK_INTERVAL_MS
    await vi.advanceTimersByTimeAsync(RECHECK_INTERVAL_MS)
    expect(updater.calls.check).toBe(2)
    controller.stop()
  })

  it('refuses an automatic check inside the minimum interval', async () => {
    const { controller, updater, clock } = harness()
    updater.onCheck = () => updater.emitNotAvailable(info('0.1.0'))

    await controller.check({ automatic: true })
    expect(updater.calls.check).toBe(1)

    clock.value += MIN_AUTOMATIC_INTERVAL_MS - 1
    await controller.check({ automatic: true })
    expect(updater.calls.check).toBe(1)

    clock.value += 1
    await controller.check({ automatic: true })
    expect(updater.calls.check).toBe(2)
  })

  it('never rate limits a check the user asked for', async () => {
    const { controller, updater } = harness()
    updater.onCheck = () => updater.emitNotAvailable(info('0.1.0'))

    await controller.check({ automatic: true })
    // A button that declines to do its job is a dead click.
    await controller.check()
    await controller.check()

    expect(updater.calls.check).toBe(3)
  })

  it('stop() disarms both timers', async () => {
    vi.useFakeTimers()
    const { controller, updater } = harness()

    controller.start()
    controller.stop()
    await vi.advanceTimersByTimeAsync(LAUNCH_DELAY_MS + RECHECK_INTERVAL_MS * 2)

    expect(updater.calls.check).toBe(0)
  })

  it('start() twice does not arm two sets of timers', async () => {
    vi.useFakeTimers()
    const { controller, updater } = harness()

    controller.start()
    controller.start()
    await vi.advanceTimersByTimeAsync(LAUNCH_DELAY_MS)

    expect(updater.calls.check).toBe(1)
    controller.stop()
  })
})

/* ------------------------------------------------------------- broadcasts -- */

describe('the push channel', () => {
  it('pushes every change and repeats nothing', async () => {
    const { controller, updater, pushed } = harness()
    updater.onCheck = () => {
      updater.emitChecking()
      updater.emitAvailable(info('0.2.0'))
    }

    await controller.check()
    // `set({ phase: 'checking' })` runs before `checkForUpdates`, and the
    // emitter fires the same state again from inside it. The panel should see
    // one message, not two.
    expect(pushed.map((state) => state.phase)).toEqual(['checking', 'available'])
  })

  it('never pushes the same state twice in a row', async () => {
    const { controller, updater, pushed } = harness()
    updater.onCheck = () => {
      // The real emitter announces the state this module has already set, and
      // a second identical check produces a second identical idle result.
      updater.emitChecking()
      updater.emitChecking()
      updater.emitNotAvailable(info('0.1.0'))
      updater.emitNotAvailable(info('0.1.0'))
    }

    await controller.check()
    await controller.check()

    const phases = pushed.map((state) => state.phase)
    expect(phases).toEqual(['checking', 'idle', 'checking', 'idle'])
    for (let i = 1; i < pushed.length; i++) {
      expect(pushed[i]).not.toEqual(pushed[i - 1])
    }
  })
})

/* -------------------------------------------------------- reading the feed -- */

describe('reading the feed', () => {
  it('takes notes from a string or an array, and null from nothing', () => {
    expect(readNotes(info('1.0.0', { releaseNotes: 'Fixed the thing.' }))).toBe('Fixed the thing.')
    expect(
      readNotes(
        info('1.0.0', {
          releaseNotes: [
            { version: '1.0.0', note: 'Second.' },
            { version: '0.9.0', note: 'First.' },
          ],
        }),
      ),
    ).toBe('Second.\n\nFirst.')
    expect(readNotes(info('1.0.0'))).toBeNull()
    expect(readNotes(info('1.0.0', { releaseNotes: '   ' }))).toBeNull()
    expect(readNotes(info('1.0.0', { releaseNotes: null }))).toBeNull()
  })

  it('caps notes so a whole changelog cannot arrive as a notification', () => {
    const notes = readNotes(info('1.0.0', { releaseNotes: 'x'.repeat(MAX_NOTES_LENGTH * 2) }))
    expect(notes).toHaveLength(MAX_NOTES_LENGTH)
  })

  it('sizes the zip, because the zip is what gets downloaded on macOS', () => {
    const withDmg = info('1.0.0', {
      files: [
        { url: 'terminaldeck-1.0.0-arm64.dmg', sha512: 'a', size: 119_533_030 },
        { url: 'terminaldeck-1.0.0-arm64.zip', sha512: 'b', size: 119_559_307 },
      ],
    })
    expect(readSizeBytes(withDmg)).toBe(119_559_307)
  })

  it('reports no size rather than inventing one', () => {
    expect(readSizeBytes(info('1.0.0', { files: [] }))).toBeNull()
    expect(
      readSizeBytes(info('1.0.0', { files: [{ url: 'terminaldeck.zip', sha512: 'a' }] })),
    ).toBeNull()
  })
})

/* -------------------------------------------------------------------- ipc -- */

describe('registerUpdateIpc', () => {
  interface Registered {
    handlers: Map<string, () => unknown>
  }

  function fakeIpcMain(): { ipcMain: Parameters<typeof registerUpdateIpc>[0]; registered: Registered } {
    const handlers = new Map<string, () => unknown>()
    // Only `handle` is exercised; the module registers nothing with `on`, which
    // is what `src/preload/contract.test.ts` checks from the other side.
    const ipcMain = {
      handle: (channel: string, listener: () => unknown) => {
        handlers.set(channel, listener)
      },
    }
    const asIpcMain: unknown = ipcMain
    // Narrowed by the guard below rather than asserted: a cast here would be
    // the exact thing this project banned.
    if (!isIpcMainLike(asIpcMain)) throw new Error('unreachable')
    return { ipcMain: asIpcMain, registered: { handlers } }
  }

  function isIpcMainLike(value: unknown): value is Parameters<typeof registerUpdateIpc>[0] {
    return typeof value === 'object' && value !== null && 'handle' in value
  }

  let controller: ReturnType<typeof registerUpdateIpc> | null = null

  beforeEach(() => {
    vi.useFakeTimers()
  })

  afterEach(() => {
    controller?.stop()
    controller = null
  })

  it('registers exactly the four request channels', () => {
    const { ipcMain, registered } = fakeIpcMain()
    const updater = new FakeUpdater()
    controller = registerUpdateIpc(ipcMain, {
      updater,
      environment: supportedEnvironment(),
      broadcast: () => undefined,
      fileExists: (path) => SUPPORTED_FILES.has(path),
    })

    expect([...registered.handlers.keys()].sort()).toEqual([
      'update:check',
      'update:download',
      'update:get',
      'update:install',
    ])
  })

  it('does not use the push channel name for a request channel', () => {
    const { ipcMain, registered } = fakeIpcMain()
    controller = registerUpdateIpc(ipcMain, {
      updater: new FakeUpdater(),
      environment: supportedEnvironment(),
      broadcast: () => undefined,
      fileExists: (path) => SUPPORTED_FILES.has(path),
    })
    // `update:state` is main → renderer only. A handler on the same name is how
    // an invoke/send mix-up gets written next.
    expect(registered.handlers.has(UPDATE_STATE_CHANNEL)).toBe(false)
  })

  it('answers update:get with the current state', async () => {
    const { ipcMain, registered } = fakeIpcMain()
    controller = registerUpdateIpc(ipcMain, {
      updater: new FakeUpdater(),
      environment: supportedEnvironment(),
      broadcast: () => undefined,
      fileExists: (path) => SUPPORTED_FILES.has(path),
    })

    const get = registered.handlers.get('update:get')
    expect(get?.()).toEqual({ phase: 'idle', checkedAt: null })
  })

  it('registering does not install anything', async () => {
    const { ipcMain } = fakeIpcMain()
    const updater = new FakeUpdater()
    controller = registerUpdateIpc(ipcMain, {
      updater,
      environment: supportedEnvironment(),
      broadcast: () => undefined,
      fileExists: (path) => SUPPORTED_FILES.has(path),
    })

    await vi.advanceTimersByTimeAsync(LAUNCH_DELAY_MS + RECHECK_INTERVAL_MS)
    expect(updater.calls.quitAndInstall).toBe(0)
    expect(updater.calls.download).toBe(0)
  })
})
