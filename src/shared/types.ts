/** Shared contract between the main process and the renderer. */

/** Where a link opened. `main/link-open.ts` owns the decision. */
export type LinkRoute = 'tab' | 'system' | 'refused'

/**
 * A URL on its way into a browser window of this app's.
 *
 * Here rather than in `main/link-open.ts` because all three sides have to agree
 * on it — main pushes it, the preload carries it, the renderer opens it — and
 * this is the only file all three are allowed to import. `link-open.ts` re-
 * exports it beside the channel constant so the payload and the channel name
 * stay next to each other for a reader.
 */
export interface LinkTabRequest {
  url: string
  /** The session this URL came from, when it came from one. */
  sessionId?: string
  /** Empty or absent for a session on this machine. */
  machineId?: string
  /**
   * Set when the sender is waiting to be told which window this became.
   *
   * A request carrying one **must** be answered, either way. The sender is a
   * `curl` inside somebody's session, holding a connection open; an unanswered
   * id is that session waiting out a timeout for nothing.
   */
  requestId?: string
}

/**
 * An agent this build was shipped knowing about.
 *
 * ## Why this list is closed and the one below it is not
 *
 * Everything in this app that is *specific* to an agent keys off this union, and
 * that specificity is the reason it has to stay closed. Transcript reading is
 * Claude Code's JSONL format and nothing else's; hook installation writes into
 * three CLIs' own configuration files in three different shapes; account
 * isolation depends on a config-directory variable that was watched move a
 * login on a real machine; the model and effort pickers type Claude Code's own
 * slash commands. Each of those is a `Record<BuiltinProviderId, …>` somewhere,
 * total by construction, so an agent added to this union fails to compile at
 * every place that would otherwise have skipped it silently. That guard has
 * caught real bugs and is worth keeping exactly as it is.
 *
 * What it is *not* is a limit on how many agents the app can run, and that is
 * the thing this pass was opened to fix. The brief said so twice:
 *
 *   > *"There should be a plus button to add, with the big list of type of AI
 *   > agents to connect — not only Codex, not only Claude Code. There are so
 *   > many, Grok agents… Just take a look how many types of agents and setup
 *   > they have in Cursor and in Visual Studio Code… They should be able to
 *   > connect a huge number of type of agents."*
 *
 * The answer is {@link CustomProviderId} below, not a longer list here, and the
 * distinction is the whole design. This union is not "agents we like" — it is
 * *agents this build makes specific claims about*, and every name in it has to
 * carry a `verified` line in `shared/agent-catalog.ts` saying what was run and
 * what answered. `AGENT_CATALOG` is a `Record` over this union, so a name added
 * here without that evidence does not compile.
 *
 * ## Seven names were in this union for a night, and are not now
 *
 * `copilot`, `opencode`, `qwen`, `crush`, `grok`, `auggie` and `amp` were added
 * to it ahead of the catalogue entries they need, and this is the note so nobody
 * puts them back the same way. They are real, they were installed into a
 * throwaway prefix and launched, and the header of `shared/agent-catalog.ts`
 * records the package, the binary and the version each one printed. What none of
 * them has is the other half of an entry — the argument lists, whether a resume
 * flag is safe in a folder with no history, whether a config-directory variable
 * actually moves the login — and those are measurements, not defaults. Declaring
 * them unmeasured would have shipped a picker full of rows that die on
 * selection, which is the one failure the catalogue's own rule names.
 *
 * The union widening also went in alone: `AGENT_CATALOG`, the spawn table, the
 * account strategies and `knownProvider` all stayed at four names, so nothing
 * type-checked, and `session-create.test.ts` was asserting that
 * `knownProvider('copilot')` is null while the type said copilot was an agent.
 * A closed union is only worth having while everything it closes over is total.
 *
 * None of that costs anybody an agent today. Every one of the seven can be run
 * *right now* through the plus button, because a custom agent is a command
 * resolved on this machine's PATH rather than a claim this build is making —
 * which is exactly the honest shape for an agent nobody here has characterised.
 * Promoting one is then a real piece of work with a measurement at the end of
 * it: an entry with a `verified` line, and its name here.
 */
export type BuiltinProviderId = 'claude' | 'codex' | 'gemini' | 'shell'

