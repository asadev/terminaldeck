/**
 * What the operating system will, and will not, tell this app about its own
 * notifications.
 *
 * ## The bug this module exists to stop repeating
 *
 * `Notification.permission` in an Electron renderer is **always `granted`**.
 * Chromium answers it out of its own permission model and never asks
 * `UNUserNotificationCenter`, so on macOS the whole chain reports success
 * whatever the OS thinks: the settings pane reads `granted`, the Test button
 * enables, the constructor returns, `onshow` fires — and macOS, whose
 * authorisation was still `notDetermined` because the prompt had never been
 * answered, drops the banner on the floor. Nothing anywhere says so.
 *
 * That is the shape of failure this product can least afford: every layer
 * reporting success while nothing happens. So this module is deliberately not
 * an attempt to *read* authorisation — Electron exposes no way to, and guessing
 * would only move the confident lie one layer down. It does two honest things
 * instead:
 *
 *  1. **Tell the user where the real switch is** — `notificationSettingsUrl`,
 *     per platform, and `null` where there is no such pane. Printing a macOS
 *     URL on Windows is a mistake this codebase has made in bulk before.
 *  2. **Ask the OS whether anything actually arrived** — `notificationDelivery`
 *     reads macOS's own notification store. A row for our bundle id, dated
 *     after the moment we posted, is macOS agreeing that it took delivery. No
 *     row is the drop, made visible.
 *
 * Every answer it cannot stand behind is `unknown`, and the copy for `unknown`
 * claims nothing. That is the point: an unreadable store degrades to "the app
 * cannot tell", never to "sent".
 *
 * ## Why a private Apple database, and why that is acceptable here
 *
 * `~/Library/Group Containers/group.com.apple.usernoted/db2/db` is where
 * Notification Center keeps what it is currently showing. It is not a public
 * API and its schema could change in any macOS release — which is exactly why
 * nothing depends on it: a failed read, a missing file, a renamed column and a
 * non-Apple platform all land in the same `unknown` branch that the UI already
 * has to handle. It is read strictly read-only (`sqlite3 -readonly`), and it is
 * only ever read in response to a button the user pressed.
 *
 * Measured on macOS 27: readable without Full Disk Access — a Terminal that
 * cannot open `TCC.db` opens this one fine. Rows disappear as banners expire,
 * so the read has to happen within seconds of posting, which it does.
 *
 * Wiring:
 *
 *     import { registerNotificationIpc } from './os-notifications'
 *     registerNotificationIpc(ipcMain)
 */

import { execFile } from 'node:child_process'
import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
import { app, shell, type IpcMain, type IpcMainInvokeEvent } from 'electron'

const run = promisify(execFile)

/* ------------------------------------------------------- the OS settings -- */

/**
 * The deep link to the pane that holds the real switch, or `null` where the
 * platform has no such thing.
 *
 * `null` is a first-class answer, not a fallback: the renderer draws no button
 * when there is nowhere to send the user, which is the only correct behaviour
 * on Linux and the only way to avoid quoting a macOS URL at a Windows user.
 */
export function notificationSettingsUrl(platform: NodeJS.Platform = process.platform): string | null {
  if (platform === 'darwin') return 'x-apple.systempreferences:com.apple.Notifications-Settings.extension'
  if (platform === 'win32') return 'ms-settings:notifications'
  return null
}

export interface OpenSettingsResult {
  opened: boolean
  /** Present only on failure, so the renderer can say what went wrong. */
  message?: string
}

/** Open that pane. Never throws — a failed escape hatch still has to say so. */
export async function openNotificationSettings(
  platform: NodeJS.Platform = process.platform,
): Promise<OpenSettingsResult> {
  const url = notificationSettingsUrl(platform)
  if (!url) return { opened: false, message: 'This system has no notification settings page to open.' }
  try {
    await shell.openExternal(url)
    return { opened: true }
  } catch (cause) {
    const detail = cause instanceof Error ? cause.message : String(cause)
    return { opened: false, message: `The settings page would not open: ${detail}` }
  }
}

/* ------------------------------------------------------- the bundle id -- */

/**
 * The bundle identifier macOS files this app's notifications under.
 *
 * Read from the running bundle's own `Info.plist` rather than hardcoded,
 * because the answer genuinely differs: `dev.terminaldeck.app` when packaged,
 * `com.github.Electron` under `electron-vite dev`. A hardcoded id would make
 * every development run report "macOS has no record of it" — a false alarm,
 * which is the same disease as a false success.
 *
 * Cached: the file cannot change while the app is running.
 */
let cachedBundleId: string | null | undefined

export async function bundleIdentifier(): Promise<string | null> {
  if (cachedBundleId !== undefined) return cachedBundleId
  cachedBundleId = null
  try {
    // …/Contents/MacOS/<exe> → …/Contents/Info.plist
    const plist = join(app.getPath('exe'), '..', '..', 'Info.plist')
    if (!existsSync(plist)) return cachedBundleId
    const { stdout } = await run('/usr/bin/plutil', ['-extract', 'CFBundleIdentifier', 'raw', '-o', '-', plist])
    const id = stdout.trim()
    cachedBundleId = id === '' ? null : id
  } catch {
    cachedBundleId = null
  }
  return cachedBundleId
}

/* ---------------------------------------------------- delivery evidence -- */

export type DeliveryVerdict =
  /** macOS's own store holds a record posted after we asked. */
  | 'delivered'
  /** The store was readable and holds nothing. The banner did not arrive. */
  | 'absent'
  /** We could not ask. Claim nothing. */
  | 'unknown'

export interface DeliveryReport {
  verdict: DeliveryVerdict
  /** Local time the OS recorded, so the note can be checked against the screen. */
  at: string | null
  /** Why the verdict is `unknown`. Diagnostic; the renderer writes its own copy. */
  detail: string | null
}

