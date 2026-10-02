/**
 * The window's own channels, reachable from a tool — the same handlers, called
 * in-process, with nothing re-implemented.
 *
 * ## Why this exists
 *
 * Asad's words for 0.16.0 were *"everything that I can do manually should be
 * able to do through the MCP."* Most of what a person does with other machines,
 * servers and paired devices lives inside three registrations —
 * `registerMachinesIpc`, `registerServersIpc` and `registerRemoteIpc` — and the
 * state those handlers act on is private to them on purpose: the link map, the
 * open shells, the setup attempts, the pairing desk. Exporting each of those so a
 * tool could reach the same object would be dozens of new seams in files other
 * work depends on, and writing the bodies again beside the tools would be the
 * second implementation this whole layer exists to prevent — *"two answers to
 * the same question, and the two would drift within a release."*
 *
 * The headless build already solved exactly this problem, and the answer is
 * small enough to say in a sentence. `headless/desk.ts`: *"a Map from channel
 * name to the same function, called in-process… When somebody fixes pairing,
 * both shells get the fix, because there is one copy of it and neither shell
 * owns it."* This is that Map, kept beside Electron's `ipcMain` instead of in
 * place of it. `ipc-trace.ts` already wraps `ipcMain.handle` and `ipcMain.on` the
 * same way at the same moment, for the same reason: it is the one point every
 * registration passes through.
 *
 * So a tool that wants "connect to that machine" calls `machines:connect`, and
 * gets the same validation, the same link lookup, the same broadcast and the
 * same answer the button gets — because it is the button's code.
 *
 * ## What it is not
 *
 * **Not a door the copilot can see.** Nothing here is a tool. A tool factory
 * gets a *typed* function over a closed list of channels (`ChannelCall` below),
 * and the factory decides — with a tier, a precheck and a consent sentence —
 * whether a call happens at all. The tap is the wire, not the permission.
 *
 * **Not a trust boundary in either direction.** Handlers in this codebase all
 * name their first parameter `_event` and never read it, for the reason the
 * headless desk gives: *"a main-process handler that trusts its sender is a
 * handler that can be called by any code running in that window."* That is what
 * makes passing `null` for the event the honest value. A handler that ever starts
 * reading the sender breaks the desk and this together, which is the right
 * failure: loudly, in two places, rather than quietly in one.
 *
 * ## The two other things it watches, and why
 *
 * **Pushes.** Some answers arrive afterwards, as a main→window message rather
 * than as a return value: a session's output on another machine, the far
 * copilot's conversation, a new session appearing in a machine's list. A tool
 * that started a session over there and could only be told `true` — *"the
 * request left this machine"* — would have to guess the new session's id. So the
 * one function in `index.ts` that sends anything to the window, `send`, tells the
 * tap first, and a tool can wait for the push it is owed instead of polling for
 * it (the standing rule is events, not polling).
 *
 * **Invocations.** A remote session's screen is a terminal whose size the window
 * chose when it attached — `machines:attach(id, session, cols, rows)` — and a
 * shadow terminal fed the same bytes at a different size draws a different
 * screen. `session-activity.ts` warns about exactly this: a second terminal
 * *"would drift the moment a resize was missed."* So the sizes are not guessed:
 * every call that reaches a handler, from the window or from a tool, is reported
 * to whoever listens, with its arguments, before the handler runs.
 */

/** What every handler in this codebase looks like from the outside. */
export type ChannelListener = (event: unknown, ...args: unknown[]) => unknown

/**
 * The two methods of Electron's `IpcMain` that registrations use.
 *
 * Structural rather than imported, so this file and its test need no Electron —
 * the same reason `ipc-seam.ts` exists. Method syntax on purpose: Electron's own
 * listener types take `IpcMainInvokeEvent`, and a method parameter accepts that
 * where a function-typed property would refuse it.
 */
export interface TappableIpc {
  handle(channel: string, listener: ChannelListener): unknown
  on(channel: string, listener: ChannelListener): unknown
}

export interface ChannelTap {
  /**
   * Start keeping every handler registered on this `ipcMain` from now on.
   *
   * Call once, before the registrations it should see — immediately after
   * `traceIpc` in `registerIpc()`. A second call on the same object is refused,
   * because two layers of this wrapper would report every invocation twice.
   */
  attach(ipcMain: TappableIpc): void
  /**
   * Call a channel's handler the way the window would, and answer what it answered.
   *
   * Always a promise, because some handlers are async and a caller that had to
   * know which is a caller that will one day be wrong. Throws a plain sentence for
   * a channel nothing registered — a missing registration, never "unsupported".
   */
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  /** Is there a handler for this channel? */
  has(channel: string): boolean
  /** The window was sent this. Called by `send` in `index.ts`, before anything else it does. */
  pushed(channel: string, args: readonly unknown[]): void
  /** Hear every push on one channel. Answers the unsubscribe. */
  onPush(channel: string, listener: (payload: unknown) => void): () => void
  /**
   * The next push on a channel whose first argument passes `matches`, or null at the deadline.
   *
   * Subscribed *before* the caller acts, by taking the action as `after`, so a
   * push that lands in the same tick as the call that caused it is not missed —
   * the race every "wait for the event" helper has, closed in the one place.
   */
  nextPush(
    channel: string,
    matches: (payload: unknown) => boolean,
    ceilingMs: number,
    after?: () => unknown,
  ): Promise<unknown | null>
  /** Hear every call that reaches a handler — from the window or from a tool. */
  onInvoke(listener: (channel: string, args: readonly unknown[]) => void): () => void
}

