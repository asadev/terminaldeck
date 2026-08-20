/**
 * The sessions belong to the machine, not to the window.
 *
 * ## The complaint this answers
 *
 * *"if we restart the application then the ones already has been started they
 * should stay there they should not die because of this"* — Asad, 2026-08-19,
 * and he is right. Until now `before-quit` called `ptys.killAll()`, so quitting
 * the app took every running agent with it. An agent that has been working for
 * forty minutes is not a view of the app; it is a process on this computer, and
 * closing a window is not a reason to end it.
 *
 * The rule the whole feature follows, in one line: **a session belongs to the
 * machine it runs on, not to the app window.** That is already true for a
 * session a phone started against this Mac, and already true for a session on a
 * paired machine, and it was the one case sitting in front of him — his own
 * window — where it was false.
 *
 * ## What this module actually is
 *
 * It is *not* a new place for sessions to live. The ptys stay exactly where they
 * are, in `PtyManager` inside the Electron main process, and that is the whole
 * trick: if the process does not exit, the sessions do not die and their
 * scrollback is still in memory, so a new window built against the same process
 * gets every tab back with its screen intact and nothing has to be replayed,
 * re-spawned or reconstructed. `hydrateRenderer` already re-announces
 * `ptys.list()` on every load, and `session:scrollback` already answers from the
 * live buffer. Both were written for a renderer reload; they turn out to be
 * exactly what reattaching needs.
 *
 * So what this module owns is the *decision* — whether a quit ends the machine's
 * work or merely puts the window away — and the honesty that decision requires.
 *
 * ## Why there has to be a tray, and why it is not optional
 *
 * An app that keeps running after you quit it, with nothing on screen saying so,
 * is not a feature. It is a process a person cannot see and cannot stop, and the
 * next thing they learn about it is that their laptop was warm all night. So the
 * rule here is: **the moment the last window goes and this process stays, there
 * is an icon in the menu bar / notification area that says what is running and
 * offers to end it.** The tray is created when the app goes resident and
 * destroyed the moment a window comes back, because a tray icon beside a visible
 * window is clutter that says nothing new.
 *
 * On macOS the Dock icon is a second, free answer to the same question — an app
 * with no windows is still in the Dock and clicking it opens one, which is the
 * platform's own idiom and this app already handles it in `activate`. Windows
 * and Linux have no such thing, which is why the tray is built on every
 * platform rather than only where it is strictly the only option: one behaviour
 * everywhere beats a protection that exists on two platforms out of three.
 *
 * ## The two opposite expectations, resolved rather than picked between
 *
 * One person quits because they are finished and expects everything to stop.
 * Another quits because the window is in the way and expects his agents to keep
 * working. Both are ordinary, and silently choosing either one surprises the
 * other — so the app **asks**, once, the first time it matters, and remembers
 * the answer if the person says to. {@link plannedQuit} is that decision, kept
 * as a pure function so both answers are pinned in a test rather than living
 * inside a dialog callback nobody can run.
 *
 * The question is only ever asked when there is something to lose: with no live
 * session, quitting quits, with no dialog and no tray. A prompt on an empty app
 * would train people to dismiss the prompt that matters.
 */

import { Menu, Tray, nativeImage, type MenuItemConstructorOptions } from 'electron'
import { basename } from 'node:path'
import { BRAND } from '../shared/brand'
import { AGENT_CATALOG } from '../shared/agent-catalog'
import type { SessionMeta } from '../shared/types'

/* --------------------------------------------------------------- deciding -- */

/**
 * What the app does when somebody quits it with sessions still running.
 *
 * `ask` is the default and stays the default forever unless a person ticks the
 * box, because the two answers below are genuinely a matter of what somebody
 * wants and this app has no way to know which of the two they are.
 */
import type { QuitBehavior } from './store'
export type { QuitBehavior }

/**
 * What a particular quit resolves to.
 *
 * `ask` is a fourth outcome rather than a missing one: the caller has to know
 * the difference between "go resident, I have decided" and "I cannot decide
 * without the person", because only the second one may put a dialog on screen.
 */
export type QuitPlan = 'keep' | 'stop' | 'ask'

/**
 * Decide, without touching Electron, what a quit means.
 *
 * Pure on purpose. The interesting case — a remembered `keep` with nothing
 * running — is the one that would otherwise leave a resident process holding
 * zero sessions behind a tray icon that says "0 sessions", which is the exact
 * shape of the invisible-background-process bug this feature must not become.
 * It is one line here and one assertion in the test; inside a dialog callback it
 * would be neither.
 */
export function plannedQuit(liveSessions: number, behavior: QuitBehavior): QuitPlan {
  if (liveSessions <= 0) return 'stop'
  return behavior === 'ask' ? 'ask' : behavior
}

