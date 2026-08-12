/** A plausible preload bridge so the real App can render outside Electron. */
const noop = () => () => {}
const sessions = [
  { id: 's1', cwd: '/Users/apple/Projects/pawl', title: 'pawl', provider: 'claude', exitCode: null, createdAt: Date.now() },
  { id: 's2', cwd: '/Users/apple/Projects/pawl', title: 'pawl', provider: 'claude', exitCode: null, createdAt: Date.now() },
]
/** Mirrors `BrowserTabState` in `src/main/browser-tab.ts` — every field of it. */
const browserTabState = {
  id: 'b1',
  url: 'http://localhost:3000/',
  label: 'localhost:3000',
  title: 'Dev server',
  loading: false,
  canGoBack: false,
  canGoForward: false,
  inspecting: false,
  error: null,
}
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
    // A *complete* BrowserTabState. The short version — `{ id, url }` — took the
    // whole browser panel down through an error boundary: `patchFrom` copies
    // every field onto the strip entry, so a missing `title` overwrote the real
    // empty string with undefined and `tabTitle` threw on `.trim()`. The real
    // main process always sends all of it; a stub that sends less invents a bug.
    browserCreate: async () => browserTabState,
    browserNavigate: async () => browserTabState,
    browserBack: async () => browserTabState,
    browserForward: async () => browserTabState,
    browserReload: async () => browserTabState,
    browserStop: async () => browserTabState,
    browserInspect: async () => browserTabState,
    browserState: async () => browserTabState,
    browserCookies: async () => [],
    hooksStatus: async () => [],
    loadBoard: async () => null,
    loadDashboard: async () => null,
    getLatestSessionInsights: async () => null,
    searchSessions: async () => ({ hits: [] }),
    // Chat view. The Proxy's fallback resolves an unknown method to `null`, and
    // `null.found` throws inside a promise — the pane would go down through the
    // error boundary and look broken rather than empty. A complete `ChatUpdate`
    // is the honest answer: the harness has no transcript store, so `found` is
    // false and the view shows its "no transcript yet" state.
    loadChat: async () => ({
      transcriptPath: '', sessionId: '', cwd: '', messages: [],
      reset: false, cursor: 0, found: false, complete: true, updatedAt: Date.now(),
    }),
    tailChat: async () => ({
      transcriptPath: '', sessionId: '', cwd: '', messages: [],
      reset: false, cursor: 0, found: false, complete: true, updatedAt: Date.now(),
    }),
    closeChat: () => {},
    browserSessionInfo: async () => ({ partition: 'persist:pawl-browser', persistent: true }),
    listBrowsers: async () => ({ browsers: [] }),
    // Per-tab isolation. The Proxy's fallback would resolve these to null, and
    // a null key is indistinguishable from "this build cannot do it" — so the
    // toggle would appear and then refuse to work, which is a bug the harness
    // would be inventing rather than finding.
    browserIsolationKey: async () => `pawl-tab-${crypto.randomUUID()}`,
    browserIsolationDispose: async () => {},
    // Cookie import. Deliberately the "nothing found" answer rather than a
    // fabricated success: a stub that pretends to import cookies would make the
    // count line and the Clear button look tested when neither had run.
    browserCookieSources: async () => [],
    browserCookieImportStatus: async () => ({
      present: 0,
      recorded: 0,
      importedAt: null,
      source: '',
      supported: true,
    }),
    importBrowserCookies: async () => ({
      ok: false,
      imported: 0,
      skipped: 0,
      failed: 0,
      domains: 0,
      keychain: null,
      message: 'The harness has no keychain, so nothing was imported.',
    }),
    clearImportedCookies: async () => ({ removed: 0 }),
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
