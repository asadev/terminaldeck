import { describe, expect, it } from 'vitest'
import {
  booleanSetting,
  coerce,
  DEFAULT_VALUES,
  defaultPatch,
  getSetting,
  MAX_TEXT_LENGTH,
  mergeSettings,
  migrateSettingsFile,
  numberSetting,
  RENAMED_IDS,
  SECTION_IDS,
  SETTINGS,
  SETTINGS_VERSION,
  settingsIn,
  settingsSchemaProblems,
  SOUND_OPTIONS,
  splitPatch,
  stringSetting,
  valueOf,
  valuesFromPreferences,
  type NumberSetting,
  type SelectSetting,
  type Setting,
  type TextSetting,
} from './settings-schema'
import { SOUND_IDS } from './notification-sound'

/**
 * The schema is the only description of what the app stores, so these tests are
 * mostly about the ways a settings file can be *wrong* — written by an older
 * build, a newer one, or a corrupted disk — because that is where a settings
 * system either preserves someone's choices or silently resets them.
 */

function find(id: string): Setting {
  const setting = getSetting(id)
  if (!setting) throw new Error(`test needs a setting called ${id}`)
  return setting
}

describe('the table itself', () => {
  it('has no structural problems', () => {
    expect(settingsSchemaProblems()).toEqual([])
  })

  it('puts every setting in a declared section', () => {
    for (const setting of SETTINGS) {
      expect(SECTION_IDS, setting.id).toContain(setting.section)
    }
  })

  it('declares a default for every setting', () => {
    expect(Object.keys(DEFAULT_VALUES).sort()).toEqual(SETTINGS.map((s) => s.id).sort())
  })

  it('lists the sections that carry stored settings', () => {
    // The rest are real panes with nothing to persist — Help is read-only (About
    // is the masthead on it), and Tools writes through the feature registry
    // rather than through this table.
    expect(settingsIn('general').length).toBeGreaterThan(0)
    expect(settingsIn('appearance').length).toBeGreaterThan(0)
    expect(settingsIn('notifications').length).toBeGreaterThan(0)
    expect(settingsIn('agents').length).toBeGreaterThan(0)
    expect(settingsIn('help')).toEqual([])
    expect(settingsIn('features')).toEqual([])
  })

  it('shows General exactly what it promises, in order', () => {
    /*
     * This section is the one people open, and its order was chosen rather than
     * accumulated. Asserting it here is what stops the next setting from being
     * appended to the end of the block because that is where the cursor was.
     *
     * Three rows left in the 2026-08-17 regroup — the coding-tool picker to
     * Agents, the sound and the banner to Notifications — and one came back
     * from Advanced. This list is therefore also the record of what General is
     * now *about*: how a session behaves while you work.
     */
    expect(settingsIn('general').map((setting) => setting.id)).toEqual([
      'general.restoreSessions',
      'general.autoNameSessions',
      'general.confirmCloseWorking',
      'general.copyOnSelect',
    ])
  })

  /**
   * The language row is gone, and this is what stops it coming back.
   *
   *   > "It will be always English and it is English, so there is no selection.
   *   > The option should not be there."
   *
   * It had already survived one pass by being softened — the picker became the
   * word "English" beside a line explaining that English is the only one there
   * is — so the failure mode this guards against is not somebody re-adding a
   * dropdown. It is somebody re-adding the *row*, in any form, because a row
   * that states a constant reads like a reasonable thing to have.
   */
  it('declares no language row at all, in General or anywhere else', () => {
    expect(SETTINGS.map((setting) => setting.id)).not.toContain('general.language')
    expect(SETTINGS.filter((setting) => /language/i.test(setting.label))).toEqual([])
  })

  /**
   * And nobody's stored answer was thrown away on the way out.
   *
   * A removed setting is not a renamed one, so there is no `RENAMED_IDS` entry
   * to carry it — the value survives because `mergeSettings` keeps a key it does
   * not recognise. That is the clause the whole "a downgrade must not wipe a
   * setting" rule rests on, and this is the one place it can be checked against
   * a key that genuinely no longer exists.
   */
  it('keeps a stored language value rather than dropping it', () => {
    expect(mergeSettings({ 'general.language': 'en' })['general.language']).toBe('en')
  })

  it('puts every notification row in Notifications, which is the whole point', () => {
    /*
     * The regroup, stated as an invariant rather than as a list.
     *
     * *"Desktop notification when session need attention — all of this stuff,
     * this is notification part so should be in the notification section."* A
     * setting whose id begins with `notifications.` and whose section is
     * something else is the exact defect this pass fixed, and it is the one
     * that would come back first.
     */
    for (const setting of SETTINGS) {
      if (setting.id.startsWith('notifications.')) {
        expect(setting.section, setting.id).toBe('notifications')
      }
    }
    expect(settingsIn('notifications')).toHaveLength(6)
  })
})