/** The buttons on the quit question, in the order they are drawn. */
export const QUIT_BUTTONS = ['Keep Them Running', 'Stop Everything', 'Cancel'] as const

/**
 * Turn a pressed button into an answer.
 *
 * Separated from the dialog for the same reason {@link plannedQuit} is: the
 * mapping from an index to a decision is exactly the kind of thing that is
 * silently off by one, and being off by one here means a button labelled "Stop
 * Everything" that keeps everything running.
 */
export function quitAnswer(buttonIndex: number): 'keep' | 'stop' | 'cancel' {
  if (buttonIndex === 0) return 'keep'
  if (buttonIndex === 1) return 'stop'
  return 'cancel'
}

/**
 * The sentence a person reads at the moment they press Quit.
 *
 * Written here rather than inline so that what the app promises is one string
 * that can be read next to the code that keeps the promise. It names the count
 * because "some sessions" is the kind of vagueness that makes people press
 * Cancel and go looking, and it names the tray because the tray is the whole
 * reason keeping them running is not a trap.
 */
export function quitQuestion(sessions: readonly SessionMeta[]): { message: string; detail: string } {
  const n = sessions.length
  return {
    message: n === 1 ? 'One session is still running.' : `${n} sessions are still running.`,
    detail:
      `Quitting has always ended them. It does not have to: ${BRAND.name} can keep them ` +
      `running on this machine with no window, and put them back — screens and all — the ` +
      `next time you open it.\n\n` +
      `While they are running you will find ${BRAND.name} in the menu bar, which lists them ` +
      `and can stop any of them, or all of them, without opening a window.`,
  }
}

/* ------------------------------------------------------------------- tray -- */

/**
 * The icon, as bytes, because there is nowhere to read one from at runtime.
 *
 * `build/icon.png` is a build resource: electron-builder reads it to make the
 * `.icns` and the `.ico` and does not ship it, and `electron-builder.yml`'s
 * `files` allowlist deliberately names only `out/**`, `package.json` and the
 * phone client. So a tray that loaded an icon off disk would work in dev and be
 * a blank 16×16 hole in the notification area of every packaged build — which
 * on Windows is indistinguishable from the app not running at all, and this
 * icon's entire job is to prove that it is.
 *
 * Two sizes, both alpha-only black, marked as a template image so macOS inverts
 * them with the menu bar instead of leaving a black smudge on a dark bar.
 */
const TRAY_ICON_16 =
  'iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAANklEQVR42mNgoCL4TyKmSDOGIVhNJcK1g9iA/wQMJdoFRIsTsm3gDCDbC/8JiNEuGumaH6gDADRnapb7gGUcAAAAAElFTkSuQmCC'
const TRAY_ICON_32 =
  'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAc0lEQVR42u2XUQoAIAhDu/+l1wkiy+kiFfyMPXSYjtGxDpBTJnwEgqQ0AUS2NF3cpNEADbADYADSAKBqAZwgNA/cQlBNCOcbisngqBzN5bUBpC2QmnAnfrWUMAdRCMBJycMB/vyO5UvpE2u5/DB54jSrFRNRMla44BYb7AAAAABJRU5ErkJggg=='

function trayImage(): Electron.NativeImage {
  const image = nativeImage.createFromBuffer(Buffer.from(TRAY_ICON_16, 'base64'))
  image.addRepresentation({
    scaleFactor: 2,
    buffer: Buffer.from(TRAY_ICON_32, 'base64'),
  })
  // Only meaningful on macOS, where it makes the icon follow the menu bar's
  // appearance. Harmless everywhere else, and a branch on the platform here
  // would be a branch that is only ever read on the machine that takes it.
  image.setTemplateImage(true)
  return image
}

/** Everything the tray needs from the app, and nothing about how the app works. */
export interface ResidentDeps {
  /** The sessions that still have a process, newest last. */
  sessions(): readonly SessionMeta[]
  /** Bring a window back. Reattaching is the window's own job once it loads. */
  open(): void
  /** End one session, by id. */
  stop(id: string): void
  /** End everything and exit for real. */
  quitAll(): void
}

/**
 * The menu, rebuilt from the sessions each time something changes.
 *
 * Rebuilt from events — a session starting, exiting or being removed — rather
 * than on a timer, because a tray menu polled once a second is a wakeup once a
 * second on a machine whose owner has closed the window and walked away. That is
 * the standing rule in this repository and it applies most to the code that runs
 * when nobody is watching.
 */
