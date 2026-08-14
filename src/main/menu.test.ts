import type { MenuItemConstructorOptions } from 'electron'
import { describe, expect, it, vi } from 'vitest'
import { BRAND } from '../shared/brand'

/**
 * The menu is where four commands live that exist nowhere else, and it used to
 * throw them away on Windows.
 *
 * `template.shift()` dropped the macOS app submenu on any other platform, and
 * that submenu was the only home of About, Settings…, Keyboard Shortcuts and
 * Quit. On Windows there was therefore no way to reach Settings from the menu
 * bar, no Exit item, and — because Electron binds accelerators through the menu
 * — ⌃, and ⌃/ were never registered, so the shortcuts sheet printed two chords
 * that did nothing. Every one of those facts is invisible from macOS.
 *
 * So the assertions below are made against `menuTemplate(platform, send)` with
 * the platform pinned, both of them, in one run. That is only possible because
 * the template takes the platform as a value rather than reading
 * `process.platform`; `platform/host.ts` is the long-form argument for it.
 */

vi.mock('electron', () => ({
  app: { getVersion: () => '9.9.9', setAboutPanelOptions: () => {} },
  Menu: { buildFromTemplate: (template: unknown) => template, setApplicationMenu: () => {} },
  shell: { openExternal: async () => {} },
}))

const { menuTemplate } = await import('./menu')

/**
 * A `send` whose handlers carry the command they would send.
 *
 * The real one closes over a BrowserWindow and its command is unrecoverable
 * from the outside. Tagging it is what lets a test ask "is there a menu item
 * that reaches app.preferences" rather than matching on a label, which is
 * cosmetic and would pass for an item wired to nothing.
 */
type Tagged = (() => void) & { command: string }
const send = (command: string): Tagged => Object.assign(() => {}, { command })

const commandOf = (item: MenuItemConstructorOptions): string | undefined =>
  (item.click as Partial<Tagged> | undefined)?.command

interface Found {
  /** Top-level menu the item was found under, e.g. `File`. */
  menu: string
  item: MenuItemConstructorOptions
}

/** Every item in the template, each remembering which top-level menu it is in. */
function allItems(template: MenuItemConstructorOptions[]): Found[] {
  const out: Found[] = []
  const descend = (menu: string, items: MenuItemConstructorOptions[]): void => {
    for (const item of items) {
      out.push({ menu, item })
      if (Array.isArray(item.submenu)) descend(menu, item.submenu)
    }
  }
  for (const top of template) {
    const name = top.label ?? String(top.role ?? '')
    descend(name, Array.isArray(top.submenu) ? top.submenu : [])
  }
  return out
}

const PLATFORMS: NodeJS.Platform[] = ['darwin', 'win32']

/**
 * The four the app menu used to own, and the accelerator each must keep.
 *
 * Quit is matched by role rather than by a command because it is a role — the
 * role is what carries ⌘Q and the correct teardown — and it has no menu
 * accelerator of its own off macOS, which is the Windows convention.
 */
const REQUIRED: { name: string; command: string; accelerator?: string }[] = [
  { name: 'Settings', command: 'app.preferences', accelerator: 'CmdOrCtrl+,' },
  { name: 'Keyboard Shortcuts', command: 'app.shortcuts', accelerator: 'CmdOrCtrl+/' },
  { name: 'About', command: 'app.about' },
]

