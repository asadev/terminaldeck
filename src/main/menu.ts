import {
  app,
  ipcMain,
  Menu,
  shell,
  type BrowserWindow,
  type IpcMainEvent,
  type MenuItemConstructorOptions,
} from 'electron'
import { BRAND } from '../shared/brand'
import { currentPlatform, type Platform } from './platform/host'

/**
 * The application menu.
 *
 * Electron's default menu has no Settings item, so the only way into
 * preferences was ⌘, — undiscoverable unless someone tells you. On macOS the
 * app menu is the first place anyone looks, so every dialog in the app is
 * reachable from here as well as from a shortcut.
 *
 * Items that live in the renderer are sent as a command string; App.tsx maps
 * them to the same handlers the keyboard shortcuts use, so there is one
 * behaviour per command rather than two that can drift.
 *
 * ## Why the template is built for a platform rather than around one
 *
 * The whole app menu — About, Settings…, Keyboard Shortcuts, Quit — is a macOS
 * convention, and this file used to drop it with `template.shift()` on anything
 * else. Nothing put those four items back. A Windows user therefore had no
 * Settings item anywhere in the menu bar, no Quit and no About, and because
 * Electron registers accelerators through the menu, ⌃, and ⌃/ were not bound
 * either: the shortcuts sheet printed two chords that did nothing. That is the
 * exact shape of failure `src/reachable.test.ts` exists for — a feature with no
 * way in — and it only ever appeared on the platform nobody here develops on.
 *
 * So the platform is a value that is passed in (`platform/host.ts` explains at
 * length why this codebase does that everywhere) and the two layouts are
 * written out side by side, which is what lets `menu.test.ts` pin both in one
 * run on one machine. Windows and Linux get the same four items where their own
 * conventions put them: Settings and Keyboard Shortcuts at the foot of File,
 * Exit below them, About at the bottom of Help.
 *
 * ## Why the menu has to be told about the feature store
 *
 * Three of the items below belong to features somebody can uninstall: Browser,
 * Split the Window and Swarm View. The window already stops drawing their
 * buttons, their panels and their palette rows — the registry is asked before
 * anything optional is rendered — and the menu bar was the one surface that
 * never asked. Uninstall the split view and "Split the Window ⌘D" stayed in
 * View, which is precisely the dead control the design brief's first rule is
 * about: it looks like the feature is still there, and choosing it lands you in
 * a settings page offering to install the thing you thought you were using.
 *
 * ## Why Windows still builds a whole menu it never shows
 *
 * On Windows the menu bar is drawn *inside the window*, as a strip under the
 * title bar. With the title bar now hidden and the window buttons drawn into
 * our own toolbar (see `title-bar.ts`), that strip was the last of the three
 * stacked bars the top of this window used to be, and it is not what a modern
 * Windows app looks like — none of them draw one.
 *
 * The tempting fix is `Menu.setApplicationMenu(null)`. It is the wrong one, and
 * catastrophically so in this app: **Electron registers accelerators through
 * the menu**, so a null menu is not a hidden menu bar, it is an app with no
 * Ctrl+C, no Ctrl+V, no Ctrl+X, no Ctrl+A, no Ctrl+Z, no Ctrl+R, no zoom keys,
 * no full screen — and none of the thirteen chords the items below spell out
 * for themselves. Losing copy and paste in a terminal is not a cosmetic
 * regression, it is the app. The same fact is already written
 * down twice in this file and once in `menu.test.ts`, each time as the reason
 * an item's chord dies with the item — it is exactly as true of the whole menu.
 *
 * So the menu stays built, complete, and is merely not drawn: `hidesMenuBar`
 * below is passed to the window as `autoHideMenuBar`, which hides the strip
 * while leaving the menu installed. Every accelerator keeps working, and Alt
 * still brings the bar down over the content for the one person who goes
 * looking for File → Exit, which is where Windows has trained them to look.
 *
 * Nothing is orphaned by hiding it, and that was checked rather than assumed:
 * `app.preferences` is the Settings row at the foot of the sidebar and a
 * palette entry, `app.shortcuts` and `app.help` are palette entries,
 * `app.about` and `app.setup` open pages of Settings, and every `view.*` and
 * `session.*` id here is a palette command or a sidebar row. `reachable.test.ts`
 * is what keeps that true — it fails if the menu sends a command the window has
 * no case for.
 *
 * The registry lives in the renderer, because everything that consults it does.
 * So the renderer sends the ids of the commands whose feature is switched off,
 * the same way it sends every other piece of state that has to cross — an
 * explicit preload method over one channel — and the menu is rebuilt from
 * scratch each time that list changes. Rebuilt, not built once: a menu that is
 * only correct at launch is the same bug one uninstall later, and Electron
 * binds accelerators *through* the menu, so an item that goes away takes its
 * chord with it — which is the right way round. ⌘D with no menu item behind it
 * falls through to the window's own key handler, and that handler routes a
 * command for a missing feature into the store and explains itself. Exactly one
 * of the two answers is live at any moment, and neither of them is silence.
 */

/** Turns a renderer command id into a menu click handler. */
export type Send = (command: string) => () => void

