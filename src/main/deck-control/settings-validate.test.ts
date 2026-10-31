import { describe, expect, it } from 'vitest'
import { checkSettingsValues, problemSentence } from './settings-validate'
import { getSetting, SETTINGS } from '../../renderer/settings/settings-schema'

/**
 * Validation against the real schema, not a fixture of one.
 *
 * The point of this module is that there is one settings table and this side of
 * the app reads it rather than copying it, so a test built on a hand-written
 * stand-in would be testing the copy this file exists to avoid. Every case below
 * therefore names a setting that really exists — and if one of them is renamed
 * or has its options changed, this test is *supposed* to notice.
 */

describe('the schema is the one being read', () => {
  it('is reading the app’s real settings table', () => {
    // Cheap, and it is the assertion that catches the seam breaking: if the
    // import ever resolves to something empty or stubbed, everything else here
    // would pass by validating nothing.
    expect(SETTINGS.length).toBeGreaterThan(10)
    expect(getSetting('appearance.density')?.kind).toBe('select')
  })
})

describe('values a setting can take', () => {
  it('accepts a declared option', () => {
    const check = checkSettingsValues('settings', { 'appearance.density': 'compact' })
    expect(check.problems).toEqual([])
    expect(check.effective).toEqual({ 'appearance.density': 'compact' })
  })

  /**
   * The OpenClaw failure, in one line.
   *
   * `tools.profile: "none"` was a value outside its enum, and it took down
   * their entire gateway rather than the agent it was set on — recovery needed
   * a different application on a different machine to hand-edit JSON. Here the
   * same shape of mistake is a sentence back to the model, before anybody has
   * been asked to approve anything.
   */
  it('refuses a value outside the enum, and names what would be accepted', () => {
    const check = checkSettingsValues('settings', { 'appearance.density': 'none' })
    expect(check.problems).toHaveLength(1)
    expect(problemSentence(check.problems)).toContain('comfortable')
    expect(problemSentence(check.problems)).toContain('compact')
    expect(check.effective).toEqual({})
  })

  it('refuses a key that names no setting', () => {
    const check = checkSettingsValues('settings', { 'made.up': true })
    expect(problemSentence(check.problems)).toContain('there is no setting called made.up')
  })

  it('refuses the wrong type for a toggle', () => {
    const check = checkSettingsValues('settings', { 'general.copyOnSelect': 'yes' })
    expect(problemSentence(check.problems)).toContain('true or false')
  })

  it('reports every bad key, not just the first', () => {
    const check = checkSettingsValues('settings', {
      'appearance.density': 'none',
      'made.up': 1,
      'general.copyOnSelect': true,
    })
    expect(check.problems.map((problem) => problem.key).sort()).toEqual(['appearance.density', 'made.up'])
    // The whole patch is refused by the caller; `effective` still reports what
    // *would* have been written, which is what makes a partial-application bug
    // visible here rather than in the settings file.
    expect(check.effective).toEqual({ 'general.copyOnSelect': true })
  })

  /**
   * A clamp is the schema's own decision, and this module does not overrule it.
   *
   * `coerce` clamps a number into range rather than rejecting it, deliberately:
   * a font size of 400 was a real preference typed into a build with a wider
   * range, and snapping it back keeps the app readable. What matters here is
   * that the clamp is *reported*, so a confirmation can name the value that
   * will actually be written instead of the one that was asked for.
   */
  it('clamps a number in range and says that it did', () => {
    const setting = getSetting('appearance.terminalFontSize')
    expect(setting?.kind).toBe('number')
    const max = setting?.kind === 'number' ? setting.max : 0

    const check = checkSettingsValues('settings', { 'appearance.terminalFontSize': 4_000 })
    expect(check.problems).toEqual([])
    expect(check.effective['appearance.terminalFontSize']).toBe(max)
    expect(check.adjusted).toEqual(['appearance.terminalFontSize'])
  })
})

describe('the two scopes are not interchangeable', () => {
  /**
   * The write that would have reported success and changed nothing.
   *
   * `appearance.theme` is prefs-backed, and the renderer resolves the two stores
   * as `{ ...settingsJson, ...valuesFromPreferences(prefs) }` — preferences
   * last. So writing it into `settings.json` puts a value on disk that no reader
   * ever consults, and the copilot would tell the person their theme had
   * changed. The tests in `control.test.ts` used exactly this key until this
   * check was written.
   */
  it('refuses a prefs-backed id written into the settings scope, and names the other scope', () => {
    const check = checkSettingsValues('settings', { 'appearance.theme': 'light' })
    expect(problemSentence(check.problems)).toContain('scope "preferences"')
    expect(problemSentence(check.problems)).toContain('theme')
  })

  it('accepts the same change through the preferences scope', () => {
    const check = checkSettingsValues('preferences', { theme: 'light' })
    expect(check.problems).toEqual([])
    expect(check.effective).toEqual({ theme: 'light' })
  })

  it('refuses a preference value the schema does not offer', () => {
    // `store.setPreferences` merges a partial without validating it, and has
    // done since it was written. This is the only thing standing between the
    // copilot and a theme that is not a theme.
    expect(checkSettingsValues('preferences', { theme: 'neon' }).problems).toHaveLength(1)
    expect(checkSettingsValues('preferences', { defaultProvider: 'gpt' }).problems).toHaveLength(1)
    expect(checkSettingsValues('preferences', { restoreSessions: 'yes' }).problems).toHaveLength(1)
  })

  it('lets null remove a setting, and refuses it as a preference', () => {
    // Settings: `applyPatch` deletes the key, which is how one setting goes back
    // to its default without the caller knowing what that default is.
    expect(checkSettingsValues('settings', { 'appearance.density': null }).problems).toEqual([])
    // Preferences: there is no delete. A stored `null` would be read back as a
    // theme that is not a theme, so it is refused rather than invented into
    // "reset", which is not a thing this tool offers.
    expect(problemSentence(checkSettingsValues('preferences', { theme: null }).problems)).toContain(
      'cannot be set to null',
    )
  })
})