describe('the rename table', () => {
  /**
   * A rename that points at nothing, or one whose old id is still declared,
   * fails in the one way this table exists to prevent: silently. `mergeSettings`
   * would map the stored value onto a key no setting owns, and the control would
   * come up on its default with the user's choice sitting in the file beside it.
   */
  it('renames onto settings that exist, from ids that no longer do', () => {
    const ids = new Set(SETTINGS.map((setting) => setting.id))
    for (const [from, to] of Object.entries(RENAMED_IDS)) {
      expect(ids.has(from), `${from} is renamed but still declared`).toBe(false)
      expect(ids.has(to), `${from} renames to ${to}, which is not declared`).toBe(true)
    }
  })

  it('carries a value written under the old id onto the new one', () => {
    // The real case: the settings window was regrouped by subject on
    // 2026-08-17, and five rows moved section — which is a rename, because an
    // id carries its section as its prefix.
    const merged = mergeSettings({
      'general.soundOnFinish': true,
      'general.notifyOnAttention': false,
      'general.showInsightAlerts': false,
      'general.defaultProvider': 'codex',
      'advanced.restoreSessions': false,
    })
    expect(merged['notifications.onFinishSound']).toBe(true)
    expect(merged['notifications.onNeedsInput']).toBe(false)
    expect(merged['notifications.showInsightAlerts']).toBe(false)
    expect(merged['agents.defaultProvider']).toBe('codex')
    expect(merged['general.restoreSessions']).toBe(false)
    expect(merged['general.soundOnFinish']).toBeUndefined()
    expect(merged['advanced.restoreSessions']).toBeUndefined()
  })

  it('carries a value written two builds ago, not just one', () => {
    /*
     * `notifications.sound` predates both regroups: it became
     * `general.soundOnFinish` and is now `notifications.onFinishSound`.
     * `mergeSettings` applies the table exactly once and does not chase chains,
     * so the entry for the oldest name has to point at the *current* id rather
     * than at the intermediate one. That is the mistake this asserts against —
     * it would leave a value sitting under a key nothing owns.
     */
    expect(mergeSettings({ 'notifications.sound': true })['notifications.onFinishSound']).toBe(true)
  })

  it('reads an old id through the accessors, because App.tsx still uses three', () => {
    /*
     * `App.tsx` and `useSessionNotifier.ts` read settings by id, and `App.tsx`
     * is a file no single agent may edit while several are working in this
     * repository. `booleanSetting('advanced.restoreSessions')` used to throw
     * "no setting" the moment that row moved — a blank window rather than a
     * failed test. The accessors resolve through this table, and this is what
     * keeps that true.
     */
    const values = mergeSettings({ 'general.restoreSessions': false })
    expect(booleanSetting(values, 'advanced.restoreSessions')).toBe(false)
    expect(booleanSetting(values, 'general.restoreSessions')).toBe(false)
    expect(stringSetting(mergeSettings({}), 'general.defaultProvider')).toBe('claude')
  })
})

describe('the prefs-backed settings', () => {
  /**
   * `splitPatch` casts its result to `Partial<Preferences>`. These two are what
   * make that cast a checked claim rather than a hope: if the options ever
   * stop matching the union in shared/types, the cast would start lying and
   * this fails first.
   */
  it('offers exactly the theme values store.ts accepts', () => {
    const theme = find('appearance.theme') as SelectSetting
    expect(theme.options.map((o) => o.value)).toEqual(['dark', 'light', 'system'])
  })

  it('offers exactly the provider ids store.ts accepts', () => {
    const provider = find('agents.defaultProvider') as SelectSetting
    expect(provider.options.map((o) => o.value)).toEqual(['claude', 'codex', 'gemini', 'shell'])
  })

  it('names a distinct prefsKey for each', () => {
    // Order follows the table, which follows the rail, which changed when the
    // window was regrouped by subject — the *set* is what matters here.
    const keys = SETTINGS.filter((s) => s.store === 'prefs').map((s) => s.prefsKey)
    expect([...keys].sort()).toEqual([
      'defaultProvider',
      'notifyOnComplete',
      'restoreSessions',
      'theme',
    ])
  })
})