describe('every command the app menu used to own survives on both platforms', () => {
  for (const platform of PLATFORMS) {
    const items = allItems(menuTemplate(platform, send))

    for (const required of REQUIRED) {
      it(`${platform}: ${required.name} is reachable from a menu`, () => {
        const found = items.filter(({ item }) => commandOf(item) === required.command)
        expect(
          found.length,
          `Nothing in the ${platform} menu bar sends ${required.command}. On the platform where ` +
            'it is missing there is no other way to open it.',
        ).toBeGreaterThan(0)
        // One door per room: the same command in two menus is two things to
        // keep in step and a user wondering whether they differ.
        expect(found.length, `${required.command} appears in ${found.map((f) => f.menu).join(', ')}`).toBe(1)
      })

      if (required.accelerator) {
        it(`${platform}: ${required.name} registers ${required.accelerator}`, () => {
          const found = items.find(({ item }) => commandOf(item) === required.command)
          // Electron binds accelerators through the menu, so an item that is
          // not in the template is a chord that is not bound — which is how the
          // shortcuts sheet came to print two keys that did nothing on Windows.
          expect(found?.item.accelerator).toBe(required.accelerator)
        })
      }
    }

    it(`${platform}: there is a way to quit`, () => {
      const quit = items.filter(({ item }) => item.role === 'quit')
      expect(quit.length, `no Quit/Exit item anywhere in the ${platform} menu bar`).toBe(1)
    })
  }
})

describe('each platform gets the layout its users expect', () => {
  it('macOS keeps the Apple-standard app menu, unchanged', () => {
    const template = menuTemplate('darwin', send)
    // First menu, named for the app, and holding the four items macOS puts
    // there. Anything else is a stray menu titled with the product name.
    expect(template[0].label).toBe(BRAND.name)

    const items = allItems(template)
    for (const command of ['app.about', 'app.preferences', 'app.shortcuts']) {
      expect(items.find(({ item }) => commandOf(item) === command)?.menu).toBe(BRAND.name)
    }
    expect(items.find(({ item }) => item.role === 'quit')?.menu).toBe(BRAND.name)
    // The services/hide block is the rest of the Apple standard; losing it
    // would be a regression this test would otherwise not notice.
    for (const role of ['services', 'hide', 'hideOthers', 'unhide']) {
      expect(items.some(({ item }) => item.role === role), role).toBe(true)
    }
  })

  it('Windows has no app menu, and puts the items where Windows puts them', () => {
    const template = menuTemplate('win32', send)
    expect(template.map((m) => m.label ?? m.role)).toEqual([
      'File',
      'editMenu',
      'View',
      'windowMenu',
      'help',
    ])

    const items = allItems(template)
    expect(items.find(({ item }) => commandOf(item) === 'app.preferences')?.menu).toBe('File')
    expect(items.find(({ item }) => commandOf(item) === 'app.shortcuts')?.menu).toBe('File')
    expect(items.find(({ item }) => commandOf(item) === 'app.about')?.menu).toBe('help')

    const quit = items.find(({ item }) => item.role === 'quit')
    expect(quit?.menu).toBe('File')
    // Windows says Exit, not Quit.
    expect(quit?.item.label).toBe('Exit')

    // And at the bottom of File, which is the only place anyone looks for it.
    const file = template[0].submenu as MenuItemConstructorOptions[]
    expect(file[file.length - 1].role).toBe('quit')
  })

  it('Linux follows the Windows layout rather than losing the items too', () => {
    // Not a supported target today, but `template.shift()` was written as
    // "everything that is not macOS" and this is the other half of that set.
    const items = allItems(menuTemplate('linux', send))
    for (const command of ['app.about', 'app.preferences', 'app.shortcuts']) {
      expect(items.some(({ item }) => commandOf(item) === command), command).toBe(true)
    }
    expect(items.some(({ item }) => item.role === 'quit')).toBe(true)
  })
})

describe('the two layouts offer the same commands', () => {
  /**
   * The original bug was a difference between platforms that nobody could see
   * from either one. Comparing the sets directly is the assertion that would
   * have caught it on the day it was written, whatever the cause.
   */
  it('sends exactly the same set of renderer commands on macOS and Windows', () => {
    const commands = (platform: NodeJS.Platform): string[] =>
      allItems(menuTemplate(platform, send))
        .map(({ item }) => commandOf(item))
        .filter((c): c is string => c !== undefined)
        .sort()

    expect(commands('win32')).toEqual(commands('darwin'))
    expect(commands('darwin').length).toBeGreaterThan(10)
  })
})
