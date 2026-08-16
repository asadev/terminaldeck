import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { WIDGET_TYPES } from '../dashboard/layout'
import { KEYMAP } from '../keymap'
import { getSetting, SECTIONS } from '../settings/settings-schema'
import { PANELS } from '../shell/panels'
import {
  CONTROL_IDS,
  FEATURES,
  featureOwningCommand,
  featureOwningControl,
  featureOwningPanel,
  featureOwningSection,
  featureOwningSetting,
  featureOwningWidget,
  featureRegistryProblems,
  isFeatureId,
} from './registry'

/**
 * The registry is a set of promises about the rest of the app, so this file
 * checks them against the rest of the app rather than against itself.
 *
 * The one that matters most is the first: **remote access is never a feature.**
 * That is not a style preference, it is the product decision the whole store was
 * built around — *"remote is the main one we are differentiating ourselves. so
 * it's not an optional feature"* — and it is exactly the kind of decision that
 * gets undone six months later by somebody tidying a list. So it is asserted,
 * surface by surface, in the file that would have to change to break it.
 */

const APP = readFileSync(join(__dirname, '..', 'App.tsx'), 'utf8')

describe('the table itself', () => {
  it('has no structural problems', () => {
    expect(featureRegistryProblems()).toEqual([])
  })

  it('recognises its own ids and nothing else', () => {
    for (const entry of FEATURES) expect(isFeatureId(entry.id)).toBe(true)
    for (const other of ['', 'remote', 'terminal', '__proto__']) {
      expect(isFeatureId(other), other).toBe(false)
    }
  })

  it('ships a starter set that is neither everything nor nothing', () => {
    // A fresh install has to feel complete without being the busy window this
    // was built to calm down. Both extremes would mean the defaults had stopped
    // being a decision: all-on is the app before the store, all-off is an app
    // that greets you with an empty room.
    const on = FEATURES.filter((entry) => entry.default === 'on')
    expect(on.length).toBeGreaterThan(0)
    expect(on.length).toBeLessThan(FEATURES.length)
  })
})

describe('remote access is not in the store', () => {
  /*
   * Every surface remote owns, named the way the app names it: the Remote
   * *panel* in the rail — it was briefly a settings section after the Machines
   * merge and has moved back, because pairing a device is something you do
   * rather than configure — and Power, the desk-side half of the same feature,
   * because keeping the machine awake is what makes a session survive the lid
   * closing, and reaching it from a phone is why you would want that.
   */
  it('claims none of its settings sections', () => {
    expect(featureOwningSection('power')).toBeNull()
  })

  it('claims no panel of its own, including the one it moved back to', () => {
    expect(featureOwningPanel('remote')).toBeNull()
  })

  it('claims no command belonging to it', () => {
    for (const command of ['app.join', 'view.machines', 'remote.start']) {
      expect(featureOwningCommand(command), command).toBeNull()
    }
  })
})

describe('the app itself is not in the store', () => {
  it('leaves sessions, files, artifacts, source control and the overview alone', () => {
    for (const panel of ['overview', 'files', 'artifacts', 'git'] as const) {
      expect(featureOwningPanel(panel), panel).toBeNull()
    }
    for (const widget of ['sessions', 'git'] as const) {
      expect(featureOwningWidget(widget), widget).toBeNull()
    }
    for (const command of [
      'session.new',
      'session.close',
      'session.resume',
      'project.open',
      'app.preferences',
      'palette.commands',
      'view.files',
      'view.search',
      'view.git',
      'view.dashboard',
    ]) {
      expect(featureOwningCommand(command), command).toBeNull()
    }
  })

  it('leaves settings, updates and profiles alone', () => {
    const owned = SECTIONS.filter((section) => featureOwningSection(section.id) !== null)
    // Exactly one settings section belongs to a feature today. Written as the
    // whole list rather than as a spot check, so adding a second is a decision
    // somebody makes here rather than a side effect of a declaration.
    expect(owned.map((section) => section.id)).toEqual(['browser'])
  })
})

