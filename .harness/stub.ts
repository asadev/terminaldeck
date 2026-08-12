/** A plausible preload bridge so the real App can render outside Electron. */
const noop = () => () => {}
const sessions = [
  { id: 's1', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck', provider: 'claude', exitCode: null, createdAt: Date.now() },
  { id: 's2', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck', provider: 'claude', exitCode: null, createdAt: Date.now() },
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
    getBrand: async () => ({ name: 'Deck', tagline: 'Run and watch your Claude sessions' }),
    getPreferences: async () => ({ theme: 'dark', defaultProvider: 'claude', restoreSessions: true, notifyOnComplete: true }),
    setPreferences: async (p: unknown) => p,
    getSettings: async () => ({}),
    setSettings: async (p: unknown) => p,
    settingsPaths: async () => ({ settings: '~/Library/Application Support/terminaldeck/settings.json' }),
    appAbout: async () => ({ name: 'Deck', version: '0.1.0' }),
    listProjects: async () => [{ path: '/Users/apple/Projects/terminaldeck', lastOpenedAt: Date.now() }],
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
    onPlanLimits: noop,
    // The harness has no live session, so the plan half reports "not available"
    // — which is the state worth being able to look at anyway.
    watchPlanLimits: async () => null,
    refreshPlanLimits: async () => ({ ok: false, reason: 'unwired', snapshot: null }),
    unwatchPlanLimits: () => {},
    listProfiles: async () => ({ profiles: [{ id: 'default', name: 'Default', system: true }], defaultId: 'default' }),
    gitStatus: async () => ({ ok: false, kind: 'not-a-repo', message: 'Not a git repository.' }),
    githubOverview: async () => ({ ok: false, kind: 'no-remote', message: 'This repository has no remotes yet.' }),
    scanReadiness: async () => ({ score: 93, checks: [] }),
    projectAlerts: async () => ({ alerts: [] }),
    listDir: async () => ({ entries: [] }),
    hooksStatus: async () => [],
    // Complete `McpServerStatus` rows, not a name and a flag. The composer's
    // connector list reads `enabled` and `disabledReason` to explain a server
    // the CLI would skip, and a stub that omits them would make that branch
    // look untested when it is the interesting one.
    listMcpServers: async () => [
      {
        id: 'user:github', name: 'github', scope: 'user', transport: 'stdio',
        command: 'npx', args: [], env: {}, cwd: null, url: null,
        source: '~/.claude.json', enabled: true, disabledReason: null, unsupported: null,
        state: 'idle', error: null, serverInfo: null, capabilities: [], instructions: null,
        pid: null, connectedAt: null, stderr: '',
      },
      {
        id: 'project:figma', name: 'figma', scope: 'project', transport: 'sse',
        command: null, args: [], env: {}, cwd: null, url: 'https://mcp.figma.example/sse',
        source: '.mcp.json', enabled: false, disabledReason: 'not approved for this project',
        unsupported: 'only stdio servers can be dialled from here',
        state: 'idle', error: null, serverInfo: null, capabilities: [], instructions: null,
        pid: null, connectedAt: null, stderr: '',
      },
    ],
    // The project file index, in its real `FileSearchResponse` shape. The
    // attach picker ranks this list locally on every keystroke.
    searchProjectFiles: async () => ({
      ok: true,
      root: '/Users/apple/Projects/terminaldeck',
      files: [
        'README.md', 'ROADMAP.md', 'package.json', 'electron-builder.yml',
        'build/icon.png', 'build/dmg-background.png',
        'src/main/index.ts', 'src/main/pty-manager.ts', 'src/main/chat-transcript.ts',
        'src/main/mcp-client.ts', 'src/main/file-search.ts', 'src/main/git.ts',
        'src/preload/index.ts', 'src/shared/types.ts', 'src/shared/brand.ts',
        'src/renderer/App.tsx', 'src/renderer/styles/tokens.css',
        'src/renderer/components/ChatView.tsx', 'src/renderer/components/ChatComposer.tsx',
        'src/renderer/components/CommandPalette.tsx', 'src/renderer/components/SessionInspector.tsx',
        'src/renderer/chat/attach/mentions.ts', 'src/renderer/chat/attach/AttachPicker.tsx',
        'src/renderer/assets/screenshot-empty-state.png',
      ],
      truncated: false,
      source: 'git',
      tookMs: 14,
    }),
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
    // The control row's readings. The harness has no pty and no Claude settings
    // file, so the only truthful answer is that nothing could be read — which
    // is exactly the state worth being able to look at, because "Unknown" is
    // what the row must show rather than a plausible default.
    readAgentControls: async () => ({
      model: { value: null, label: null, source: null },
      effort: { value: null, label: null, source: null },
      fast: { value: null, label: null, source: null },
      permission: { value: null, label: null, source: null },
      live: false,
    }),
    applyAgentControl: async () => ({
      ok: false,
      message: 'The harness has no terminal to type into, so nothing was changed.',
      reading: { value: null, label: null, source: null },
    }),
    browserSessionInfo: async () => ({ partition: 'persist:terminaldeck-browser', persistent: true }),
    listBrowsers: async () => ({ browsers: [] }),
    // Per-tab isolation. The Proxy's fallback would resolve these to null, and
    // a null key is indistinguishable from "this build cannot do it" — so the
    // toggle would appear and then refuse to work, which is a bug the harness
    // would be inventing rather than finding.
    browserIsolationKey: async () => `terminaldeck-tab-${crypto.randomUUID()}`,
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
;(globalThis as unknown as { terminaldeck: unknown }).deck = api
export {}