/**
 * Command ids the menu must not offer, because the feature that owns them is
 * not installed in the window that sent this.
 *
 * Empty means "offer everything", which is the only safe reading of "nobody has
 * told me anything yet": the app has to come up with its whole menu bar, and a
 * launch that hid Sessions or Settings while it waited for the first frame of
 * the renderer would be a far worse failure than a moment of showing an item
 * for a feature somebody removed.
 */
export type HiddenCommands = ReadonlySet<string>

const NOTHING_HIDDEN: HiddenCommands = new Set<string>()

/**
 * Whether this platform draws the menu bar inside the window, where it would be
 * a strip of its own under our toolbar.
 *
 * True off macOS, and the value is passed to the BrowserWindow as
 * `autoHideMenuBar` — so the menu is built and installed exactly as before and
 * simply is not painted. See the header of this file for why the menu may never
 * be thrown away to achieve that: Electron binds every accelerator through it,
 * and this is a terminal app that would be left with no Ctrl+C.
 *
 * macOS is false because there is nothing to hide: its menu bar belongs to the
 * OS and lives at the top of the *screen*, not in the window. `autoHideMenuBar`
 * is a no-op there, but returning true would read as "macOS hides its menu bar
 * too", which is the misunderstanding that would eventually get somebody to
 * delete the Apple-standard app menu again — the exact regression the first
 * half of `menu.test.ts` exists to prevent.
 */
export function hidesMenuBar(platform: Platform): boolean {
  return platform !== 'darwin'
}

