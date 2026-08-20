/**
 * Settings → Coding AI, without Electron.
 *
 *     npx vite --config .harness/vite.config.ts --port 5223
 *     open http://localhost:5223/coding.html
 *
 * The whole pane, in the real `SettingsPanel`, so the pane's own scroll
 * container and its footer are on screen — which is what NEW-2 is about: a row
 * menu near the bottom of the list is clipped by that footer, and no test that
 * renders the section on its own can see it.
 *
 * Query flags:
 *   ?accounts=many   six logins, so the last row sits under the footer
 *   ?accounts=one    a fresh machine: one system account per installed agent
 *   ?agents=claude   only Claude Code on this machine
 *   ?signedout       every account signed out, which is the state D9 is about
 */
import { createRoot } from 'react-dom/client'
import { SettingsWindow } from '../src/renderer/settings/SettingsWindow'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'
import '../src/renderer/shell/shell.css'

const q = new URLSearchParams(location.search)
const many = q.get('accounts') === 'many'
const signedOut = q.has('signedout')
const onlyClaude = q.get('agents') === 'claude'

const AGENTS = onlyClaude ? ['claude'] : ['claude', 'codex', 'gemini']

const TOOLS = [
  {
    id: 'claude',
    label: 'Claude Code',
    state: 'ready',
    version: '2.1.237',
    purpose: 'Run Claude Code sessions',
    required: true,
  },
  {
    id: 'codex',
    label: 'Codex CLI',
    state: 'ready',
    version: 'codex-cli 0.146.0-alpha.3.1',
    purpose: 'Run Codex sessions',
    note:
      'The `codex` on your PATH will not start, so Codex CLI runs from /Users/apple/.codex/plugins/.plugin-appserver/codex instead. Reinstalling with `npm install -g @openai/codex` would fix the one on your PATH.',
    required: false,
  },
  {
    id: 'gemini',
    label: 'Gemini CLI',
    state: 'ready',
    version: '0.46.0',
    purpose: 'Run Gemini sessions',
    required: false,
  },
].filter((tool) => AGENTS.includes(tool.id))

const SETUP_TOOLS = [
  ...TOOLS,
  {
    id: 'git',
    label: 'Git',
    state: 'ready',
    version: '2.51.0',
    purpose: 'Read branches and diffs for the source control panel',
    required: true,
  },
  {
    id: 'gh',
    label: 'GitHub CLI',
    state: 'missing',
    purpose: 'Read issues and pull requests without a token of your own',
    remedy: 'Install it with `brew install gh`, then sign in with `gh auth login`.',
    probe: { command: 'gh --version', line: 'gh: command not found' },
    url: 'https://cli.github.com',
    required: false,
  },
]

interface Row {
  id: string
  name: string
  provider: string | null
  configDir: string
  system: boolean
  color: string
}

const base: Row[] = [
  { id: 'system', name: 'Default', provider: 'claude', configDir: '/Users/apple/.claude', system: true, color: '--color-claude' },
  ...(AGENTS.includes('codex')
    ? [{ id: 'system-codex', name: 'Default (Codex CLI)', provider: 'codex', configDir: '/Users/apple/.codex', system: true, color: '--color-codex' }]
    : []),
  ...(AGENTS.includes('gemini')
    ? [{ id: 'system-gemini', name: 'Default (Gemini CLI)', provider: 'gemini', configDir: '/Users/apple/.gemini', system: true, color: '--color-gemini' }]
    : []),
]

const extra: Row[] = many
  ? [
      { id: 'work', name: 'Work', provider: 'claude', configDir: '/Users/apple/Library/Application Support/terminaldeck/profiles/work', system: false, color: '--color-blue' },
      { id: 'imza', name: 'Imza', provider: 'claude', configDir: '/Users/apple/Library/Application Support/terminaldeck/profiles/imza', system: false, color: '--color-green' },
      { id: 'second', name: 'second', provider: 'codex', configDir: '/Users/apple/Library/Application Support/terminaldeck/profiles/second', system: false, color: '--color-orange' },
    ]
  : []

let rows: Row[] = [...base, ...extra]
let defaultId: string | null = 'system'