/**
 * An agent the person at the keyboard added themselves.
 *
 * A template-literal type rather than a bare `string`, and the prefix is doing
 * real work rather than decorating an id. Three things depend on being able to
 * tell the two kinds apart *at the type level* and not by a lookup that might
 * come back empty:
 *
 *  1. Every builtin table above stays exhaustively checked. `Record<ProviderId,
 *     T>` would have collapsed into an index signature the moment the union
 *     opened, and the compiler would have stopped complaining about a builtin
 *     nobody had wired up — trading the bug being fixed here for the bug that
 *     guard was added to prevent.
 *  2. A custom id can never collide with a builtin one. `custom:claude` is not
 *     `claude`, so an agent somebody names "Claude" cannot quietly inherit
 *     Claude Code's transcript reader, hooks or account isolation.
 *  3. Anything narrowing a string off the wire — a session restored from disk,
 *     a `create` frame from a phone — has one shape to test rather than a list
 *     to keep in step. `isCustomProviderId` in `shared/custom-agents.ts` is the
 *     single test, and it is the only place the prefix is spelled.
 */
export type CustomProviderId = `custom:${string}`

/** Which agent a session is running: one this build ships, or one you added. */
export type ProviderId = BuiltinProviderId | CustomProviderId

/**
 * Live state of a session, surfaced as the coloured dot on its tab.
 * Derived in the renderer from output patterns and process state.
 */
export type SessionStatus = 'idle' | 'working' | 'waiting' | 'input' | 'completed' | 'exited'

/**
 * Who wanted this session to exist.
 *
 * `COPILOT-DESIGN.md` needs this for two things and they pull in the same
 * direction. The sidebar groups sessions the copilot started under their own
 * heading — *"Each one links back to the copilot turn that spawned it, and that
 * turn links forward to the session"* — and the routine engine needs it to
 * refuse to be triggered by its own work: "when a session finishes, start a
 * session" is an obvious loop, and provenance is the only exact way to break
 * it. See `src/main/routines/engine.ts`.
 *
 * Absent means `user`, which is every session that existed before this field
 * did. Nothing may treat the absence as unknown.
 */
export type SessionOrigin = 'user' | 'copilot'

export interface SessionMeta {
  id: string
  /** Absolute path to the project folder this session runs in. */
  cwd: string
  /** Folder name, used as the tab label until a better title is derived. */
  title: string
  /** Which agent CLI this session is running. */
  provider: ProviderId
  /** Set once the underlying process exits. */
  exitCode: number | null
  createdAt: number
  /**
   * Started with "continue the last conversation" rather than fresh.
   *
   * Carried because it changes which transcript belongs to this session: a
   * fresh run writes a new file, a continued one appends to an older one.
   *
   * **What the process got, never what was asked for.** Those two came apart
   * once and nothing on screen could see it: `one-conversation.ts` can refuse a
   * resume that was requested — a second tab in a folder that already has a
   * live session, and, until it learnt to recognise a replacement, every single
   * account switch — and while this was read off the request those sessions
   * reported having continued a conversation they had just started fresh.
   * `host-core.ts` sets it from the argument list it spawned.
   */
  resumed?: boolean
  /**
   * The conversation id this app gave the agent when it started it, so the
   * transcript can be found by name instead of guessed at.
   *
   * Claude Code files a conversation at
   * `<configDir>/projects/<encoded cwd>/<id>.jsonl`, and until this existed
   * nothing here knew that id: the app spawned `claude` with no id, the CLI
   * invented one, and every reader afterwards had to pick "the most recently
   * written transcript in this folder" and hope. Two sessions open in one folder
   * therefore reported the *same* context window, which is what Asad recorded on
   * 2026-08-19 — *"it is showing same context window for your session too, so all
   * the sessions show same context window"*. Both tabs were reading one file.
   *
   * `claude --session-id <uuid>` is what closes it, verified against 2.1.235 on
   * this machine: a run with a generated id wrote exactly
   * `…/projects/<encoded cwd>/<that uuid>.jsonl` and nothing else.
   *
   * Absent, and honestly absent, for three kinds of session. A resumed one — the
   * CLI refuses `--continue` beside `--session-id` unless the conversation is
   * forked, and forking would copy somebody's history into a new file to make a
   * number easier to read. A session running any other agent. And every session
   * this app did not start, which is the case Asad asked to keep working: *"I did
   * not start this session … which is okay, I want it that way"*. Those keep the
   * inference, and it is labelled as an inference.
   */
  agentSessionId?: string
  /**
   * The account this session actually runs as — the *resolved* profile, not the
   * one that was asked for.
   *
   * Set by the main process at spawn, because that is the only place the answer
   * exists: `profileId` on the request is frequently null, meaning "whatever
   * this project's default is", and the resolution chain that turns that into a
   * profile runs in `host-core.ts`. A window that recomputed it would be
   * guessing, and would guess wrong for any session it did not start — one
   * restored at launch, or one a phone asked for.
   *
   * Absent when no account applies: a plain shell has no login, and an agent
   * whose config directory this app cannot redirect runs under whatever login
   * the machine already has. Showing an account name against either would be a
   * claim about isolation that is not true. See `supportsProfiles`.
   */
  profileId?: string
  /** The account's name, so a list can show it without a second lookup. */
  profileName?: string
  /** Who wanted this session. Absent means the person did. See {@link SessionOrigin}. */
  origin?: SessionOrigin
  /**
   * The routine whose run started this session, when a routine did.
   *
   * Carried on the session rather than held in a table beside it, because the
   * question "why does this session exist" is asked about a session — by the
   * sidebar, by the routine engine's loop guard, and by a person looking at a
   * tab they did not open.
   */
  originRoutineId?: string
  /** The individual run, so a session and the turn that spawned it link both ways. */
  originRunId?: string
}

