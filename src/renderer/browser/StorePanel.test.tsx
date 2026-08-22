import { renderToStaticMarkup } from 'react-dom/server'
import { describe, expect, it } from 'vitest'
import { StoreBody, type StoreBodyProps } from './StorePanel'
import type { StoreTool, StoreView } from './store-bridge'
import type { ExtensionsView, StoreExtension } from './extensions-bridge'

/**
 * The store's one screen, actually rendered.
 *
 * The defect this store was audited for was structural: his ask was one store
 * where *"tools will not be here only when they download"*, and what shipped
 * was a Tools dialog of six bundled recipes in which nothing downloaded, with
 * the real downloads behind a different door. So the thing worth asserting is
 * the screen itself — that the one dialog holds both halves, and that the seam
 * between *downloaded when chosen* and *built into this app* is drawn in words
 * a person reads, not implied by which dialog they happened to open.
 *
 * `StoreBody` is the whole screen as a pure function of the two loaded views —
 * the panel above it only adds the effects SSR cannot run — so rendering it
 * here is rendering what a person sees, not a helper nothing calls.
 */

function tool(over: Partial<StoreTool> = {}): StoreTool {
  return {
    id: 'page-images',
    name: 'Full-size images',
    summary: 'Every image URL a page offers.',
    homepage: 'https://example.com',
    licence: 'Public domain',
    version: '1.0.0',
    grants: ['page-read'],
    origins: ['*'],
    url: '',
    fetched: false,
    sha256: 'b'.repeat(64),
    state: 'available',
    installedVersion: '',
    installedAt: 0,
    message: '',
    reads: [],
    ...over,
  }
}

function extension(over: Partial<StoreExtension> = {}): StoreExtension {
  return {
    id: 'dark-reader',
    name: 'Dark Reader',
    summary: 'Turns every site dark.',
    homepage: 'https://github.com/darkreader/darkreader',
    licence: 'MIT',
    version: '4.9.129',
    works: 'works',
    measured: 'Watched working.',
    url: 'https://github.com/darkreader/releases/a.zip',
    sha256: 'a'.repeat(64),
    bytes: 831_273,
    state: 'available',
    installedVersion: '',
    installedAt: 0,
    enabled: false,
    reach: ['*://*/*'],
    everywhere: true,
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

const TOOLS: StoreView = {
  tools: [tool()],
  folder: '/data/browser-tools',
  orphans: [],
}

const EXT: ExtensionsView = {
  profileId: 'default',
  profileName: 'Default',
  extensions: [extension()],
  folder: '/data/browser-extensions/default',
  orphans: [],
  profiles: [{ id: 'default', name: 'Default' }],
  limits: ['There is no Chrome Web Store here.'],
}

function render(over: Partial<StoreBodyProps> = {}): string {
  const noop = (): void => {}
  return renderToStaticMarkup(
    <StoreBody
      toolsWired
      extensionsWired
      tools={TOOLS}
      toolsProblem=""
      ext={EXT}
      extProblem=""
      showing="default"
      busy=""
      said={{}}
      canOpenPopup
      onShowProfile={noop}
      onTool={noop}
      onExtension={noop}
      onEnable={noop}
      onOpenPopup={noop}
      {...over}
    />,
  )
}

describe('one screen, both halves, the seam in words', () => {
  const markup = render()

  it('holds the downloads and the built-ins together', () => {
    expect(markup).toContain('Open-source extensions')
    expect(markup).toContain('Dark Reader')
    expect(markup).toContain('Built into this app')
    expect(markup).toContain('Full-size images')
  })

  it('says the downloads ship nowhere inside the app', () => {
    expect(markup).toContain('None of these ship inside this app')
    expect(markup).toContain('checks it against the fingerprint')
  })

  it('says the built-ins are not downloads, before their first row', () => {
    expect(markup).toContain('These are not downloads')
    expect(markup).toContain('fetches nothing')
  })

  it('carries the store-wide limits, said once at the top', () => {
    expect(markup).toContain('There is no Chrome Web Store here.')
  })

  it('names both folders, because Remove claims files are deleted', () => {
    expect(markup).toContain('/data/browser-tools')
    expect(markup).toContain('/data/browser-extensions/default')
  })
})

describe('the honesty that must not regress', () => {
  it('a measured-failing extension keeps its section and gets no button', () => {
    const markup = render({
      ext: {
        ...EXT,
        extensions: [
          extension({
            id: 'broken',
            name: 'Broken Thing',
            works: 'no',
            state: 'unavailable',
            url: '',
            sha256: '',
            bytes: 0,
            measured: 'It loads, and then blocks nothing.',
          }),
        ],
      },
    })
    expect(markup).toContain('Cannot work in this browser')
    expect(markup).toContain('It loads, and then blocks nothing.')
    // The row is drawn inside the unavailable section with no control on it —
    // ExtensionRow.test.tsx pins the row itself; this pins that the unified
    // screen still gives such a row a home instead of dropping it.
    expect(markup).toContain('installing one would only put a program on your disk that does nothing')
  })

  it('a download row shows URL and fingerprint on this screen, not in a detail view', () => {
    const markup = render()
    expect(markup).toContain('https://github.com/darkreader/releases/a.zip')
    expect(markup).toContain('a'.repeat(64))
  })

  it('an installed extension is under an Installed heading that names the profile', () => {
    const markup = render({
      ext: { ...EXT, extensions: [extension({ state: 'installed', enabled: true })] },
    })
    expect(markup).toContain('Installed in Default')
  })
})

describe('halves that are absent or unreadable', () => {
  it('draws nothing of a half the preload does not carry', () => {
    // Absent rather than disabled — a section whose buttons could never work
    // is the control-that-does-nothing, sectioned.
    const markup = render({ extensionsWired: false })
    expect(markup).not.toContain('Open-source extensions')
    expect(markup).toContain('Built into this app')
  })

  it('prints why a half could not be read where its rows would be', () => {
    // A store that opens blank reads as a store with nothing in it, which is a
    // more misleading thing than a store that could not be read.
    const markup = render({ extProblem: 'The list could not be read.' })
    expect(markup).toContain('The list could not be read.')
    expect(markup).not.toContain('Open-source extensions')
    expect(markup).toContain('Built into this app')
  })
})

describe('what this build can no longer name', () => {
  it('offers Remove for orphans of either kind', () => {
    const markup = render({
      tools: { ...TOOLS, orphans: ['old-tool'] },
      ext: { ...EXT, orphans: ['old-extension'] },
    })
    expect(markup).toContain('No longer offered')
    expect(markup).toContain('old-tool')
    expect(markup).toContain('old-extension')
  })
})

describe('the profile is a fact of the download half', () => {
  it('offers the picker only when there is a choice to make', () => {
    expect(render()).not.toContain('bw-ext-profile')
    const two = render({
      ext: {
        ...EXT,
        profiles: [
          { id: 'default', name: 'Default' },
          { id: '11111111-2222-3333-4444-555555555555', name: 'Work' },
        ],
      },
    })
    expect(two).toContain('bw-ext-profile')
    expect(two).toContain('Work')
  })
})
