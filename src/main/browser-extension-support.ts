/*
 * `browser-extension-compat.ts` imports only a *type* from this file, so this
 * value import is not a runtime cycle: the type is erased before either module
 * exists. The alternative was writing the namespace list out twice, and two
 * copies of a list is how a screen and the code start disagreeing.
 */
import { COMPAT_PROVIDES } from './browser-extension-compat'

/**
 * What a browser extension can actually do inside this app — measured, not
 * remembered.
 *
 * ## Why this file exists before the store does
 *
 *   > *"extensions store needs to be a proper store from where we can see most
 *   > famous open source tools to attach to the browser and use there with
 *   > session ai."*
 *
 * The tools store next door was built on the opposite premise — `browser-store.ts`
 * says outright that a Chrome extension store *"would promise the extension
 * ecosystem and deliver a subset nobody can predict from the outside"*. That
 * sentence had one word wrong in it: **nobody**. The subset is entirely
 * predictable from the inside, because Electron either provides a `chrome.*`
 * namespace or it does not, and an extension either loads or throws a named
 * error. So the subset was measured, against the Electron this app actually
 * ships, before a single row of a catalogue was written.
 *
 * ## The measurement
 *
 * Electron **41.10.5**, Chromium **146.0.7680.216**, on macOS, driving a bare
 * `Electron` binary with its own `--user-data-dir` — never this app, which was
 * open at the time. A probe extension declared every namespace worth asking for
 * and reported `Object.keys(chrome[name]).length` from its own service worker
 * and from an MV2 background page, and real extensions were then loaded and
 * watched doing their jobs on a local HTTP server. Everything below is what came
 * back, and {@link ELECTRON_MEASURED} pins the version it came back from.
 *
 * The mechanics, all observed rather than recalled:
 *
 *  - `ses.extensions.loadExtension(dir)` takes an **unpacked directory**. A
 *    `.crx` is not unpacked and not even recognised — the error is *"Extension
 *    directory not found"*, which is why {@link CANNOT_INSTALL_CRX} is a rule the
 *    store enforces rather than a caveat in a paragraph.
 *  - Nothing is remembered across boots. Electron's own note: *"loadExtension
 *    must be called on every boot of your app"*. So the app's disk is the record
 *    and the load is replayed at launch.
 *  - A non-persistent session refuses outright: *"Extensions cannot be loaded in
 *    a temporary session"*. Every profile in this browser is a `persist:`
 *    partition, so this never bites — but it is why an extension belongs to a
 *    profile and could not be made global even if that were wanted.
 *  - The extension **id is derived from the directory path**, not from a Web
 *    Store key. uBlock Origin loaded from a temporary directory came back as
 *    `npihifkbmjfbckjnmlhcohjfebmeagbg`, which is not its Web Store id. Two
 *    consequences the store depends on: an id is stable as long as the folder
 *    is, and it is *different in every profile*, which is exactly right for a
 *    per-profile install and wrong for anything that tried to key on it globally.
 *  - MV2 still loads, with one refusal: an MV2 **event page** (`persistent:
 *    false`) that asks for `webRequest` is rejected with *"The 'webRequest' API
 *    cannot be used with event pages."* A persistent MV2 background page is
 *    fine, and its blocking `webRequest` listener really does cancel requests —
 *    that was watched cancelling one.
 *  - MV3 loads, and its service worker really runs.
 *  - **`declarativeNetRequest` static rulesets declared in the manifest are not
 *    enabled at load.** With `"enabled": true` on a rule resource,
 *    `getEnabledRulesets()` answered `[]` and the rule did nothing;
 *    `updateEnabledRulesets({ enableRulesetIds })` turned it on and it blocked
 *    immediately afterwards. Dynamic rules work without any of that. This is the
 *    single most misleading behaviour in the set, because a content blocker
 *    built on static rulesets installs, loads, shows a toolbar icon and blocks
 *    nothing.
 *  - **`chrome.storage.sync` does not exist here.** Reading it fails with
 *    *"\"sync\" is not available in this instance of Chrome"*. The manifest does
 *    not distinguish it from `storage.local` — both are the one `storage`
 *    permission — so no manifest check can predict it, and an extension that
 *    keeps its settings in `sync` comes up with every setting `undefined`. Two
 *    of the extensions tested die exactly there.
 *
 * ## What this module is for
 *
 * Two questions, both answered from an extension's own manifest and neither
 * from anybody's opinion:
 *
 *  1. {@link loadability} — will `loadExtension` take this at all?
 *  2. {@link missingApis} — which namespaces does it ask for that are not here?
 *
 * That is deliberately mechanical. It is not a prediction that an extension
 * *works*: an extension can ask for nothing unusual and still die on
 * `storage.sync`, and one can ask for a missing namespace and guard every use of
 * it. Which is why the catalogue carries a **separately measured verdict** per
 * entry (`browser-extension-catalogue.ts`) and this file carries only what the
 * manifest can prove. The two are different kinds of knowledge and the store
 * shows both rather than blending them into one confident word.
 */

