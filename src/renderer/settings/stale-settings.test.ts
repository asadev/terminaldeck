import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { mergeSettings } from './settings-schema'
import { sameValues, storedValues } from './SettingsWindow'

/**
 * A page's settings follow every save, its own included, without its own save
 * coming back to disturb it.
 *
 * Every save is now told to every window (`main/settings-broadcast.test.ts`).
 * The app window already merges that push (`useAppSettings`). The Settings
 * panel re-reads what is stored — quietly, with no loading state — and skips
 * the re-read while a save of its own is still in flight, and throws away a
 * re-read that started before it saved again: a stale answer landing last would
 * put an old value back under the cursor.
 */

const PANEL = readFileSync(join(__dirname, 'SettingsWindow.tsx'), 'utf8')
const HOOK = readFileSync(join(__dirname, 'useAppSettings.ts'), 'utf8')

describe('what is stored, read the one way', () => {
  it('lets preferences win for the keys they own, and fills in the defaults', () => {
    const merged = storedValues({ theme: 'light' }, { version: 1, values: { 'appearance.theme': 'dark', 'appearance.density': 'compact' } })
    expect(merged['appearance.theme']).toBe('light')
    expect(merged['appearance.density']).toBe('compact')
    expect(sameValues(merged, mergeSettings({ ...merged }))).toBe(true)
  })

  it('tells a real change from a page’s own echo', () => {
    const now = storedValues({ theme: 'dark' }, null)
    expect(sameValues(now, storedValues({ theme: 'dark' }, null))).toBe(true)
    expect(sameValues(now, storedValues({ theme: 'light' }, null))).toBe(false)
  })
})

describe('the Settings panel', () => {
  it('re-reads quietly on every push, and only when nothing of its own is on the way', () => {
    expect(PANEL).toContain('const offPrefs = bridge.onPreferencesChanged?.(() => refresh())')
    expect(PANEL).toContain('const offSettings = bridge.onSettingsChanged?.(() => refresh())')
    const refresh = PANEL.slice(PANEL.indexOf('const refresh = useCallback('), PANEL.indexOf('}, [bridge])', PANEL.indexOf('const refresh = useCallback(')))
    expect(refresh).toContain('if (writing.current > 0) return')
    expect(refresh).toContain('if (saves.current !== savesAtStart || writing.current > 0 || loadId.current !== generation) return')
    expect(refresh).toContain('if (sameValues(merged, latest.current)) return')
    expect(refresh).not.toContain('setLoading(')
  })

  it('counts its own saves in and out, whether they land or fail', () => {
    const save = PANEL.slice(PANEL.indexOf('const save = useCallback('), PANEL.indexOf('[bridge, onChange, onSaveState]'))
    expect(save).toContain('saves.current += 1')
    expect(save).toContain('writing.current += 1')
    expect(save.match(/writing\.current -= 1/g)).toHaveLength(2)
  })
})

describe('every other page', () => {
  it('merges the pushed store over what it holds (useAppSettings)', () => {
    expect(HOOK).toContain('window.deck.onPreferencesChanged?.((prefs) => {')
    expect(HOOK).toContain('window.deck.onSettingsChanged?.((stored) => {')
  })
})
