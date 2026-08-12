/** A plausible preload bridge so the real App can render outside Electron. */
const noop = () => () => {}
const sessions = [
  { id: 's1', cwd: '/Users/apple/Projects/pawl', title: 'pawl', provider: 'claude', exitCode: null, createdAt: Date.now() },
  { id: 's2', cwd: '/Users/apple/Projects/pawl', title: 'pawl', provider: 'claude', exitCode: null, createdAt: Date.now() },
]
const api: Record<string, unknown> = new Proxy(
  {
    getBrand: async () => ({ name: 'Pawl', tagline: 'Run and watch your Claude sessions' }),
    getPreferences: async () => ({ theme: 'dark', defaultProvider: 'claude', restoreSessions: true, notifyOnComplete: true }),
    setPreferences: async (p: unknown) => p,
    getSettings: async () => ({}),
    setSettings: async (p: unknown) => p,
    settingsPaths: async () => ({ settings: '~/Library/Application Support/pawl/settings.json' }),
    appAbout: async () => ({ name: 'Pawl', version: '0.1.0' }),
    listProjects: async () => [{ path: '/Users/apple/Projects/pawl', lastOpenedAt: Date.now() }],
    checkPrerequisites: async () => ({
      canRunSessions: true,
      needsLogin: false,
      tools: [
        { id: 'claude', label: 'Claude Code', state: 'ready', version: '2.1.206', purpose: 'Run Claude Code sessions', required: false },
        { id: 'git', label: 'Git', state: 'ready', purpose: 'Branch and change tracking', required: false },
      ],
    }),
    detectProviders: async () => ({ claude: true, codex: true, gemini: true, shell: true }),
    listSessions: async () => sessions,
    getScrollback: async () => '',
    createSession: async (i: Record<string, unknown>) => ({ ...sessions[0], id: 'new', ...i }),
    killSession: async () => {},
    writeToSession: () => {},
    resizeSession: () => {},
    onSessionData: noop, onSessionExit: noop, onSessionStatus: noop,
    onCostUpdate: noop, onGitStatus: noop, onBrowserState: noop, onBrowserElement: noop,
    listProfiles: async () => ({ profiles: [{ id: 'default', name: 'Default', system: true }], defaultId: 'default' }),
    gitStatus: async () => ({ ok: false, kind: 'not-a-repo', message: 'Not a git repository.' }),
    githubOverview: async () => ({ ok: false, kind: 'no-remote', message: 'This repository has no remotes yet.' }),
    scanReadiness: async () => ({ score: 93, checks: [] }),
    projectAlerts: async () => ({ alerts: [] }),
    listDir: async () => ({ entries: [] }),
    hooksStatus: async () => [],
    listMcpServers: async () => [],
    connectMcpServer: async () => null,
    disconnectMcpServer: async () => null,
    mcpInventory: async () => ({ tools: [], resources: [], prompts: [] }),
    callMcpTool: async () => ({ ok: true, content: [] }),
    browserClaim: async () => ({ ok: true }),
    browserRelease: async () => {},
    browserZoom: async () => 1,
    browserCreate: async () => ({ id: 'b1', url: 'http://localhost:3000' }),
    browserCookies: async () => [],
    hooksStatus: async () => [],
    loadBoard: async () => null,
    loadDashboard: async () => null,
    getLatestSessionInsights: async () => null,
    searchSessions: async () => ({ hits: [] }),
    browserSessionInfo: async () => ({ partition: 'persist:pawl-browser', persistent: true }),
    listBrowsers: async () => ({ browsers: [] }),
  },
  {
    // Mirror the real preload's shape: on* methods are subscriptions that
    // return an unsubscribe function; everything else is a promise. Getting
    // this wrong is what made the harness disagree with Electron.
    get: (t: Record<string, unknown>, k: string) =>
      t[k] ?? (k.startsWith('on') ? () => () => {} : async () => null),
  },
)
;(globalThis as unknown as { pawl: unknown }).pawl = api
export {}
