# Wiring — lane `mcp-browser` (0.16.0)

Everything in the browser area of the checklist now has a tool or a stated reason
(`src/main/deck-control/actions/browser.ts`: 100 tools, 17 skips). The tools are built
by factories that take plain-function deps; one helper closes them over the real
modules, so `src/main/index.ts` needs **two edits**: one import, one spread, and three
spread-in lines on the existing `extensionTools({...})` call.

Mac only, per the scope change. No headless-host wiring is owed (the headless host has
its own `machine-browser.ts`; nothing here touches it).

## 1. `src/main/index.ts` — the import

Next to the other `./deck-control/*` imports (around line 246, beside `workerTools`):

```ts
import { browserAreaTools, extensionManageDeps } from './deck-control/browser-area-tools'
```

## 2. `src/main/index.ts` — the tools, in `extraTools`

Inside `registerDeckControlIpc(ipcMain, { … extraTools: [ … ] })` (around line 4786),
add one spread anywhere in the list — after `...browserStoreTools(),` reads best:

```ts
      /*
       * The rest of the browser — every window, every toolbar control, downloads,
       * history, profiles, saved logins, site data, the Chrome import, sign-in
       * help, the Scraping panel and both stores. Each one calls the function the
       * browser's own control calls; `deck-control/browser-area-tools.ts` has the
       * list. Every one is an index line behind `tools.describe`.
       */
      ...browserAreaTools({
        send: (channel, payload) => send(channel, payload),
        // Read per call: the drive is published after this list is composed.
        drive: () => browserDrive(),
        reach: () => browserReach,
        machineOfSession: (sessionId) => machineOfSession(sessionId),
        // The same two the Store's own `registerCommunityIpc` is given in registerIpc().
        community: {
          userData: () => app.getPath('userData'),
          base: () => storeApiBase(process.env),
        },
      }),
```

All five names already exist at that point in `index.ts`: `send` and `machineOfSession`
are module functions, `browserDrive` and `storeApiBase` are imported, `browserReach` is
the module-level `let` that `registerBrowserReachIpc` fills.

## 3. `src/main/index.ts` — the extension store's other buttons

The existing `...extensionTools({ … })` call (around line 4816) gains one spread, so
the tool can install, remove, reload, rename, add-your-own and open an extension's
window. Without it those actions answer "this build cannot … from here" and the two
old verbs work exactly as before:

```ts
      ...extensionTools({
        installed: (profileId) => installedExtensionsFor(profileId),
        isLoaded: (profileId, id) => isExtensionLoaded(profileId, id),
        currentProfileId: () => currentBrowserProfileId(),
        profileName: (profileId) => browserProfileNameFor(profileId),
        setEnabled: (profileId, id, on) => setExtensionEnabled(profileId, id, on),
        ...extensionManageDeps(),
      }),
```

That is the whole of the wiring. Nothing in `preload/index.ts`, `App.tsx`,
`shared/types.ts` or `package.json` changes.

## What the integrator should know

- **`reachable.test.ts`** lists the new `deck-control/*-tools.ts` files as orphans until
  step 1 lands (they are reached through `browser-area-tools.ts`). It already fails on
  the base commit for `deck-control/actions/*`, which nothing imports yet — that one is
  not this lane's.
- **`actions.test.ts` → "has decided every one"** still fails, for the other three areas
  only. The browser area has no `null` left; `browser-coverage.test.ts` checks that on
  its own, and that every tool it names is built.
- **Catalogue budget.** All twelve new tools carry an `index`, so the advertised count is
  unchanged (19). Their twelve index lines cost 1,326 characters, ~379 estimated tokens,
  measured in `browser-coverage.test.ts`, which also asserts the assembled catalogue
  *with* them stays under both ceilings. `catalogue-cost.test.ts`'s pinned
  `cost.chars < 23_000` was written before them; once every lane's index lines are in,
  that pin (not the ceiling) is the number most likely to need re-measuring. Its
  `shipped()` list could also grow `...browserAreaTools`-equivalent factories the way
  `browser-coverage.test.ts`'s does.
- **The one gate.** Every tool here that touches a page or a login (`browser.windows`,
  `browser.page`, `browser.passwords`, `browser.data`, `browser.import`, and
  `browser.signin` handover) passes `mayDrive` from `browser-tools.ts` — the same gate
  the six original verbs use: the person at this machine (or a session, which these
  tools refuse separately), attended. If lane `mcp-door` gives outside clients a new
  caller kind, `mayDrive` is the single place that decides whether they drive the
  browser, and these tools follow it with no edit. The management tools (downloads,
  history, profiles, scraping, both stores, extensions) are governed by tiers alone, as
  `browser.extensions` always was. None of the new tools is on `SESSION_TOOLS`, and each
  refuses a session caller anyway (`notASession` in `browser-area-kit.ts`).
- **No push to the window for some lists.** Profiles, history, saved logins, the Scraping
  panel's settings and both stores have no main→renderer push today (they re-read when
  opened). A change made by a tool is saved and in force at once, and an already-open
  panel shows it when it next reads its list; the tool results say exactly that rather
  than implying it is on screen. Adding pushes needs `preload/index.ts`, which this lane
  may not touch.

## Existing files this lane edited (no behaviour change for the window)

Handler bodies were **moved** into exported functions, and each `ipcMain.handle` now
calls the function — so the window's button and the tool are one code path:

| File | Newly exported |
|---|---|
| `browser-tab.ts` | `browserTabState`, `stopBrowserTab`, `setBrowserTabInspecting`, `signInOffer`, `fillSavedLogin` |
| `browser-view.ts` | `zoomBrowserView`, `findInBrowserView` (now also answers the match count), `stopFindInBrowserView`, `printBrowserView`, `toggleBrowserViewDevtools`, `setBrowserViewUserAgent`, `clearBrowserViewRecording`, `revealBrowserScreenshot` |
| `browser-session.ts` | `browserSessionInfo`, `browserCookieDomains`, `clearBrowserCookies`, `clearBrowserStorage`, `clearBrowserCache` |
| `browser-binding-ipc.ts` | `bindWindow`, `unbindWindow` |
| `browser-extensions-ipc.ts` | `extensionListFor`, `installExtension`, `removeExtension`, `openExtensionWindow`, `addOwnExtension`, `reloadOwnExtension`, `renameOwnExtension` |
| `browser-passwords.ts` | `loginSummariesFor`, `revealLoginsFile`, `answerPendingOffer` |
| `browser-signin.ts` | `handOverSignIn` |
| `browser-scraping-ipc.ts` | `clearScrapeCapture`, `revealScrapeCapture`, `clearScrapeLedgers` (and `ScrapeOutcome`) |
| `browser-store-ipc.ts` | `browserStoreList`, `browserStoreInstall`, `browserStoreRemove` |
| `store-install-ipc.ts` | `communityView`, `communityInstall`, `communityRemove` |
| `cookie-import.ts` | `cookieImportStatus`, `clearImportedCookies` |

Comment-only edits that keep a written rule true: `browser-fill-gate.ts` and the
`browser-password:fill` handler comment in `browser-tab.ts` (a fill can now be asked for
by a tool, and is `alter` every time); `extension-tools.ts`'s header (install/remove now
exist, as `alter`); `store-tools.ts`'s install sentence (now caller-aware: a session is
still told only the panel can install).
