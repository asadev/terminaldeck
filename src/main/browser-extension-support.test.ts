import { describe, expect, it } from 'vitest'
import {
  CHROMIUM_MEASURED,
  ELECTRON_MEASURED,
  EXTENSION_LIMITS,
  MISSING_APIS,
  SUPPORTED_APIS,
  displayName,
  everywhere,
  loadability,
  mayAskToReach,
  missingApis,
  optionsPageOf,
  parseManifest,
  popupPage,
  reachOf,
  requestedApis,
  setExtensionRuntime,
  usesStaticRulesets,
} from './browser-extension-support'

function manifest(over: Record<string, unknown> = {}): Record<string, unknown> {
  return { manifest_version: 3, name: 'X', version: '1.0', ...over }
}

describe('reading a manifest', () => {
  it('refuses bytes that are not JSON', () => {
    const result = parseManifest('{ not json')
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('not valid JSON')
  })

  it('refuses a manifest with no name or no version', () => {
    // Both become part of what the store writes down, so a missing one produces
    // an install whose record says nothing about what is in it.
    expect(parseManifest(JSON.stringify({ manifest_version: 3, version: '1' })).ok).toBe(false)
    expect(parseManifest(JSON.stringify({ manifest_version: 3, name: 'X' })).ok).toBe(false)
  })

  it('refuses a manifest version this browser has never loaded', () => {
    const result = parseManifest(JSON.stringify(manifest({ manifest_version: 1 })))
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('neither manifest version 2 nor 3')
  })

  it('takes both 2 and 3', () => {
    expect(parseManifest(JSON.stringify(manifest({ manifest_version: 2 }))).ok).toBe(true)
    expect(parseManifest(JSON.stringify(manifest())).ok).toBe(true)
  })
})

describe('the name a row draws', () => {
  it('falls back when the manifest name is a message key', () => {
    /*
     * uBlock Origin Lite, Violentmonkey and SponsorBlock all ship
     * `__MSG_extName__`. Drawing that would be this app repeating a placeholder
     * at somebody as though it were English.
     */
    expect(displayName({ name: '__MSG_extName__' }, 'uBlock Origin Lite')).toBe('uBlock Origin Lite')
  })

  it('uses the manifest\'s own name when it is a real one', () => {
    expect(displayName({ name: 'Dark Reader' }, 'Fallback')).toBe('Dark Reader')
  })
})

describe('which chrome.* an extension asks for', () => {
  it('leaves out things that are not namespaces at all', () => {
    /*
     * The false-sentence trap. `unlimitedStorage` is a quota and `activeTab` is
     * a grant; reporting either as "an API this browser does not have" would put
     * a true-sounding, false line on a row.
     */
    const asked = requestedApis(
      manifest({ permissions: ['storage', 'unlimitedStorage', 'activeTab', 'webRequestBlocking'] }),
    )
    expect(asked).toEqual(['storage'])
  })

  it('folds the declarativeNetRequest variants onto the namespace that exists', () => {
    expect(requestedApis(manifest({ permissions: ['declarativeNetRequestWithHostAccess'] }))).toEqual([
      'declarativeNetRequest',
    ])
    expect(missingApis(manifest({ permissions: ['declarativeNetRequestWithHostAccess'] }))).toEqual([])
  })

  it('leaves host patterns out — they are reach, not APIs', () => {
    expect(
      requestedApis(manifest({ permissions: ['<all_urls>', 'https://example.com/*', 'storage'] })),
    ).toEqual(['storage'])
  })

  it('counts optional permissions, because the code that calls them still throws', () => {
    expect(missingApis(manifest({ optional_permissions: ['contextMenus'] }))).toEqual(['contextMenus'])
  })

  it('names what uBlock Origin asks for and this browser has not got', () => {
    // The measured cause of the ad blocker not blocking. Kept as a test so the
    // catalogue's sentence about it stays connected to something checkable.
    const gaps = missingApis(
      manifest({
        manifest_version: 2,
        permissions: ['alarms', 'contextMenus', 'privacy', 'storage', 'tabs', 'webNavigation', 'webRequest'],
      }),
    )
    expect(gaps).toEqual(['contextMenus', 'privacy', 'webNavigation'])
  })

  it('reports nothing missing for an extension that asks only for what is here', () => {
    expect(missingApis(manifest({ permissions: ['storage', 'scripting', 'alarms'] }))).toEqual([])
  })

  it('never lists a namespace as both present and missing', () => {
    for (const api of SUPPORTED_APIS) expect(MISSING_APIS).not.toContain(api)
  })
})

