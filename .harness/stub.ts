/** A plausible preload bridge so the real App can render outside Electron. */
// The one splitter, shared with the renderer and the main process. See the note
// on `addAgent` below for what happened when this file had its own.
import {
  customAgentId,
  draftIsValid,
  parseDraft,
  splitArgs,
  validateDraft,
} from '../src/shared/custom-agents'
import { AGENT_ENTRIES } from '../src/shared/agent-catalog'

const noop = () => () => {}
/** When these sessions started, which is what decides whose transcript is whose. */
const launchedAt = Date.now()
/**
 * The session list, in the four shapes the rail and the Overview board have to
 * tell apart. Every field is `SessionMeta`'s.
 *
 * `profileId`/`profileName` are the account the main process resolved at spawn,
 * and they are here because leaving them out hid two defects for as long as this
 * harness has existed: the rail and the board both printed `profileName` raw,
 * which for the machine's own install is the generated key `Default`, and with
 * no account on any session neither surface ever drew that column.
 *
 * The last two carry the *same* agent-written title in the same folder on the
 * same account, which is not a contrived case — it is what two agents given one
 * task actually write, and it is what was reported from the rail: two rows with
 * nothing on screen to tell them apart.
 */
const shellDefault = new URLSearchParams(location.search).has('shell')
const sessions = [
  // Under `?shell` the first session is a plain shell — which is a session with
  // no account at all, because there is no configuration directory to hand a
  // shell. That absence is the state the chip has to describe honestly.
  shellDefault
    ? { id: 's1', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck', provider: 'shell', exitCode: null, createdAt: launchedAt }
    : { id: 's1', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck', provider: 'claude', exitCode: null, createdAt: launchedAt, profileId: 'system', profileName: 'Default' },
  { id: 's2', cwd: '/Users/apple/Projects/terminaldeck', title: 'terminaldeck', provider: 'claude', exitCode: null, createdAt: launchedAt, profileId: 'work', profileName: 'Work' },
  { id: '7f3c9a21-6d40-4a1e-9d2b-1a5f0c3e7b81', cwd: '/Users/apple/Projects/terminaldeck', title: 'Update Claude Code terminal to new API', provider: 'claude', exitCode: null, createdAt: launchedAt, profileId: 'system', profileName: 'Default' },
  { id: 'b4e1d508-2c77-4f93-8a10-9e6b2d4c5a03', cwd: '/Users/apple/Projects/terminaldeck', title: 'Update Claude Code terminal to new API', provider: 'claude', exitCode: null, createdAt: launchedAt, profileId: 'system', profileName: 'Default' },
]
let sessionCounter = 0
/**
 * The agents "added" in this browser session. See `addAgent` below.
 *
 * Module-level and mutable, because the plus button's whole point is that the
 * list gets longer, and a list that resets between calls would let the form be
 * submitted and then show the same four rows back.
 */
let addedAgents: Array<Record<string, unknown>> = []
/** Subscribers to `session:created`. See `onSessionCreated` below. */
const sessionCreatedListeners = new Set<(meta: unknown) => void>()
/**
 * Subscribers to the copilot's confirmation push.
 *
 * Held for the same reason the set above is: the main process raises these, so
 * there is no click anywhere in the app that produces one, and without a driver
 * the one dialog that stands between an agent and your settings could never be
 * looked at outside Electron. See `emitCopilotConsent` at the bottom.
 */
const consentListeners = new Set<(request: unknown) => void>()
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
    /*
     * `?shell` sets the default coding tool to a plain shell.
     *
     * The same kind of switch as `?onboarding` below, and for the same reason:
     * it is a setting, not an edge case, and it puts the window into a state
     * that cannot be reached by clicking in the harness — the one where a new
     * session here would run an agent that has no account to be given. The
     * account chip has to say so *and* not name an account in the same breath,
     * which is exactly the pair of statements that were contradicting each other.
     */
    getPreferences: async () => ({
      theme: 'dark',
      defaultProvider: new URLSearchParams(location.search).has('shell') ? 'shell' : 'claude',
      restoreSessions: true,
      notifyOnComplete: true,
    }),
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
    detectProviders: async () => ({
      claude: true,
      codex: true,
      gemini: true,
      shell: true,
      // Every added agent answers here too — the real handler merges the two
      // halves — so a row that appears in the picker and is greyed out is a
      // stub that forgot to, not a bug in the dialog.
      ...Object.fromEntries(addedAgents.map((agent) => [agent.id, true])),
    }),

    /*
     * The agents somebody added, kept in a module-level array so the Add form
     * can actually be driven in the browser.
     *
     * A stub that answered `[]` and swallowed `addAgent` would let the plus
     * button be clicked and the form filled in and then show nothing, which is
     * the shape of bug this harness exists to catch rather than to produce. The
     * PATH check is the one thing it cannot do — there is no main process — so
     * it accepts whatever it is given, and the sentence to remember is that a
     * refusal is the one path that has to be looked at in the real app.
     *
     * `splitArgs`, not `split(/\s+/)`. It was the naive split for an hour and it
     * invented a bug that does not exist: `--system-prompt "answer in French"`
     * became six arguments, two of them carrying a quote character, the renderer
     * then dropped the whole record on the way back through `parseCustomAgents`
     * — which refuses a shell metacharacter — and the agent that had just been
     * added never appeared. Exactly the failure the header of this file warns
     * about: a stub that disagrees with the real thing invents bugs that are not
     * there and hides ones that are.
     */
    listAgents: async () => addedAgents,
    addAgent: async (draft: unknown) => {
      const value = parseDraft(draft)
      // The store's own rule, not a shortened version of it. A stub that
      // complained about one field at a time drew a form that fixes itself in
      // three round trips, while the real one names everything wrong at once —
      // and the difference is only visible by looking at both, which nobody does.
      const problems = validateDraft(value, [...AGENT_ENTRIES.map((entry) => entry.label), ...addedAgents.map((agent) => agent.label as string)])
      if (!draftIsValid(problems)) return { ok: false, problems }
      const agent = {
        id: customAgentId(value.label.trim(), addedAgents.map((a) => a.id as string)),
        label: value.label.trim(),
        description: value.description.trim(),
        command: value.command.trim(),
        args: splitArgs(value.args),
        resumeArgs: splitArgs(value.resumeArgs),
        addedAt: Date.now(),
        // The one check that cannot happen here: there is no main process to ask
        // the login PATH. Every command resolves. A refusal is therefore the one
        // path in this flow that has to be looked at in the real app.
        resolvedPath: `/usr/local/bin/${value.command.trim()}`,
      }
      addedAgents = [...addedAgents, agent]
      return { ok: true, agent }
    },
    removeAgent: async (id: string) => {
      const before = addedAgents.length
      addedAgents = addedAgents.filter((agent) => agent.id !== id)
      return addedAgents.length !== before
    },
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
    // `ShownPairingCode` is a token, an expiry and whether anything can look the
    // code up. It has never carried a URL: the link is built in the renderer,
    // from the status.
    //
    // `findable` is here because a stub that omitted it would put the panel in
    // its "the main process did not say" branch for every code the harness
    // shows, which is the one state a real build never produces — and this stub
    // exists to be the shapes the preload actually sends.
    startRemotePairing: async () => ({
      token: 'stub-token',
      expiresAt: Date.now() + 60_000,
      findable: true,
    }),
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
    onUsage: noop,
    // Same reasoning for the usage windows: there is no terminal to read a
    // Claude panel off and no `~/.codex` to walk, so the honest answer is an
    // empty report carrying the sentence that explains it. Deliberately not a
    // fixture of plausible percentages — a stub that invents a 42% bar is how a
    // "not reported" state stops being looked at.
    watchUsage: async () => ({
      sessionId: null,
      readings: [],
      reason: 'The harness has no session to read usage from.',
      assembledAt: Date.now(),
    }),
    readUsage: async () => ({
      sessionId: null,
      readings: [],
      reason: 'The harness has no session to read usage from.',
      assembledAt: Date.now(),
    }),
    unwatchUsage: () => {},
    // `provider` and `configDir` are what the main process actually sends, and
    // both are drawn: the account chip and the Accounts list put that agent's
    // mark beside the name, and the settings row shows the directory that makes
    // an account a separate login. Without them the harness shows an account
    // with no agent and no path — which is a real state (a record from an older
    // build) but not the ordinary one, so it would make the badge look broken.
    listProfiles: async () => ({
      profiles: [
        { id: 'system', name: 'Default', provider: 'claude', configDir: '/Users/you/.claude', system: true },
        { id: 'system:codex', name: 'Default (Codex CLI)', provider: 'codex', configDir: '/Users/you/.codex', system: true },
        { id: 'work', name: 'Work', provider: 'claude', configDir: '/Users/you/Library/Application Support/terminaldeck/profiles/work', system: false, lastUsedAt: launchedAt },
      ],
      // `defaultProfileId`, which is what `profiles:list` actually sends and
      // what both `parseSnapshot` and `toProfiles` read. This said `defaultId`
      // for as long as it has existed, so every surface in the harness resolved
      // its default the long way round — through the system flag — and the one
      // thing the key decides could never be exercised here.
      defaultProfileId: null,
      projectDefaults: {},
    }),
    /**
     * Who each account is signed in as — `SignInReport` from
     * `main/profiles-signin.ts`, field for field.
     *
     * Missing entirely until now, which meant every label that climbs the
     * identity ladder stopped on its lowest rung in the harness and the address
     * — the thing the whole control exists to show — could not be looked at.
     * The three answers below are the three the real probes actually give:
     * Claude's `auth status --json` names an address and a plan, Codex's `login
     * status` names neither, and an account nobody has signed into is a plain
     * `signed-out` rather than an error.
     */
    profileSignIn: async (id: string) => {
      if (id === 'system') {
        return {
          state: 'signed-in',
          account: 'app.imatch.ae@gmail.com',
          plan: 'max',
          detail: 'Signed in as app.imatch.ae@gmail.com · max',
          command: 'claude auth status --json',
        }
      }
      if (id === 'system:codex') {
        return {
          state: 'signed-in',
          account: null,
          plan: 'ChatGPT',
          detail: 'Logged in using ChatGPT',
          command: 'codex login status',
        }
      }
      return {
        state: 'signed-out',
        account: null,
        plan: null,
        detail: 'Not signed in. Open a session with this account to log in.',
        command: 'claude auth status --json',
      }
    },
    /*
     * The copilot, as a machine that has been running for a while.
     *
     * Deliberately *not* the empty first-launch state, which the harness gets
     * for free from the proxy fallback below and which the real app shows on a
     * fresh install anyway. What cannot be seen any other way is the populated
     * pane: memory with front matter, a log holding an app event beside a
     * refused alter-tier call, and a routine the engine paused after failing
     * three times — the last of which is the case Settings → Copilot exists to
     * make visible, because a paused routine and a quiet one look identical
     * otherwise.
     *
     * Every shape here is the main process's own, field for field. A stub that
     * disagrees with the preload invents bugs that do not exist and hides ones
     * that do, which has happened three times in one session in this project.
     */
    copilotState: async () => ({
      status: 'running',
      sessionId: 'copilot-1',
      paths: {
        root: '/Users/apple/Library/Application Support/terminaldeck/copilot',
        instructions:
          '/Users/apple/Library/Application Support/terminaldeck/copilot/CLAUDE.md',
        memory: '/Users/apple/Library/Application Support/terminaldeck/copilot/memory',
        log: '/Users/apple/Library/Application Support/terminaldeck/copilot-log',
        actions:
          '/Users/apple/Library/Application Support/terminaldeck/copilot-log/actions.jsonl',
      },
      home: '/Users/apple/Library/Application Support/terminaldeck/remote/homes/copilot',
      startedAt: launchedAt - 42 * 60_000,
      problem: null,
      confinement: { kind: 'seatbelt', enforced: true, reason: null },
      // `superseded` rather than `current`, because it is the state with an
      // offer attached and the one a pane can get wrong by calling it "edited".
      instructionsAreDefault: false,
      instructions: 'superseded',
      projects: {
        granted: ['/Users/apple/Projects/terminaldeck'],
        available: ['/Users/apple/Projects/terminaldeck', '/Users/apple/Projects/science-locus'],
        pending: ['/Users/apple/Projects/science-locus'],
        enforceable: true,
        reason: null,
        excluded: ['.env', '.env.*', 'id_rsa', '*.pem', '.npmrc', '.netrc', '.ssh', '.aws'],
      },
      startupFiles: [
        {
          path: '/Users/apple/Library/Application Support/terminaldeck/copilot/CLAUDE.md',
          purpose: 'Instructions — what it is and what it may do',
          exists: true,
          size: 9410,
          modifiedAt: launchedAt - 3 * 3600_000,
        },
        {
          path: '/Users/apple/Library/Application Support/terminaldeck/copilot/memory/MEMORY.md',
          purpose: 'Memory index',
          exists: true,
          size: 412,
          modifiedAt: launchedAt - 40 * 60_000,
        },
        {
          path: '/Users/apple/Library/Application Support/terminaldeck/copilot/memory/science_locus_uses_pnpm.md',
          purpose: 'Memory',
          exists: true,
          size: 286,
          modifiedAt: launchedAt - 40 * 60_000,
        },
      ],
    }),
    copilotSignIn: async () => ({
      state: 'signed-in',
      account: 'copilot@terminaldeck.local',
      plan: 'max',
      checkedAt: launchedAt,
    }),
    /*
     * `deck-control`: the copilot's tools, and the gate in front of them.
     *
     * `attachConsent` answers with an empty list rather than falling through to
     * the proxy's `null`, because the empty list is the *true* answer for a
     * window that has just arrived with nothing outstanding — and because a
     * stub that rejected here would exercise the attach retry on every harness
     * load, which is not what that retry is for.
     *
     * There is no fabricated pending question. A dialog that appeared on load
     * would make the gate look exercised when nothing had gone through it; the
     * driver at the bottom of this file is how one is raised, deliberately, by
     * hand — the same shape as `emitSessionCreated`.
     */
    deckControlStatus: async () => ({
      running: true,
      port: 51_234,
      server: 'deck-control',
      tools: [
        { id: 'sessions.list', tier: 'read', title: 'List sessions' },
        { id: 'sessions.transcript', tier: 'read', title: 'Read a session’s conversation' },
        { id: 'sessions.start', tier: 'act', title: 'Start a session' },
        { id: 'sessions.send', tier: 'act', title: 'Send text to a session' },
        { id: 'sessions.stop', tier: 'act', title: 'Stop a session' },
        { id: 'settings.write', tier: 'alter', title: 'Change a setting' },
      ],
      catalogue: { tools: 6, tokens: 1_180 },
      pendingConfirmations: 0,
      copilotSessions: ['copilot-started-1'],
      logFile:
        '/Users/apple/Library/Application Support/terminaldeck/copilot-log/actions.jsonl',
      logging: true,
    }),
    deckControlActivity: async () => [
      {
        at: new Date(launchedAt - 12 * 60_000).toISOString(),
        action: 'tool.sessions.start',
        detail: 'Start a claude session in /Users/apple/Projects/terminaldeck — done',
        v: 1,
        id: 'turn-1',
        tool: 'sessions.start',
        tier: 'act',
        args: { cwd: '/Users/apple/Projects/terminaldeck' },
        outcome: 'ok',
        confirmed: { required: false, granted: false, by: null, at: null, reason: null },
        caller: { kind: 'local' },
        ms: 380,
        result: { sessionId: 'copilot-started-1' },
        error: null,
      },
    ],
    attachConsent: async () => [],
    answerConsent: async () => ({ accepted: true }),
    onCopilotConsentRequest: (cb: (request: unknown) => void) => {
      consentListeners.add(cb)
      return () => consentListeners.delete(cb)
    },
    copilotMemory: async () => ({
      dir: '/Users/apple/Library/Application Support/terminaldeck/copilot/memory',
      exists: true,
      error: null,
      facts: [
        {
          name: 'science_locus_uses_pnpm.md',
          path: '/Users/apple/Library/Application Support/terminaldeck/copilot/memory/science_locus_uses_pnpm.md',
          bytes: 286,
          modifiedAt: launchedAt - 40 * 60_000,
          description: 'science-locus builds with pnpm, not npm',
          type: 'convention',
          scope: '~/Projects/science-locus',
          verified: '2026-08-17',
          index: false,
        },
        {
          name: 'MEMORY.md',
          path: '/Users/apple/Library/Application Support/terminaldeck/copilot/memory/MEMORY.md',
          bytes: 412,
          modifiedAt: launchedAt - 40 * 60_000,
          description: null,
          type: null,
          scope: null,
          verified: null,
          index: true,
        },
        {
          name: 'no_redis.md',
          path: '/Users/apple/Library/Application Support/terminaldeck/copilot/memory/no_redis.md',
          bytes: 190,
          modifiedAt: launchedAt - 6 * 86_400_000,
          description: 'decided against Redis in March; the queue is Postgres',
          type: 'decision',
          scope: 'global',
          verified: null,
          index: false,
        },
      ],
    }),
    copilotMemoryRead: async (name: string) => ({
      ok: true,
      name,
      path: `/Users/apple/Library/Application Support/terminaldeck/copilot/memory/${name}`,
      truncated: false,
      text:
        '---\nname: science_locus_uses_pnpm\ndescription: "science-locus builds with pnpm, not npm"\n' +
        'type: convention\nscope: ~/Projects/science-locus\nmodified: 2026-08-17\nverified: 2026-08-17\n---\n\n' +
        'The lockfile is pnpm-lock.yaml and `npm install` will fight it.\nDecided when the workspace was split, 2026-05.\n',
    }),
    copilotActions: async () => ({
      dir: '/Users/apple/Library/Application Support/terminaldeck/copilot-log',
      file: '/Users/apple/Library/Application Support/terminaldeck/copilot-log/actions.jsonl',
      exists: true,
      bytes: 18_244,
      outsideCopilotFolder: true,
      more: false,
      error: null,
      rows: [
        {
          at: new Date(launchedAt - 42 * 60_000).toISOString(),
          action: 'session.started',
          detail: 'started the copilot inside a proven boundary',
          tool: null, tier: null, outcome: null,
          confirmationRequired: null, confirmed: null, confirmedBy: null, refusedReason: null,
          caller: null, ms: null, error: null, sessionId: 'copilot-1',
        },
        {
          at: new Date(launchedAt - 38 * 60_000).toISOString(),
          action: 'tool.sessions.list',
          detail: 'listed 4 sessions across 2 projects',
          tool: 'sessions.list', tier: 'read', outcome: 'ok',
          confirmationRequired: false, confirmed: false, confirmedBy: null, refusedReason: null,
          caller: 'local', ms: 12, error: null, sessionId: null,
        },
        {
          at: new Date(launchedAt - 31 * 60_000).toISOString(),
          action: 'tool.sessions.send',
          detail: 'sent 240 characters to “Update Claude Code terminal”',
          tool: 'sessions.send', tier: 'act', outcome: 'ok',
          confirmationRequired: false, confirmed: false, confirmedBy: null, refusedReason: null,
          caller: 'local', ms: 38, error: null, sessionId: 's2',
        },
        {
          at: new Date(launchedAt - 22 * 60_000).toISOString(),
          action: 'tool.settings.write',
          detail: 'changed notifications.sound',
          tool: 'settings.write', tier: 'alter', outcome: 'ok',
          confirmationRequired: true, confirmed: true, confirmedBy: 'main window',
          refusedReason: null, caller: 'local', ms: 4_120, error: null, sessionId: null,
        },
        {
          at: new Date(launchedAt - 9 * 60_000).toISOString(),
          action: 'tool.sessions.stop',
          detail: 'asked to stop “nightly sweep” during an unattended run',
          tool: 'sessions.stop', tier: 'alter', outcome: 'refused',
          confirmationRequired: true, confirmed: false, confirmedBy: null,
          refusedReason: 'not-permitted-unattended',
          caller: 'local', ms: 2, error: 'nobody was at the machine to confirm it', sessionId: null,
        },
        {
          at: new Date(launchedAt - 4 * 60_000).toISOString(),
          action: 'tool.log.note',
          detail: 'noted: the auth test is flaky on CI only, not locally',
          tool: 'log.note', tier: 'act', outcome: 'ok',
          confirmationRequired: false, confirmed: false, confirmedBy: null, refusedReason: null,
          caller: 'local', ms: 1, error: null, sessionId: null,
        },
      ],
    }),
    copilotReveal: async () => ({ opened: true, path: null, message: 'Opened.' }),
    routinesList: async () => [
      {
        id: 'overnight-report',
        name: 'Overnight report',
        file: '/Users/apple/Library/Application Support/terminaldeck/routines/overnight-report.md',
        folder: '/Users/apple/Projects/terminaldeck',
        triggers: ['when: schedule daily 08:00'],
        prompt: 'Summarise what every session did overnight, with the evidence links.',
        enabled: true, overlap: 'skip', state: 'armed', reason: null,
        problems: [], warnings: [],
        lastFiredAt: launchedAt - 5 * 3600_000,
        lastRunAt: launchedAt - 5 * 3600_000,
        lastFinishedAt: launchedAt - 5 * 3600_000 + 92_000,
        lastOutcome: 'ok', lastError: null, consecutiveFailures: 0,
        refusedCalls: [], running: false, pending: false,
        runsLastHour: 0, runsLastDay: 1, firesLastHour: 0,
        maxRunsPerHour: 2, maxRunsPerDay: 4,
        pausedUntil: null, nextDueAt: launchedAt + 11 * 3600_000, missedWhileClosed: 0,
        sources: [],
      },
      {
        id: 'nightly-sweep',
        name: 'Nightly sweep',
        file: '/Users/apple/Library/Application Support/terminaldeck/routines/nightly-sweep.md',
        folder: '/Users/apple/Projects/science-locus',
        triggers: ['when: session-failed', 'when: git-change'],
        prompt: 'When a session fails, read the tail of its transcript and say what broke.',
        enabled: true, overlap: 'skip', state: 'paused',
        reason: 'Stopped after 3 failures in a row.',
        problems: [], warnings: [],
        lastFiredAt: launchedAt - 70 * 60_000,
        lastRunAt: launchedAt - 70 * 60_000,
        lastFinishedAt: launchedAt - 69 * 60_000,
        lastOutcome: 'failed',
        lastError: 'the session it started never reported a result',
        consecutiveFailures: 3,
        refusedCalls: [
          { at: launchedAt - 69 * 60_000, tool: 'sessions.stop', reason: 'not-permitted-unattended' },
        ],
        running: false, pending: false,
        runsLastHour: 0, runsLastDay: 3, firesLastHour: 0,
        maxRunsPerHour: 4, maxRunsPerDay: 12,
        pausedUntil: null, nextDueAt: null, missedWhileClosed: 0,
        sources: [],
      },
      {
        id: 'weekly-diff-review',
        name: 'Weekly diff review',
        file: '/Users/apple/Library/Application Support/terminaldeck/routines/weekly-diff-review.md',
        folder: null,
        triggers: ['when: manual'],
        prompt: 'Review everything that landed this week and flag what should not have.',
        enabled: false, overlap: 'skip', state: 'disabled',
        reason: 'Its own file says enabled: false.',
        problems: [], warnings: [],
        lastFiredAt: null, lastRunAt: null, lastFinishedAt: null,
        lastOutcome: null, lastError: null, consecutiveFailures: 0,
        refusedCalls: [], running: false, pending: false,
        runsLastHour: 0, runsLastDay: 0, firesLastHour: 0,
        maxRunsPerHour: null, maxRunsPerDay: null,
        pausedUntil: null, nextDueAt: null, missedWhileClosed: 0,
        sources: [],
      },
    ],
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
    /*
     * The three routes that reach outside the project, stubbed honestly.
     *
     * A browser cannot open an NSOpenPanel and has no pasteboard this app may
     * read, so the harness cannot *do* any of this — and the rule for this file
     * is that it must mirror the preload's shapes rather than invent behaviour.
     * So each answers the real shape for the case it can honestly represent:
     * browse answers a pick, which is what lets the chip and its "outside" mark
     * be looked at without Electron; paste answers "nothing on the clipboard",
     * which is true here; and the boundary answers unconfined, which is the
     * answer for every session started in the window.
     */
    browseForAttachment: async () => ({
      ok: true,
      picks: [{ path: '/Users/apple/Desktop/screenshot.png', isDirectory: false }],
    }),
    inspectAttachPaths: async (paths: string[]) =>
      paths.map((path) => ({ path, isDirectory: !/\.[a-z0-9]+$/i.test(path) })),
    pasteAttachment: async () => ({
      ok: false,
      reason: 'nothing',
      detail: 'There is no file or image on the clipboard.',
    }),
    sessionAttachBoundary: async () => ({ confined: false, folder: '', projects: [] }),
    // Not a promise: `webUtils.getPathForFile` is synchronous in the preload,
    // and a stub that returned a promise here would make the drop handler
    // `await` a value the real bridge hands back directly — the exact class of
    // disagreement this file exists to avoid. A browser `File` has no path.
    pathForDroppedFile: () => '',
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
    /*
     * Artifacts. Same reason as `loadChat` below, and the same failure without
     * it: `ArtifactsPanel` decides what to draw from `response.ok`, the Proxy
     * fallback answers `null`, and `null.ok` throws inside the promise. The
     * panel catches it, so the harness would show the Artifacts page reporting
     * a TypeError as if the feature were broken — which is precisely the
     * invented bug this file's contract exists to avoid. `resolveBridge` cannot
     * save it either: the fallback *is* a function, so the panel's "not wired
     * yet" guard is satisfied and it goes ahead and calls it.
     *
     * The answer is an honest empty scan rather than fabricated files: the
     * harness has no transcripts, so nothing was written or edited, and the page
     * shows the empty state a real project with no recorded sessions shows.
     * `sessionsScanned: 0` is what makes it say so in those words.
     */
    listArtifacts: async () => ({
      ok: true,
      root: '/Users/apple/Projects/terminaldeck',
      scope: 'project',
      artifacts: [],
      sessions: [],
      sessionsScanned: 0,
      outsideProject: 0,
      truncated: false,
      cancelled: false,
      tookMs: 0,
    }),
    artifactChanges: async () => ({
      ok: true,
      root: '/Users/apple/Projects/terminaldeck',
      relPath: '',
      changes: [],
      totalChanges: 0,
      truncated: false,
      cancelled: false,
      tookMs: 0,
    }),
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
      // And whether a command could be typed at it, which in the harness is the
      // same "there is no pty" the line above says — quoted from the real
      // handler's own sentence for that case rather than reworded, so a stub
      // that has drifted from the preload shows up as different words on
      // screen instead of as a plausible sentence nobody wrote.
      gate: { canType: false, reason: 'That session is no longer running.' },
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
    // Draw mode. Present, because the Draw button asks whether both methods
    // exist before it offers itself and the Proxy's `async () => null` would
    // make it offer itself and then fail with a null nobody can read. Both
    // *reject*, with the sentence the real failure has: the harness renders the
    // app in an ordinary browser tab, where there is no native `WebContentsView`
    // and therefore no page to photograph. Handing back an invented frame would
    // make the canvas, the marks and the Send button all look verified while the
    // one thing this feature is — a real capture reaching a real session —
    // had never run.
    browserFrame: async () => {
      throw new Error('The page has to be on screen to capture it.')
    },
    browserScreenshotMarked: async () => {
      throw new Error('The harness has no filesystem, so nothing was saved.')
    },
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

/**
 * Raise the copilot's alter-tier confirmation.
 *
 * The one dialog in this app that nothing on screen can produce: it is pushed by
 * the main process when the copilot asks for something in the tier that has to
 * be confirmed, so without a driver it could never be looked at outside
 * Electron. The default is a real `settings.write` question, shaped exactly as
 * `ConsentRequest` and with a real two-minute deadline, so the countdown and the
 * refusal-on-silence are the real ones.
 */
;(globalThis as unknown as {
  emitCopilotConsent: (request?: Record<string, unknown>) => void
}).emitCopilotConsent = (request = {}) => {
  const at = Date.now()
  const full = {
    id: `consent-${(sessionCounter += 1)}`,
    tool: 'settings.write',
    tier: 'alter',
    summary: 'Change settings: appearance.theme to "dark", general.copyOnSelect to true',
    args: {
      scope: 'settings',
      patch: { 'appearance.theme': 'dark', 'general.copyOnSelect': true },
    },
    requestedAt: at,
    expiresAt: at + 120_000,
    ...request,
  }
  for (const listener of [...consentListeners]) listener(full)
}
export {}
