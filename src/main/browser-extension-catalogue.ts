import type { CatalogueEntry } from './browser-extensions'

/**
 * The extensions this app offers — and it offers nothing it cannot install and
 * has not watched run.
 *
 * ## The rule, and the day it changed
 *
 * This catalogue used to hold thirty-six rows and install twelve of them. The
 * other twenty-four carried a **Get it** button that opened the Chrome Web
 * Store, on the argument that *"never heard of it"* and *"it cannot work here"*
 * are different sentences and a store should be able to say the second one.
 * That argument was about honesty and it was not wrong about honesty. It was
 * wrong about what a store is. Asad, on the store as built:
 *
 *   > *"You have added everything. They click Get and it takes them to the
 *   > Chrome store, which gives extensions that require a newer Chrome than the
 *   > one we have in Terminal Deck. … we only give the option to install those
 *   > tools that can actually install in this one, and it will not redirect
 *   > them to the Chrome store. We should not offer tools that don't work with
 *   > our architecture."*
 *
 * So the rule is now structural rather than editorial, and {@link
 * CatalogueEntry} is where it lives: **a catalogue row has a pinned download and
 * a verdict of `works` or `partly`.** A row with no artifact and a row watched
 * failing cannot be written down here at all — the type refuses them, so this
 * file cannot drift back into a shelf of things to go and get somewhere else.
 * Twenty-four rows went; twelve stayed. What each one was and why it went is at
 * the bottom of this header.
 *
 * ## The Chromium question, measured rather than assumed
 *
 * The complaint above contains a mechanism — *extensions that require a newer
 * Chrome* — and it is a real one. An extension whose manifest declares
 * `minimum_chrome_version` above this browser's is refused outright by
 * `loadExtension`, with *"This extension requires Chromium version N or
 * greater."* That was measured, not recalled: a probe manifest was loaded at
 * 146, 148, 150 and 151 against both builds below, and the boundary is exact.
 *
 * What is **not** true is that a newer Chromium would let this store hold more.
 * Both builds were run with the same probe extension — one asking for every
 * namespace worth asking for — with their own `--user-data-dir`:
 *
 * ```
 *                        Electron 41.10.5      Electron 43.4.1
 *                        Chromium 146.0.7680   Chromium 150.0.7871
 *   chrome.* present     14 namespaces         the same 14
 *   chrome.* absent      20 namespaces         the same 20
 *   chrome.tabs methods  no create/getCurrent  the same
 *   storage.sync         throws                throws, same message
 *   active-tab query     []                    []
 *   connectNative        not a function        not a function
 * ```
 *
 * Identical, in every field. The gap this catalogue is written around is
 * **Electron's**, not Chromium's: Electron implements a deliberately small slice
 * of the extension API and that slice did not grow between Chromium 146 and 150.
 * Moving forward would raise the `minimum_chrome_version` ceiling from 146 to
 * 150 and change nothing else — and not one row was excluded by that ceiling.
 * See `browser-extension-support.ts`, which holds the measurement.
 *
 * ## What a verdict means
 *
 * Every row below was loaded into the Electron this app ships, with its own
 * `--user-data-dir` — never into this app, which was in use at the time —
 * pointed at a local HTTP server, and watched.
 *
 * - `works` — it was observed **doing its job**. Not "it loaded", not "it asks
 *   for nothing missing": the thing it exists to do was seen happening.
 * - `partly` — it installs, loads and runs with no uncaught error, and it asks
 *   for `chrome.*` namespaces this Electron does not have. The row names them.
 *   Three rows, and each says in its own words what was and was not watched.
 *   Whether the parts that matter to a given person survive that is not
 *   something this app can promise, so it does not.
 *
 * There is no third value, because a store that installs nothing else has no use
 * for one.
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
 * There is a second reason particular to extensions. Every row carries a verdict
 * **measured by running that exact release inside this app's Electron**, and a
 * verdict is not something a URL can be trusted to hand over. Only a catalogue
 * that ships alongside the app it was measured against can promise that the
 * sentence on the row and the binary underneath it are the same pair that were
 * tested.
 *
 * ## Categories
 *
 * Every row names one, and one only. A row that appeared under three headings
 * would make a catalogue of twelve look like a catalogue of thirty, and a store
 * overstating its own size is the first thing that makes the rest of it
 * unbelievable.
 *
 * Five shelves emptied when the rule above was applied — *Passwords*, *Writing
 * and language*, *Documents and work*, *Shopping*, *Saving and research* — and
 * they were deleted rather than left standing with nothing on them. A shelf
 * whose every row was a link somewhere else is not a shelf this store has; the
 * honest catalogue is five shelves and the one somebody fills themselves. What
 * would put *Passwords* back is not a bigger list: it is native messaging, and
 * `browser-extension-support.ts` says exactly why nothing here can fake it.
 *
 * ## Keeping this honest across releases
 *
 * A version here is a version somebody ran. When one is bumped, the release is
 * re-measured and `measured` is rewritten to what was seen — it is never carried
 * forward on the assumption that a project's next release behaves like its last.
 *
 * The harness that does the running is `scripts/measure-extension.mjs`, and it
 * is in the repository for exactly this reason: it was thrown away after the
 * first round of measurements, which meant the next person to bump a version
 * either rebuilt it or quietly carried an old sentence forward. Run it twice,
 * plain and `--no-compat`, because the difference between the two runs is what
 * most of the sentences below are actually made of.
 * `browser-extension-catalogue.test.ts` holds the shape to that: every row has a
 * download and a measured sentence, and nothing that was watched failing can be
 * written down here at all.
 *
 * ## The marks
 *
 * Every row names one in `logo`, and the picture behind that name lives in
 * `renderer/store/logo-data.ts` — inside this app, never at the end of a URL, for
 * the reason that module's header gives. `node scripts/store-logos.mjs` is what
 * fetched them and what refreshes them; `--check` re-fetches and names any whose
 * upstream bytes have moved. A row added without one draws this app's own
 * monogram rather than nothing, so the field is optional and adding a row does
 * not require the network.
 *
 * ## The twenty-four that went, and why
 *
 * Nothing here was deleted for being unpopular. Each fell into one of three
 * groups, and the group is the reason:
 *
 *  - **Seventeen had no artifact to install.** Google Translate, Grammarly,
 *    Google Docs Offline, Todoist, PayPal Honey, LastPass, 1Password, Loom,
 *    Notion Web Clipper, Save to Google Drive, Google Keep, Momentum, Privacy
 *    Badger, SingleFile, Vimium, Wappalyzer, JSON Formatter. Every one publishes
 *    through the Chrome Web Store and nowhere this app can fetch from, so every
 *    one was a **Get it** that left this app for a store this app cannot install
 *    from. Nothing was ever measured about any of them; nothing is claimed about
 *    any of them now.
 *  - **Six were watched failing here.** Ghostery (its service worker throws on
 *    `chrome.extension.isAllowedIncognitoAccess`, `chrome.cookies` and
 *    `chrome.tabs.create`, and all 33 of its rulesets ship disabled), Cookie
 *    AutoDelete (there is no `chrome.cookies` at all and cookies are the whole
 *    of its job), Bitwarden (`chrome.tabs.getCurrent is not a function` on the
 *    first line of its own polyfill, and its panel is its entire interface),
 *    KeePassXC-Browser (native messaging is off, which is how it gets every
 *    password it has), Search by Image and Web Archives (both load cleanly and
 *    are startable only from a right-click menu this browser does not draw).
 *  - **One installed and ran and did not do its job.** LibRedirect's blocking
 *    `webRequest` listener attaches and then throws inside its own `redirect()`
 *    once per request — *Cannot read properties of undefined (reading
 *    "redirectOnlyInIncognito")* — and no redirect was ever watched happening.
 *    It loaded, which is why it used to read `partly`; loading is not the job.
 *
 * The three that stayed at `partly` differ from that last one in exactly one
 * way: nothing in the path that does their job was watched throwing. Stylus and
 * Violentmonkey load with no uncaught error and were not watched applying a
 * style or running a userscript; Consent-O-Matic fetched its rule list and
 * searched a page correctly, and no consent dialog was ever put in front of it.
 * Each row says so in its own sentence rather than borrowing a neighbour's.
 */

