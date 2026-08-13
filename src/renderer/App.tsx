import { Fragment, useCallback, useEffect, useMemo, useState } from 'react'
import { StoreProvider, useStore } from './state/store'
import { TitleBar } from './components/TitleBar'
import { TerminalView } from './components/TerminalView'
import { EmptyState } from './components/EmptyState'
import { SettingsWindow } from './settings/SettingsWindow'
import { NewSessionDialog } from './components/NewSessionDialog'
import { HelpDialog } from './components/HelpPanel'
import { JoinRemoteDialog } from './components/JoinRemoteDialog'
import { SessionInspector } from './components/SessionInspector'
import { CommandPalette, type PaletteCommand } from './components/CommandPalette'
import { ShortcutsSheet } from './components/ShortcutsSheet'
import { Onboarding } from './components/Onboarding'
import { ChatView } from './components/ChatView'
import { UpdateBanner } from './updates/UpdateBanner'
import { ChatToggle, type SessionViewMode } from './components/ChatToggle'
import { BrowserWorkspace } from './browser/BrowserWorkspace'
import { SwarmGrid } from './layout/SwarmGrid'
import { ActivityBar } from './shell/ActivityBar'
import { PanelDock } from './shell/PanelDock'
import { usePanelDock } from './shell/usePanelDock'
import { HeaderTabs } from './shell/HeaderTabs'
import { nextActiveId, type TabKind, type WorkspaceTab } from './shell/workspace-tabs'
import { ErrorBoundary } from './shell/ErrorBoundary'
import { applyStoredTheme } from './theme'
import './shell/shell.css'

