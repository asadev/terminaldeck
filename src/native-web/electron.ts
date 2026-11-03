/**
 * What `import … from 'electron'` means inside the native window's build.
 *
 * `vite.native-web.config.ts` aliases the bare specifier `electron` to this
 * file, so when `src/preload/index.ts` imports `contextBridge`, `ipcRenderer`
 * and `webUtils` it gets these — built over the engine's HTTP bridge — and runs
 * unchanged. Nothing imports this file by name; the alias is the only way in
 * (which is why `reachable.test.ts` lists it as an entry).
 *
 * Evaluating this module opens the one event stream the window has. That is on
 * purpose: React subscribes within the first frames, and a stream that only
 * opened on the first `on()` would race the engine's first pushes.
 */

import { createTransport, openEventStream, type StreamHost, type TransportHost } from './bridge'
import { createDrops, type DropHost } from './drops'
import { createContextBridge, createIpcRenderer, type IpcEventStub } from './ipc-renderer'
import type { BridgeHooks } from './page-features'

/*
 * The page's own globals, typed by the bridge's needs rather than by the DOM
 * library: this file is compiled with the preload (`tsconfig.node.json`), which
 * has no DOM types to offer.
 */
const page = globalThis as unknown as Record<string, unknown> & {
  fetch: TransportHost['fetch']
  XMLHttpRequest?: TransportHost['XMLHttpRequest']
  EventSource: StreamHost['EventSource']
}

/**
 * Where the shim's page features (`page-features.ts`) take an invoke or a push
 * over before it reaches the engine or the page — a menu answered natively, a
 * link handed to the native browser. Empty until the shim's entry fills them in,
 * which it does before any of the page's own code runs.
 */
export const bridgeHooks: BridgeHooks = { invoke: null, push: null }

const transport = createTransport({
  // Wrapped, never passed bare: `fetch` called as a method of some other
  // object throws "Illegal invocation" in WebKit.
  fetch: (input, init) => page.fetch(input, init),
  ...(page.XMLHttpRequest ? { XMLHttpRequest: page.XMLHttpRequest } : {}),
})

const bridge = createIpcRenderer({
  ...transport,
  invoke: (channel, args) => bridgeHooks.invoke?.(channel, args) ?? transport.invoke(channel, args),
})

openEventStream(
  {
    EventSource: page.EventSource,
    setTimeout: (callback, ms) => setTimeout(callback, ms),
    clearTimeout: (handle) => clearTimeout(handle as ReturnType<typeof setTimeout>),
  },
  (channel, args) => {
    if (bridgeHooks.push?.(channel, args) === true) return
    bridge.dispatch(channel, args)
  },
)

/** Files dropped on the native window, replayed into the page with their paths (`drops.ts`). */
export const drops = createDrops(page as unknown as DropHost)

export const ipcRenderer = bridge.ipcRenderer
export const contextBridge = createContextBridge(page)
/**
 * The path behind a dropped `File`: a WKWebView gives none, so this answers for
 * the files `drops.ts` replays from the native window's drop, and '' for any
 * other — the same answer the preload already gives a drag of text.
 */
export const webUtils = { getPathForFile: (file: unknown): string => drops.pathFor(file) }

/** The preload names this type in its listeners' signatures; it is erased at build time. */
export type IpcRendererEvent = IpcEventStub
