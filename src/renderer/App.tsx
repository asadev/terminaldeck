import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { SessionStatus } from '@shared/types'
import { StoreProvider, useStore } from './state/store'
import { TerminalView } from './components/TerminalView'
import { EmptyState } from './components/EmptyState'
import { SettingsWindow } from './settings/SettingsWindow'
import type { SectionId } from './settings/settings-schema'
import { NewSessionDialog } from './components/NewSessionDialog'
import { HelpDialog } from './components/HelpPanel'
import { JoinRemoteDialog } from './components/JoinRemoteDialog'
import { SessionInspector } from './components/SessionInspector'
import {
  CloseSessionConfirm,
  CONFIRM_CLOSE_KEY,
  needsCloseConfirm,
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
import { panelSpec, type PanelId } from './shell/panels'
import { nextActiveId, sessionLabel, type WorkspaceTab } from './shell/workspace-tabs'
import { ErrorBoundary } from './shell/ErrorBoundary'
import { UnreadTracker } from './unread'
import { isProviderId } from './preferences'
import { AutoTitler } from './auto-title'
import { useSessionNotifier } from './useSessionNotifier'
import { useAppSettings } from './settings/useAppSettings'
import { booleanSetting, numberSetting, stringSetting } from './settings/settings-schema'
import { resolveCommand, scopeForTarget, tip } from './keymap'
import './shell/shell.css'

/** Toolbar icons, 24×24, 1.5 stroke — the same grid the sidebar draws on. */
const ICON = {
  inspector: 'M12 4.6c-4.3 0-7.4 3.2-8.6 5.2a2 2 0 0 0 0 2c1.2 2 4.3 5.2 8.6 5.2s7.4-3.2 8.6-5.2a2 2 0 0 0 0-2c-1.2-2-4.3-5.2-8.6-5.2zM12 14a3.2 3.2 0 1 0 0-6.4 3.2 3.2 0 0 0 0 6.4z',
  swarm: 'M4.5 4.5h6v6h-6zM13.5 4.5h6v6h-6zM4.5 13.5h6v6h-6zM13.5 13.5h6v6h-6z',
  palette: 'M11 4.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13zM19.5 19.5l-3.9-3.9',
}

/** A close waiting on the user: one session, or every session in a project. */
type PendingClose =
  | { kind: 'session'; tab: WorkspaceTab }
  | { kind: 'project'; path: string; name: string; status: SessionStatus; count: number }

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
    setSessionTitle,
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

  /** The same output, read for a better name than the folder's. */
  const titlerRef = useRef<AutoTitler>(undefined)
  if (!titlerRef.current) titlerRef.current = new AutoTitler()
  const titler = titlerRef.current

  const sidebar = useSidebar()
  const { panel, selectPanel, clearPanel } = sidebar
  const [extraTabs, setExtraTabs] = useState<WorkspaceTab[]>([])
  const [activeTabId, setActiveTabId] = useState<string | null>(null)
  const [swarm, setSwarm] = useState(false)
  const [sessionView, setSessionView] = useState<Record<string, SessionViewMode>>({})
  const [openFile, setOpenFile] = useState<string | null>(null)
  /**
   * The close that is waiting on an answer — one session, or a whole project.
   *
   * Both go through the same dialog. Closing a project used to skip it
   * entirely: `removeProject` killed every session in the project outright,
   * with "Confirm closing an active session" switched on.
   */
  const [pendingClose, setPendingClose] = useState<PendingClose | null>(null)
  /**
   * Which part of a view was asked for — a git group, a GitHub list.
   *
   * A count on the dashboard is a door (rule 1.2), and a door has to open onto
   * the thing it counted rather than the page in general (rule 1.5). This is
   * how "staged: 3" arrives at Source control already looking at the three.
   */
  const [panelFocus, setPanelFocus] = useState<string | null>(null)
  const [prefsOpen, setPrefsOpen] = useState(false)
  /** Which settings section opens. Reset whenever Settings is opened plainly. */
  const [prefsSection, setPrefsSection] = useState<SectionId>('general')
  const [newSessionOpen, setNewSessionOpen] = useState(false)
  const [helpOpen, setHelpOpen] = useState(false)
  const [joinOpen, setJoinOpen] = useState(false)
  const [inspectorOpen, setInspectorOpen] = useState(false)
  const [paletteMode, setPaletteMode] = useState<'files' | 'commands' | null>(null)
  const [shortcutsOpen, setShortcutsOpen] = useState(false)
  const [onboardingDone, setOnboardingDone] = useState(false)
  const [needsOnboarding, setNeedsOnboarding] = useState<boolean | null>(null)
  /** Whether the app window itself has focus. Half of "is anyone looking". */
  const [windowFocused, setWindowFocused] = useState(true)

  /**
   * Every setting that changes how the app behaves, read once.
   *
   * Not once per consumer: this used to be three separate reads of the same
   * file at launch — one for density, one for the confirm-on-close switch, one
   * inside Settings — and the settings that had no reader at all were invisible
   * precisely because nobody was looking for them in one place.
   */
  const { values: settings, loaded: settingsLoaded, apply: applySettings } = useAppSettings()
  const confirmClose = booleanSetting(settings, CONFIRM_CLOSE_KEY)
  const terminalFontSize = numberSetting(settings, 'appearance.terminalFontSize')
  const terminalFontFamily = stringSetting(settings, 'appearance.terminalFontFamily')
  const copyOnSelect = booleanSetting(settings, 'general.copyOnSelect')
  const autoNameSessions = booleanSetting(settings, 'general.autoNameSessions')

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

  /**
   * Latest sessions and switches, for the callbacks that must not re-register.
   * Assigned during render, so an effect that runs after it always sees the
   * values of the render it belongs to.
   */
  const sessionsRef = useRef(sessions)
  sessionsRef.current = sessions
  const autoNameRef = useRef(autoNameSessions)
  autoNameRef.current = autoNameSessions

  const activeProjectPath =
    activeSession?.projectPath ??
    sessions.find((s) => s.id === activeSessionId)?.projectPath ??
    projects[0]?.path ??
    null

  useEffect(() => unread.subscribe((snapshot) => setUnreadIds(snapshot.ids)), [unread])

  /**
   * Output on a session nobody is looking at lights its row — and names it.
   *
   * One app-level subscription, not one per session and not one per job:
   * `onSessionData` already broadcasts every chunk with its id, and both
   * readers of that stream want the same chunk. The tracker's own noise filter
   * is what keeps a spinner from badging a tab forever; the titler's rate limit
   * is what keeps a title scan off the hot path.
   *
   * Everything variable is read through a ref. Depending on `sessions` here
   * would tear down and re-register the IPC listener every time any session
   * changed status.
   */
  useEffect(
    () =>
      window.deck.onSessionData((id, chunk) => {
        unread.recordOutput(id, chunk)
        if (!autoNameRef.current) return
        const session = sessionsRef.current.find((s) => s.id === id)
        // Only while the session is still wearing the folder's name. A title
        // the user typed, or one the new-session dialog derived from their
        // first prompt, outranks anything read off a repainting TUI.
        if (!session || session.title !== folderNameOf(session.projectPath)) return
        titler.record(id, chunk)
        const title = titler.titleFor(id, session.projectPath)
        if (title) setSessionTitle(id, title)
      }),
    [unread, titler, setSessionTitle],
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
    const sync = () => setWindowFocused(document.hasFocus())
    sync()
    window.addEventListener('focus', sync)
    window.addEventListener('blur', sync)
    return () => {
      window.removeEventListener('focus', sync)
      window.removeEventListener('blur', sync)
    }
  }, [])

  const viewing = useMemo(
    () => ({
      activeSessionId: showingPanel ? null : activeTab?.id ?? null,
      windowFocused,
    }),
    [showingPanel, activeTab?.id, windowFocused],
  )

  useEffect(() => unread.setViewing(viewing), [unread, viewing])

  /**
   * The projects you had open, put back.
   *
   * Gated on the setting, and on the setting having actually arrived: doing
   * this against the schema default would reopen everything for someone who
   * turned it off, one frame before their answer landed. The switch used to be
   * called "Restore sessions on launch" and was read by nothing at all.
   */
  useEffect(() => {
    if (!settingsLoaded) return
    if (!booleanSetting(settings, 'advanced.restoreSessions')) return
    let cancelled = false
    void window.deck.listProjects().then((saved) => {
      if (cancelled) return
      for (const p of saved) addProject(p.path)
    })
    return () => {
      cancelled = true
    }
  }, [addProject, settings, settingsLoaded])

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

  const newSessionIn = useCallback(
    async (path: string, resume = false) => {
      /*
       * The default agent is *sent*, not assumed.
       *
       * `session:create` used to go out with no provider at all, so the main
       * process fell back to Claude Code whatever General said — someone whose
       * default was Plain shell got Claude from the sidebar button while the
       * new-session dialog, which does read the setting, pre-selected Shell.
       * The app disagreed with itself about its own preference.
       */
      const provider = stringSetting(settings, 'general.defaultProvider')
      const meta = await window.deck.createSession({
        cwd: path,
        cols: 100,
        rows: 30,
        resume,
        ...(isProviderId(provider) ? { provider } : {}),
      })
      addSession(meta)
      showTab(meta.id)
    },
    [addSession, showTab, settings],
  )

  const openProject = useCallback(async () => {
    const path = await window.deck.pickProjectFolder()
    if (!path) return
    addProject(path)
    void window.deck.addProject(path)
    // Through `newSessionIn`, so the first session in a project starts on the
    // same agent every other one does. This call used to build its own request
    // and left the provider off it.
    await newSessionIn(path)
    setOnboardingDone(true)
  }, [addProject, newSessionIn])

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

  const selectTab = useCallback(
    (id: string) => {
      showTab(id)
      // Terminals key off the store's active session; keep the two in step or
      // switching to a session shows the previously focused terminal.
      if (sessions.some((session) => session.id === id)) setActiveSession(id)
    },
    [sessions, setActiveSession, showTab],
  )

  /**
   * Banners and the finish sound.
   *
   * Placed here because clicking a banner has to be able to bring you to the
   * session it is about, and `selectTab` is what does that.
   */
  const notifier = useSessionNotifier({
    values: settings,
    viewing,
    describe: (id) => {
      const session = sessionsRef.current.find((s) => s.id === id)
      return {
        title: session?.title ?? 'Session',
        project: folderNameOf(session?.projectPath),
      }
    },
    onActivate: (id) => {
      // The OS gives the app focus when a banner is clicked; the app still has
      // to land on the session that rang, which may not be the one in front.
      selectTab(id)
    },
  })

  /**
   * Status changes: the sidebar's dot, and everything that rings.
   *
   * One subscription for both. Every change is reported to the notifier, even
   * the ones nobody wants a banner for — the policy needs the whole sequence to
   * tell a real transition from the main process re-broadcasting.
   */
  useEffect(() => {
    return window.deck.onSessionStatus((id, status) => {
      setSessionStatus(id, status)
      notifier.observe(id, status)
    })
  }, [setSessionStatus, notifier])

  const closeTabNow = useCallback(
    (id: string) => {
      const tab = tabs.find((t) => t.id === id)
      const following = nextActiveId(tabs, id)
      // Everything that remembers this session forgets it together: a stale
      // unread dot is untidy, a banner for a session that no longer exists is
      // a click that goes nowhere.
      unread.forget(id)
      notifier.forget(id)
      titler.forget(id)
      if (tab?.kind === 'session') {
        void window.deck.killSession(id)
        removeSession(id)
      } else {
        setExtraTabs((prev) => prev.filter((t) => t.id !== id))
      }
      setActiveTabId(following)
    },
    [tabs, removeSession, unread, notifier, titler],
  )

  /**
   * Close a project and everything running in it.
   *
   * The store kills each session's pty, so this is the same loss as closing
   * every one of those tabs by hand — which is why it now asks first when any
   * of them has something to lose.
   */
  const closeProjectNow = useCallback(
    (path: string) => {
      for (const session of sessionsRef.current) {
        if (session.projectPath !== path) continue
        unread.forget(session.id)
        notifier.forget(session.id)
        titler.forget(session.id)
      }
      removeProject(path)
    },
    [removeProject, unread, notifier, titler],
  )

  const closeProject = useCallback(
    (path: string) => {
      const risky = sessionsRef.current.filter(
        (session) =>
          session.projectPath === path && needsCloseConfirm(session.status, confirmClose),
      )
      if (risky.length === 0) {
        closeProjectNow(path)
        return
      }
      setPendingClose({
        kind: 'project',
        path,
        name: folderNameOf(path) ?? path,
        status: risky[0].status,
        count: risky.length,
      })
    },
    [closeProjectNow, confirmClose],
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
        setPendingClose({ kind: 'session', tab })
        return
      }
      closeTabNow(id)
    },
    [tabs, confirmClose, closeTabNow],
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

  /** Settings, at a section. Plain routes land on General rather than wherever
      an alert last sent someone. */
  const openSettings = useCallback((section: SectionId = 'general') => {
    setPrefsSection(section)
    setPrefsOpen(true)
  }, [])

  /**
   * Open one of the sidebar's views, optionally already looking at one part of
   * it — the staged files, the pull requests. `focus` is cleared on every plain
   * navigation, or the sidebar would keep landing you where a dashboard tile
   * once sent you.
   */
  const showPanel = useCallback(
    (id: PanelId, focus: string | null = null) => {
      setPanelFocus(focus)
      selectPanel(id)
    },
    [selectPanel],
  )

  /** Source control hands a file here; the Files page is what can show it. */
  const showFile = useCallback(
    (relPath: string) => {
      setOpenFile(relPath)
      showPanel('files')
    },
    [showPanel],
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
      // `view.dashboard`, which is the id the keymap binds ⌘⇧D to. The row used
      // to call itself `view.overview` and print ⌘⇧D anyway: the chord worked,
      // via an alias in the switch below, but the palette was printing a
      // shortcut for a command it was not the entry for.
      { id: 'view.dashboard', title: 'Overview', group: 'View', shortcut: '⌘⇧D', run: () => showPanel('overview') },
      { id: 'view.files', title: 'Files', group: 'View', shortcut: '⌘⇧E', run: () => showPanel('files') },
      { id: 'view.search', title: 'Search past sessions', group: 'View', shortcut: '⌘⇧F', run: () => showPanel('search') },
      { id: 'view.git', title: 'Source control', group: 'View', shortcut: '⌘⇧G', run: () => showPanel('git') },
      { id: 'view.board', title: 'Task board', group: 'View', shortcut: '⌘⇧B', run: () => showPanel('board') },
      { id: 'view.github', title: 'GitHub', group: 'View', run: () => showPanel('github') },
      { id: 'view.alerts', title: 'Alerts', group: 'View', run: () => showPanel('alerts') },
      { id: 'view.readiness', title: 'AI readiness', group: 'View', run: () => showPanel('readiness') },
      { id: 'view.mcp', title: 'MCP servers', group: 'View', run: () => showPanel('mcp') },
      { id: 'view.hooks', title: 'Hooks', group: 'View', run: () => showPanel('hooks') },
      { id: 'view.sidebar', title: 'Show or hide the sidebar', group: 'View', shortcut: '⌘B', run: () => sidebar.toggleCollapsed() },
      { id: 'view.inspector', title: 'Session details', group: 'App', shortcut: '⌘⇧I', run: () => setInspectorOpen(true) },
      { id: 'app.preferences', title: 'Settings', group: 'App', shortcut: '⌘,', run: () => openSettings() },
      { id: 'app.help', title: 'Help', group: 'App', run: () => setHelpOpen(true) },
      { id: 'app.join', title: 'Join a remote session', group: 'App', run: () => setJoinOpen(true) },
      { id: 'app.shortcuts', title: 'Keyboard shortcuts', group: 'App', shortcut: '⌘/', run: () => setShortcutsOpen(true) },
    ],
    [newSession, newBrowserTab, openProject, showPanel, openSettings, sidebar],
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
          showPanel('search')
          return true
        case 'app.inspector':
          setInspectorOpen(true)
          return true
        // The application menu's name for the same view.
        case 'view.overview':
          showPanel('overview')
          return true
        case 'view.terminal':
          if (sessions[0]) selectTab(sessions[0].id)
          return true
        case 'app.about':
          openSettings('about')
          return true
        case 'app.setup':
          openSettings('setup')
          return true
        default:
          return false
      }
    },
    [commands, activeTab, closeTab, cycleTab, showPanel, openSettings, selectTab, sessions],
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
          // `showFile`, not `setOpenFile`: clicking a changed file in Source
          // control set the Files page's selection and left you looking at
          // Source control, so the click did nothing you could see.
          onOpenFile={showFile}
          focus={panelFocus}
          showInsights={booleanSetting(settings, 'general.showInsightAlerts')}
          /*
           * Every alert's button, given somewhere to go. Each of the five kinds
           * names a target the app can already show; the panel raised them and
           * nothing listened, so pressing one re-ran the scan behind it and
           * left you exactly where you were.
           */
          onAlertAction={(action) => {
            /*
             * A session-targeted alert names Claude's own conversation id,
             * taken from the transcript — not this window's tab id, which the
             * main process mints. They coincide only when the app started the
             * session. So the match is attempted, and where it fails the action
             * lands on the inspector, which reads the project's transcripts and
             * can therefore show the very session the alert is about. What it
             * never does is guess: `/compact` is a write, and a write to the
             * wrong session is worse than a button that took you somewhere
             * slightly broader.
             */
            const openSession = sessions.find((session) => session.id === action.target)
            switch (action.kind) {
              case 'open-git':
                showPanel('git')
                return
              case 'focus-session':
                if (openSession) selectTab(openSession.id)
                else setInspectorOpen(true)
                return
              case 'open-inspector':
                setInspectorOpen(true)
                return
              case 'compact-session':
                // The agent's own command, typed into the session it is about —
                // the same channel chat mode writes through. Focus follows it,
                // because a command sent to a terminal you cannot see is a
                // command you cannot tell ran.
                if (openSession) {
                  selectTab(openSession.id)
                  window.deck.writeToSession(openSession.id, '/compact\r')
                } else {
                  setInspectorOpen(true)
                }
                return
              case 'install-provider':
                // Setup is the section that lists what is installed and what is
                // missing; landing on General would be a page about something
                // else (rule 1.5).
                setPrefsSection('setup')
                setPrefsOpen(true)
                return
            }
          }}
          // What makes the dashboard's numbers doors rather than decoration.
          // Every one of these was undefined until now, which is why the
          // sessions list rendered its rows disabled and the git and board
          // tiles hid their "open" buttons entirely.
          dashboard={{
            sessions: sessions
              .filter((session) => session.projectPath === activeProjectPath)
              .map((session, index) => ({
                id: session.id,
                title: sessionLabel(
                  session.title,
                  index,
                  folderNameOf(session.projectPath),
                ),
                provider: session.provider,
                status: session.status,
              })),
            onOpenSession: selectTab,
            onShowSessions: () => {
              clearPanel()
              setSwarm(true)
            },
            onOpenInspector: () => setInspectorOpen(true),
            onNavigate: showPanel,
            onOpenFile: showFile,
          }}
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
          renderCell={({ session }) => (
            <TerminalView
              sessionId={session.id}
              visible
              fontSize={terminalFontSize}
              fontFamily={terminalFontFamily}
              copyOnSelect={copyOnSelect}
            />
          )}
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
              // Settings owns where a page opens; the panel's own button
              // writes the same setting rather than a copy of it.
              startUrl={stringSetting(settings, 'browser.startUrl')}
              onStartUrl={(url) => {
                applySettings({ ...settings, 'browser.startUrl': url })
                void window.deck.setSettings({ 'browser.startUrl': url })
              }}
              // Otherwise every browser row in the sidebar reads "New tab".
              onTitle={(title) =>
                setExtraTabs((prev) =>
                  // The same array back when nothing changed. `prev.map` always
                  // builds a new one, and a new array is a new state, which is
                  // a re-render, which reports the title again.
                  prev.some((entry) => entry.id === tab.id && entry.label !== title)
                    ? prev.map((entry) =>
                        entry.id === tab.id ? { ...entry, label: title } : entry,
                      )
                    : prev,
                )
              }
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
              <TerminalView
                sessionId={session.id}
                visible={active && mode === 'terminal'}
                fontSize={terminalFontSize}
                fontFamily={terminalFontFamily}
                copyOnSelect={copyOnSelect}
              />
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
      // No subtitle. "Nothing open yet." is the sidebar's line, and it is there to
      // explain why the list beneath it is empty — a job this heading does not
      // share. Saying it here too put the same sentence on screen twice, a few
      // centimetres apart, while the page in the middle was already explaining
      // the same emptiness with a button. The title alone is enough.
      : { title: 'Terminal Deck', subtitle: null }

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
          onSelectPanel={showPanel}
          onNewSession={newSession}
          onNewBrowserTab={newBrowserTab}
          onOpenProject={openProject}
          onCloseProject={closeProject}
          onOpenSettings={() => openSettings()}
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
        initialSection={prefsSection}
        onClose={() => setPrefsOpen(false)}
        // Every behavioural setting is read from one copy up here, so a change
        // made in the dialog has to land in it — otherwise the next ⌘W, the
        // next banner and the next terminal all disagree with what is on
        // screen until the app is restarted.
        onChange={applySettings}
      />
      <CloseSessionConfirm
        open={pendingClose !== null}
        title={
          pendingClose === null
            ? ''
            : pendingClose.kind === 'session'
              ? labelOf(pendingClose.tab)
              : pendingClose.name
        }
        status={
          pendingClose === null
            ? 'idle'
            : pendingClose.kind === 'session'
              ? (pendingClose.tab.status ?? 'idle')
              : pendingClose.status
        }
        count={pendingClose?.kind === 'project' ? pendingClose.count : 1}
        provider={
          pendingClose?.kind === 'session'
            ? sessions.find((s) => s.id === pendingClose.tab.id)?.provider
            : undefined
        }
        onCancel={() => setPendingClose(null)}
        onConfirm={() => {
          const closing = pendingClose
          setPendingClose(null)
          if (!closing) return
          if (closing.kind === 'session') closeTabNow(closing.tab.id)
          else closeProjectNow(closing.path)
        }}
        // The dialog writes the setting itself; this keeps the copy above in
        // step so the very next close does not ask again.
        onConfirmSettingChange={(enabled) =>
          applySettings({ ...settings, [CONFIRM_CLOSE_KEY]: enabled })
        }
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
