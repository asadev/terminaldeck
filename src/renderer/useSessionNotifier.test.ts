import { describe, expect, it } from 'vitest'
import { notifyPolicy } from './useSessionNotifier'
import { DEFAULT_VALUES, mergeSettings } from './settings/settings-schema'

const withSettings = (patch: Record<string, unknown>) =>
  mergeSettings({ ...DEFAULT_VALUES, ...patch })

describe('notifyPolicy', () => {
  it('banners a finish and a question by default, in the background', () => {
    const policy = notifyPolicy(withSettings({}), false)
    expect(policy.banner('completed')).toBe(true)
    expect(policy.banner('input')).toBe(true)
  })

  it('never banners a status that is only passing weather', () => {
    const policy = notifyPolicy(withSettings({}), false)
    for (const status of ['working', 'waiting', 'idle', 'exited'] as const) {
      expect(policy.banner(status), status).toBe(false)
    }
  })

  it('honours the two switches separately', () => {
    const noFinish = notifyPolicy(
      withSettings({ 'notifications.onComplete': false }),
      false,
    )
    expect(noFinish.banner('completed')).toBe(false)
    expect(noFinish.banner('input')).toBe(true)

    const noAttention = notifyPolicy(
      withSettings({ 'general.notifyOnAttention': false }),
      false,
    )
    expect(noAttention.banner('completed')).toBe(true)
    expect(noAttention.banner('input')).toBe(false)
  })

  it('goes quiet while the window is in front, when asked to', () => {
    // The default. `watching` in notifications.ts already covers the session on
    // screen; this switch is about the whole app being in front.
    const focused = notifyPolicy(withSettings({}), true)
    expect(focused.banner('completed')).toBe(false)
    expect(focused.banner('input')).toBe(false)

    const always = notifyPolicy(
      withSettings({ 'notifications.onlyWhenUnfocused': false }),
      true,
    )
    expect(always.banner('completed')).toBe(true)
  })

  it('keeps the sound independent of the banner', () => {
    // Two switches, two answers: someone can want a ding and no banner, and
    // folding them together would make the sound switch a no-op whenever
    // notifications were off.
    const sound = notifyPolicy(
      withSettings({ 'general.soundOnFinish': true, 'notifications.onComplete': false }),
      false,
    )
    expect(sound.sound).toBe(true)
    expect(sound.banner('completed')).toBe(false)

    expect(notifyPolicy(withSettings({}), false).sound).toBe(false)
  })

  it('does not silence the sound just because the window is in front', () => {
    // `onlyWhenUnfocused` says "notify", meaning the banner. A ding while you
    // are looking at another tab of the same app is the point of the setting.
    const policy = notifyPolicy(withSettings({ 'general.soundOnFinish': true }), true)
    expect(policy.sound).toBe(true)
  })
})
