import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import './styles/tokens.css'
import './styles/app.css'
import { App } from './App'
import { DriveHost } from './copilot/driving/DriveHost'

const container = document.getElementById('root')
if (!container) throw new Error('#root missing from index.html')

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
