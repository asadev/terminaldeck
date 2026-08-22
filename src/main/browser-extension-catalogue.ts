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
 * ## The three answers to “where is X”
 *
 * A store that only lists what it can sell answers *never heard of it* to
 * every question it cannot say yes to, and that is one answer doing the work of
 * three. This catalogue keeps them apart:
 *
 *  - **A row with an Install.** It was run here and it works, or it runs and the
 *    part that matters was not watched.
 *  - **A row that says it cannot work here, with no button.** It was run here
 *    and watched failing, and the row names the line it died on. Six of these,
 *    and no two for the same reason: a missing `chrome.cookies`, a missing
 *    `chrome.tabs.getCurrent`, native messaging switched off, rulesets that ship
 *    disabled, and two whose only trigger is a menu this browser does not draw.
 *  - **A row that says nothing was measured, with no button.** Added because the
 *    first two were both wrong for Vimium, Privacy Badger, SingleFile and
 *    Wappalyzer: their projects publish through the Chrome Web Store and their
 *    release pages carry no file this app could fetch and pin a fingerprint to.
 *    Nothing was run, so nothing is claimed — which is a different sentence from
 *    *it does not work here*, and the row says the one that is true.
 *
 * ## Categories
 *
 * Every row names one, and one only. A row that appeared under three headings
 * would make a catalogue of thirty-six look like a catalogue of sixty, and a
 * store overstating its own size is the first thing that makes the rest of it
 * unbelievable.
 *
 * Three shelves were added on 2026-08-23 — *Writing and language*, *Documents
 * and work*, *Shopping* — because Grammarly, Google Docs Offline and Honey had
 * no honest home among the eight that were here, and filing a coupon finder
 * under *Scripting and the keyboard* would have been the store pretending its
 * old shape still fitted.
 *
 * ## The mainstream half, 2026-08-23
 *
 * Twelve rows were added for extensions people have actually heard of, and not
 * one of them can be installed here:
 *
 *   > *"also all other regular tools too like google's ones or like this."*
 *
 * Every one is a closed product published through the Chrome Web Store and
 * nowhere else — no release file, so nothing to fetch and nothing to fingerprint
 * — which puts all twelve in the third state this file already argued for over
 * Vimium: **nothing was measured**, no button, and a *Get it* that opens the
 * listing. Each listing was fetched on the day and the name on the row is the
 * name that came back in its page title, which is why one of them says *PayPal
 * Honey*.
 *
 * Two things had to give, and both were tests rather than rows. The catalogue
 * used to assert that exactly two rows may want anything from a person, on the
 * ground that *"a browser extension needs nothing from you"* — which stopped
 * being true the moment the store held clients for accounts. And *"is a store
 * rather than a shelf of refusals"* counted rows with a download; kept as it
 * was, it would have argued that answering *where is Grammarly* makes the store
 * worse. Both now check what they were always about: refusals stay a minority,
 * and every row has somewhere to go.
 *
 * ## What it costs
 *
 * Every row carries a price, and it is the field this half of the catalogue
 * could not have been added without. Every extension in a browser store is a
 * free download — that is what a browser store is — so *free to install* had
 * been quietly standing in for *free to use*. It is true of uBlock Origin and
 * false of 1Password, whose extension is a free download of a thing with no free
 * plan at all. The rule, in Asad's words: **never imply free when a key costs
 * money.**
 *
 * The prices were checked the same way the listings were, on the same day, and
 * against each vendor's own plans page rather than from memory: 1Password
 * answers *"Yes. You can try 1Password Individual or Families free for 14 days
 * before choosing a plan"* and prices the Individual plan at $2.99 a month, so
 * that row is `paid`; LastPass's free plan says *"Limited to 1 device type"*;
 * Loom's Starter is $0 with *"25 videos, 5 minute screen recordings"*, which is
 * a cap rather than a trial and therefore `metered`; Grammarly lists Free at $0
 * beside Pro at $12. Each of those sentences is on the row it came from.
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
 * `browser-extension-catalogue.test.ts` holds the shape to that: a row cannot
 * claim `works` without a `measured` sentence, and a row that cannot work cannot
 * carry a download.
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
 */
