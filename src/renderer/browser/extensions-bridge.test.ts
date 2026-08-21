import { describe, expect, it } from 'vitest'
import {
  canAct,
  extensionActionLabel,
  extensionActionVerb,
  extensionsAvailable,
  reachWords,
  readExtensionResult,
  readExtensionsView,
  resolveExtensionsApi,
  type StoreExtension,
} from './extensions-bridge'

function row(over: Partial<StoreExtension> = {}): StoreExtension {
  return {
    id: 'x',
    name: 'X',
    summary: '',
    homepage: '',
    licence: 'MIT',
    version: '1.0',
    works: 'works',
    measured: 'Watched working.',
    url: '',
    sha256: '',
    bytes: 0,
    state: 'available',
    installedVersion: '',
    installedAt: 0,
    enabled: false,
    reach: [],
    everywhere: false,
    missing: [],
    provides: [],
    inert: [],
    rulesetsSwitchedOn: 0,
    popup: '',
    staticRulesets: false,
    message: '',
    ...over,
  }
}

describe('resolving the preload', () => {
  it('takes only the methods that are actually functions', () => {
    /*
     * A preload older than this feature must cost the browser its extension
     * store and never the whole browser — the argument `store-bridge.ts` makes
     * about its own optional methods.
     */
    const api = resolveExtensionsApi({ browserExtensions: () => Promise.resolve({}), browserExtensionInstall: 3 })
    expect(typeof api.browserExtensions).toBe('function')
    expect(api.browserExtensionInstall).toBeUndefined()
  })

  it('survives a host that is not an object at all', () => {
    expect(resolveExtensionsApi(null)).toEqual({})
    expect(resolveExtensionsApi('nonsense')).toEqual({})
  })
})

describe('whether the store is drawn at all', () => {
  const full = {
    browserExtensions: () => Promise.resolve({}),
    browserExtensionInstall: () => Promise.resolve({}),
    browserExtensionRemove: () => Promise.resolve({}),
    browserExtensionEnable: () => Promise.resolve({}),
  }

  it('needs list, install, remove and the switch', () => {
    expect(extensionsAvailable(full)).toBe(true)
  })

  it.each(['browserExtensions', 'browserExtensionInstall', 'browserExtensionRemove', 'browserExtensionEnable'])(
    'goes away without %s',
    (missing) => {
      /*
       * A store with a list and no Install is a catalogue of things you cannot
       * have; one with Install and no Remove is worse than none. The switch
       * joins them because an extension that can be installed and not turned off
       * is a program somebody cannot stop without deleting it.
       */
      const partial = { ...full }
      delete (partial as Record<string, unknown>)[missing]
      expect(extensionsAvailable(partial)).toBe(false)
    },
  )

  it('does not need the popup, which not every extension has anyway', () => {
    expect(extensionsAvailable(full)).toBe(true)
  })
})

describe('narrowing what the main process sent', () => {
  it('never throws on rubbish', () => {
    expect(readExtensionsView(null).extensions).toEqual([])
    expect(readExtensionsView({ view: 'nope' }).extensions).toEqual([])
    expect(readExtensionsView({ view: { extensions: [1, null, 'x'] } }).extensions).toEqual([])
  })

  it('drops a row with no id, which nothing could act on', () => {
    const view = readExtensionsView({ view: { extensions: [{ name: 'X' }, { id: 'a', name: 'A' }] } })
    expect(view.extensions.map((one) => one.id)).toEqual(['a'])
  })

  it('reads an unknown verdict as the safest one', () => {
    // `no` draws no Install. A corrupted field defaulting to `works` would draw
    // a button over something that cannot work.
    expect(readExtensionsView({ view: { extensions: [{ id: 'a', works: 'excellent' }] } }).extensions[0].works).toBe('no')
  })

  it('reads an unknown state as available rather than installed', () => {
    expect(readExtensionsView({ view: { extensions: [{ id: 'a', state: 'weird' }] } }).extensions[0].state).toBe(
      'available',
    )
  })

  it('carries the profiles and the limits through', () => {
    const view = readExtensionsView({
      view: { extensions: [], profileId: 'default', profileName: 'Default' },
      profiles: [{ id: 'default', name: 'Default' }, 'nonsense'],
      limits: ['No Chrome Web Store.', 7],
    })
    expect(view.profiles).toEqual([{ id: 'default', name: 'Default' }])
    expect(view.limits).toEqual(['No Chrome Web Store.'])
  })

  it('turns a missing answer into a refusal rather than a silent success', () => {
    expect(readExtensionResult(null)).toEqual({ ok: false, message: 'The app did not answer.' })
    expect(readExtensionResult({ ok: true, message: 'done' })).toEqual({ ok: true, message: 'done' })
  })
})

describe('the reach sentence', () => {
  it('spells out "every page" rather than printing <all_urls>', () => {
    // `<all_urls>` means nothing to somebody deciding whether to install a
    // program that will read their banking session.
    expect(reachWords(['<all_urls>'], true)).toBe('every page you open in this profile')
  })

  it('names the sites when it is only some', () => {
    expect(reachWords(['https://a.com/*', 'https://b.com/*'], false)).toBe('https://a.com/*, https://b.com/*')
  })

  it('says so when it reaches nothing', () => {
    expect(reachWords([], false)).toBe('no pages of its own')
  })
})

describe('the button', () => {
  it('says Install for something not installed and Remove for something that is', () => {
    expect(extensionActionLabel(row(), false)).toBe('Install')
    expect(extensionActionLabel(row({ state: 'installed' }), false)).toBe('Remove')
  })

  it('says Remove for a damaged install, not Reinstall', () => {
    // The files on disk are not the ones that were installed, and the honest
    // first move is to delete them.
    expect(extensionActionLabel(row({ state: 'damaged' }), false)).toBe('Remove')
    expect(extensionActionVerb(row({ state: 'damaged' }))).toBe('remove')
  })

  it('agrees with the verb it sends, in every state', () => {
    /*
     * A label that disagrees with its handler is the defect this app names
     * outright, and it is exactly what a pair of inline ternaries produces.
     */
    for (const state of ['available', 'installed', 'damaged'] as const) {
      const one = row({ state })
      const label = extensionActionLabel(one, false)
      expect(label === 'Remove' ? 'remove' : 'install').toBe(extensionActionVerb(one))
    }
  })

  it('is not drawn at all for something this app measured failing', () => {
    /*
     * Not disabled either: a disabled Install with a tooltip is still a store
     * offering something. An `unavailable` row has no download pinned, so the
     * button could only ever refuse.
     */
    expect(canAct(row({ state: 'unavailable', works: 'no' }))).toBe(false)
    expect(canAct(row({ state: 'available' }))).toBe(true)
    expect(canAct(row({ state: 'installed' }))).toBe(true)
  })
})
