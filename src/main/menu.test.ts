import type { MenuItemConstructorOptions } from 'electron'
import { beforeEach, describe, expect, it, vi } from 'vitest'
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

/**
 * The mock doubles as a recorder for the second half of this file.
 *
 * `buildMenu` is the part that can only fail at runtime: it installs the menu
 * once and then has to install it again every time the window's feature state
 * changes. Capturing what `setApplicationMenu` was handed, and holding the
 * listener `ipcMain.on` was given, is what lets that be exercised here rather
 * than discovered by uninstalling something in the running app.
 */
const installed: MenuItemConstructorOptions[][] = []
const listeners = new Map<string, (event: unknown, ...args: unknown[]) => void>()

vi.mock('electron', () => ({
  app: { getVersion: () => '9.9.9', setAboutPanelOptions: () => {} },
  Menu: {
    buildFromTemplate: (template: unknown) => template,
    setApplicationMenu: (template: unknown) => {
      if (Array.isArray(template)) installed.push(template)
    },
  },
  ipcMain: {
    on: (channel: string, listener: (event: unknown, ...args: unknown[]) => void) => {
      listeners.set(channel, listener)
    },
    removeAllListeners: (channel: string) => {
      listeners.delete(channel)
    },
  },
  shell: { openExternal: async () => {} },
}))

const { buildMenu, MENU_HIDDEN_COMMANDS, menuTemplate } = await import('./menu')

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

/* ============================================================== features -- */

/**
 * The three items the feature store can take away.
 *
 * Written out here rather than imported from the registry on purpose: this file
 * is compiled by the *main* project, which does not include `src/renderer`, and
 * a test that reached across would either fail to compile or drag the whole
 * renderer into the main tsconfig. The link between the two lists is guarded
 * from the other side, in `renderer/features/menu-bridge.test.ts`, which reads
 * this file as text and fails if the menu sends a command the registry gates
 * and does not put it behind `whenInstalled`.
 */
const GATED = ['view.browser', 'pane.split', 'view.swarm']

/** Every item that is not a separator, per submenu, for the tidiness check. */
function submenus(template: MenuItemConstructorOptions[]): MenuItemConstructorOptions[][] {
  const out: MenuItemConstructorOptions[][] = []
  const descend = (items: MenuItemConstructorOptions[]): void => {
    out.push(items)
    for (const item of items) if (Array.isArray(item.submenu)) descend(item.submenu)
  }
  for (const top of template) if (Array.isArray(top.submenu)) descend(top.submenu)
  return out
}

describe('a feature that is not installed has no menu item', () => {
  for (const platform of PLATFORMS) {
    it(`${platform}: hides exactly the commands it is told to`, () => {
      const items = allItems(menuTemplate(platform, send, new Set(GATED)))
      const commands = items.map(({ item }) => commandOf(item))
      for (const gated of GATED) {
        expect(
          commands.includes(gated),
          `${gated} is still in the ${platform} menu with its feature uninstalled — ` +
            'a menu item that looks like the feature is still there',
        ).toBe(false)
      }
      // And nothing else went with them. The window is unusable without these.
      for (const core of ['session.new', 'app.preferences', 'view.terminal', 'view.sidebar']) {
        expect(commands.includes(core), core).toBe(true)
      }
    })

    it(`${platform}: takes the accelerator with the item`, () => {
      // Electron binds accelerators through the menu. An item that is gone but
      // whose chord is still registered would fire a command for a feature that
      // is not installed — and the window's own key handler, which routes that
      // command into the store and explains itself, would never see the key.
      const items = allItems(menuTemplate(platform, send, new Set(GATED)))
      const chords = items.map(({ item }) => item.accelerator)
      expect(chords).not.toContain('CmdOrCtrl+D')
      expect(chords).not.toContain('CmdOrCtrl+\\')
      // The sidebar shares that group and is not optional.
      expect(chords).toContain('CmdOrCtrl+B')
    })

    it(`${platform}: offers everything when it has been told nothing`, () => {
      // The launch state. The menu bar exists before the window has loaded, and
      // an app that came up with half a View menu while it waited for the first
      // frame would be a worse failure than the one being fixed.
      const commands = allItems(menuTemplate(platform, send)).map(({ item }) => commandOf(item))
      for (const gated of GATED) expect(commands.includes(gated), gated).toBe(true)
    })

    /*
     * Eight combinations, because "no group can be emptied" is a property of
     * the layout rather than of any one uninstall. A submenu that opens on a
     * hairline rule with nothing above it, or that ends in one, is the visual
     * equivalent of the empty section the design brief forbids.
     */
    for (let mask = 0; mask < 1 << GATED.length; mask++) {
      const hidden = GATED.filter((_, index) => (mask & (1 << index)) !== 0)
      it(`${platform}: strands no separator with ${hidden.length === 0 ? 'nothing' : hidden.join(', ')} hidden`, () => {
        for (const items of submenus(menuTemplate(platform, send, new Set(hidden)))) {
          const separators = items.map((item) => item.type === 'separator')
          expect(separators[0], 'a submenu opens with a separator').not.toBe(true)
          expect(separators[separators.length - 1], 'a submenu ends with a separator').not.toBe(true)
          for (let i = 1; i < separators.length; i++) {
            expect(
              separators[i] && separators[i - 1],
              `two separators in a row in ${items.map((item) => item.label ?? item.role ?? '—').join(' / ')}`,
            ).toBe(false)
          }
        }
      })
    }
  }
})

