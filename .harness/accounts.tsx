/**
 * The Accounts list, on its own, in a real browser — with ten Claude logins.
 *
 * The brief for this page is Asad's: *"cannot add as many accounts as we want"*.
 * So the state worth looking at is not two accounts, it is many: ten Claude
 * Code logins the app keeps itself, two Codex ones, an Add that was never
 * finished, an account that turned out to be a second copy of another's login,
 * and sessions running on several of them. `?add=1` opens the Add-account popup
 * over it; `?add=unfinished` opens it with the unfinished address already typed
 * in is not possible from props, so that state is pinned by tests instead.
 *
 * One theme per load — `?theme=light` — for the reason `deleteconfirm.tsx`
 * gives: the popup portals into `<body>`, so the theme has to be on the root.
 */
import './stub'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import '../src/renderer/settings/SettingsWindow.css'
import { AccountsView } from '../src/renderer/settings/sections/AccountsSection'
import { AddAccountsMenu } from '../src/renderer/settings/sections/AgentsSection'
import type { AccountView, SignInView } from '../src/renderer/accounts'
import { buildAccountProviderRows, type AccountProviderRow } from '../src/renderer/components/ProviderPicker'

const params = new URLSearchParams(location.search)
const theme = params.get('theme') === 'light' ? 'light' : 'dark'
document.documentElement.dataset.theme = theme

const COLORS = ['--accent', '--status-completed', '--status-waiting', '--status-input', '--color-warning', '--color-critical']
const ROOT = '/Users/you/Library/Application Support/terminaldeck/profiles'

const accounts: AccountView[] = [
  { id: 'system', name: 'Default', provider: 'claude', configDir: '/Users/you/.claude', system: true, color: COLORS[0], lastUsedAt: null, keptBy: 'agent', keptSignedIn: null },
  ...Array.from({ length: 10 }, (_, i): AccountView => ({
    id: `claude-${i + 1}`,
    name: `team${i + 1}@example.com`,
    provider: 'claude',
    configDir: `${ROOT}/team${i + 1}-example-com`,
    system: false,
    color: COLORS[(i + 1) % COLORS.length],
    lastUsedAt: Date.now() - i * 3_600_000,
    keptBy: 'app',
    keptSignedIn: i !== 9,
  })),
  // An account added while the browser was still signed in to team2 — so it
  // holds team2's login under another name.
  { id: 'copy', name: 'new@example.com', provider: 'claude', configDir: `${ROOT}/new-example-com`, system: false, color: COLORS[3], lastUsedAt: null, keptBy: 'app', keptSignedIn: true },
  { id: 'system:codex', name: 'Default (Codex CLI)', provider: 'codex', configDir: '/Users/you/.codex', system: true, color: COLORS[1], lastUsedAt: null, keptBy: 'agent', keptSignedIn: null },
  { id: 'codex-1', name: 'work@example.com', provider: 'codex', configDir: `${ROOT}/work-example-com`, system: false, color: COLORS[2], lastUsedAt: null, keptBy: 'app', keptSignedIn: true },
  { id: 'codex-2', name: 'side@example.com', provider: 'codex', configDir: `${ROOT}/side-example-com`, system: false, color: COLORS[4], lastUsedAt: null, keptBy: 'app', keptSignedIn: true },
]

const signedIn = (account: string | null, plan: string | null = 'max'): SignInView => ({
  state: 'signed-in',
  account,
  plan,
  detail: account ? `Signed in as ${account}` : `Signed in using ${plan}`,
  command: '',
})

const signIn: Record<string, SignInView> = {
  system: signedIn('app.imatch.ae@gmail.com'),
  'system:codex': signedIn(null, 'ChatGPT'),
  'codex-1': signedIn(null, 'ChatGPT'),
  'codex-2': signedIn(null, 'ChatGPT'),
  copy: signedIn('team2@example.com'),
  'claude-10': {
    state: 'signed-out',
    account: null,
    plan: null,
    detail: 'Not signed in. Sign in to it here, and this app keeps the login.',
    command: '',
  },
}
for (let i = 1; i <= 9; i++) signIn[`claude-${i}`] = signedIn(`team${i}@example.com`, i % 3 === 0 ? 'pro' : 'max')

/*
 * Built by the app's own function from the two answers it is built from in the
 * app — what detection found, and what `profiles:account-providers` says — so
 * the rows here are the rows the real pane gets, field for field.
 */
const providerRows: AccountProviderRow[] = buildAccountProviderRows({ claude: true, codex: true, gemini: false, shell: true }, [
  { id: 'claude', label: 'Claude Code', supported: true, canSignIn: true, configEnv: 'CLAUDE_CONFIG_DIR', reason: null },
  { id: 'codex', label: 'Codex CLI', supported: true, canSignIn: true, configEnv: 'CODEX_HOME', reason: null },
  {
    id: 'gemini',
    label: 'Gemini CLI',
    supported: false,
    canSignIn: true,
    configEnv: 'GEMINI_CLI_HOME',
    reason: 'Gemini keeps one login per machine.',
  },
])

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <div className="settings-panel" style={{ height: '100vh', background: 'var(--bg-primary)' }}>
      <AccountsView
        head={params.get("head") === "1"}
        addingInitially={params.get('add') === '1'}
        addingProvider={params.get('add') === '1' ? 'claude' : null}
        snapshot={{ accounts, defaultId: null, projectDefaults: {}, inherited: [], machine: 'Mac mini' }}
        signIn={signIn}
        loading={false}
        error={null}
        available
        busy={false}
        providerRows={providerRows}
        onSignIn={() => undefined}
        onSignOut={() => undefined}
        onSignInNew={() => undefined}
        onRename={() => undefined}
        onRemove={() => undefined}
        onMakeDefault={() => undefined}
        sessionsByAccount={{
          'claude-1': ['api-server', 'web'],
          'claude-2': ['billing'],
          'claude-4': ['docs', 'mobile', 'infra', 'data'],
          'codex-1': ['scripts'],
        }}
        addAccounts={
          <AddAccountsMenu
            present={new Set(['claude', 'codex'])}
            addable={new Set(['claude', 'codex'])}
            // Nothing has answered yet — the state that used to hide Add account.
            signedIn={new Set()}
            signInable={new Set(['claude', 'codex'])}
            hasAccounts={new Set(['claude', 'codex'])}
            onAddAccount={() => undefined}
            onSignIn={() => undefined}
          />
        }
      />
    </div>
  </StrictMode>,
)
