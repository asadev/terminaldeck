/**
 * The whole window, with terminals you can actually open on a server.
 *
 *     npx vite --config .harness/vite.config.ts --port 5199
 *     open http://localhost:5199/server-session.html
 *
 * ## Why this is not `servers.html`
 *
 * That one mounts `MachinesPanel` on its own, which is right for the thing it
 * was built to show — the *sequence* of adding a server and reading its page.
 * It cannot show this one at all: a terminal on a server is a session in the
 * window now, so what has to be looked at is the rail row, the pill in the top
 * strip, the pane behind them and the chrome that is deliberately **not** drawn
 * over it. None of that exists without the window around it, and the panel
 * rendered bare correctly says so — it reports that it is not inside a window
 * that can hold a terminal open.
 *
 * ## Why it is not a change to `stub.ts`
 *
 * The shared stub answers `listServers` with nothing on purpose, so that opening
 * Machines in every other harness page draws the real *"you have not added a
 * server yet"* screen. Filling it in there would take that state away from every
 * other view to give it to this one. So this page imports the stub for the whole
 * of the rest of the app and replaces four of its answers, which is also the
 * honest shape: the only thing being faked here is the far end.
 *
 * `?light` boots the light theme, through the stub's own switch — poking
 * `data-theme` from outside changes the sheet and not the terminals, because
 * xterm paints on a canvas and re-resolves its palette only when the app's own
 * theme controller fires.
 */
import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { App } from '../src/renderer/App'

const NOW = Date.now()

type Listener = (chunk: { shellId: string; data: string }) => void

const output = new Set<Listener>()
const closed = new Set<Listener>()
let shells = 0

/** A pause, because every one of these crosses the internet in the real thing. */
function after<T>(value: T, ms = 400): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms))
}

function fact<T>(value: T, how: string): unknown {
  return { known: 'yes', value, measuredAt: NOW - 20 * 60_000, how }
}

const SERVERS = [
  { id: 's1', name: 'the shop', address: 'shop.example.com', username: 'admin', credential: 'key' },
  {
    id: 's2',
    name: 'the little one',
    address: '203.0.113.10',
    username: 'deploy',
    credential: 'password',
  },
]

const view = {
  cards: [
    {
      id: 'c1',
      kind: 'site',
      name: 'shop.example.com',
      detail: 'Served by nginx',
      running: true,
      url: 'https://shop.example.com',
    },
  ],
  facts: {
    os: fact('Ubuntu 24.04.4 LTS', 'read what the system calls itself'),
    hostname: fact('shop-1', 'asked what it calls itself'),
    user: fact('admin', 'asked who we are signed in as'),
  },
  offered: { c1: ['open'] },
  absent: {},
  how: [],
  cannot: [],
  measuredAt: NOW - 20 * 60_000,
}

Object.assign((globalThis as unknown as { deck: Record<string, unknown> }).deck, {
  listServers: () => after(SERVERS),
  lookAtServer: () => after({ ok: true, view }, 700),
  closeServer: async () => ({ closed: true }),
  previewServerAction: async () => ({ ok: true, preview: { id: 'open', label: 'Open', sentence: 'Opens it.' } }),
  serverGrantState: async () => null,

  /**
   * A shell, with the same race the real one has.
   *
   * The first frame is emitted **before** the id is answered, deliberately: the
   * far side attaches its listener the moment the shell exists, while the id
   * naming it is still travelling back. That is how the dropped-prompt defect
   * was found in the other harness, and slowing this down to be polite would
   * hide it again.
   */
  openServerShell: (id: string, cols: number) => {
    const shellId = `${id} ${(shells += 1)}`
    setTimeout(() => {
      for (const listener of output) {
        listener({
          shellId,
          data:
            `\r\nWelcome to Ubuntu 24.04.4 LTS (GNU/Linux 6.8.0 aarch64)\r\n\r\n` +
            `admin@shop-1:~$ \x1b[2m# ${cols} columns\x1b[0m\r\n`,
        })
      }
    }, 350)
    return after({ ok: true, shellId }, 450)
  },
  writeToServerShell: (shellId: string, data: string) => {
    for (const listener of output) listener({ shellId, data })
    return Promise.resolve({ written: true })
  },
  resizeServerShell: async () => ({ resized: true }),
  closeServerShell: (shellId: string) => {
    for (const listener of closed) listener({ shellId })
    return Promise.resolve({ closed: true })
  },
  onServerShellOutput: (cb: Listener) => {
    output.add(cb)
    return () => output.delete(cb)
  },
  onServerShellClosed: (cb: Listener) => {
    closed.add(cb)
    return () => closed.delete(cb)
  },
  renameServer: async () => ({ renamed: true }),
})

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