describe('the menu is rebuilt when a feature is installed or uninstalled', () => {
  /**
   * Labels of the menu that was installed most recently.
   *
   * Labels here, commands everywhere else in this file, and the difference is
   * `buildMenu`: it builds its own `send`, which closes over a BrowserWindow and
   * is deliberately opaque from the outside. What the tests above pin is that
   * the item labelled "Split the Window" is the one that sends `pane.split`;
   * what these pin is whether that item is in the menu that was installed. Two
   * halves of one fact, each checked where it can be seen.
   */
  function latest(): string[] {
    const template = installed[installed.length - 1]
    expect(template, 'no menu was ever installed').toBeDefined()
    return allItems(template)
      .map(({ item }) => item.label)
      .filter((label): label is string => label !== undefined)
  }

  function push(commands: unknown): void {
    const listener = listeners.get(MENU_HIDDEN_COMMANDS)
    expect(listener, `nothing is listening on ${MENU_HIDDEN_COMMANDS}`).toBeDefined()
    listener?.({}, commands)
  }

  beforeEach(() => {
    installed.length = 0
    listeners.clear()
    buildMenu(() => null, 'darwin')
  })

  /** What each gated command is labelled, for the menu `buildMenu` installed. */
  const LABELS: Record<string, string> = {
    'view.browser': 'Browser',
    'pane.split': 'Split the Window',
    'view.swarm': 'Swarm View',
  }

  it('installs a full menu at launch', () => {
    expect(installed.length).toBe(1)
    for (const gated of GATED) expect(latest(), gated).toContain(LABELS[gated])
  })

  it('rebuilds without the items when the window says a feature went away', () => {
    push(['pane.split', 'view.swarm'])
    expect(installed.length).toBe(2)
    expect(latest()).not.toContain('Split the Window')
    expect(latest()).not.toContain('Swarm View')
    // Not in the list, so it stays: the list is the whole truth every time, and
    // this is what proves the menu is filtered by it rather than by a rule of
    // its own about which items are optional.
    expect(latest()).toContain('Browser')
    // The group the two came out of still has its core item.
    expect(latest()).toContain('Toggle Sidebar')
  })

  it('puts them back when the feature is installed again', () => {
    push(['pane.split'])
    push([])
    expect(installed.length).toBe(3)
    for (const gated of GATED) expect(latest(), gated).toContain(LABELS[gated])
  })

  it('does not touch the menu bar when nothing has changed', () => {
    // `setApplicationMenu` replaces the live menu bar, which closes any menu
    // that happens to be open under the pointer. The renderer re-renders for
    // reasons that have nothing to do with features.
    push(['pane.split'])
    push(['pane.split'])
    expect(installed.length).toBe(2)
  })

  it('hides nothing when the message is not a list of command ids', () => {
    // It arrives from a renderer, so it is parsed rather than trusted. The worst
    // a malformed one may do is leave the menu the app has always had.
    for (const junk of [undefined, null, 'pane.split', 42, { 0: 'pane.split' }, [7, '', null]]) {
      installed.length = 0
      push(junk)
      expect(installed.length, JSON.stringify(junk) ?? 'undefined').toBe(0)
    }
  })

  it('leaves one listener behind however many times it runs', () => {
    // macOS re-creates the window on `activate`, and two listeners would each
    // close over a different `getWindow` — so the menu would dispatch into
    // whichever window registered first, which is the one that was just closed.
    buildMenu(() => null, 'darwin')
    buildMenu(() => null, 'darwin')
    expect(listeners.size).toBe(1)
  })
})
