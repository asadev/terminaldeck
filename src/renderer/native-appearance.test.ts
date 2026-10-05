import { describe, expect, it } from 'vitest'
import { NATIVE_MESSAGE_HANDLER, type NativeHost } from '../shared/native-shell'
import { appearanceMessage, publishNativeAppearance } from './native-appearance'
import { createThemeController, type ThemeMediaQuery } from './theme'

/** A page host that records what it tells the native window. */
function host(native: boolean) {
  const posted: unknown[] = []
  const target: NativeHost = {
    document: { documentElement: { dataset: native ? { shell: 'native' } : {} } },
    webkit: { messageHandlers: { [NATIVE_MESSAGE_HANDLER]: { postMessage: (message) => posted.push(message) } } },
  }
  return { target, posted }
}

/** A real theme controller over a fake Mac setting that can be flipped. */
function theme(systemDark: boolean) {
  const listeners = new Set<(event: { matches: boolean }) => void>()
  const media: ThemeMediaQuery = {
    matches: systemDark,
    addEventListener: (_type, listener) => listeners.add(listener),
    removeEventListener: (_type, listener) => listeners.delete(listener),
  }
  const controller = createThemeController({ root: { setAttribute: () => {} }, matchMedia: () => media }, 'dark')
  const setMac = (dark: boolean) => {
    media.matches = dark
    for (const listener of [...listeners]) listener({ matches: dark })
  }
  return { controller, setMac }
}

describe('the native window is told the app theme', () => {
  it('says the current theme as soon as the page starts', () => {
    const page = host(true)
    publishNativeAppearance(theme(false).controller, page.target)
    expect(page.posted).toEqual([{ type: 'appearance', preference: 'dark', resolved: 'dark' }])
  })

  it('says it again on every change of the setting', () => {
    const page = host(true)
    const { controller } = theme(false)
    publishNativeAppearance(controller, page.target)
    controller.setPreference('light')
    controller.setPreference('system')
    expect(page.posted.slice(1)).toEqual([
      appearanceMessage('light', 'light'),
      appearanceMessage('system', 'light'),
    ])
  })

  it("follows the Mac while the setting is 'system', and says so as 'system'", () => {
    const page = host(true)
    const { controller, setMac } = theme(false)
    controller.setPreference('system')
    publishNativeAppearance(controller, page.target)
    setMac(true)
    setMac(false)
    // 'system' travels with the scheme, so the native window follows the Mac
    // instead of pinning one (which would freeze the page's own media query).
    expect(page.posted).toEqual([
      appearanceMessage('system', 'light'),
      appearanceMessage('system', 'dark'),
      appearanceMessage('system', 'light'),
    ])
  })

  it('posts nothing outside the native window', () => {
    const page = host(false)
    const { controller } = theme(true)
    const stop = publishNativeAppearance(controller, page.target)
    controller.setPreference('light')
    stop()
    expect(page.posted).toEqual([])
  })

  it('stops when cleaned up', () => {
    const page = host(true)
    const { controller } = theme(false)
    const stop = publishNativeAppearance(controller, page.target)
    stop()
    controller.setPreference('light')
    expect(page.posted).toHaveLength(1)
  })
})