const SIGNED_IN: Record<string, { account: string; plan: string }> = {
  system: { account: 'asadiqbalonline@gmail.com', plan: 'max' },
  'system-codex': { account: 'asad@imza.ae', plan: 'plus' },
  'system-gemini': { account: 'asadiqbalonline@gmail.com', plan: 'free' },
  work: { account: 'app.imatch.ae', plan: 'max' },
  imza: { account: 'ops@imza.ae', plan: 'max' },
}

const after = <T,>(value: T, ms = 120): Promise<T> =>
  new Promise((resolve) => setTimeout(() => resolve(value), ms))

const deck = {
  listProfiles: () => after({ profiles: rows, defaultProfileId: defaultId }),
  accountProviders: () =>
    after([
      { id: 'claude', supported: true },
      { id: 'codex', supported: true },
      { id: 'gemini', supported: false, reason: 'Gemini CLI keeps one login per machine.' },
    ]),
  detectProviders: () =>
    after(Object.fromEntries(['claude', 'codex', 'gemini'].map((id) => [id, AGENTS.includes(id)]))),
  createProfile: (name: string, options?: { provider?: string }) => {
    const id = `p${rows.length}`
    rows = [...rows, { id, name, provider: options?.provider ?? 'claude', configDir: `/Users/apple/Library/Application Support/terminaldeck/profiles/${id}`, system: false, color: '--color-purple' }]
    return after({ id })
  },
  renameProfile: (id: string, name: string) => {
    rows = rows.map((row) => (row.id === id ? { ...row, name } : row))
    return after({ ok: true })
  },
  deleteProfile: (id: string) => {
    rows = rows.filter((row) => row.id !== id)
    return after({ ok: true })
  },
  setDefaultProfile: (id: string | null) => {
    defaultId = id
    return after({ profiles: rows, defaultProfileId: defaultId })
  },
  setProjectDefaultProfile: () => after({ ok: true }),
  profileSignIn: (id: string) => {
    const known = signedOut ? undefined : SIGNED_IN[id]
    return after(
      known
        ? { state: 'signed-in', account: known.account, plan: known.plan, detail: `Signed in as ${known.account}`, command: 'claude auth status' }
        : { state: 'signed-out', account: null, plan: null, detail: 'Not signed in', command: 'claude auth status' },
      200,
    )
  },
  sessionAccount: () => after(null),
  accountHistoryState: (id: string) =>
    after({
      state: { link: id === 'system' ? 'separate' : 'shared', root: '/Users/apple/.claude/projects', ownProjects: 4 },
      share: 'Sharing points this account at the same conversations.',
      unshare: 'Its own conversations come back.',
      remove: 'Nothing is deleted: this account keeps no conversations of its own.',
    }),
  shareAccountHistory: (id: string) => after({ state: { link: 'shared', root: '/Users/apple/.claude/projects', ownProjects: 0 } }),
  unshareAccountHistory: () => after({ state: { link: 'separate', root: '', ownProjects: 0 } }),

  getSettings: () => after({ 'agents.defaultProvider': 'claude', 'general.defaultProvider': 'claude', 'appearance.density': 'comfortable', 'appearance.theme': 'dark' }),
  setSettings: (patch: Record<string, unknown>) => after(patch),
  resetSettings: () => after({}),
  getPreferences: () => after({}),
  setPreferences: (patch: Record<string, unknown>) => after(patch),
  onPreferencesChanged: () => () => {},
  onSettingsChanged: () => () => {},
  settingsPaths: () => after({}),
  openSettingsPath: () => after({}),
  appAbout: () => after({ name: 'Terminal Deck', version: '0.7.0' }),
  getBrand: () => after({ name: 'Terminal Deck' }),
  checkPrerequisites: () => after({ tools: TOOLS, canRunSessions: true, needsLogin: false }),
  setupStatus: () => after({ tools: SETUP_TOOLS, canRunSessions: true, needsLogin: false, hooks: [] }),
  features: () => after({}),
}

;(globalThis as unknown as { deck: unknown }).deck = deck

createRoot(document.getElementById('root')!).render(
  <SettingsWindow
    open
    onClose={() => console.log('close')}
    initialSection="agents"
    platform="mac"
    onStartSession={(request) => console.log('startSession', request)}
  />,
)
