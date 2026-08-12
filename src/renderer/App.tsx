import { useCallback, useEffect, useState } from 'react'
import { StoreProvider, useStore } from './state/store'
import { PreferencesModal } from './components/PreferencesModal'
import { SessionInspector } from './components/SessionInspector'
import { applyStoredTheme } from './theme'
import { TitleBar } from './components/TitleBar'
import { Sidebar } from './components/Sidebar'
import { TabBar } from './components/TabBar'
import { TerminalView } from './components/TerminalView'
import { EmptyState } from './components/EmptyState'

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

  // Restore previously opened projects. Sessions are not restored — the
  // processes are gone — but the project list is, so ⌘T works immediately.
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

  const [prefsOpen, setPrefsOpen] = useState(false)
  const [inspectorOpen, setInspectorOpen] = useState(false)

  const activeProjectPath =
    sessions.find((s) => s.id === activeSessionId)?.projectPath ?? projects[0]?.path ?? null

  // Single subscription for every session's status, rather than one per
  // terminal — the main process classifies, the renderer just reflects.
  useEffect(() => {
    const off = window.pawl.onSessionStatus((id, status) => setSessionStatus(id, status))
    return off
  }, [setSessionStatus])

  // Apply the saved theme before the user sees anything.
  useEffect(() => {
    void window.pawl.getPreferences().then((p) => applyStoredTheme(p.theme))
  }, [])

  const openProject = useCallback(async () => {
    const path = await window.pawl.pickProjectFolder()
    if (!path) return
    addProject(path)
    void window.pawl.addProject(path)
    const meta = await window.pawl.createSession({ cwd: path, cols: 100, rows: 30 })
    addSession(meta)
  }, [addProject, addSession])

  const newSessionIn = useCallback(
    async (path: string, resume = false) => {
      const meta = await window.pawl.createSession({ cwd: path, cols: 100, rows: 30, resume })
      addSession(meta)
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

  // Global shortcuts. Kept in one place so the keymap is readable at a glance.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey
      if (!mod) return

      if (e.key === 't' || e.key === 'T') {
        e.preventDefault()
        const target = sessions.find((s) => s.id === activeSessionId)?.projectPath ?? projects[0]?.path
        // Shift resumes the project's most recent agent session instead of
        // starting a fresh one (claude --continue / codex resume --last).
        if (target) void newSessionIn(target, e.shiftKey)
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
      // Shift+I arrives as 'I' on macOS, so match case-insensitively.
      if (e.shiftKey && (e.key === 'i' || e.key === 'I')) {
        e.preventDefault()
        setInspectorOpen(true)
        return
      }
      // Cmd+1..9 jumps straight to a tab.
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
    projects,
    activeSessionId,
    newSessionIn,
    openProject,
    closeSession,
    setActiveSession,
  ])

  return (
    <div className="app">
      <TitleBar />
      <div className="app-body">
        <Sidebar onOpenProject={openProject} onNewSession={newSessionIn} />
        <main className="workspace">
          {sessions.length > 0 && <TabBar onClose={closeSession} />}
          <div className="panes">
            {sessions.length === 0 ? (
              <EmptyState onOpenProject={openProject} />
            ) : (
              sessions.map((s) => (
                <TerminalView key={s.id} sessionId={s.id} visible={s.id === activeSessionId} />
              ))
            )}
          </div>
        </main>
      </div>
      <PreferencesModal open={prefsOpen} onClose={() => setPrefsOpen(false)} />
      <SessionInspector
        open={inspectorOpen}
        onClose={() => setInspectorOpen(false)}
        cwd={activeProjectPath}
        sessionTitle={sessions.find((s) => s.id === activeSessionId)?.title}
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
