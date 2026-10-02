/**
 * Settings → Connect an AI app, without Electron.
 *
 *     npx vite --config .harness/vite.config.ts --port 5231
 *     open http://localhost:5231/aiapps.html
 *
 * The real `SettingsWindow`, opened on the pane, over the shared stub — so the
 * shapes the pane reads are the ones `stub.ts` keeps in step with the preload.
 *
 * Query flags:
 *   ?light           the light theme
 *   ?ai-apps-empty   a fresh install: no keys, internet reach off
 */
import './stub'
import { createRoot } from 'react-dom/client'
import { SettingsWindow } from '../src/renderer/settings/SettingsWindow'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'
import '../src/renderer/shell/shell.css'

document.documentElement.dataset.theme = new URLSearchParams(location.search).has('light') ? 'light' : 'dark'

createRoot(document.getElementById('root')!).render(
  <SettingsWindow open onClose={() => console.log('close')} initialSection="ai-apps" platform="mac" />,
)