function Workspace() {
  const {
    projects,
    sessions,
    activeSessionId,
    addProject,
    addSession,
    removeSession,
    setActiveSession,
    setSessionStatus,
  } = useStore()

  const dock = usePanelDock()
  const { panel, selectPanel: setPanel } = dock
  const [extraTabs, setExtraTabs] = useState<WorkspaceTab[]>([])
  const [activeTabId, setActiveTabId] = useState<string | null>(null)
  const [swarm, setSwarm] = useState(false)
  const [sessionView, setSessionView] = useState<Record<string, SessionViewMode>>({})
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
   * The browser is a native WebContentsView layered ABOVE the HTML, so every
   * modal opens behind it — pressing Cmd+, while the Browser view was active
   * dimmed the app and showed nothing, because Settings was underneath the
   * web page. The view has to be hidden while a dialog is up.
   */
  const anyModalOpen =
    prefsOpen || newSessionOpen || helpOpen || joinOpen || inspectorOpen || shortcutsOpen ||
    paletteMode !== null

  /** Sessions first, then anything else the user opened, in one strip. */
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

  const activeProjectPath =
    activeSession?.projectPath ??
    sessions.find((s) => s.id === activeSessionId)?.projectPath ??
    projects[0]?.path ??
    null

  useEffect(() => {
    const off = window.deck.onSessionStatus((id, status) => setSessionStatus(id, status))
    return off
  }, [setSessionStatus])

  useEffect(() => {
    void window.deck.getPreferences().then((p) => applyStoredTheme(p.theme))
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

  const openProject = useCallback(async () => {
    const path = await window.deck.pickProjectFolder()
    if (!path) return
    addProject(path)
    void window.deck.addProject(path)
    const meta = await window.deck.createSession({ cwd: path, cols: 100, rows: 30 })
    addSession(meta)
    setOnboardingDone(true)
    setActiveTabId(meta.id)
  }, [addProject, addSession])

  const newSessionIn = useCallback(
    async (path: string, resume = false) => {
      const meta = await window.deck.createSession({ cwd: path, cols: 100, rows: 30, resume })
      addSession(meta)
      setActiveTabId(meta.id)
    },
    [addSession],
  )

  const openTab = useCallback(
    (kind: TabKind) => {
      if (kind === 'session') {
        if (activeProjectPath) void newSessionIn(activeProjectPath)
        else void openProject()
        return
      }
      // Overview and Board show the same thing however many times you open
      // them, so focus the existing tab instead of stacking duplicates.
      const id = `browser:${Date.now()}`
      setExtraTabs((prev) => [...prev, { id, kind, label: 'New tab', closable: true }])
      setActiveTabId(id)
    },
    [activeProjectPath, newSessionIn, openProject],
  )

  const closeTab = useCallback(
    (id: string) => {
      const tab = tabs.find((t) => t.id === id)
      const following = nextActiveId(tabs, id)
      if (tab?.kind === 'session') {
        void window.deck.killSession(id)
        removeSession(id)
      } else {
        setExtraTabs((prev) => prev.filter((t) => t.id !== id))
      }
      setActiveTabId(following)
    },
    [tabs, removeSession],
  )

  const closeSession = useCallback(
    async (id: string) => {
      await window.deck.killSession(id)
      removeSession(id)
    },
    [removeSession],
  )

  const selectTab = useCallback(
    (id: string) => {
      setActiveTabId(id)
      // Terminals key off the store's active session; keep the two in step or
      // switching to a session tab shows the previously focused terminal.
      if (sessions.some((session) => session.id === id)) setActiveSession(id)
    },
    [sessions, setActiveSession],
  )

  const commands = useMemo<PaletteCommand[]>(
    () => [
      { id: 'session.new', title: 'New session', group: 'Session', shortcut: '⌘T', run: () => activeProjectPath && void newSessionIn(activeProjectPath) },
      { id: 'session.resume', title: 'Continue last session', group: 'Session', shortcut: '⌘⇧T', run: () => activeProjectPath && void newSessionIn(activeProjectPath, true) },
      { id: 'project.open', title: 'Open a project', group: 'Project', shortcut: '⌘O', run: () => void openProject() },
      { id: 'view.overview', title: 'Show project overview', group: 'View', run: () => setPanel('overview') },
      { id: 'view.board', title: 'Show task board', group: 'View', run: () => setPanel('board') },
      { id: 'view.browser', title: 'Show browser', group: 'View', run: () => openTab('browser') },
      { id: 'view.swarm', title: 'Toggle swarm view', group: 'View', shortcut: '⌘\\', run: () => setSwarm((value) => !value) },
      { id: 'panel.git', title: 'Show source control', group: 'Panel', run: () => setPanel('git') },
      { id: 'panel.files', title: 'Show files', group: 'Panel', run: () => setPanel('files') },
      { id: 'panel.search', title: 'Search past sessions', group: 'Panel', shortcut: '⌘⇧F', run: () => setPanel('search') },
      { id: 'panel.alerts', title: 'Show alerts', group: 'Panel', run: () => setPanel('alerts') },
      { id: 'panel.github', title: 'Show GitHub', group: 'Panel', run: () => setPanel('github') },
      { id: 'panel.readiness', title: 'Show AI readiness', group: 'Panel', run: () => setPanel('readiness') },
      { id: 'panel.mcp', title: 'Show MCP servers', group: 'Panel', run: () => setPanel('mcp') },
      { id: 'panel.hooks', title: 'Show hooks', group: 'Panel', run: () => setPanel('hooks') },
      { id: 'app.inspector', title: 'Session inspector', group: 'App', shortcut: '⌘⇧I', run: () => setInspectorOpen(true) },
      { id: 'app.prefs', title: 'Preferences', group: 'App', shortcut: '⌘,', run: () => setPrefsOpen(true) },
      { id: 'app.shortcuts', title: 'Keyboard shortcuts', group: 'App', shortcut: '⌘/', run: () => setShortcutsOpen(true) },
    ],
    [activeProjectPath, newSessionIn, openProject],
  )

  // Menu items dispatch the same commands the palette runs, so a menu entry
  // and its shortcut can never drift apart.
  useEffect(() => {
    return window.deck.onMenuCommand((command) => {
      const run = commands.find((c) => c.id === command)
      if (run) {
        void run.run()
        return
      }
      switch (command) {
        case 'session.newDialog': setNewSessionOpen(true); break
        case 'session.close': if (activeTab) closeTab(activeTab.id); break
        case 'view.terminal': if (sessions[0]) selectTab(sessions[0].id); break
        case 'view.sidebar': dock.toggleCollapsed(); break
        case 'app.palette': setPaletteMode('commands'); break
        case 'app.quickOpen': setPaletteMode('files'); break
        case 'app.help': setHelpOpen(true); break
        case 'app.about': setPrefsOpen(true); break
        case 'app.setup': setPrefsOpen(true); break
        default: break
      }
    })
  }, [commands, activeSessionId, closeSession, dock])

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey
      if (!mod) return

      if (e.key === 't' || e.key === 'T') {
        e.preventDefault()
        if (e.shiftKey) setNewSessionOpen(true)
        else if (activeProjectPath) void newSessionIn(activeProjectPath)
        else void openProject()
        return
      }
      if (e.key === 'w' && activeTab) {
        e.preventDefault()
        closeTab(activeTab.id)
        return
      }
      if (e.key === 'o') {
        e.preventDefault()
        void openProject()
        return
      }
      if (e.key === ',') {
        e.preventDefault()
        setPrefsOpen(true)
        return
      }
      if (e.key === '/') {
        e.preventDefault()
        setShortcutsOpen(true)
        return
      }
      if (e.key === 'b' || e.key === 'B') {
        e.preventDefault()
        dock.toggleCollapsed()
        return
      }
      if (e.key === '\\') {
        e.preventDefault()
        setSwarm((value) => !value)
        return
      }
      if (e.key === 'p' || e.key === 'P') {
        e.preventDefault()
        setPaletteMode(e.shiftKey ? 'commands' : 'files')
        return
      }
      if (e.key === 'k' || e.key === 'K') {
        e.preventDefault()
        setPaletteMode('commands')
        return
      }
      if (e.shiftKey && (e.key === 'f' || e.key === 'F')) {
        e.preventDefault()
        setPanel('search')
        return
      }
      if (e.shiftKey && (e.key === 'i' || e.key === 'I')) {
        e.preventDefault()
        setInspectorOpen(true)
        return
      }
      const n = Number(e.key)
      if (Number.isInteger(n) && n >= 1 && n <= 9 && tabs[n - 1]) {
        e.preventDefault()
        selectTab(tabs[n - 1].id)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [
    sessions,
    activeProjectPath,
    activeSessionId,
    newSessionIn,
    openProject,
    closeSession,
    setActiveSession,
  ])

  if (needsOnboarding && !onboardingDone) {
    return (
      <div className="app">
        <TitleBar />
        <Onboarding onContinue={() => setOnboardingDone(true)} onOpenProject={openProject} />
      </div>
    )
  }

  const mainView = () => {
    if (!activeTab) return <EmptyState onOpenProject={openProject} />

    if (swarm) {
      return (
        <SwarmGrid
          sessions={sessions}
          activeSessionId={activeSessionId}
          onFocusSession={selectTab}
          renderCell={({ session }) => <TerminalView sessionId={session.id} visible />}
        />
      )
    }

    // Every browser and terminal stays mounted and is shown or hidden, so a
    // page keeps its scroll position and a terminal keeps its scrollback when
    // you switch tabs and come back.
    return (
      <>
        {tabs
          .filter((tab) => tab.kind === 'browser')
          .map((tab) => (
            <BrowserWorkspace
              key={tab.id}
              visible={tab.id === activeTab.id && !anyModalOpen}
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

  return (
    <div className="app">
      <TitleBar>
        <HeaderTabs
          tabs={tabs}
          activeId={activeTab?.id ?? null}
          onSelect={selectTab}
          onClose={closeTab}
          onOpen={openTab}
        />
      </TitleBar>
      {/* Below the tab strip, above everything else: an update is worth
          interrupting the chrome for, but never the work — a session may be
          mid-run, so this is a banner and not a modal. */}
      <UpdateBanner />
      <div className="app-body">
        <ActivityBar
          active={panel}
          onSelect={setPanel}
          onOpenSettings={() => setPrefsOpen(true)}
          onOpenHelp={() => setHelpOpen(true)}
        />
        <PanelDock
          panel={panel}
          projectPath={activeProjectPath}
          width={dock.width}
          collapsed={dock.collapsed}
          onToggleCollapsed={dock.toggleCollapsed}
          onStartResize={dock.startResize}
          onOpenProject={openProject}
          onNewSession={newSessionIn}
          onOpenFile={() => setPanel('files')}
        />
        <main className="workspace">
          {activeSession ? (
            <div className="chat-toggle-bar">
              <ChatToggle
                mode={sessionView[activeSession.id] ?? 'terminal'}
                onChange={(mode) =>
                  setSessionView((views) => ({ ...views, [activeSession.id]: mode }))
                }
              />
            </div>
          ) : null}
          <div className="panes">
            <ErrorBoundary label={activeTab?.label ?? 'Workspace'}>
              {mainView()}
            </ErrorBoundary>
          </div>
        </main>
      </div>

      <SettingsWindow open={prefsOpen} onClose={() => setPrefsOpen(false)} />
      <NewSessionDialog
        open={newSessionOpen}
        projectPath={activeProjectPath}
        onClose={() => setNewSessionOpen(false)}
        onStart={async (request) => {
          setNewSessionOpen(false)
          const meta = await window.deck.createSession(request)
          addSession(meta)
          setActiveTabId(meta.id)
        }}
      />
      <HelpDialog open={helpOpen} onClose={() => setHelpOpen(false)} />
      <JoinRemoteDialog open={joinOpen} onClose={() => setJoinOpen(false)} />
      <SessionInspector
        open={inspectorOpen}
        onClose={() => setInspectorOpen(false)}
        cwd={activeProjectPath}
        sessionTitle={sessions.find((s) => s.id === activeSessionId)?.title}
      />
      <ShortcutsSheet open={shortcutsOpen} onClose={() => setShortcutsOpen(false)} />
      <CommandPalette
        open={paletteMode !== null}
        mode={paletteMode ?? 'commands'}
        commands={commands}
        projectRoot={activeProjectPath}
        onClose={() => setPaletteMode(null)}
        onOpenFile={() => setPaletteMode(null)}
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
