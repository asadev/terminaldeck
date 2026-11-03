/**
 * Service worker: the shell, and nothing else, ever.
 *
 * ## What may be cached
 *
 * An allowlist, not a denylist. Only the files that make up the application
 * shell — the document, Vite's hashed bundle, the icons and the manifest — are
 * ever written to a cache. Everything else goes straight to the network with no
 * copy kept.
 *
 * That is a deliberate line rather than a precaution. This client displays
 * somebody's terminal: their source tree, their prompts, their environment. All
 * of it arrives over a WebSocket and therefore never passes through `fetch`
 * here at all — but a denylist would mean the next HTTP endpoint anyone adds is
 * cached by default, and a phone's cache is a plain file that survives logging
 * out, being handed to someone else, or being backed up to a computer.
 *
 * ## Why there is no skipWaiting
 *
 * A new worker taking over immediately swaps the hashed assets under a page
 * that is already running, which on this app means doing it to a live terminal
 * session. The update lands on the next launch instead, which for a
 * home-screen app is minutes away and costs nobody anything.
 *
 * The cache name carries a build-time hash of the shell — see `vite.config.ts`.
 * Without it a deploy leaves every installed phone serving the previous build
 * out of its own cache indefinitely.
 */

const VERSION = '__SHELL_VERSION__'
const CACHE = `terminaldeck-shell-${VERSION}`

/**
 * Precached at install time. The hashed bundle is not here — its filenames are
 * not knowable when this file is written — so it is cached on first use below.
 */
const SHELL = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png']

function isShellPath(pathname) {
  return (
    pathname === '/' ||
    pathname === '/index.html' ||
    pathname === '/manifest.webmanifest' ||
    pathname.startsWith('/assets/') ||
    pathname.startsWith('/icons/')
  )
}

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) =>
      // Individually, and forgiving: one missing icon must not fail the whole
      // install and leave the app permanently uninstallable.
      Promise.all(SHELL.map((path) => cache.add(path).catch(() => undefined))),
    ),
  )
})

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((names) => Promise.all(names.filter((name) => name !== CACHE).map((name) => caches.delete(name))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const request = event.request
  if (request.method !== 'GET') return

  const url = new URL(request.url)
  if (url.origin !== self.location.origin) return
  if (!isShellPath(url.pathname)) return

  // Navigations are network-first: the newest shell wins whenever the Mac is
  // reachable, and the cached one is there so that opening the app out of
  // range shows its own "not connected" screen rather than the browser's
  // dinosaur. Nothing on that screen claims a session is live.
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          // Only a real shell is kept. Without this check the offline copy
          // becomes whatever answered last — the desktop's own "the phone app
          // has not been built yet" page, a 502 from something in between, or a
          // captive portal's redirect, any of which then greets the user every
          // time they open the app out of range. `basic` also keeps `cache.put`
          // from rejecting on an opaque response, which it does silently here.
          if (response.ok && response.type === 'basic') {
            const copy = response.clone()
            caches.open(CACHE).then((cache) => cache.put('/', copy))
          }
          return response
        })
        .catch(() => caches.match('/').then((cached) => cached ?? Response.error())),
    )
    return
  }

  // Hashed assets and icons are immutable, so a hit is always correct.
  event.respondWith(
    caches.match(request).then((cached) => {
      if (cached) return cached
      return fetch(request).then((response) => {
        if (response.ok && response.type === 'basic') {
          const copy = response.clone()
          caches.open(CACHE).then((cache) => cache.put(request, copy))
        }
        return response
      })
    }),
  )
})
