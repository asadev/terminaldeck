import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { App } from '../src/renderer/App'
createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>)
