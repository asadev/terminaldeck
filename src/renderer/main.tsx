import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import './styles/tokens.css'
import './styles/app.css'
import { App } from './App'
import { DriveHost } from './copilot/driving/DriveHost'
import { PopoutWindow } from './popout/PopoutWindow'
import { HootPanel } from './hoot-panel/HootPanel'
import { bindCatcher } from '../shared/hoot-catcher'
import { SettingsPage } from './settings/SettingsPage'
import { isSettingsPage, settingsIntentFromUrl, settingsSectionFromUrl } from './settings/native-settings'
import { ScreenPage } from './screens/ScreenPage'
import { screenRoute } from './screens/screen-route'
import { IslandPage } from './island/IslandPage'
import { isIslandPage } from './island/native-island'

const container = document.getElementById('root')
if (!container) throw new Error('#root missing from index.html')

/*
 * A file dropped anywhere this window does not handle must do nothing.
 *
 * Chromium's default for a dropped file is to **navigate to it**, and in an
 * Electron window that means the application is replaced by whatever was
 * dropped — a picture of the photo, or a text file, with no way back except
 * reload. It was reachable from every pixel of this app until 2026-08-20,
 * because no surface in it had a drop handler at all.
 *
 * The panes that *do* mean something by a drop — a terminal, the chat composer —
 * call `preventDefault` themselves and this never sees the event, because a
 * handler on the document runs after the ones on the elements inside it and
 * `dropEffect: 'none'` here is not consulted for an event already handled.
 * What is left is every other pixel, and the honest answer there is nothing:
 * silence, rather than a guess about which session a drop on the sidebar meant.
 *
 * Both events, and `dragover` is the load-bearing one: the navigation is
 * committed by the default action of `dragover`, so a `drop` handler alone
 * arrives too late.
 */
for (const kind of ['dragover', 'drop'] as const) {
  window.addEventListener(kind, (event: DragEvent) => {
    if (event.defaultPrevented) return
    event.preventDefault()
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'none'
  })
}

/*
 * A session in a window of its own loads this same page with `?popout=<id>`
 * (`main/popout-windows.ts`), and gets that session and nothing else. Decided
 * before anything mounts: the whole application would otherwise boot in a
 * second window — restore announcements, notifications, the copilot overlay —
 * and every one of those is the main window's job.
 */
const popout = new URLSearchParams(location.search).get('popout')
/*
 * Hoot's island at the top of the screen loads it with `?hootpanel=1`
 * (`main/hoot-menubar.ts`), and gets the island and nothing of the application.
 */
const hootPanel = new URLSearchParams(location.search).get('hootpanel') === '1'

const hootCatcher = new URLSearchParams(location.search).get('hootcatcher') === '1'
/*
 * The native macOS window's Settings window loads it with `?settings=1`
 * (`settings/native-settings.ts`), and gets Settings and nothing of the
 * application. Electron never loads this; its Settings is a sheet in the window.
 */
const settingsPage = isSettingsPage(location.search)
/*
 * And the native window's other pages, each one screen and nothing of the
 * application around it: a view or a session in a window of its own
 * (`?screen=panel&id=…`, `?screen=session&id=…` — `screens/screen-route.ts`),
 * and what Hoot's island holds when it opens (`?island=1`). Electron loads
 * neither.
 */
const screen = screenRoute(location.search)
const islandPage = isIslandPage(location.search)
if (hootCatcher) {
  // A faint painted pixel is required for AppKit's transparent-window hit test.
  document.documentElement.style.cssText = 'height:100%;background:rgba(0,0,0,0.004)'
  document.body.style.cssText = 'margin:0;height:100%;background:transparent;cursor:default'
  bindCatcher(document, (kind) => window.deck.hootPanelCatch(kind), () => window.deck.hootPanelMenu())
} else createRoot(container).render(
  hootPanel ? (
    <StrictMode>
      <HootPanel />
    </StrictMode>
  ) : islandPage ? (
    <StrictMode>
      <IslandPage />
    </StrictMode>
  ) : screen !== null ? (
    <StrictMode>
      <ScreenPage route={screen} />
    </StrictMode>
  ) : settingsPage ? (
    <StrictMode>
      <SettingsPage
        initialSection={settingsSectionFromUrl(location.search)}
        intent={settingsIntentFromUrl(location.search)}
      />
    </StrictMode>
  ) : popout ? (
    <StrictMode>
      <PopoutWindow sessionId={popout} />
    </StrictMode>
  ) : (
  <StrictMode>
    <App />
    {/*
      Driving mode: the copilot's focus overlay — the box around what it is
      pointing at and the dulling of everything else — plus the panel that takes
      the rail's column while a tour plays.

      A sibling of the application rather than a child of it, which is not a
      stylistic preference. Both surfaces are `position: fixed` and take no part
      in the layout, so neither belongs in `.app`'s flex row — and for the panel
      that is load-bearing rather than tidy: a panel inside the row would push
      `.main` narrower, every `TerminalView` would refit its pty, and xterm
      would reflow the buffers the highlights are anchored to. The panel would
      break its own boxes at the moment it opened.

      They also have to stay inside `#root` rather than being portalled into
      `<body>`, because `overlay-watch.ts` reads every body child with a box as
      a floating surface and parks any browser page it covers. A portalled scrim
      would blank every web page in the window while a highlight was up — most
      damagingly when the highlight was pointing at the page.
      `driving/DriveLayer.tsx` and `copilot/driving/DriveHost.tsx` carry the
      arguments in full.

      It renders nothing until a tour arrives on `deck-control:tour`.
    */}
    <DriveHost />
  </StrictMode>
  ),
)
