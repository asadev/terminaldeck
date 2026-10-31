/**
 * The four things a tour is allowed to do to the window, and nothing else.
 *
 * ## Why this is a registry and not a prop
 *
 * The tour player is mounted as a sibling of `<App/>` — see `DriveHost.tsx` for
 * why it has to be out of the application's layout — so it is not below the
 * component that owns navigation and cannot be handed a callback down a tree it
 * is not in. `App.tsx` registers itself here in one effect, and the player asks.
 *
 * That is the same shape `focus-controller.ts` and `terminal-registry.ts`
 * already take, for the same reason and with the same `Symbol.for` guard: a
 * second copy of this module in one window is a second registry, and the symptom
 * is a `selectTab` that returns cleanly while the screen does not move.
 *
 * ## Why the surface is this small
 *
 * `DRIVING-MODE.md` §7 lists what driving may do, and the list is short by
 * design: *"Navigate (`selectTab`, `showPanel`), switch a session between
 * terminal and chat, scroll a pane, draw a box, dim, un-dim, and write its own
 * record. That is the whole list."* The scrolling and the drawing belong to the
 * overlay, so what is left for the app is these four.
 *
 * The temptation is to expose `App`'s command dispatcher and let a tour name any
 * command. That is the same mistake as a CSS-selector anchor and it is worse: a
 * tour's arguments were composed by a model out of *other sessions' transcripts*
 * (`COPILOT-CAPABILITIES.md` §3.2 item 8), and a dispatcher takes ids like
 * `session.close`. A closed set of three functions cannot be talked into closing
 * a tab, and the reason it cannot is structural rather than a check somebody has
 * to remember to write.
 */

export interface DriveNavigator {
  /** Bring a session or a page tab to the front. */
  selectTab(id: string): void
  /** Open one of the sidebar's views, optionally focused on part of it. */
  showPanel(id: string, focus?: string | null): void
  /** The folder a session is running in, for a `git-file` anchor. */
  cwdOf(sessionId: string): string | null
}

const REGISTRY = Symbol.for('terminaldeck.driving.navigator')

type Host = { [REGISTRY]?: { current: DriveNavigator | null } }

function slot(): { current: DriveNavigator | null } {
  const host = globalThis as Host
  const existing = host[REGISTRY]
  if (existing) return existing
  const created = { current: null as DriveNavigator | null }
  host[REGISTRY] = created
  return created
}

/**
 * Register the window's navigation. Call the returned function on unmount.
 *
 * Returns an unregister rather than exposing a `clear`, and the closure checks
 * identity before clearing, for the reason `terminal-registry.ts` gives: React
 * can mount a replacement before it runs the previous one's cleanup, and an
 * unconditional clear would then wipe the live registration.
 */
export function registerNavigator(navigator: DriveNavigator): () => void {
  const current = slot()
  current.current = navigator
  return () => {
    if (current.current === navigator) current.current = null
  }
}

/**
 * The window's navigation, or null.
 *
 * Null is a real state and not an error: a harness that mounts the driving panel
 * without the application has no navigation, and a tour of anchor stops still
 * draws correctly in it. A player that treated null as a failure would be
 * untestable outside a full app for no benefit.
 */
export function navigator(): DriveNavigator | null {
  return slot().current
}
