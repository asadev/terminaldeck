import { resolve } from 'node:path'
import { defineConfig } from 'vite'

/**
 * The native window's page bridge: `out/native-web/shim.js`, one IIFE.
 *
 * The native macOS window (`macos/`) shows the renderer's own screens in a
 * WKWebView and talks to Terminal Deck's main process — running windowless, as
 * an engine — over a private HTTP bridge. What the page needs from that bridge
 * is exactly what `src/preload/index.ts` gives the Electron window, so this
 * builds **that file**, unchanged, with one difference: the bare specifier
 * `electron` resolves to `src/native-web/electron.ts`, whose `ipcRenderer`,
 * `contextBridge` and `webUtils` speak HTTP instead of IPC. `window.deck` comes
 * out the same object, method for method, and a method added to the preload
 * reaches both windows with no second copy to keep in step.
 *
 * Separate from `electron.vite.config.ts` because the output disagrees with all
 * three of its targets: not CommonJS for Node, not a sandboxed preload with a
 * real `electron` module, not an HTML app — a classic script for `<head>`.
 *
 * The preload imports nothing at runtime but `electron` (its `../shared/types`
 * import is type-only), so no Node built-in needs a stand-in; if it ever starts
 * to, the build will fail on it here rather than at runtime in the window.
 */
export default defineConfig({
  publicDir: false,
  resolve: {
    alias: [
      // Exactly `electron` — a regex so that a package merely starting with the
      // word (`electron-updater`) is never caught by it.
      { find: /^electron$/, replacement: resolve(__dirname, 'src/native-web/electron.ts') },
      { find: '@shared', replacement: resolve(__dirname, 'src/shared') },
    ],
  },
  build: {
    outDir: 'out/native-web',
    emptyOutDir: true,
    // The WKWebView of the oldest macOS the native window supports.
    target: 'safari16',
    // Unminified: it is small, it is read by whoever is debugging a page that
    // will not talk to its engine, and a stack trace should name a real function.
    minify: false,
    sourcemap: true,
    lib: {
      entry: resolve(__dirname, 'src/native-web/index.ts'),
      formats: ['iife'],
      name: 'TerminalDeckNativeShim',
      fileName: () => 'shim.js',
    },
  },
})
