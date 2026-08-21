import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import type { ExtensionManifest } from './browser-extension-support'

/**
 * The gap between the `chrome.*` an extension was written against and the one
 * this Electron has — closed where it can be closed, named where it cannot.
 *
 * ## What this is for
 *
 *   > *"i want it to be with no resistance — people just install and do some
 *   > clicks and everything works fine"*
 *
 * `browser-extension-support.ts` measured twenty namespaces missing from this
 * Chromium and left it there, and the catalogue turned that measurement into
 * five rows that say *cannot work here* with no Install button. That is honest,
 * and for two of those rows — the ad blockers, which are the first thing anybody
 * opens an extension store looking for — it was also avoidable, which makes it
 * resistance rather than truth.
 *
 * The reason it was avoidable is narrow and worth stating exactly, because it is
 * what this file rests on. **None of the five died doing their job. Every one of
 * them died before starting one.** uBlock Origin's own `webext.js` builds a
 * wrapper object at module load:
 *
 * ```js
 * browserAction: {
 *     setBadgeBackgroundColor: promisifyNoFail(chrome.browserAction, 'setBadgeBackgroundColor'),
 * ```
 *
 * `chrome.browserAction` is `undefined` here, so reading `.setBadgeBackgroundColor`
 * off it throws — *"Cannot read properties of undefined (reading
 * 'setBadgeBackgroundColor')"*, which is the first line of the background page's
 * console and the whole of the reason a request to `ads.doubleclick.net` was
 * served on every attempt. The blocking engine underneath was never reached, let
 * alone found wanting. uBlock Origin Lite dies the same way one line into
 * `browser.permissions.onRemoved.addListener`.
 *
 * So this layer defines the namespaces those start-ups read, before the
 * extension's own code runs, and the two ad blockers then block. That was
 * measured the same way the refusals were: a bare Electron with its own
 * `--user-data-dir`, a local HTTP server, and `ads.doubleclick.net` pointed at
 * it with `--host-resolver-rules` so a blocked request is a request the server
 * never receives. Baseline: three ad hits, `hasListeners()` false. With this
 * layer: zero ad hits, `hasListeners()` true, and a control script from an
 * innocent host loading in both runs so that "blocked" is never confused with
 * "broken".
 *
 * ## What is real here and what is only present
 *
 * The distinction matters more than the code does, so it is drawn per namespace
 * rather than in a paragraph:
 *
 * **Backed by something real:**
 *  - `storage.sync` → `storage.local`. Every read and write happens, on this
 *    machine's disk. The one thing that does not happen is syncing to another
 *    machine, and there is no other machine: this browser has no Chrome account
 *    and no sync backend, so `sync` could never have meant anything else here.
 *  - `permissions` → answered out of the extension's own manifest, which is the
 *    grant in this browser. `request()` answers `false` because nothing can be
 *    granted at runtime here, and `false` is the truth rather than a stub.
 *  - `commands.getAll()` → the manifest's own `commands` block, with an empty
 *    `shortcut` on each, because none is bound.
 *  - `windows` → one window, focused, id 1. A browser session here *is* one
 *    window, so this is a description and not a placeholder.
 *  - `webNavigation` → main-frame events synthesised from `chrome.tabs.onUpdated`,
 *    which does fire here. A real navigation produces a real event with the real
 *    URL and tab id. Sub-frame navigations produce nothing, and
 *    {@link COMPAT_INERT} says so.
 *  - `declarativeNetRequest` static rulesets → **switched on**, once, on the
 *    first run after install, for exactly the resources the manifest marks
 *    `"enabled": true`. Chromium here answers `getEnabledRulesets()` with `[]`
 *    at load even for those, which is the single most misleading thing in the
 *    set. Doing it once and recording that it was done is deliberate: an
 *    extension's own UI may switch rulesets off afterwards, and re-running this
 *    every boot would undo that person's choice on their behalf.
 *
 * **Present so start-up survives, and inert:**
 *  - `contextMenus` — items are accepted and are not drawn in the page menu.
 *  - `browserAction` (manifest v2 only; v3's `action` is native here) — badge
 *    text, title and icon are accepted and are not drawn.
 *  - `notifications` — accepted, nothing appears.
 *  - `commands.onCommand` — no keyboard shortcut is bound, so it never fires.
 *
 * Nothing in the second list is hidden. {@link COMPAT_INERT} names each one in
 * the words a person reads, the store row carries them before the Install
 * button, and the catalogue's `measured` sentence for each extension says what
 * was watched working and what was watched not working. An extension being told
 * a small "yes" so that it can start is a different thing from a person being
 * shown a control that does nothing, and only the second one is the defect this
 * store was written against.
 *
 * ## Why the layer is written into the unpacked copy
 *
 * There is no way to inject into an extension's own JavaScript context from
 * Electron's main process — no preload, no `executeJavaScript` before first
 * paint for a service worker, nothing. The only place that runs before the
 * extension's first line is inside the extension's own bundle. So the store,
 * which already unpacks every install itself, prepends one file to the
 * background entry point and to any content script that needs it.
 *
 * That copy is per profile and is thrown away and rewritten on reinstall. The
 * archive digest the store verifies is the digest of the *download*, checked
 * before a single byte is written, so patching afterwards changes nothing about
 * what was verified: the bytes that were checked are the bytes that were
 * unpacked, and this file's additions are this app's own, shipped in this app's
 * own bytes exactly like the digests are.
 */

