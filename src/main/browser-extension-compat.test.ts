import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import {
  COMPAT_FILE,
  COMPAT_SHIM,
  applyCompat,
  compatProvides,
  compatShimFor,
  enabledRulesetIds,
  injectIntoHtml,
  planCompat,
  prependLine,
  setCompatRuntime,
} from './browser-extension-compat'
import type { ExtensionManifest } from './browser-extension-support'

/**
 * The compatibility layer, held to the shape the measurements demanded.
 *
 * Every case below is a fact that was watched on Electron 41.10.5 before it was
 * a test — the header of `browser-extension-compat.ts` has the runs. Two of them
 * are bugs this file caught only after they had shipped into a measurement and
 * produced a wrong verdict, and both are named where they are asserted, because
 * a regression test whose reason is not written down is a line somebody deletes
 * next year.
 */

function dir(): string {
  return mkdtempSync(join(tmpdir(), 'td-compat-'))
}

function write(root: string, relative: string, body: string): void {
  const file = join(root, relative)
  mkdirSync(join(file, '..'), { recursive: true })
  writeFileSync(file, body, 'utf8')
}

describe('what the layer decides to provide', () => {
  it('gives storage.sync to anything that asked for storage', () => {
    const manifest: ExtensionManifest = { manifest_version: 3, permissions: ['storage'] }
    expect(compatProvides(manifest)).toContain('storage.sync')
  })

  it('withholds storage.sync from an extension that never asked for storage', () => {
    expect(compatProvides({ manifest_version: 3, permissions: ['tabs'] })).not.toContain(
      'storage.sync',
    )
  })

  it('gives permissions and windows to everything, because Chrome does', () => {
    /*
     * The bug this pins. The first draft keyed every namespace off the manifest's
     * `permissions` array, and `chrome.permissions` needs no permission — so the
     * layer defined nothing and uBlock Origin Lite went on dying on the first
     * line of `browser.permissions.onRemoved.addListener`, exactly as it had
     * without the layer at all.
     */
    const bare: ExtensionManifest = { manifest_version: 3, permissions: [] }
    expect(compatProvides(bare)).toEqual(expect.arrayContaining(['permissions', 'windows']))
  })

  it('gives commands to an extension with a commands block and no commands permission', () => {
    const manifest = {
      manifest_version: 3,
      permissions: [],
      commands: { 'open-thing': { description: 'Open the thing' } },
    } as unknown as ExtensionManifest
    expect(compatProvides(manifest)).toContain('commands')
    expect(compatProvides({ manifest_version: 3, permissions: [] })).not.toContain('commands')
  })

  it('gives browserAction only to manifest v2, because v3 has chrome.action for real', () => {
    const two: ExtensionManifest = { manifest_version: 2, browser_action: { default_popup: 'p.html' } }
    const three: ExtensionManifest = { manifest_version: 3, action: { default_popup: 'p.html' } }
    expect(compatProvides(two)).toContain('browserAction')
    expect(compatProvides(three)).not.toContain('browserAction')
  })

  it('never provides a namespace that would have to invent data', () => {
    const greedy: ExtensionManifest = {
      manifest_version: 3,
      permissions: ['cookies', 'history', 'downloads', 'bookmarks', 'topSites'],
    }
    const provided = compatProvides(greedy)
    for (const invented of ['cookies', 'history', 'downloads', 'bookmarks', 'topSites']) {
      expect(provided).not.toContain(invented)
    }
  })
})

describe('static rulesets', () => {
  it('reads only the resources the manifest marks enabled', () => {
    const manifest: ExtensionManifest = {
      manifest_version: 3,
      declarative_net_request: {
        rule_resources: [
          { id: 'on', enabled: true, path: 'a.json' },
          { id: 'off', enabled: false, path: 'b.json' },
          { id: '', enabled: true, path: 'c.json' },
        ],
      },
    }
    expect(enabledRulesetIds(manifest)).toEqual(['on'])
  })

  it('compiles the ids into the layer, leaving no placeholder behind', () => {
    const plan = planCompat({
      manifest_version: 3,
      permissions: ['storage'],
      background: { service_worker: 'bg.js' },
      declarative_net_request: { rule_resources: [{ id: 'ruleset_1', enabled: true, path: 'r.json' }] },
    })
    const text = compatShimFor(plan)
    expect(text).toContain('["ruleset_1"]')
    expect(text).not.toContain('__TD_RULESETS__')
    expect(COMPAT_SHIM).toContain('__TD_RULESETS__')
  })
})

