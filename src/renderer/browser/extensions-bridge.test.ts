import { describe, expect, it } from 'vitest'
import {
  EXTENSION_FACETS,
  extensionActionLabel,
  extensionActionVerb,
  extensionCompat,
  extensionFacets,
  extensionSource,
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
    category: 'appearance',
    tags: [],
    needs: [],
    cost: 'free',
    costNote: '',
    works: 'works',
    logo: '',
    measured: 'Watched working.',
    url: '',
    sha256: '',
    bytes: 0,
    state: 'available',
    installedVersion: '',
    installedAt: 0,
    enabled: false,
    reach: [],
    mayAsk: [],
    everywhere: false,
    missing: [],
    provides: [],
    inert: [],
    rulesetsSwitchedOn: 0,
    popup: '',
    optionsPage: '',
    sideloaded: false,
    origin: '',
    crxId: '',
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

  it('is drawn on every row, because every row is one this browser installs', () => {
    /*
     * This replaces a test for `canAct`, which answered false for a row this app
     * watched failing. There is no such row any more — `CatalogueEntry` refuses
     * to hold one — so the function had one answer left and went. What is worth
     * keeping is the pair of labels, which is what the button actually says.
     */
    expect(extensionActionLabel(row({ state: 'available' }), false)).toBe('Install')
    expect(extensionActionLabel(row({ state: 'installed' }), false)).toBe('Remove')
    expect(extensionActionVerb(row({ state: 'damaged' }))).toBe('remove')
  })
})

describe('the storefront projection', () => {
  it('reads `partly` as unknown rather than as working', () => {
    /*
     * The honest reading of what the catalogue says about those rows: *"Loads.
     * Its background page runs with no uncaught error. It was not watched
     * applying a style, so this app does not claim it does."* A filter called
     * "Works here" that returned it would be making the claim the row refuses.
     */
    expect(extensionCompat(row({ works: 'partly' }))).toBe('unknown')
    // `unmeasured` still arrives — it is what a sideloaded folder carries.
    expect(extensionCompat(row({ works: 'unmeasured' }))).toBe('unknown')
    expect(extensionCompat(row({ works: 'works' }))).toBe('works')
    /*
     * And `cannot` still has a reading, though no catalogue row can be it any
     * more. This is a wire narrowing: an older main process, or a caller that
     * sends something else entirely, must land somewhere defined rather than on
     * `works`.
     */
    expect(extensionCompat(row({ works: 'no' }))).toBe('cannot')
  })

  it('derives where a row comes from rather than carrying a new field for it', () => {
    /*
     * Two answers now, where there were three. `web-store` went with the rows
     * that were it: a project publishing through the Chrome Web Store and
     * nowhere this app can fetch from is not something the catalogue can hold.
     */
    expect(extensionSource(row())).toBe('release')
    expect(extensionSource(row({ sideloaded: true }))).toBe('your-own')
  })

  it('searches tags and the shelf name, and never the measured paragraph', () => {
    /*
     * Those paragraphs mention `chrome.tabs`, `ads.doubleclick.net` and every
     * namespace this browser lacks, so searching them would make a search for
     * "cookies" return the ad blockers and one for "tabs" return most of the
     * catalogue. A search that answers with almost everything is the same as one
     * that answers with nothing, and slower to disbelieve.
     */
    const facets = extensionFacets(
      row({ tags: ['adblock'], measured: 'It reaches for chrome.cookies, which is not here.' }),
    )
    expect(facets.tags).toEqual(['adblock'])
    expect([facets.name, facets.summary, facets.categoryName, ...facets.tags].join(' ')).not.toContain(
      'chrome.cookies',
    )
  })

  it('counts a damaged install as installed, because the files are on the disk', () => {
    expect(extensionFacets(row({ state: 'damaged' })).installed).toBe(true)
    expect(extensionFacets(row({ state: 'installed' })).installed).toBe(true)
    expect(extensionFacets(row({ state: 'available' })).installed).toBe(false)
  })
})

/*
 * `describe('the link out')` used to be here — four tests over `linkOut` and
 * `linkOutLabel`, checking that a row with no Install offered **Get it** or
 * **Open project** instead. Both functions are gone, and so is the reason for
 * them: no row in this store lacks an Install, and the destination those
 * buttons opened was, for most of them, the Chrome Web Store. See
 * `extensions-bridge.ts` where they used to live.
 */

describe('price on an extension row', () => {
  it('travels as its own facet, because every extension is a free download', () => {
    // *Free to install* is true of every row in a browser store and says nothing
    // about 1Password, whose extension does nothing at all without a paid
    // account.
    expect(extensionFacets(row({ cost: 'paid' })).cost).toBe('paid')
    expect(extensionFacets(row({ cost: 'free' })).cost).toBe('free')
  })

  it('lands on "not known" when nothing was sent, never on free', () => {
    /*
     * `unknown` is a real answer here rather than a hedge: a sideloaded folder
     * is something this app has never seen, and pricing it would be inventing a
     * fact. That makes it the right thing to fall back to when a main process
     * one version behind sends no price at all — the alternative, `free`, is the
     * one guess that can cost somebody money.
     */
    const view = readExtensionsView({ view: { extensions: [{ id: 'a' }] } })
    expect(view.extensions[0]?.cost).toBe('unknown')
    expect(
      readExtensionsView({ view: { extensions: [{ id: 'a', cost: 'cheap' }] } }).extensions[0]?.cost,
    ).toBe('unknown')
    expect(
      readExtensionsView({ view: { extensions: [{ id: 'a', cost: 'metered' }] } }).extensions[0]
        ?.cost,
    ).toBe('metered')
  })

  it('keeps "not known" as a chip, because a folder somebody added really is one', () => {
    const ids = (EXTENSION_FACETS.cost?.options ?? []).map((option) => option.id)
    expect(ids).toEqual(['free', 'account', 'metered', 'paid', 'unknown'])
  })
})