/** The build every sentence above was measured against. */
export const COMPAT_MEASURED_ELECTRON = '41.10.5'

/** The name of the file written into the unpacked extension. */
export const COMPAT_FILE = 'td-compat.js'

/**
 * The namespaces this layer will define when they are absent.
 *
 * Deliberately short. A namespace that *returns data* — `cookies`, `history`,
 * `downloads`, `bookmarks`, `topSites` — is not here and will not be: answering
 * "no cookies" or "no history" to an extension that asked is a false answer
 * dressed as an empty one, and it changes behaviour silently. Everything below
 * is either backed by something real or accepts a write that this browser has
 * nowhere to draw, and the second kind is named in {@link COMPAT_INERT}.
 */
export const COMPAT_PROVIDES: readonly string[] = [
  'browserAction',
  'commands',
  'contextMenus',
  'notifications',
  'permissions',
  'privacy',
  'storage.sync',
  'webNavigation',
  'windows',
]

/**
 * What stays inert after the layer, in the words a row shows.
 *
 * Keyed by the namespace so a row only carries the sentences that apply to the
 * extension in front of it.
 */
export const COMPAT_INERT: Readonly<Record<string, string>> = {
  browserAction: 'its toolbar badge, icon and title are not drawn',
  commands: 'its keyboard shortcuts are not bound',
  contextMenus: 'its right-click menu entries are not shown',
  notifications: 'its desktop notifications do not appear',
  privacy: 'it cannot change this browser’s privacy settings',
  webNavigation: 'it is told about main-frame navigations only, never sub-frames',
}

/* ------------------------------------------------------------------ the plan -- */

/** Where the layer has to be prepended for this manifest. */
export type CompatBackground = 'none' | 'worker' | 'scripts' | 'page'

export interface CompatPlan {
  /** Namespaces this layer will define for this extension, sorted. */
  provides: string[]
  /** The sentences from {@link COMPAT_INERT} that apply, in `provides` order. */
  inert: string[]
  /** How the background entry point gets it. */
  background: CompatBackground
  /** The background file or page the layer is prepended to, relative to the root. */
  backgroundPath: string
  /** Indexes into `content_scripts` that get it prepended. */
  contentScripts: number[]
  /**
   * The extension's own HTML pages that get a `<script>` tag, relative to the root.
   *
   * The popup and the options page, and nothing else. Both were missed in the
   * first draft, and the miss was not cosmetic: SponsorBlock and Return YouTube
   * Dislike keep every setting in `storage.sync`, so a popup without this layer
   * opens with every control blank whatever the background page has stored. A
   * store row that says an extension works and a popup that shows nothing are
   * the same defect this whole feature was written against.
   */
  pages: string[]
  /** Ruleset ids the manifest marks enabled, which this layer switches on once. */
  rulesets: string[]
  /** Nothing to do at all. */
  empty: boolean
}

function record(raw: unknown): Record<string, unknown> {
  return typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
}

function strings(raw: unknown): string[] {
  return Array.isArray(raw) ? raw.filter((x): x is string => typeof x === 'string') : []
}

/**
 * Which namespaces an extension is gated on, in Chrome's own terms.
 *
 * Not one rule: Chrome hands some of these to every extension, some only for a
 * permission, and one only for a manifest key. Getting that wrong is not a
 * detail — `chrome.permissions` needs no permission and `chrome.commands` needs
 * no permission either, so a layer that keyed both off the `permissions` array
 * would define neither, and uBlock Origin Lite would still die on the first line
 * of `browser.permissions.onRemoved.addListener`. It did, in the first draft.
 */
const GATE: Readonly<Record<string, 'always' | 'permission' | 'commands-key' | 'mv2-action' | 'storage'>> =
  {
    browserAction: 'mv2-action',
    commands: 'commands-key',
    contextMenus: 'permission',
    notifications: 'permission',
    permissions: 'always',
    privacy: 'permission',
    'storage.sync': 'storage',
    webNavigation: 'permission',
    windows: 'always',
  }

/**
 * The namespaces *this* extension's start-up would read and not find.
 *
 * Two of the nine are not permissions at all. An MV2 `browser_action` block
 * means the extension will reach for `chrome.browserAction`, which is absent
 * here even though MV3's `chrome.action` is present; a `storage` permission
 * means it may reach for `storage.sync`, which exists as an object and throws
 * on every call.
 */
