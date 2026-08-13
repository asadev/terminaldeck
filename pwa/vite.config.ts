import { createHash } from 'node:crypto'
import { readFileSync, readdirSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

const here = (rel: string): string => fileURLToPath(new URL(rel, import.meta.url))

/**
 * The service worker, the manifest and the icons ship verbatim at fixed URLs.
 *
 * They cannot go through Vite's asset pipeline, which fingerprints filenames:
 * a service worker registered as `/sw.js` must stay `/sw.js` or every install
 * re-registers a different script, and `/sw-a3f19c.js` would also narrow its
 * scope to the directory it was served from. Vite's own answer to this is
 * `public/`, but the brief fixes these files at `pwa/sw.js` and
 * `pwa/manifest.webmanifest`, so they are emitted from where they live.
 *
 * The worker's cache name is stamped with a content hash of the shell sources
 * at build time. Without that, a deploy leaves every installed phone serving
 * the previous shell out of its cache until the cache name happens to change,
 * which is the classic way a PWA ships an update nobody receives.
 */
/** Stable URLs, injected after Vite has finished rewriting the document's own. */
const SHELL_LINKS = [
  '<link rel="manifest" href="/manifest.webmanifest">',
  '<link rel="icon" href="/icons/icon-192.png" sizes="192x192">',
  '<link rel="apple-touch-icon" href="/icons/icon-180.png">',
].join('\n    ')

function shellAssets(): Plugin {
  return {
    name: 'terminaldeck-shell-assets',
    transformIndexHtml: {
      // `post`, so these are added after the asset pipeline has run and are
      // never fingerprinted. In the tag list above they would be.
      order: 'post',
      handler: (html) => html.replace('</head>', `  ${SHELL_LINKS}\n  </head>`),
    },
    generateBundle(_options, bundle) {
      const manifest = readFileSync(here('manifest.webmanifest'), 'utf8')
      const icons = readdirSync(here('icons')).filter((name) => name.endsWith('.png'))

      // The emitted filenames are in the hash, and they are the part that
      // actually moves: they carry Vite's content hash, so any change to the
      // client changes this version. Hashing only the sources of the document
      // and the manifest left the cache named the same across every JS-only
      // build — which is correct for what is served, because the document is
      // network-first and the bundle is hashed, but it means `activate` never
      // deletes anything and the phone keeps every build it has ever seen.
      const emitted = Object.keys(bundle).sort().join(',')

      const version = createHash('sha256')
        .update(readFileSync(here('index.html')))
        .update(manifest)
        .update(String(icons.length))
        .update(emitted)
        .digest('hex')
        .slice(0, 12)

      const worker = readFileSync(here('sw.js'), 'utf8').replace('__SHELL_VERSION__', version)

      this.emitFile({ type: 'asset', fileName: 'sw.js', source: worker })
      this.emitFile({ type: 'asset', fileName: 'manifest.webmanifest', source: manifest })
      for (const name of icons) {
        this.emitFile({ type: 'asset', fileName: `icons/${name}`, source: readFileSync(here(`icons/${name}`)) })
      }
    },
  }
}

export default defineConfig({
  root: here('.'),
  // Root-absolute, not './'. The desktop serves this at the origin root, and a
  // service worker's scope is the directory its script came from — a relative
  // base would put the worker somewhere it cannot control the navigation.
  base: '/',
  publicDir: false,
  plugins: [shellAssets()],
  resolve: {
    // Only needed if the protocol module reaches for the app's shared types
    // through the alias the desktop tsconfigs define. Harmless when it does not.
    alias: { '@shared': here('../src/shared') },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    // Safari 16.4 is the floor: it is the first iOS release with web push and
    // the first that can install this to the home screen and keep a worker.
    target: ['es2022', 'safari16'],
  },
  server: {
    // Bound to every interface on purpose: `vite dev` here is only useful when
    // it is reachable from the phone that is meant to be testing it.
    host: true,
    port: 5174,
  },
})
