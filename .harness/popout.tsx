/**
 * A session in a window of its own, looked at rather than asserted.
 *
 * The page a session's own window loads — `?popout=<id>`, which is exactly the
 * address `main/popout-windows.ts` gives it — over the stub, with a screen of
 * output in that session's scrollback so the terminal has something on it.
 * `?theme=light` for the other theme; `?shell` for a session with no account.
 *
 * The main window's half — the card where a popped session's terminal was — is
 * the ordinary harness with `?popped=s1`.
 */
import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { PopoutWindow } from '../src/renderer/popout/PopoutWindow'

const params = new URLSearchParams(location.search)
const sessionId = params.get('popout') ?? 's1'
if (params.get('theme') === 'light') document.documentElement.dataset.theme = 'light'

/*
 * What the main process would hand back for this session's scrollback: a
 * Claude Code screen, colours and all. The one thing out here that has to be
 * made up — there is no pty — so it is set on the bridge rather than in the
 * stub, which keeps answering '' for every other page.
 */
const ESC = '\x1b['
const SCREEN = [
  `${ESC}38;5;174m╭──────────────────────────────────────────────╮${ESC}0m`,
  `${ESC}38;5;174m│${ESC}0m ${ESC}1m✻ Welcome to Claude Code!${ESC}0m                    ${ESC}38;5;174m│${ESC}0m`,
  `${ESC}38;5;174m│${ESC}0m   ${ESC}2m/help for help, /status for your setup${ESC}0m     ${ESC}38;5;174m│${ESC}0m`,
  `${ESC}38;5;174m│${ESC}0m   ${ESC}2mcwd: /Users/apple/Projects/terminaldeck${ESC}0m    ${ESC}38;5;174m│${ESC}0m`,
  `${ESC}38;5;174m╰──────────────────────────────────────────────╯${ESC}0m`,
  '',
  `${ESC}2m>${ESC}0m Move the parser tests next to the reader and run them`,
  '',
  `${ESC}38;5;114m⏺${ESC}0m I'll move the tests first, then run the suite.`,
  '',
  `${ESC}38;5;114m⏺${ESC}0m ${ESC}1mBash${ESC}0m(git mv src/parser.test.ts src/reader/parser.test.ts)`,
  `  ⎿  ${ESC}2m(no output)${ESC}0m`,
  '',
  `${ESC}38;5;114m⏺${ESC}0m ${ESC}1mBash${ESC}0m(npx vitest run src/reader)`,
  `  ⎿   ${ESC}32m✓${ESC}0m src/reader/parser.test.ts ${ESC}2m(42 tests)${ESC}0m 118ms`,
  `     ${ESC}32m✓${ESC}0m src/reader/reader.test.ts ${ESC}2m(17 tests)${ESC}0m 64ms`,
  `     ${ESC}1mTest Files${ESC}0m  ${ESC}32m2 passed${ESC}0m (2)`,
  '',
  `${ESC}38;5;114m⏺${ESC}0m Both files pass. The tests now sit beside the code they cover.`,
  '',
  `${ESC}38;5;246m╭──────────────────────────────────────────────────────────────────╮${ESC}0m`,
  `${ESC}38;5;246m│${ESC}0m > ${ESC}2mTry "write a test for reader.ts"${ESC}0m                              ${ESC}38;5;246m│${ESC}0m`,
  `${ESC}38;5;246m╰──────────────────────────────────────────────────────────────────╯${ESC}0m`,
  `  ${ESC}2m? for shortcuts${ESC}0m`,
].join('\r\n')

const deck = (globalThis as unknown as { deck: Record<string, unknown> }).deck
deck.getScrollback = async (id: string) => (id === sessionId ? SCREEN : '')

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <PopoutWindow sessionId={sessionId} />
  </StrictMode>,
)
