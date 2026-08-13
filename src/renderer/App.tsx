import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { StoreProvider, useStore } from './state/store'
import { TerminalView } from './components/TerminalView'
import { EmptyState } from './components/EmptyState'
import { SettingsWindow } from './settings/SettingsWindow'
import { NewSessionDialog } from './components/NewSessionDialog'
import { HelpDialog } from './components/HelpPanel'
import { JoinRemoteDialog } from './components/JoinRemoteDialog'
import { SessionInspector } from './components/SessionInspector'
import {
  CloseSessionConfirm,
  needsCloseConfirm,
  readConfirmClose,
} from './components/CloseSessionConfirm'
import { CommandPalette, type PaletteCommand } from './components/CommandPalette'
import { ShortcutsSheet } from './components/ShortcutsSheet'
import { Onboarding } from './components/Onboarding'
import { ChatView } from './components/ChatView'
import { UpdateBanner } from './updates/UpdateBanner'
import { ChatToggle, type SessionViewMode } from './components/ChatToggle'
import { BrowserWorkspace } from './browser/BrowserWorkspace'
import { SwarmGrid } from './layout/SwarmGrid'
import { Sidebar } from './shell/Sidebar'
import { WindowToolbar } from './shell/WindowToolbar'
import { PanelView } from './shell/PanelView'
import { useSidebar } from './shell/useSidebar'
import { panelSpec } from './shell/panels'
import { nextActiveId, sessionLabel, type WorkspaceTab } from './shell/workspace-tabs'
import { ErrorBoundary } from './shell/ErrorBoundary'
import { applyStoredTheme } from './theme'
import { UnreadTracker } from './unread'
import { mergeSettings, stringSetting } from './settings/settings-schema'
import { toStoredSettings } from './settings/settings-bridge'
import { resolveCommand, scopeForTarget, tip } from './keymap'
import './shell/shell.css'

/** Toolbar icons, 24×24, 1.5 stroke — the same grid the sidebar draws on. */
const ICON = {
  inspector: 'M12 4.6c-4.3 0-7.4 3.2-8.6 5.2a2 2 0 0 0 0 2c1.2 2 4.3 5.2 8.6 5.2s7.4-3.2 8.6-5.2a2 2 0 0 0 0-2c-1.2-2-4.3-5.2-8.6-5.2zM12 14a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4z',
  swarm: 'M4.5 4.5h6v6h-6zM13.5 4.5h6v6h-6zM4.5 13.5h6v6h-6zM13.5 13.5h6v6h-6z',
  palette: 'M11 4.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM19.5 19.5l-3.9-3.9',
}

/** Last segment of a path, or null. The store's own `folderName`, minus the store. */
function folderNameOf(path: string | undefined): string | undefined {
  if (!path) return undefined
  const parts = path.split('/').filter(Boolean)
  return parts[parts.length - 1]
}

function ToolbarIcon({ path }: { path: string }) {
  return (
    <svg
      width="17"
      height="17"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={path} />
    </svg>
  )
}