/** The build every sentence in this file was measured against. */
export const ELECTRON_MEASURED = '41.10.5'

/** The Chromium inside it, because that is what the extension actually meets. */
export const CHROMIUM_MEASURED = '146.0.7680.216'

/**
 * The `chrome.*` namespaces that exist here.
 *
 * Read out of a live extension context on {@link ELECTRON_MEASURED}, from both
 * an MV3 service worker and an MV2 background page, which returned the same set
 * apart from the namespaces each manifest had not asked for. A namespace only
 * appears once its permission is granted, so this is the union over a manifest
 * that requested everything.
 */
export const SUPPORTED_APIS: readonly string[] = [
  'action',
  'alarms',
  'declarativeNetRequest',
  'extension',
  'i18n',
  'management',
  'offscreen',
  'runtime',
  'scripting',
  'storage',
  'tabs',
  'webRequest',
]

/**
 * Namespaces an extension can ask for in a manifest that are not here.
 *
 * Every one of these was asked for by the probe manifest and came back
 * undefined. The list is not "everything Chrome has" — it is the permissions
 * real extensions in the catalogue actually request, because a list of
 * namespaces nobody uses would make {@link missingApis} noisy without making it
 * more true.
 */
export const MISSING_APIS: readonly string[] = [
  'bookmarks',
  'browsingData',
  'commands',
  'contextMenus',
  'cookies',
  'dom',
  'downloads',
  'fontSettings',
  'history',
  'idle',
  'notifications',
  'permissions',
  'power',
  'privacy',
  'proxy',
  'sidePanel',
  'topSites',
  'userScripts',
  'webNavigation',
  'windows',
]

/**
 * Permission strings that are not namespaces and must never be reported missing.
 *
 * `unlimitedStorage` is a quota, `activeTab` is a grant, `webRequestBlocking` is
 * a modifier on `webRequest`, and `declarativeNetRequestWithHostAccess` is a
 * variant of a namespace that *is* here. Reporting any of them as "an API this
 * browser does not have" would be a true-sounding sentence that is false, which
 * is the failure this whole feature is being written against.
 */
const NOT_A_NAMESPACE: readonly string[] = [
  'activeTab',
  'background',
  'clipboardRead',
  'clipboardWrite',
  'unlimitedStorage',
  'webRequestBlocking',
]

/**
 * `declarativeNetRequestWithHostAccess` is `declarativeNetRequest` by another
 * name — a different *grant* over the same namespace.
 *
 * Deliberately here and **not** in {@link NOT_A_NAMESPACE}, which was the first
 * arrangement and was wrong in a way only a test caught: a permission listed in
 * both is filtered out before it is ever aliased, so an extension asking for the
 * host-access variant looked as though it asked for no APIs at all.
 */
const ALIASES: Readonly<Record<string, string>> = {
  declarativeNetRequestWithHostAccess: 'declarativeNetRequest',
  declarativeNetRequestFeedback: 'declarativeNetRequest',
}

/* ------------------------------------------------------------- the manifest -- */

/** Only the parts of a manifest anything here reads. Everything else is ignored. */
export interface ExtensionManifest {
  manifest_version?: unknown
  name?: unknown
  version?: unknown
  description?: unknown
  permissions?: unknown
  optional_permissions?: unknown
  host_permissions?: unknown
  background?: unknown
  action?: unknown
  browser_action?: unknown
  content_scripts?: unknown
  declarative_net_request?: unknown
  default_locale?: unknown
}

function strings(raw: unknown): string[] {
  if (!Array.isArray(raw)) return []
  return raw.filter((entry): entry is string => typeof entry === 'string')
}

function record(raw: unknown): Record<string, unknown> {
  return typeof raw === 'object' && raw !== null ? (raw as Record<string, unknown>) : {}
}

