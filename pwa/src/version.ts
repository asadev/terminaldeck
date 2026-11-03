/**
 * Which build of this client somebody is looking at.
 *
 * ## Why a web app needs to be able to answer this at all
 *
 * The other two clients get it for free: a phone shows its version in Settings
 * (`Brand.version`, read out of the bundle it is running inside), and the
 * desktop is a file somebody downloaded and can see. A browser has neither. It
 * updates itself silently, it is *installed* on a home screen for people who
 * added it there, and — the part that makes this specific rather than tidy — it
 * keeps its shell in a service worker cache. `sw.js` is stamped with a content
 * hash at build time precisely because a PWA's classic failure is shipping an
 * update nobody receives; when that goes wrong, the first question anybody asks
 * is *which build are you on*, and until now this client had no way to answer.
 *
 * So: one number, on the Settings screen, where the phone puts its.
 *
 * ## What it is, and the two things it is not
 *
 * It is the version of the **repository this page was built from**, injected by
 * `pwa/vite.config.ts` from the root `package.json` — the same number
 * `scripts/version.mjs` moves the changelog and the git tag with.
 *
 * It is **not the desktop's version**. Nothing on this protocol carries one, so
 * a browser paired with a machine running an older build has no way to know and
 * this screen does not pretend otherwise. If a `welcome` frame ever grows an app
 * version, that is a second line here and a deliberate one.
 *
 * It is **not a promise that the page in front of you is the newest deploy**.
 * The service worker serves the document network-first, so a reload with a
 * network picks up a new deploy; offline, it is honestly the last one that
 * arrived. What this number does is make the difference *visible*, which is the
 * whole of what it was missing.
 *
 * ## The `typeof` guard
 *
 * `__APP_VERSION__` is a token Vite substitutes, so under vitest — plain Node,
 * no bundler — the identifier does not exist and reading it bare is a
 * `ReferenceError` rather than `undefined`. The guard is what lets this module
 * be imported by a test at all. `'unknown'` is deliberately not a plausible
 * version string: if it ever reaches a screen, it says "nobody stamped this"
 * instead of quietly showing a wrong number.
 */
export const VERSION: string = typeof __APP_VERSION__ === 'string' ? __APP_VERSION__ : 'unknown'
