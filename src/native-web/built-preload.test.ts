import { resolve } from 'node:path'
import { createContext, runInContext } from 'node:vm'
import { build, type Rollup } from 'vite'
import { beforeAll, describe, expect, it, vi } from 'vitest'

/**
 * The bundle the native window loads exposes the same `window.deck` as the
 * preload source — proved on the built output, not on the modules it came from.
 *
 * The source side: `src/preload/index.ts` is imported here with `electron`
 * mocked, and whatever it passes to `exposeInMainWorld('deck', …)` is the
 * reference. The built side: `vite.native-web.config.ts` is run (in memory,
 * nothing written) and the IIFE is evaluated in a bare VM context that has only
 * what a WKWebView page has — `fetch`, `EventSource`, a `document` — with fakes
 * for each. If the `electron` alias stopped resolving, if the preload stopped
 * being bundled whole, or if the shim's `contextBridge` lost a method on the
 * way, the two key lists would differ here.
 *
 * Then two calls are made through the built `window.deck` to prove it is wired
 * to the bridge and not merely shaped like it: an invoke that must reach
 * `POST /__td/invoke`, and a subscription that must hear an SSE push.
 */

const reference = vi.hoisted(() => ({ name: '', api: null as Record<string, unknown> | null }))

vi.mock('electron', () => ({
  contextBridge: {
    exposeInMainWorld: (name: string, api: Record<string, unknown>) => {
      reference.name = name
      reference.api = api
    },
  },
  ipcRenderer: { invoke: () => Promise.resolve(), send: () => {}, on: () => {}, off: () => {} },
  webUtils: { getPathForFile: () => '' },
}))

const ROOT = resolve(__dirname, '../..')

interface Request {
  url: string
  body: { channel: string; args: unknown[] }
}

interface Sandbox {
  deck?: Record<string, unknown>
  tdNative?: { run(name: string): boolean }
  document: { documentElement: { dataset: Record<string, string | undefined> } }
}

let bundle = ''
const requests: Request[] = []
const sources: Array<{ url: string; onmessage: ((event: { data: string }) => void) | null }> = []
let page: Sandbox

beforeAll(async () => {
  const output = await build({
    configFile: resolve(ROOT, 'vite.native-web.config.ts'),
    root: ROOT,
    logLevel: 'silent',
    build: { write: false, sourcemap: false, emptyOutDir: false },
  })
  const results = (Array.isArray(output) ? output : [output]) as Rollup.RollupOutput[]
  const chunks = results.flatMap((result) => result.output).filter((item): item is Rollup.OutputChunk => item.type === 'chunk')
  expect(chunks.map((chunk) => chunk.fileName)).toEqual(['shim.js'])
  bundle = chunks[0].code

  await import('../preload/index')

  class FakeEventSource {
    onopen = null
    onmessage: ((event: { data: string }) => void) | null = null
    onerror = null
    constructor(readonly url: string) {
      sources.push(this)
    }
    close() {}
  }
  const sandbox = {
    console,
    setTimeout,
    clearTimeout,
    btoa,
    atob,
    fetch: async (url: string, init: { body: string }) => {
      requests.push({ url, body: JSON.parse(init.body) as Request['body'] })
      return { status: 200, text: async () => JSON.stringify({ ok: true, value: { name: 'Terminal Deck', tagline: 't' } }) }
    },
    EventSource: FakeEventSource,
    // What a WKWebView page has and the shim's page features reach for.
    EventTarget,
    Event,
    URL,
    URLSearchParams,
    location: { href: 'http://127.0.0.1:4000/', origin: 'http://127.0.0.1:4000', search: '' },
    addEventListener: () => {},
    document: {
      documentElement: { dataset: {} },
      title: 'Terminal Deck',
      readyState: 'complete',
      head: null,
      addEventListener: () => {},
    },
  }
  createContext(sandbox)
  runInContext(bundle, sandbox, { filename: 'shim.js' })
  page = sandbox as unknown as Sandbox
}, 60_000)

describe('the built shim', () => {
  it('is one classic script with nothing left that asks for Electron or Node', () => {
    expect(bundle).not.toMatch(/\brequire\(/)
    expect(bundle).not.toMatch(/from\s+["']electron["']/)
    expect(bundle).not.toMatch(/^\s*(import|export)\s/m)
  })

  it('exposes window.deck with exactly the keys the preload source exposes', () => {
    expect(reference.name).toBe('deck')
    const source = reference.api
    expect(source).not.toBeNull()
    const built = page.deck
    expect(built).toBeDefined()
    const sourceKeys = Object.keys(source ?? {})
    expect(sourceKeys.length).toBeGreaterThan(400)
    expect(Object.keys(built ?? {})).toEqual(sourceKeys)
    const kinds = (api: Record<string, unknown>) => Object.fromEntries(Object.entries(api).map(([key, value]) => [key, typeof value]))
    expect(kinds(built ?? {})).toEqual(kinds(source ?? {}))
  })

  it('marks the page as the native shell and leaves an early tdNative', () => {
    expect(page.document.documentElement.dataset.shell).toBe('native')
    expect(page.tdNative?.run('new-session')).toBe(false)
  })

  it('backs the Notification API and takes window.open, through the bundle', () => {
    const host = page as unknown as { Notification?: { permission?: string }; open?: unknown }
    expect(host.Notification?.permission).toBe('granted')
    expect(typeof host.open).toBe('function')
  })

  it('sends an invoke through POST /__td/invoke and resolves with the engine’s value', async () => {
    const getBrand = page.deck?.getBrand as () => Promise<unknown>
    const brand = await getBrand()
    expect(JSON.parse(JSON.stringify(brand))).toEqual({ name: 'Terminal Deck', tagline: 't' })
    expect(requests.at(-1)).toEqual({ url: '/__td/invoke', body: { channel: 'brand:get', args: [] } })
  })

  it('hears an engine push on the one event stream, through the preload’s own subscription', () => {
    expect(sources.map((source) => source.url)).toEqual(['/__td/events'])
    const heard: unknown[] = []
    const onPreferencesChanged = page.deck?.onPreferencesChanged as (cb: (value: unknown) => void) => () => void
    const unsubscribe = onPreferencesChanged((value) => heard.push(JSON.parse(JSON.stringify(value))))
    sources[0].onmessage?.({ data: JSON.stringify({ channel: 'prefs:changed', args: [{ theme: 'light' }] }) })
    unsubscribe()
    sources[0].onmessage?.({ data: JSON.stringify({ channel: 'prefs:changed', args: [{ theme: 'dark' }] }) })
    expect(heard).toEqual([{ theme: 'light' }])
  })
})
