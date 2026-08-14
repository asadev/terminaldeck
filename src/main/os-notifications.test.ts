import { describe, expect, it } from 'vitest'
import { notificationDelivery, notificationSettingsUrl, notificationSupport } from './os-notifications'

/**
 * The two things this module must never get wrong.
 *
 * **It must not quote one platform's settings URL at another.** Roughly 115
 * places in this codebase said "Mac" to Windows users in one night; a deep link
 * is the version of that mistake that also does nothing when clicked.
 *
 * **It must never answer `delivered` without having asked.** Every branch that
 * cannot reach macOS's notification store has to come back `unknown`, because
 * the copy for `unknown` claims nothing and the copy for `delivered` claims the
 * banner appeared. Getting that backwards is the whole bug this module exists
 * to close.
 */
describe('notificationSettingsUrl', () => {
  it('deep-links the macOS notifications pane', () => {
    expect(notificationSettingsUrl('darwin')).toBe(
      'x-apple.systempreferences:com.apple.Notifications-Settings.extension',
    )
  })

  it('uses Windows own scheme on Windows', () => {
    expect(notificationSettingsUrl('win32')).toBe('ms-settings:notifications')
  })

  it('offers nothing where there is no such page, rather than the wrong one', () => {
    expect(notificationSettingsUrl('linux')).toBeNull()
    expect(notificationSettingsUrl('freebsd')).toBeNull()
  })
})

describe('notificationSupport', () => {
  it('tells a Linux renderer not to draw a settings button', () => {
    const support = notificationSupport('linux')
    expect(support.settingsPane).toBe(false)
    expect(support.deliveryReadable).toBe(false)
  })

  it('offers the button on Windows but promises no verification', () => {
    const support = notificationSupport('win32')
    expect(support.settingsPane).toBe(true)
    expect(support.deliveryReadable).toBe(false)
  })
})

describe('notificationDelivery', () => {
  it('is unknown — never delivered — on a platform it cannot ask', async () => {
    for (const platform of ['win32', 'linux'] as const) {
      const report = await notificationDelivery(Date.now(), { platform })
      expect(report.verdict).toBe('unknown')
      expect(report.at).toBeNull()
      expect(report.detail).toBeTruthy()
    }
  })
})
