import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { App } from '../src/renderer/App'
import { DriveHost } from '../src/renderer/copilot/driving/DriveHost'

/**
 * Driving mode, on a screen, without Electron.
 *
 * `CLAUDE.md`: *"Compiling is not working. Two bugs shipped clean typechecks and
 * clean console output while being visibly wrong on screen."* That applies
 * harder to this feature than to anything else in the app, because every part of
 * it is a thing you can only judge by looking: whether the dots read as a
 * machine working, whether the focus is genuinely the one clear thing on the
 * window, whether 260 ms a stop is a scan or a strobe. None of that is visible
 * in a diff and none of it fails a test.
 *
 * ## What is real here and what is not, stated plainly
 *
 * The **plan is a fixture**; everything downstream of it is the shipping code.
 * The overlay, the anchor resolution, the dot field, the panel, the playhead and
 * the interruption watch are all the real modules, mounted the way `main.tsx`
 * mounts them, against the real `App` with real xterm terminals in it. What the
 * harness stands in for is the one thing it cannot have — a copilot process that
 * read four transcripts and wrote a tour — and that half is checked by
 * `tour.test.ts` and `tour-gates.test.ts` against the real validator instead.
 *
 * This is the split `DRIVING-MODE.md` §9 asks for in as many words: *"Feed it a
 * plan from a fixture. This phase is finished when a hand-written tour drives a
 * real fleet correctly."*
 *
 * Nothing here ships. It is a page under `.harness/`, which is not in any
 * bundle the app builds.
 *
 * ## Driving it
 *
 *     npx vite --config .harness/vite.config.ts
 *     # then, in the page or over CDP:
 *     scan()          // play the fixture
 *     scan(2)         // play a two-stop one
 */

/* --------------------------------------------------------------- fixture -- */

const SESSIONS = [
  's1',
  's2',
  '7f3c9a21-6d40-4a1e-9d2b-1a5f0c3e7b81',
  'b4e1d508-2c77-4f93-8a10-9e6b2d4c5a03',
]

/**
 * What each session has on screen, and the line the scan points at.
 *
 * Written into the real xterm buffers below, so the stop is anchored the way a
 * real one is: by finding its text. `terminal-region.ts` scans the buffer
 * backwards for the most recent match, and if the text is not there the stop is
 * dropped by the same verification that protects the shipping path. That makes
 * this fixture a genuine exercise of the anchor, not a picture of one.
 */
const SCREENS: Array<{ lines: string[]; quote: string; note: string; why: string }> = [
  {
    lines: [
      '\u001b[2m❯\u001b[0m npm run migrate -- --to 20260817b',
      '  applying 20260817b_orders_backfill …',
      '  \u001b[33mThe backfill would touch 41,882 rows in orders.\u001b[0m',
      '  Run it against production now? (y/N)',
    ],
    quote: 'The backfill would touch 41,882 rows in orders.',
    note: 'Waiting on you before it touches production.',
    why: 'blocked-on-you',
  },
  {
    lines: [
      '\u001b[2m❯\u001b[0m npx vitest run src/relay',
      '  \u001b[31mFAIL\u001b[0m src/relay/handshake.test.ts > rejects a replayed nonce',
      '  → retrying with a wider timeout (attempt 4)',
      '  \u001b[31mFAIL\u001b[0m src/relay/handshake.test.ts > rejects a replayed nonce',
    ],
    quote: 'retrying with a wider timeout (attempt 4)',
    note: 'Fourth attempt at the same fix; the timeout is not the problem.',
    why: 'looping',
  },
  {
    lines: [
      '\u001b[2m❯\u001b[0m git status --short',
      '   M src/main/pty-manager.ts',
      '   M src/main/session-held.ts',
      '  11 files changed, 402 insertions(+), 87 deletions(-)',
    ],
    quote: '11 files changed, 402 insertions(+), 87 deletions(-)',
    note: 'Wrote to eleven files under src/main and stopped cleanly.',
    why: 'files-changed',
  },
  {
    lines: [
      '\u001b[2m❯\u001b[0m read the whole of src/renderer and plan the refactor',
      '  … 214 files read',
      '  Tokens: 4,180,332 in · 96,441 out',
      '  Cost so far: $18.40',
    ],
    quote: 'Tokens: 4,180,332 in · 96,441 out',
    note: 'Spent about four times what the others did on one refactor.',
    why: 'expensive',
  },
]

