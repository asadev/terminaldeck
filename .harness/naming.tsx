/**
 * Look at the copy the naming sweep rewrote, on screen, in both themes.
 *
 *     npx vite --config .harness/vite.config.ts --port 5233
 *     open http://localhost:5233/naming.html
 *
 * `src/neutral-naming.test.ts` proves the vendor names are gone from the
 * strings. It cannot prove the replacements *read* — that a row still says
 * something, that a sentence did not lose the word that made it make sense, or
 * that a shortened label now collides with the badge beside it. Two of the
 * strings this sweep touched are the help line under a settings row and the
 * label on a `<textarea>`, and both are the kind of thing that looks fine in a
 * diff and wrong on a screen.
 *
 * So this mounts the two panes that took most of the rewrite — Settings →
 * Copilot, and the AI-readiness list — against fixtures, side by side in light
 * and dark. It is a board to look at, not a test; nothing here asserts anything.
 */
import { createRoot } from 'react-dom/client'
import { CopilotSection } from '../src/renderer/settings/sections/CopilotSection'
import { ReadinessPanel } from '../src/renderer/components/ReadinessPanel'
import { CHOOSING_A_FOLDER } from '../src/shared/copilot-text'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/settings/SettingsWindow.css'

const ROOT = '/Users/asad/Projects/website'

/**
 * A copilot pointed at a folder of the person's own, which is the state whose
 * help line the sweep rewrote — the branch that used to name a filename.
 */
const STATE = {
  status: 'stopped',
  sessionId: null,
  paths: {
    root: ROOT,
    ownFolder: false,
    instructions: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer/instructions.md',
    memory: `${ROOT}/memory`,
    log: '/Users/asad/Library/Application Support/terminaldeck/copilot-log',
    actions: '/Users/asad/Library/Application Support/terminaldeck/copilot-log/actions.jsonl',
    layer: {
      dir: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer',
      yours: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer/instructions.md',
      contract: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer/tools.md',
      composed: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer/copilot.md',
    },
  },
  folder: { home: ROOT, isDefault: false, chosen: ROOT, problem: null },
  home: ROOT,
  startedAt: null,
  problem: null,
  records: { kind: 'none', count: 0 },
  profile: { id: 'p1', name: 'app.imatch.ae@gmail.com' },
  instructionsAreDefault: false,
  instructions: 'edited',
  startupFiles: [],
  layerFiles: [
    {
      path: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer/instructions.md',
      purpose: 'Yours — the persona and the standing instructions.',
      exists: true,
      size: 4210,
      modifiedAt: Date.now() - 90_000,
      owner: 'yours',
    },
    {
      path: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer/tools.md',
      purpose: 'The app’s — the tool contract and the permission rules.',
      exists: true,
      size: 8800,
      modifiedAt: Date.now() - 90_000,
      owner: 'app',
    },
    {
      path: '/Users/asad/Library/Application Support/terminaldeck/copilot-layer/copilot.md',
      purpose: 'The two of them composed.',
      exists: true,
      size: 13_010,
      modifiedAt: Date.now() - 90_000,
      owner: 'app',
    },
  ],
}

const INSTRUCTIONS_TEXT = [
  '# Who you are',
  '',
  'You are Nova, the copilot for Terminal Deck.',
  '',
  '## Who they are',
  '',
  'Call them Asad.',
].join('\n')

const deckBridge = {
  copilotState: () => Promise.resolve(STATE),
  copilotFolder: () => Promise.resolve(STATE.folder),
  copilotReadInstructions: () =>
    Promise.resolve({ ok: true, text: INSTRUCTIONS_TEXT, state: 'edited', path: STATE.paths.layer.yours }),
  copilotWriteInstructions: () => Promise.resolve({ saved: true, backup: null, error: null }),
  copilotResetInstructions: () => Promise.resolve({ restored: true, backup: null, error: null }),
  copilotMemory: () => Promise.resolve({ dir: `${ROOT}/memory`, files: [], indexPath: null }),
  copilotActions: () => Promise.resolve({ path: STATE.paths.actions, entries: [] }),
  copilotReveal: () => Promise.resolve(null),
  routinesList: () => Promise.resolve([]),
  ensureCopilot: () => Promise.resolve(null),
  stopCopilot: () => Promise.resolve(null),
  scanReadiness: () => Promise.resolve(REPORT),
  applyReadinessFix: () => Promise.resolve({ ok: true, message: 'Written.', changed: ['CLAUDE.md'] }),
}

