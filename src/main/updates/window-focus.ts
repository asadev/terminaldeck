/**
 * "A window of this app came to the front", as a subscription.
 *
 * Split into its own file for one reason: `updater.ts` is a dependency-injected
 * module with no Electron import in it, which is what lets its tests run the
 * real controller under plain Node with a fake emitter. Reaching for `app`
 * inside it would have pulled Electron into every one of those tests, so the
 * one line that does reach for it lives here instead, and `updater.ts` takes it
 * as a default it can be handed something else in place of.
 *
 * The `electron` import is dynamic and its failure is swallowed, because this
 * module *is* loaded outside Electron — by the update tests, through
 * `registerUpdateIpc`. There, `import('electron')` resolves to the npm
 * package's path string rather than the runtime, `app` comes back undefined,
 * and this returns a subscription to nothing. That is the right answer: a test
 * harness has no windows to focus.
 */

/** Electron's `app`, in the one shape this module uses. */
interface FocusEmitter {
  on(event: 'browser-window-focus', listener: () => void): unknown
  removeListener(event: 'browser-window-focus', listener: () => void): unknown
}

/**
 * Subscribe to something, and get back the way to stop.
 *
 * The whole seam between `updater.ts` and Electron. A test supplies a function
 * of this shape and drives the controller by calling the listener.
 */
export type FocusSource = (listener: () => void) => () => void

const EVENT = 'browser-window-focus' as const

/**
 * The real source: Electron's own event for a window of this app being brought
 * to the front.
 *
 * Fires on every window, not just the first, and after a `show()` as well as a
 * click — which is the behaviour wanted here, since what it is standing in for
 * is "the user turned their attention back to this app". The caller rate-limits
 * what it does about that; this only reports.
 */
export const appWindowFocus: FocusSource = (listener) => {
  let detach: (() => void) | null = null
  let cancelled = false

  void import('electron')
    .then((electron) => {
      const app = (electron as { app?: Partial<FocusEmitter> }).app
      if (cancelled || typeof app?.on !== 'function') return
      const emitter = app as FocusEmitter
      emitter.on(EVENT, listener)
      detach = () => emitter.removeListener(EVENT, listener)
    })
    .catch(() => {
      // No Electron here. Nothing to listen to, and nothing worth saying about
      // it: the caller's other trigger — the check on launch — still runs.
    })

  return () => {
    cancelled = true
    detach?.()
    detach = null
  }
}
