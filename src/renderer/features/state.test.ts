import { describe, expect, it, vi } from 'vitest'
import { getSetting } from '../settings/settings-schema'
import { FEATURES, feature } from './registry'
import {
  availableFeatures,
  clearFeatureData,
  defaultFeatureState,
  everythingOff,
  everythingOn,
  FEATURES_KEY,
  installedFeatures,
  isInstalled,
  isOn,
  mergeFeatureState,
  readFeatureState,
  statusOf,
  uninstallPlan,
  withStatus,
  writeFeatureState,
} from './state'

/**
 * The model behind the store, tested away from React — every question the
 * window asks is answered here first.
 *
 * Two things are worth more than the rest and both are about *loss*: that
 * turning something off keeps what it stored, and that uninstalling deletes
 * exactly what the dialog said it would. Everything else is a state machine
 * with three states.
 */

/** A `localStorage` that lives in a variable. */
function fakeStorage(seed: Record<string, string> = {}): Storage {
  const map = new Map(Object.entries(seed))
  return {
    get length() {
      return map.size
    },
    clear: () => map.clear(),
    getItem: (key: string) => map.get(key) ?? null,
    key: (index: number) => [...map.keys()][index] ?? null,
    removeItem: (key: string) => void map.delete(key),
    setItem: (key: string, value: string) => void map.set(key, value),
  }
}

describe('what a fresh install has', () => {
  it('gives every feature its declared default', () => {
    const state = defaultFeatureState()
    for (const entry of FEATURES) {
      expect(statusOf(state, entry.id), entry.id).toBe(entry.default === 'on' ? 'on' : 'uninstalled')
    }
  })

  it('has something in both lists, which is what makes the store worth opening', () => {
    const state = defaultFeatureState()
    expect(installedFeatures(state).length).toBeGreaterThan(0)
    expect(availableFeatures(state).length).toBeGreaterThan(0)
  })

  it('is what an install with nothing stored gets', () => {
    expect(readFeatureState(fakeStorage())).toEqual(defaultFeatureState())
    expect(readFeatureState(null)).toEqual(defaultFeatureState())
  })
})

describe('off and uninstalled are different', () => {
  const id = 'browser'

  it('keeps a switched-off feature installed', () => {
    const state = withStatus(defaultFeatureState(), id, 'off')
    expect(isOn(state, id)).toBe(false)
    expect(isInstalled(state, id)).toBe(true)
    // And it stays in the installed list, which is where it can be switched
    // back on. A feature that vanished from both lists would be unreachable.
    expect(installedFeatures(state).map((entry) => entry.id)).toContain(id)
    expect(availableFeatures(state).map((entry) => entry.id)).not.toContain(id)
  })

  it('takes an uninstalled feature out of the installed list', () => {
    const state = withStatus(defaultFeatureState(), id, 'uninstalled')
    expect(isOn(state, id)).toBe(false)
    expect(isInstalled(state, id)).toBe(false)
    expect(availableFeatures(state).map((entry) => entry.id)).toContain(id)
  })
})

describe('a stored map from any build', () => {
  it('fills in a feature it has never heard of with that feature’s default', () => {
    // The case this covers is shipping a new feature to an existing install:
    // the stored map predates it, and the honest answer is what a fresh install
    // would have got rather than "off, because nobody has said otherwise".
    const merged = mergeFeatureState({ browser: 'off' })
    expect(merged.browser).toBe('off')
    for (const entry of FEATURES.filter((f) => f.id !== 'browser')) {
      expect(statusOf(merged, entry.id), entry.id).toBe(entry.default === 'on' ? 'on' : 'uninstalled')
    }
  })

  it('keeps an id this build does not know', () => {
    // A downgrade, or one agent's build meeting another's. Dropping the key is
    // how a user's choice about a feature silently reverts the next time the
    // older build writes the file back.
    const merged = mergeFeatureState({ 'not-a-feature-here': 'off' })
    expect(merged['not-a-feature-here']).toBe('off')
  })

  it('ignores a value that is not one of the three states', () => {
    const merged = mergeFeatureState({ browser: 'sort-of', split: 7, swarm: null })
    expect(merged.browser).toBe(feature('browser').default === 'on' ? 'on' : 'uninstalled')
    expect(merged.split).toBe(feature('split').default === 'on' ? 'on' : 'uninstalled')
  })

  it('survives anything at all', () => {
    for (const raw of ['', 'null', '[]', '{oops', null, undefined, 42, ['on']]) {
      expect(mergeFeatureState(raw), String(raw)).toEqual(defaultFeatureState())
    }
  })

  it('never lets a stored key reach the prototype', () => {
    const merged = mergeFeatureState('{"__proto__":"off"}')
    expect(Object.getPrototypeOf(merged)).toBe(Object.prototype)
    expect(({} as Record<string, unknown>).browser).toBeUndefined()
  })
})

