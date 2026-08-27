import type { SavedSession } from './session-restore'

/**
 * The sessions that were open, could not be started again, and are being kept
 * anyway.
 *
 * ## Why this exists
 *
 * Because the app used to throw them away, and it did it quietly.
 *
 * `OpenSessionLedger` is rebuilt from nothing at every launch: it is a map of
 * *live* sessions, and `flush()` writes exactly what is in it over the top of
 * `openSessions`. So the list on disk survives a restart only for as long as
 * nothing writes to it — and the first session that starts, for any reason,
 * replaces the whole file. A session that failed to come back was therefore not
 * "still remembered, and not running". It was gone, permanently, at the moment
 * the next tab opened.
 *
 * That is what happened on `DESKTOP-DDGMNCV`. Four Claude sessions in two WSL
 * folders failed to restart on 2026-08-16 at 22:17 (`wsl.ts`'s `wslExePath` has
 * the cause). The app log recorded it honestly — *"did not come back: it could
 * not be started again"* — and then the list was overwritten, so by the next
 * launch the app no longer knew those sessions had ever existed. Asad opened
 * plain terminals in the same folders to get *something*, those were remembered
 * instead, and from then on every restart produced two shells and a log line
 * saying a shell has nothing to continue. A recoverable failure had become
 * permanent, and the wrong thing on screen hid the right one.
 *
 * ## What a held session is
 *
 * It is the *request*, not the process: the folder, the agent, the account —
 * exactly the fields a `SavedSession` carries and nothing more, because that is
 * all a restart ever had. It stays in `openSessions` on disk, so the next launch
 * tries again all by itself; and it is offered to the window, so a person can
 * see a row that says what did not start and why, and press it to try again
 * now.
 *
 * ## What it deliberately is not
 *
 * It is **not** a session. It has no id, no pty, no scrollback and no place in
 * `ptys.list()`, and nothing that draws terminals should ever be handed one.
 * The whole fault being fixed here is an app that answered "we could not start
 * your agent" with something that looked like a working session, and a held
 * entry that pretended to be a `SessionMeta` would be the same mistake wearing
 * this module's name.
 */

/**
 * The channel the held list travels on, in both directions.
 *
 * One name for the question and the announcement — `invoke('sessions:held')`
 * answers with the list, and main pushes the same list on the same name
 * whenever it changes — because they are one fact and a second name for it is a
 * second thing to keep in step.
 *
 * Exported from here rather than declared beside the handler in `index.ts` for
 * two reasons, and the second is mechanical. The first is the house rule: a
 * feature's shape lives in the module that owns it. The second is that
 * `preload/contract.test.ts` resolves a channel registered through a constant
 * only when that constant is *exported* — it scans every main-process source
 * for `export const NAME = '…'` and then looks for `ipcMain.handle(NAME`. A
 * file-local `const` is invisible to it, and the check that would have caught a
 * preload calling a channel nobody registered reports "no handler at all" for a
 * handler sitting right there. A guard whose blind spot is the code being added
 * is worse than no guard.
 */
export const SESSIONS_HELD_CHANNEL = 'sessions:held'

/** One session that did not start, and why. */
export interface HeldSession {
  /**
   * Stable for as long as this entry exists, and meaningless afterwards.
   *
   * Minted here rather than derived from the folder and the agent, because two
   * tabs on the same agent in the same folder are an ordinary thing to have open
   * — `planRestore` has a whole case about which of them gets to continue the
   * conversation — and a key that collapsed them would silently drop one of the
   * two sessions this module exists to stop dropping.
   */
  key: string
  /** The folder it ran in. */
  cwd: string
  /** The agent it was, spelled the way the person asked for it. */
  provider: SavedSession['provider']
  profileId: string | null
  cols: number
  rows: number
  lastSeenAt: number
  /**
   * The tab it was, so Try again brings back *that* tab.
   *
   * Carried through the hold rather than re-minted on the retry, because a
   * session that did not start is still somebody's tab in somebody's
   * arrangement — and a retry that came back under a new name would put it on
   * the end of the bar instead of where it was. See {@link SavedSession.tabKey}.
   *
   * Absent for the same one reason it is absent there: a list written by an
   * older build.
   */
  tabKey?: string
  /**
   * The device this session is held inside a folder for, carried so that Try
   * again brings it back **as confined as it was** rather than loose.
   *
   * A session a device started that failed to restore is still confined work,
   * and the retry re-applies its boundary exactly as the launch restore does —
   * see {@link SavedSession.confineDeviceId}. Dropping it here would make the one
   * button whose whole job is to reproduce a session reproduce it *unconfined*,
   * which is the one thing the boundary must never do. Absent for a tab opened
   * at the keyboard, which has no boundary.
   */
  confineDeviceId?: string
  /**
   * Why it did not start, in a sentence written for the person.
   *
   * The same sentence the app log carries, on purpose: the log is what somebody
   * reads when they are trying to work out what happened, the row is what they
   * see when it happens, and two different explanations of one event is how a
   * support conversation goes wrong.
   */
  reason: string
  /** When the most recent attempt failed. Epoch ms. */
  at: number
}

