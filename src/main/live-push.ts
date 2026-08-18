/**
 * The three pushes that keep an open window honest about state changed from
 * somewhere other than that window.
 *
 * Every one of them exists because this app grew a *second* way to change its
 * own state — the copilot, and behind it a paired phone — and the window was
 * only ever built to learn about a change it had asked for itself. A renderer
 * that learns a value from the return of its own `invoke` is a renderer that
 * cannot learn it any other way, and the symptom is always the same shape: the
 * file on disk is right, the tool reports success, and the screen is wrong.
 *
 * Watched live on 2026-08-18, in the capability audit that produced this file:
 *
 *   The copilot was asked to switch the theme to light. The consent dialog drew,
 *   a person pressed Allow, `state.json` said `"light"` — and the window stayed
 *   dark. The copilot then reported *"Done — theme is now light"*, which was true
 *   of the file and false of the screen, and the only way to see the change was
 *   to reload. A tool that is right about the disk and wrong about the screen is
 *   indistinguishable, to the person looking at it, from one that does not work.
 *
 * And, in the same audit, from the other end of the same class of bug: the
 * copilot stopped a session with `sessions_stop`, `sessions_list` came back with
 * only the copilot in it — and *"Copilot sessions → Session 1"* was still sitting
 * in the sidebar, pointing at a pty that no longer existed anywhere in this
 * process.
 *
 * ## Why the channel names live here and not beside their senders
 *
 * Because a `webContents.send` on a channel nobody listens to is a silent no-op,
 * and so is an `ipcRenderer.on` for a channel nobody sends — the seam is
 * `unknown` by design, so there is nothing for the compiler to compare. That is
 * exactly how the browser's progress bar was dead for a week
 * (`browser-view.channels.test.ts` is the account of it). Naming the three in one
 * module gives `live-push.channels.test.ts` something to hold the preload against.
 *
 * ## What is deliberately not pushed
 *
 * The window's own writes. `prefs:set` and `settings:set` arrive *from* the
 * renderer and answer with the new values, so the renderer already knows; a push
 * back down the same wire would be a second update for one change and a loop to
 * reason about for nothing. These channels carry changes the window did not make.
 */

/** Main → renderer: `store.ts` preferences were changed by something else. */
export const PREFS_CHANGED_CHANNEL = 'prefs:changed'

/** Main → renderer: `settings.json` was changed by something else. */
export const SETTINGS_CHANGED_CHANNEL = 'settings:changed'

/**
 * Main → renderer: this app is no longer holding that session at all.
 *
 * Deliberately not `session:exit`, which already exists and means something
 * else. A process that ends on its own stays in `PtyManager`'s map with an exit
 * code, keeps its scrollback, and keeps its row — somebody wants to read what it
 * printed before it died. This fires from the one moment the session is *dropped
 * from the map*, after which its scrollback is gone, writes to it go nowhere and
 * `session:list` does not mention it. A row for one of those is a row that
 * cannot do anything, which is the definition of a ghost.
 */
export const SESSION_REMOVED_CHANNEL = 'session:removed'