export interface CreateSessionInput {
  cwd: string
  cols: number
  rows: number
  /** Defaults to 'claude' when the CLI is installed, otherwise 'shell'. */
  provider?: ProviderId
  /** Continue the most recent session in this folder instead of starting fresh. */
  resume?: boolean
  /**
   * The conversation to continue, by id, instead of "the folder's most recent".
   *
   * Only meaningful beside `resume`, and only for Claude Code, which is the one
   * agent whose conversations this app names (`SessionMeta.agentSessionId`). It
   * exists for the account switch: the sheet promises that the conversation
   * *on screen* follows, and `--continue` promises the folder's newest, which
   * are the same thing right up until they are not.
   */
  resumeConversationId?: string
  /**
   * The session this one replaces, when it is a replacement rather than a
   * second session.
   *
   * Set only by an account switch. `one-conversation.ts` refuses `--continue`
   * to a spawn that would join a folder another live session is already in —
   * correctly, because two sessions resolving one `--continue` fork the
   * transcript — and a switch starts the replacement before it stops the
   * outgoing process, so without this it tripped that guard on every switch and
   * lost the conversation it had just promised to keep.
   */
  replaces?: string
  /** Which agent profile (isolated login) to run as. Null uses the default. */
  profileId?: string | null
  /**
   * Who is asking. Absent means the person at the keyboard.
   *
   * Set only by the copilot's own tools and by the routine engine. It is
   * deliberately *not* a permission — a session started by the copilot runs
   * under exactly the same rules as any other, and the confinement, the profile
   * and the folder checks all apply unchanged. It is a label, so that what the
   * machine did on its own can be told apart from what you did.
   */
  origin?: SessionOrigin
  originRoutineId?: string
  originRunId?: string
}

export interface BrandInfo {
  name: string
  tagline: string
}

/** Everything the renderer may call, exposed by the preload bridge. */
export interface Preferences {
  theme: 'dark' | 'light' | 'system'
  defaultProvider: ProviderId
  restoreSessions: boolean
  notifyOnComplete: boolean
}

export interface PersistedProject {
  path: string
  provider?: ProviderId
  lastOpenedAt: number
}

export interface DeckApi {
  getBrand(): Promise<BrandInfo>
  /**
   * Which agents can actually be started here, keyed by id.
   *
   * `Record<string, boolean>` rather than a record over `ProviderId`, because
   * the answer now includes agents this build was not shipped knowing about —
   * the ones the person added. Totality has not been given up, it has moved to
   * where it can still be checked: `detectProviders` in `main/providers.ts`
   * builds the builtin half as an object literal typed
   * `Record<BuiltinProviderId, boolean>`, so a builtin agent left out of the
   * detection loop is still a compile error, and the custom half is merged on
   * top of it.
   */
  detectProviders(): Promise<Record<string, boolean>>

