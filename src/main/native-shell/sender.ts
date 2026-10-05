import { EventEmitter } from 'node:events'

/**
 * The `event.sender` every bridge call carries: a stand-in for the main
 * window's `WebContents`.
 *
 * ## What handlers actually read off a sender
 *
 * Read from the handlers in `src/main`, not guessed:
 *
 *  - `send(channel, …)` — the subscription modules (usage, cost, plan limit,
 *    MCP state, devices, diagnostics, the lift inbox) keep the sender and push
 *    to it later. Here that is the bridge's event stream.
 *  - `isDestroyed()` and `once('destroyed', …)` — `web-contents-teardown.ts`
 *    and every subscriber set. Never destroyed while the engine runs, which is
 *    what a window that reloads looks like too.
 *  - `id` — the per-window cancellation keys in search, file search and
 *    artifacts. A number no real `WebContents` gets in practice.
 *  - `session` — `browser-workers-ipc.ts` asks whether the sender is a guest
 *    page. The app's own window lives in the default session, so that is what
 *    this answers.
 *  - `getOwnerBrowserWindow()` — what `BrowserWindow.fromWebContents` calls.
 *    Null, so a handler that wants a window to attach something to gets the
 *    "no window" answer it already has, instead of a type error from Electron.
 *  - `mainFrame` — null, and `senderFrame` on the event is null too: the
 *    guest-page checks that compare frames refuse, which is right.
 *  - `executeJavaScript(code)` — Hoot's window readers. Only the three known
 *    page calls run, as named calls over the bridge (`page-call.ts`); any other
 *    script is refused, because no other script is ever sent.
 *
 * Identity is the point: `isApprover` in `index.ts` compares the sender
 * against the main window's contents, and in native mode it also accepts this
 * one object — `isNativeShellSender` — and nothing else.
 */
export interface NativeSender extends EventEmitter {
  readonly id: number
  readonly mainFrame: null
  readonly session: unknown
  send(channel: string, ...args: unknown[]): void
  isDestroyed(): boolean
  isCrashed(): boolean
  isLoading(): boolean
  getURL(): string
  getTitle(): string
  getType(): string
  getOwnerBrowserWindow(): null
  executeJavaScript(code: string, userGesture?: boolean): Promise<unknown>
}

export interface NativeSenderOptions {
  /** Deliver a push to the page. Answers whether anybody received it. */
  deliver(channel: string, args: readonly unknown[]): boolean
  /** The page's address, for `getURL()`. */
  url(): string
  /** The session the app's own window would be in. Read lazily: Electron's is not ready at import. */
  session(): unknown
  /** Run one of the page's named calls. Absent: nothing is run. */
  evaluate?(code: string): Promise<unknown>
}

/** Far above any id Electron hands out in a run, so it can never collide with a real one. */
export const NATIVE_SENDER_ID = 1_000_000_000

export function createNativeSender(options: NativeSenderOptions): NativeSender {
  const sender = new EventEmitter() as NativeSender
  Object.defineProperties(sender, {
    id: { value: NATIVE_SENDER_ID, enumerable: true },
    mainFrame: { value: null, enumerable: true },
    session: { get: () => options.session(), enumerable: true },
  })
  // `destroyed` listeners pile up one per subscription and are never fired
  // while the engine runs; that is not a leak worth a warning.
  sender.setMaxListeners(0)
  sender.send = (channel: string, ...args: unknown[]): void => {
    options.deliver(channel, args)
  }
  sender.isDestroyed = () => false
  sender.isCrashed = () => false
  sender.isLoading = () => false
  sender.getURL = () => options.url()
  sender.getTitle = () => ''
  sender.getType = () => 'window'
  sender.getOwnerBrowserWindow = () => null
  sender.executeJavaScript = (code: string) =>
    options.evaluate !== undefined
      ? options.evaluate(code)
      : Promise.reject(new Error('The native shell runs its page in a native window; this process cannot run script in it.'))
  return sender
}
