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
 * ## The verdicts that changed, and why they were allowed to
 *
 * Five of these rows once said `no`, and two of those were the ad blockers —
 * the first thing anybody opens an extension store looking for. Every one of
 * the five has been re-measured against `browser-extension-compat.ts`, which
 * closes the part of the gap that can be closed, and four of them moved.
 *
 * The re-measurement was the same shape as the refusals it overturned: a bare
 * Electron with its own `--user-data-dir`, a local HTTP server, and
 * `ads.doubleclick.net` and a consent-manager script host both pointed at that
 * server with `--host-resolver-rules`, so **a blocked request is a request the
 * server never receives** rather than an error message somebody interpreted. A
 * script from an innocent third host loaded in every run, so "blocked" is never
 * confused with "the network broke". The table, requests received out of three:
 *
 * ```
 *                                  ads   consent script   control
 *   no extension at all             3          1             1
 *   uBlock Origin, before           3          –             1
 *   uBlock Origin, now              0          1             1
 *   uBlock Origin Lite, before      3          –             1
 *   uBlock Origin Lite, now         0          1             1
 *   I still don’t care…, before     3          1             1
 *   I still don’t care…, now        3          0             1
 * ```
 *
 * None of the three was failing at its job. Each died before starting one —
 * uBlock Origin on `chrome.browserAction` being undefined, uBlock Origin Lite
 * on `chrome.permissions`, I still don’t care about cookies on
 * `chrome.webNavigation` — and none of those three namespaces is what any of
 * them blocks with. That is the whole of why the verdicts could move without
 * anything being fudged: what changed is that the extension now reaches its own
 * first line, and what it does from there was watched, on this Electron, in
 * these runs.
 *
 * What that layer costs is on the row too, in {@link ExtensionEntry.measured}
 * and in the store view's `inert` line: a badge that is not drawn, a right-click
 * entry that is not shown, a keyboard shortcut that is not bound. Those are
 * stated rather than discovered, and they are a different kind of thing from a
 * control that pretends. See `browser-extension-compat.ts` for which parts of
 * the layer are backed by something real and which are only present.
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
    works: 'works',
    measured:
      'Watched blocking. Three requests to ads.doubleclick.net were sent from a test page: with ' +
      'this app’s compatibility layer the local server they were pointed at received none of ' +
      'them, and a script from an unrelated host loaded in the same run, so nothing was merely ' +
      'broken. Its background page starts with no uncaught error and ' +
      'chrome.webRequest.onBeforeRequest.hasListeners() is true. Without the layer the same run ' +
      'served all three and hasListeners() stayed false — it was never a blocking problem, it was ' +
      'chrome.browserAction being undefined here, which its own webext.js reads at module load. ' +
      'What it does not get: its toolbar badge and icon are not drawn, its right-click “Block ' +
      'element” entry is not in the page menu, its keyboard shortcuts are not bound, and it is ' +
      'told about main-frame navigations only.',
    source: {
      url: 'https://github.com/gorhill/uBlock/releases/download/1.73.0/uBlock0_1.73.0.chromium.zip',
      bytes: 4_675_783,
      sha256: '22c62bc0f35ed0c5e95d1fc831a829af199c7ca6fdb4f841be034c25719ce911',
    },
  },
  {
    id: 'ublock-origin-lite',
    name: 'uBlock Origin Lite',
    summary: 'The manifest v3 content blocker.',
    homepage: 'https://github.com/uBlockOrigin/uBOL-home',
    licence: 'GPL-3.0',
    version: '2026.820.1159',
    reach: ['<all_urls>'],
    works: 'works',
    measured:
      'Watched blocking, by the same three requests to ads.doubleclick.net: none of them reached ' +
      'the server, and the control script from an unrelated host loaded. Its service worker now ' +
      'starts with no uncaught error, and getEnabledRulesets() answers with all six of its filter ' +
      'lists where it answered [] before. Without the layer it threw on ' +
      'chrome.permissions.onRemoved before it finished starting and all three ads were served. ' +
      'Its keyboard shortcuts are not bound.',
    source: {
      url: 'https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.820.1159/uBOLite_2026.820.1159.chromium.zip',
      bytes: 9_723_591,
      sha256: '45642289ed7c2c46dc8a3a20e801e452a1d180a9718be9a1074021d3d5b94205',
    },
  },
  {
    id: 'sponsorblock',
    name: 'SponsorBlock',
    summary: 'Skips sponsor segments in YouTube videos.',
    homepage: 'https://github.com/ajayyy/SponsorBlock',
    licence: 'GPL-3.0',
    version: '6.1.7',
    reach: ['https://*.youtube.com/*', 'https://sponsor.ajay.app/*'],
    works: 'works',
    measured:
      'Watched skipping: on a video with a sponsor segment from 0:00 to 1:28 the player was past ' +
      'it seconds after the video began, the segment was drawn on the progress bar, and its ' +
      'controls were in the player. An honest correction to this row’s old verdict — the skip is ' +
      'done by its content script and happened with or without this app’s compatibility layer, so ' +
      '“it cannot work here” was never true of the thing it exists to do. What the layer fixes is ' +
      'its service worker, which used to throw “window is not defined” and then time out waiting ' +
      'for itself: without it the panel opens with “sync” is not available on the console and ' +
      'nothing you change there is kept.',
    source: {
      url: 'https://github.com/ajayyy/SponsorBlock/releases/download/6.1.7/ChromeExtension.zip',
      bytes: 1_845_183,
      sha256: '7c8e3dc8b5e560b480ae8efdf28f4f1101fce0cc32434562a336a89e4962eda3',
    },
  },
  {
    id: 'return-youtube-dislike',
    name: 'Return YouTube Dislike',
    summary: 'Puts the dislike count back on YouTube videos.',
    homepage: 'https://github.com/Anarios/return-youtube-dislike',
    licence: 'GPL-3.0',
    version: '4.0.4',
    reach: ['*://*.youtube.com/*', '*://returnyoutubedislikeapi.com/*'],
    works: 'works',
    measured:
      'Watched working: on a real video the dislike button read 518K, fetched live from ' +
      'returnyoutubedislikeapi.com/votes, with its ratio bar drawn under the player. An honest ' +
      'correction to this row’s old verdict — the count came back on that page with or without ' +
      'this app’s compatibility layer, so “it cannot work here” was never true of the thing it ' +
      'exists to do. What the layer fixes is everything around it: without it, its panel opened ' +
      'with “sync” is not available on the console and every setting undefined, and with it the ' +
      'panel opens whole and its options save.',
    source: {
      url: 'https://github.com/Anarios/return-youtube-dislike/releases/download/v4.0.4/chrome.zip',
      bytes: 1_273_186,
      sha256: '4cf9d401c81cf52b813141a973450ca704fba7478d4105e2bf4a39454a9d9117',
    },
  },
  {
    id: 'isdcac',
    name: 'I still don’t care about cookies',
    summary: 'Dismisses cookie banners.',
    homepage: 'https://github.com/OhMyGuus/I-Still-Dont-Care-About-Cookies',
    licence: 'GPL-3.0',
    version: '1.1.9',
    reach: ['http://*/*', 'https://*/*'],
    works: 'works',
    measured:
      'Watched blocking a consent manager. A test page asked for a script whose path matches one ' +
      'of its 1,734 rules; with this app’s compatibility layer the local server it was pointed at ' +
      'never received the request, and without the layer it received it every time. Its service ' +
      'worker starts with no uncaught error, where it used to throw on ' +
      'chrome.webNavigation.onCommitted before it started, and getEnabledRulesets() answers with ' +
      'its ruleset where it answered [] before. Its desktop notifications do not appear, and it ' +
      'is told about main-frame navigations only.',
    source: {
      url: 'https://github.com/OhMyGuus/I-Still-Dont-Care-About-Cookies/releases/download/v1.1.9/ISDCAC-chrome-source.zip',
      bytes: 539_792,
      sha256: '8f70ab947cb2d274f4022a970f5dd3cecd8ec02b060e05187bef9ee3cb18bbcb',
    },
  },
]