const STOPS = SCREENS.map((screen, index) => ({
  kind: 'screen',
  sessionId: SESSIONS[index],
  quote: screen.quote,
  note: screen.note,
  why: screen.why,
}))

/**
 * Put the text on the real terminals, through the real registry.
 *
 * The registry is keyed by a registered symbol precisely so that "the terminals
 * in this window" is one fact however the code was loaded — see
 * `terminal-registry.ts` — which also makes it the honest way in from here.
 * Nothing is stubbed: these are the same `Terminal` objects `TerminalView`
 * mounted, and the scan finds its quotes in them by scanning the buffer.
 */
function paint(): void {
  const registry = (globalThis as Record<symbol, unknown>)[
    Symbol.for('terminaldeck.driving.terminals')
  ] as Map<string, { term: { write(data: string): void } }> | undefined
  if (registry === undefined) return
  SESSIONS.forEach((id, index) => {
    const entry = registry.get(id)
    if (entry === undefined) return
    entry.term.write(`\r\n${SCREENS[index].lines.join('\r\n')}\r\n`)
  })
}

function record(count: number) {
  const stops = STOPS.slice(0, count)
  return {
    v: 1,
    id: `tour_${Date.now()}_harness01`,
    startedAt: Date.now(),
    endedAt: null,
    askedBy: 'user',
    question: 'What happened last night?',
    headline: 'Four sessions ran. One is waiting on you and one is going in circles.',
    shown: 'screen',
    stops: stops.map((stop, index) => ({
      index,
      sessionId: stop.sessionId,
      sessionTitle: ['terminaldeck', 'relay', 'pty-manager', 'renderer refactor'][index],
      kind: 'screen',
      cwd: '/Users/apple/Projects/terminaldeck',
      why: stop.why,
      quote: stop.quote,
      note: stop.note,
      shownAt: null,
      dwellMs: null,
      degraded: false,
      degradedWhy: null,
    })),
    stoppedAfter: null,
    dropped: [],
  }
}

/* ----------------------------------------------------------------- wiring -- */

type Handler = (tour: unknown) => void
const handlers = new Set<Handler>()

const deck = (globalThis as unknown as { deck: Record<string, unknown> }).deck
/*
 * `onTour` and `reportTour` are added rather than proxied through.
 *
 * `stub.ts` answers an unknown key with a generic noop, which is right for a
 * key nothing is testing and wrong for these two: the host waits on
 * `reportTour` resolving and subscribes through `onTour`, so a generic
 * `async () => null` would leave every scan reported into a void with no
 * subscriber. Keeping the stub honest is a rule this harness has broken three
 * times, and each time it invented a bug that did not exist.
 */
deck.onTour = (handler: Handler) => {
  handlers.add(handler)
  return () => handlers.delete(handler)
}
/*
 * The record the app would have on disk, kept in memory.
 *
 * `reportTour` is how the window tells the main process what it did — which
 * stop was shown, when, and for how long — and `tours` is how the answer card
 * reads the record back. Keeping the same object between them is what makes the
 * second phase real here: the card is rendered from the record the scan
 * actually produced, including the stops it never reached, rather than from a
 * separate fixture that could quietly disagree with it.
 */
let written: Record<string, unknown> | null = null
deck.reportTour = async (report: { record?: Record<string, unknown> }) => {
  if (report?.record !== undefined) written = report.record
  return { accepted: true }
}
deck.tours = async () => (written === null ? [] : [written])

;(globalThis as unknown as { answer: () => void }).answer = () => {
  document.querySelector<HTMLElement>('[data-copilot-row]')?.click()
}

;(globalThis as unknown as { scan: (count?: number) => void }).scan = (count = STOPS.length) => {
  paint()
  const message = { record: record(count), stops: STOPS.slice(0, count) }
  for (const handler of handlers) handler(message)
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
    <DriveHost />
  </StrictMode>,
)
