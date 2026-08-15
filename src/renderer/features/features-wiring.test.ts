import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { SECTIONS } from '../settings/settings-schema'
import { CONTROL_IDS, FEATURES, featureOwningControl } from './registry'

/**
 * Everything a feature store can be, while gating nothing.
 *
 * This is the bug class this repository names as its own: built, tested,
 * correct — and never wired to the thing that makes it real. A feature store is
 * unusually good at it, because every failure is silent in the same direction.
 * Forget the provider and every component falls back to the shipped defaults
 * and looks perfect. Forget one host and its control simply keeps rendering,
 * which is the state the app is in today anyway. Nothing throws, nothing looks
 * wrong, and the switch in the store does nothing for that one control.
 *
 * So each check below is a seam, and each one names the thing that would go
 * unnoticed if it came apart. Static, like `wiring.test.ts` and
 * `preload/contract.test.ts`, and for the same reason: there is no DOM here to
 * mount the tree in, and mounting `App` needs a preload bridge.
 */

const SRC = join(__dirname, '..', '..')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

const APP = read('renderer/App.tsx')

describe('the provider is mounted at the top of the window', () => {
  it('wraps the workspace', () => {
    // Without this every `useFeatures()` in the tree quietly answers with the
    // shipped defaults: the store's switches would move, write to storage, and
    // change nothing on screen for the life of the session.
    expect(APP).toMatch(/<FeaturesProvider>[\s\S]*<Workspace \/>[\s\S]*<\/FeaturesProvider>/)
  })

  it('is inside the store provider, so both exist for the same tree', () => {
    expect(APP.indexOf('<StoreProvider>')).toBeLessThan(APP.indexOf('<FeaturesProvider>'))
  })
})

describe('the window asks before it draws', () => {
  const seams: Array<{ file: string; needle: string; why: string }> = [
    {
      file: 'renderer/App.tsx',
      needle: 'panels={PANELS.filter',
      why: 'the sidebar would list a row for every view, including the ones whose feature is uninstalled',
    },
    {
      file: 'renderer/App.tsx',
      needle: "browser={features.on('browser')}",
      why: 'the browser button beside New session would open a pane the app no longer has',
    },
    {
      file: 'renderer/App.tsx',
      needle: "splitOffer={!features.on('split')}",
      why: 'the mode switch would offer Split as a mode rather than as an install, and pressing it would split with the feature uninstalled',
    },
    {
      file: 'renderer/App.tsx',
      needle: 'enabled: features.commandOn(row.id)',
      why: 'the command palette would keep offering every command, so an uninstalled feature would still be one ⌘K away',
    },
    {
      file: 'renderer/App.tsx',
      needle: 'features.featureForCommand(id)',
      why: 'a chord for an uninstalled feature would do nothing at all, which is indistinguishable from a broken shortcut',
    },
    {
      file: 'renderer/App.tsx',
      needle: 'availableFeatures(features.state)',
      why: 'nothing would offer an uninstalled feature by name, and searching the palette for it would return nothing — which is how somebody concludes the app cannot do it',
    },
    {
      file: 'renderer/components/ShortcutsSheet.tsx',
      needle: 'features.commandOn(binding.id)',
      why: 'the shortcuts sheet would print a chord for an uninstalled feature as though it worked — and it is the surface people open precisely because they are not sure what a chord does',
    },
    {
      file: 'renderer/shell/PanelView.tsx',
      needle: 'features.featureForPanel(panel)',
      why: 'the last-viewed page for an uninstalled feature would render blank instead of offering it back',
    },
    {
      file: 'renderer/dashboard/Dashboard.tsx',
      needle: 'features.widgetOn',
      why: 'a saved layout would keep drawing the Cost, GitHub or readiness tile for a feature that is gone',
    },
    {
      file: 'renderer/settings/SettingsWindow.tsx',
      needle: 'features.sectionOn',
      why: 'the rail would keep a settings section for an uninstalled feature',
    },
    {
      file: 'renderer/settings/controls.tsx',
      needle: 'features.settingOn',
      why: 'a setting owned by an uninstalled feature would go on being offered in whichever section it happens to live in',
    },
  ]

  for (const { file, needle, why } of seams) {
    it(`${file} asks about ${needle}`, () => {
      expect(read(file), why).toContain(needle)
    })
  }
})

describe('every declared control has a host that checks it', () => {
  /**
   * Where each control is drawn. A control declared in the registry and checked
   * nowhere is a switch in the store that does nothing — the exact shape of
   * failure the registry was written to prevent, one level in.
   */
  const HOSTS: Record<(typeof CONTROL_IDS)[number], string> = {
    'chat.dictate': 'renderer/components/ChatComposer.tsx',
    'chat.connectors': 'renderer/chat/attach/AttachMenu.tsx',
    'chat.usage': 'renderer/components/ChatView.tsx',
    // Split's segment is drawn by ModeSwitch but decided by the window, which
    // is the file that knows whether the feature is installed.
    'window.split': 'renderer/App.tsx',
    // Same arrangement for the globe: the rail is handed what to draw, and the
    // window is what asks. Both of these are checked through `useControlOffer`
    // now, which names the control id — the point of the check below is that
    // *something* in the host file asks, not how it phrases the question.
    'sidebar.browser': 'renderer/App.tsx',
  }

  for (const control of CONTROL_IDS) {
    it(`${control} is checked in ${HOSTS[control]}`, () => {
      const source = read(HOSTS[control])
      const owner = featureOwningControl(control)
      const asks = source.includes(`'${control}'`) || source.includes(`features.on('${owner}')`)
      expect(
        asks,
        `${HOSTS[control]} draws ${control} and never asks whether ${owner} is installed`,
      ).toBe(true)
    })
  }
})

describe('the store has a way in', () => {
  it('is a section of the settings window', () => {
    expect(SECTIONS.map((section) => section.id)).toContain('features')
    expect(read('renderer/settings/SettingsWindow.tsx')).toContain('features: FeaturesSection')
  })

  it('is where a command for a missing feature lands', () => {
    // The store being reachable only from a rail somebody has to already know
    // about is the difference between a feature store and a hidden one.
    expect(APP).toContain("openSettings('features')")
  })
})

describe('what the store promises about itself', () => {
  it('never calls any of this a plugin', () => {
    /*
     * "Plugins" promises an ecosystem — third-party authors, an API, code this
     * app did not write — and none of that exists or is planned. The word would
     * be a promise the app breaks, so it is not in the copy anybody reads.
     */
    const copy = [
      read('renderer/settings/sections/FeaturesSection.tsx'),
      read('renderer/features/FeatureOffer.tsx'),
      ...FEATURES.flatMap((entry) => [entry.name, entry.summary, entry.where]),
    ].join('\n')
    expect(/plug-?in/i.test(copy)).toBe(false)
  })

  it('says the code never left, because that is why reinstalling is instant', () => {
    const section = read('renderer/settings/sections/FeaturesSection.tsx')
    expect(section).toContain('Nothing is downloaded')
  })
})
