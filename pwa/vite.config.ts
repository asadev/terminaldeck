import { createHash } from 'node:crypto'
import { readFileSync, readdirSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { defineConfig, type Plugin } from 'vite'

const here = (rel: string): string => fileURLToPath(new URL(rel, import.meta.url))

/**
 * The two webfaces, which live outside this directory and are read from it.
 *
 * `src/styles.css` declares both `@font-face` rules with a `url()` that climbs
 * out of `pwa/` into the desktop's asset folder — deliberately, so the product
 * ships one copy of each face rather than two that can drift. A *build* handles
 * that without being told: Rollup follows the `url()`, hashes the file and
 * emits it into `dist/assets/`, which is exactly what it does today.
 *
 * A **dev server** does not, and that is what this constant is for. Vite serves
 * a file from outside its root through `/@fs/…`, and it refuses that path unless
 * the directory is on `server.fs.allow` — a real protection, because a dev
 * server bound to `host: true` is reachable from the network. With `pwa/` as the
 * root and the fonts a level up, the default allow-list did not cover them and
 * both requests came back **403**, so `document.fonts` reported
 * `Hanken Grotesk error` and `JetBrains Mono error` and the client fell through
 * to `-apple-system` and the system mono.
 *
 * That mattered far more than a wrong-looking dev server. `vite dev` is the only
 * way this client can be *looked at* — vitest runs here with no DOM, and the
 * repo's standing rule is that a visible change has to be verified on a screen —
 * so every screenshot ever taken of this app, by a person or by
 * `.harness/web-drive.mjs`, was in a typeface it does not ship. A harness that
 * renders the wrong font is not a weaker check; it is a check that will one day
 * approve a layout the product cannot draw.
 *
 * Named rather than inlined so `tests/fonts.test.ts` can resolve every
 * `@font-face` url in the stylesheet and prove each one lands inside a directory
 * this list allows. That is the pin: the failure it guards against is somebody
 * moving the fonts, or adding a third face from somewhere new, and finding out
 * from a screenshot months later.
 */
export const FONT_DIR = here('../src/renderer/assets/fonts')

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

/**
 * `Buffer`, bound per module rather than dropped on `globalThis`.
 *
 * The shared crypto this client imports — `src/shared/sealed.ts` and
 * `src/shared/relay-wire.ts` — writes `Buffer` as the global it is under Node.
 * A browser has none, so one has to arrive from somewhere, and there are two
 * ways to arrange that.
 *
 * The tempting one is a module that assigns `globalThis.Buffer` and is imported
 * first from the entry point. It works, and it works because of ESM evaluation
 * order — which means it keeps working only for as long as nobody adds an import
 * above it, and `sealed.ts` builds two `Buffer.from` constants at module scope,
 * so getting that wrong is a blank screen at load rather than a warning.
 *
 * So the import is injected into each module that mentions the name. Rollup
 * binds it like any other import, order stops mattering, and nothing is added to
 * the global scope of a page that did not ask for it. Modules that only mention
 * `Buffer` in a comment get an unused import, which the bundler removes.
 */
/**
 * The `Buffer` implementation, resolved from *this* directory and checked.
 *
 * A bare `import … from 'buffer'` looked obviously correct and was wrong. Module
 * resolution starts at the importing file, and the importing files are
 * `src/shared/sealed.ts` and `src/shared/relay-wire.ts` — which sit at the
 * repository root, where `node_modules/buffer` is **5.7.1**, dragged in years
 * ago by something else. That version has no `writeBigUInt64LE`, which is the
 * one method the Noise nonce counter needs, and the symptom was a browser
 * saying "that address cannot be opened from this page" about a perfectly good
 * relay URL. `pwa/node_modules/buffer` is 6.0.3 and has it.
 *
 * So the path is resolved from here, and the module is then *asked* whether it
 * can do the two things the crypto depends on. A build that would ship a Buffer
 * missing either of them fails now, with a sentence, rather than at a handshake
 * in somebody's browser. This is the same family of bug as the ChaCha that was
 * not in Electron: the right code, and the wrong implementation underneath it.
 */
/*
 * `'buffer/index.js'`, not `'buffer'`, and that detail is the bug twice over.
 *
 * `require.resolve('buffer')` answers `"buffer"` — Node reports the *builtin* by
 * that name and never looks in `node_modules` at all. An alias built from it is
 * therefore a no-op that maps `buffer` to `buffer`, and a check built from it
 * imports Node's own Buffer and passes while the browser gets whatever the
 * bundler found. Naming a file inside the package is what makes the resolver
 * walk `node_modules` from here, which is the only place the right version is.
 */
const bufferModule = createRequire(import.meta.url).resolve('buffer/index.js')

/**
 * The crypto packages, resolved from *here* — the same bug as `buffer`, found
 * the same way, one deploy later.
 *
 * `src/shared/sealed.ts` imports `@noble/ciphers/chacha.js`, and it sits at the
 * repository root, so Node's resolver walks up from `src/shared/` and finds the
 * **root** `node_modules`. On this Mac that directory is full — the desktop app
 * lives there — so the build has always worked and always resolved a copy of the
 * cipher that `pwa/package.json` does not name and `pwa/package-lock.json` does
 * not pin.
 *
 * The first deploy of this client is what said so out loud. Vercel builds with
 * the Root Directory set to `pwa`, runs `npm ci` there and nowhere else, and
 * Rollup stopped with "failed to resolve import @noble/ciphers/chacha.js from
 * src/shared/sealed.ts". Nothing was wrong with the code; the build had been
 * leaning on a directory that only exists on a machine where somebody has also
 * installed Electron.
 *
 * So each package is pinned to the copy in `pwa/`, which is the one the lockfile
 * beside this file describes. The versions happen to match today — that is the
 * point: two resolutions that agree by luck are the ones that part company
 * silently, and this bundle is the sealed channel.
 *
 * Resolved through a **subpath that the package exports**, not through
 * `package.json`. `@noble/*` ship an `exports` map that lists their modules and
 * nothing else, so asking for `@noble/ciphers/package.json` throws
 * ERR_PACKAGE_PATH_NOT_EXPORTED — the directory has to be reached by way of a
 * file the package admits to having.
 */
const nobleDir = (subpath: string): string =>
  dirname(createRequire(import.meta.url).resolve(subpath))

function checkBuffer(): Plugin {
  return {
    name: 'terminaldeck-buffer-check',
    async buildStart() {
      // `pathToFileURL`, because `bufferModule` is an ABSOLUTE PATH and ESM only
      // accepts file:, data: and node: URLs. On macOS and Linux a leading `/`
      // happens to parse, so `import('/Users/…/buffer/index.js')` works and this
      // read like ordinary code. On Windows the same string is `D:\…`, whose
      // first two characters ESM parses as the scheme — the Windows release
      // build failed with "Received protocol 'd:'" before the client compiled a
      // single module. A check that cannot run is worse than no check: this one
      // exists because a broken `buffer` breaks every Noise nonce silently.
      const { Buffer: Shim } = (await import(pathToFileURL(bufferModule).href)) as {
        Buffer: typeof Buffer
      }
      const nonce = Shim.alloc(12)
      if (typeof nonce.writeBigUInt64LE !== 'function') {
        this.error(
          `the Buffer at ${bufferModule} has no writeBigUInt64LE, so the sealed channel's nonce ` +
            'counter cannot be written — install buffer@^6 in pwa/',
        )
      }
      if (Shim.from('/w', 'base64').length !== 1) {
        this.error(`the Buffer at ${bufferModule} does not decode base64, which host keys arrive as`)
      }
    },
  }
}

function bufferImport(): Plugin {
  const source = /\.tsx?$/
  return {
    name: 'terminaldeck-buffer-import',
    enforce: 'pre',
    transform(code, id) {
      if (id.includes('/node_modules/') || !source.test(id.split('?')[0])) return null
      if (!/\bBuffer\b/.test(code)) return null
      if (/^import .*from ['"]buffer['"]/m.test(code)) return null
      return { code: `import { Buffer } from 'buffer'\n${code}`, map: null }
    },
  }
}

/**
 * The version this page was built from, stamped in at build time.
 *
 * Read from the **repository's** package.json, one directory up, and not from
 * `pwa/package.json`. That file carries a `0.1.0` nobody has ever bumped, and
 * nothing keeps it in step with anything — `scripts/version.mjs` moves the root
 * package.json, the changelog and the git tag together, and that number is what
 * the desktop release, the changelog entry and the tag all mean by "the
 * version". This client is built from the same working tree in the same commit,
 * so it is the honest answer to *which build of Terminal Deck is this page*.
 *
 * It is deliberately **not** a claim about the machine on the other end of the
 * socket. Nothing on this protocol carries the desktop's app version — only
 * `PROTOCOL_VERSION` and a capability list — so the About row says "this
 * browser" and stops there rather than implying the pair agree.
 *
 * `define` rather than an import so the string is inlined and there is no
 * `package.json` in the bundle; the value has to be JSON-encoded because
 * `define` substitutes raw source text.
 */
const VERSION: string = JSON.parse(readFileSync(here('../package.json'), 'utf8')).version

export default defineConfig({
  root: here('.'),
  // Root-absolute, not './'. The desktop serves this at the origin root, and a
  // service worker's scope is the directory its script came from — a relative
  // base would put the worker somewhere it cannot control the navigation.
  base: '/',
  publicDir: false,
  define: { __APP_VERSION__: JSON.stringify(VERSION) },
  plugins: [checkBuffer(), bufferImport(), shellAssets()],
  resolve: {
    alias: {
      // Only needed if the protocol module reaches for the app's shared types
      // through the alias the desktop tsconfigs define. Harmless when it does not.
      '@shared': here('../src/shared'),
      /*
       * The sealed channel runs in the browser, so its primitives have to.
       *
       * `src/shared/sealed.ts` is the product's only implementation of the Noise
       * IK handshake and this client imports it rather than writing a second
       * one — the lesson of the ChaCha bug is that a second implementation
       * agrees with itself and drifts from everything else. What a browser
       * cannot provide is `node:crypto`, so `runtime/node-crypto.ts` provides
       * exactly the five primitives that file asks for, and
       * `pwa/tests/node-crypto.test.ts` proves under Node that they produce the
       * same bytes as the ones they stand in for.
       *
       * The mapping is exact rather than a prefix: aliasing `node:*` wholesale
       * would let a genuine mistake — an `import { readFile } from 'node:fs'`
       * that never belonged in a browser — resolve to something instead of
       * failing the build, which is the guard `"types": []` exists to be.
       */
      'node:crypto': here('src/runtime/node-crypto.ts'),
      // Pinned to the copy in `pwa/`, for the reason above `checkBuffer`.
      buffer: bufferModule,
      // Likewise, for the reason above `nobleDir`. A string `find` is a prefix
      // here, so `@noble/ciphers/chacha.js` lands on `<dir>/chacha.js` — which
      // is where these packages keep their modules; the layout is flat and the
      // exports map is an identity.
      '@noble/ciphers': nobleDir('@noble/ciphers/chacha.js'),
      '@noble/curves': nobleDir('@noble/curves/ed25519.js'),
      '@noble/hashes': nobleDir('@noble/hashes/sha2.js'),
    },
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
    fs: {
      /*
       * The root, and the one directory outside it this client actually reads.
       *
       * Listed rather than widened to the repository, and that is the point: the
       * dev server is on every interface, so `allow: ['..']` would put the whole
       * checkout — `credentials`, `.env`, the host identity under `.harness/` —
       * one crafted `/@fs/` request away from anybody on the network. Two
       * entries is the smallest list that serves the two faces in `FONT_DIR`,
       * and it fails loudly rather than silently if a third asset ever arrives
       * from somewhere new.
       */
      allow: [here('.'), FONT_DIR],
    },
  },
})