  /**
   * The agents the person added themselves, and the machinery to manage them.
   *
   * These cross the bridge as `unknown` like every other feature module —
   * `main/custom-agents.ts` owns the shapes and `shared/custom-agents.ts` holds
   * the narrowers both sides use. `addAgent` is deliberately the only way one
   * comes into existence: it probes the command on the user's login PATH and
   * refuses a draft it could not resolve, which is the same rule the built-in
   * table lives by — never declare an agent that has not been launched.
   */
  listAgents(): Promise<unknown>
  addAgent(draft: unknown): Promise<unknown>
  removeAgent(id: string): Promise<unknown>
  listProjects(): Promise<PersistedProject[]>
  addProject(path: string): Promise<PersistedProject>
  removeProject(path: string): Promise<void>
  getPreferences(): Promise<Preferences>
  setPreferences(patch: Partial<Preferences>): Promise<Preferences>
  /**
   * The stored values changed, and this window is not what changed them.
   *
   * Both carry the whole store rather than the patch. There is no push for this
   * window's own writes — those answer with the new values already — so anything
   * arriving here came from the copilot or from a paired device, and the window
   * has to take it or go on drawing a value that is no longer stored anywhere.
   * See `main/live-push.ts` for the failure that produced them.
   */
  onPreferencesChanged(cb: (preferences: unknown) => void): () => void
  onSettingsChanged(cb: (settings: unknown) => void): () => void
  pickProjectFolder(): Promise<string | null>
  /** The home directory, for the one path that needs a folder and has none. */
  homeFolder(): Promise<string | null>
  createSession(input: CreateSessionInput): Promise<SessionMeta>
  writeToSession(id: string, data: string): void
  resizeSession(id: string, cols: number, rows: number): void
  getScrollback(id: string): Promise<string>
  killSession(id: string): Promise<void>
  listSessions(): Promise<SessionMeta[]>
  /** Listeners all return an unsubscribe function. */
  onSessionData(cb: (id: string, data: string) => void): () => void
  onSessionExit(cb: (id: string, exitCode: number) => void): () => void
  onSessionStatus(cb: (id: string, status: SessionStatus) => void): () => void
  /**
   * This app is not holding that session any more, so its row cannot act.
   *
   * Not the same fact as {@link onSessionExit}: a process that ends on its own
   * keeps its place in the manager and its scrollback, and its tab is still
   * worth having. This one fires when the session is dropped outright — by the
   * copilot's `sessions.stop`, by a paired phone, by a routine — after which
   * nothing in this process can answer for it.
   */
  onSessionRemoved(cb: (id: string) => void): () => void
  /**
   * A session this window did not start — today, one started from a phone.
   *
   * The window builds its tab list from what it asked for, so without
   * subscribing to this a session started remotely runs on this Mac and never
   * appears in the app that owns it.
   */
  onSessionCreated(cb: (meta: SessionMeta) => void): () => void
  /**
   * An account switch that was armed for the next message has happened.
   *
   * Declared optional because it is: a window running against an older preload
   * has no such method, and the two subscribers are written to cope with that
   * rather than to assume it. The immediate switch needs no equivalent — it
   * answers with the replacement as the return value of the call that asked for
   * it, and this one had nothing to answer, because it fired inside a keystroke
   * long after the sheet was shut.
   */
  onSessionSwitched?(cb: (previousId: string, meta: SessionMeta, note: string) => void): () => void
  /**
   * And one that did not take. The session is still running as it was.
   *
   * Carries the account it failed to reach as well as the reason, so the window
   * can name it rather than saying "an account" about a login somebody chose by
   * name.
   */
  onSessionSwitchFailed?(
    cb: (sessionId: string, profileId: string, why: string) => void,
  ): () => void
  /** Application-menu items, dispatched as command ids. */
  onMenuCommand(cb: (command: string) => void): () => void
  /**
   * The commands the application menu must not offer, because the feature that
   * owns them is not installed.
   *
   * The menu is built in the main process; the feature registry lives in the
   * renderer, with everything else that asks it. This is how the answer
   * crosses. See `src/main/menu.ts`.
   */
  setHiddenMenuCommands(commands: string[]): void

