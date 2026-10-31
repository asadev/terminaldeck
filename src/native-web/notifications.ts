/**
 * The web `Notification` API, backed by the engine in the native window.
 *
 * The app tells a person a session finished or needs them with
 * `new Notification(title, { body })` and an `onclick` that selects the
 * session (`renderer/notifications.ts`); Settings' "send a test" does the same
 * (`settings/notification-check.ts`). Chromium backs that with the system's
 * banners. The native window's web view has no `Notification` at all, so this
 * stands in for it, with the engine showing the banner exactly as Electron
 * shows its own (`main/native-shell/notifications.ts`):
 *
 *     invoke native-shell:notify        { id, title, body }  → { shown }
 *     invoke native-shell:notify-close  id
 *     push   native-shell:notification-click  id
 *
 * A click comes back to the instance that showed it, which runs its own
 * `onclick` and `click` listeners — the page's code, unchanged.
 */

export const NOTIFY_CHANNEL = 'native-shell:notify'
export const NOTIFY_CLOSE_CHANNEL = 'native-shell:notify-close'
export const NOTIFICATION_CLICK_CHANNEL = 'native-shell:notification-click'

interface NotifyIpc {
  invoke(channel: string, ...args: unknown[]): Promise<unknown>
  on(channel: string, listener: (event: unknown, ...args: unknown[]) => void): unknown
}

type Handler = ((this: unknown, event: unknown) => unknown) | null

/** One banner, as the page holds it — the slice of the web `Notification` the app uses. */
export interface NativeNotificationInstance {
  readonly title: string
  readonly body: string
  readonly tag: string
  readonly silent: boolean
  readonly data: unknown
  onclick: Handler
  onclose: Handler
  onshow: Handler
  onerror: Handler
  close(): void
  addEventListener(type: string, listener: (event: unknown) => void): void
  removeEventListener(type: string, listener: (event: unknown) => void): void
}

/** The class the page sees as `window.Notification`. */
export interface NativeNotificationConstructor {
  new (title: string, options?: NativeNotificationOptions): NativeNotificationInstance
  readonly permission: 'granted'
  requestPermission(callback?: (permission: string) => void): Promise<string>
}

export interface NativeNotificationOptions {
  body?: string
  tag?: string
  silent?: boolean
  data?: unknown
}

/**
 * A `Notification` class for this page. Permission is granted — whether a
 * banner may appear is the system's question, asked by the engine when it shows
 * one, and its answer is the `show` or `error` event.
 */
export function createNativeNotification(ipc: NotifyIpc, makeId: () => string = defaultId): NativeNotificationConstructor {
  const live = new Map<string, NativeNotification>()

  class NativeNotification extends EventTarget {
    static readonly permission = 'granted'
    static requestPermission(callback?: (permission: string) => void): Promise<string> {
      callback?.('granted')
      return Promise.resolve('granted')
    }

    readonly title: string
    readonly body: string
    readonly tag: string
    readonly silent: boolean
    readonly data: unknown
    onclick: Handler = null
    onclose: Handler = null
    onshow: Handler = null
    onerror: Handler = null
    readonly #id: string

    constructor(title: string, options: NativeNotificationOptions = {}) {
      super()
      this.title = String(title)
      this.body = typeof options.body === 'string' ? options.body : ''
      this.tag = typeof options.tag === 'string' ? options.tag : ''
      this.silent = options.silent === true
      this.data = options.data ?? null
      this.#id = makeId()
      live.set(this.#id, this)
      ipc.invoke(NOTIFY_CHANNEL, { id: this.#id, title: this.title, body: this.body }).then(
        (answer) => this.fire((answer as { shown?: unknown } | null)?.shown === true ? 'show' : 'error'),
        () => this.fire('error'),
      )
    }

    close(): void {
      if (!live.delete(this.#id)) return
      void ipc.invoke(NOTIFY_CLOSE_CHANNEL, this.#id).catch(() => undefined)
      this.fire('close')
    }

    /** @internal — a click on this banner, or one of the others. */
    fire(type: 'click' | 'close' | 'show' | 'error'): void {
      const event = new Event(type)
      this.dispatchEvent(event)
      const handler = this[`on${type}`]
      if (typeof handler === 'function') handler.call(this, event)
    }
  }

  ipc.on(NOTIFICATION_CLICK_CHANNEL, (_event, id) => {
    if (typeof id === 'string') live.get(id)?.fire('click')
  })

  return NativeNotification
}

let counter = 0
function defaultId(): string {
  counter += 1
  // Every page hears every click, so an id must be unique across pages, not only within one.
  return `n-${Date.now().toString(36)}-${counter}-${Math.random().toString(36).slice(2, 8)}`
}