describe('where the layer goes', () => {
  it('finds a manifest v3 service worker', () => {
    const plan = planCompat({
      manifest_version: 3,
      permissions: ['storage'],
      background: { service_worker: '/js/background.js', type: 'module' },
    })
    expect(plan.background).toBe('worker')
    expect(plan.backgroundPath).toBe('/js/background.js')
  })

  it('finds a manifest v2 background page and a manifest v2 script list', () => {
    expect(planCompat({ manifest_version: 2, background: { page: 'background.html' } }).background).toBe(
      'page',
    )
    expect(planCompat({ manifest_version: 2, background: { scripts: ['a.js'] } }).background).toBe(
      'scripts',
    )
  })

  it('skips a MAIN-world content script', () => {
    /*
     * A `"world": "MAIN"` script runs in the page's own context with no `chrome`
     * in it. Prepending a file that reads `chrome.storage` there would put a
     * thrown error into every page the extension touches — a new failure
     * invented by the thing meant to remove one. SponsorBlock ships exactly this
     * shape.
     */
    const plan = planCompat({
      manifest_version: 3,
      permissions: ['storage'],
      background: { service_worker: 'bg.js' },
      content_scripts: [
        { world: 'MAIN', js: ['page.js'], matches: ['https://*/*'] },
        { world: 'ISOLATED', js: ['content.js'], matches: ['https://*/*'] },
        { js: ['default-world.js'], matches: ['https://*/*'] },
      ],
    })
    expect(plan.contentScripts).toEqual([1, 2])
  })

  it('takes the popup and the options page and nothing else', () => {
    const plan = planCompat({
      manifest_version: 3,
      permissions: ['storage'],
      background: { service_worker: 'bg.js' },
      action: { default_popup: '/data/menu/index.html' },
      options_ui: { page: 'options.html' },
    } as unknown as ExtensionManifest)
    expect(plan.pages).toEqual(['data/menu/index.html', 'options.html'])
  })

  it('writes nothing when there is nowhere to put it', () => {
    // No background, no content script, no popup: the layer has no entry point,
    // so it stays off the disk rather than being written where nothing loads it.
    const nowhere = planCompat({ manifest_version: 3, permissions: [] })
    expect(nowhere.background).toBe('none')
    expect(nowhere.empty).toBe(true)
    // The same manifest with somewhere to go is not empty.
    expect(planCompat({ manifest_version: 3, permissions: [], background: { service_worker: 'b.js' } }).empty).toBe(false)
  })
})

describe('the two text edits', () => {
  it('puts the layer before a page’s first script, not after it', () => {
    const html = '<!DOCTYPE html>\n<body>\n<script src="a.js"></script>\n<script src="b.js"></script>\n'
    const out = injectIntoHtml(html, COMPAT_FILE)
    expect(out.indexOf(COMPAT_FILE)).toBeLessThan(out.indexOf('a.js'))
  })

  it('falls back to the end of the body, then to the front of the file', () => {
    expect(injectIntoHtml('<body><p>hi</p></body>', 'x.js')).toContain('<script src="x.js"></script>')
    expect(injectIntoHtml('<p>hi</p>', 'x.js').startsWith('<script')).toBe(true)
  })

  it('keeps a byte order mark at the front of a module', () => {
    const out = prependLine('﻿export const a = 1', "import './x.js';")
    expect(out.startsWith('﻿')).toBe(true)
    expect(out.slice(1).startsWith("import './x.js';")).toBe(true)
  })
})

