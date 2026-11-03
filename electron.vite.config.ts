import { resolve } from 'node:path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  main: {
    // `@noble/ciphers` is bundled rather than left as a runtime `require`.
    //
    // It is the ChaCha20-Poly1305 behind the sealed channel, it is ESM-only,
    // and this bundle is CommonJS — so externalising it would make every
    // relayed connection depend on `require(esm)` resolving a package out of
    // node_modules inside a packaged app. The feature has already been broken
    // once by a cipher that was not there at runtime; a dependency that cannot
    // be missing is worth more than the few kilobytes it adds. It is
    // dependency-free pure JavaScript, so there is nothing else to drag in.
    plugins: [externalizeDepsPlugin({ exclude: ['@noble/ciphers'] })],
    build: {
      rollupOptions: {
        input: { index: resolve(__dirname, 'src/main/index.ts') },
      },
    },
    resolve: {
      alias: { '@shared': resolve(__dirname, 'src/shared') },
    },
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    build: {
      rollupOptions: {
        input: { index: resolve(__dirname, 'src/preload/index.ts') },
      },
    },
    resolve: {
      alias: { '@shared': resolve(__dirname, 'src/shared') },
    },
  },
  renderer: {
    root: resolve(__dirname, 'src/renderer'),
    plugins: [react()],
    build: {
      rollupOptions: {
        input: { index: resolve(__dirname, 'src/renderer/index.html') },
      },
    },
    resolve: {
      alias: {
        '@shared': resolve(__dirname, 'src/shared'),
        '@renderer': resolve(__dirname, 'src/renderer'),
      },
    },
  },
})
