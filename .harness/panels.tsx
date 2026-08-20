/**
 * The three panel surfaces from the 2026-08-20 review, in a real browser.
 *
 * Every one of them has a state that cannot be reached from a static render and
 * that shipped wrong because of it:
 *
 *  - **GitHub → Issues, on a repository whose issues are switched off.** It drew
 *    a red "GitHub request failed" with a Retry that could never succeed. Only
 *    a rendered page shows that it now reads as an ordinary empty list.
 *  - **MCP servers with a list.** The rows only exist after the bridge answers,
 *    so the Remove control cannot be seen in `renderToStaticMarkup` at all —
 *    which is why the panel could tell people to use a terminal for a year.
 *  - **The copilot's machine switch with a server on it.**
 *
 * `?panel=github|mcp|copilot` picks one; the default draws all three stacked.
 */
import './stub'
import { StrictMode, useState } from 'react'
import { createRoot } from 'react-dom/client'
import '../src/renderer/styles/tokens.css'
import '../src/renderer/styles/app.css'
import { GitHubPanel, type GitHubBridge } from '../src/renderer/components/GitHubPanel'
import {
  McpInspector,
  type McpBridge,
  type McpInventory,
  type McpServerStatus,
} from '../src/renderer/components/McpInspector'
import { CopilotMachines } from '../src/renderer/copilot/CopilotMachines'
import { useCopilotMachines } from '../src/renderer/copilot/useCopilotMachines'

const CWD = '/Users/apple/Projects/terminaldeck'

/*
 * One stored server, on this page only.
 *
 * `stub.ts` answers an empty server list and stays that way — it is shared by
 * every harness page, and a server appearing in the New Session picker because
 * this page wanted one would be exactly the kind of stub-invented state
 * `CLAUDE.md` warns about. The copilot switch is the surface that needs one, so
 * it is overridden here.
 */
const deck = (globalThis as { deck?: Record<string, unknown> }).deck
if (deck) {
  deck.listServers = async () => [
    { id: 's1', name: 'imza-vps', address: '203.0.113.10', username: 'root' },
  ]
}

/* ------------------------------------------------------------------ github -- */

const REPO = { host: 'github.com', owner: 'multica-ai', name: 'andrej-karpathy-skills', nameWithOwner: 'multica-ai/andrej-karpathy-skills' }

const AUTH = {
  ok: true as const,
  connected: true,
  host: 'github.com',
  source: 'gh-cli' as const,
  identity: { login: 'asadev', name: 'Asad', htmlUrl: 'https://github.com/asadev' },
  scopes: [],
  scopesReported: false,
  disconnect: 'Signs the GitHub CLI out on this machine, so your terminal is signed out too.',
  credentialKind: 'github-app' as const,
  installUrl: null,
  repo: REPO,
  branch: { name: 'main', head: 'abc1234', detached: false },
  access: { ok: true as const, repos: [], truncated: false, atLeast: 0, readAt: Date.now() },
} as unknown as Awaited<ReturnType<GitHubBridge['githubAuthStatus']>>

/** Issues off on GitHub, pull requests fine — the exact state that drew a red error. */
const OVERVIEW = {
  ok: true as const,
  cwd: CWD,
  repo: REPO,
  pulls: { ok: true as const, value: [] },
  issues: {
    ok: false as const,
    kind: 'issues-disabled' as const,
    message: 'Issues are off for this repository.',
    action: null,
    detail: "the 'multica-ai/andrej-karpathy-skills' repository has disabled issues",
  },
  limit: 20,
  fetchedAt: Date.now(),
}

const githubBridge: GitHubBridge = {
  githubOverview: async () => OVERVIEW,
  githubRefresh: async () => OVERVIEW,
  githubAuthStatus: async () => AUTH,
  githubConnect: async () => ({ ok: false, kind: 'auth-unavailable', message: '', action: null, detail: '' }),
  githubAwaitConnect: async () => AUTH,
  githubCancelConnect: async () => AUTH,
  githubDisconnect: async () => AUTH,
}