/**
 * Parse the bytes of a `manifest.json`, or say why they are not one.
 *
 * A manifest with no `name` or no `version` is refused here rather than at
 * `loadExtension`, because the store writes a row on disk keyed by both and a
 * missing one would produce an install whose folder says nothing about what is
 * in it.
 */
export function parseManifest(
  bytes: string,
): { ok: true; manifest: ExtensionManifest } | { ok: false; why: string } {
  let raw: unknown
  try {
    raw = JSON.parse(bytes)
  } catch {
    return { ok: false, why: 'its manifest.json is not valid JSON' }
  }
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    return { ok: false, why: 'its manifest.json is not an object' }
  }
  const manifest = raw as ExtensionManifest
  if (typeof manifest.name !== 'string' || manifest.name.trim() === '') {
    return { ok: false, why: 'its manifest.json has no name' }
  }
  if (typeof manifest.version !== 'string' || manifest.version.trim() === '') {
    return { ok: false, why: 'its manifest.json has no version' }
  }
  const mv = manifest.manifest_version
  if (mv !== 2 && mv !== 3) {
    return { ok: false, why: 'its manifest.json is neither manifest version 2 nor 3' }
  }
  return { ok: true, manifest }
}

/**
 * A manifest name is often `__MSG_extName__`, which is a lookup and not a name.
 *
 * Drawing that on a row would be this app repeating a placeholder at somebody
 * as if it were English. `_locales` is not read — resolving it properly means
 * picking a locale, falling back, and handling `default_locale` being absent —
 * so the caller's own name is used instead, which is the catalogue's name and
 * therefore a real one. The check is here rather than at the call site so both
 * the store and the loader answer the same way.
 */
export function displayName(manifest: ExtensionManifest, fallback: string): string {
  const name = typeof manifest.name === 'string' ? manifest.name.trim() : ''
  if (name === '' || /^__MSG_.+__$/.test(name)) return fallback
  return name
}

/* --------------------------------------------------------------- the checks -- */

/**
 * Every namespace this manifest asks for, normalised.
 *
 * Optional permissions are included. An extension that asks for
 * `contextMenus` optionally still has code that calls it, and that code still
 * throws here — the only difference is that the extension asked politely.
 */
export function requestedApis(manifest: ExtensionManifest): string[] {
  const asked = [
    ...strings(manifest.permissions),
    ...strings(manifest.optional_permissions),
  ]
  const out: string[] = []
  for (const raw of asked) {
    // Host permissions can appear in `permissions` in MV2. They are not
    // namespaces and are reported separately, by `reachOf`.
    if (raw.includes('/') || raw.includes('*') || raw === '<all_urls>') continue
    if (NOT_A_NAMESPACE.includes(raw)) continue
    const name = ALIASES[raw] ?? raw
    if (!out.includes(name)) out.push(name)
  }
  return out.sort()
}

/**
 * Which of them are not here.
 *
 * Only namespaces this file has actually measured are reported. A permission
 * nobody probed is left out rather than guessed at in either direction: calling
 * an unmeasured namespace "missing" would put a false sentence on a row, and
 * calling it "present" would put a different false sentence there.
 */
export function missingApis(manifest: ExtensionManifest): string[] {
  return requestedApis(manifest).filter(
    (name) => MISSING_APIS.includes(name) && !SUPPORTED_APIS.includes(name),
  )
}

/** What the extension may reach, in its own words: the host patterns it asks for. */
export function reachOf(manifest: ExtensionManifest): string[] {
  const hosts = [
    ...strings(manifest.host_permissions),
    ...strings(manifest.permissions).filter(
      (raw) => raw === '<all_urls>' || raw.includes('://') || raw.startsWith('*.'),
    ),
  ]
  const out: string[] = []
  for (const host of hosts) if (!out.includes(host)) out.push(host)
  return out.sort()
}

/**
 * Do the content scripts run everywhere?
 *
 * On the row because it is the difference between an extension that reads one
 * site and one that reads every page the person opens, and that difference is
 * invisible in a name.
 */
export function everywhere(manifest: ExtensionManifest): boolean {
  const reach = reachOf(manifest)
  if (reach.includes('<all_urls>')) return true
  return reach.some((pattern) => /^\*:\/\/\*\/\*$|^https?:\/\/\*\/\*$/.test(pattern))
}