  /**
   * Links.
   *
   * A link opens in a tab of this app's own browser by default — it is the main
   * process that decides, in `main/link-open.ts`, because both kinds of request
   * (`window.open` from this UI, `target="_blank"` inside a page) arrive there
   * as a window-open request. {@link onOpenLinkTab} is how the decision comes
   * back; the other two are the way out, for the person who wants this
   * particular link in the browser they are already signed into.
   */
  onOpenLinkTab(cb: (request: LinkTabRequest) => void): () => void
  openLinkExternally(url: string): Promise<boolean>
  showLinkMenu(url: string): Promise<boolean>
  /**
   * A link somebody clicked **inside a session** — a URL an agent printed in
   * the terminal, above all.
   *
   * Separate from `window.open` and from {@link onOpenLinkTab} because it is the
   * only one that knows which session it came from, and that is the whole point:
   * the main process routes it to a browser window attached to *that* session
   * rather than to a new tab at the end of the strip. It resolves with what was
   * decided, so a caller that wants to say what happened can; the terminal does
   * not wait, because a click is not a place to await.
   */
  openLink(request: { url: string; sessionId?: string; machineId?: string }): Promise<LinkRoute>
  /** Tell the main process which browser windows this window is showing. */
  browserWindowOpened(window: {
    tabId: string
    viewId?: string | null
    url?: string
    title?: string
    /**
     * Which machine is really serving this page. Empty for this computer.
     *
     * Not derivable from the URL and that is the point: a page reached on
     * another machine wears a `localhost` address on **this** one, because the
     * tunnel put it there. *"We always need a truth."*
     */
    machineId?: string
    machineName?: string
    /** True while this is the page on screen. */
    visible?: boolean
  }): void
  /** A browser window that has been closed. Its number is not handed out again. */
  browserWindowClosed(tabId: string): void
  /** Attach a browser window to a session, or move it from the session it is on. */
  browserBind(request: { tabId: string; sessionId: string; machineId?: string }): void
  /** Detach a browser window. The page stays open. */
  browserUnbind(tabId: string): void
  /** The answer to a {@link LinkTabRequest} that carried a `requestId`. */
  browserLinkOpened(reply: { requestId: string; tabId?: string; refused?: string }): void
  /** Every session's attached windows, pushed whenever the relation changes. */
  onBrowserBindings(cb: (view: unknown) => void): () => void
  /** The relation as it stands, for a window that has just come up. */
  browserBindings(): Promise<unknown>
  /**
   * Pop the attach/detach menu for one session, at the pointer.
   *
   * A native menu, built in the main process, for the reason `link-open.ts`
   * gives at `showLinkMenu`: a `WebContentsView` composites above the entire
   * renderer, so an HTML menu would be invisible in exactly the situation this
   * feature exists for — a browser window on screen.
   */
  showBrowserBindMenu(request: { sessionId: string; machineId?: string }): Promise<boolean>

  /**
   * The same relation from the browser's end: which session this window is on.
   *
   * *"Both sides should be the option."* It reads and writes the one map in
   * `main/browser-binding.ts`, so a change made here is on the session's pane
   * bar and in the rail in the same frame. The sessions travel in the request
   * because their names are this window's — main has ids.
   */
  showBrowserConnectMenu(request: {
    tabId: string
    sessions: { sessionId: string; machineId?: string; name: string; machineName?: string }[]
  }): Promise<boolean>

  /**
   * The ⋯ menu on a sidebar row, and what the person chose from it.
   *
   * `'promote' | 'close' | 'copilot'`, or null when the menu was dismissed —
   * which is the ordinary outcome and not an error. Native for the reason above,
   * and doubly so here: the entry people open it for is **Connect browser**, so
   * the moment it is most used is the moment a browser page is on screen.
   *
   * Every sentence in it is passed in rather than derived, because the row's own
   * tooltips already carry them and a second copy in the main process is the one
   * that keeps the old wording. See `main/session-row-menu.ts`.
   */
  showSessionRowMenu(request: {
    sessionId: string
    machineId?: string
    name: string
    promoted: boolean
    promoteBlocked?: string | null
    /** Whether this row can be deleted at all. The menu writes the word. */
    close?: boolean
    copilotTurn?: boolean
    browser?: boolean
  }): Promise<string | null>

  // Feature modules. These cross the bridge as `unknown` and each consumer
  // narrows to its own module's types — the main-process modules own those
  // definitions, and duplicating them here would let the two drift apart.
  getProjectCost(cwd: string): Promise<unknown>
  getSessionCost(transcriptPath: string): Promise<unknown>
  listSessionTranscripts(cwd: string): Promise<unknown>
  watchProjectCost(cwd: string): Promise<unknown>
  unwatchProjectCost(cwd: string): Promise<void>
  onCostUpdate(cb: (summary: unknown) => void): () => void