describe('writing it into an unpacked extension', () => {
  it('ends the prepended line with a semicolon, or the extension calls its result', () => {
    /*
     * The bug this pins, and it cost a whole measurement round. `importScripts('td-compat.js')`
     * with no semicolon, followed by a bundle that opens with `(function(){…})()`,
     * parses as `importScripts('td-compat.js')(function(){…})()` — automatic
     * semicolon insertion does not apply before an open parenthesis. Both
     * SponsorBlock and Return YouTube Dislike open exactly that way, and both
     * came back with "importScripts(...) is not a function" and a layer that had
     * never run.
     */
    const root = dir()
    write(root, 'manifest.json', JSON.stringify({ manifest_version: 3, name: 'x', version: '1', permissions: ['storage'], background: { service_worker: 'bg.js' } }))
    write(root, 'bg.js', '(function () { self.ran = true })()\n')
    const report = applyCompat(root, {
      manifest_version: 3,
      name: 'x',
      version: '1',
      permissions: ['storage'],
      background: { service_worker: 'bg.js' },
    })
    expect(report.ok).toBe(true)
    const bg = readFileSync(join(root, 'bg.js'), 'utf8')
    expect(bg.split('\n')[0]).toBe(`importScripts('${COMPAT_FILE}');`)
    expect(bg).toContain('self.ran = true')
  })

  it('imports rather than importScripts when the worker is a module', () => {
    const root = dir()
    const manifest = {
      manifest_version: 3,
      name: 'x',
      version: '1',
      permissions: ['storage'],
      background: { service_worker: '/js/background.js', type: 'module' },
    } as ExtensionManifest
    write(root, 'manifest.json', JSON.stringify(manifest))
    write(root, 'js/background.js', 'export const a = 1\n')
    expect(applyCompat(root, manifest).ok).toBe(true)
    const bg = readFileSync(join(root, 'js/background.js'), 'utf8')
    expect(bg.split('\n')[0]).toBe(`import './${COMPAT_FILE}';`)
    // Beside the worker, because a relative import resolves against the script's
    // own URL and the worker is a directory down.
    expect(readFileSync(join(root, 'js', COMPAT_FILE), 'utf8')).toContain('Terminal Deck')
  })

  it('prepends the layer to a manifest v2 script list and to the content scripts', () => {
    const root = dir()
    const manifest = {
      manifest_version: 2,
      name: 'x',
      version: '1',
      permissions: ['storage'],
      background: { scripts: ['bg.js'] },
      content_scripts: [{ js: ['content.js'], matches: ['https://*/*'] }],
    } as ExtensionManifest
    write(root, 'manifest.json', JSON.stringify(manifest))
    write(root, 'bg.js', 'var a = 1\n')
    write(root, 'content.js', 'var b = 2\n')
    expect(applyCompat(root, manifest).ok).toBe(true)
    const written = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8')) as Record<string, unknown>
    expect((written.background as { scripts: string[] }).scripts).toEqual([COMPAT_FILE, 'bg.js'])
    expect((written.content_scripts as { js: string[] }[])[0]?.js).toEqual([COMPAT_FILE, 'content.js'])
  })

  it('patches the popup so its controls read the same settings the background wrote', () => {
    /*
     * Missed in the first draft, and not cosmetically: SponsorBlock and Return
     * YouTube Dislike keep every setting in `storage.sync`, so a popup without
     * the layer opened with `"sync" is not available in this instance of Chrome`
     * on its console and its checkboxes at whatever undefined coerces to.
     */
    const root = dir()
    const manifest = {
      manifest_version: 3,
      name: 'x',
      version: '1',
      permissions: ['storage'],
      background: { service_worker: 'bg.js' },
      action: { default_popup: 'popup.html' },
    } as unknown as ExtensionManifest
    write(root, 'manifest.json', JSON.stringify(manifest))
    write(root, 'bg.js', 'var a = 1\n')
    write(root, 'popup.html', '<body><script src="popup.js"></script></body>')
    expect(applyCompat(root, manifest).ok).toBe(true)
    const popup = readFileSync(join(root, 'popup.html'), 'utf8')
    expect(popup.indexOf(COMPAT_FILE)).toBeLessThan(popup.indexOf('popup.js'))
  })

  it('reports rather than throws when the background it was told about is not there', () => {
    const root = dir()
    const manifest = {
      manifest_version: 3,
      name: 'x',
      version: '1',
      permissions: ['storage'],
      background: { service_worker: 'nowhere.js' },
    } as ExtensionManifest
    write(root, 'manifest.json', JSON.stringify(manifest))
    const report = applyCompat(root, manifest)
    expect(report.ok).toBe(false)
    expect(report.why).toContain('nowhere.js')
  })

  it('is idempotent — a second pass does not stack two copies of the layer', () => {
    const root = dir()
    const manifest = {
      manifest_version: 2,
      name: 'x',
      version: '1',
      permissions: ['storage'],
      background: { scripts: ['bg.js'] },
    } as ExtensionManifest
    write(root, 'manifest.json', JSON.stringify(manifest))
    write(root, 'bg.js', 'var a = 1\n')
    applyCompat(root, manifest)
    const after = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8')) as {
      background: { scripts: string[] }
    }
    applyCompat(root, after as unknown as ExtensionManifest)
    const twice = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8')) as {
      background: { scripts: string[] }
    }
    expect(twice.background.scripts).toEqual([COMPAT_FILE, 'bg.js'])
  })
})

