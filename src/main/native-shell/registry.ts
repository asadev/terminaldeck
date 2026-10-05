/**
 * Every `ipcMain.handle` this process registers, callable from the bridge.
 *
 * ## Why a tap, and why it goes first
 *
 * `ipcMain` offers no public way to call a handler: a handler is reached by a
 * renderer's `invoke` and nothing else. So the registry replaces `handle` and
 * `removeHandler` on the instance — both are own properties or prototype
 * methods that an assignment shadows, and `handleOnce` calls through
 * `this.handle` / `this.removeHandler`, so it is covered for free — and keeps
 * the listener it was given.
 *
 * It is installed at module scope in `index.ts`, before `registerIpc()` runs,
 * so every later layer (`ipc-trace.ts`, `diagnostics.ts`, the deck-control
 * channel tap) wraps *this* `handle`, and what the registry keeps is the fully
 * wrapped listener: a call over the bridge is traced, timed and tapped exactly
 * like a call from a window.
 *
 * ## The fallback
 *
 * A channel registered before the tap — there are none today — is read off
 * Electron's own map, `_invokeHandlers`, the same internal `diagnostics.ts`
 * already reads (verified there against the Electron 41 binary in this repo).
 * Electron 41 keeps the raw listener in that map; an older shape that answered
 * through `event._reply` / `event._throw` is honoured too.
 *
 * `ipcMain.on` listeners need no tap: `ipcMain` is an `EventEmitter`, and
 * `emit(channel, event, ...args)` is exactly how Electron delivers a `send`.
 */

export type IpcListener = (event: unknown, ...args: unknown[]) => unknown

/** The parts of `ipcMain` this touches — narrow, so a test can hand in a fake. */
export interface TappableIpcMain {
  handle(channel: string, listener: IpcListener): unknown
  removeHandler(channel: string): unknown
  emit(eventName: string | symbol, ...args: unknown[]): boolean
  listenerCount(eventName: string | symbol): number
}

export interface HandlerRegistry {
  /** Replace `handle` / `removeHandler` on this `ipcMain`. Once per instance. */
  tap(ipcMain: TappableIpcMain): void
  /** Is there an invoke handler for this channel? */
  has(channel: string): boolean
  /** Call the invoke handler, as a renderer's `invoke` would. Rejects like Electron when there is none. */
  invoke(channel: string, event: object, args: readonly unknown[]): Promise<unknown>
  /** Deliver to `ipcMain.on` listeners, as a renderer's `send` would. False when nobody listens. */
  send(channel: string, event: object, args: readonly unknown[]): boolean
}

/**
 * Names the bridge will not touch, whatever is asked: Electron's own internal
 * channels, and the `EventEmitter` bookkeeping events, which are not channels.
 */
export function isBridgeChannel(channel: unknown): channel is string {
  if (typeof channel !== 'string') return false
  if (channel.length === 0 || channel.length > 200) return false
  if (/[\s\0]/.test(channel)) return false
  if (channel.startsWith('-') || channel.startsWith('ELECTRON_')) return false
  return channel !== 'error' && channel !== 'newListener' && channel !== 'removeListener'
}

export function createHandlerRegistry(): HandlerRegistry {
  const handlers = new Map<string, IpcListener>()
  const tapped = new WeakSet<object>()
  let target: TappableIpcMain | null = null

  /** Electron's own map, or null when this Electron does not have one by that name. */
  function internal(): Map<string, unknown> | null {
    const map = (target as unknown as { _invokeHandlers?: unknown } | null)?._invokeHandlers
    return map instanceof Map ? (map as Map<string, unknown>) : null
  }

  return {
    tap(ipcMain) {
      if (tapped.has(ipcMain)) return
      tapped.add(ipcMain)
      target = ipcMain
      const handle = ipcMain.handle.bind(ipcMain)
      const removeHandler = ipcMain.removeHandler.bind(ipcMain)
      ipcMain.handle = (channel: string, listener: IpcListener): unknown => {
        // Electron's `handle` throws on a second registration; let it decide
        // before this map changes, so the two can never disagree.
        const result = handle(channel, listener)
        handlers.set(channel, listener)
        return result
      }
      ipcMain.removeHandler = (channel: string): unknown => {
        handlers.delete(channel)
        return removeHandler(channel)
      }
    },

    has(channel) {
      return handlers.has(channel) || internal()?.has(channel) === true
    },

    async invoke(channel, event, args) {
      const own = handlers.get(channel)
      if (own !== undefined) return await own(event, ...args)
      const fallback = internal()?.get(channel)
      if (typeof fallback !== 'function') throw new Error(`No handler registered for '${channel}'`)
      // The older Electron shape answered through the event rather than returning.
      let replied: { value: unknown } | { error: unknown } | null = null
      const withReply = Object.assign(Object.create(event) as object, {
        _reply: (value: unknown) => {
          replied = { value }
        },
        _throw: (error: unknown) => {
          replied = { error }
        },
      })
      const returned = await (fallback as IpcListener)(withReply, ...args)
      const settled = replied as { value: unknown } | { error: unknown } | null
      if (settled === null) return returned
      if ('error' in settled) throw settled.error
      return settled.value
    },

    send(channel, event, args) {
      if (target === null || target.listenerCount(channel) === 0) return false
      target.emit(channel, event, ...args)
      return true
    },
  }
}