  gitStatus(cwd: string): Promise<unknown>
  gitInit(cwd: string): Promise<unknown>
  gitDiff(cwd: string, path: string, options?: { staged?: boolean; untracked?: boolean }): Promise<string>
  watchGit(cwd: string): Promise<unknown>
  unwatchGit(cwd: string): void
  onGitStatus(cb: (cwd: string, status: unknown) => void): () => void

  listDir(root: string, relDir: string, options?: { showIgnored?: boolean }): Promise<unknown>
  readFile(root: string, relPath: string): Promise<unknown>
  searchProjectFiles(request: { root: string; refresh?: boolean; limit?: number }): Promise<unknown>
  cancelProjectFileSearch(): Promise<void>
  invalidateProjectFiles(root?: string): Promise<void>

  getSessionInsights(transcriptPath: string): Promise<unknown>
  getLatestSessionInsights(cwd: string): Promise<unknown>
  listSessionInsights(cwd: string): Promise<unknown>

  githubOverview(cwd: string): Promise<unknown>
  githubRefresh(cwd: string): Promise<unknown>
  githubRepo(cwd: string): Promise<unknown>
  clearGitHubCache(cwd?: string): void

  githubAuthStatus(cwd?: string): Promise<unknown>
  githubConnect(): Promise<unknown>
  githubAwaitConnect(cwd?: string): Promise<unknown>
  githubCancelConnect(cwd?: string): Promise<unknown>
  githubDisconnect(cwd?: string): Promise<unknown>

  /**
   * The copilot — one session, in a folder of its own, held inside it.
   *
   * None of these takes an argument, and that is deliberate rather than
   * incidental: where the copilot runs, which account it runs as and what it
   * may reach are all decided in the main process, so there is nothing for a
   * window to pass and nothing for page code to point somewhere else. They
   * cross as `unknown` like every other feature module — `src/main/copilot-session.ts`
   * owns the shapes.
   */
  ensureCopilot(): Promise<unknown>
  copilotState(): Promise<unknown>
  copilotFiles(): Promise<unknown>
  stopCopilot(): Promise<unknown>
  copilotSignIn(): Promise<unknown>

  scanReadiness(projectPath: string): Promise<unknown>
  applyReadinessFix(projectPath: string, checkId: string): Promise<unknown>

  checkPrerequisites(): Promise<unknown>

  loadChat(request: { cwd?: string; transcriptPath?: string }): Promise<unknown>
  tailChat(request: { cwd?: string; transcriptPath?: string }): Promise<unknown>
  closeChat(transcriptPath: string): void
  devPorts(force?: boolean): Promise<unknown>


  getSettings(): Promise<unknown>
  setSettings(patch: Record<string, unknown>): Promise<unknown>
  resetSettings(): Promise<unknown>
  settingsPaths(): Promise<unknown>
  openSettingsPath(key: string): Promise<unknown>
  appAbout(): Promise<unknown>
  clearBrowserData(): Promise<unknown>

  /**
   * What the OS is prepared to say about notifications, and the way out when
   * it says nothing. See `src/main/os-notifications.ts` — the short version is
   * that `Notification.permission` is a lie in a renderer and these three are
   * the only honest questions left to ask.
   */
  notificationSupport(): Promise<unknown>
  openNotificationSettings(): Promise<unknown>
  notificationDelivery(sinceMs: number): Promise<unknown>

  browserSessionInfo(profileId?: unknown): Promise<unknown>
  browserCookies(profileId?: unknown): Promise<unknown>

  loadDashboard(projectPath: string): Promise<unknown>
  saveDashboard(projectPath: string, layout: unknown): Promise<void>
  clearDashboard(projectPath: string): Promise<void>