/**
 * One tap per process. Module-level in `index.ts`, because `send` — the push
 * half — is a module-level function there and runs before `registerIpc` does.
 */
export function createChannelTap(): ChannelTap {
  const handlers = new Map<string, ChannelListener>()
  const pushListeners = new Map<string, Set<(payload: unknown) => void>>()
  const invokeListeners = new Set<(channel: string, args: readonly unknown[]) => void>()
  const attached = new WeakSet<object>()

  /*
   * Listeners are told inside a try, every one of them, because the thing being
   * observed is somebody's real IPC call. A screen tracker that threw on a
   * malformed payload must cost that tracker its update — never the window its
   * answer, and never the next listener its turn.
   */
  const tellInvoke = (channel: string, args: readonly unknown[]): void => {
    for (const listener of [...invokeListeners]) {
      try {
        listener(channel, args)
      } catch (error) {
        console.error(`[channel-tap] an invocation listener threw on ${channel}:`, error)
      }
    }
  }

  function onPush(channel: string, listener: (payload: unknown) => void): () => void {
    const listeners = pushListeners.get(channel) ?? new Set()
    listeners.add(listener)
    pushListeners.set(channel, listeners)
    return () => {
      listeners.delete(listener)
      if (listeners.size === 0) pushListeners.delete(channel)
    }
  }

  return {
    attach(ipcMain) {
      if (attached.has(ipcMain)) {
        throw new Error('The channel tap is already attached to this ipcMain; a second layer would report every call twice.')
      }
      attached.add(ipcMain)
      const handle = ipcMain.handle.bind(ipcMain)
      const on = ipcMain.on.bind(ipcMain)
      /*
       * The listener is kept *unwrapped*, and the wrapper only goes to Electron.
       * A tool's own call reports itself in `invoke` below, so wrapping what is
       * kept as well would report a tool's call twice.
       */
      const wrap =
        (channel: string, listener: ChannelListener): ChannelListener =>
        (event, ...args) => {
          tellInvoke(channel, args)
          return listener(event, ...args)
        }
      ipcMain.handle = (channel: string, listener: ChannelListener): unknown => {
        handlers.set(channel, listener)
        return handle(channel, wrap(channel, listener))
      }
      ipcMain.on = (channel: string, listener: ChannelListener): unknown => {
        // `on` channels can carry more than one listener in Electron. The ones
        // a tool reaches (`github:clear-cache`) carry one; keep the first, so a
        // later diagnostic listener cannot silently replace the real one.
        if (!handlers.has(channel)) handlers.set(channel, listener)
        return on(channel, wrap(channel, listener))
      }
    },

    async invoke(channel, ...args) {
      const handler = handlers.get(channel)
      if (handler === undefined) {
        throw new Error(
          `Nothing in this app answers "${channel}". The registration that owns it has not run, ` +
            'or the tap was attached after it — a wiring fault, not an unsupported action.',
        )
      }
      tellInvoke(channel, args)
      return await handler(null, ...args)
    },

    has: (channel) => handlers.has(channel),

    pushed(channel, args) {
      const listeners = pushListeners.get(channel)
      if (listeners === undefined) return
      for (const listener of [...listeners]) {
        try {
          listener(args[0])
        } catch (error) {
          console.error(`[channel-tap] a push listener threw on ${channel}:`, error)
        }
      }
    },

    onPush,

    async nextPush(channel, matches, ceilingMs, after) {
      let stop = (): void => undefined
      const heard = new Promise<unknown | null>((resolve) => {
        const timer = setTimeout(() => {
          stop()
          resolve(null)
        }, ceilingMs)
        timer.unref?.()
        const unsubscribe = onPush(channel, (payload) => {
          if (!matches(payload)) return
          stop()
          resolve(payload)
        })
        stop = () => {
          clearTimeout(timer)
          unsubscribe()
        }
      })
      try {
        await after?.()
      } catch (error) {
        stop()
        throw error
      }
      return heard
    },

    onInvoke(listener) {
      invokeListeners.add(listener)
      return () => {
        invokeListeners.delete(listener)
      }
    },
  }
}

/**
 * A typed call over a closed list of channels.
 *
 * What a tool factory takes instead of the tap: `M` names each channel it may
 * reach, the arguments that channel takes and the shape it answers. A factory
 * cannot name a channel outside its map, and a test fakes exactly the channels
 * it exercises — the narrow-deps rule, kept without writing a wrapper function
 * per channel.
 */
export type ChannelMap = Record<string, { args: readonly unknown[]; result: unknown }>

export type ChannelCall<M extends ChannelMap> = <C extends keyof M & string>(
  channel: C,
  ...args: M[C]['args']
) => Promise<M[C]['result']>

/**
 * The tap, narrowed to one map.
 *
 * The cast is the one place this layer trusts a handler's declared return type,
 * and it is the same trust the preload extends to the same handlers: every
 * `invoke` there answers `Promise<unknown>` and the renderer narrows it. Fields a
 * tool *reads* off an answer are re-checked where they are read.
 */
export function channelCall<M extends ChannelMap>(tap: Pick<ChannelTap, 'invoke'>): ChannelCall<M> {
  return ((channel: string, ...args: unknown[]) => tap.invoke(channel, ...args)) as ChannelCall<M>
}