describe('what an extension reaches', () => {
  it('reads host_permissions and MV2 host patterns alike', () => {
    expect(reachOf(manifest({ host_permissions: ['https://a.com/*'] }))).toEqual(['https://a.com/*'])
    expect(
      reachOf(manifest({ manifest_version: 2, permissions: ['storage', 'https://b.com/*'] })),
    ).toEqual(['https://b.com/*'])
  })

  it('counts a content script as reach, because it is', () => {
    /*
     * The false sentence this store printed until it was measured. A statically
     * declared content script is injected on the pages it matches whether or
     * not a host permission backs it — they are two separate grants — and only
     * one of them was being read. Video Speed Controller declares no
     * host_permissions at all and a content script on every page, and its row
     * said *no pages of its own* about a program that reads all of them.
     */
    const vsc = manifest({
      content_scripts: [{ matches: ['http://*/*', 'https://*/*', 'file:///*'], js: ['c.js'] }],
    })
    expect(reachOf(vsc)).toEqual(['file:///*', 'http://*/*', 'https://*/*'])
    expect(everywhere(vsc)).toBe(true)
  })

  it('does not repeat a pattern that is in both places', () => {
    const both = manifest({
      host_permissions: ['<all_urls>'],
      content_scripts: [{ matches: ['<all_urls>'], js: ['c.js'] }],
    })
    expect(reachOf(both)).toEqual(['<all_urls>'])
  })

  it('keeps what it may only ask for on a separate line', () => {
    /*
     * `optional_host_permissions` is not reach: the extension does not have it.
     * Folding it in would over-state, and dropping it would hide that the thing
     * expects to grow — so it is its own answer, with the sentence about this
     * browser never granting one attached to it on the row.
     */
    const asks = manifest({
      host_permissions: ['https://a.com/*'],
      optional_host_permissions: ['*://*/*'],
    })
    expect(reachOf(asks)).toEqual(['https://a.com/*'])
    expect(mayAskToReach(asks)).toEqual(['*://*/*'])
    expect(everywhere(asks)).toBe(false)
  })

  it('knows the difference between one site and every page', () => {
    // The difference a name never shows, and the whole of what somebody is
    // agreeing to when they install a program into a profile.
    expect(everywhere(manifest({ host_permissions: ['https://a.com/*'] }))).toBe(false)
    expect(everywhere(manifest({ host_permissions: ['<all_urls>'] }))).toBe(true)
    expect(everywhere(manifest({ host_permissions: ['*://*/*'] }))).toBe(true)
    expect(everywhere(manifest({ host_permissions: ['https://*/*'] }))).toBe(true)
  })
})