/**
 * Will Electron load this, and if not, why not.
 *
 * The one refusal that is not obvious is the MV2 event page: Chromium rejects
 * `webRequest` on a non-persistent MV2 background, with a message naming event
 * pages, and an extension in that shape never reaches its first line of code.
 * Predicting it here means the store can say so on the row instead of the
 * install failing with Chromium's wording halfway through.
 */
export function loadability(manifest: ExtensionManifest): { ok: true } | { ok: false; why: string } {
  const background = record(manifest.background)
  if (manifest.manifest_version === 2) {
    const persistent = background.persistent
    const hasScripts = Array.isArray(background.scripts)
    const usesWebRequest = requestedApis(manifest).includes('webRequest')
    // `persistent` defaults to true in MV2, so only an explicit `false` is an
    // event page. Getting that default backwards would refuse extensions that
    // load perfectly well.
    if (persistent === false && hasScripts && usesWebRequest) {
      return {
        ok: false,
        why:
          'it is a manifest v2 extension whose background is an event page that uses ' +
          'chrome.webRequest — Chromium refuses to load that, with “The ‘webRequest’ API cannot ' +
          'be used with event pages.”',
      }
    }
  }
  return { ok: true }
}

/**
 * Does this extension's blocking rest on static `declarativeNetRequest` rulesets?
 *
 * Measured to be dead on arrival here — see this file's header. Separate from
 * {@link missingApis} because the namespace *is* present: an extension in this
 * shape passes every other check, loads without a warning, and does nothing.
 * The whole point of naming it is that nothing else would.
 */
export function usesStaticRulesets(manifest: ExtensionManifest): boolean {
  const dnr = record(manifest.declarative_net_request)
  return Array.isArray(dnr.rule_resources) && dnr.rule_resources.length > 0
}

/** The popup page a toolbar button would open, or `''` when it draws no button. */
export function popupPage(manifest: ExtensionManifest): string {
  const action = record(manifest.action ?? manifest.browser_action)
  const popup = action.default_popup
  if (typeof popup !== 'string' || popup.trim() === '') return ''
  // Manifests write both `popup.html` and `/popup.html`; the extension URL
  // already ends in a slash, so a leading one would make `chrome-extension://id//popup.html`.
  return popup.trim().replace(/^\/+/, '')
}

/**
 * The limits, in the words a person reads them in, once.
 *
 * Rewritten when `browser-extension-compat.ts` arrived, because three of these
 * sentences had become false. A limits list that goes on naming a limit the app
 * has since closed is the same defect as a control that does nothing, read the
 * other way round: it talks somebody out of an install that would have worked.
 *
 * Exported as data rather than written into JSX so the same sentences can be
 * asserted by a test and reused by the tool an agent calls. A screen and an
 * agent disagreeing about what this browser can do is the same defect as a
 * screen disagreeing with the code.
 */
export const EXTENSION_LIMITS: readonly string[] = [
  'There is no Chrome Web Store here. Every extension in this list is fetched from its own ' +
    'project’s release page and checked against a fingerprint built into this app.',
  'Nothing updates itself. An extension stays at the version this app has written down until a ' +
    'newer build of this app offers a newer one.',
  `This browser is Chromium ${CHROMIUM_MEASURED} inside Electron ${ELECTRON_MEASURED}, which ` +
    'provides only part of the extension API. Missing here: ' +
    `${MISSING_APIS.join(', ')}. This app fills in enough of ` +
    `${COMPAT_PROVIDES.filter((name) => name !== 'storage.sync').join(', ')} for an extension to ` +
    'start, and a row says which of them it filled in and what stays inert.',
  'chrome.storage.sync is not available. This app gives an extension a store of its own that ' +
    'behaves like it and lives on this machine — there is no account here to sync to, and never ' +
    'was. Its manifest cannot show this; it was found by running them.',
  'Filter lists shipped as manifest declarativeNetRequest rulesets are not switched on when an ' +
    'extension loads. This app switches on the ones a manifest marks enabled, once, after ' +
    'installing, and leaves them alone after that.',
  'Packed .crx files cannot be installed, and neither can an extension from the Chrome Web Store.',
]

/** The store refuses these outright, and the sentence it refuses them with. */
export const CANNOT_INSTALL_CRX =
  'A .crx is a packed, signed Chrome extension and this browser cannot open one. Only an ' +
  'unpacked extension, from a project’s own release, can be installed here.'
