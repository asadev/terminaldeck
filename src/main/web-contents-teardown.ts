import type { WebContents } from 'electron'

/**
 * One `destroyed` listener per WebContents, shared by everything that needs it.
 *
 * ## The warning this exists to remove
 *
 * A packaged v0.1.3 printed this before the user had done anything:
 *
 *     MaxListenersExceededWarning: Possible EventEmitter memory leak detected.
 *     11 destroyed listeners added to [WebContents]. MaxListeners is 10.
 *
 * Nothing was leaking in the usual sense. There is one renderer WebContents and
 * eleven separate modules each wanted to know when it went away — plan limits,
 * costs, MCP, git watches, session search, file search, browser tabs,
 * diagnostics — and each attached its own `once('destroyed')`. Every one of
 * them was individually correct and several went to real trouble to attach only
 * once. Node counts listeners per emitter, not per module, so being right
 * eleven times is what produced the warning.
 *
 * Two of them were worse than that. `plan:watch` and `cost:watch` guarded with
 * `if (!entry.subscribers.has(contents))` — per *entry*, not per WebContents —
 * so a window watching eleven sessions or eleven projects attached eleven
 * listeners by itself, and the count grew with ordinary use rather than
 * settling.
 *
 * ## Why a registry rather than `setMaxListeners`
 *
 * Raising the cap silences the warning and keeps the thing it was reporting: a
 * count that grows with how much of the app you have opened. Here every module
 * registers a callback, exactly one real listener is attached per WebContents,
 * and the count is one no matter how many modules or entries there are.
 *
 * Callbacks are also isolated from each other. These run during teardown, which
 * is when the app is least able to absorb a throw, and one module's failure
 * must not stop the other ten from releasing what they hold.
 *
 * ## Why registration is keyed
 *
 * Every caller here is inside an IPC handler that runs many times — `plan:watch`
 * once per session, `cost:watch` once per project, `mcp:list` on every refresh —
 * and each therefore needs to register its teardown exactly once. Before this,
 * every module solved that for itself with a `Set` of contents it had already
 * seen, and the two that got it subtly wrong are the reason this file exists.
 *
 * So the caller names its registration instead. Registering the same key on the
 * same WebContents twice keeps one, which makes "call this on every request"
 * the correct usage rather than a leak, and deletes the bookkeeping that was
 * being duplicated eleven times.
 */

/**
 * Callbacks per WebContents, keyed by owner. The presence of an entry also
 * records that a real listener is already attached. Weak, so a closed window's
 * entry goes away with it.
 */
const registry = new WeakMap<WebContents, Map<string, () => void>>()

/**
 * Run `callback` when `contents` is destroyed, once per `key`.
 *
 * `key` identifies the registration, not the contents — a module-scoped
 * constant like `'plan-limit'`. Re-registering replaces the callback, so the
 * latest closure wins and the count stays at one.
 *
 * Already-destroyed contents run the callback immediately: `once('destroyed')`
 * on a dead emitter never fires, and a caller that registered a moment too late
 * would otherwise hold its resource forever. Immediate is the same answer, just
 * sooner.
 */
export function onWebContentsDestroyed(
  contents: WebContents,
  key: string,
  callback: () => void,
): void {
  if (contents.isDestroyed()) {
    runQuietly(callback)
    return
  }

  let callbacks = registry.get(contents)
  if (!callbacks) {
    callbacks = new Map()
    registry.set(contents, callbacks)
    const owned = callbacks
    contents.once('destroyed', () => {
      registry.delete(contents)
      // Copied before iterating: a callback is free to unregister another, and
      // several do — releasing a shared entry can drop its siblings.
      for (const run of [...owned.values()]) runQuietly(run)
      owned.clear()
    })
  }

  callbacks.set(key, callback)
}

/** Drop a registration early, when the module has already let go by itself. */
export function offWebContentsDestroyed(contents: WebContents, key: string): void {
  registry.get(contents)?.delete(key)
}

/** Which owners are still waiting on this WebContents. For tests. */
export function pendingTeardowns(contents: WebContents): string[] {
  return [...(registry.get(contents)?.keys() ?? [])].sort()
}

function runQuietly(callback: () => void): void {
  try {
    callback()
  } catch (error) {
    // Reported, not thrown: this runs while a window is going away, and the
    // remaining callbacks still have resources to release.
    console.error('[teardown] a destroyed handler threw:', error)
  }
}