describe('storage', () => {
  it('reads back what it wrote', () => {
    const storage = fakeStorage()
    const state = withStatus(defaultFeatureState(), 'hooks', 'on')
    writeFeatureState(state, storage)
    expect(storage.getItem(FEATURES_KEY)).toBeTruthy()
    expect(readFeatureState(storage)).toEqual(state)
  })

  it('falls back to the defaults rather than throwing when the store is angry', () => {
    const broken: Storage = {
      ...fakeStorage(),
      getItem: () => {
        throw new Error('SecurityError')
      },
      setItem: () => {
        throw new Error('QuotaExceededError')
      },
    }
    expect(readFeatureState(broken)).toEqual(defaultFeatureState())
    // A write that cannot land must not take the window down with it: the
    // choice is already on screen, it simply will not survive a restart.
    expect(() => writeFeatureState(defaultFeatureState(), broken)).not.toThrow()
  })
})

describe('what uninstalling says it will delete', () => {
  it('names the settings, and counts them', () => {
    const plan = uninstallPlan('browser')
    const line = plan.find((item) => item.label.includes('setting'))
    expect(line).toBeDefined()
    expect(line?.label).toContain(String(feature('browser').settings.length))
    // By name, not by id. "browser.startUrl" is not a thing anybody chose.
    for (const setting of feature('browser').settings) {
      expect(line?.detail).toContain(getSetting(setting)?.label)
    }
  })

  it('names the data as well as the settings', () => {
    const labels = uninstallPlan('browser').map((item) => item.label)
    for (const data of feature('browser').data) expect(labels).toContain(data.label)
  })

  it('is empty for a feature that stores nothing of yours', () => {
    // Empty is the answer for most of them, and the store says so in words.
    // Inventing a line to fill the space would be inventing a deletion.
    expect(uninstallPlan('split')).toEqual([])
    expect(uninstallPlan('swarm')).toEqual([])
  })
})

describe('what uninstalling actually does', () => {
  it('puts every setting it owns back to its default, in one write', () => {
    const save = vi.fn()
    clearFeatureData('browser', { save })
    expect(save).toHaveBeenCalledTimes(1)
    const patch = save.mock.calls[0][0] as Record<string, unknown>
    for (const setting of feature('browser').settings) {
      expect(patch[setting], setting).toBe(getSetting(setting)?.default)
    }
  })

  it('clears the data the plan promised', () => {
    const clearBrowserData = vi.fn(() => Promise.resolve())
    clearFeatureData('browser', { save: vi.fn(), clearBrowserData })
    expect(clearBrowserData).toHaveBeenCalledTimes(1)
  })

  it('writes nothing at all for a feature that owns nothing', () => {
    const save = vi.fn()
    const clearBrowserData = vi.fn(() => Promise.resolve())
    clearFeatureData('split', { save, clearBrowserData })
    expect(save).not.toHaveBeenCalled()
    expect(clearBrowserData).not.toHaveBeenCalled()
  })

  it('does not need a bridge to be there', () => {
    // A build whose preload has not wired the clearance still resets the
    // settings. Refusing the whole uninstall over a missing channel would leave
    // a feature that cannot be removed at all.
    expect(() => clearFeatureData('browser', { save: vi.fn() })).not.toThrow()
  })
})

describe('the extremes', () => {
  it('answers for every feature with everything on', () => {
    const state = everythingOn()
    for (const entry of FEATURES) {
      expect(isOn(state, entry.id), entry.id).toBe(true)
      expect(isInstalled(state, entry.id), entry.id).toBe(true)
    }
    expect(availableFeatures(state)).toEqual([])
    expect(installedFeatures(state)).toHaveLength(FEATURES.length)
  })

  it('answers for every feature with everything off', () => {
    const state = everythingOff()
    for (const entry of FEATURES) {
      expect(isOn(state, entry.id), entry.id).toBe(false)
      expect(isInstalled(state, entry.id), entry.id).toBe(false)
    }
    expect(installedFeatures(state)).toEqual([])
    expect(availableFeatures(state)).toHaveLength(FEATURES.length)
  })
})