describe('the layer itself', () => {
  it('parses — it is written into somebody else’s bundle and a syntax error there is theirs', () => {
    const text = compatShimFor(planCompat({ manifest_version: 3, permissions: ['storage'] }))
    expect(() => new Function(text)).not.toThrow()
  })

  it('never touches storage.sync when there is no storage.local to mirror onto', () => {
    const text = compatShimFor(planCompat({ manifest_version: 3, permissions: ['storage'] }))
    expect(text).toContain('var local = api.storage && api.storage.local')
    expect(text).toContain('if (local) {')
  })

  it('leaves a content script with storage and nothing else', () => {
    const text = compatShimFor(planCompat({ manifest_version: 3, permissions: ['storage'] }))
    expect(text).toContain('if (inPage) return')
  })
})

/**
 * The layer running, against a `chrome` stub shaped like the one it meets.
 *
 * The unit tests above hold what the layer *decides*; this holds what it *does*,
 * and it exists because the most expensive bug in this file was behavioural and
 * invisible to every static check: aliasing `storage.sync` straight onto
 * `storage.local` compiled, typechecked, passed every plan test, and quietly
 * merged two of SponsorBlock's own key spaces into one.
 */
function fakeChrome(manifest: Record<string, unknown> = { manifest_version: 3, permissions: ['storage'] }) {
  const disk = new Map<string, unknown>()
  const listeners: ((changes: Record<string, unknown>, area: string) => void)[] = []
  const local = {
    get(keys: unknown, cb: (out: Record<string, unknown>) => void) {
      const out: Record<string, unknown> = {}
      if (keys === null || keys === undefined) {
        for (const [k, v] of disk) out[k] = v
      } else {
        for (const k of Array.isArray(keys) ? keys : [keys as string]) {
          if (disk.has(k)) out[k] = disk.get(k)
        }
      }
      cb(out)
    },
    set(items: Record<string, unknown>, cb?: () => void) {
      const changes: Record<string, unknown> = {}
      for (const [k, v] of Object.entries(items)) {
        changes[k] = { oldValue: disk.get(k), newValue: v }
        disk.set(k, v)
      }
      for (const fn of listeners) fn(changes, 'local')
      cb?.()
    },
    remove(keys: string | string[], cb?: () => void) {
      for (const k of Array.isArray(keys) ? keys : [keys]) disk.delete(k)
      cb?.()
    },
    clear(cb?: () => void) {
      disk.clear()
      cb?.()
    },
  }
  const chrome = {
    runtime: { lastError: undefined, getManifest: () => manifest },
    storage: { local, sync: { get() { /* exists and never works, as measured */ } }, onChanged: { addListener: (fn: (c: Record<string, unknown>, a: string) => void) => listeners.push(fn) } },
    tabs: { onUpdated: { addListener: () => {} } },
  }
  return { chrome, disk }
}

function runShim(chrome: unknown, manifest: ExtensionManifest = { manifest_version: 3, permissions: ['storage'] }) {
  const text = compatShimFor(planCompat(manifest))
  const scope: Record<string, unknown> = { chrome, location: { protocol: 'chrome-extension:' } }
  // eslint-disable-next-line no-new-func
  new Function('globalThis', 'self', 'location', `var g = self; ${text}`)(scope, scope, scope.location)
  return scope
}

