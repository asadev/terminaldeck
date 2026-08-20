import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '../../src/renderer/styles/tokens.css'
import '../../src/renderer/styles/app.css'
import '../../src/renderer/browser/BrowserWorkspace.css'
import { Toolbar } from '../../src/renderer/browser/Toolbar'
import { Panel } from './common'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div style={{ padding: 16, background: 'var(--bg-primary)', minHeight: '100vh' }}>
      {[1176, 940, 792, 592].map((w) => <Panel key={w} width={w} T={Toolbar} tag="NEW" />)}
    </div>
  </StrictMode>,
)
