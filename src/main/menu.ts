import { app, Menu, shell, type BrowserWindow, type MenuItemConstructorOptions } from 'electron'
import { BRAND } from '../shared/brand'

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
 */
export function buildMenu(getWindow: () => BrowserWindow | null): void {
  const send = (command: string) => () => {
    const window = getWindow()
    if (window && !window.isDestroyed()) window.webContents.send('menu:command', command)
  }

  const template: MenuItemConstructorOptions[] = [
    {
      label: BRAND.name,
      submenu: [
        { label: `About ${BRAND.name}`, click: send('app.about') },
        { type: 'separator' },
        // macOS convention: Settings…, ⌘, at the top of the app menu.
        { label: 'Settings…', accelerator: 'CmdOrCtrl+,', click: send('app.preferences') },
        { label: 'Keyboard Shortcuts', accelerator: 'CmdOrCtrl+/', click: send('app.shortcuts') },
        { type: 'separator' },
        { role: 'services' },
        { type: 'separator' },
        { role: 'hide' },
        { role: 'hideOthers' },
        { role: 'unhide' },
        { type: 'separator' },
        { role: 'quit' },
      ],
    },
    {
      label: 'File',
      submenu: [
        { label: 'Open Project…', accelerator: 'CmdOrCtrl+O', click: send('project.open') },
        { type: 'separator' },
        { label: 'New Session', accelerator: 'CmdOrCtrl+T', click: send('session.new') },
        { label: 'New Session…', accelerator: 'CmdOrCtrl+Shift+T', click: send('session.newDialog') },
        { label: 'Close Session', accelerator: 'CmdOrCtrl+W', click: send('session.close') },
      ],
    },
    { role: 'editMenu' },
    {
      label: 'View',
      submenu: [
        { label: 'Sessions', click: send('view.terminal') },
        { label: 'Project Overview', click: send('view.overview') },
        { label: 'Task Board', click: send('view.board') },
        { label: 'Browser', click: send('view.browser') },
        { type: 'separator' },
        { label: 'Toggle Sidebar', accelerator: 'CmdOrCtrl+B', click: send('view.sidebar') },
        { label: 'Swarm View', accelerator: 'CmdOrCtrl+\\', click: send('view.swarm') },
        { type: 'separator' },
        { label: 'Command Palette', accelerator: 'CmdOrCtrl+K', click: send('app.palette') },
        { label: 'Quick Open', accelerator: 'CmdOrCtrl+P', click: send('app.quickOpen') },
        { label: 'Search Sessions', accelerator: 'CmdOrCtrl+Shift+F', click: send('panel.search') },
        { label: 'Session Inspector', accelerator: 'CmdOrCtrl+Shift+I', click: send('app.inspector') },
        { type: 'separator' },
        { role: 'reload' },
        { role: 'toggleDevTools' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { role: 'togglefullscreen' },
      ],
    },
    { role: 'windowMenu' },
    {
      role: 'help',
      submenu: [
        { label: `${BRAND.name} Help`, click: send('app.help') },
        { label: 'Setup & Diagnostics', click: send('app.setup') },
        { type: 'separator' },
        {
          label: 'Report an Issue',
          click: () => void shell.openExternal('https://github.com/'),
        },
      ],
    },
  ]

  // The first submenu is the app menu only on macOS; elsewhere it would appear
  // as a stray menu titled with the product name.
  if (process.platform !== 'darwin') template.shift()

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
  app.setAboutPanelOptions({ applicationName: BRAND.name, applicationVersion: app.getVersion() })
}
