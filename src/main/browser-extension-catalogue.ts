import type { ExtensionEntry } from './browser-extensions'

/**
 * The extensions this app offers, and what each one was measured doing.
 *
 * ## Why a list this app ships rather than one it fetches
 *
 * The same argument `browser-store.ts` makes for its recipes, and it is stronger
 * here because the payload is a program rather than a set of selectors: *"Each
 * entry pins the artifact's sha256, and that digest is in the app's own bytes,
 * not in anything fetched."* A store that fetched its own catalogue would be
 * fetching the fingerprints it verifies downloads against, which is not
 * verification — it is asking the same network twice and believing it the second
 * time.
 *
 * There is a second reason particular to extensions. Every row below carries a
 * **verdict measured by running that exact release inside this app's Electron**,
 * and a verdict is not something a URL can be trusted to hand over. Only a
 * catalogue that ships alongside the app it was measured against can promise
 * that the sentence on the row and the binary underneath it are the same pair
 * that were tested.
 *
 * ## What the verdicts mean, and how each was arrived at
 *
 * Every one of these was loaded into a bare Electron **41.10.5** (Chromium
 * 146.0.7680.216) with its own `--user-data-dir` — never into this app, which
 * was in use at the time — pointed at a local HTTP server, and watched.
 *
 * - `works` — it was observed **doing its job**. Not "it loaded", not "it
 *   asks for nothing missing": the thing it exists to do was seen happening.
 * - `partly` — it loads and runs, and it asks for `chrome.*` namespaces this
 *   Electron does not have. The row names them. Whether the parts that matter to
 *   a given person survive that is not something this app can promise, so it does
 *   not.
 * - `no` — it was watched **failing**. These rows carry no download, no digest
 *   and no Install button, because there is nothing here worth installing and a
 *   button that put it on the disk anyway would be the exact defect this store
 *   is written against. They are listed rather than omitted because the first
 *   question anybody opens an extension store with is *where is uBlock Origin*,
 *   and "it is not in the list" and "it cannot work here" are different answers.
 *
 * The two `no` verdicts for the ad blockers are the important ones and neither
 * is a guess:
 *
 * - **uBlock Origin** loads. Its background page runs and `vAPI` exists. But
 *   `chrome.webRequest.onBeforeRequest.hasListeners()` is `false` — it never
 *   installs the listener that does the blocking, because `chrome.webNavigation`,
 *   `chrome.contextMenus` and `chrome.privacy` are all absent and its start-up
 *   does not survive that. A request to `ads.doubleclick.net` was served,
 *   unblocked, on every attempt across 54 seconds.
 * - **uBlock Origin Lite** dies earlier: its service worker throws
 *   `TypeError: Cannot read properties of undefined (reading 'onRemoved')`
 *   before it finishes starting. Even had it survived, its filter lists ship as
 *   manifest `declarativeNetRequest` rulesets, and those are measured **not
 *   enabled at load** here — `getEnabledRulesets()` answers `[]`.
 *
 * So this app cannot offer an ad blocker, and says so rather than shipping one
 * that installs, appears in the list, and blocks nothing.
 *
 * ## Keeping this honest across releases
 *
 * A version here is a version somebody ran. When one is bumped, the release is
 * re-measured and `measured` is rewritten to what was seen — it is never carried
 * forward on the assumption that a project's next release behaves like its last.
 * `browser-extension-catalogue.test.ts` holds the shape to that: a row cannot
 * claim `works` without a `measured` sentence, and a row that cannot work cannot
 * carry a download.
 */