/* --------------------------------------------------------------------- mcp -- */

function server(overrides: Partial<McpServerStatus> = {}): McpServerStatus {
  return {
    id: 'user:auditprobe',
    name: 'auditprobe',
    scope: 'user',
    transport: 'stdio',
    command: 'node',
    args: ['/private/tmp/tdaudit-mcp/server.mjs'],
    url: null,
    source: '/Users/apple/.claude.json',
    enabled: true,
    disabledReason: null,
    unsupported: null,
    state: 'idle',
    error: null,
    serverInfo: null,
    capabilities: [],
    instructions: null,
    pid: null,
    connectedAt: null,
    stderr: '',
    ...overrides,
  }
}

const inventory = (id: string): McpInventory => ({
  serverId: id,
  tools: [{ name: 'echo', title: null, description: null, inputSchema: {}, outputSchema: null }],
  resources: [],
  resourceTemplates: [],
  prompts: [],
  errors: {},
  status: server({ id, state: 'ready', pid: 11755, serverInfo: { name: 'audit-probe', version: '1.0.0' } }),
})

function mcpBridge(): McpBridge {
  let rows = [server(), server({ id: 'local:files', name: 'files', scope: 'local', command: 'npx' })]
  return {
    listMcpServers: async () => rows,
    addMcpServer: async () => ({ ok: true, message: 'Added stdio MCP server files to user config' }),
    removeMcpServer: async (request) => {
      rows = rows.filter((row) => row.name !== request.name)
      return { ok: true, message: 'Removed.' }
    },
    connectMcpServer: async (id) => server({ id, state: 'ready' }),
    disconnectMcpServer: async () => null,
    mcpInventory: async (id) => inventory(id),
    callMcpTool: async () => ({ ok: true, result: null, error: null, durationMs: 2, truncated: false }),
    onMcpState: () => () => undefined,
  }
}

/* ----------------------------------------------------------------- copilot -- */

const MACHINES = [
  { id: '', name: 'this Mac', reach: 'ready' as const, open: true },
  { id: 'm1', name: 'MacBookPro', reach: 'ready' as const, open: true },
  { id: 'server s1', name: 'imza-vps', reach: 'server' as const, open: false },
]

/* -------------------------------------------------------------------------- */

function LiveSwitch() {
  const machines = useCopilotMachines()
  const [chosen, setChosen] = useState('')
  return (
    <div style={{ width: 720 }}>
      <CopilotMachines machines={machines} chosen={chosen} onChoose={setChosen} />
      <pre id="rows" style={{ color: 'var(--text-secondary)', font: '12px ui-monospace, monospace' }}>
        {machines.map((row) => `${row.name} · ${row.reach}`).join('\n')}
      </pre>
    </div>
  )
}

function Page() {
  const only = new URLSearchParams(location.search).get('panel')
  const [chosen, setChosen] = useState('')
  const [bridge] = useState(mcpBridge)
  const show = (name: string) => only === null || only === name
  return (
    <div style={{ display: 'grid', gap: 24, padding: 16, background: 'var(--bg-app)', minHeight: '100vh' }}>
      {show('github') && (
        <div style={{ width: 720 }}>
          <GitHubPanel cwd={CWD} bridge={githubBridge} initialTab="issues" now={Date.now()} />
        </div>
      )}
      {show('mcp') && (
        <div style={{ width: 720 }}>
          <McpInspector bridge={bridge} projectPath={CWD} />
        </div>
      )}
      {show('copilot') && (
        <div style={{ width: 720 }}>
          <CopilotMachines machines={MACHINES} chosen={chosen} onChoose={setChosen} />
        </div>
      )}
      {/* The same switch built by the hook off the stub bridge, which is the
          half that had no reference to servers at all until now. */}
      {show('live') && <LiveSwitch />}
    </div>
  )
}

createRoot(document.getElementById('root') as HTMLElement).render(
  <StrictMode>
    <Page />
  </StrictMode>,
)