function Workspace() {
  const {
    projects,
    sessions,
    activeSessionId,
    addProject,
    addSession,
    removeProject,
    removeSession,
    setActiveSession,
    setSessionStatus,
  } = useStore()

  /**
   * Which sessions have produced something the user has not looked at.
   *
   * Built once and kept in a ref: it is a plain object with subscribers, not
   * React state, so a chunk of PTY output on a background session costs one
   * Set insert rather than a render of the whole shell. Only the *snapshot*
   * is state, and it changes only when a session actually flips.
   */
  const unreadRef = useRef<UnreadTracker>(undefined)
  if (!unreadRef.current) unreadRef.current = new UnreadTracker()
  const unread = unreadRef.current
  const [unreadIds, setUnreadIds] = useState<readonly string[]>([])

  const sidebar = useSidebar()
  const { panel, selectPanel, clearPanel } = sidebar
  const [extraTabs, setExtraTabs] = useState<WorkspaceTab[]>([])
  const [activeTabId, setActiveTabId] = useState<string | null>(null)
  const [swarm, setSwarm] = useState(false)
  const [sessionView, setSessionView] = useState<Record<string, SessionViewMode>>({})
  const [openFile, setOpenFile] = useState<string | null>(null)
  /** The session a close is waiting on, and whether to ask at all. */
  const [pendingClose, setPendingClose] = useState<WorkspaceTab | null>(null)
  const [confirmClose, setConfirmClose] = useState(true)
  const [prefsOpen, setPrefsOpen] = useState(false)
  const [newSessionOpen, setNewSessionOpen] = useState(false)
  const [helpOpen, setHelpOpen] = useState(false)
  const [joinOpen, setJoinOpen] = useState(false)
  const [inspectorOpen, setInspectorOpen] = useState(false)
  const [paletteMode, setPaletteMode] = useState<'files' | 'commands' | null>(null)
  const [shortcutsOpen, setShortcutsOpen] = useState(false)
  const [onboardingDone, setOnboardingDone] = useState(false)
  const [needsOnboarding, setNeedsOnboarding] = useState<boolean | null>(null)

  /**
   * Any app-level dialog being open.
   *
   * The browser's pages are native WebContentsViews layered ABOVE the HTML, so
   * every modal opens behind them — pressing Cmd+, while the Browser view was
   * active dimmed the app and showed nothing, because Settings was underneath
   * the web page. The pages have to be parked while a dialog is up; the panel
   * around them stays, or the workspace behind the dialog goes blank.
   */
  const anyModalOpen =
    prefsOpen || newSessionOpen || helpOpen || joinOpen || inspectorOpen || shortcutsOpen ||
    pendingClose !== null || paletteMode !== null

  /** Sessions first, then anything else the user opened, in one list. */
  const tabs: WorkspaceTab[] = [
    ...sessions.map((session) => ({
      id: session.id,
      kind: 'session' as const,
      label: session.title,
      status: session.status,
      projectPath: session.projectPath,
      closable: true,
    })),
    ...extraTabs,
  ]

  const activeTab = tabs.find((t) => t.id === activeTabId) ?? tabs[0] ?? null
  const activeSession = activeTab?.kind === 'session' ? activeTab : null
  /** The full record behind the open session — a tab carries only its label. */
  const activeSessionMeta = activeSession
    ? sessions.find((s) => s.id === activeSession.id) ?? null
    : null

  /** True while one of the sidebar's views has the window. */
  const showingPanel = panel !== null

  /**
   * What a session is called on screen, the same way the sidebar names it.
   *
   * Three surfaces print this — the sidebar row, the toolbar title and the
   * close confirmation — and they have to agree, or the dialog asks about
   * "terminaldeck" while the row the user clicked said "Session 2".
   */
  const labelOf = (tab: WorkspaceTab): string => {
    if (tab.kind !== 'session') return tab.label
    const siblings = tabs.filter(
      (t) => t.kind === 'session' && t.projectPath === tab.projectPath,
    )
    return sessionLabel(
      tab.label,
      siblings.findIndex((t) => t.id === tab.id),
      folderNameOf(tab.projectPath),
    )
  }

  const activeProjectPath =
    activeSession?.projectPath ??
    sessions.find((s) => s.id === activeSessionId)?.projectPath ??
    projects[0]?.path ??
    null

  useEffect(() => {
    const off = window.deck.onSessionStatus((id, status) => setSessionStatus(id, status))
    return off
  }, [setSessionStatus])

  useEffect(() => unread.subscribe((snapshot) => setUnreadIds(snapshot.ids)), [unread])

  /**
   * Output on a session nobody is looking at lights its row.
   *
   * One app-level subscription, not one per session: `onSessionData` already
   * broadcasts every chunk with its id, and the tracker's own noise filter is
   * what keeps a spinner from badging a tab forever.
   */
  useEffect(
    () => window.deck.onSessionData((id, chunk) => unread.recordOutput(id, chunk)),
    [unread],
  )

  /**
   * A session this window did not ask for — one started from a paired phone.
   *
   * It is added without focus on purpose. The alternative is that answering a
   * message on your phone yanks the Mac out of whatever terminal you were
   * typing into, which is the one thing a second device must never do. It
   * arrives the way anything else arrives here: a row in the sidebar with an
   * unread dot, cleared the moment it is opened.
   */
  useEffect(
    () =>
      window.deck.onSessionCreated((meta) => {
        addSession(meta, { focus: false })
        unread.recordOutput(meta.id)
      }),
    [addSession, unread],
  )

  /**
   * What counts as "being looked at": the session on screen, in a focused
   * window, with no view covering it. Alt-tabbing back clears the one in
   * front; walking away clears nothing.
   */
  useEffect(() => {
    const sync = () =>
      unread.setViewing({
        activeSessionId: showingPanel ? null : activeTab?.id ?? null,
        windowFocused: document.hasFocus(),
      })
    sync()
    window.addEventListener('focus', sync)
    window.addEventListener('blur', sync)
    return () => {
      window.removeEventListener('focus', sync)
      window.removeEventListener('blur', sync)
    }
  }, [unread, activeTab?.id, showingPanel])

  useEffect(() => {
    void window.deck.getPreferences().then((p) => applyStoredTheme(p.theme))
  }, [])

  // Whether closing a working session asks first. Read once and kept in step
  // with Settings, because a disk round-trip inside ⌘W would be felt.
  useEffect(() => {
    void readConfirmClose().then(setConfirmClose)
  }, [])

  /**
   * Density, applied at launch.
   *
   * `SettingsWindow` writes this attribute whenever it loads or a control
   * changes — but only when it has been opened. Until then every
   * `[data-density='compact']` rule in the app was inert, so choosing Compact
   * held until the next launch and then quietly stopped applying.
   */
  useEffect(() => {
    void window.deck
      .getSettings()
      .then((stored) => {
        document.documentElement.dataset.density = stringSetting(
          mergeSettings(toStoredSettings(stored)),
          'appearance.density',
        )
      })
      .catch(() => {
        // The schema default is what the stylesheets already assume.
      })
  }, [])

  useEffect(() => {
    let cancelled = false
    void window.deck.listProjects().then((saved) => {
      if (cancelled) return
      for (const p of saved) addProject(p.path)
    })
    return () => {
      cancelled = true
    }
  }, [addProject])

  // Show the first-run screen only when no agent is usable. Someone with a
  // working setup should never be made to click through a welcome screen.
  useEffect(() => {
    void window.deck
      .checkPrerequisites()
      .then((p) => setNeedsOnboarding(!(p as { canRunSessions: boolean }).canRunSessions))
      .catch(() => setNeedsOnboarding(false))
  }, [])

  /** Show a session or page in the window, leaving whatever view was over it. */
  const showTab = useCallback(
    (id: string) => {
      clearPanel()
      setActiveTabId(id)
    },
    [clearPanel],
  )

  const openProject = useCallback(async () => {
    const path = await window.deck.pickProjectFolder()
    if (!path) return
    addProject(path)
    void window.deck.addProject(path)
    const meta = await window.deck.createSession({ cwd: path, cols: 100, rows: 30 })
    addSession(meta)
    setOnboardingDone(true)
    showTab(meta.id)
  }, [addProject, addSession, showTab])

  const newSessionIn = useCallback(
    async (path: string, resume = false) => {
      const meta = await window.deck.createSession({ cwd: path, cols: 100, rows: 30, resume })
      addSession(meta)
      showTab(meta.id)
    },
    [addSession, showTab],
  )

  /** ⌘T and the sidebar's primary button: a session wherever you last were. */
  const newSession = useCallback(
    (path?: string, resume = false) => {
      const target = path ?? activeProjectPath
      if (target) void newSessionIn(target, resume)
      else void openProject()
    },
    [activeProjectPath, newSessionIn, openProject],
  )

  const newBrowserTab = useCallback(() => {
    const id = `browser:${Date.now()}`
    setExtraTabs((prev) => [...prev, { id, kind: 'browser', label: 'New tab', closable: true }])
    showTab(id)
  }, [showTab])

  const closeTabNow = useCallback(
    (id: string) => {
      const tab = tabs.find((t) => t.id === id)
      const following = nextActiveId(tabs, id)
      unread.forget(id)
      if (tab?.kind === 'session') {
        void window.deck.killSession(id)
        removeSession(id)
      } else {
        setExtraTabs((prev) => prev.filter((t) => t.id !== id))
      }
      setActiveTabId(following)
    },
    [tabs, removeSession, unread],
  )

  /**
   * Close, asking first when the session has something to lose.
   *
   * `CloseSessionConfirm` was written, tested and left on the unreachable list
   * while Settings offered a switch called "Confirm closing an active session"
   * that turned nothing on. The gate lives here rather than in the dialog for
   * the reason its own comment gives: a component that decides for itself
   * whether to appear can only decline by rendering nothing, which leaves the
   * user having pressed Close with no dialog and no session closed.
   */
  const closeTab = useCallback(
    (id: string) => {
      const tab = tabs.find((t) => t.id === id)
      if (tab?.kind === 'session' && tab.status && needsCloseConfirm(tab.status, confirmClose)) {
        setPendingClose(tab)
        return
      }
      closeTabNow(id)
    },
    [tabs, confirmClose, closeTabNow],
  )

  const selectTab = useCallback(
    (id: string) => {
      showTab(id)
      // Terminals key off the store's active session; keep the two in step or
      // switching to a session shows the previously focused terminal.
      if (sessions.some((session) => session.id === id)) setActiveSession(id)
    },
    [sessions, setActiveSession, showTab],
  )

  /** Step through the open sessions and pages, wrapping at each end. */
  const cycleTab = useCallback(
    (delta: number) => {
      if (tabs.length < 2) return
      const at = tabs.findIndex((t) => t.id === activeTab?.id)
      const next = tabs[(at + delta + tabs.length) % tabs.length]
      selectTab(next.id)
    },
    [tabs, activeTab, selectTab],
  )

  /** Source control hands a file here; the Files page is what can show it. */
  const showFile = useCallback(
    (relPath: string) => {
      setOpenFile(relPath)
      selectPanel('files')
    },
    [selectPanel],
  )

  const commands = useMemo<PaletteCommand[]>(
    () => [
      { id: 'session.new', title: 'New session', group: 'Session', shortcut: '⌘T', run: () => newSession() },
      { id: 'session.resume', title: 'Continue last session', group: 'Session', shortcut: '⌘⇧R', run: () => newSession(undefined, true) },
      // The only way to reach the dialog that picks an agent, a prompt and a
      // login was the app menu. A menu is a control, but it is not a findable
      // one, and this is the screen where a session is configured.
      { id: 'session.newDialog', title: 'New session with options…', group: 'Session', shortcut: '⌘⇧T', run: () => setNewSessionOpen(true) },
      { id: 'project.open', title: 'Open a project', group: 'Project', shortcut: '⌘O', run: () => void openProject() },
      { id: 'palette.quickOpen', title: 'Open a file…', group: 'Project', shortcut: '⌘P', run: () => setPaletteMode('files') },
      { id: 'view.browser', title: 'New browser tab', group: 'View', run: () => newBrowserTab() },
      { id: 'view.swarm', title: 'Toggle swarm view', group: 'View', shortcut: '⌘\\', run: () => setSwarm((value) => !value) },
      { id: 'view.overview', title: 'Overview', group: 'View', shortcut: '⌘⇧D', run: () => selectPanel('overview') },
      { id: 'view.files', title: 'Files', group: 'View', shortcut: '⌘⇧E', run: () => selectPanel('files') },
      { id: 'view.search', title: 'Search past sessions', group: 'View', shortcut: '⌘⇧F', run: () => selectPanel('search') },
      { id: 'view.git', title: 'Source control', group: 'View', shortcut: '⌘⇧G', run: () => selectPanel('git') },
      { id: 'view.board', title: 'Task board', group: 'View', shortcut: '⌘⇧B', run: () => selectPanel('board') },
      { id: 'view.github', title: 'GitHub', group: 'View', run: () => selectPanel('github') },
      { id: 'view.alerts', title: 'Alerts', group: 'View', run: () => selectPanel('alerts') },
      { id: 'view.readiness', title: 'AI readiness', group: 'View', run: () => selectPanel('readiness') },
      { id: 'view.mcp', title: 'MCP servers', group: 'View', run: () => selectPanel('mcp') },
      { id: 'view.hooks', title: 'Hooks', group: 'View', run: () => selectPanel('hooks') },
      { id: 'view.sidebar', title: 'Show or hide the sidebar', group: 'View', shortcut: '⌘B', run: () => sidebar.toggleCollapsed() },
      { id: 'view.inspector', title: 'Session details', group: 'App', shortcut: '⌘⇧I', run: () => setInspectorOpen(true) },
      { id: 'app.preferences', title: 'Settings', group: 'App', shortcut: '⌘,', run: () => setPrefsOpen(true) },
      { id: 'app.help', title: 'Help', group: 'App', run: () => setHelpOpen(true) },
      { id: 'app.join', title: 'Join a remote session', group: 'App', run: () => setJoinOpen(true) },
      { id: 'app.shortcuts', title: 'Keyboard shortcuts', group: 'App', shortcut: '⌘/', run: () => setShortcutsOpen(true) },
    ],
    [newSession, newBrowserTab, openProject, selectPanel, sidebar],
  )

  /**
   * One dispatcher for every command, whatever fired it: a menu item, a chord
   * or a row in the palette. The three used to be three switch statements, and
   * the shortcuts sheet documented chords none of them implemented.
   */
  const run = useCallback(
    (id: string): boolean => {
      const command = commands.find((c) => c.id === id)
      if (command) {
        void command.run()
        return true
      }
      switch (id) {
        case 'session.close':
          if (activeTab) closeTab(activeTab.id)
          return true
        case 'session.next':
          cycleTab(1)
          return true
        case 'session.previous':
          cycleTab(-1)
          return true
        // The application menu speaks an older dialect than the keymap does.
        // Rather than two tables of truth, the menu's ids land here as aliases
        // for the command they have always meant.
        case 'app.palette':
        case 'palette.commands':
          setPaletteMode('commands')
          return true
        case 'app.quickOpen':
          setPaletteMode('files')
          return true
        case 'panel.search':
          selectPanel('search')
          return true
        case 'app.inspector':
          setInspectorOpen(true)
          return true
        case 'view.dashboard':
          selectPanel('overview')
          return true
        case 'view.terminal':
          if (sessions[0]) selectTab(sessions[0].id)
          return true
        case 'app.about':
        case 'app.setup':
          setPrefsOpen(true)
          return true
        default:
          return false
      }
    },
    [commands, activeTab, closeTab, cycleTab, selectPanel, selectTab, sessions],
  )

  // Menu items dispatch the same commands the palette runs, so a menu entry
  // and its shortcut can never drift apart.
  useEffect(() => window.deck.onMenuCommand((command) => void run(command)), [run])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const scope = scopeForTarget(e.target, { modalOpen: anyModalOpen })
      if (scope === 'modal') return

      // ⌘1–9 is a range in the keymap, so the digit has to be read here.
      const digit = Number(e.key)
      if (
        (e.metaKey || e.ctrlKey) &&
        !e.shiftKey &&
        !e.altKey &&
        Number.isInteger(digit) &&
        digit >= 1 &&
        digit <= 9
      ) {
        if (tabs[digit - 1]) {
          e.preventDefault()
          selectTab(tabs[digit - 1].id)
        }
        return
      }

      const id = resolveCommand(e, { scope })
      if (!id) return
      if (id === 'session.jump') return
      if (run(id)) e.preventDefault()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [run, tabs, selectTab, anyModalOpen])

  if (needsOnboarding && !onboardingDone) {
    return (
      <div className="app app-plain">
        <div className="window-drag" />
        <Onboarding onContinue={() => setOnboardingDone(true)} onOpenProject={openProject} />
      </div>
    )
  }

  const mainView = () => {
    if (showingPanel && panel) {
      return (
        <PanelView
          panel={panel}
          projectPath={activeProjectPath}
          onOpenProject={openProject}
          openFile={openFile}
          onOpenFile={setOpenFile}
        />
      )
    }

    if (!activeTab) return <EmptyState onOpenProject={openProject} />

    if (swarm) {
      return (
        <SwarmGrid
          // Named the way the sidebar names them, so a grid of sessions in one
          // project is not four cells all headed with the folder's name.
          sessions={sessions.map((session, index) => ({
            id: session.id,
            title: sessionLabel(session.title, index, folderNameOf(session.projectPath)),
            status: session.status,
          }))}
          activeSessionId={activeSessionId}
          onFocusSession={selectTab}
          // The leftover slots in the grid are a real affordance or they are a
          // row of empty boxes. Without this they were the second thing.
          onNewSession={() => newSession()}
          renderCell={({ session }) => <TerminalView sessionId={session.id} visible />}
        />
      )
    }

    // Every browser and terminal stays mounted and is shown or hidden, so a
    // page keeps its scroll position and a terminal keeps its scrollback when
    // you switch away and come back.
    return (
      <>
        {tabs
          .filter((tab) => tab.kind === 'browser')
          .map((tab) => (
            <BrowserWorkspace
              key={tab.id}
              // Which page is on screen, and nothing else. Folding the modal
              // flag in here would blank the workspace behind every dialog —
              // parking the native pages is what a dialog needs, and that is
              // what `parkPage` is.
              visible={tab.id === activeTab.id && !showingPanel}
              parkPage={anyModalOpen}
              onSendToAgent={(context) => {
                if (activeSessionId) window.deck.writeToSession(activeSessionId, context)
              }}
            />
          ))}
        {sessions.map((session) => {
          const active = session.id === activeTab.id
          const mode = sessionView[session.id] ?? 'terminal'
          return (
            <Fragment key={session.id}>
              {/* The terminal stays mounted in chat mode — only hidden — so
                  scrollback and cursor survive a trip through Chat. */}
              <TerminalView sessionId={session.id} visible={active && mode === 'terminal'} />
              {active && mode === 'chat' ? (
                <ChatView
                  cwd={session.projectPath ?? null}
                  // Which conversation this pane is a view of. Without it the
                  // pane reads the folder's newest transcript, which is any
                  // `claude` running here — including ones this app did not
                  // start.
                  session={{ startedAt: session.createdAt, resumed: session.resumed }}
                  // Without this the controls row and the usage strip both
                  // render in their "no session focused" state: model, effort
                  // and permission mode are read off this session's screen.
                  sessionId={session.id}
                  onSend={(text) => {
                    // Written to the session's own terminal: chat mode is a
                    // different view of the same session, not a second channel,
                    // so a reply typed here also appears in the terminal view.
                    window.deck.writeToSession(session.id, `${text}\r`)
                  }}
                />
              ) : null}
            </Fragment>
          )
        })}
      </>
    )
  }

  const heading = showingPanel && panel
    ? { title: panelSpec(panel).label, subtitle: panelSpec(panel).blurb }
    : activeTab
      ? {
          title: labelOf(activeTab),
          subtitle: activeTab.kind === 'session' ? activeTab.projectPath ?? null : null,
        }
      : { title: 'Terminal Deck', subtitle: 'Nothing open yet.' }

  return (
    <div className="app">
      {!sidebar.collapsed && (
        <Sidebar
          width={sidebar.width}
          projects={projects}
          tabs={tabs}
          activeTabId={activeTab?.id ?? null}
          activePanel={panel}
          unread={unreadIds}
          onSelectTab={selectTab}
          onCloseTab={closeTab}
          onSelectPanel={selectPanel}
          onNewSession={newSession}
          onNewBrowserTab={newBrowserTab}
          onOpenProject={openProject}
          onCloseProject={removeProject}
          onOpenSettings={() => setPrefsOpen(true)}
          onStartResize={sidebar.startResize}
        />
      )}

      <main className="main">
        <WindowToolbar
          title={heading.title}
          subtitle={heading.subtitle}
          sidebarCollapsed={sidebar.collapsed}
          onToggleSidebar={sidebar.toggleCollapsed}
        >
          {/* Swarm shows every terminal at once, so a Terminal/Chat switch for
              "the" session would be a control with no session to act on. */}
          {activeSession && !showingPanel && !swarm ? (
            <ChatToggle
              mode={sessionView[activeSession.id] ?? 'terminal'}
              onChange={(mode) =>
                setSessionView((views) => ({ ...views, [activeSession.id]: mode }))
              }
            />
          ) : null}
          {sessions.length > 1 && !showingPanel && (
            <button
              type="button"
              className={`toolbar-btn${swarm ? ' on' : ''}`}
              aria-pressed={swarm}
              onClick={() => setSwarm((value) => !value)}
              aria-label="Swarm view"
              title={tip('Every session at once', 'view.swarm')}
            >
              <ToolbarIcon path={ICON.swarm} />
            </button>
          )}
          {activeSession && (
            <button
              type="button"
              className="toolbar-btn"
              onClick={() => setInspectorOpen(true)}
              aria-label="Session details"
              title={tip('Session details', 'view.inspector')}
            >
              <ToolbarIcon path={ICON.inspector} />
            </button>
          )}
          <button
            type="button"
            className="toolbar-btn"
            onClick={() => setPaletteMode('commands')}
            aria-label="Command palette"
            title={tip('Command palette', 'palette.commands')}
          >
            <ToolbarIcon path={ICON.palette} />
          </button>
        </WindowToolbar>

        {/* Under the toolbar, above the work: an update is worth interrupting
            the chrome for, but never the work — a session may be mid-run, so
            this is a banner and not a modal. */}
        <UpdateBanner />

        <div className="panes">
          <ErrorBoundary label={heading.title}>{mainView()}</ErrorBoundary>
        </div>
      </main>

      <SettingsWindow
        open={prefsOpen}
        onClose={() => setPrefsOpen(false)}
        // The confirm-on-close switch is read here as well as there, so a
        // change has to reach this copy or the next ⌘W disagrees with it.
        onChange={(values) => setConfirmClose(values['general.confirmCloseWorking'] !== false)}
      />
      <CloseSessionConfirm
        open={pendingClose !== null}
        title={pendingClose ? labelOf(pendingClose) : ''}
        status={pendingClose?.status ?? 'idle'}
        provider={sessions.find((s) => s.id === pendingClose?.id)?.provider}
        onCancel={() => setPendingClose(null)}
        onConfirm={() => {
          const closing = pendingClose
          setPendingClose(null)
          if (closing) closeTabNow(closing.id)
        }}
        // The dialog writes the setting itself; this keeps the copy above in
        // step so the very next close does not ask again.
        onConfirmSettingChange={setConfirmClose}
      />
      <NewSessionDialog
        open={newSessionOpen}
        projectPath={activeProjectPath}
        onClose={() => setNewSessionOpen(false)}
        onStart={async (request) => {
          setNewSessionOpen(false)
          const meta = await window.deck.createSession(request)
          addSession(meta)
          showTab(meta.id)
        }}
      />
      <HelpDialog open={helpOpen} onClose={() => setHelpOpen(false)} />
      <JoinRemoteDialog open={joinOpen} onClose={() => setJoinOpen(false)} />
      <SessionInspector
        open={inspectorOpen}
        onClose={() => setInspectorOpen(false)}
        cwd={activeSessionMeta?.projectPath ?? activeProjectPath}
        // The session in front of you, not whatever the store last marked
        // active — those disagree the moment you switch to a browser page, and
        // the dialog was heading one session's numbers with another's name.
        session={
          activeSessionMeta
            ? { startedAt: activeSessionMeta.createdAt, resumed: activeSessionMeta.resumed }
            : null
        }
        sessionTitle={activeSessionMeta?.title}
      />
      <ShortcutsSheet open={shortcutsOpen} onClose={() => setShortcutsOpen(false)} />
      <CommandPalette
        open={paletteMode !== null}
        mode={paletteMode ?? 'commands'}
        commands={commands}
        projectRoot={activeProjectPath}
        onClose={() => setPaletteMode(null)}
        onOpenFile={(selection) => {
          setPaletteMode(null)
          showFile(selection.path)
        }}
      />
    </div>
  )
}

export function App() {
  return (
    <StoreProvider>
      <Workspace />
    </StoreProvider>
  )
}