  /**
   * Other machines: the ones this desktop has paired *to*.
   *
   * The mirror of the `remote*` half, which is about devices reaching in. These
   * cross the bridge as `unknown` like every other feature module, and
   * `renderer/machines/` narrows them against the main-process types that own
   * the definitions.
   *
   * There is deliberately nothing here that returns a credential or a key.
   * `MachineStore` keeps both and publishes neither — the window has no use for
   * either, and a bridge that carried a bearer secret is one screenshot away
   * from publishing it.
   */
  listMachines(): Promise<unknown>
  startMachineCode(): Promise<unknown>
  cancelMachineCode(): Promise<unknown>
  pairMachine(code: string): Promise<unknown>
  forgetMachine(id: string): Promise<unknown>
  renameMachine(id: string, name: string): Promise<unknown>
  connectMachine(id: string): Promise<unknown>
  disconnectMachine(id: string): Promise<unknown>
  attachMachineSession(id: string, sessionId: string, cols: number, rows: number): Promise<unknown>
  detachMachineSession(id: string, sessionId: string): Promise<unknown>
  writeToMachineSession(id: string, sessionId: string, data: string): Promise<unknown>
  /**
   * Type into a session on another machine **without attaching to it**.
   *
   * The line above is a remote terminal pane's keyboard and is served only to a
   * connection that attached first; this is for a surface that has something to
   * say and nothing to read, where taking out an attach would displace the
   * handle a pane on that link already holds and replay its scrollback at
   * whoever is reading it.
   *
   * Answers `{ ok, message }` — never a bare boolean and never a throw — because
   * the caller has no terminal on screen to read the outcome off and draws that
   * sentence itself.
   */
  sendToMachineSession(machineId: string, sessionId: string, data: string): Promise<unknown>
  resizeMachineSession(id: string, sessionId: string, cols: number, rows: number): Promise<unknown>
  createMachineSession(id: string, cwd?: string, provider?: string): Promise<unknown>
  /**
   * End one session on another machine. Refused unless it advertised `close`.
   *
   * Not `detachMachineSession`, which is the line above and means the opposite
   * of this: that one stops this window receiving a session's bytes and leaves
   * the process running; this kills the process on the far machine for everyone
   * attached to it. The boolean that comes back is *the request left this
   * machine* — the row disappearing from `machines:state` is what says it
   * happened.
   */
  closeMachineSession(id: string, sessionId: string): Promise<unknown>
  /** Ask that machine again what is listening on it. The list rides on `machines:state`. */
  refreshMachinePorts(id: string): Promise<unknown>
  /** Open a page in the browser **on that machine**. Refused unless it advertised `web`. */
  openOnMachine(id: string, url: string): Promise<unknown>
  /**
   * The copilot on one of his *other* machines.
   *
   * The switcher at the top of the copilot page is what these are under: two
   * paired machines, one page, either copilot. Nothing opens the connection —
   * the link sends `copilot.hello` on every welcome that carried one, because
   * that machine refuses every copilot verb until this socket has, and the
   * socket is new after every reconnect.
   *
   * Each resolves `{ ok, message }`, where `ok` is *the frame left this
   * machine*. There is no request id on the copilot wire, so it cannot mean
   * more; what the far end made of it arrives on the two subscriptions below,
   * and a refusal arrives as that machine's `reason` on `machines:state`.
   */
  attachMachineCopilot(machineId: string): Promise<unknown>
  /** Start a run of this desktop's own over there. `sayToMachineCopilot` has nothing to talk to until it has. */
  startMachineCopilot(machineId: string): Promise<unknown>
  sayToMachineCopilot(machineId: string, text: string): Promise<unknown>
  /** Ask again for that machine's copilot state. The answer arrives on `onMachineCopilotState`. */
  refreshMachineCopilot(machineId: string): Promise<unknown>
  /** The whole `CopilotStateReport` that machine sent — `desk`, `run` and `profile` included. */
  onMachineCopilotState(cb: (machineId: string, state: unknown) => void): () => void
  /**
   * A slice of the conversation with that machine's copilot.
   *
   * The whole `copilot.chat` frame rather than one bubble: `run` says which run
   * it belongs to, so a frame from a run that has ended is dropped instead of
   * spliced onto a live conversation, and `reset` says to throw away what is
   * held. Merging is the renderer's — nothing in main keeps a transcript.
   */
  onMachineCopilotChat(cb: (machineId: string, bubble: unknown) => void): () => void
  onMachinesState(cb: (view: unknown) => void): () => void
  onMachineOutput(cb: (chunk: unknown) => void): () => void
  /**
   * Send a file from this machine into a session running on that one.
   *
   * A path, never the bytes: `pathForDroppedFile` has already turned the dropped
   * `File` into a real path, and streaming it off disk in the main process is
   * what keeps a 200 MB video out of the renderer's heap. Answers with the path
   * it landed at over there — which is what gets typed at the prompt, and which
   * may not be the name it left with — or with a sentence.
   */
  uploadToMachine(id: string, filePath: string): Promise<unknown>
  cancelMachineUpload(id: string): Promise<unknown>
  /** Slice-by-slice progress for the transfer to that machine. */
  onMachineUpload(cb: (progress: unknown) => void): () => void
}

declare global {
  interface Window {
    deck: DeckApi
  }
}