export function menuTemplate(
  platform: Platform,
  send: Send,
  hidden: HiddenCommands = NOTHING_HIDDEN,
): MenuItemConstructorOptions[] {
  const mac = platform === 'darwin'
  const separator: MenuItemConstructorOptions = { type: 'separator' }

  /**
   * A menu item, or nothing at all when its feature has been uninstalled.
   *
   * Gone, rather than present and greyed out. A permanently disabled item is a
   * question the menu bar has no room to answer — it cannot say "you uninstalled
   * this, here is how to get it back" — and the palette already does exactly
   * that, in words, under the name of the feature.
   *
   * `renderer/features/menu-bridge.test.ts` reads this file and fails the build
   * if a command the registry gates is sent from an item that does not go
   * through here.
   */
  const whenInstalled = (
    command: string,
    item: MenuItemConstructorOptions,
  ): MenuItemConstructorOptions[] => (hidden.has(command) ? [] : [item])

  // The four items the app menu used to own. Defined once so the two layouts
  // cannot disagree about a label or an accelerator — the drift would show up
  // as a shortcut that works on one platform and prints on both.
  const about: MenuItemConstructorOptions = {
    label: `About ${BRAND.name}`,
    click: send('app.about'),
  }
  const settings: MenuItemConstructorOptions = {
    label: 'Settings…',
    accelerator: 'CmdOrCtrl+,',
    click: send('app.preferences'),
  }
  const shortcuts: MenuItemConstructorOptions = {
    label: 'Keyboard Shortcuts',
    accelerator: 'CmdOrCtrl+/',
    click: send('app.shortcuts'),
  }
  // `role: 'quit'` rather than a click, because the role is what carries ⌘Q on
  // macOS and the right teardown everywhere. Windows spells it Exit, and a role
  // takes an overriding label.
  const quit: MenuItemConstructorOptions = mac ? { role: 'quit' } : { role: 'quit', label: 'Exit' }

  const appMenu: MenuItemConstructorOptions = {
    label: BRAND.name,
    submenu: [
      about,
      separator,
      // macOS convention: Settings…, ⌘, at the top of the app menu.
      settings,
      shortcuts,
      separator,
      { role: 'services' },
      separator,
      { role: 'hide' },
      { role: 'hideOthers' },
      { role: 'unhide' },
      separator,
      quit,
    ],
  }

  const file: MenuItemConstructorOptions = {
    label: 'File',
    submenu: [
      { label: 'Open Project…', accelerator: 'CmdOrCtrl+O', click: send('project.open') },
      separator,
      { label: 'New Session', accelerator: 'CmdOrCtrl+T', click: send('session.new') },
      { label: 'New Session…', accelerator: 'CmdOrCtrl+Shift+T', click: send('session.newDialog') },
      // *"Don't give the button as close in drop downs, in three dots,
      // everywhere."* The File menu is one of the everywheres: this item ends
      // the session for real, through the same confirmation the rail's ⋯ opens.
      // The command it sends keeps its old name — that string is the wire to
      // `keymap.ts` and `App.tsx`, and renaming it to change a word on a menu is
      // how a menu item stops firing.
      { label: 'Delete Session', accelerator: 'CmdOrCtrl+W', click: send('session.close') },
      // Where a Windows user looks for them. On macOS these stay in the app
      // menu, so repeating them here would be a second door to one room.
      ...(mac ? [] : [separator, settings, shortcuts, separator, quit]),
    ],
  }

  const help: MenuItemConstructorOptions = {
    role: 'help',
    submenu: [
      { label: `${BRAND.name} Help`, click: send('app.help') },
      { label: 'Setup & Diagnostics', click: send('app.setup') },
      separator,
      {
        label: 'Report an Issue',
        click: () => void shell.openExternal('https://github.com/'),
      },
      // Bottom of Help is where Windows puts About; macOS has it in the app menu.
      ...(mac ? [] : [separator, about]),
    ],
  }

  // Every gated item below shares its group with an item nothing can take away
  // — Sessions in the first, Toggle Sidebar in the second — so uninstalling all
  // three features can never strand a separator against another separator or
  // against the end of the menu. `menu.test.ts` asserts that for every
  // combination rather than leaving it as something true today.
  const view: MenuItemConstructorOptions = {
    label: 'View',
    submenu: [
      { label: 'Sessions', click: send('view.terminal') },
      { label: 'Project Overview', click: send('view.overview') },
      ...whenInstalled('view.browser', { label: 'Browser', click: send('view.browser') }),
      separator,
      { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+B', click: send('view.sidebar') },
      ...whenInstalled('pane.split', {
        label: 'Split the Window',
        accelerator: 'CmdOrCtrl+D',
        click: send('pane.split'),
      }),
      ...whenInstalled('view.swarm', {
        label: 'Swarm View',
        accelerator: 'CmdOrCtrl+\\',
        click: send('view.swarm'),
      }),
      separator,
      { label: 'Command Palette', accelerator: 'CmdOrCtrl+K', click: send('app.palette') },
      { label: 'Quick Open', accelerator: 'CmdOrCtrl+P', click: send('app.quickOpen') },
      { label: 'Search Sessions', accelerator: 'CmdOrCtrl+Shift+F', click: send('panel.search') },
      { label: 'Session Inspector', accelerator: 'CmdOrCtrl+Shift+I', click: send('app.inspector') },
      separator,
      { role: 'reload' },
      { role: 'toggleDevTools' },
      { role: 'resetZoom' },
      { role: 'zoomIn' },
      { role: 'zoomOut' },
      { role: 'togglefullscreen' },
    ],
  }

  return [
    ...(mac ? [appMenu] : []),
    file,
    { role: 'editMenu' },
    view,
    { role: 'windowMenu' },
    help,
  ]
}

/**
 * The channel the window pushes its feature state down.
 *
 * A `send`, not an `invoke`: the renderer is telling the menu something, and
 * there is no answer to wait for. Named for what it carries rather than for the
 * feature store, because that is all the main process is ever told — a list of
 * command ids, no feature ids, no statuses. The registry stays in the one
 * process that owns it, and this side cannot fall out of step with a table it
 * never reads.
 */
export const MENU_HIDDEN_COMMANDS = 'menu:hidden-commands'

/**
 * Command ids off a message, and nothing else.
 *
 * This arrives from a renderer, so it is parsed rather than trusted: the worst
 * a malformed one can do here is hide nothing, which is the menu the app has
 * always had.
 */
function commandsFrom(value: unknown): HiddenCommands {
  if (!Array.isArray(value)) return NOTHING_HIDDEN
  const entries: readonly unknown[] = value
  const commands = new Set<string>()
  for (const entry of entries) {
    if (typeof entry === 'string' && entry !== '') commands.add(entry)
  }
  return commands
}

function sameCommands(a: HiddenCommands, b: HiddenCommands): boolean {
  if (a.size !== b.size) return false
  for (const command of a) if (!b.has(command)) return false
  return true
}

export function buildMenu(
  getWindow: () => BrowserWindow | null,
  platform: Platform = currentPlatform(),
): void {
  const send: Send = (command: string) => () => {
    const window = getWindow()
    if (window && !window.isDestroyed()) window.webContents.send('menu:command', command)
  }

  let hidden: HiddenCommands = NOTHING_HIDDEN
  const apply = (): void => {
    Menu.setApplicationMenu(Menu.buildFromTemplate(menuTemplate(platform, send, hidden)))
  }
  apply()

  /*
   * Rebuilt whenever the window's feature state changes, and only then.
   *
   * `removeAllListeners` first so that two calls leave one listener. Nothing
   * calls this twice today — `index.ts` builds the menu once, at `whenReady` —
   * but two listeners would each close over a different `getWindow`, and the
   * menu would then dispatch its commands into whichever window registered
   * first, which is the one that had just been replaced. One line to make that
   * impossible is better than a convention that nobody may call this again.
   *
   * The equality check is not an optimisation either. `setApplicationMenu`
   * replaces the live menu bar, and doing that while a menu is open closes it
   * under the pointer — and the window pushes the same list again every time it
   * reloads, which is every time somebody opens the devtools and hits reload.
   */
  ipcMain.removeAllListeners(MENU_HIDDEN_COMMANDS)
  ipcMain.on(MENU_HIDDEN_COMMANDS, (_event: IpcMainEvent, commands: unknown) => {
    const next = commandsFrom(commands)
    if (sameCommands(next, hidden)) return
    hidden = next
    apply()
  })

  app.setAboutPanelOptions({ applicationName: BRAND.name, applicationVersion: app.getVersion() })
}
