import './stub'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { TourRecap } from '../src/renderer/copilot/driving/TourRecap'

/**
 * The answer, on its own.
 *
 * Phase two of driving mode is the only half meant to be read, and it is the
 * half the whole-app harness cannot reach: the copilot's own window needs a live
 * copilot session behind it, and the stub has none. Mounting the component alone
 * is the pattern every other component page here already uses, and it is enough,
 * because what has to be judged is one thing — does *"this session did this,
 * this session did that"* read as an answer, or as a log.
 *
 * The record below is the shape `tour-stage.ts` writes, field for field,
 * including the two honest cases the card has to render: a stop the scan never
 * reached, and a stop that was dropped before it played.
 */

const RECORD = {
  v: 1,
  id: 'tour_1700000000000_abcdef01',
  startedAt: Date.now() - 60_000,
  endedAt: Date.now() - 58_000,
  askedBy: 'user',
  question: 'What happened last night?',
  headline:
    'Four sessions ran. The migration is waiting on you before it touches production, the relay tests are ' +
    'going in circles, and the renderer refactor cost about four times what the others did.',
  shown: 'screen',
  stops: [
    {
      index: 0,
      sessionId: 's1',
      sessionTitle: 'terminaldeck — migration',
      kind: 'screen',
      cwd: '/Users/apple/Projects/terminaldeck',
      why: 'blocked-on-you',
      quote: 'The backfill would touch 41,882 rows in orders.\nRun it against production now? (y/N)',
      note: 'Waiting on you before it touches production.',
      shownAt: Date.now() - 59_500,
      dwellMs: 262,
      degraded: false,
      degradedWhy: null,
    },
    {
      index: 1,
      sessionId: 's1',
      sessionTitle: 'terminaldeck — migration',
      kind: 'screen',
      cwd: '/Users/apple/Projects/terminaldeck',
      why: 'files-changed',
      quote: '11 files changed, 402 insertions(+), 87 deletions(-)',
      note: 'It had already written the new migration before it stopped to ask.',
      shownAt: Date.now() - 59_200,
      dwellMs: 259,
      degraded: false,
      degradedWhy: null,
    },
    {
      index: 2,
      sessionId: 's2',
      sessionTitle: 'relay',
      kind: 'screen',
      cwd: '/Users/apple/Projects/terminaldeck',
      why: 'looping',
      quote: '→ retrying with a wider timeout (attempt 4)\nFAIL src/relay/handshake.test.ts > rejects a replayed nonce',
      note: 'Fourth attempt at the same fix; the timeout is not the problem.',
      shownAt: Date.now() - 58_900,
      dwellMs: 261,
      degraded: false,
      degradedWhy: null,
    },
    {
      index: 3,
      sessionId: 's4',
      sessionTitle: 'renderer refactor',
      kind: 'screen',
      cwd: '/Users/apple/Projects/terminaldeck',
      why: 'expensive',
      quote: 'Tokens: 4,180,332 in · 96,441 out',
      note: 'Spent about four times what the others did on one refactor.',
      shownAt: null,
      dwellMs: null,
      degraded: false,
      degradedWhy: null,
    },
  ],
  stoppedAfter: 2,
  dropped: [
    {
      title: 'pty-manager — a crash it recovered from',
      why: 'quote-not-found',
      detail: 'The quoted line had scrolled out of what this window still holds.',
    },
  ],
}

createRoot(document.getElementById('root')!).render(
  <div style={{ maxWidth: 760, margin: '0 auto' }}>
    <TourRecap read={async () => [RECORD]} />
  </div>,
)
