/**
 * The two facts about the native macOS window that both sides of its page need:
 * how to tell the page is inside it, and how to say something to it.
 *
 * Shared rather than owned by either side because both compile it. The page
 * shim (`src/native-web/native-shell.ts`, built with the preload) sets the
 * marker and reports the title; the renderer (`renderer/native-commands.ts`)
 * reads the marker and says when the app is ready. One handler name, one
 * marker — two copies would be two places for the native side's contract to
 * drift.
 */

/** The `WKScriptMessageHandler` name the native window registers. */
export const NATIVE_MESSAGE_HANDLER = 'tdNative'

/** The slice of `window` read and written here, so callers and tests need no DOM. */
export interface NativeHost {
  tdNative?: unknown
  document?: { documentElement?: { dataset?: Record<string, string | undefined> } }
  webkit?: { messageHandlers?: Record<string, { postMessage(message: unknown): void } | undefined> }
}

/** Set by the page shim, as `<html data-shell="native">`, before the renderer runs. */
export function isNativeShell(host: NativeHost = globalThis as NativeHost): boolean {
  return host.document?.documentElement?.dataset?.shell === 'native'
}

/** A message to the native window, when one is listening; nothing otherwise. */
export function postToNative<M extends { type: string }>(message: M, host: NativeHost = globalThis as NativeHost): void {
  host.webkit?.messageHandlers?.[NATIVE_MESSAGE_HANDLER]?.postMessage(message)
}
