import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import './styles/tokens.css'
import './styles/app.css'
import { App } from './App'
import { DriveHost } from './copilot/driving/DriveHost'

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

createRoot(container).render(
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
  </StrictMode>,
)