export const BROWSER_EXTENSION_CATALOGUE: readonly CatalogueEntry[] = [
  {
    id: 'dark-reader',
    category: 'appearance',
    name: 'Dark Reader',
    summary: 'Turns every site dark, generating the dark theme itself rather than looking one up.',
    homepage: 'https://github.com/darkreader/darkreader',
    tags: ['dark mode', 'night', 'theme', 'contrast', 'eyes'],
    licence: 'MIT',
    version: '4.9.129',
    reach: ['*://*/*', '<all_urls>'],
    cost: 'free',
    costNote: '',
    works: 'works',
    measured:
      'Watched working: a plain white test page came back with background rgb(24, 26, 27) and a ' +
      'style.darkreader element injected into it, and its popup opens and renders. Its background ' +
      'worker does log errors here — it reaches for chrome.storage.sync, which this browser has ' +
      'none of — so its saved settings and site list may not survive a restart. It darkens pages ' +
      'regardless; that was checked rather than assumed.',
    logo: 'dark-reader',
    source: {
      url: 'https://github.com/darkreader/darkreader/releases/download/v4.9.129/darkreader-chrome-mv3.zip',
      bytes: 831_273,
      sha256: '20e7993eee8015f7db18748eea366616dfd05ec477efb7be6ae52d2b221b0a64',
    },
  },
  {
    id: 'clearurls',
    category: 'privacy',
    name: 'ClearURLs',
    summary:
      'Strips tracking parameters — utm_source, fbclid and the rest — out of links before they ' +
      'are requested.',
    homepage: 'https://github.com/ClearURLs/Addon',
    tags: ['tracking', 'utm', 'fbclid', 'links', 'clean', 'parameters'],
    licence: 'LGPL-3.0',
    version: '1.27.3',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote: '',
    works: 'works',
    measured:
      'Watched working: a page opened at ?utm_source=newsletter&utm_medium=email&fbclid=abc123&id=7 ' +
      'arrived at the server as ?id=7, and the server never saw the stripped parameters at all.',
    logo: 'clearurls',
    source: {
      url: 'https://github.com/ClearURLs/Addon/releases/download/1.27.3/ClearURLs.zip',
      bytes: 1_080_297,
      sha256: '2d5c879d3e7d8f562b0ffbb4bd5b4a94884ef404d8ed5637bf4da2601556d148',
    },
  },
  {
    id: 'stylus',
    category: 'appearance',
    name: 'Stylus',
    summary: 'Write and apply your own CSS to any site, and manage the styles you have written.',
    homepage: 'https://github.com/openstyles/stylus',
    tags: ['css', 'userstyles', 'theme', 'custom styles', 'restyle'],
    licence: 'GPL-3.0',
    version: '2.4.11',
    reach: ['<all_urls>', 'https://userstyles.org/*'],
    cost: 'free',
    costNote: '',
    works: 'partly',
    measured:
      'Loads. Its background page runs with no uncaught error. It was not watched applying a ' +
      'style, so this app does not claim it does.',
    logo: 'stylus',
    source: {
      url: 'https://github.com/openstyles/stylus/releases/download/v2.4.11/stylus-mv2-v2.4.11-id.zip',
      bytes: 1_214_092,
      sha256: '74aa1e55ea719155919c90d281fe94111730bebd0f98cdf5b69ae6e9dd172d7f',
    },
  },
  {
    id: 'violentmonkey',
    category: 'scripting',
    name: 'Violentmonkey',
    summary: 'Runs userscripts — small scripts you install to change how particular sites behave.',
    homepage: 'https://github.com/violentmonkey/violentmonkey',
    tags: ['userscripts', 'greasemonkey', 'tampermonkey', 'scripts'],
    licence: 'MIT',
    version: '2.48.0',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote: '',
    works: 'partly',
    measured:
      'Loads. Its background page runs with no uncaught error. It was not watched running a ' +
      'userscript, so this app does not claim it does.',
    logo: 'violentmonkey',
    source: {
      url: 'https://github.com/violentmonkey/violentmonkey/releases/download/v2.48.0/Violentmonkey-webext-v2.48.0.zip',
      bytes: 680_783,
      sha256: 'e45efc89f485185e1f07b6e68050692bc241cbdf6058230b5f134e27ecdd083a',
    },
  },
  {
    id: 'ublock-origin',
    category: 'blocking',
    name: 'uBlock Origin',
    summary: 'The wide-spectrum content blocker.',
    homepage: 'https://github.com/gorhill/uBlock',
    tags: ['ads', 'adblock', 'ad blocker', 'trackers', 'filters', 'pop-ups'],
    licence: 'GPL-3.0',
    version: '1.73.0',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote: '',
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
    logo: 'ublock-origin',
    source: {
      url: 'https://github.com/gorhill/uBlock/releases/download/1.73.0/uBlock0_1.73.0.chromium.zip',
      bytes: 4_675_783,
      sha256: '22c62bc0f35ed0c5e95d1fc831a829af199c7ca6fdb4f841be034c25719ce911',
    },
  },
  {
    id: 'ublock-origin-lite',
    category: 'blocking',
    name: 'uBlock Origin Lite',
    summary: 'The manifest v3 content blocker.',
    homepage: 'https://github.com/uBlockOrigin/uBOL-home',
    tags: ['ads', 'adblock', 'ad blocker', 'trackers', 'filters', 'manifest v3'],
    licence: 'GPL-3.0',
    version: '2026.820.1159',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote: '',
    works: 'works',
    measured:
      'Watched blocking, by the same three requests to ads.doubleclick.net: none of them reached ' +
      'the server, and the control script from an unrelated host loaded. Its service worker now ' +
      'starts with no uncaught error, and getEnabledRulesets() answers with all six of its filter ' +
      'lists where it answered [] before. Without the layer it threw on ' +
      'chrome.permissions.onRemoved before it finished starting and all three ads were served. ' +
      'Its keyboard shortcuts are not bound.',
    logo: 'ublock-origin-lite',
    source: {
      url: 'https://github.com/uBlockOrigin/uBOL-home/releases/download/2026.820.1159/uBOLite_2026.820.1159.chromium.zip',
      bytes: 9_723_591,
      sha256: '45642289ed7c2c46dc8a3a20e801e452a1d180a9718be9a1074021d3d5b94205',
    },
  },
  {
    id: 'sponsorblock',
    category: 'media',
    name: 'SponsorBlock',
    summary: 'Skips sponsor segments in YouTube videos.',
    homepage: 'https://github.com/ajayyy/SponsorBlock',
    tags: ['youtube', 'sponsors', 'skip', 'video', 'segments'],
    licence: 'GPL-3.0',
    version: '6.1.7',
    reach: [
      'https://*.youtube.com/*',
      'https://sponsor.ajay.app/*',
      'https://www.youtube-nocookie.com/embed/*',
    ],
    mayAskToReach: ['*://*/*'],
    cost: 'free',
    costNote: '',
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
    logo: 'sponsorblock',
    source: {
      url: 'https://github.com/ajayyy/SponsorBlock/releases/download/6.1.7/ChromeExtension.zip',
      bytes: 1_845_183,
      sha256: '7c8e3dc8b5e560b480ae8efdf28f4f1101fce0cc32434562a336a89e4962eda3',
    },
  },
  {
    id: 'return-youtube-dislike',
    category: 'media',
    name: 'Return YouTube Dislike',
    summary: 'Puts the dislike count back on YouTube videos.',
    homepage: 'https://github.com/Anarios/return-youtube-dislike',
    tags: ['youtube', 'dislikes', 'ratings', 'video'],
    licence: 'GPL-3.0',
    version: '4.0.4',
    reach: [
      '*://*.youtube.com/*',
      '*://m.youtube.com/*',
      '*://returnyoutubedislikeapi.com/*',
      '*://www.youtube.com/*',
      '*://youtube.com/*',
    ],
    cost: 'free',
    costNote: '',
    works: 'works',
    measured:
      'Watched working: on a real video the dislike button read 518K, fetched live from ' +
      'returnyoutubedislikeapi.com/votes, with its ratio bar drawn under the player. An honest ' +
      'correction to this row’s old verdict — the count came back on that page with or without ' +
      'this app’s compatibility layer, so “it cannot work here” was never true of the thing it ' +
      'exists to do. What the layer fixes is everything around it: without it, its panel opened ' +
      'with “sync” is not available on the console and every setting undefined, and with it the ' +
      'panel opens whole and its options save.',
    logo: 'return-youtube-dislike',
    source: {
      url: 'https://github.com/Anarios/return-youtube-dislike/releases/download/v4.0.4/chrome.zip',
      bytes: 1_273_186,
      sha256: '4cf9d401c81cf52b813141a973450ca704fba7478d4105e2bf4a39454a9d9117',
    },
  },
  {
    id: 'isdcac',
    category: 'privacy',
    name: 'I still don’t care about cookies',
    summary: 'Dismisses cookie banners.',
    homepage: 'https://github.com/OhMyGuus/I-Still-Dont-Care-About-Cookies',
    tags: ['cookies', 'banners', 'consent', 'gdpr', 'pop-ups'],
    licence: 'GPL-3.0',
    version: '1.1.9',
    reach: ['http://*/*', 'https://*/*'],
    cost: 'free',
    costNote: '',
    works: 'works',
    measured:
      'Watched blocking a consent manager. A test page asked for a script whose path matches one ' +
      'of its 1,734 rules; with this app’s compatibility layer the local server it was pointed at ' +
      'never received the request, and without the layer it received it every time. Its service ' +
      'worker starts with no uncaught error, where it used to throw on ' +
      'chrome.webNavigation.onCommitted before it started, and getEnabledRulesets() answers with ' +
      'its ruleset where it answered [] before. Its desktop notifications do not appear, and it ' +
      'is told about main-frame navigations only.',
    logo: 'isdcac',
    source: {
      url: 'https://github.com/OhMyGuus/I-Still-Dont-Care-About-Cookies/releases/download/v1.1.9/ISDCAC-chrome-source.zip',
      bytes: 539_792,
      sha256: '8f70ab947cb2d274f4022a970f5dd3cecd8ec02b060e05187bef9ee3cb18bbcb',
    },
  },
  {
    id: 'adguard',
    category: 'blocking',
    name: 'AdGuard',
    summary: 'A wide-spectrum blocker whose filter lists ship inside it rather than being fetched.',
    homepage: 'https://github.com/AdguardTeam/AdguardBrowserExtension',
    tags: ['ads', 'adblock', 'ad blocker', 'trackers', 'filters'],
    licence: 'GPL-3.0',
    version: '5.5.1.0',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote:
      'Free. The AdGuard browser extension costs nothing; what AdGuard sells is its desktop ' +
      'and mobile applications, which this is not one of.',
    works: 'works',
    measured:
      'Watched blocking. Three requests went out of a test page — ads.doubleclick.net, a ' +
      'consent-manager host, and an unrelated host as a control — and the local server all three ' +
      'were pointed at received the second and third and never the first, on four runs. Its ' +
      'manifest marks one of its 53 declarativeNetRequest rulesets enabled and this app switches ' +
      'that one on: getEnabledRulesets() answers ruleset_2, where without the layer it answers [] ' +
      'and all three requests are served. The fifth run, the first after unpacking while it was ' +
      'still fetching filter updates, served the ad — its first seconds after an install are not ' +
      'covered by this. Its own panel is broken here: it opens and throws on options being ' +
      'undefined, and its polyfill logs that chrome.tabs.create is not a function.',
    logo: 'adguard',
    source: {
      url: 'https://github.com/AdguardTeam/AdguardBrowserExtension/releases/download/v5.5.1.0/chrome-mv3.zip',
      bytes: 29_210_647,
      sha256: 'cee0136f7f125a0250794ec9dc0e2c4f42c7a1b3177ffea7e2636ae982bbf912',
    },
  },
  {
    id: 'consent-o-matic',
    category: 'privacy',
    name: 'Consent-O-Matic',
    summary:
      'Answers cookie dialogs the way you said to, from rules written by a university research ' +
      'group rather than by the sites.',
    homepage: 'https://github.com/cavi-au/Consent-O-Matic',
    tags: ['cookies', 'consent', 'banners', 'gdpr'],
    licence: 'MIT',
    version: '1.1.5',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote: '',
    works: 'partly',
    measured:
      'Loads and runs. Its service worker fetched its rule list, searched the test page and ' +
      'reported nothing found, which is the correct answer for a page with no consent dialog on ' +
      'it — but a real one was never put in front of it here, so this app does not claim it ' +
      'answers those. Its panel opens and then throws reading .url of undefined: an extension ' +
      'page in this browser gets [] from chrome.tabs.query for the active tab. chrome.tabs.create ' +
      'is also missing, which it logs on start-up.',
    logo: 'consent-o-matic',
    source: {
      url: 'https://github.com/cavi-au/Consent-O-Matic/releases/download/v1.1.5/consent-o-matic-v1.1.5-unpacked-release-chromium.zip',
      bytes: 88_188,
      sha256: '37cec881fc5f53c84419e39d6a01cb79ff0b06b8df556219ac5c74887ba1473a',
    },
  },
  {
    id: 'video-speed-controller',
    category: 'media',
    name: 'Video Speed Controller',
    summary: 'Speed up, slow down, and step through any HTML5 video with the keyboard.',
    homepage: 'https://github.com/igrigorik/videospeed',
    tags: ['video', 'speed', 'playback', 'html5', 'keyboard'],
    licence: 'MIT',
    version: '0.11.1',
    reach: ['file:///*', 'http://*/*', 'https://*/*'],
    cost: 'free',
    costNote: '',
    works: 'works',
    measured:
      'Watched speeding a video up. On a page playing a video its own vsc-controller element was ' +
      'in the page, and two presses of d moved the video’s playbackRate from 1 to 1.2. Without ' +
      'this app’s compatibility layer neither happened: its content script threw “sync” is not ' +
      'available in this instance of Chrome before it could read a setting, and its panel opened ' +
      'with every control undefined. Note what it reaches: it asks for no host permissions at all ' +
      'and declares content scripts on every http and https page and on local files, which is the ' +
      'same thing by another route.',
    logo: 'video-speed-controller',
    source: {
      url: 'https://github.com/igrigorik/videospeed/releases/download/v0.11.1/videospeed-0.11.1.zip',
      bytes: 101_763,
      sha256: '511e977c0399afe8f14b724c7fcf4e673e2d648f895bc01a911b25ad84c4f18c',
    },
  },
]