describe('a select with one option', () => {
  /**
   * The rule outlived the row that demonstrated it.
   *
   * `general.language` was the only one-option select in the table and it has
   * been removed outright. The *allowance* stays, because what it protects is a
   * rendering rule in `SettingControl` — a one-option select is drawn as a
   * value, never as a dropdown — and a schema that rejected one would push the
   * next person into inventing a second option to get their row on screen,
   * which is a fake control arrived at by the tidiest possible route.
   *
   * Checked against a table of its own rather than against `SETTINGS`, so it
   * keeps testing the rule on the day nothing in the real table uses it.
   */
  it('is legal in the schema, so nobody has to invent a second option', () => {
    const only: SelectSetting = {
      id: 'general.example',
      section: 'general',
      label: 'Example',
      help: 'One option, on purpose.',
      store: 'extra',
      kind: 'select',
      default: 'a',
      options: [{ value: 'a', label: 'A' }],
    }
    expect(settingsSchemaProblems([only])).toEqual([])
  })

  it('is still a problem with no options at all', () => {
    const empty: SelectSetting = {
      id: 'general.example',
      section: 'general',
      label: 'Example',
      help: 'Nothing to choose.',
      store: 'extra',
      kind: 'select',
      default: 'a',
      options: [],
    }
    // Two problems: no option, and a default that cannot survive coercion
    // because there is no option for it to be.
    expect(settingsSchemaProblems([empty]).length).toBeGreaterThan(0)
  })
})

describe('the sound picker', () => {
  it('offers exactly the sounds that can actually be played', () => {
    expect(SOUND_OPTIONS.map((option) => option.value).sort()).toEqual([...SOUND_IDS].sort())
  })
})

describe('coerce', () => {
  it('accepts only the declared type', () => {
    const toggle = find('general.copyOnSelect')
    expect(coerce(toggle, true)).toBe(true)
    expect(coerce(toggle, 'true')).toBeNull()
    expect(coerce(toggle, 1)).toBeNull()
  })

  it('rejects a select value that is not on the list', () => {
    const density = find('appearance.density')
    expect(coerce(density, 'compact')).toBe('compact')
    expect(coerce(density, 'cosy')).toBeNull()
  })

  it('clamps a number instead of discarding it', () => {
    const size = find('appearance.terminalFontSize') as NumberSetting
    expect(coerce(size, 400)).toBe(size.max)
    expect(coerce(size, 1)).toBe(size.min)
    expect(coerce(size, 15)).toBe(15)
  })

  it('snaps a fractional number onto the step', () => {
    const size = find('appearance.terminalFontSize')
    expect(coerce(size, 14.4)).toBe(14)
    expect(coerce(size, 14.6)).toBe(15)
  })

  it('refuses NaN and Infinity, which JSON.parse can produce from a hand edit', () => {
    const size = find('appearance.terminalFontSize')
    expect(coerce(size, Number.NaN)).toBeNull()
    expect(coerce(size, Number.POSITIVE_INFINITY)).toBeNull()
  })

  it('truncates text rather than storing an essay', () => {
    const font = find('appearance.terminalFontFamily') as TextSetting
    const long = 'x'.repeat(MAX_TEXT_LENGTH + 50)
    expect((coerce(font, long) as string).length).toBe(MAX_TEXT_LENGTH)
  })

  it('accepts an empty string, which is a real choice for a text setting', () => {
    expect(coerce(find('appearance.terminalFontFamily'), '')).toBe('')
  })
})

describe('mergeSettings', () => {
  it('fills every missing key from the defaults', () => {
    const merged = mergeSettings({ 'general.copyOnSelect': true })
    expect(merged['general.copyOnSelect']).toBe(true)
    expect(merged['appearance.terminalFontSize']).toBe(DEFAULT_VALUES['appearance.terminalFontSize'])
    expect(Object.keys(merged).length).toBe(SETTINGS.length)
  })

  it('keeps a key it does not recognise', () => {
    // The case that matters: a newer build wrote this, and dropping it here
    // would delete the user's choice the moment an older build touched the file.
    const merged = mergeSettings({ 'future.somethingNew': 'keep me' })
    expect(merged['future.somethingNew']).toBe('keep me')
  })

  it('falls back to the default for a known key of the wrong type', () => {
    const merged = mergeSettings({ 'general.copyOnSelect': 'yes please' })
    expect(merged['general.copyOnSelect']).toBe(false)
  })

  it('survives junk where the file should be', () => {
    for (const junk of [null, undefined, 42, 'nope', []]) {
      expect(mergeSettings(junk)).toEqual(DEFAULT_VALUES)
    }
  })

  it('applies a rename before filling defaults', () => {
    const merged = mergeSettings(
      { 'general.oldName': true },
      { renames: { 'general.oldName': 'general.copyOnSelect' } },
    )
    expect(merged['general.copyOnSelect']).toBe(true)
    expect(merged['general.oldName']).toBeUndefined()
  })

  it('does not let a stored __proto__ key reach the prototype', () => {
    const merged = mergeSettings(JSON.parse('{"__proto__": {"polluted": true}}'))
    expect((merged as Record<string, unknown>).polluted).toBeUndefined()
    expect(({} as Record<string, unknown>).polluted).toBeUndefined()
  })
})

