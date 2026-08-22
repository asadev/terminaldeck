import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { ExtensionRow } from './ExtensionRow'
import type { StoreExtension } from './extensions-bridge'

/**
 * An extension row, actually rendered.
 *
 * The row is where this feature can most easily start lying, so it is the thing
 * that gets rendered and read. Three ways it could:
 *
 *  - **A button over something that cannot work.** A row this app measured
 *    failing has no download pinned, so an Install could only ever refuse.
 *  - **A switch over something that is not running.** "On" is the live session's
 *    answer, not the disk's, and a checked box above a program that threw at
 *    load is exactly the control this app's brief forbids.
 *  - **A reach nobody was shown before pressing Install.** What an extension may
 *    read is the whole of what somebody is agreeing to, so it cannot arrive after
 *    the agreement. It is safe for the row to state the catalogue's answer only
 *    because `browser-extensions.ts` refuses any release whose manifest reaches
 *    wider than the row said — so the two are the same thing or neither happens.
 *
 * There is no DOM in this project's test setup, so this renders through
 * `react-dom/server` the way `ToolRow.test.tsx` does. The panel around this
 * row loads through an effect, which SSR never runs, so the row is where
 * everything worth asserting lives.
 */

function row(over: Partial<StoreExtension> = {}): StoreExtension {
  return {
    id: 'dark-reader',
    name: 'Dark Reader',
    summary: 'Turns every site dark.',
    homepage: 'https://github.com/darkreader/darkreader',
    licence: 'MIT',
    version: '4.9.129',
    category: 'appearance',
    tags: [],
    needs: [],
    works: 'works',
    measured: 'Watched working: a white page came back with background rgb(24, 26, 27).',
    noRelease: '',
    logo: 'dark-reader',
    url: 'https://example.com/a.zip',
    sha256: 'a'.repeat(64),
    bytes: 100,
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

function render(over: Partial<StoreExtension> = {}, props: Partial<Parameters<typeof ExtensionRow>[0]> = {}) {
  return renderToStaticMarkup(
    <ExtensionRow
      extension={row(over)}
      busy={false}
      said=""
      canOpenPopup
      canOpenOptions
      onAct={() => {}}
      onEnable={() => {}}
      onOpenPopup={() => {}}
      onOpenOptions={() => {}}
      {...props}
    />,
  )
}

describe('every row', () => {
  it('shows what this app measured, whatever the verdict', () => {
    // A verdict with no observation behind it is an opinion.
    expect(render()).toContain('rgb(24, 26, 27)')
  })

  it('names the licence and where it comes from, so the row is not this app’s word for it', () => {
    const html = render()
    expect(html).toContain('MIT')
    expect(html).toContain('github.com/darkreader/darkreader')
  })
})

describe('what will be fetched, and what was', () => {
  it('says the exact URL, the exact byte count and the fingerprint before Install is pressed', () => {
    // This is the disclosure. A store that fetches programs and will not say
    // from where, or says "verified" without saying against what, is asking
    // for the trust it exists to replace.
    const html = render()
    expect(html).toContain('https://example.com/a.zip')
    expect(html).toContain('100 bytes, exactly')
    expect(html).toContain('a'.repeat(64))
    expect(html).toContain('must match this, or nothing is saved')
  })

  it('answers "where did this program come from" on an installed row, past tense', () => {
    const html = render({ state: 'installed', enabled: true })
    expect(html).toContain('https://example.com/a.zip')
    expect(html).toContain('matched this before it was unpacked')
  })

  it('offers no provenance on a row with no download pinned', () => {
    // A "cannot work here" row pins nothing, so a URL under it would be
    // provenance for a fetch that can never happen.
    const html = render({ works: 'no', state: 'unavailable', url: '', sha256: '', bytes: 0 })
    expect(html).not.toContain('Download')
    expect(html).not.toContain('sha256')
  })
})

describe('a row this app measured failing', () => {
  it('offers no Install — not even a disabled one — and links out instead', () => {
    /*
     * Not a disabled Install: a disabled Install with a tooltip is still a store
     * offering something. There is no download pinned to this row, so that
     * button could only ever refuse.
     *
     * What the row does carry now is one control that does exactly what it says.
     * *"or maybe only link of the application from github or wherever they can
     * go and download it, it will just redirect them"* — so the dead end became
     * a way onward, and it is worded **Open project** rather than Get it,
     * because you cannot get this one here and the sentence underneath says why.
     */
    const html = render({
      id: 'ublock-origin',
      name: 'uBlock Origin',
      works: 'no',
      state: 'unavailable',
      url: '',
      sha256: '',
      homepage: 'https://github.com/gorhill/uBlock',
      measured: 'It loads, and then blocks nothing.',
    })
    expect(html).not.toContain('Install')
    expect(html).not.toContain('Download')
    expect(html).toContain('Open project')
    expect(html).toContain('https://github.com/gorhill/uBlock')
    expect(html).toContain('blocks nothing')
  })

  it('has no link-out when the row carries no project address', () => {
    // A button whose destination is an empty string is the dead control this
    // whole store is written against, so it is not drawn at all.
    const html = render({
      works: 'no',
      state: 'unavailable',
      url: '',
      sha256: '',
      homepage: '',
    })
    expect(html).not.toContain('storefront-getit')
  })

  it('is still on screen, because "where is uBlock Origin" has a true answer', () => {
    const html = render({ id: 'ublock-origin', name: 'uBlock Origin', works: 'no', state: 'unavailable' })
    expect(html).toContain('uBlock Origin')
  })
})

describe('a row that can be installed', () => {
  it('offers Install and says so on the button', () => {
    expect(render()).toContain('Install')
  })

  it('states what it reaches while Install is still the button on it', () => {
    /*
     * Reach is the single fact somebody is agreeing to when they press Install,
     * so it cannot wait until afterwards. It is safe to print the catalogue's
     * answer because `browser-extensions.ts` refuses any release whose manifest
     * reaches wider than this line — the row and the program agree or neither
     * happens.
     */
    const html = render({ reach: ['<all_urls>'], everywhere: true })
    expect(html).toContain('every page you open in this profile')
    expect(html).toContain('Install')
  })
})

describe('a row that is installed', () => {
  it('says what it actually reaches, in words rather than in patterns', () => {
    const html = render({ state: 'installed', enabled: true, everywhere: true, reach: ['<all_urls>'] })
    expect(html).toContain('every page you open in this profile')
  })

  it('draws the switch, and Remove beside it', () => {
    // Off and gone are different things and a person means one of them.
    const html = render({ state: 'installed', enabled: true })
    expect(html).toContain('checkbox')
    expect(html).toContain('Remove')
  })

  it('shows the switch unchecked when the browser did not load it', () => {
    /*
     * The one that matters most. The store writes `enabled: true` and the
     * browser can still refuse; the main process folds the live answer in and
     * the row draws that, with the reason.
     */
    const html = render({
      state: 'installed',
      enabled: false,
      message: 'It is switched on but the browser did not load it: it threw.',
    })
    expect(html).not.toContain('checked=""')
    expect(html).toContain('did not load it')
  })

  it('names the chrome.* it asks for that is not here', () => {
    const html = render({ state: 'installed', enabled: true, missing: ['contextMenus', 'webNavigation'] })
    expect(html).toContain('chrome.contextMenus')
    expect(html).toContain('chrome.webNavigation')
  })

  it('says outright when its rules are static rulesets that are not in force', () => {
    // Nothing else on the row would show it: the extension installs, loads,
    // draws its button and blocks nothing.
    const html = render({ state: 'installed', enabled: true, staticRulesets: true })
    expect(html).toContain('not in force')
  })
})

describe('the panel button', () => {
  it('is drawn only for an extension that has one and is running', () => {
    // A button opening the popup of a program that is not loaded has nothing to
    // show, and one for an extension with no `default_popup` has no page at all.
    expect(render({ state: 'installed', enabled: true, popup: 'popup.html' })).toContain('Open panel')
    expect(render({ state: 'installed', enabled: false, popup: 'popup.html' })).not.toContain('Open panel')
    expect(render({ state: 'installed', enabled: true, popup: '' })).not.toContain('Open panel')
  })

  it('is not drawn when the preload cannot open one', () => {
    expect(
      render({ state: 'installed', enabled: true, popup: 'popup.html' }, { canOpenPopup: false }),
    ).not.toContain('Open panel')
  })
})

describe('a damaged install', () => {
  it('says what is wrong and offers Remove', () => {
    const html = render({
      state: 'damaged',
      message: 'it was installed from a different release than this version of the app offers',
    })
    expect(html).toContain('different release')
    expect(html).toContain('Remove')
  })
})

describe('the compatibility layer, on the row', () => {
  it('names what this app filled in and what is still not there', () => {
    /*
     * The layer rewrites files inside a program somebody just agreed to install.
     * An app that does that and does not say so is keeping a secret it has no
     * reason to keep — and one that says "works" without naming what is inert is
     * the row version of a button that does nothing.
     */
    const html = render(
      row({
        state: 'installed',
        enabled: true,
        provides: ['contextMenus', 'webNavigation'],
        inert: ['its right-click menu entries are not shown'],
      }),
    )
    expect(html).toContain('Filled in by this app')
    expect(html).toContain('chrome.contextMenus')
    expect(html).toContain('Still not there')
    expect(html).toContain('right-click menu entries are not shown')
  })

  it('stops warning about static rulesets once it has switched them on', () => {
    const warned = render(row({ state: 'installed', staticRulesets: true, rulesetsSwitchedOn: 0 }))
    expect(warned).toContain('are not in force')
    const handled = render(row({ state: 'installed', staticRulesets: true, rulesetsSwitchedOn: 6 }))
    expect(handled).not.toContain('are not in force')
    expect(handled).toContain('switched its 6 on')
  })

  it('says nothing about a layer for a row nobody has installed', () => {
    // Before an install there is no manifest, so there is nothing measured to
    // say. A row that guessed would be guessing about somebody else's release.
    const html = render(row({ state: 'available' }))
    expect(html).not.toContain('Filled in by this app')
  })
})
