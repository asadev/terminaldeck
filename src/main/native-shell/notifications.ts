/**
 * The renderer's banners, shown by this process for the native page.
 *
 * The app tells a person a session finished or needs them with the web
 * `Notification` API (`renderer/notifications.ts`). Chromium backs that with
 * the system's notifications; the native window's web view does not have it at
 * all. So the page's shim hands each banner here, this process shows it the way
 * Electron shows its own, and a click comes back to the page as a push — which
 * runs the page's own `onclick`, the one that selects the session.
 *
 *  - `native-shell:notify`        (invoke, `{ id, title, body? }`) → `{ shown }`
 *  - `native-shell:notify-close`  (invoke, id)
 *  - `native-shell:notification-click` (push, id)
 */

export const NOTIFY_CHANNEL = 'native-shell:notify'
export const NOTIFY_CLOSE_CHANNEL = 'native-shell:notify-close'
export const NOTIFICATION_CLICK_CHANNEL = 'native-shell:notification-click'

/** More banners than anybody reads; the oldest are let go so a long run cannot grow this without end. */
const MAX_LIVE = 50

export interface BannerHandle {
  show(): void
  close(): void
  on(event: 'click' | 'close', listener: () => void): void
}

export interface NativeNotifier {
  notify(input: unknown): { shown: boolean }
  close(id: unknown): void
}

export function createNativeNotifier(deps: {
  supported(): boolean
  make(input: { title: string; body: string }): BannerHandle
  /** Push to the page. */
  push(channel: string, args: unknown[]): void
}): NativeNotifier {
  const live = new Map<string, BannerHandle>()
  return {
    notify(input) {
      const request = typeof input === 'object' && input !== null ? (input as Record<string, unknown>) : {}
      const id = typeof request.id === 'string' ? request.id.slice(0, 200) : ''
      const title = typeof request.title === 'string' ? request.title.slice(0, 500) : ''
      const body = typeof request.body === 'string' ? request.body.slice(0, 2000) : ''
      if (id === '' || title === '' || !deps.supported()) return { shown: false }
      live.get(id)?.close()
      const banner = deps.make({ title, body })
      live.set(id, banner)
      banner.on('click', () => {
        deps.push(NOTIFICATION_CLICK_CHANNEL, [id])
        live.delete(id)
      })
      banner.on('close', () => {
        if (live.get(id) === banner) live.delete(id)
      })
      while (live.size > MAX_LIVE) {
        const oldest = live.keys().next().value
        if (oldest === undefined) break
        live.delete(oldest)
      }
      banner.show()
      return { shown: true }
    },
    close(id) {
      if (typeof id !== 'string') return
      live.get(id)?.close()
      live.delete(id)
    },
  }
}