describe('whether Electron will load it at all', () => {
  it('refuses an MV2 event page that uses webRequest', () => {
    /*
     * Measured: Chromium answers "The 'webRequest' API cannot be used with event
     * pages." Predicted here so the store can say so on the row rather than
     * failing halfway through an install with Chromium's wording.
     */
    const result = loadability(
      manifest({
        manifest_version: 2,
        permissions: ['webRequest'],
        background: { scripts: ['bg.js'], persistent: false },
      }),
    )
    expect(result.ok).toBe(false)
    if (!result.ok) expect(result.why).toContain('event page')
  })

  it('takes an MV2 persistent background page that uses webRequest', () => {
    // ClearURLs' shape, and it was watched blocking for real.
    expect(
      loadability(
        manifest({
          manifest_version: 2,
          permissions: ['webRequest'],
          background: { scripts: ['bg.js'], persistent: true },
        }),
      ).ok,
    ).toBe(true)
  })

  it('treats an omitted `persistent` as true, which is the MV2 default', () => {
    /*
     * Getting this default backwards would refuse ClearURLs and Violentmonkey,
     * both of which omit the field — two extensions that load perfectly well.
     */
    expect(
      loadability(
        manifest({
          manifest_version: 2,
          permissions: ['webRequest'],
          background: { scripts: ['bg.js'] },
        }),
      ).ok,
    ).toBe(true)
  })

  it('takes an MV3 service worker', () => {
    expect(loadability(manifest({ background: { service_worker: 'sw.js' } })).ok).toBe(true)
  })
})

describe('static declarativeNetRequest rulesets', () => {
  it('is spotted, because nothing else on a row would show it', () => {
    /*
     * Measured dead here: `getEnabledRulesets()` answers `[]` even with
     * `"enabled": true`. The namespace *is* present, so this passes every other
     * check — the extension installs, loads, draws its button and blocks nothing.
     */
    expect(
      usesStaticRulesets(
        manifest({
          permissions: ['declarativeNetRequest'],
          declarative_net_request: { rule_resources: [{ id: 'a', enabled: true, path: 'a.json' }] },
        }),
      ),
    ).toBe(true)
  })

  it('is not claimed of an extension that declares none', () => {
    expect(usesStaticRulesets(manifest({ permissions: ['declarativeNetRequest'] }))).toBe(false)
  })
})

describe('the popup page a toolbar button would open', () => {
  it('reads MV3 action and MV2 browser_action alike', () => {
    expect(popupPage(manifest({ action: { default_popup: 'popup.html' } }))).toBe('popup.html')
    expect(
      popupPage(manifest({ manifest_version: 2, browser_action: { default_popup: 'p/index.html' } })),
    ).toBe('p/index.html')
  })

  it('strips a leading slash, which would otherwise double one in the URL', () => {
    // uBlock Origin Lite writes `/popup.html`, and the extension URL already
    // ends in a slash — `chrome-extension://id//popup.html` loads nothing.
    expect(popupPage(manifest({ action: { default_popup: '/popup.html' } }))).toBe('popup.html')
  })

  it('answers empty for an extension that draws no popup', () => {
    // The panel asks this before it draws the control, so an empty answer is
    // what stops a button appearing over a page that does not exist.
    expect(popupPage(manifest({ action: { default_title: 'X' } }))).toBe('')
    expect(popupPage(manifest())).toBe('')
  })
})

describe('the limits shown on screen', () => {
  it('names the build they were measured against', () => {
    // A limit with no version attached is a claim that ages invisibly.
    const all = EXTENSION_LIMITS.join(' ')
    expect(all).toContain(ELECTRON_MEASURED)
    expect(all).toContain(CHROMIUM_MEASURED)
  })

  it('says each of the four things somebody would otherwise discover the hard way', () => {
    const all = EXTENSION_LIMITS.join(' ').toLowerCase()
    expect(all).toContain('no chrome web store')
    expect(all).toContain('nothing updates itself')
    expect(all).toContain('chrome.storage.sync')
    expect(all).toContain('declarativenetrequest')
  })
})

/**
 * The same manifests, read against the full Chromium the server runs.
 *
 * Everything above is the Electron measurement. On the server the runtime flag
 * says the compat-provided namespaces are native and the static-ruleset gap is
 * closed — but only those: a namespace this file never measured on either
 * runtime is left reported the way it always was. Each case resets the flag in a
 * `finally`, because it is module state and the desktop default must not leak
 * into the next test.
 */
