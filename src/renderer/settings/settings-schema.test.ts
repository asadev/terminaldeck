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
    // The rest are real sections with nothing to persist — shortcuts, help and
    // about are read-only, profiles and agents write through their own modules.
    expect(settingsIn('general').length).toBeGreaterThan(0)
    expect(settingsIn('appearance').length).toBeGreaterThan(0)
    expect(settingsIn('notifications').length).toBeGreaterThan(0)
    expect(settingsIn('shortcuts')).toEqual([])
    expect(settingsIn('help')).toEqual([])
    expect(settingsIn('about')).toEqual([])
    // Agents kept its pane and lost its setting when the default coding tool
    // moved to General. An empty list here is the expected state, not a hole.
    expect(settingsIn('agents')).toEqual([])
  })

  it('shows General exactly what it promises, in order', () => {
    // This section is the one people open, and its order was chosen rather than
    // accumulated. Asserting it here is what stops the next setting from being
    // appended to the end of the block because that is where the cursor was.
    expect(settingsIn('general').map((setting) => setting.id)).toEqual([
      'general.language',
      'general.defaultProvider',
      'general.soundOnFinish',
      'general.notifyOnAttention',
      'general.showInsightAlerts',
      'general.autoNameSessions',
      'general.confirmCloseWorking',
      'general.copyOnSelect',
    ])
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
    // The real case: General was rebuilt, and these four moved section — which
    // is a rename, because an id carries its section as its prefix.
    const merged = mergeSettings({
      'notifications.sound': true,
      'notifications.onNeedsInput': false,
      'general.restoreSessions': false,
      'agents.defaultProvider': 'codex',
    })
    expect(merged['general.soundOnFinish']).toBe(true)
    expect(merged['general.notifyOnAttention']).toBe(false)
    expect(merged['advanced.restoreSessions']).toBe(false)
    expect(merged['general.defaultProvider']).toBe('codex')
    expect(merged['notifications.sound']).toBeUndefined()
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
    const provider = find('general.defaultProvider') as SelectSetting
    expect(provider.options.map((o) => o.value)).toEqual(['claude', 'codex', 'gemini', 'shell'])
  })

  it('names a distinct prefsKey for each', () => {
    const keys = SETTINGS.filter((s) => s.store === 'prefs').map((s) => s.prefsKey)
    expect(keys).toEqual(['defaultProvider', 'theme', 'notifyOnComplete', 'restoreSessions'])
  })
})

describe('the language picker', () => {
  it('offers English and says nothing it cannot deliver', () => {
    const language = find('general.language') as SelectSetting
    expect(language.options.map((option) => option.value)).toEqual(['en'])
    // A one-option select is deliberate here, so the schema's own check has to
    // allow it — this is the assertion that catches the rule being tightened
    // back to "at least two" without anyone noticing this row.
    expect(settingsSchemaProblems()).toEqual([])
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
      'general.defaultProvider': 'codex',
      'advanced.restoreSessions': false,
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