/**
 * Turn a held entry back into the thing that gets written to disk and handed to
 * a restart.
 *
 * A separate function rather than a spread at each call site, because the two
 * shapes are deliberately allowed to diverge — `reason` and `at` are about the
 * failure and have no business in `openSessions`, which is a list of what was
 * open.
 */
export function savedFrom(held: HeldSession): SavedSession {
  return {
    cwd: held.cwd,
    provider: held.provider,
    profileId: held.profileId,
    cols: held.cols,
    rows: held.rows,
    lastSeenAt: held.lastSeenAt,
    // Spread rather than assigned: an absent key means "this entry predates
    // named tabs", and `tabKey: undefined` would be written into `openSessions`
    // as an absent key anyway — but only one of the two reads as absent to a
    // caller checking the property before it spawns.
    ...(held.tabKey !== undefined ? { tabKey: held.tabKey } : {}),
    // And the device its boundary is rebuilt for, so a session written back to
    // `openSessions` and restored next launch is still re-confined.
    ...(held.confineDeviceId !== undefined ? { confineDeviceId: held.confineDeviceId } : {}),
  }
}

/**
 * The held list.
 *
 * A class with its change hook injected, for the same reason `FolderGrants` and
 * `WslLink` are: a test has to be able to stand two of them up in one file, and
 * the thing that has to happen when this changes — write the file, tell the
 * window — belongs to whoever assembled the app, not to the list.
 */
export class HeldSessions {
  private readonly held = new Map<string, HeldSession>()
  private counter = 0

  /**
   * Called after every change, exactly once per change.
   *
   * Both of its jobs are the caller's: `OpenSessionLedger.flush()` writes the
   * combined list to disk, and the shell pushes the new list to whatever is
   * drawing it. Neither can be done from here — this module has no store and no
   * window — and a list that could do them itself would be a list that does them
   * twice when it is embedded in something that also does.
   */
  constructor(private readonly onChange: () => void = () => undefined) {}

  /**
   * Keep a session that could not be started.
   *
   * Returns the entry so the caller can log or announce it without looking it up
   * again.
   */
  hold(session: SavedSession, reason: string): HeldSession {
    this.counter += 1
    const entry: HeldSession = {
      key: `held-${this.counter}`,
      cwd: session.cwd,
      provider: session.provider,
      profileId: session.profileId,
      cols: session.cols,
      rows: session.rows,
      lastSeenAt: session.lastSeenAt,
      // The tab it was. `key` above names the *row*, which is minted here and
      // dies with the row; this names the tab, which outlives the app.
      ...(session.tabKey !== undefined ? { tabKey: session.tabKey } : {}),
      // The device its boundary is rebuilt for, so Try again re-confines it
      // rather than starting it loose.
      ...(session.confineDeviceId !== undefined
        ? { confineDeviceId: session.confineDeviceId }
        : {}),
      reason,
      at: Date.now(),
    }
    this.held.set(entry.key, entry)
    this.onChange()
    return entry
  }

  /** Every held entry, oldest first — which is the order they were tabs in. */
  list(): HeldSession[] {
    return [...this.held.values()]
  }

  /** The same entries as the list that gets written to disk. */
  saved(): SavedSession[] {
    return this.list().map(savedFrom)
  }

  get(key: string): HeldSession | null {
    return this.held.get(key) ?? null
  }

  /**
   * Another attempt, and it failed too.
   *
   * The entry stays; only the reason and the time change. A retry that removed
   * the entry on failure would be this module handing back the exact behaviour
   * it exists to remove — press the button, the row disappears, the session is
   * gone.
   */
  fail(key: string, reason: string): void {
    const entry = this.held.get(key)
    if (!entry) return
    this.held.set(key, { ...entry, reason, at: Date.now() })
    this.onChange()
  }

  /**
   * Stop holding it — because it started, or because the person dismissed it.
   *
   * One method for both, because they are the same thing to this list and the
   * difference is entirely in what the caller does next: a start writes a live
   * record in its place, a dismissal writes nothing. Answering whether anything
   * was actually removed is what lets a caller avoid announcing a change that
   * did not happen — a double-clicked retry arrives twice.
   */
  release(key: string): boolean {
    if (!this.held.delete(key)) return false
    this.onChange()
    return true
  }

  /** True when there is nothing being held. Cheaper than building the list. */
  get empty(): boolean {
    return this.held.size === 0
  }
}
