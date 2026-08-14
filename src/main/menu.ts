import { app, Menu, shell, type BrowserWindow, type MenuItemConstructorOptions } from 'electron'
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
 */

/** Turns a renderer command id into a menu click handler. */
export type Send = (command: string) => () => void

export function menuTemplate(platform: Platform, send: Send): MenuItemConstructorOptions[] {
  const mac = platform === 'darwin'
  const separator: MenuItemConstructorOptions = { type: 'separator' }

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
      { label: 'Close Session', accelerator: 'CmdOrCtrl+W', click: send('session.close') },
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

  const view: MenuItemConstructorOptions = {
    label: 'View',
    submenu: [
      { label: 'Sessions', click: send('view.terminal') },
      { label: 'Project Overview', click: send('view.overview') },
      { label: 'Task Board', click: send('view.board') },
      { label: 'Browser', click: send('view.browser') },
      separator,
      { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+B', click: send('view.sidebar') },
      { label: 'Swarm View', accelerator: 'CmdOrCtrl+\\', click: send('view.swarm') },
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

export function buildMenu(
  getWindow: () => BrowserWindow | null,
  platform: Platform = currentPlatform(),
): void {
  const send: Send = (command: string) => () => {
    const window = getWindow()
    if (window && !window.isDestroyed()) window.webContents.send('menu:command', command)
  }

  Menu.setApplicationMenu(Menu.buildFromTemplate(menuTemplate(platform, send)))
  app.setAboutPanelOptions({ applicationName: BRAND.name, applicationVersion: app.getVersion() })
}