export const BROWSER_EXTENSION_CATALOGUE: readonly ExtensionEntry[] = [
  {
    id: 'dark-reader',
    name: 'Dark Reader',
    summary: 'Turns every site dark, generating the dark theme itself rather than looking one up.',
    homepage: 'https://github.com/darkreader/darkreader',
    licence: 'MIT',
    version: '4.9.129',
    reach: ['*://*/*'],
    works: 'works',
    measured:
      'Watched working: a plain white test page came back with background rgb(24, 26, 27) and a ' +
      'style.darkreader element injected into it, and its popup opens and renders. Its background ' +
      'worker does log errors here — it reaches for chrome.storage.sync, which this browser has ' +
      'none of — so its saved settings and site list may not survive a restart. It darkens pages ' +
      'regardless; that was checked rather than assumed.',
    source: {
      url: 'https://github.com/darkreader/darkreader/releases/download/v4.9.129/darkreader-chrome-mv3.zip',
      bytes: 831_273,
      sha256: '20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64',
    },
  },
  {
    id: 'clearurls',
    name: 'ClearURLs',
    summary:
      'Strips tracking parameters — utm_source, fbclid and the rest — out of links before they ' +
      'are requested.',
    homepage: 'https://github.com/ClearURLs/Addon',
    licence: 'LGPL-3.0',
    version: '1.27.3',
    reach: ['<all_urls>'],
    works: 'works',
    measured:
      'Watched working: a page opened at ?utm_source=newsletter&utm_medium=email&fbclid=abc123&id=7 ' +
      'arrived at the server as ?id=7, and the server never saw the stripped parameters at all.',
    source: {
      url: 'https://github.com/ClearURLs/Addon/releases/download/1.27.3/ClearURLs.zip',
      bytes: 1_080_297,
      sha256: '2d5c879d3e7d8f562b0ffbb4bd5b4a94884ef404d8ed5637bf4da2601556d148',
    },
  },
  {
    id: 'stylus',
    name: 'Stylus',
    summary: 'Write and apply your own CSS to any site, and manage the styles you have written.',
    homepage: 'https://github.com/openstyles/stylus',
    licence: 'GPL-3.0',
    version: '2.4.11',
    reach: ['<all_urls>'],
    works: 'partly',
    measured:
      'Loads. Its background page runs with no uncaught error. It was not watched applying a ' +
      'style, so this app does not claim it does.',
    source: {
      url: 'https://github.com/openstyles/stylus/releases/download/v2.4.11/stylus-mv2-v2.4.11-id.zip',
      bytes: 1_214_092,
      sha256: '74aa1e55ea719155919c90d281fe94111730bebd0f98cdf5b69ae6e9dd172d7f',
    },
  },
  {
    id: 'violentmonkey',
    name: 'Violentmonkey',
    summary: 'Runs userscripts — small scripts you install to change how particular sites behave.',
    homepage: 'https://github.com/violentmonkey/violentmonkey',
    licence: 'MIT',
    version: '2.48.0',
    reach: ['<all_urls>'],
    works: 'partly',
    measured:
      'Loads. Its background page runs with no uncaught error. It was not watched running a ' +
      'userscript, so this app does not claim it does.',
    source: {
      url: 'https://github.com/violentmonkey/violentmonkey/releases/download/v2.48.0/Violentmonkey-webext-v2.48.0.zip',
      bytes: 680_783,
      sha256: 'e45efc89f485185e1f07b6e68050692bc241cbdf6058230b5f134e27ecdd083a',
    },
  },
  {
    id: 'ublock-origin',
    name: 'uBlock Origin',
    summary: 'The wide-spectrum content blocker.',
    homepage: 'https://github.com/gorhill/uBlock',
    licence: 'GPL-3.0',
    version: '1.73.0',
    reach: ['<all_urls>'],
    works: 'no',
    measured:
      'It loads, and then blocks nothing. Its background page starts but never installs its ' +
      'blocking listener — chrome.webRequest.onBeforeRequest.hasListeners() stays false — because ' +
      'chrome.webNavigation, chrome.contextMenus and chrome.privacy are all missing here. A ' +
      'request to ads.doubleclick.net was served on every attempt over 54 seconds.',
    source: null,
  },
  {
    id: 'ublock-origin-lite',
    name: 'uBlock Origin Lite',
    summary: 'The manifest v3 content blocker.',
    homepage: 'https://github.com/uBlockOrigin/uBOL-home',
    licence: 'GPL-3.0',
    version: '2026.820.1159',
    reach: ['<all_urls>'],
    works: 'no',
    measured:
      'Its service worker throws “Cannot read properties of undefined (reading ‘onRemoved’)” ' +
      'before it finishes starting. Its filter lists are manifest declarativeNetRequest rulesets ' +
      'besides, and those are not switched on when an extension loads here.',
    source: null,
  },
  {
    id: 'sponsorblock',
    name: 'SponsorBlock',
    summary: 'Skips sponsor segments in YouTube videos.',
    homepage: 'https://github.com/ajayyy/SponsorBlock',
    licence: 'GPL-3.0',
    version: '6.1.7',
    reach: ['https://*.youtube.com/*', 'https://sponsor.ajay.app/*'],
    works: 'no',
    measured:
      'Its service worker throws “window is not defined” and then times out waiting for its own ' +
      'start-up. Its settings live in chrome.storage.sync, which does not exist here.',
    source: null,
  },
  {
    id: 'return-youtube-dislike',
    name: 'Return YouTube Dislike',
    summary: 'Puts the dislike count back on YouTube videos.',
    homepage: 'https://github.com/Anarios/return-youtube-dislike',
    licence: 'GPL-3.0',
    version: '4.0.4',
    reach: ['*://*.youtube.com/*', '*://returnyoutubedislikeapi.com/*'],
    works: 'no',
    measured:
      'Every setting it reads comes back undefined: it keeps them in chrome.storage.sync, and ' +
      'reading that fails here with “‘sync’ is not available in this instance of Chrome”.',
    source: null,
  },
  {
    id: 'isdcac',
    name: 'I still don’t care about cookies',
    summary: 'Dismisses cookie banners.',
    homepage: 'https://github.com/OhMyGuus/I-Still-Dont-Care-About-Cookies',
    licence: 'GPL-3.0',
    version: '1.1.9',
    reach: ['http://*/*', 'https://*/*'],
    works: 'no',
    measured:
      'Its service worker throws “Cannot read properties of undefined (reading ‘onCommitted’)” ' +
      'immediately: it hangs its whole start-up on chrome.webNavigation, which is missing here.',
    source: null,
  },
]