/**
 * Why a mainstream extension gets a row and no button.
 *
 * One sentence, shared by twelve rows, because it is one fact: they are closed
 * products published through the Chrome Web Store, there is no release file to
 * fetch, and *"this store installs nothing it cannot check"*. Writing twelve
 * paraphrases of that would have made twelve different-looking reasons out of
 * the same one, which is how a catalogue starts sounding like it is arguing.
 */
const WEB_STORE_ONLY =
  'A closed-source product, published through the Chrome Web Store and nowhere else. There is no ' +
  'release file for this app to fetch and no fingerprint to pin one against, so there is nothing ' +
  'here to install — the button opens its own listing instead.'

/**
 * And what this app therefore knows about it: nothing.
 *
 * The word `Watched` is the currency of this file and a row nobody ran must not
 * spend it. Several rows extend this with a *"worth knowing"* clause about the
 * **shape** of the extension — a toolbar button this browser does not draw, a
 * new tab it cannot hand over — which is the same hedge the SingleFile row
 * already makes, and is still not a measurement.
 */
const NOT_RUN_HERE =
  'Nothing was measured. This app has never run it, because there is no artifact to run, so it ' +
  'says nothing about whether it would work in this browser.'

export const BROWSER_EXTENSION_CATALOGUE: readonly ExtensionEntry[] = [
  /* ------------------------- the ones people arrive looking for, 2026-08-23 -- */
  /*
   * Twelve rows nobody can install here, and the store is better for every one
   * of them.
   *
   * Asad, widening both catalogues:
   *
   *   > *"also all other regular tools too like google's ones or like this."*
   *
   * These are the extensions a person has actually heard of, and every one is
   * published through the Chrome Web Store and nowhere else — closed source,
   * with no release file to fetch and no fingerprint to check one against. So
   * none of them carries an Install, and each carries **Get it**, which opens
   * its own listing in a tab of this browser and installs nothing.
   *
   * That is the third answer this file already argued for over Vimium and
   * Privacy Badger, applied where it matters most: *"never heard of it"* and
   * *"it cannot work here"* and *"nothing was measured"* are three different
   * sentences, and the only one that is true of Grammarly is the third.
   *
   * Every listing below was fetched on **2026-08-23** and the name on the row is
   * the name that came back in its page title — which is why this row says
   * *PayPal Honey* rather than *Honey*, and why the Google Keep row is not
   * called what its own product page calls it.
   */
  {
    id: 'google-translate',
    category: 'writing',
    name: 'Google Translate',
    summary: 'Translates a whole page, or just the phrase you selected on it.',
    homepage: 'https://chromewebstore.google.com/detail/aapbdbdomjkkjkaonfhkkikfgjllcleb',
    tags: ['translate', 'translation', 'language', 'google', 'phrase', 'foreign'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'free',
    costNote: 'Free, and it asks for no account. Google’s own extension for its own free service.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured: NOT_RUN_HERE,
    source: null,
  },
  {
    id: 'grammarly',
    category: 'writing',
    name: 'Grammarly',
    summary: 'Checks spelling, grammar and tone as you type, in text boxes on any site.',
    homepage: 'https://chromewebstore.google.com/detail/kbfnbcaeplbcioakkpcpgfkobkghlhen',
    tags: ['grammar', 'spelling', 'writing', 'proofread', 'tone', 'ai'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'account',
    costNote:
      'Free to use with a free Grammarly account — its own plans page lists Free at $0 a month ' +
      'beside Pro. Pro is a paid subscription the extension will keep offering, and what you get ' +
      'without it is real rather than a trial.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured:
      NOT_RUN_HERE +
      ' Worth knowing if you go looking for it another way: it signs in through its own account ' +
      'and works inside the pages you type on, which is the half of the extension API this ' +
      'browser has most of — and that is a shape, not a measurement.',
    source: null,
  },
  {
    id: 'google-docs-offline',
    category: 'work',
    name: 'Google Docs Offline',
    summary: 'Lets Google Docs, Sheets and Slides open and edit with no network.',
    homepage: 'https://chromewebstore.google.com/detail/ghbmnnjooekpmoecnnnilnnbdlolhkhi',
    tags: ['google', 'docs', 'sheets', 'slides', 'offline', 'editing'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'account',
    costNote:
      'Free, and it does nothing without a Google account — it is the offline half of Google’s ' +
      'own free editors rather than a product of its own.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured: NOT_RUN_HERE,
    source: null,
  },
  {
    id: 'todoist',
    category: 'work',
    name: 'Todoist for Chrome',
    summary: 'Adds a task from whatever page you are on, and keeps today’s list a click away.',
    homepage: 'https://chromewebstore.google.com/detail/jldhpllghnbhlbpcmnajkpdmadaolakh',
    tags: ['tasks', 'todo', 'planner', 'reminders', 'productivity', 'list'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'account',
    costNote:
      'Free to use with a free Todoist account. That free plan is limited rather than a trial, ' +
      'and the paid plans lift the limits — the extension itself is not what costs.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured:
      NOT_RUN_HERE +
      ' Worth knowing: adding a task is started from a toolbar button, and this browser draws ' +
      'none — so the shape of it is unpromising here even though nobody has run it.',
    source: null,
  },
  {
    id: 'honey',
    category: 'shopping',
    name: 'PayPal Honey',
    summary: 'Tries known discount codes at the checkout of a shop you are already buying from.',
    homepage: 'https://chromewebstore.google.com/detail/bmnlcjabgnpnenekpadlanbbkooimhnj',
    tags: ['coupons', 'discount', 'deals', 'shopping', 'checkout', 'cashback'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'free',
    costNote:
      'Free, and that is worth a sentence rather than a word: nothing is charged to you, and ' +
      'PayPal is paid a commission by the shops you buy through it. Free of charge is not the ' +
      'same as free of an interest in what you buy.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured: NOT_RUN_HERE,
    source: null,
  },
  {
    id: 'lastpass',
    category: 'passwords',
    name: 'LastPass',
    summary: 'Fills logins out of a LastPass vault and saves new ones as you make them.',
    homepage: 'https://chromewebstore.google.com/detail/hdokiejnpimakedhajhdlcegeplioahd',
    tags: ['password manager', 'vault', 'logins', 'autofill', 'passwords'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'account',
    costNote:
      'Free to install, and its free tier covers one kind of device — computers or phones, not ' +
      'both. Using the same vault across the two is a paid plan.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured:
      NOT_RUN_HERE +
      ' Worth knowing: this app did run Bitwarden, whose whole interface is a panel, and watched ' +
      'it die on chrome.tabs.getCurrent — a method this browser does not have. That says nothing ' +
      'about this extension and everything about the shape it shares.',
    source: null,
  },
  {
    id: 'onepassword',
    category: 'passwords',
    name: '1Password',
    summary: 'Fills logins out of a 1Password account, unlocking in the browser rather than a separate app.',
    homepage: 'https://chromewebstore.google.com/detail/aeblfdkhhhdcdjpifhhbdiojplfjncoa',
    tags: ['password manager', 'vault', 'logins', 'autofill', 'passwords'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'paid',
    costNote:
      'Paid, and it is the row this field was added for. 1Password has no free plan: the ' +
      'extension is a free download that does nothing at all once the trial ends. A store that ' +
      'let “free to install” stand in for “free” would be lying about exactly this row.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured: NOT_RUN_HERE,
    source: null,
  },
  {
    id: 'loom',
    category: 'media',
    name: 'Loom',
    summary: 'Records the screen and camera into a video with a link, without leaving the browser.',
    homepage: 'https://chromewebstore.google.com/detail/liecbddmkiiihnedobmlmillhodjkdmb',
    tags: ['screen recording', 'video', 'camera', 'capture', 'screencast', 'share'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'metered',
    costNote:
      'Free to a limit, then paid. Loom’s free plan caps how long a recording may be and how ' +
      'many you may keep; its paid plans lift both.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured: NOT_RUN_HERE,
    source: null,
  },
  {
    id: 'notion-web-clipper',
    category: 'research',
    name: 'Notion Web Clipper',
    summary: 'Saves the page you are on into a Notion page or database, with its text.',
    homepage: 'https://chromewebstore.google.com/detail/knheggckgoiihginacbkhaalnibhilkk',
    tags: ['clip', 'save page', 'notes', 'notion', 'bookmark', 'research'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'account',
    costNote:
      'Free. Notion’s free personal plan is enough for it; its paid plans buy team features ' +
      'rather than this.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured:
      NOT_RUN_HERE +
      ' Worth knowing: clipping is started from a toolbar button, and this browser draws none — ' +
      'the same shape that leaves SingleFile unpromising here.',
    source: null,
  },
  {
    id: 'save-to-google-drive',
    category: 'research',
    name: 'Save to Google Drive',
    summary: 'Saves a page, an image or a link straight into Google Drive.',
    homepage: 'https://chromewebstore.google.com/detail/gmbmikajjgmnabiglmofipeabaddhgne',
    tags: ['google', 'drive', 'save page', 'screenshot', 'bookmark', 'cloud storage'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'account',
    costNote:
      'Free. It saves into a Google account’s Drive, so what can cost is Drive storage past the ' +
      'free allowance, not this.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured:
      NOT_RUN_HERE +
      ' Worth knowing: saving is started from the right-click menu or a toolbar button, and this ' +
      'browser draws neither — which is what stopped Web Archives and Search by Image after they ' +
      'had loaded perfectly.',
    source: null,
  },
  {
    id: 'google-keep',
    category: 'research',
    name: 'Google Keep Chrome Extension',
    summary: 'Clips a page, an image or a quote into a Google Keep note.',
    homepage: 'https://chromewebstore.google.com/detail/lpcaedmchfhocbbapmcbpinfpgnhiddi',
    tags: ['google', 'keep', 'notes', 'clip', 'save page', 'bookmark'],
    needs: ['account'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'account',
    costNote: 'Free with a Google account.',
    works: 'unmeasured',
    noRelease: WEB_STORE_ONLY,
    measured: NOT_RUN_HERE,
    source: null,
  },
  {
    id: 'momentum',
    category: 'appearance',
    name: 'Momentum',
    summary: 'Replaces the new-tab page with a photograph, a clock and one thing to do today.',
    homepage: 'https://chromewebstore.google.com/detail/laookkfknpbbblfpciffpaejjkokdgca',
    tags: ['new tab', 'dashboard', 'focus', 'wallpaper', 'clock', 'todo'],
    licence: 'Proprietary',
    version: '',
    reach: [],
    cost: 'free',
    costNote:
      'Free to install and use. Momentum Plus is a paid subscription for its extra features, and ' +
      'the free version is not a trial of it.',
    works: 'unmeasured',
    noRelease:
      WEB_STORE_ONLY +
      ' It also replaces the new-tab page, which is `chrome_url_overrides` — a part of a manifest ' +
      'this browser has no new tab to hand over, so even a file to fetch would not have made it ' +
      'a row with a button.',
    measured: NOT_RUN_HERE,
    source: null,
  },
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
    id: 'ghostery',
    category: 'blocking',
    name: 'Ghostery',
    summary: 'Blocks ads and trackers and names what it found on each page.',
    homepage: 'https://github.com/ghostery/ghostery-extension',
    tags: ['ads', 'adblock', 'ad blocker', 'trackers', 'privacy'],
    licence: 'GPL-3.0',
    version: '10.5.57',
    reach: [
      '*://www.youtube.com/*',
      'http://*/*',
      'https://*/*',
      'ws://*/*',
      'wss://*/*',
    ],
    cost: 'free',
    costNote: '',
    works: 'no',
    measured:
      'Watched not blocking. The same three requests every blocker here is measured with were all ' +
      'served, the one to ads.doubleclick.net included. Its service worker throws on ' +
      'chrome.extension.isAllowedIncognitoAccess, on chrome.cookies.getAllCookieStores and on ' +
      'chrome.tabs.create, none of which exist in this browser — and all 33 of its filter ' +
      'rulesets ship marked disabled in its own manifest, so the layer that switches on the ones ' +
      'a manifest enables has nothing to switch on and getEnabledRulesets() answers [].',
    logo: 'ghostery',
    source: null,
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
    id: 'libredirect',
    category: 'privacy',
    name: 'LibRedirect',
    summary:
      'Sends links to popular sites to a privacy-respecting front end for the same content instead.',
    homepage: 'https://github.com/libredirect/browser_extension',
    tags: ['redirect', 'front ends', 'privacy', 'invidious', 'nitter', 'alternatives'],
    licence: 'GPL-3.0',
    version: '3.4.0',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote: '',
    works: 'partly',
    measured:
      'Loads. Its background page runs and its blocking webRequest listener is attached — and it ' +
      'threw inside that listener twice while the test page loaded, once per request: Cannot read ' +
      'properties of undefined (reading “redirectOnlyInIncognito”) inside its own redirect(). No ' +
      'redirect was watched happening, so this app claims none. Its panel opens and throws ' +
      'reading .url of undefined, which is the empty answer this browser gives an extension page ' +
      'asking which tab is in front.',
    logo: 'libredirect',
    source: {
      url: 'https://github.com/libredirect/browser_extension/releases/download/v3.4.0/libredirect-3.4.0.zip',
      bytes: 1_122_989,
      sha256: '6e2d897457cfa85849b38664bc85ce24cf561a61955b5249cdb081235807c963',
    },
  },
  {
    id: 'cookie-autodelete',
    category: 'privacy',
    name: 'Cookie AutoDelete',
    summary: 'Deletes the cookies of a site the moment you close its last tab.',
    homepage: 'https://github.com/Cookie-AutoDelete/Cookie-AutoDelete',
    tags: ['cookies', 'delete', 'clean up', 'privacy'],
    licence: 'MIT',
    version: '3.8.2',
    reach: ['<all_urls>'],
    cost: 'free',
    costNote: '',
    works: 'no',
    measured:
      'Watched failing before it started. Its background page throws Cannot read properties of ' +
      'undefined (reading “onChanged”) — that is chrome.cookies.onChanged, and this browser has ' +
      'no chrome.cookies at all — and its panel throws on cookieStoreId for the same reason. ' +
      'Reading and deleting cookies is the whole of what it does, and there is no cookie API here ' +
      'to do it with, so there is nothing this app could fill in that would help.',
    logo: 'cookie-autodelete',
    source: null,
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
  {
    id: 'bitwarden',
    category: 'passwords',
    name: 'Bitwarden',
    summary: 'The open-source password manager, with its vault in the browser.',
    homepage: 'https://github.com/bitwarden/clients',
    tags: ['password manager', 'vault', 'logins', 'autofill', 'passwords'],
    needs: ['account'],
    licence: 'GPL-3.0',
    version: '2026.8.0',
    reach: ['*://*/*', 'file:///*', 'http://*/*', 'https://*/*'],
    cost: 'account',
    costNote:
      'Free. Bitwarden’s free plan is enough for a personal vault and the extension is the ' +
      'free client for it; the paid plans buy sharing and extras.',
    works: 'no',
    measured:
      'Watched failing. Its service worker starts properly — WebAssembly loads, its SDK loads, its ' +
      'state initialises — and then its panel, which is the whole of its interface, throws ' +
      'chrome.tabs.getCurrent is not a function on the first line of its own polyfill and again ' +
      'inside Angular. chrome.tabs is present here and granted; that one method is simply not on ' +
      'it, which no check of a manifest could ever predict. Nothing else opens it: this browser ' +
      'draws no toolbar button and binds no keyboard shortcut, so a vault that cannot open is all ' +
      'there is.',
    logo: 'bitwarden',
    source: null,
  },
  {
    id: 'keepassxc-browser',
    category: 'passwords',
    name: 'KeePassXC-Browser',
    summary: 'Fills logins out of a KeePassXC database running on this machine.',
    homepage: 'https://github.com/keepassxreboot/keepassxc-browser',
    tags: ['password manager', 'keepass', 'vault', 'logins', 'autofill'],
    needs: ['companion-app'],
    licence: 'GPL-3.0',
    version: '1.10.3',
    reach: ['<all_urls>', 'http://*/*', 'https://*/*'],
    cost: 'free',
    costNote: '',
    works: 'no',
    measured:
      'Watched failing at the one thing it exists for. It loads with no error anywhere — service ' +
      'worker clean, panel clean, settings saved — and then ' +
      'chrome.runtime.connectNative("org.keepassxc.keepassxc_browser") disconnects immediately ' +
      'with “Access to the native messaging host was disabled by the system administrator.” That ' +
      'was measured by connecting. Native messaging is switched off in this browser, and talking ' +
      'to the KeePassXC application over it is how this extension gets every password it has.',
    logo: 'keepassxc-browser',
    source: null,
  },
  {
    id: 'search-by-image',
    category: 'research',
    name: 'Search by Image',
    summary: 'Reverse-searches a picture on the page across a long list of image search engines.',
    homepage: 'https://github.com/dessant/search-by-image',
    tags: ['reverse image search', 'pictures', 'photos', 'lens', 'tineye'],
    licence: 'GPL-3.0',
    version: '8.5.4',
    reach: ['<all_urls>', 'file:///*', 'http://*/*', 'https://*/*'],
    cost: 'free',
    costNote: '',
    works: 'no',
    measured:
      'Watched loading perfectly and then having no way in. Its service worker ran its whole ' +
      'storage migration without one error and its settings page opens — and nothing can start a ' +
      'search: it is begun from the right-click menu, which is chrome.contextMenus, which this ' +
      'app accepts and cannot draw, or from a toolbar button this browser does not have. An ' +
      'extension nobody can invoke is not a working extension, however cleanly it loads.',
    logo: 'search-by-image',
    source: null,
  },
  {
    id: 'web-archives',
    category: 'research',
    name: 'Web Archives',
    summary: 'Opens the archived copy of a page at the Wayback Machine, Archive.today and others.',
    homepage: 'https://github.com/dessant/web-archives',
    tags: ['wayback machine', 'archive', 'cached', 'history', 'snapshot'],
    licence: 'GPL-3.0',
    version: '7.3.3',
    reach: ['<all_urls>', 'http://*/*', 'https://*/*'],
    cost: 'free',
    costNote: '',
    works: 'no',
    measured:
      'Watched loading cleanly and then having no way in, exactly as its sibling does. Its ' +
      'service worker completes its storage migration with no error and its settings page opens; ' +
      'the only ways to ask it for an archived page are the right-click menu, which is ' +
      'chrome.contextMenus and is not drawn here, and a toolbar button this browser does not ' +
      'have. There is no third way to reach it and this app will not pretend there is.',
    logo: 'web-archives',
    source: null,
  },
  {
    id: 'privacy-badger',
    category: 'blocking',
    name: 'Privacy Badger',
    summary:
      'The EFF’s tracker blocker, which learns what is following you rather than reading a list.',
    homepage: 'https://github.com/EFForg/privacybadger',
    tags: ['trackers', 'privacy', 'eff', 'blocking'],
    licence: 'GPL-3.0',
    version: '',
    reach: [],
    cost: 'free',
    costNote: '',
    works: 'unmeasured',
    noRelease:
      'The EFF ships Privacy Badger through the browser stores and its GitHub releases carry no ' +
      'built file — the tags are there, the assets are empty. There is nothing for this app to ' +
      'fetch at a fixed byte count and check against a fingerprint, so there is no row to install.',
    measured:
      'Nothing was measured. This app has never run Privacy Badger, so it says nothing about ' +
      'whether it would work here — which is a different sentence from the ones on the rows above ' +
      'and below, and it is the only true one this app has.',
    logo: 'privacy-badger',
    source: null,
  },
  {
    id: 'singlefile',
    category: 'research',
    name: 'SingleFile',
    summary: 'Saves a whole page — images, styles and all — into one self-contained HTML file.',
    homepage: 'https://github.com/gildas-lormeau/SingleFile',
    tags: ['save page', 'archive', 'offline', 'snapshot', 'html'],
    licence: 'AGPL-3.0',
    version: '',
    reach: [],
    cost: 'free',
    costNote: '',
    works: 'unmeasured',
    noRelease:
      'Its releases carry no built extension: the project publishes through the browser stores ' +
      'and its GitHub tags have no assets on them. Nothing to fetch means nothing to pin a ' +
      'fingerprint to, and this store installs nothing it cannot check.',
    measured:
      'Nothing was measured. Worth knowing if you go looking for it another way: saving a page is ' +
      'started from a toolbar button, a keyboard shortcut or the right-click menu, and this ' +
      'browser draws none of the three — so the shape of it is unpromising here even though ' +
      'nobody has run it.',
    logo: 'singlefile',
    source: null,
  },
  {
    id: 'vimium',
    category: 'scripting',
    name: 'Vimium',
    summary: 'Drives the browser from the keyboard, with vim’s keys.',
    homepage: 'https://github.com/philc/vimium',
    tags: ['keyboard', 'vim', 'shortcuts', 'navigation', 'hints'],
    licence: 'MIT',
    version: '',
    reach: [],
    cost: 'free',
    costNote: '',
    works: 'unmeasured',
    noRelease:
      'philc/vimium publishes no GitHub releases at all — its distribution is the Chrome Web ' +
      'Store — so there is no versioned file for this app to fetch and fingerprint.',
    measured:
      'Nothing was measured. Much of what it does is a content script reading key presses, which ' +
      'is the part of the extension API this browser has most of; its own commands, which are ' +
      'chrome.commands, are not bound here. Neither of those is a measurement and neither is a ' +
      'claim — nobody has run it.',
    logo: 'vimium',
    source: null,
  },
  {
    id: 'wappalyzer',
    category: 'research',
    name: 'Wappalyzer',
    summary: 'Names the framework, analytics and hosting a site is built on.',
    homepage: 'https://www.wappalyzer.com/',
    tags: ['technology', 'stack', 'framework', 'analytics', 'detect'],
    licence: 'unknown',
    version: '',
    reach: [],
    cost: 'unknown',
    costNote:
      'Not known. The open-source repository this row named answers 404, there is nothing ' +
      'left to read, and this app is no more willing to price it than to licence it.',
    works: 'unmeasured',
    noRelease:
      'The open-source repository this app knew, github.com/wappalyzer/wappalyzer, answers 404. ' +
      'There is no release to fetch and no source to read, so this app pins nothing and claims ' +
      'nothing — including about its licence.',
    measured:
      'Nothing was measured, and nothing can be until there is something to run. The row is here ' +
      'because being asked for by name and not being findable are different from being absent.',
    logo: 'wappalyzer',
    source: null,
  },
  {
    id: 'json-formatter',
    category: 'scripting',
    name: 'JSON Formatter',
    summary: 'Turns a raw JSON response in the browser into something you can read and fold.',
    homepage: 'https://github.com/callumlocke/json-formatter',
    tags: ['json', 'pretty print', 'viewer', 'api', 'format'],
    licence: 'BSD-3-Clause',
    version: '',
    reach: [],
    cost: 'free',
    costNote: '',
    works: 'unmeasured',
    noRelease:
      'Its releases carry no built file — the project ships through the Chrome Web Store. There ' +
      'is no versioned artifact for this app to fetch and check a fingerprint against.',
    measured:
      'Nothing was measured. If you want folded JSON in the meantime, the browser here already ' +
      'renders a JSON response as text and the page-reading tools in the other half of this store ' +
      'will parse one — that is this app’s own code and a different thing from an extension.',
    logo: 'json-formatter',
    source: null,
  },
]
