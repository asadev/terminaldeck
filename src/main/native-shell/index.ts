import { existsSync, writeSync } from 'node:fs'
import { join } from 'node:path'
import { app, dialog, ipcMain, Notification, session } from 'electron'
import { failedLine, readyLine, startBridgeServer, type BridgeServer } from './bridge-server'
import { frontDialogs } from './dialogs'
import { scrubProcessEnv } from './inherited-env'
import { isNativeShell, NATIVE_REFUSED_CHANNELS } from './mode'
import { hydrateOnce } from './hydration'
import { createNativeNotifier, NOTIFY_CHANNEL, NOTIFY_CLOSE_CHANNEL } from './notifications'
import { createHandlerRegistry, type TappableIpcMain } from './registry'
import { createNativeSender } from './sender'

/**
 * The engine side of the native shell: this app's main process, running with
 * no window, serving its own React screens to a native window over a private
 * loopback bridge.
 *
 * ## The launch contract
 *
 *     Electron <repo> --native-shell --user-data-dir=<dir>
 *
 * prints exactly one of these on stdout, once:
 *
 *     TD_NATIVE_READY http://127.0.0.1:<port>/?t=<token>
 *     TD_NATIVE_FAILED <reason>          (and exits non-zero)
 *
 * and leaves — through the app's ordinary quit, so every pty it started is
 * killed the way a normal quit kills them — when its stdin closes (the parent
 * is gone) or on SIGTERM / SIGINT / SIGHUP.
 *
 * ## How it reaches the app
 *
 *  - **Calls in.** `installNativeShell()` taps `ipcMain.handle` before
 *    `registerIpc()` runs (see `registry.ts`), so `POST /__td/invoke` calls the
 *    very handler a window's `invoke` would. `POST /__td/send` emits on
 *    `ipcMain`, which is how Electron delivers a window's `send`.
 *  - **Pushes out.** `send` in `index.ts` — the one place the main window is
 *    pushed to — hands every push to {@link nativeShellBroadcast} in native
 *    mode. The modules that keep `event.sender` and push to it later (usage,
 *    cost, MCP state, devices, …) were given the stand-in sender from
 *    `sender.ts`, whose `send` goes to the same event stream.
 *  - **Dialogs** are free-standing and bring this process forward (`dialogs.ts`).
 *  - **The environment** it was started with is cleaned of another app's session
 *    first (`inherited-env.ts`).
 *
 * ## What native mode switches off
 *
 * Every gate is a one-line `isNativeShell()` check at the place the side effect
 * happens, so each can be found by searching for the function's name. The list
 * is in the lane report and in `mode.ts`.
 */

export { isNativeShell } from './mode'

const registry = createHandlerRegistry()
let bridge: BridgeServer | null = null
let installed = false
let leaving = false
let startupDeadline: NodeJS.Timeout | null = null

const sender = createNativeSender({
  deliver: (channel, args) => bridge?.emit(channel, args) ?? false,
  url: () => (bridge === null ? '' : `${bridge.origin}/`),
  session: () => session.defaultSession,
})

/** The event every bridge call carries: the stand-in for the main window, and no frame. */
function invokeEvent(): object {
  return { sender, senderFrame: null, processId: -1, frameId: -1, type: 'frame' }
}

function sendEvent(): object {
  return {
    ...invokeEvent(),
    ports: [],
    returnValue: undefined,
    preventDefault: () => undefined,
    reply: (channel: string, ...args: unknown[]) => sender.send(channel, ...args),
  }
}

/** True for the bridge's sender — which `isApprover` treats as the app's own window — and only in native mode. */
export function isNativeShellSender(contents: unknown): boolean {
  return installed && contents === sender
}

/** Push to the page, as `webContents.send` does for a window. True when a page was listening. */
export function nativeShellBroadcast(channel: string, args: readonly unknown[]): boolean {
  return bridge?.emit(channel, args) ?? false
}

/** Is the native window there to answer a question? The engine's answer to "is the window attended". */
export function nativeShellAttended(): boolean {
  return installed && !leaving && (bridge?.clientCount() ?? 0) > 0
}

/** Say why, on the one line the parent reads, and go. */
export function nativeShellFailed(reason: string): void {
  try {
    writeSync(1, `${failedLine(reason)}\n`)
  } catch {
    /* stdout is gone too; the exit code still says it */
  }
  app.exit(1)
}

/**
 * The ordinary quit, so `before-quit` in `index.ts` kills every pty and stops
 * every server the way it does when a person quits. A hard exit stands behind
 * it in case something in that teardown hangs: the parent is gone, and an
 * engine nobody can reach must not outlive it.
 */
function leave(reason: string): void {
  if (leaving) return
  leaving = true
  console.error(`[native-shell] leaving: ${reason}`)
  setTimeout(() => app.exit(0), 10_000).unref()
  void bridge?.close()
  if (app.isReady()) app.quit()
  else app.exit(0)
}

/**
 * Called once from `index.ts` at module scope, before anything registers a
 * handler. Does nothing unless `--native-shell` was passed.
 */