export function compatProvides(manifest: ExtensionManifest): string[] {
  const asked = new Set([
    ...strings(manifest.permissions),
    ...strings(manifest.optional_permissions),
  ])
  const declaresCommands = Object.keys(record((manifest as Record<string, unknown>).commands)).length > 0
  const out: string[] = []
  for (const name of COMPAT_PROVIDES) {
    switch (GATE[name]) {
      case 'always':
        out.push(name)
        break
      case 'permission':
        if (asked.has(name)) out.push(name)
        break
      case 'commands-key':
        if (declaresCommands) out.push(name)
        break
      case 'mv2-action':
        if (manifest.manifest_version === 2 && manifest.browser_action !== undefined) out.push(name)
        break
      case 'storage':
        if (asked.has('storage')) out.push(name)
        break
    }
  }
  return out
}

/** The static ruleset ids the manifest asks to have on. */
export function enabledRulesetIds(manifest: ExtensionManifest): string[] {
  const dnr = record(manifest.declarative_net_request)
  if (!Array.isArray(dnr.rule_resources)) return []
  const out: string[] = []
  for (const raw of dnr.rule_resources) {
    const resource = record(raw)
    if (resource.enabled !== true) continue
    if (typeof resource.id === 'string' && resource.id !== '') out.push(resource.id)
  }
  return out
}

/**
 * Which content scripts need the layer.
 *
 * Only the ones that run in the isolated world: a `"world": "MAIN"` script is
 * the page's own context with no `chrome` in it at all, and prepending a file
 * that reads `chrome.storage` there would put a thrown error into every page the
 * extension touches — a new failure invented by the thing meant to remove one.
 */
function contentScriptTargets(manifest: ExtensionManifest, wantsStorage: boolean): number[] {
  if (!wantsStorage) return []
  const list = Array.isArray(manifest.content_scripts) ? manifest.content_scripts : []
  const out: number[] = []
  list.forEach((raw, index) => {
    const entry = record(raw)
    if (entry.world === 'MAIN') return
    if (!Array.isArray(entry.js) || entry.js.length === 0) return
    out.push(index)
  })
  return out
}

/**
 * The extension's own pages a person opens: the toolbar popup and the options page.
 *
 * Not every HTML file in the bundle. A dashboard reachable only from inside the
 * extension is one more file to rewrite for no measured gain, and this layer
 * touches as little of somebody else's bundle as it can get away with.
 */
function ownPages(manifest: ExtensionManifest): string[] {
  const out: string[] = []
  const push = (raw: unknown): void => {
    if (typeof raw !== 'string') return
    const trimmed = raw.trim().replace(/^\/+/, '').split('#')[0]?.split('?')[0] ?? ''
    if (trimmed === '' || !/\.html?$/i.test(trimmed)) return
    if (!out.includes(trimmed)) out.push(trimmed)
  }
  push(record(manifest.action ?? manifest.browser_action).default_popup)
  push((manifest as Record<string, unknown>).options_page)
  push(record((manifest as Record<string, unknown>).options_ui).page)
  return out
}

/** What this layer would do to an extension, decided from its manifest alone. */
export function planCompat(manifest: ExtensionManifest): CompatPlan {
  const provides = compatProvides(manifest)
  const background = record(manifest.background)
  let where: CompatBackground = 'none'
  let path = ''
  if (typeof background.service_worker === 'string' && background.service_worker !== '') {
    where = 'worker'
    path = background.service_worker
  } else if (Array.isArray(background.scripts) && strings(background.scripts).length > 0) {
    where = 'scripts'
    path = strings(background.scripts)[0] ?? ''
  } else if (typeof background.page === 'string' && background.page !== '') {
    where = 'page'
    path = background.page
  }
  const rulesets = enabledRulesetIds(manifest)
  const contentScripts = contentScriptTargets(manifest, provides.includes('storage.sync'))
  const pages = ownPages(manifest)
  const inert = provides.map((name) => COMPAT_INERT[name] ?? '').filter((line) => line !== '')
  const nothingToDo =
    (provides.length === 0 && rulesets.length === 0) ||
    (where === 'none' && contentScripts.length === 0 && pages.length === 0)
  return {
    provides,
    inert,
    background: where,
    backgroundPath: path,
    contentScripts,
    pages,
    rulesets,
    empty: nothingToDo,
  }
}

/* ----------------------------------------------------------------- the shim -- */

/**
 * The layer itself, as text, because it is written into somebody else's bundle.
 *
 * Deliberately ES5-shaped and free of template literals: it is loaded three
 * different ways — as a classic script in a manifest v2 background page, as an
 * ES module imported by a manifest v3 module service worker, and as a content
 * script in an isolated world — and the smallest common shape is the one that
 * cannot be wrong in one of them.
 */
