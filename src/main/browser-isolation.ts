import { randomUUID } from 'node:crypto'
import { app, session, type IpcMain, type Session } from 'electron'
import { writeRecordPreload } from './browser-record-preload'

/**
 * Per-tab isolation: a browser tab that shares nothing with the others.
 *
 * ## What "isolated" has to mean to be worth having
 *
 * Every tab in this app has always shared one `persist:terminaldeck-browser` partition,
 * which is what makes a login survive a restart. That is the right default and
 * the wrong one for two jobs the browser panel exists to do: signing into the
 * same dev app as a second user, and looking at a page without the cookies just
 * imported from Chrome following you into it.
 *
 * So an isolated tab gets a partition of its own, named `terminaldeck-tab-<uuid>` with
 * **no `persist:` prefix**. That prefix is the entire difference between a
 * partition Electron writes to `<userData>/Partitions/<name>` and one that lives
 * in memory and is gone when the process ends. Isolation that left a directory
 * behind for every tab ever opened would be neither isolated nor tidy, and the
 * name is generated per tab so two isolated tabs never collide — `fromPartition`
 * returns *the same session object* for the same string, which is exactly the
 * property being avoided here and the one `browser-session.ts` relies on.
 *
 * All four of those claims were checked on Electron 41.10.5 rather than taken
 * from the docs, because the whole feature is worthless if any of them is
 * wrong: `persist:terminaldeck-browser` reports `isPersistent()` true, a bare
 * `terminaldeck-tab-<uuid>` reports false with a null storage path, the same name hands
 * back the identical object while a different one does not, and a cookie
 * written into one isolated partition is invisible to both the other isolated
 * partition and the shared one.
 *
 * ## Isolated does not mean less hardened
 *
 * A guest page is untrusted whichever partition it is in. Everything
 * `browser-tab.ts` does to the shared session is done here too — permissions
 * refused, downloads blocked — and the flow recorder's session preload is
 * registered as well, or recording would silently stop working the moment a tab
 * was switched to Isolated. Both are easy to forget and neither fails loudly.
 *
 * ## The seam
 *
 * `browser-tab.ts` owns view creation and this module does not duplicate it. It
 * offers {@link isolatedSession}, which that module consults for one option on
 * the create call: a key means "your own partition", no key means the shared
 * one. That is the whole integration.
 */

/** No `persist:` — that is what keeps an isolated tab's data in memory only. */
export const ISOLATED_PREFIX = 'terminaldeck-tab-'

/** Partitions handed out this run, so they can be recognised and disposed. */
const sessions = new Map<string, Session>()

let recordPreloadPath: string | null = null

/**
 * Is this a key this module minted?
 *
 * Keys arrive from the renderer over IPC, and a partition name is a string
 * Electron will happily create *anything* for — including `persist:something`,
 * which would quietly give an "isolated" tab a directory on disk. So the shape
 * is checked rather than trusted: our prefix, then a UUID, and nothing else.
 */
export function isIsolationKey(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    new RegExp(`^${ISOLATED_PREFIX}[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`).test(
      value,
    )
  )
}

/** A fresh key. One per isolated tab; never reused, never persisted. */
export function newIsolationKey(): string {
  return `${ISOLATED_PREFIX}${randomUUID()}`
}

/**
 * Harden a guest partition.
 *
 * Deliberately the same list as `hardenedGuestSession()` in `browser-tab.ts`:
 * a page being looked at has no business asking for the camera, the clipboard
 * or a notification, and there is no UI here to ask the user with. Downloads are
 * refused for the same reason they are refused there.
 */
function harden(ses: Session): Session {
  ses.setPermissionRequestHandler((_wc, _permission, callback) => callback(false))
  ses.setPermissionCheckHandler(() => false)
  ses.on('will-download', (event) => event.preventDefault())

  // The recorder's guest script is attached per *session*, so an isolated tab
  // that skipped this would look like it was recording and capture nothing.
  if (recordPreloadPath === null) recordPreloadPath = writeRecordPreload(app.getPath('userData'))
  ses.registerPreloadScript({ type: 'frame', filePath: recordPreloadPath })

  return ses
}

/**
 * The session for an isolated tab, or null when the caller did not ask for one.
 *
 * Null rather than a throw: this is called from `browser-tab.ts` on the normal
 * create path, where "no key" is the ordinary case and means "use the shared
 * session". A malformed key is treated the same way on purpose — a tab that
 * quietly falls back to Shared is wrong, but a browser panel that refuses to
 * open a tab at all is worse, and the renderer only ever sends keys this module
 * minted.
 */
export function isolatedSession(key: unknown): Session | null {
  if (!isIsolationKey(key)) return null
  const existing = sessions.get(key)
  if (existing) return existing
  const ses = harden(session.fromPartition(key))
  sessions.set(key, ses)
  return ses
}

/**
 * Does this session belong to an isolated tab?
 *
 * `browser-view.ts` needs it: it recognises guest views by comparing their
 * session to the shared one, and without this an isolated tab's view would never
 * be claimed — losing zoom, devtools, screenshots, load progress and recording,
 * all without an error.
 */
export function isIsolatedGuestSession(candidate: Session): boolean {
  for (const ses of sessions.values()) {
    if (ses === candidate) return true
  }
  return false
}

/**
 * How many isolated partitions are alive.
 *
 * Nothing in the UI shows this yet — the settings panel's isolation block is
 * prose, because the switch is per tab and the tab strip already marks which
 * ones are isolated. It backs the `browser-isolation:count` channel and the
 * disposal tests, and is the one way to see a partition that was leaked.
 */
export function isolatedSessionCount(): number {
  return sessions.size
}

/**
 * Forget an isolated partition.
 *
 * The storage was never on disk, so this is about not holding a tab's cookies in
 * memory for the rest of the run after it has been closed. `fromPartition` keeps
 * handing back the same object for a name, so dropping our reference is not
 * enough on its own — the data is cleared first.
 */
export async function disposeIsolatedSession(key: unknown): Promise<void> {
  if (!isIsolationKey(key)) return
  const ses = sessions.get(key)
  sessions.delete(key)
  if (!ses) return
  try {
    await ses.clearStorageData()
  } catch {
    // A session torn down with its window is already as cleared as it gets.
  }
}

/** Called from `before-quit`, alongside the other browser teardown. */
export async function disposeAllIsolatedSessions(): Promise<void> {
  await Promise.all([...sessions.keys()].map((key) => disposeIsolatedSession(key)))
}

/**
 * Wire the renderer's half. Call once from `registerIpc()`, before
 * `registerBrowserIpc`:
 *
 *     import { registerBrowserIsolationIpc } from './browser-isolation'
 *     registerBrowserIsolationIpc(ipcMain)
 *
 * Channels:
 * - `browser-isolation:key`     (invoke)      → a key to pass to `browser:create`
 * - `browser-isolation:dispose` (invoke, key) → void
 * - `browser-isolation:count`   (invoke)      → number
 */
export function registerBrowserIsolationIpc(ipcMain: IpcMain): void {
  ipcMain.handle('browser-isolation:key', () => newIsolationKey())
  ipcMain.handle('browser-isolation:dispose', (_event, key: unknown) => disposeIsolatedSession(key))
  ipcMain.handle('browser-isolation:count', () => isolatedSessionCount())
}
