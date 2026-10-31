/**
 * The parts of Electron's renderer-side API that `src/preload/index.ts` uses,
 * rebuilt over the HTTP bridge in `bridge.ts`.
 *
 * The preload is not copied or rewritten for the native window. It is compiled
 * as it is, with `electron` pointed at `electron.ts` (which builds these), so
 * `window.deck` there is the same object, method for method, that the Electron
 * window gets — and a method added to the preload tomorrow arrives in both.
 */

import type { Transport } from './bridge'

/**
 * What a listener gets as its first argument, standing in for Electron's
 * `IpcRendererEvent`. Every listener in the preload ignores it (`_e`), but the
 * slot has to be filled or every payload would arrive one argument early.
 */
export interface IpcEventStub {
  sender: IpcRendererShim
  senderId: number
  ports: never[]
}

export type IpcListener = (event: IpcEventStub, ...args: unknown[]) => void

export interface IpcRendererShim {
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  send(channel: string, ...args: unknown[]): void
  sendSync(channel: string, ...args: unknown[]): unknown
  on(channel: string, listener: IpcListener): IpcRendererShim
  addListener(channel: string, listener: IpcListener): IpcRendererShim
  once(channel: string, listener: IpcListener): IpcRendererShim
  off(channel: string, listener: IpcListener): IpcRendererShim
  removeListener(channel: string, listener: IpcListener): IpcRendererShim
  removeAllListeners(channel?: string): IpcRendererShim
  listenerCount(channel: string): number
}

interface Entry {
  listener: IpcListener
  once: boolean
}

/**
 * `ipcRenderer`, and the `dispatch` the event stream feeds it through.
 *
 * Listener bookkeeping follows Node's `EventEmitter`, which is what Electron's
 * `ipcRenderer` is: the same function may be added twice and is then called
 * twice; `off` removes the most recently added copy; a `once` listener can be
 * removed by the function that was passed in; and a listener added or removed
 * while an event is being delivered does not change who hears *that* event.
 *
 * One deliberate difference: a listener that throws does not stop the ones
 * after it. Under `EventEmitter` the rest of that event would be lost; here the
 * error is still reported, as an uncaught error, through `report`.
 */
export function createIpcRenderer(
  transport: Transport,
  report: (error: unknown) => void = defaultReport,
): { ipcRenderer: IpcRendererShim; dispatch(channel: string, args: readonly unknown[]): void } {
  const listeners = new Map<string, Entry[]>()

  const add = (channel: string, listener: IpcListener, once: boolean): void => {
    const entries = listeners.get(channel) ?? []
    entries.push({ listener, once })
    listeners.set(channel, entries)
  }

  const remove = (channel: string, listener: IpcListener): void => {
    const entries = listeners.get(channel)
    if (!entries) return
    for (let at = entries.length - 1; at >= 0; at--) {
      if (entries[at].listener === listener) {
        entries.splice(at, 1)
        break
      }
    }
    if (entries.length === 0) listeners.delete(channel)
  }

  const ipcRenderer: IpcRendererShim = {
    invoke: (channel, ...args) => transport.invoke(channel, args),
    send: (channel, ...args) => transport.send(channel, args),
    sendSync: (channel, ...args) => transport.sendSync(channel, args),
    on(channel, listener) {
      add(channel, listener, false)
      return ipcRenderer
    },
    addListener(channel, listener) {
      add(channel, listener, false)
      return ipcRenderer
    },
    once(channel, listener) {
      add(channel, listener, true)
      return ipcRenderer
    },
    off(channel, listener) {
      remove(channel, listener)
      return ipcRenderer
    },
    removeListener(channel, listener) {
      remove(channel, listener)
      return ipcRenderer
    },
    removeAllListeners(channel) {
      if (channel === undefined) listeners.clear()
      else listeners.delete(channel)
      return ipcRenderer
    },
    listenerCount: (channel) => listeners.get(channel)?.length ?? 0,
  }

  const event: IpcEventStub = { sender: ipcRenderer, senderId: 0, ports: [] }

  const dispatch = (channel: string, args: readonly unknown[]): void => {
    const entries = listeners.get(channel)
    if (!entries) return
    for (const entry of [...entries]) {
      if (entry.once) remove(channel, entry.listener)
      try {
        entry.listener(event, ...args)
      } catch (error) {
        report(error)
      }
    }
  }

  return { ipcRenderer, dispatch }
}

function defaultReport(error: unknown): void {
  const host = globalThis as { reportError?: (error: unknown) => void }
  if (typeof host.reportError === 'function') host.reportError(error)
  else
    setTimeout(() => {
      throw error
    }, 0)
}

/**
 * `contextBridge`, for a page with one world.
 *
 * Electron's version copies the API across from the isolated world the preload
 * runs in. Here the shim *is* the page's world, so exposing is assignment — and
 * it keeps Electron's one refusal: binding over a name the window already has
 * throws, rather than silently replacing it.
 */
export function createContextBridge(host: Record<string, unknown>): {
  exposeInMainWorld(apiKey: string, api: unknown): void
} {
  return {
    exposeInMainWorld(apiKey, api) {
      if (apiKey in host) throw new Error('Cannot bind an API on top of an existing property on the window object')
      host[apiKey] = api
    },
  }
}
