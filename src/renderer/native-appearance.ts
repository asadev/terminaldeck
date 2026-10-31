/**
 * The app's theme, told to the native macOS window, so its sidebar, toolbar and
 * Settings chrome are painted in the same scheme as the page.
 *
 *   { type: 'appearance', preference: 'dark' | 'light' | 'system', resolved: 'dark' | 'light' }
 *
 * Posted once when a page starts and again on every change — the setting
 * changing, or the Mac switching light/dark while the setting is 'system'.
 *
 * The preference travels as well as the resolved scheme, and that is not
 * redundant. With 'system' the native window must follow the Mac rather than
 * pin the scheme it was told: pinning it would make this page's own
 * `prefers-color-scheme` answer with the pinned value from then on, so the app
 * would never see the Mac change again.
 *
 * Outside the native window (Electron, the browser client) nothing is posted.
 */

import { isNativeShell, postToNative, type NativeHost } from '../shared/native-shell'
import { themeController, type ResolvedTheme, type ThemeController, type ThemePreference } from './theme'

export interface NativeAppearanceMessage {
  type: 'appearance'
  preference: ThemePreference
  resolved: ResolvedTheme
}

export function appearanceMessage(preference: ThemePreference, resolved: ResolvedTheme): NativeAppearanceMessage {
  return { type: 'appearance', preference, resolved }
}

/**
 * Tell the native window the theme now and on every change. Returns the cleanup,
 * so `useEffect(() => publishNativeAppearance(), [])` is the whole of the wiring.
 */
export function publishNativeAppearance(
  theme: Pick<ThemeController, 'getPreference' | 'getResolved' | 'subscribe'> = themeController(),
  host: NativeHost = globalThis as NativeHost,
): () => void {
  if (!isNativeShell(host)) return () => {}
  const now = appearanceMessage(theme.getPreference(), theme.getResolved())
  postToNative(now, host)
  return theme.subscribe((resolved, preference) => {
    const next = appearanceMessage(preference, resolved)
    postToNative(next, host)
  })
}
