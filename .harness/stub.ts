/** A plausible preload bridge so the real App can render outside Electron. */
const noop = () => () => {}
/** When these sessions started, which is what decides whose transcript is whose. */
const launchedAt = Date.now()
const sessions = [
  { id: 's1', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck', provider: 'claude', exitCode: null, createdAt: launchedAt },
  { id: 's2', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck', provider: 'claude', exitCode: null, createdAt: launchedAt },
]
let sessionCounter = 0
/** Subscribers to `session:created`. See `onSessionCreated` below. */
const sessionCreatedListeners = new Set<(meta: unknown) => void>()
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
/**
 * The remote-access world, mutable so the panel's buttons do something.
 *
 * Shapes are the main process's: `Device` from `device-auth.ts` (a `status`,
 * not an `approved` flag), `RemoteConnection` and `TunnelInfo` from
 * `server.ts`/`tunnel.ts`. `tunnels` is the field that makes a phone's open
 * pages visible on the desktop, so one phone here has two — one busy, one idle
 * at zero sockets, because the row prints the count only for the busy one.
 */
const remote = {
  running: true,
  devices: [
    { id: 'dev-1', name: 'Asad’s iPhone', status: 'pending', addedAt: launchedAt - 40_000, lastSeenAt: launchedAt - 20_000, fingerprint: 'H4TC-8MKD-2QWX-7BNP-5ZRJ-9VFY' },
    { id: 'dev-2', name: 'iPad mini', status: 'approved', addedAt: launchedAt - 6 * 3_600_000, lastSeenAt: launchedAt - 90_000, fingerprint: 'B2WK-6HJN-4TDX-8CRM-3YFQ-7PZV' },
  ],
  connections: [
    {
      id: 'conn-1',
      deviceId: 'dev-2',
      deviceName: 'iPad mini',
      platform: 'iPadOS 26',
      address: 'relay:8Kd2Nq4Rt7Vw1Yb3',
      connectedAt: launchedAt - 12 * 60_000,
      sessionIds: ['s1'],
      tunnels: [
        { id: 'tun-1', port: 5173, streams: 3, openedAt: launchedAt - 4 * 60_000 },
        { id: 'tun-2', port: 8080, streams: 0, openedAt: launchedAt - 40_000 },
      ],
    },
  ],
}

/** `RemoteStatus`, rebuilt each read so the buttons above are visible in it. */
const remoteState = () => ({
  running: remote.running,
  url: remote.running ? 'https://asads-macbook-pro-1.taile59277.ts.net:8443' : null,
  address: remote.running ? '100.86.107.119' : null,
  port: 8443,
  reason: remote.running
    ? null
    : 'Tailscale is installed but this Mac is logged out of the tailnet. Open the Tailscale menu bar icon and sign in, then turn this on again.',
  directReason: null,
  relay: remote.running
    ? {
        url: 'wss://relay.terminaldeck.dev',
        hostId: 'AXGK7VAEYZHKTTVUKZ4U9HZQ7J',
        publicKey: 'Zm9vYmFyYmF6cXV1eGZvb2JhcmJhenF1dXhmb29iYXI',
        fingerprint: 'K7QM-3XTB-9WHD-2PVJ-6RNY-4CFG',
        connected: true,
        channels: remote.connections.length,
        reason: null,
        retryAt: null,
      }
    : null,
  connections: remote.running ? remote.connections : [],
})

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
    // `?onboarding` forces the first-run screen. It is the one view in the app
    // that cannot be reached by clicking — it appears only on a machine with no
    // agent CLI at all — so without a switch here it can never be looked at.
    checkPrerequisites: async () => ({
      canRunSessions: !new URLSearchParams(location.search).has('onboarding'),
      needsLogin: false,
      tools: [
        { id: 'claude', label: 'Claude Code', state: 'ready', version: '2.1.206', purpose: 'Run Claude Code sessions', required: false },
        { id: 'git', label: 'Git', state: 'ready', purpose: 'Branch and change tracking', required: false },
      ],
    }),
    detectProviders: async () => ({ claude: true, codex: true, gemini: true, shell: true }),
    listSessions: async () => sessions,
    getScrollback: async () => '',
    // A fresh id per call. A fixed one meant the second "New session" produced
    // a duplicate React key and the sidebar could never show more than one row.
    createSession: async (i: Record<string, unknown>) => ({
      ...sessions[0],
      id: `s-${(sessionCounter += 1)}`,
      title: `terminaldeck`,
      createdAt: Date.now(),
      ...i,
    }),
    killSession: async () => {},
    writeToSession: () => {},
    resizeSession: () => {},
    onSessionData: noop, onSessionExit: noop, onSessionStatus: noop,
    /**
     * A real subscription rather than a noop, because this is the one event
     * nothing in the window can provoke: `session:created` is broadcast only
     * for sessions this window did *not* ask for — a phone starting one. With
     * a noop here the arrival path can only be read, never seen, and the
     * failure it guards against (the new row stealing the focused tab) is a
     * render-time fact. Drive it from the console or a script with
     * `emitSessionCreated({ ... })`.
     */
    onSessionCreated: (cb: (meta: unknown) => void) => {
      sessionCreatedListeners.add(cb)
      return () => sessionCreatedListeners.delete(cb)
    },
    onCostUpdate: noop, onGitStatus: noop, onBrowserState: noop, onBrowserElement: noop,
    // A couple of real-looking dev servers, so the browser start page has
    // something to render in the harness.
    devPorts: async () => [
      { port: 5173, process: 'node', guessed: false },
      { port: 8080, process: '', guessed: true },
    ],
    // Remote access, in the shape `RemoteStatus` actually has — `reason` and
    // `directReason` are two different facts, and `relay` is null while the
    // server is stopped. The old fixture here carried a `tailnet` object the
    // main process has never sent, which is exactly the kind of stub that
    // invents bugs.
    //
    // Serving, with a phone attached and pages open on two of this Mac's ports:
    // a stopped server draws four sentences and no rows, so every list on this
    // panel — devices, attachments, tunnels — was unreachable from the app
    // harness. The states where nothing is up are still covered, and covered
    // better, by `remote.html`, which fixes them as props in both themes.
    remoteStatus: async () => remoteState(),
    startRemote: async () => {
      remote.running = true
      return remoteState()
    },
    stopRemote: async () => {
      remote.running = false
      return remoteState()
    },
    listRemoteDevices: async () => remote.devices,
    // `PairingToken` is a token and an expiry. It has never carried a URL: the
    // link is built in the renderer, from the status.
    startRemotePairing: async () => ({ token: 'stub-token', expiresAt: Date.now() + 60_000 }),
    cancelRemotePairing: async () => ({ ok: true }),
    // Each of these answers with the list the main process answers with, and
    // each actually changes it. A stub that returned `{ ok: true }` and left
    // the fixture alone made every button on this panel look broken in the
    // harness — pressed, cheerful sentence, row unchanged — which is the exact
    // symptom of the bug the panel's `settle` guard exists to catch.
    approveRemoteDevice: async (id: string) => {
      const device = remote.devices.find((d) => d.id === id)
      if (device && device.status !== 'revoked') device.status = 'approved'
      return remote.devices
    },
    revokeRemoteDevice: async (id: string) => {
      const device = remote.devices.find((d) => d.id === id)
      if (device) device.status = 'revoked'
      // Immediate, exactly as `remote:device:revoke` is: the socket goes with
      // the approval rather than at the next connection.
      remote.connections = remote.connections.filter((c) => c.deviceId !== id)
      return remote.devices
    },
    disconnectRemoteConnection: async (id: string) => {
      remote.connections = remote.connections.filter((c) => c.id !== id)
      return remote.connections
    },
    // Two ids, because a tunnel is only unique inside its own connection.
    stopRemoteTunnel: async (connectionId: string, tunnelId: string) => {
      const connection = remote.connections.find((c) => c.id === connectionId)
      if (connection) connection.tunnels = connection.tunnels.filter((t) => t.id !== tunnelId)
      return remote.connections
    },
    onRemoteConnections: noop,
    tailnetStatus: async () => ({
      ready: true,
      address: '100.86.107.119',
      address6: null,
      dnsName: 'asads-macbook-pro-1.taile59277.ts.net',
      hostName: 'asads-macbook-pro-1',
      tailnetName: 'taile59277.ts.net',
      magicDnsSuffix: 'taile59277.ts.net',
      magicDns: true,
      certsAvailable: false,
      binary: '/opt/homebrew/bin/tailscale',
    }),
    tailnetCert: async () => ({
      ok: false,
      reason: 'https-disabled',
      message:
        'Tailscale HTTPS certificates are off for this tailnet. Open the admin console DNS page and turn on HTTPS Certificates.',
    }),
    // The harness shows the state most users on an unsigned build will meet.
    // `?update=available|downloading|ready|error` picks a phase. Only
    // `unsupported` can be reached in the harness otherwise, and it is the one
    // phase with no tint — so the coloured washes on the banner were the only
    // part of it nobody could look at.
    updateStatus: async () => {
      const phase = new URLSearchParams(location.search).get('update')
      if (phase === 'available') return { phase, version: '0.2.0', notes: null }
      if (phase === 'downloading')
        return { phase, version: '0.2.0', percent: 42, bytesPerSecond: 1_500_000 }
      if (phase === 'ready') return { phase, version: '0.2.0' }
      if (phase === 'error') return { phase, message: 'The download stopped halfway.' }
      return {
        phase: 'unsupported',
        reason:
          'This build is not signed, so it cannot update itself. Download the latest version from the releases page.',
      }
    },
    checkForUpdate: async () => ({ phase: 'checking' }),
    downloadUpdate: async () => ({ phase: 'downloading', version: '0.2.0', percent: 42, bytesPerSecond: 1_500_000 }),
    installUpdate: async () => ({ phase: 'ready', version: '0.2.0' }),
    onUpdateState: noop,
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
    // A *complete* `McpInventory`. The short version — tools/resources/prompts
    // only — took the whole MCP page down through the error boundary the moment
    // a server was expanded: `countFor` reads `resourceTemplates.length`, and
    // the header reads `status`. Same class of bug as the short
    // `BrowserTabState` below; the real main process always sends all of it.
    mcpInventory: async (serverId: string) => ({
      serverId,
      tools: [],
      resources: [],
      resourceTemplates: [],
      prompts: [],
      errors: {},
      status: {
        id: serverId,
        name: serverId.split(':')[1] ?? serverId,
        scope: 'user',
        transport: 'stdio',
        command: 'npx',
        args: [],
        url: null,
        source: '~/.claude.json',
        enabled: true,
        disabledReason: null,
        // Honest about the harness: there is no process here to dial, so the
        // panel must draw its "could not connect" state rather than a
        // fabricated inventory.
        unsupported: null,
        state: 'error',
        error: 'The harness has no MCP server to dial, so nothing was listed.',
        serverInfo: null,
        capabilities: [],
        instructions: null,
        pid: null,
        connectedAt: null,
        stderr: '',
      },
    }),
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
    // How a session finds its own transcript rather than the folder's busiest
    // one — see `src/renderer/session-transcript.ts`. Two entries, not one, and
    // the older is the one still being written to: that is the shape that used
    // to put a stranger's conversation in a fresh tab, so it is the shape the
    // harness should be showing. The Proxy fallback would answer `null`, which
    // reads as "this project has never been opened" and exercises nothing.
    listSessionInsights: async () => [
      {
        path: '/tmp/harness/projects/stranger.jsonl',
        sessionId: '8ae018a8-ee80-4a6d-b960-19ffdb1f50a7',
        createdAt: launchedAt - 2 * 60 * 60 * 1000,
        // Still being written to, and by a wide margin the busiest file here.
        modifiedAt: Date.now(),
      },
      {
        path: '/tmp/harness/projects/own.jsonl',
        sessionId: 'aa11bb22-0000-4000-8000-000000000000',
        // Begun just after the harness's sessions did, so it is theirs.
        createdAt: launchedAt + 1,
        modifiedAt: launchedAt + 2000,
      },
    ],
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
      // The shape the real handler answers with. `false` here means "none of
      // the CLI's own markers are on this session's screen", which for the
      // harness's plain-shell sessions is the truth — so the account chip
      // shows a Run Claude button, which is the state item 1 is about.
      agent: { running: false, evidence: null, saw: null },
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

/**
 * Stand in for a phone starting a session on this Mac.
 *
 * The main process broadcasts `session:created` only to windows that did not
 * request the session, so there is no click anywhere in the app that produces
 * one. This is how the arrival is driven in the harness.
 */
;(globalThis as unknown as { emitSessionCreated: (meta?: Record<string, unknown>) => void })
  .emitSessionCreated = (meta = {}) => {
  const full = {
    ...sessions[0],
    id: `phone-${(sessionCounter += 1)}`,
    title: 'terminaldeck',
    createdAt: Date.now(),
    ...meta,
  }
  for (const listener of [...sessionCreatedListeners]) listener(full)
}
export {}