describe('migrateSettingsFile', () => {
  it('reads the versioned envelope', () => {
    const file = migrateSettingsFile({ version: 1, values: { 'general.copyOnSelect': true } })
    expect(file.version).toBe(SETTINGS_VERSION)
    expect(file.values['general.copyOnSelect']).toBe(true)
  })

  it('reads a bare map from before the envelope existed', () => {
    const file = migrateSettingsFile({ 'general.copyOnSelect': true })
    expect(file.values['general.copyOnSelect']).toBe(true)
    expect(file.values['general.autoNameSessions']).toBe(true)
  })
})

describe('splitPatch', () => {
  it('sends each key to the file that owns it', () => {
    const split = splitPatch({
      'appearance.theme': 'light',
      'appearance.density': 'compact',
    })
    expect(split.prefs).toEqual({ theme: 'light' })
    expect(split.extra).toEqual({ 'appearance.density': 'compact' })
    expect(split.unknown).toEqual([])
  })

  it('reports rather than writes anything it cannot place', () => {
    const split = splitPatch({ 'nope.notReal': 1, 'appearance.theme': 'chartreuse' })
    expect(split.prefs).toEqual({})
    expect(split.extra).toEqual({})
    expect(split.unknown.sort()).toEqual(['appearance.theme', 'nope.notReal'])
  })

  it('coerces on the way through, so a clamped number is what gets stored', () => {
    const split = splitPatch({ 'appearance.terminalFontSize': 999 })
    expect(split.extra['appearance.terminalFontSize']).toBe(24)
  })
})

describe('valuesFromPreferences', () => {
  it('maps store.ts preferences onto schema ids', () => {
    expect(
      valuesFromPreferences({
        theme: 'light',
        defaultProvider: 'codex',
        restoreSessions: false,
        notifyOnComplete: false,
      }),
    ).toEqual({
      'appearance.theme': 'light',
      'agents.defaultProvider': 'codex',
      'general.restoreSessions': false,
      'notifications.onComplete': false,
    })
  })

  it('skips a preference that is missing or unusable instead of inventing one', () => {
    expect(valuesFromPreferences({ theme: 'neon' })).toEqual({})
    expect(valuesFromPreferences(null)).toEqual({})
  })
})

describe('accessors', () => {
  it('return the stored value when it is valid', () => {
    const values = {
      'general.copyOnSelect': true,
      'appearance.density': 'compact',
      'appearance.terminalFontSize': 16,
    }
    expect(booleanSetting(values, 'general.copyOnSelect')).toBe(true)
    expect(stringSetting(values, 'appearance.density')).toBe('compact')
    expect(numberSetting(values, 'appearance.terminalFontSize')).toBe(16)
  })

  it('fall back to the default rather than handing a control junk', () => {
    const values = {
      'general.copyOnSelect': 'yes',
      'appearance.density': 'cosy',
      'appearance.terminalFontSize': 'big',
    }
    expect(booleanSetting(values, 'general.copyOnSelect')).toBe(false)
    expect(stringSetting(values, 'appearance.density')).toBe('comfortable')
    expect(numberSetting(values, 'appearance.terminalFontSize')).toBe(13)
  })

  it('throw when asked for a setting of the wrong kind — a bug, not bad data', () => {
    expect(() => booleanSetting({}, 'appearance.density')).toThrow()
    expect(() => numberSetting({}, 'nope')).toThrow()
  })

  it('valueOf coerces whatever is stored for a generated control', () => {
    expect(valueOf({ 'appearance.terminalFontSize': 999 }, find('appearance.terminalFontSize'))).toBe(24)
    expect(valueOf({}, find('appearance.theme'))).toBe('dark')
  })
})

describe('defaultPatch', () => {
  it('covers every setting, so a reset leaves nothing behind', () => {
    const patch = defaultPatch()
    expect(Object.keys(patch).sort()).toEqual(SETTINGS.map((s) => s.id).sort())
    const split = splitPatch(patch)
    expect(split.unknown).toEqual([])
    expect(Object.keys(split.prefs).length + Object.keys(split.extra).length).toBe(SETTINGS.length)
  })
})