/**
 * The readiness report in the two states whose copy changed: no instructions
 * file at all (the fail branch, which lists the names it would accept), and one
 * that is present and fine (the pass branch, which names the real file it
 * found).
 */
const REPORT = {
  projectPath: ROOT,
  score: 62,
  band: 'fair' as const,
  cappedBy: null,
  scannedAt: new Date().toISOString(),
  checks: [
    {
      id: 'claude-md',
      title: 'Agent instructions present and useful',
      status: 'fail' as const,
      weight: 18,
      detail:
        'No instructions file — none of CLAUDE.md, .claude/CLAUDE.md or AGENTS.md is here. Every session starts by re-deriving your build commands, your layout and your conventions from scratch — slower, more expensive, and wrong more often.',
      fix: {
        id: 'create-claude-md',
        label: 'Create instructions file',
        description:
          'Writes an instructions skeleton at the project root — what this is, how to run it, how to test it, layout and conventions — each section left as a prompt for you to fill in. The file is CLAUDE.md. Refuses if one is already there.',
        touches: ['CLAUDE.md'],
        destructive: false,
      },
      gate: false,
    },
    {
      id: 'readme',
      title: 'README for humans',
      status: 'fail' as const,
      weight: 8,
      detail:
        'No README. It is the file an agent opens when the instructions file does not answer the question, and the one a new contributor opens first.',
      fix: {
        id: 'create-readme',
        label: 'Create README.md',
        description:
          'Writes a short README.md at the project root — title, one-line summary, install, run, test — with placeholders to fill in. Refuses if a README already exists.',
        touches: ['README.md'],
        destructive: false,
      },
      gate: false,
    },
    {
      id: 'test-script',
      title: 'Tests can be run with one command',
      status: 'pass' as const,
      weight: 14,
      detail: '`npm test` runs vitest.',
      fix: null,
      gate: false,
    },
  ],
}

function Board({ theme }: { theme: 'light' | 'dark' }) {
  return (
    <div
      data-theme={theme}
      style={{
        background: 'var(--bg-primary)',
        color: 'var(--text-primary)',
        padding: '24px',
        width: '760px',
        boxSizing: 'border-box',
      }}
    >
      <h2 style={{ font: 'var(--t-title2)', margin: '0 0 4px' }}>{theme}</h2>

      <p style={{ font: 'var(--t-caption1)', color: 'var(--text-tertiary)', margin: '0 0 16px' }}>
        CHOOSING_A_FOLDER, verbatim:
      </p>
      <p
        style={{
          font: 'var(--t-body)',
          color: 'var(--text-secondary)',
          background: 'var(--bg-secondary)',
          padding: '12px',
          borderRadius: '10px',
          margin: '0 0 24px',
        }}
      >
        {CHOOSING_A_FOLDER}
      </p>

      <div className="settings-pane">
        <CopilotSection />
      </div>

      <div style={{ marginTop: '32px' }}>
        <ReadinessPanel projectPath={ROOT} />
      </div>
    </div>
  )
}

// The pane resolves its own bridge off `window.deck`, the same as it does in
// the app. Set before the first render rather than passed as a prop, because
// `resolveCopilotBridge` runs in a `useMemo` on mount.
;(globalThis as unknown as { deck: unknown }).deck = deckBridge

createRoot(document.getElementById('root') as HTMLElement).render(
  <div style={{ display: 'flex', alignItems: 'flex-start' }}>
    <Board theme="light" />
    <Board theme="dark" />
  </div>,
)
