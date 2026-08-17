import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import './styles/tokens.css'
import './styles/app.css'
import { App } from './App'
import { DriveLayer } from './driving/DriveLayer'

const container = document.getElementById('root')
if (!container) throw new Error('#root missing from index.html')

createRoot(container).render(
  <StrictMode>
    <App />
    {/*
      The copilot's focus overlay — the box around what it is pointing at, and
      the dulling of everything else.

      A sibling of the application rather than a child of it, which is not a
      stylistic preference. It is `position: fixed` and takes no part in the
      layout, so it does not belong in `.app`'s flex row; and it has to stay
      inside `#root` rather than being portalled into `<body>`, because
      `overlay-watch.ts` reads every body child with a box as a floating surface
      and parks any browser page it covers. A portalled scrim would blank every
      web page in the window while a highlight was up — most damagingly when the
      highlight was pointing at the page. `driving/DriveLayer.tsx` carries the
      full argument.

      It renders nothing until something calls `setFocus`.
    */}
    <DriveLayer />
  </StrictMode>,
)
