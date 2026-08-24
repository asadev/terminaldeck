/**
 * Appearance → Terminal, beside a terminal it is actually painting.
 *
 * The claim this page exists to make checkable is the one nothing in the suite
 * can see: that changing a colour repaints a session that is **already open**.
 * A test can prove `terminalTheme()` returns the scheme and that the subscription
 * is written down; only a browser with a live xterm in it can show that the
 * pixels on a running terminal changed while the pane was open.
 *
 * So the right half is wired exactly as `TerminalView` wires itself — the same
 * `terminalTheme()`, the same two subscriptions — and it prints real ANSI, all
 * sixteen colours, so a scheme with a dull green in it is visible as a dull
 * green rather than as a name.
 *
 * `?light` boots the app light, to look at a dark scheme pinned in a light
 * window, which is the case the pane's own copy makes a promise about.
 */
import './stub'
import { StrictMode, useEffect, useRef } from 'react'
import { createRoot } from 'react-dom/client'
import { Terminal } from '@xterm/xterm'
import '@xterm/xterm/css/xterm.css'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { SettingsPanel } from '../src/renderer/settings/SettingsWindow'
import { terminalTheme } from '../src/renderer/components/TerminalView'
import { applyTerminalScheme, subscribeTerminalScheme } from '../src/renderer/terminal-scheme'
import { subscribeTheme } from '../src/renderer/theme'
import { mergeSettings } from '../src/renderer/settings/settings-schema'

/*
 * A settings file that survives a re-read, which the shared stub's does not.
 *
 * `stub.ts` answers `{}` to every `getSettings` and echoes every `setSettings`
 * back, which is right for a page that never writes one — and wrong for this
 * one, where the whole feature is a list of schemes somebody makes and the pane
 * re-reads the file after every write.
 */
const stored: Record<string, unknown> = {}
const deck = (globalThis as unknown as { deck: Record<string, unknown> }).deck
deck.getSettings = async () => ({ version: 1, values: { ...stored } })
deck.setSettings = async (patch: unknown) => {
  for (const [key, value] of Object.entries(patch as Record<string, unknown>)) {
    if (value === null) delete stored[key]
    else stored[key] = value
  }
  // The app half of the window learns the same way `useAppSettings` does.
  applyTerminalScheme(mergeSettings({ ...stored }) as Record<string, unknown>)
  return { version: 1, values: { ...stored } }
}

const DEMO = [
  '\x1b[32m➜\x1b[0m  \x1b[36mterminaldeck\x1b[0m \x1b[34mgit:(\x1b[31mmain\x1b[34m)\x1b[0m npm test',
  '',
  '\x1b[90m RUN \x1b[0m v4.1.10 /Users/apple/Projects/terminaldeck',
  '',
  ' \x1b[32m✓\x1b[0m src/shared/terminal-theme.test.ts \x1b[90m(31 tests)\x1b[0m \x1b[90m18ms\x1b[0m',
  ' \x1b[32m✓\x1b[0m src/renderer/terminal-scheme.test.ts \x1b[90m(12 tests)\x1b[0m \x1b[90m6ms\x1b[0m',
  ' \x1b[33m❯\x1b[0m src/renderer/settings/settings-schema.test.ts \x1b[90m(1 skipped)\x1b[0m',
  '',
  '\x1b[1m Test Files \x1b[0m \x1b[32m2 passed\x1b[0m \x1b[90m(2)\x1b[0m',
  '\x1b[1m      Tests \x1b[0m \x1b[32m43 passed\x1b[0m \x1b[90m(43)\x1b[0m',
  '',
  '\x1b[35m warning\x1b[0m  \x1b[33m1 skipped\x1b[0m  \x1b[31m0 failed\x1b[0m  \x1b[36mdone in 1.2s\x1b[0m',
  '',
  '  \x1b[30m\x1b[47m 30 \x1b[0m\x1b[31m 31 \x1b[32m 32 \x1b[33m 33 \x1b[34m 34 \x1b[35m 35 \x1b[36m 36 \x1b[37m 37 \x1b[0m',
  '  \x1b[90m 90 \x1b[91m 91 \x1b[92m 92 \x1b[93m 93 \x1b[94m 94 \x1b[95m 95 \x1b[96m 96 \x1b[97m 97 \x1b[0m',
  '',
  '\x1b[32m➜\x1b[0m  \x1b[36mterminaldeck\x1b[0m \x1b[34mgit:(\x1b[31mmain\x1b[34m)\x1b[0m ',
]

function LiveTerminal() {
  const host = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const element = host.current
    if (!element) return
    const term = new Terminal({
      fontFamily: 'JetBrains Mono, Menlo, monospace',
      fontSize: 13,
      lineHeight: 1.35,
      cursorBlink: false,
      cols: 74,
      rows: 22,
      theme: terminalTheme(),
    })
    term.open(element)
    term.write(DEMO.join('\r\n'))
    // Exactly what `TerminalView` holds: the app's theme, and the scheme.
    const offTheme = subscribeTheme(() => {
      term.options.theme = terminalTheme()
    })
    const offScheme = subscribeTerminalScheme(() => {
      term.options.theme = terminalTheme()
    })
    return () => {
      offTheme()
      offScheme()
      term.dispose()
    }
  }, [])
  return <div className="harness-term" ref={host} />
}

function Page() {
  return (
    <div className="harness-split">
      <div className="harness-pane">
        <SettingsPanel platform="mac" initialSection="appearance" />
      </div>
      <div className="harness-side">
        <LiveTerminal />
      </div>
    </div>
  )
}

const style = document.createElement('style')
style.textContent = `
  body { margin: 0; background: var(--bg-primary); color: var(--text-primary); }
  .harness-split { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 20px; padding: 20px; align-items: start; }
  .harness-pane { min-width: 0; border: 1px solid var(--border); border-radius: 12px; overflow: hidden; background: var(--bg-secondary); }
  .harness-side { padding: 10px; border-radius: 12px; background: var(--bg-secondary); border: 1px solid var(--border); }
`
document.head.append(style)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <Page />
  </StrictMode>,
)