describe('every surface a feature claims is a real one', () => {
  it('names panels the sidebar actually has', () => {
    const ids = new Set(PANELS.map((panel) => panel.id))
    for (const entry of FEATURES) {
      for (const panel of entry.panels) expect(ids.has(panel), `${entry.id} → ${panel}`).toBe(true)
    }
  })

  it('names widgets the dashboard actually has', () => {
    for (const entry of FEATURES) {
      for (const widget of entry.widgets) {
        expect(WIDGET_TYPES.includes(widget), `${entry.id} → ${widget}`).toBe(true)
      }
    }
  })

  it('names settings the schema actually declares', () => {
    for (const entry of FEATURES) {
      for (const setting of entry.settings) {
        expect(getSetting(setting), `${entry.id} → ${setting}`).toBeDefined()
      }
    }
  })

  /**
   * A command a feature owns has to be a command the app dispatches, or the
   * feature gates nothing — the row would keep working with the feature
   * uninstalled, which is the exact failure this whole table exists to stop.
   *
   * Read out of `App.tsx` as text for the same reason `reachable.test.ts` reads
   * it that way: there is no DOM here to mount the app in.
   *
   * **Both** spellings count, because `run()` has always had two arms and this
   * check only knew about one. A command either appears in the `commands`
   * table as `id: 'x'` or is handled by the `switch (id)` below it as
   * `case 'x':` — `pane.split` takes the first route and `pane.focusLeft` the
   * second. Testing only the table form meant a genuinely dispatched command
   * could not be declared here without failing, which is how the two pane-focus
   * chords ended up ownerless and advertised while their feature was off.
   */
  it('names commands the app dispatches', () => {
    for (const entry of FEATURES) {
      for (const command of entry.commands) {
        const dispatched =
          APP.includes(`id: '${command}'`) || APP.includes(`case '${command}':`)
        expect(dispatched, `${entry.id} → ${command}`).toBe(true)
      }
    }
  })

  it('does not claim a chord the keymap has since dropped', () => {
    // Only for the commands that have one: a feature command with no binding is
    // fine (the palette row is enough), a feature command whose binding was
    // renamed is a chord that silently stops opening the store.
    const bound = new Set(KEYMAP.map((binding) => binding.id))
    for (const command of ['pane.split', 'view.swarm']) {
      expect(bound.has(command), command).toBe(true)
      expect(featureOwningCommand(command), command).not.toBeNull()
    }
  })

  /*
   * Every chord that only means something inside a split has to belong to the
   * split feature — not just the one that creates the split.
   *
   * `commands: ['pane.split']` was the whole declaration, so with Split view
   * uninstalled the shortcuts sheet still listed "Focus the pane to the left"
   * and "Focus the pane to the right", and both chords fell through the
   * dispatcher to `focusNeighbour`, which had no second pane to move to. A
   * chord that is advertised and then does nothing is the exact failure the
   * note beside ⌘D in `keymap.ts` was written against.
   *
   * Asserted over the keymap's own group rather than over a list spelled out
   * here, so a fourth pane chord added later cannot quietly arrive ownerless.
   */
  it('gives every pane chord to the split feature', () => {
    const paneChords = KEYMAP.filter((binding) => binding.group === 'Panes')
    expect(paneChords.length).toBeGreaterThan(1)
    for (const binding of paneChords) {
      expect(featureOwningCommand(binding.id), binding.label).toBe('split')
    }
  })

  it('gives every declared control an owner', () => {
    for (const control of CONTROL_IDS) expect(featureOwningControl(control)).toBeTruthy()
  })
})

describe('what uninstalling would take with it', () => {
  it('never claims a setting two features could both delete', () => {
    // `featureRegistryProblems` already refuses a double claim; this is the
    // reader's version of the same fact, and the one that would be noticed in a
    // review: a settings id maps to at most one feature.
    for (const entry of FEATURES) {
      for (const setting of entry.settings) {
        expect(featureOwningSetting(setting), setting).toBe(entry.id)
      }
    }
  })

  it('says where every feature appears, in a sentence that names a place', () => {
    for (const entry of FEATURES) {
      // The install confirmation is this sentence. A category — "the sidebar",
      // "settings" — is not an answer to "where did it go", so each one has to
      // be long enough to name something specific.
      expect(entry.where.length, entry.id).toBeGreaterThan(20)
    }
  })
})
