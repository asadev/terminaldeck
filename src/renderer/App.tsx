import { useCallback, useEffect, useMemo, useState } from 'react'
import { StoreProvider, useStore } from './state/store'
import { TitleBar } from './components/TitleBar'
import { TabBar } from './components/TabBar'
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
import { BrowserWorkspace } from './browser/BrowserWorkspace'
import { Board } from './board/Board'
import { Dashboard } from './dashboard/Dashboard'
import { SwarmGrid } from './layout/SwarmGrid'
import { ActivityBar } from './shell/ActivityBar'
import { PanelDock } from './shell/PanelDock'
import { usePanelDock } from './shell/usePanelDock'
import { ErrorBoundary } from './shell/ErrorBoundary'
import { applyStoredTheme } from './theme'
import './shell/shell.css'

type MainView = 'terminal' | 'overview' | 'board' | 'browser'

const VIEWS: Array<{ id: MainView; label: string }> = [
  { id: 'terminal', label: 'Sessions' },
  { id: 'overview', label: 'Overview' },
  { id: 'board', label: 'Board' },
  { id: 'browser', label: 'Browser' },
]

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
  const [view, setView] = useState<MainView>('terminal')
  const [swarm, setSwarm] = useState(false)
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

  const activeProjectPath =
    sessions.find((s) => s.id === activeSessionId)?.projectPath ?? projects[0]?.path ?? null

  useEffect(() => {
    const off = window.pawl.onSessionStatus((id, status) => setSessionStatus(id, status))
    return off
  }, [setSessionStatus])

  useEffect(() => {
    void window.pawl.getPreferences().then((p) => applyStoredTheme(p.theme))
  }, [])

  useEffect(() => {
    let cancelled = false
    void window.pawl.listProjects().then((saved) => {
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
    void window.pawl
      .checkPrerequisites()
      .then((p) => setNeedsOnboarding(!(p as { canRunSessions: boolean }).canRunSessions))
      .catch(() => setNeedsOnboarding(false))
  }, [])

  const openProject = useCallback(async () => {
    const path = await window.pawl.pickProjectFolder()
    if (!path) return
    addProject(path)
    void window.pawl.addProject(path)
    const meta = await window.pawl.createSession({ cwd: path, cols: 100, rows: 30 })
    addSession(meta)
    setOnboardingDone(true)
    setView('terminal')
  }, [addProject, addSession])

  const newSessionIn = useCallback(
    async (path: string, resume = false) => {
      const meta = await window.pawl.createSession({ cwd: path, cols: 100, rows: 30, resume })
      addSession(meta)
      setView('terminal')
    },
    [addSession],
  )

  const closeSession = useCallback(
    async (id: string) => {
      await window.pawl.killSession(id)
      removeSession(id)
    },
    [removeSession],
  )

  const commands = useMemo<PaletteCommand[]>(
    () => [
      { id: 'session.new', title: 'New session', group: 'Session', shortcut: '⌘T', run: () => activeProjectPath && void newSessionIn(activeProjectPath) },
      { id: 'session.resume', title: 'Continue last session', group: 'Session', shortcut: '⌘⇧T', run: () => activeProjectPath && void newSessionIn(activeProjectPath, true) },
      { id: 'project.open', title: 'Open a project', group: 'Project', shortcut: '⌘O', run: () => void openProject() },
      { id: 'view.overview', title: 'Show project overview', group: 'View', run: () => setView('overview') },
      { id: 'view.board', title: 'Show task board', group: 'View', run: () => setView('board') },
      { id: 'view.browser', title: 'Show browser', group: 'View', run: () => setView('browser') },
      { id: 'view.swarm', title: 'Toggle swarm view', group: 'View', shortcut: '⌘\\', run: () => { setView('terminal'); setSwarm((s) => !s) } },
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
      if (e.key === 'w' && activeSessionId) {
        e.preventDefault()
        void closeSession(activeSessionId)
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
        setView('terminal')
        setSwarm((s) => !s)
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
      if (Number.isInteger(n) && n >= 1 && n <= 9 && sessions[n - 1]) {
        e.preventDefault()
        setActiveSession(sessions[n - 1].id)
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
    if (view === 'overview') {
      return activeProjectPath ? (
        <Dashboard projectPath={activeProjectPath} />
      ) : (
        <EmptyState onOpenProject={openProject} />
      )
    }
    if (view === 'board') {
      return activeProjectPath ? (
        <Board projectPath={activeProjectPath} />
      ) : (
        <EmptyState onOpenProject={openProject} />
      )
    }
    if (view === 'browser') {
      return (
        <BrowserWorkspace
          visible={!anyModalOpen}
          onSendToAgent={(context) => {
            // Element context goes straight into the focused session, which is
            // the whole point of inspecting from inside the app.
            if (activeSessionId) window.pawl.writeToSession(activeSessionId, context)
          }}
        />
      )
    }
    if (sessions.length === 0) return <EmptyState onOpenProject={openProject} />
    if (swarm) {
      return (
        <SwarmGrid
          sessions={sessions}
          activeSessionId={activeSessionId}
          onFocusSession={setActiveSession}
          renderCell={({ session }) => <TerminalView sessionId={session.id} visible />}
        />
      )
    }
    return sessions.map((s) => (
      <TerminalView key={s.id} sessionId={s.id} visible={s.id === activeSessionId} />
    ))
  }

  return (
    <div className="app">
      <TitleBar />
      <div className="app-body">
        <ActivityBar active={panel} onSelect={setPanel} />
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
          <div className="view-bar">
            {view === 'terminal' && sessions.length > 0 ? (
              <TabBar onClose={closeSession} />
            ) : (
              <div className="view-switcher" />
            )}
            <div className="view-modes">
              {VIEWS.map((v) => (
                <button
                  key={v.id}
                  type="button"
                  className={`view-tab${view === v.id ? ' active' : ''}`}
                  onClick={() => setView(v.id)}
                >
                  {v.label}
                </button>
              ))}
            </div>
          </div>
          <div className="panes">
            <ErrorBoundary label={VIEWS.find((v) => v.id === view)?.label ?? view}>
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
          const meta = await window.pawl.createSession(request)
          addSession(meta)
          setView('terminal')
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