function residentMenu(deps: ResidentDeps): Menu {
  const live = deps.sessions().filter((meta) => meta.exitCode === null)
  const items: MenuItemConstructorOptions[] = [
    {
      label:
        live.length === 1
          ? `${BRAND.name} — 1 session running`
          : `${BRAND.name} — ${live.length} sessions running`,
      enabled: false,
    },
    { type: 'separator' },
    { label: `Open ${BRAND.name}`, click: () => deps.open() },
  ]

  if (live.length > 0) {
    items.push({ type: 'separator' })
    for (const meta of live) {
      // The agent and the folder, because those two together are how a person
      // recognises a session they started an hour ago. The tab title is the
      // renderer's, derived from the session's own output, and it does not exist
      // in this process — see `SessionMeta.title`, which is only ever the
      // folder's basename here.
      const label = `${AGENT_CATALOG[meta.provider]?.label ?? meta.provider} — ${basename(meta.cwd)}`
      items.push({
        label,
        submenu: [
          { label: 'Open', click: () => deps.open() },
          { label: 'Stop This Session', click: () => deps.stop(meta.id) },
        ],
      })
    }
  }

  items.push(
    { type: 'separator' },
    { label: 'Quit and Stop All Sessions', click: () => deps.quitAll() },
  )
  return Menu.buildFromTemplate(items)
}

/**
 * The menu-bar presence, created when the app goes resident and destroyed when a
 * window comes back.
 *
 * A class over a pair of module functions because there is exactly one piece of
 * state — the `Tray` — and `show`/`refresh`/`hide` all have to agree about
 * whether it exists. `show` twice is a no-op rather than a second icon: on the
 * platforms where the last window closing also triggers a quit, this is reached
 * twice in a row through two different events, and two icons for one app is the
 * kind of thing nobody notices until it ships.
 */
export class ResidentPresence {
  private tray: Tray | null = null

  constructor(private readonly deps: ResidentDeps) {}

  get visible(): boolean {
    return this.tray !== null
  }

  /**
   * Try to appear. Answers with {@link visible}, and never throws.
   *
   * `new Tray()` is not guaranteed to work: a Linux session with no status
   * notifier host has nowhere to put it, and that failure has to reach the
   * caller as a *fact about visibility* rather than as an exception on the quit
   * path. The caller's answer to "I could not be seen" is to quit properly
   * instead of hiding, which is only possible if it is told.
   */
  show(): void {
    if (this.tray === null) {
      try {
        this.tray = new Tray(trayImage())
        this.tray.setToolTip(BRAND.name)
        // Clicking the icon itself opens the app, which is what people try
        // first; the menu is still there on right-click, and on macOS on a
        // plain click.
        this.tray.on('double-click', () => this.deps.open())
      } catch {
        this.tray = null
        return
      }
    }
    this.refresh()
  }

  /** Redraw the menu, if there is one. Safe to call when the app has a window. */
  refresh(): void {
    if (this.tray === null) return
    const live = this.deps.sessions().filter((meta) => meta.exitCode === null).length
    this.tray.setToolTip(
      live === 1 ? `${BRAND.name} — 1 session running` : `${BRAND.name} — ${live} sessions running`,
    )
    this.tray.setContextMenu(residentMenu(this.deps))
  }

  hide(): void {
    this.tray?.destroy()
    this.tray = null
  }
}

/**
 * Whether this platform hides the app from view when its last window closes.
 *
 * macOS does not — an app with no windows keeps its Dock icon and its menu bar,
 * which is a running app a person can already see and quit through the ordinary
 * platform gesture. Everywhere else, the tray is the only thing standing between
 * "your agents kept working" and "there is a process you cannot find".
 *
 * Exported because the honest thing to do when a tray cannot be created — a bare
 * Linux session with no notification area is a real configuration — differs by
 * platform, and the caller is where that is decided.
 */
export function needsTrayToBeVisible(platform: NodeJS.Platform): boolean {
  return platform !== 'darwin'
}

/**
 * Keep the process alive on a platform that would otherwise exit.
 *
 * On Windows and Linux, Electron ends the process when the last window closes
 * *and nothing else is holding the loop open*. The tray does hold it, and so do
 * the relay socket and the hook server — but relying on that is relying on a
 * side effect of three unrelated features, and the day one of them is made to
 * `unref()` its handle is the day sessions start dying again with no code change
 * anywhere near this file. So the intent is written down: one ref'd handle whose
 * only job is to say the process is deliberately still here.
 *
 * `app.quit()` is not blocked by it — a ref'd timer keeps libuv's loop alive, it
 * does not veto a quit — which is exactly the property wanted: the tray's "Quit
 * and Stop All Sessions" still works instantly.
 */
export class ProcessKeepAlive {
  private handle: NodeJS.Timeout | null = null

  hold(): void {
    if (this.handle !== null) return
    // Never fires in practice: an hour is far longer than any resident spell,
    // and it re-arms. The interval is a handle, not a schedule — nothing runs on
    // it, so it is not polling.
    this.handle = setInterval(() => {}, 60 * 60 * 1000)
  }

  release(): void {
    if (this.handle === null) return
    clearInterval(this.handle)
    this.handle = null
  }
}
