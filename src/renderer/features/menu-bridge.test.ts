import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { featureOwningCommand } from './registry'
import { everythingOff, everythingOn, offCommands, withStatus } from './state'

/**
 * The one surface of this app that is drawn by the other process.
 *
 * Everything optional in the window asks the registry before it renders — the
 * sidebar, the palette, the mode switch, the settings rail. The **application
 * menu** could not: it is built in the main process, which has no registry, no
 * `localStorage` and no way to acquire either. So it went on offering Browser,
 * Split the Window and Swarm View with all three features uninstalled, which is
 * the dead control the design brief's first rule is about — and it is invisible
 * to every test in `renderer/`, because nothing in `renderer/` draws it.
 *
 * The fix is a list of command ids pushed over the preload bridge, and it has
 * three ends that can each come apart in silence:
 *
 *   1. the menu can add an item for a feature and forget to gate it;
 *   2. the provider can stop pushing, and nothing on screen would change;
 *   3. the two sides can stop agreeing about the channel or the method name.
 *
 * Each one is checked below by reading the source, the way
 * `features-wiring.test.ts` and `preload/contract.test.ts` do — there is no DOM
 * here to mount a window in, and there is no Electron here to open a menu with.
 */

const SRC = join(__dirname, '..', '..')
const read = (rel: string): string => readFileSync(join(SRC, rel), 'utf8')

const MENU = read('main/menu.ts')
const PRELOAD = read('preload/index.ts')
const PROVIDER = read('renderer/features/FeaturesProvider.tsx')

/** Every command id the application menu sends, in the order it sends them. */
function menuCommands(): string[] {
  // The same pattern `reachable.test.ts` uses to ask what the menu dispatches.
  const sent = [...MENU.matchAll(/send\('([a-z][\w.]*)'\)/g)].map((match) => match[1])
  expect(sent.length, 'no menu commands found — has menu.ts changed shape?').toBeGreaterThan(10)
  return sent
}

describe('the menu gates every command a feature owns', () => {
  it('puts each of them behind whenInstalled', () => {
    const ungated = menuCommands().filter(
      (command) =>
        featureOwningCommand(command) !== null && !MENU.includes(`whenInstalled('${command}'`),
    )
    expect(
      ungated,
      'the application menu offers these with the feature that owns them uninstalled. ' +
        'The item stays in View doing something the person removed, which is the ' +
        'first rule in DESIGN-BRIEF.md: a control that looks live is a promise.',
    ).toEqual([])
  })

  it('gates nothing else', () => {
    // A core command behind the gate would be worse than an ungated feature
    // one: `menu.ts` hides whatever it is sent, so Settings or New Session could
    // be taken out of the menu bar by a list this side had no business putting
    // them in.
    const gated = [...MENU.matchAll(/whenInstalled\('([a-z][\w.]*)'/g)].map((match) => match[1])
    expect(gated.length, 'nothing is gated at all — has menu.ts changed shape?').toBeGreaterThan(0)
    expect(gated.filter((command) => featureOwningCommand(command) === null)).toEqual([])
  })
})

describe('the window tells the menu what it can no longer offer', () => {
  it('names every gated menu command when nothing is installed', () => {
    const off = new Set(offCommands(everythingOff()))
    const missed = menuCommands().filter(
      (command) => featureOwningCommand(command) !== null && !off.has(command),
    )
    expect(
      missed,
      'the menu gates these and the list the window sends never mentions them, so the ' +
        'item would stay in the menu for a feature that is gone',
    ).toEqual([])
  })

  it('names nothing at all when everything is installed', () => {
    expect(offCommands(everythingOn())).toEqual([])
  })

  it('counts switched off the same as uninstalled', () => {
    // `isOn` is the question every drawn surface asks. A feature switched off
    // still owns its data, but its menu item would do something the person has
    // just turned off — which is the same dead control by a different route.
    expect(offCommands(withStatus(everythingOn(), 'split', 'off'))).toContain('pane.split')
  })

  it('is pushed from the provider whenever the state changes', () => {
    // Without this the whole bridge is inert: the list would be computed
    // correctly, sent nowhere, and every gate above would pass forever.
    expect(PROVIDER).toContain('offCommands(state)')
    expect(PROVIDER).toContain('setHiddenMenuCommands(hiddenCommands)')
  })
})

describe('both ends name the same channel', () => {
  it('the preload sends on the channel the menu listens to', () => {
    const declared = /export const MENU_HIDDEN_COMMANDS = '([^']+)'/.exec(MENU)
    expect(declared, 'menu.ts no longer declares the channel').not.toBeNull()
    expect(MENU).toContain('ipcMain.on(MENU_HIDDEN_COMMANDS')
    expect(PRELOAD).toContain(`ipcRenderer.send('${declared?.[1] ?? ''}'`)
  })

  it('the preload exposes the method the provider calls', () => {
    expect(PRELOAD).toContain('setHiddenMenuCommands: (commands: string[]): void =>')
  })
})