describe('read against the full Chromium on the server', () => {
  it('does not call the compat-provided namespaces missing any more', () => {
    setExtensionRuntime('chromium')
    try {
      // contextMenus, notifications and webNavigation are shimmed on the desktop
      // and native here — so not "missing" on the server.
      expect(
        missingApis(manifest({ permissions: ['contextMenus', 'notifications', 'webNavigation'] })),
      ).toEqual([])
    } finally {
      setExtensionRuntime('electron')
    }
    // The desktop default is unchanged: they are still missing there.
    expect(
      missingApis(manifest({ permissions: ['contextMenus', 'notifications', 'webNavigation'] })),
    ).toEqual(['contextMenus', 'notifications', 'webNavigation'])
  })

  it('still reports a namespace it never measured as native — measured cuts both ways', () => {
    setExtensionRuntime('chromium')
    try {
      // `bookmarks` is not in the compat-provided set, so the server relaxation
      // does not touch it: it stays reported exactly as the Electron measurement
      // had it, rather than being claimed native on a guess.
      expect(missingApis(manifest({ permissions: ['bookmarks'] }))).toEqual(['bookmarks'])
    } finally {
      setExtensionRuntime('electron')
    }
  })

  it('reports the static-ruleset gap as resolved', () => {
    const withRulesets = manifest({
      declarative_net_request: { rule_resources: [{ id: 'ads', enabled: true, path: 'a.json' }] },
    })
    setExtensionRuntime('chromium')
    try {
      // Real Chromium enables a manifest ruleset marked enabled at load, so there
      // is no dead-on-arrival blocking to warn about.
      expect(usesStaticRulesets(withRulesets)).toBe(false)
    } finally {
      setExtensionRuntime('electron')
    }
    // The desktop default still spots it.
    expect(usesStaticRulesets(withRulesets)).toBe(true)
  })
})

describe('the settings page', () => {
  /*
   * Read for the same reason the popup is, and it closed a dead end: an
   * extension can declare an options page and no popup — Search by Image and
   * Web Archives both do — and before this the store drew a door only for a
   * popup, so such a thing installed, loaded, ran, and had no interface anybody
   * could open.
   */
  it('reads options_ui.page, and the older options_page too', () => {
    expect(optionsPageOf(manifest({ options_ui: { page: 'settings.html' } }))).toBe('settings.html')
    expect(optionsPageOf(manifest({ options_page: 'old.html' }))).toBe('old.html')
  })

  it('prefers options_ui when a manifest carries both, as Chrome does', () => {
    expect(
      optionsPageOf(manifest({ options_ui: { page: 'new.html' }, options_page: 'old.html' })),
    ).toBe('new.html')
  })

  it('strips a leading slash, so the extension URL does not gain a double one', () => {
    expect(optionsPageOf(manifest({ options_page: '/deep/settings.html' }))).toBe(
      'deep/settings.html',
    )
  })

  it('answers empty when there is none, so no control is drawn', () => {
    expect(optionsPageOf(manifest())).toBe('')
    expect(optionsPageOf(manifest({ options_ui: {} }))).toBe('')
  })
})

describe('the limits, after this round of measuring', () => {
  it('names native messaging being off, because a password manager dies on it', () => {
    /*
     * Measured by connecting: `chrome.runtime.connectNative` exists and the
     * port disconnects immediately with a message about a system administrator.
     * It is the whole reason KeePassXC-Browser cannot work here, and no
     * manifest check predicts it.
     */
    expect(EXTENSION_LIMITS.join(' ')).toContain('connectNative')
  })

  it('names the empty answer a panel gets when it asks which tab is in front', () => {
    // Three of the extensions measured die on the next line.
    expect(EXTENSION_LIMITS.join(' ')).toContain('currentWindow')
  })

  it('says an extension you added yourself was measured by nobody', () => {
    expect(EXTENSION_LIMITS.join(' ')).toContain('no fingerprint is checked')
  })
})
