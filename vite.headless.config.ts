import { resolve } from 'node:path'
import { defineConfig } from 'vite'

/**
 * The headless build: two Node programs, no Electron, no Chromium.
 *
 * Separate from `electron.vite.config.ts` rather than another target inside it,
 * because they disagree about the thing that matters most — that config's whole
 * job is to produce a CommonJS bundle for Electron's main process, and this one
 * produces plain ESM for Node. Sharing a config would mean one set of externals
 * and one output format for two runtimes that want different ones.
 *
 * ## Nothing from node_modules is bundled, and that is a reversal worth stating
 *
 * The Electron config bundles `@noble/ciphers` and gives a good reason: that
 * bundle is CommonJS, the package is ESM-only, and externalising it would make
 * every relayed connection depend on `require(esm)` resolving inside a packaged
 * app — which has broken this feature once already.
 *
 * None of that reasoning survives the move to Node. This output *is* ESM, it is
 * installed by npm beside a real `node_modules`, and an ESM-only dependency is
 * simply an import. So the packages stay external, get listed in the generated
 * package's dependencies, and a security fix in one of them is `npm update` on
 * the server rather than a release of this. `node-pty` is native and could not
 * have been bundled in any case.
 *
 * ## Why `ssr` and not a library build
 *
 * `build.ssr` is what tells Vite the output runs in Node: builtins and
 * dependencies stay external, `import.meta.url` survives, and nothing is
 * polyfilled for a browser that is not there. Both entry points read
 * `import.meta.url` to find their siblings on disk, so a build that rewrote it
 * would break the CLI's ability to start the host.
 */

/**
 * `@xterm/headless` 6.0.0, addressed by the file that actually exists.
 *
 * Its `package.json` says `"module": "lib/xterm.mjs"` and ships no such file —
 * the ESM build is at `lib-headless/xterm-headless.mjs` — and there is no
 * `exports` field, so Node falls back to `main`, which is the CommonJS build.
 * The first run of the built host died on its first line:
 *
 *     SyntaxError: Named export 'Terminal' not found. The requested module
 *     '@xterm/headless' is a CommonJS module…
 *
 * Node's CJS-to-ESM interop only surfaces the named exports its lexer can find,
 * and it cannot find that one. Naming the ESM file directly fixes it, and that
 * is a legal specifier precisely because the package has no `exports` map to
 * forbid it.
 *
 * The fix lives here rather than in `session-activity.ts`, which is core and
 * shared with the desktop: the Electron build emits CommonJS, so over there the
 * same import is a `require` and works. A build problem belongs to the build
 * that has it.
 *
 * It is an alias rather than a `rollupOptions.external` entry because Rollup
 * asks about the specifier *as written*, before any alias runs — declaring it
 * external emitted the broken bare `@xterm/headless` again and the built host
 * died exactly as before, with the build reporting success. Vite's SSR pass
 * externalises the aliased path afterwards, which is the wanted outcome: still a
 * dependency, addressed by a specifier Node can resolve.
 */
const XTERM_HEADLESS_ESM = '@xterm/headless/lib-headless/xterm-headless.mjs'

export default defineConfig({
  resolve: {
    alias: {
      '@shared': resolve(__dirname, 'src/shared'),
      '@xterm/headless': XTERM_HEADLESS_ESM,
    },
  },
  build: {
    ssr: true,
    target: 'node22',
    outDir: 'out/headless',
    emptyOutDir: true,
    // Unminified on purpose. This ships to servers, it is read by whoever is
    // debugging a host that will not start, and the bytes saved are irrelevant
    // beside a stack trace that names a real function.
    minify: false,
    sourcemap: true,
    rollupOptions: {
      input: {
        host: resolve(__dirname, 'src/headless/daemon.ts'),
        cli: resolve(__dirname, 'src/headless/main.ts'),
      },
      output: {
        format: 'es',
        entryFileNames: '[name].mjs',
        // Prefixed, because a shared chunk is named after whichever module
        // Rollup picked and `version.mjs` sitting beside `cli.mjs` reads like an
        // entry point somebody could run.
        chunkFileNames: 'chunk-[name].mjs',
      },
    },
  },
})