describe('the layer, run', () => {
  it('keeps storage.sync out of storage.local’s way', async () => {
    /*
     * The bug. SponsorBlock keeps its settings in `sync` and its segment cache
     * in `local`. Aliased, one wrote over the other; prefixed, the same key name
     * in both is two values, which is what Chrome gives it.
     */
    const { chrome, disk } = fakeChrome()
    runShim(chrome)
    const api = chrome as unknown as {
      storage: {
        sync: { set: (i: unknown, cb?: () => void) => Promise<void>; get: (k: unknown, cb?: unknown) => Promise<Record<string, unknown>>; clear: () => Promise<void> }
        local: { set: (i: unknown, cb?: () => void) => void }
      }
    }
    api.storage.local.set({ sponsorTimes: 'the cache' })
    await api.storage.sync.set({ sponsorTimes: 'the settings' })
    expect(disk.get('sponsorTimes')).toBe('the cache')
    expect(await api.storage.sync.get('sponsorTimes')).toEqual({ sponsorTimes: 'the settings' })
  })

  it('answers get() with the defaults an object of keys carries', async () => {
    const { chrome } = fakeChrome()
    runShim(chrome)
    const sync = (chrome as unknown as { storage: { sync: { get: (k: unknown) => Promise<Record<string, unknown>> ; set: (i: unknown) => Promise<void> } } }).storage.sync
    await sync.set({ known: 1 })
    expect(await sync.get({ known: 99, missing: 'fallback' })).toEqual({ known: 1, missing: 'fallback' })
  })

  it('clear() takes its own keys and leaves the extension’s local ones alone', async () => {
    const { chrome, disk } = fakeChrome()
    runShim(chrome)
    const store = (chrome as unknown as { storage: { sync: { set: (i: unknown) => Promise<void>; clear: () => Promise<void>; get: (k: unknown) => Promise<Record<string, unknown>> }; local: { set: (i: unknown) => void } } }).storage
    store.local.set({ cache: 'keep me' })
    await store.sync.set({ setting: 'go' })
    await store.sync.clear()
    expect(disk.get('cache')).toBe('keep me')
    expect(await store.sync.get(null)).toEqual({})
  })

  it('reports what it provided, so a row is never guessing', () => {
    const manifest = {
      manifest_version: 3,
      permissions: ['storage', 'webNavigation'],
    } as ExtensionManifest
    const { chrome } = fakeChrome({ manifest_version: 3, permissions: ['storage', 'webNavigation'] })
    const scope = runShim(chrome, manifest)
    const report = (scope as { __tdCompat?: { provided: string[] } }).__tdCompat
    expect(report?.provided).toEqual(expect.arrayContaining(['storage.sync', 'permissions', 'windows', 'webNavigation']))
  })

  it('parses under strict mode, because a module service worker is strict', () => {
    const text = compatShimFor(planCompat({ manifest_version: 3, permissions: ['storage'] }))
    expect(() => new Function(`'use strict';${text}`)).not.toThrow()
  })
})

/**
 * The runtime flag, which is what makes the same shim safe on the server.
 *
 * On the desktop this whole layer fills gaps in Electron's Chromium. On the
 * server the Chromium is full chrome-for-testing, which provides those namespaces
 * itself — and the shim's own `if (!api.X)` guards already self-disable there for
 * all but `storage.sync`, the one namespace it replaces without such a guard
 * because on Electron the object exists and silently never works. The flag is how
 * the shim learns not to overwrite a `storage.sync` that actually works.
 */
describe('the runtime flag', () => {
  it('compiles the runtime into the layer, leaving no placeholder', () => {
    setCompatRuntime('chromium')
    try {
      const text = compatShimFor(planCompat({ manifest_version: 3, permissions: ['storage'] }))
      expect(text).toContain('var TD_NATIVE = true')
      expect(text).not.toContain('__TD_NATIVE__')
    } finally {
      setCompatRuntime('electron')
    }
    const electronText = compatShimFor(planCompat({ manifest_version: 3, permissions: ['storage'] }))
    expect(electronText).toContain('var TD_NATIVE = false')
    expect(electronText).not.toContain('__TD_NATIVE__')
  })

  it('leaves a working native storage.sync alone under chromium', () => {
    setCompatRuntime('chromium')
    try {
      const { chrome } = fakeChrome()
      const native = { __native: true, get() {}, set() {} }
      // Stand in for a real chrome-for-testing storage.sync: present and working.
      ;(chrome.storage as unknown as { sync: unknown }).sync = native
      runShim(chrome)
      // The native store is untouched — not replaced by the storage.local mirror.
      expect((chrome.storage as unknown as { sync: unknown }).sync).toBe(native)
    } finally {
      setCompatRuntime('electron')
    }
  })

  it('reports storage.sync as not provided under chromium, because it was native', () => {
    setCompatRuntime('chromium')
    try {
      const { chrome } = fakeChrome()
      ;(chrome.storage as unknown as { sync: unknown }).sync = { get() {}, set() {} }
      const scope = runShim(chrome)
      const report = (scope as { __tdCompat?: { provided: string[] } }).__tdCompat
      expect(report?.provided ?? []).not.toContain('storage.sync')
    } finally {
      setCompatRuntime('electron')
    }
  })

  it('still replaces the broken Electron storage.sync when the runtime is electron', () => {
    // The default the desktop keeps: on Electron the object exists but never
    // works, so the mirror must go in regardless.
    const { chrome } = fakeChrome()
    const broken = (chrome.storage as unknown as { sync: unknown }).sync
    runShim(chrome)
    expect((chrome.storage as unknown as { sync: unknown }).sync).not.toBe(broken)
  })
})