/** Seconds between the Unix epoch and Apple's, which `delivered_date` counts from. */
const APPLE_EPOCH_OFFSET = 978_307_200

const STORE = () =>
  join(homedir(), 'Library', 'Group Containers', 'group.com.apple.usernoted', 'db2', 'db')

/**
 * How long to keep asking, and how often.
 *
 * A poll, in a codebase whose rule is events over timers (7.9) — so the reason
 * is written down. Notification Center pushes nothing; there is no callback,
 * no file watcher that fires on a row insert, and no Electron event for
 * "macOS accepted this". This is therefore the only reading available, it is
 * bounded, it exists only between a button press and its answer, and nothing
 * schedules it again.
 *
 * The window is nine and a half seconds because of a fact that has to be
 * measured rather than assumed, and that a shorter poll gets exactly backwards.
 * **The row is not written when the banner appears. It is written when the
 * banner leaves the screen.** Polled once a second against a banner that was
 * plainly on screen the whole time:
 *
 *     t+1s … t+5s   rows = 0
 *     t+6s onwards  rows = 1
 *
 * A 2.4-second probe would therefore have reported "macOS has no record of it"
 * for every banner that worked perfectly — a false alarm, which is the same
 * disease as the false success this module was written to cure, pointing the
 * other way. Nine and a half seconds clears the ~6s transition with room for a
 * loaded machine.
 */
const POLL_EVERY_MS = 700
const POLL_FOR_MS = 9500

const sleep = (ms: number): Promise<void> => new Promise((done) => setTimeout(done, ms))

/** SQL string literal. The id comes from our own Info.plist; escaped anyway. */
function quote(value: string): string {
  return `'${value.replace(/'/g, "''")}'`
}

/**
 * Ask macOS whether it took delivery of a notification for this app since
 * `sinceMs`.
 *
 * The one-second slack on the lower bound is not sloppiness: `delivered_date`
 * is a float of Apple-epoch seconds and the renderer's clock reading is taken
 * a moment before the notification is constructed, so an exact boundary would
 * be able to miss the very row it is looking for.
 */
export async function notificationDelivery(
  sinceMs: unknown,
  options: { platform?: NodeJS.Platform; now?: () => number } = {},
): Promise<DeliveryReport> {
  const platform = options.platform ?? process.platform
  const now = options.now ?? Date.now

  if (platform !== 'darwin') {
    return { verdict: 'unknown', at: null, detail: 'Only macOS records this where the app can read it.' }
  }

  const since = typeof sinceMs === 'number' && Number.isFinite(sinceMs) ? sinceMs : now()
  const appleSince = since / 1000 - APPLE_EPOCH_OFFSET - 1

  const db = STORE()
  if (!existsSync(db)) {
    return { verdict: 'unknown', at: null, detail: 'This Mac has no notification store at the expected path.' }
  }

  const id = await bundleIdentifier()
  if (!id) {
    return { verdict: 'unknown', at: null, detail: 'The app could not read its own bundle identifier.' }
  }

  // `lower(...)`, not `=`. macOS files the app under a lower-cased identifier:
  // `Info.plist` says `com.github.Electron` and the store says
  // `com.github.electron`. SQLite compares TEXT case-sensitively, so an exact
  // match silently found nothing for every notification that did arrive —
  // caught only by looking at the store by hand, which is the whole argument
  // for not trusting a chain that has never been watched end to end.
  const sql =
    `select datetime(r.delivered_date + ${APPLE_EPOCH_OFFSET}, 'unixepoch', 'localtime') ` +
    `from record r join app a on r.app_id = a.app_id ` +
    `where lower(a.identifier) = lower(${quote(id)}) and r.delivered_date > ${appleSince} ` +
    `order by r.delivered_date desc limit 1;`

  const deadline = now() + POLL_FOR_MS
  let lastError: string | null = null

  for (;;) {
    try {
      const { stdout } = await run('/usr/bin/sqlite3', ['-readonly', db, sql], { timeout: 4000 })
      const at = stdout.trim()
      if (at !== '') return { verdict: 'delivered', at, detail: null }
      lastError = null
    } catch (cause) {
      lastError = cause instanceof Error ? cause.message : String(cause)
    }
    if (now() >= deadline) break
    await sleep(POLL_EVERY_MS)
  }

  if (lastError) return { verdict: 'unknown', at: null, detail: `The notification store could not be read: ${lastError}` }
  return { verdict: 'absent', at: null, detail: null }
}

/* ------------------------------------------------------------- support -- */

export interface NotificationSupport {
  /** Is there an OS settings page worth offering a button for? */
  settingsPane: boolean
  /** Can `notificationDelivery` ever answer anything but `unknown`? */
  deliveryReadable: boolean
  platform: NodeJS.Platform
}

export function notificationSupport(
  platform: NodeJS.Platform = process.platform,
): NotificationSupport {
  return {
    settingsPane: notificationSettingsUrl(platform) !== null,
    // Optimistic by design: it says the *mechanism* exists on this platform,
    // not that today's read will succeed. A read that fails still returns
    // `unknown`, and the copy for `unknown` promises nothing.
    deliveryReadable: platform === 'darwin' && existsSync(STORE()),
    platform,
  }
}

/* ----------------------------------------------------------------- ipc -- */

export function registerNotificationIpc(ipcMain: IpcMain): void {
  ipcMain.handle('notifications:support', () => notificationSupport())
  ipcMain.handle('notifications:open-settings', () => openNotificationSettings())
  ipcMain.handle('notifications:delivery', (_e: IpcMainInvokeEvent, since: unknown) =>
    notificationDelivery(since),
  )
}
