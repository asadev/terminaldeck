/**
 * `out/native-web/shim.js`: the first script the native window's page runs.
 *
 * The engine serves the renderer's own `index.html` with
 * `<script src="/__td/shim.js">` in `<head>`, ahead of the renderer's scripts,
 * so by the time React starts `window.deck` is already there — built by the
 * real `src/preload/index.ts`, unchanged, over the HTTP bridge instead of
 * Electron's IPC. Built by `npm run build:native-web` (`vite.native-web.config.ts`).
 *
 * What runs, in order: the preload's `import … from 'electron'` evaluates
 * `electron.ts` through the build's alias (the bridge comes up and its one event
 * stream opens); the preload exposes `window.deck`; then this body marks the
 * page as the native shell, puts `window.tdNative` in place, and wires what the
 * page needs from the native window that Electron gives it for free — Hoot's
 * window readers, banners, menus, links and dropped files (`page-features.ts`).
 * All of it
 * finishes before the renderer's first line, which is the only order that is
 * load-bearing.
 */

import '../preload/index'
import { bridgeHooks, drops, ipcRenderer } from './electron'
import { installNativeShell, type ShellHost } from './native-shell'
import { installPageFeatures, type PageHost } from './page-features'

installNativeShell(globalThis as unknown as ShellHost)
installPageFeatures(globalThis as unknown as PageHost, ipcRenderer, bridgeHooks, drops)