export const COMPAT_SHIM = `/* Terminal Deck compatibility layer. Written by browser-extension-compat.ts.
 * Defines the chrome.* an extension's start-up reads and this Chromium does not
 * have. See that file for which of these are real and which are inert. */
;(function () {
  var g = typeof globalThis !== 'undefined' ? globalThis : self
  var api = g.chrome
  if (!api || !api.runtime) return
  var report = (g.__tdCompat = g.__tdCompat || { provided: [], notes: [] })
  function provided(name) { if (report.provided.indexOf(name) < 0) report.provided.push(name) }
  function note(line) { if (report.notes.length < 40) report.notes.push(line) }

  var inPage = false
  try { inPage = typeof location !== 'undefined' && location.protocol !== 'chrome-extension:' } catch (e) {}

  function settle(cb, value) {
    if (typeof cb === 'function') { try { cb(value) } catch (e) { note('callback: ' + e.message) } }
    return Promise.resolve(value)
  }

  function emitter(name) {
    var listeners = []
    return {
      addListener: function (fn) { if (typeof fn === 'function' && listeners.indexOf(fn) < 0) listeners.push(fn) },
      removeListener: function (fn) { var i = listeners.indexOf(fn); if (i >= 0) listeners.splice(i, 1) },
      hasListener: function (fn) { return listeners.indexOf(fn) >= 0 },
      hasListeners: function () { return listeners.length > 0 },
      __fire: function () {
        var args = arguments
        for (var i = 0; i < listeners.length; i++) {
          try { listeners[i].apply(null, args) } catch (e) { note(name + ' listener: ' + e.message) }
        }
      },
    }
  }

  /* storage.sync, kept in storage.local under a prefix of its own.
   *
   * NOT aliased onto storage.local, which is what the first version did and
   * what SponsorBlock caught: it keeps its settings in sync and its segment
   * cache in local, and one object serving both means two of the extension's
   * own key spaces writing over each other. The prefix keeps them two stores,
   * both on this machine's disk, which is what sync could ever have meant here:
   * this browser has no Chrome account and no sync backend. */
  var TD_SYNC = '__tdsync:'
  var local = api.storage && api.storage.local
  if (local) {
    function requested(keys) {
      if (keys === null || keys === undefined) return { names: null, fallback: {} }
      if (typeof keys === 'string') return { names: [keys], fallback: {} }
      if (Array.isArray(keys)) return { names: keys.slice(), fallback: {} }
      var names = []
      for (var k in keys) names.push(k)
      return { names: names, fallback: keys }
    }
    function mine(raw) {
      var out = {}
      for (var key in raw) {
        if (key.indexOf(TD_SYNC) !== 0) continue
        out[key.slice(TD_SYNC.length)] = raw[key]
      }
      return out
    }
    function syncGet(keys, cb) {
      var want = requested(keys)
      var ask = want.names === null ? null : want.names.map(function (n) { return TD_SYNC + n })
      return new Promise(function (resolve) {
        local.get(ask, function (raw) {
          void api.runtime.lastError
          var out = {}
          for (var d in want.fallback) out[d] = want.fallback[d]
          var found = mine(raw || {})
          for (var f in found) out[f] = found[f]
          if (typeof cb === 'function') { try { cb(out) } catch (e) { note('storage.sync.get: ' + e.message) } }
          resolve(out)
        })
      })
    }
    function syncSet(items, cb) {
      var prefixed = {}
      for (var k2 in items) prefixed[TD_SYNC + k2] = items[k2]
      return new Promise(function (resolve) {
        local.set(prefixed, function () {
          void api.runtime.lastError
          if (typeof cb === 'function') { try { cb() } catch (e) { note('storage.sync.set: ' + e.message) } }
          resolve()
        })
      })
    }
    function syncRemove(keys, cb) {
      var names = typeof keys === 'string' ? [keys] : Array.isArray(keys) ? keys : []
      return new Promise(function (resolve) {
        local.remove(names.map(function (n) { return TD_SYNC + n }), function () {
          void api.runtime.lastError
          if (typeof cb === 'function') { try { cb() } catch (e) {} }
          resolve()
        })
      })
    }
    function syncClear(cb) {
      /* Only this store's own keys. A clear() that reached storage.local would
       * throw away whatever the extension keeps there, which is exactly the
       * collision this prefix exists to prevent, in the other direction. */
      return new Promise(function (resolve) {
        local.get(null, function (raw) {
          void api.runtime.lastError
          var doomed = []
          for (var key in raw || {}) if (key.indexOf(TD_SYNC) === 0) doomed.push(key)
          local.remove(doomed, function () {
            void api.runtime.lastError
            if (typeof cb === 'function') { try { cb() } catch (e) {} }
            resolve()
          })
        })
      })
    }
    var syncChanged = emitter('storage.sync.onChanged')
    try {
      if (api.storage.onChanged && api.storage.onChanged.addListener) {
        api.storage.onChanged.addListener(function (changes, area) {
          if (area !== 'local') return
          var translated = {}
          var any = false
          for (var key in changes) {
            if (key.indexOf(TD_SYNC) !== 0) continue
            translated[key.slice(TD_SYNC.length)] = changes[key]
            any = true
          }
          if (any) syncChanged.__fire(translated, 'sync')
        })
      }
    } catch (e) { note('storage.sync.onChanged: ' + e.message) }

    /* Installed without probing first, and that is deliberate. The first draft
     * probed with api.storage.sync.get() in a try/catch and always passed,
     * because this Chromium does not throw: the object exists, the call
     * succeeds, and the failure arrives later as runtime.lastError reading
     * '"sync" is not available in this instance of Chrome'. So the probe swapped
     * nothing in and SponsorBlock and Return YouTube Dislike went on reading
     * undefined out of every setting. Measured, not guessed at: see
     * COMPAT_MEASURED_ELECTRON, and the catalogue re-measures every release. */
    var mirror = {
      get: syncGet,
      set: syncSet,
      remove: syncRemove,
      clear: syncClear,
      getKeys: function (cb) {
        return syncGet(null, null).then(function (all) {
          var names = []
          for (var k3 in all) names.push(k3)
          if (typeof cb === 'function') cb(names)
          return names
        })
      },
      getBytesInUse: function (keys, cb) {
        var done = typeof keys === 'function' ? keys : cb
        return syncGet(typeof keys === 'function' ? null : keys, null).then(function (all) {
          var size = 0
          for (var k4 in all) size += k4.length + JSON.stringify(all[k4] === undefined ? null : all[k4]).length
          if (typeof done === 'function') done(size)
          return size
        })
      },
      onChanged: syncChanged,
      QUOTA_BYTES: 102400,
      QUOTA_BYTES_PER_ITEM: 8192,
      MAX_ITEMS: 512,
      MAX_WRITE_OPERATIONS_PER_HOUR: 1800,
      MAX_WRITE_OPERATIONS_PER_MINUTE: 120,
      MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000,
    }
    try {
      Object.defineProperty(api.storage, 'sync', { value: mirror, writable: true, configurable: true })
      provided('storage.sync')
    } catch (e) { note('storage.sync: ' + e.message) }
  }

  /* A content script needs storage and nothing else here. */
  if (inPage) return

  var manifest = {}
  try { manifest = api.runtime.getManifest() || {} } catch (e) {}

  /* browserAction: manifest v2 only. Accepted, not drawn. */
  function actionApi() {
    var state = (g.__tdActionState = g.__tdActionState || { badge: {}, title: {}, colour: '', icon: false })
    function tabKey(details) { return String((details && details.tabId) || 0) }
    return {
      setBadgeText: function (d, cb) { state.badge[tabKey(d)] = (d && d.text) || ''; return settle(cb) },
      setBadgeBackgroundColor: function (d, cb) { state.colour = (d && d.color) || ''; return settle(cb) },
      setBadgeTextColor: function (d, cb) { return settle(cb) },
      getBadgeText: function (d, cb) { return settle(cb, state.badge[tabKey(d)] || '') },
      setIcon: function (d, cb) { state.icon = true; return settle(cb) },
      setTitle: function (d, cb) { state.title[tabKey(d)] = (d && d.title) || ''; return settle(cb) },
      getTitle: function (d, cb) { return settle(cb, state.title[tabKey(d)] || '') },
      setPopup: function (d, cb) { return settle(cb) },
      getPopup: function (d, cb) { return settle(cb, '') },
      enable: function (t, cb) { return settle(typeof t === 'function' ? t : cb) },
      disable: function (t, cb) { return settle(typeof t === 'function' ? t : cb) },
      onClicked: emitter('browserAction.onClicked'),
    }
  }
  if (!api.browserAction && manifest.manifest_version === 2 && manifest.browser_action) {
    api.browserAction = actionApi()
    provided('browserAction')
  }
  if (!api.action && api.browserAction) { api.action = api.browserAction }

  /* contextMenus: accepted, not drawn. */
  if (!api.contextMenus) {
    var items = (g.__tdMenuItems = {})
    var nextId = 1
    api.contextMenus = {
      ACTION_MENU_TOP_LEVEL_LIMIT: 6,
      create: function (props, cb) {
        var id = props && props.id !== undefined ? props.id : 'td-menu-' + nextId++
        items[String(id)] = props || {}
        if (typeof cb === 'function') cb()
        return id
      },
      update: function (id, props, cb) {
        var key = String(id)
        if (items[key]) { for (var k in props) items[key][k] = props[k] }
        return settle(cb)
      },
      remove: function (id, cb) { delete items[String(id)]; return settle(cb) },
      removeAll: function (cb) { for (var k2 in items) delete items[k2]; return settle(cb) },
      onClicked: emitter('contextMenus.onClicked'),
    }
    provided('contextMenus')
  }

  /* permissions: answered from the manifest, which is the grant here. */
  if (!api.permissions) {
    var grantedNames = (manifest.permissions || []).slice()
    var grantedOrigins = (manifest.host_permissions || []).concat(
      (manifest.permissions || []).filter(function (p) {
        return p === '<all_urls>' || p.indexOf('://') >= 0
      })
    )
    function covered(asked, have) {
      if (!asked || asked.length === 0) return true
      if (have.indexOf('<all_urls>') >= 0) return true
      for (var i = 0; i < asked.length; i++) if (have.indexOf(asked[i]) < 0) return false
      return true
    }
    api.permissions = {
      getAll: function (cb) { return settle(cb, { permissions: grantedNames.slice(), origins: grantedOrigins.slice() }) },
      contains: function (p, cb) {
        return settle(cb, covered(p && p.permissions, grantedNames) && covered(p && p.origins, grantedOrigins))
      },
      request: function (p, cb) { return settle(cb, false) },
      remove: function (p, cb) { return settle(cb, false) },
      onAdded: emitter('permissions.onAdded'),
      onRemoved: emitter('permissions.onRemoved'),
    }
    provided('permissions')
  }

  /* commands: getAll from the manifest; nothing is bound, so nothing fires. */
  if (!api.commands) {
    var declared = manifest.commands || {}
    var list = []
    for (var name in declared) {
      list.push({ name: name, description: declared[name].description || '', shortcut: '' })
    }
    api.commands = {
      getAll: function (cb) { return settle(cb, list.slice()) },
      onCommand: emitter('commands.onCommand'),
    }
    provided('commands')
  }

  /* windows: one window, which is what a browser session here is. */
  if (!api.windows) {
    var only = { id: 1, focused: true, type: 'normal', state: 'normal', incognito: false, alwaysOnTop: false, tabs: [] }
    function windowArgs(a, b) { return typeof a === 'function' ? a : b }
    api.windows = {
      WINDOW_ID_NONE: -1,
      WINDOW_ID_CURRENT: -2,
      get: function (id, a, b) { return settle(windowArgs(a, b), only) },
      getCurrent: function (a, b) { return settle(windowArgs(a, b), only) },
      getLastFocused: function (a, b) { return settle(windowArgs(a, b), only) },
      getAll: function (a, b) { return settle(windowArgs(a, b), [only]) },
      create: function (o, cb) { return settle(cb, only) },
      update: function (id, o, cb) { return settle(cb, only) },
      remove: function (id, cb) { return settle(cb) },
      onCreated: emitter('windows.onCreated'),
      onRemoved: emitter('windows.onRemoved'),
      onFocusChanged: emitter('windows.onFocusChanged'),
      onBoundsChanged: emitter('windows.onBoundsChanged'),
    }
    provided('windows')
  }

  /* privacy: not_controllable is Chrome's own word for exactly this. */
  if (!api.privacy) {
    function setting() {
      return {
        get: function (d, cb) { return settle(cb, { value: false, levelOfControl: 'not_controllable' }) },
        set: function (d, cb) { return settle(cb) },
        clear: function (d, cb) { return settle(cb) },
        onChange: emitter('privacy.onChange'),
      }
    }
    api.privacy = {
      network: {
        networkPredictionEnabled: setting(),
        webRTCIPHandlingPolicy: setting(),
      },
      websites: {
        hyperlinkAuditingEnabled: setting(),
        referrersEnabled: setting(),
        thirdPartyCookiesAllowed: setting(),
        protectedContentEnabled: setting(),
      },
      services: { autofillAddressEnabled: setting(), passwordSavingEnabled: setting() },
    }
    provided('privacy')
  }

  /* notifications: accepted, nothing appears. */
  if (!api.notifications) {
    var noteId = 1
    api.notifications = {
      create: function (a, b, c) {
        var cb = typeof b === 'function' ? b : c
        var id = typeof a === 'string' ? a : 'td-note-' + noteId++
        return settle(cb, id)
      },
      update: function (id, o, cb) { return settle(cb, false) },
      clear: function (id, cb) { return settle(cb, false) },
      getAll: function (cb) { return settle(cb, {}) },
      getPermissionLevel: function (cb) { return settle(cb, 'denied') },
      onClicked: emitter('notifications.onClicked'),
      onClosed: emitter('notifications.onClosed'),
      onButtonClicked: emitter('notifications.onButtonClicked'),
    }
    provided('notifications')
  }

  /* webNavigation: real main-frame events, from tab updates that really happen. */
  if (!api.webNavigation && api.tabs && api.tabs.onUpdated) {
    var onBeforeNavigate = emitter('webNavigation.onBeforeNavigate')
    var onCommitted = emitter('webNavigation.onCommitted')
    var onDOMContentLoaded = emitter('webNavigation.onDOMContentLoaded')
    var onCompleted = emitter('webNavigation.onCompleted')
    api.webNavigation = {
      onBeforeNavigate: onBeforeNavigate,
      onCommitted: onCommitted,
      onDOMContentLoaded: onDOMContentLoaded,
      onCompleted: onCompleted,
      onErrorOccurred: emitter('webNavigation.onErrorOccurred'),
      onHistoryStateUpdated: emitter('webNavigation.onHistoryStateUpdated'),
      onReferenceFragmentUpdated: emitter('webNavigation.onReferenceFragmentUpdated'),
      onCreatedNavigationTarget: emitter('webNavigation.onCreatedNavigationTarget'),
      onTabReplaced: emitter('webNavigation.onTabReplaced'),
      getFrame: function (d, cb) { return settle(cb, null) },
      getAllFrames: function (d, cb) { return settle(cb, null) },
    }
    var committed = {}
    try {
      api.tabs.onUpdated.addListener(function (tabId, info, tab) {
        var url = (info && info.url) || (tab && tab.url) || ''
        if (url === '') return
        var key = tabId + '|' + url
        var status = info && info.status
        if (status === 'complete') {
          delete committed[key]
          onCompleted.__fire({ tabId: tabId, frameId: 0, url: url, timeStamp: Date.now() })
          return
        }
        if (committed[key]) return
        committed[key] = true
        var details = {
          tabId: tabId,
          frameId: 0,
          parentFrameId: -1,
          url: url,
          timeStamp: Date.now(),
          transitionType: 'link',
          transitionQualifiers: [],
        }
        onBeforeNavigate.__fire(details)
        onCommitted.__fire(details)
        onDOMContentLoaded.__fire(details)
      })
      provided('webNavigation')
    } catch (e) {
      note('webNavigation: ' + e.message)
      try { delete api.webNavigation } catch (e2) {}
    }
  }

  /* Static declarativeNetRequest rulesets, switched on once after install.
   * Chromium here answers getEnabledRulesets() with [] at load even for
   * resources the manifest marks enabled. Done once, and recorded, so that an
   * extension's own UI switching one off later is never undone on its behalf. */
  var WANT = __TD_RULESETS__
  if (WANT.length > 0 && api.declarativeNetRequest && api.declarativeNetRequest.updateEnabledRulesets && local) {
    local.get('__tdCompatRulesets', function (stored) {
      void api.runtime.lastError
      if (stored && stored.__tdCompatRulesets) return
      api.declarativeNetRequest.getEnabledRulesets(function (on) {
        void api.runtime.lastError
        var missing = []
        for (var i = 0; i < WANT.length; i++) {
          if (!on || on.indexOf(WANT[i]) < 0) missing.push(WANT[i])
        }
        if (missing.length === 0) {
          local.set({ __tdCompatRulesets: true }, function () { void api.runtime.lastError })
          return
        }
        api.declarativeNetRequest.updateEnabledRulesets({ enableRulesetIds: missing }, function () {
          void api.runtime.lastError
          local.set({ __tdCompatRulesets: true }, function () { void api.runtime.lastError })
          note('enabled rulesets: ' + missing.join(', '))
        })
      })
    })
  }
})()
`

