import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { BANNER_SETTINGS, deliveryCopy, turnedOnABanner } from './notification-check'
import { SETTINGS } from './settings-schema'

/**
 * The wording is the feature, so the wording is what is tested.
 *
 * This pane once printed **"Sent. If nothing appeared, the banner was
 * suppressed by a Focus mode."** for a banner macOS had silently dropped — a
 * confident success it had not confirmed, followed by the single cause that had
 * already been checked and ruled out. Both halves sent whoever was debugging it
 * in the wrong direction for hours.
 *
 * These tests are the tripwire on both halves.
 */
describe('deliveryCopy', () => {
  it('only sounds like success when the OS confirmed it', () => {
    const copy = deliveryCopy({ verdict: 'delivered', at: '2026-08-14 09:52:11' }, 'test', 'mac')
    expect(copy.tone).toBe('info')
    expect(copy.text).toContain('macOS recorded a banner')
    expect(copy.text).toContain('09:52:11')
    // Nothing to escape to: it worked.
    expect(copy.offerSettings).toBe(false)
  })

  it('says the OS has no record when the OS has no record', () => {
    const copy = deliveryCopy({ verdict: 'absent', at: null }, 'test', 'mac')
    expect(copy.tone).toBe('warn')
    expect(copy.text).toContain('no record')
    expect(copy.offerSettings).toBe(true)
  })

  it('names authorisation, not a Focus mode, as the likely cause', () => {
    const copy = deliveryCopy({ verdict: 'absent', at: null }, 'test', 'mac')
    expect(copy.text).toMatch(/pending or has been refused/i)
    expect(copy.text).not.toMatch(/focus/i)
  })

  it('says where Allow hides, because that is the bug', () => {
    for (const kind of ['test', 'enabled'] as const) {
      const copy = deliveryCopy({ verdict: 'absent', at: null }, kind, 'mac')
      expect(copy.text).toContain('Options')
    }
    expect(deliveryCopy({ verdict: 'unknown', at: null }, 'enabled', 'mac').text).toContain('Options')
  })

  it('never claims delivery it could not check', () => {
    const copy = deliveryCopy({ verdict: 'unknown', at: null }, 'test', 'mac')
    expect(copy.tone).toBe('warn')
    expect(copy.text).toContain('cannot read')
    expect(copy.text).not.toMatch(/^Sent\b/)
    expect(copy.offerSettings).toBe(true)
  })

  it('names the reader’s own OS, never macOS at a Windows user', () => {
    const windows = deliveryCopy({ verdict: 'unknown', at: null }, 'test', 'windows')
    expect(windows.text).toContain('Windows')
    expect(windows.text).not.toContain('macOS')

    const other = deliveryCopy({ verdict: 'absent', at: null }, 'test', 'other')
    expect(other.text).not.toContain('macOS')
    expect(other.text).not.toContain('Windows')
  })

  it('reports a switch being turned on without pretending it is proven', () => {
    const unknown = deliveryCopy({ verdict: 'unknown', at: null }, 'enabled', 'mac')
    expect(unknown.text).toMatch(/^On\./)
    expect(unknown.tone).toBe('warn')

    const proven = deliveryCopy({ verdict: 'delivered', at: '2026-08-14 09:52:11' }, 'enabled', 'mac')
    expect(proven.text).toMatch(/proven/i)
    expect(proven.tone).toBe('info')
  })
})

/**
 * The ask has to survive the settings window being rearranged.
 *
 * macOS asks for notification authorisation exactly once, with a banner whose
 * Allow is hidden under `Options`. Fire it when nobody is looking and the
 * feature is dead for good, in silence — so "the switch was flipped, therefore
 * the OS was asked" is not a nicety, it is the only chance the feature gets.
 *
 * These switches have already moved between sections once. The guard below is
 * deliberately the same shape as `wiring.test.ts`: it reads the section sources
 * and fails the build if a section that draws a banner switch stops routing its
 * saves through the ask.
 */
describe('turnedOnABanner', () => {
  it('fires only when a banner setting is switched on', () => {
    expect(turnedOnABanner({ 'notifications.onNeedsInput': true })).toBe(true)
    expect(turnedOnABanner({ 'notifications.onComplete': true })).toBe(true)
  })

  it('does not fire when one is switched off', () => {
    // Posting a banner to announce that banners are off would be absurd, and
    // would also burn the one prompt the OS ever gives us.
    expect(turnedOnABanner({ 'notifications.onNeedsInput': false })).toBe(false)
    expect(turnedOnABanner({ 'notifications.onComplete': false })).toBe(false)
  })

  it('ignores every other setting, and a merely-present key', () => {
    expect(turnedOnABanner({ 'general.autoNameSessions': true })).toBe(false)
    expect(turnedOnABanner({})).toBe(false)
    expect(turnedOnABanner({ 'notifications.onComplete': 'true' })).toBe(false)
    expect(turnedOnABanner({ 'notifications.onComplete': undefined })).toBe(false)
  })

  it('names settings that actually exist', () => {
    // A typo here fails open — nothing matches, nothing asks, and the only
    // symptom is notifications quietly never working.
    const known = new Set(SETTINGS.map((setting) => setting.id))
    for (const id of BANNER_SETTINGS) expect(known.has(id)).toBe(true)
  })
})

describe('the ask is wired to the switch, not to a button', () => {
  /*
   * One section now, where there were two.
   *
   * Both banner switches lived in General until the window was regrouped by
   * subject on 2026-08-17 — which is why this list existed at all, and why
   * `BANNER_SETTINGS` is a list in a module rather than an id inside a section.
   * Derived from the schema rather than typed out, so the day one of them moves
   * again, the section it moves *to* is the one this checks.
   */
  const sections = [...new Set(
    BANNER_SETTINGS.map((id) => {
      const setting = SETTINGS.find((entry) => entry.id === id)
      const section = setting?.section ?? 'notifications'
      // The pane for a section id, by the convention every file in `sections/`
      // follows. Agents is the assembled pane, so a banner switch landing there
      // would have to be checked in the file that draws it.
      return `sections/${section[0].toUpperCase()}${section.slice(1)}Section.tsx`
    }),
  )]

  it('every section drawing a banner switch routes its saves through the ask', () => {
    const detached: string[] = []
    for (const file of sections) {
      const text = readFileSync(join(__dirname, file), 'utf8')
      // The section hands `save` to <SettingList>. If it hands the raw `save`
      // rather than the wrapper that asks, the switch still works and the OS is
      // never asked — which is exactly the failure that shipped.
      if (!text.includes('turnedOnABanner')) detached.push(`${file}: no longer asks the OS`)
      if (!/save=\{saveAndProve\}/.test(text)) detached.push(`${file}: SettingList is not on the asking path`)
    }
    expect(detached).toEqual([])
  })
})