export function installNativeShell(): void {
  if (!isNativeShell() || installed) return
  installed = true
  registry.tap(ipcMain as unknown as TappableIpcMain)

  // Before anything reads `process.env`: another app's session identity must not
  // become every session's here. See `inherited-env.ts` for what it broke.
  const removed = scrubProcessEnv({ ownUserData: app.getPath('userData') })
  if (removed.length > 0) console.error(`[native-shell] not inherited: ${removed.join(', ')}`)

  // Free-standing dialogs that come to the front. See `dialogs.ts`.
  frontDialogs(dialog, () => app.focus({ steal: true }))

  /*
   * stdout is the protocol: one line, read by the parent. The app logs freely
   * with `console.log`, so in this mode that goes to stderr with everything
   * else Chromium prints, and the ready line cannot be lost among it.
   */
  console.log = console.error
  console.info = console.error
  console.debug = console.error

  // No Dock icon: the native shell is the app the person sees.
  try {
    app.dock?.hide()
  } catch {
    /* not on macOS, or too early; the window-less engine still works */
  }

  // The parent holds our stdin. When it closes, the parent has gone.
  const stdin = process.stdin
  stdin.on('data', () => undefined)
  stdin.on('end', () => leave('stdin closed'))
  stdin.on('close', () => leave('stdin closed'))
  stdin.on('error', () => leave('stdin failed'))
  stdin.resume()
  for (const signal of ['SIGTERM', 'SIGINT', 'SIGHUP'] as const) process.on(signal, () => leave(signal))

  // A launch that never gets as far as serving says so rather than hanging the parent.
  startupDeadline = setTimeout(() => nativeShellFailed('the engine did not start serving within 90 seconds'), 90_000)
  startupDeadline.unref()
}

export interface StartNativeShellOptions {
  /** `out/` — where `renderer/` and `native-web/` were built. */
  outDir: string
  /**
   * The first page opened its event stream: restore the last run's sessions, as
   * the window's first `did-finish-load` does. Only the first — see `hydration.ts`.
   */
  onFirstClient(): void
  /** Wait for every pty the quit killed to have reported its exit. */
  drain(): Promise<unknown>
}

/** Serve the bridge and print the ready line. Called from `whenReady`, after `registerIpc()`. */
export async function startNativeShell(options: StartNativeShellOptions): Promise<void> {
  if (!installed) return
  if (!existsSync(join(options.outDir, 'renderer', 'index.html'))) {
    nativeShellFailed('the renderer has not been built: out/renderer/index.html is missing')
    return
  }
  try {
    bridge = await startBridgeServer({
      rendererDir: join(options.outDir, 'renderer'),
      shimFile: join(options.outDir, 'native-web', 'shim.js'),
      // One port per data folder, so the web view's saved state (kept per origin) survives a relaunch.
      portFile: join(app.getPath('userData'), 'native-shell-port'),
      invoke: (channel, args) => {
        const refused = NATIVE_REFUSED_CHANNELS[channel]
        if (refused !== undefined) return Promise.reject(new Error(refused))
        return registry.invoke(channel, invokeEvent(), args)
      },
      send: (channel, args) => {
        registry.send(channel, sendEvent(), args)
      },
      onClient: hydrateOnce(options.onFirstClient),
      log: (message) => console.error(`[native-shell] ${message}`),
    })
  } catch (error) {
    nativeShellFailed(`the bridge could not start: ${error instanceof Error ? error.message : String(error)}`)
    return
  }
  registerNativeNotifications()
  if (startupDeadline !== null) clearTimeout(startupDeadline)
  writeSync(1, `${readyLine(bridge.url)}\n`)
  /*
   * Leave only once every killed pty has reported its exit.
   *
   * `before-quit` kills the ptys and returns; each one's exit arrives a moment
   * later through node-pty's thread-safe callback. If Node's environment is
   * already being torn down when it arrives, the callback cannot run, node-pty
   * throws from native code, and the process aborts — measured here as
   * `libc++abi: terminating due to uncaught exception of type Napi::Error` from
   * `pty.node … ThreadSafeFunction::CallJS` under `node::FreeEnvironment`, and a
   * crash report on the person's screen. So the last step waits for the exits
   * (bounded — `PtyManager.drain`), then exits.
   */
  let drained = false
  app.on('will-quit', (event) => {
    void bridge?.close()
    if (drained) return
    event.preventDefault()
    void options
      .drain()
      .catch(() => undefined)
      .finally(() => {
        drained = true
        app.exit(0)
      })
  })
}


/** The page's banners, shown here. See `notifications.ts`. */
function registerNativeNotifications(): void {
  const notifier = createNativeNotifier({
    supported: () => Notification.isSupported(),
    // Silent, as the renderer asks for its own: the user's sound setting is the system's.
    make: ({ title, body }) => new Notification({ title, body, silent: true }),
    push: (channel, args) => {
      bridge?.emit(channel, args)
    },
  })
  ipcMain.handle(NOTIFY_CHANNEL, (_event, input: unknown) => notifier.notify(input))
  ipcMain.handle(NOTIFY_CLOSE_CHANNEL, (_event, id: unknown) => notifier.close(id))
}