/** The layer's text for one extension, with its ruleset ids compiled in. */
export function compatShimFor(plan: CompatPlan): string {
  return COMPAT_SHIM.replace('__TD_RULESETS__', JSON.stringify(plan.rulesets))
}

/* ---------------------------------------------------------------- the write -- */

export interface CompatReport {
  ok: boolean
  /** Namespaces actually wired in. */
  provides: string[]
  /** Inert sentences that apply. */
  inert: string[]
  /** Why nothing was written, when `ok` is false. */
  why: string
}

/**
 * A `<script src>` tag for the layer, inserted before an HTML page's first script.
 *
 * Manifest v2 background pages are HTML, and the layer has to run before the
 * page's own first `<script>` — a classic script in document order, which is
 * exactly what "before the first one" means. Exported so a test can hold the
 * rule rather than the regex.
 */
export function injectIntoHtml(html: string, src: string): string {
  const tag = `<script src="${src}"></script>\n`
  const first = html.search(/<script\b/i)
  if (first >= 0) return html.slice(0, first) + tag + html.slice(first)
  const body = html.search(/<\/body\s*>/i)
  if (body >= 0) return html.slice(0, body) + tag + html.slice(body)
  return tag + html
}

/**
 * Put one line at the top of a JavaScript file, past any byte order mark.
 *
 * A BOM before an `import` is a syntax error in a module, so the mark is kept
 * where it was rather than pushed into the middle of the file.
 */
export function prependLine(source: string, line: string): string {
  if (source.startsWith('﻿')) return '﻿' + line + '\n' + source.slice(1)
  return line + '\n' + source
}

function readIfPresent(file: string): string | null {
  if (!existsSync(file)) return null
  try {
    return readFileSync(file, 'utf8')
  } catch {
    return null
  }
}

/**
 * Write the layer into one unpacked extension, and say what it wired in.
 *
 * Returns `ok: false` with a reason rather than throwing, and the caller decides
 * whether that is fatal. It is not: an extension this layer could not reach is
 * an extension that behaves exactly as it did before this file existed, which is
 * measured, described on its row and no worse than the day before.
 */
export function applyCompat(dir: string, manifest: ExtensionManifest): CompatReport {
  const plan = planCompat(manifest)
  if (plan.empty) return { ok: true, provides: [], inert: [], why: '' }

  const shimTarget =
    plan.background === 'worker' || plan.background === 'scripts'
      ? join(dir, plan.backgroundPath.replace(/^\/+/, ''))
      : ''
  // A classic worker's `importScripts` and a module worker's relative import both
  // resolve against the script's own URL, so the layer lives beside it rather
  // than at the root when the entry point is in a subdirectory.
  const beside = shimTarget === '' ? dir : dirname(shimTarget)
  const rootFile = join(dir, COMPAT_FILE)
  const besideFile = join(beside, COMPAT_FILE)
  const text = compatShimFor(plan)
  try {
    mkdirSync(dirname(rootFile), { recursive: true })
    writeFileSync(rootFile, text, 'utf8')
    if (besideFile !== rootFile) {
      mkdirSync(dirname(besideFile), { recursive: true })
      writeFileSync(besideFile, text, 'utf8')
    }
  } catch (error) {
    return {
      ok: false,
      provides: [],
      inert: [],
      why: error instanceof Error ? error.message : 'the layer could not be written',
    }
  }

  if (plan.background === 'worker') {
    const source = readIfPresent(shimTarget)
    if (source === null) {
      return { ok: false, provides: [], inert: [], why: `its background ${plan.backgroundPath} is not there` }
    }
    const background = record(manifest.background)
    const line =
      background.type === 'module'
        ? `import './${COMPAT_FILE}';`
        : `importScripts('${COMPAT_FILE}');`
    try {
      writeFileSync(shimTarget, prependLine(source, line), 'utf8')
    } catch (error) {
      return {
        ok: false,
        provides: [],
        inert: [],
        why: error instanceof Error ? error.message : 'its background could not be written',
      }
    }
  } else if (plan.background === 'page') {
    const page = join(dir, plan.backgroundPath.replace(/^\/+/, ''))
    const html = readIfPresent(page)
    if (html === null) {
      return { ok: false, provides: [], inert: [], why: `its background ${plan.backgroundPath} is not there` }
    }
    const depth = plan.backgroundPath.replace(/^\/+/, '').split('/').length - 1
    const src = depth === 0 ? COMPAT_FILE : '../'.repeat(depth) + COMPAT_FILE
    try {
      writeFileSync(page, injectIntoHtml(html, src), 'utf8')
    } catch (error) {
      return {
        ok: false,
        provides: [],
        inert: [],
        why: error instanceof Error ? error.message : 'its background page could not be written',
      }
    }
  }

  /*
   * The extension's own pages get a `<script>` tag ahead of their own first one.
   * A popup two directories down needs `../../td-compat.js`, so the layer is
   * written beside each page rather than referred to across a path this app
   * would have to get right in one guess.
   */
  for (const page of plan.pages) {
    const file = join(dir, page)
    const html = readIfPresent(file)
    if (html === null) continue
    const local = join(dirname(file), COMPAT_FILE)
    try {
      if (local !== rootFile && local !== besideFile) writeFileSync(local, text, 'utf8')
      writeFileSync(file, injectIntoHtml(html, COMPAT_FILE), 'utf8')
    } catch {
      // One page that would not take the layer is one page whose controls read
      // whatever storage.sync gives them, which is what they did before. Not
      // worth failing an install that is otherwise wired.
    }
  }

  /*
   * The manifest is rewritten only for the two lists that name files: an MV2
   * `background.scripts` and the content scripts that need `storage.sync`.
   * Nothing else in it is touched — the reach a person agreed to on the row is
   * the reach the manifest still declares afterwards.
   */
  const manifestFile = join(dir, 'manifest.json')
  const raw = readIfPresent(manifestFile)
  if (raw === null) return { ok: false, provides: [], inert: [], why: 'its manifest.json is not there' }
  let parsed: Record<string, unknown>
  try {
    parsed = JSON.parse(raw) as Record<string, unknown>
  } catch {
    return { ok: false, provides: [], inert: [], why: 'its manifest.json is not valid JSON' }
  }
  let changed = false
  if (plan.background === 'scripts') {
    const background = record(parsed.background)
    const scripts = strings(background.scripts)
    if (!scripts.includes(COMPAT_FILE)) {
      background.scripts = [COMPAT_FILE, ...scripts]
      parsed.background = background
      changed = true
    }
  }
  if (plan.contentScripts.length > 0 && Array.isArray(parsed.content_scripts)) {
    for (const index of plan.contentScripts) {
      const entry = record(parsed.content_scripts[index])
      const js = strings(entry.js)
      if (js.includes(COMPAT_FILE) || js.includes('/' + COMPAT_FILE)) continue
      entry.js = [COMPAT_FILE, ...js]
      parsed.content_scripts[index] = entry
      changed = true
    }
  }
  if (changed) {
    try {
      writeFileSync(manifestFile, JSON.stringify(parsed, null, 1), 'utf8')
    } catch (error) {
      return {
        ok: false,
        provides: [],
        inert: [],
        why: error instanceof Error ? error.message : 'its manifest could not be written',
      }
    }
  }
  return { ok: true, provides: plan.provides, inert: plan.inert, why: '' }
}
