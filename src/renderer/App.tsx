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
import { PageEmpty } from './components/PageEmpty'
import { BRAND } from '@shared/brand'
import { StatusDot } from './components/StatusDot'
import { UpdateBanner } from './updates/UpdateBanner'
import { ModeSwitch, type SessionViewMode, type WorkspaceMode } from './shell/ModeSwitch'
import { BrowserWorkspace } from './browser/BrowserWorkspace'
import { SwarmGrid } from './layout/SwarmGrid'
import { SplitView } from './layout/SplitView'
import {
  closePane,
  emptyLayout,
  focusedSessionId,
  moveFocus,
  type PaneLayout,
} from './layout/pane-tree'
import {
  closePaneOrCollapse,
  isSplit,
  pruneClosedSessions,
  seedSplit,
  showInFocusedPane,
  splitFocused,
} from './layout/panes'
import { Sidebar } from './shell/Sidebar'
import { WindowToolbar } from './shell/WindowToolbar'
import { FolderChip } from './shell/FolderChip'
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
import { readLastFolder, writeLastFolder } from './session-start'
import { chordFor, resolveCommand, scopeForTarget } from './keymap'
import './shell/shell.css'

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

const PANE_CLOSE = 'M6.5 6.5l11 11M17.5 6.5l-11 11'

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
  /**
   * The split layout, and the only record of whether the window is split.
   *
   * A `PaneLayout` with a null root *is* "not split", so there is no second
   * boolean beside it to fall out of step. The two disagreeing is not
   * hypothetical: closing the last pane from inside the split view has to leave
   * the mode switch reading "Terminal", and a separate flag would have left it
   * claiming Split with nothing in it.
   *
   * The pane tree and its view have existed, complete and unit-tested, since
   * before the first release, and were rendered by nothing at all for that
   * entire time — twice nearly deleted for it. This is the wiring.
   */
  const [panes, setPanes] = useState<PaneLayout>(emptyLayout)
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

  /**
   * The folder the last session was started in, read once at launch.
   *
   * Held in a ref rather than state because nothing on screen depends on it —
   * it is the answer the New session button needs when there is nothing open to
   * infer a folder from, and reading `localStorage` inside the click handler
   * would be a synchronous disk-backed read on the way to spawning a process.
   */
  // `undefined` is "not read yet" and `null` is "read, and there was nothing".
  // Without that distinction the read repeats on every render for anyone who
  // has never started a session — which is a synchronous disk-backed read per
  // frame, for the one user it can never help.
  const lastFolderRef = useRef<string | null | undefined>(undefined)
  if (lastFolderRef.current === undefined) {
    lastFolderRef.current = readLastFolder(globalThis.localStorage ?? null)
  }

  const activeProjectPath =
    activeSession?.projectPath ??
    sessions.find((s) => s.id === activeSessionId)?.projectPath ??
    projects[0]?.path ??
    null

  /** Whether the window is showing a hand-arranged layout rather than one session. */
  const splitting = isSplit(panes)

  /**
   * The session the app acts on: the focused pane's while split, the open tab's
   * otherwise.
   *
   * This is the whole of "focus routing", and it is one expression on purpose.
   * Everything downstream — the title, the folder chip, the inspector, which
   * row the sidebar draws as current, what `unread` counts as being looked at —
   * asks this and not `activeTab`, so there is no second place for the two
   * models to disagree.
   */
  const focusedId = splitting ? focusedSessionId(panes) : activeTab?.id ?? null
  const focusedSession = focusedId
    ? sessions.find((session) => session.id === focusedId) ?? null
    : null

  useEffect(() => unread.subscribe((snapshot) => setUnreadIds(snapshot.ids)), [unread])

  /**
   * A pane naming a session that no longer exists is a hole with no
   * explanation, and `focusedSessionId` would keep answering with an id the
   * store has already forgotten — so the toolbar and the inspector would be
   * reading a dead session's name. Driven off the session list rather than off
   * each close path, because a session can leave four different ways (⌘W, the
   * row's ✕, the process exiting, a whole project closing) and only one of them
   * is a place a caller could remember to prune.
   */
  useEffect(() => {
    setPanes((current) => pruneClosedSessions(current, sessions))
  }, [sessions])

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
      activeSessionId: showingPanel ? null : focusedId,
      windowFocused,
    }),
    [showingPanel, focusedId, windowFocused],
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

  /**
   * The sessions that are still running, put back — on every mount, not just
   * on launch.
   *
   * This app's own stated bug class is a feature wired to a button and never
   * wired to boot. This is its sibling, and it had shipped: the session list
   * lived only in renderer state, so reloading the renderer (⌘R, or a crash
   * that React recovered from) emptied the sidebar while the ptys carried on
   * running in the main process. Verified with `ps`: a `/bin/zsh -l` still
   * parented to Electron, with no row in the window to reach it and no way to
   * close it short of quitting the app. Every piece needed to fix it already
   * existed — `session:list` returns the manager's live map, and `TerminalView`
   * already replays `session:scrollback` when it mounts — and nothing had ever
   * called the first one.
   *
   * Deliberately NOT gated on `advanced.restoreSessions`. That setting is about
   * reopening the projects you had open the last time the *app* ran; this is a
   * process that is running right now, in this very main process, and hiding it
   * is not a preference anybody expressed.
   *
   * `focus: false` on every one of them: a reload should put the window back as
   * it was, not pull the user onto whichever session happens to be last in the
   * map. The project is added first so the rows have a group to land in.
   */
  useEffect(() => {
    let cancelled = false
    void window.deck
      .listSessions()
      .then((live) => {
        if (cancelled) return
        for (const meta of live) {
          addProject(meta.cwd)
          addSession(meta, { focus: false })
        }
      })
      .catch(() => {
        // A build whose bridge is missing the channel keeps the old behaviour:
        // an empty list. There is nothing better to do and nothing to say.
      })
    return () => {
      cancelled = true
    }
  }, [addProject, addSession])

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
      // Remembered here rather than at the call sites, because every way of
      // starting a session goes through this function and only one of them
      // knows where the folder came from.
      lastFolderRef.current = path
      writeLastFolder(path, globalThis.localStorage ?? null)
      // Started while the window is split: it belongs in the pane you are
      // looking at, which is the same rule a sidebar click follows. Without it,
      // the empty pane's own New session button would start a session that
      // appeared everywhere except the pane it was pressed in.
      setPanes((current) => (isSplit(current) ? showInFocusedPane(current, meta.id) : current))
      // A session in a folder the sidebar is not listing is a session with no
      // row. That happened whenever the folder came from the remembered one
      // rather than from a project the user had opened in this window.
      addProject(path)
      void window.deck.addProject(path)
      addSession(meta)
      showTab(meta.id)
    },
    [addProject, addSession, showTab, settings],
  )

  const openProject = useCallback(async () => {
    const path = await window.deck.pickProjectFolder()
    if (!path) return
    // Through `newSessionIn`, so the first session in a project starts on the
    // same agent every other one does — and is registered the same way. This
    // call used to build its own request and left the provider off it.
    await newSessionIn(path)
    setOnboardingDone(true)
  }, [newSessionIn])

  /**
   * ⌘T and the sidebar's primary button: a session, immediately.
   *
   * No dialog stands in front of this any more, and the folder is decided in
   * the order the user would guess: the one you asked for, then the one you are
   * working in, then the one you were working in last time. The picker is what
   * happens when all three are genuinely unknown — a first launch — and at that
   * point it is not "a dialog in the way", it is the only question left.
   *
   * `openProject` was previously reached whenever no project was open at all,
   * which included every launch with restore-on-start switched off: pressing
   * New session put a folder chooser on screen instead of a session.
   */
  const newSession = useCallback(
    (path?: string, resume = false) => {
      const target = path ?? activeProjectPath ?? lastFolderRef.current
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
      if (!sessions.some((session) => session.id === id)) return
      setActiveSession(id)
      /*
       * While the window is split, a sidebar row fills the pane you are looking
       * at rather than taking the whole window back.
       *
       * This is the sentence that makes the two models one model. The sidebar
       * keeps meaning exactly what it always meant — "show me this session" —
       * and the only thing that changed is where "show" happens to be. It is
       * deliberately not "open it in a new pane": the sidebar is a list of what
       * you have open, not a layout editor, and a click that quietly multiplied
       * your panes would be the list fighting the layout.
       */
      setPanes((current) => (isSplit(current) ? showInFocusedPane(current, id) : current))
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

  /* --------------------------------------------------------------- panes -- */

  /**
   * Split the window, or split again.
   *
   * Pressing it the first time seeds two panes from the sessions you already
   * have; pressing it again divides whichever pane has focus. The two are one
   * command because to the user they are one idea, and because a "Split" that
   * does nothing the second time you press it is a control that has stopped
   * answering.
   */
  const splitPanes = useCallback(() => {
    clearPanel()
    setSwarm(false)
    setPanes((current) =>
      isSplit(current) ? splitFocused(current) : seedSplit(sessionsRef.current, focusedId),
    )
  }, [clearPanel, focusedId])

  /** Leave the layout behind and go back to one session filling the window. */
  const closeSplit = useCallback(() => setPanes(emptyLayout()), [])

  /**
   * Terminal, Chat, Split — what the window is doing.
   *
   * The first two are per session and the third is per window, and joining them
   * in one control is a deliberate simplification rather than a shortcut: they
   * are three answers to one question the user is actually asking, which is
   * "what am I looking at". The state stays split — `sessionView` per session,
   * `panes` for the window — so nothing downstream has to unpick the join.
   */
  const setMode = useCallback(
    (next: WorkspaceMode) => {
      if (next === 'split') {
        splitPanes()
        return
      }
      closeSplit()
      setSwarm(false)
      // The focused pane's session, so leaving a split leaves you looking at
      // the half you were working in rather than at whatever tab was active
      // before you split.
      if (focusedId) {
        setActiveTabId(focusedId)
        setActiveSession(focusedId)
        setSessionView((views) => ({ ...views, [focusedId]: next }))
      }
    },
    [splitPanes, closeSplit, focusedId, setActiveSession],
  )

  /** Arrow-key travel between panes, geometric rather than by tree order. */
  const focusNeighbour = useCallback((direction: 'left' | 'right') => {
    setPanes((current) => moveFocus(current, direction))
  }, [])

  /**
   * Close one pane, and land somewhere sensible when that was the last split.
   *
   * The survivor is read before the collapse, not after: `closePaneOrCollapse`
   * throws the tree away once one pane is left, so by the time the new layout
   * exists there is nothing to ask which session was kept. Without this,
   * closing the pane you were *in* left the window showing the session you had
   * just closed the view of — still running, still real, and not the one you
   * chose to keep.
   */
  const closePaneAt = useCallback(
    (paneId: string) => {
      const survivor = focusedSessionId(closePane(panes, paneId))
      const next = closePaneOrCollapse(panes, paneId)
      setPanes(next)
      if (isSplit(next) || !survivor) return
      setActiveTabId(survivor)
      setActiveSession(survivor)
    },
    [panes, setActiveSession],
  )

  /**
   * While the window is split, the focused pane *is* the active session.
   *
   * One effect rather than a line in each of the four places focus can move —
   * a click in a pane, an arrow key, a pane closing, a session being pruned.
   * Everything outside the layout reads the store, so a pane taking focus
   * without this leaves the composer, the inspector and the chat bridge acting
   * on whichever session was in front before the window was split.
   */
  useEffect(() => {
    if (!splitting) return
    const id = focusedSessionId(panes)
    if (!id) return
    setActiveTabId(id)
    setActiveSession(id)
  }, [panes, splitting, setActiveSession])

  const commands = useMemo<PaletteCommand[]>(() => {
    /*
     * No chord is written down here.
     *
     * There used to be seventeen of them — `shortcut: '⌘T'`, `shortcut: '⌘⇧R'`
     * — and every one was a copy of what `keymap.ts` renders, taken on a Mac.
     * A copy of a platform-dependent fact is wrong on the other platform by
     * construction, and this one was wrong in the worst way a shortcut can be:
     * a Windows machine has no ⌘ key, so the palette was printing a character
     * the reader cannot press next to the command it supposedly runs.
     * `reachable.test.ts` guarded the copies against drift from the keymap; it
     * could not guard them against the platform, because it ran on a Mac.
     *
     * `chordFor` renders the binding for the platform this window is running
     * on, and returns null when the keymap has no binding — so the rows that
     * genuinely have no shortcut (GitHub, Alerts, Help, Join) print nothing
     * rather than something invented.
     */
    const rows: Omit<PaletteCommand, 'shortcut'>[] = [
      { id: 'session.new', title: 'New session', group: 'Session', run: () => newSession() },
      { id: 'session.resume', title: 'Continue last session', group: 'Session', run: () => newSession(undefined, true) },
      // The only way to reach the dialog that picks an agent, a prompt and a
      // login was the app menu. A menu is a control, but it is not a findable
      // one, and this is the screen where a session is configured.
      { id: 'session.newDialog', title: 'New session with options…', group: 'Session', run: () => setNewSessionOpen(true) },
      { id: 'project.open', title: 'Open a project', group: 'Project', run: () => void openProject() },
      { id: 'palette.quickOpen', title: 'Open a file…', group: 'Project', run: () => setPaletteMode('files') },
      { id: 'view.browser', title: 'New browser tab', group: 'View', run: () => newBrowserTab() },
      { id: 'pane.split', title: 'Split the window', group: 'View', run: () => splitPanes() },
      {
        id: 'view.swarm',
        title: 'Every session at once',
        group: 'View',
        // Swarm and split are both "several sessions on screen", so only one of
        // them may be on: they are two answers to the same question, and a
        // window showing both would be answering it twice. Swarm derives its
        // grid from the session list and rearranges itself; split is arranged
        // by hand and stays where it is put.
        run: () => {
          closeSplit()
          setSwarm((value) => !value)
        },
      },
      // `view.dashboard`, which is the id the keymap binds the Overview chord
      // to. The row used to call itself `view.overview` and print that chord
      // anyway: the chord worked, via an alias in the switch below, but the
      // palette was printing a shortcut for a command it was not the entry for.
      { id: 'view.dashboard', title: 'Overview', group: 'View', run: () => showPanel('overview') },
      { id: 'view.files', title: 'Files', group: 'View', run: () => showPanel('files') },
      { id: 'view.search', title: 'Search past sessions', group: 'View', run: () => showPanel('search') },
      { id: 'view.git', title: 'Source control', group: 'View', run: () => showPanel('git') },
      { id: 'view.github', title: 'GitHub', group: 'View', run: () => showPanel('github') },
      { id: 'view.alerts', title: 'Alerts', group: 'View', run: () => showPanel('alerts') },
      { id: 'view.readiness', title: 'AI readiness', group: 'View', run: () => showPanel('readiness') },
      { id: 'view.mcp', title: 'MCP servers', group: 'View', run: () => showPanel('mcp') },
      { id: 'view.hooks', title: 'Hooks', group: 'View', run: () => showPanel('hooks') },
      { id: 'view.sidebar', title: 'Show or hide the sidebar', group: 'View', run: () => sidebar.toggleCollapsed() },
      { id: 'view.inspector', title: 'Session details', group: 'App', run: () => setInspectorOpen(true) },
      { id: 'app.preferences', title: 'Settings', group: 'App', run: () => openSettings() },
      { id: 'app.help', title: 'Help', group: 'App', run: () => setHelpOpen(true) },
      { id: 'app.join', title: 'Join a remote session', group: 'App', run: () => setJoinOpen(true) },
      { id: 'app.shortcuts', title: 'Keyboard shortcuts', group: 'App', run: () => setShortcutsOpen(true) },
    ]
    return rows.map((row) => {
      const chord = chordFor(row.id)
      return chord === null ? row : { ...row, shortcut: chord }
    })
  }, [newSession, newBrowserTab, openProject, showPanel, openSettings, sidebar, splitPanes, closeSplit])

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
        // Travel between panes without reaching for the mouse. Geometric, via
        // `moveFocus` — of the panes that share an edge with this one, the
        // closest one lined up with its centre — because a tree walk has to
        // guess which leaf to land on the moment a split is nested.
        case 'pane.focusLeft':
          focusNeighbour('left')
          return true
        case 'pane.focusRight':
          focusNeighbour('right')
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
    [
      commands,
      activeTab,
      closeTab,
      cycleTab,
      showPanel,
      openSettings,
      selectTab,
      sessions,
      focusNeighbour,
    ],
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
          // sessions list rendered its rows disabled and the git tile hid its
          // "open" button entirely.
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
              closeSplit()
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

    /*
     * The split layout.
     *
     * Only the panes' terminals are mounted here, where the single-session view
     * below keeps every terminal mounted and hides the ones off screen. That is
     * safe for the same reason a session started on a phone can be opened cold:
     * the main process holds each session's scrollback and `TerminalView` asks
     * for it on mount, so entering or leaving a split is a redraw from a buffer
     * rather than a loss. What it is not safe to do is keep both — a session
     * rendered twice would attach two input handlers to one pty.
     */
    if (splitting) {
      return (
        <SplitView
          layout={panes}
          // Focus and geometry both arrive here; the effect above is what
          // carries a focus change on to the store.
          onLayoutChange={setPanes}
          renderPane={({ paneId, sessionId, focused }) => {
            const session = sessionId
              ? sessions.find((entry) => entry.id === sessionId) ?? null
              : null
            const index = session
              ? sessions.filter((s) => s.projectPath === session.projectPath).indexOf(session)
              : 0
            return (
              <div className="pane-cell" data-focused={focused}>
                <header className="pane-cell-head" data-empty={!session || undefined}>
                  {session ? (
                    <>
                      <StatusDot status={session.status} />
                      <span className="pane-cell-title">
                        {sessionLabel(session.title, index, folderNameOf(session.projectPath))}
                      </span>
                    </>
                  ) : (
                    <span className="pane-cell-title pane-cell-waiting">Empty pane</span>
                  )}
                  <button
                    type="button"
                    className="pane-cell-close"
                    aria-label="Close this pane"
                    // Closing the second-to-last pane puts the window back to a
                    // single session rather than leaving a "split view" with one
                    // pane in it, which is the ordinary view wearing a divider.
                    title="Close this pane"
                    onClick={() => closePaneAt(paneId)}
                  >
                    <svg
                      width="13"
                      height="13"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="1.6"
                      strokeLinecap="round"
                      aria-hidden="true"
                    >
                      <path d={PANE_CLOSE} />
                    </svg>
                  </button>
                </header>
                <div className="pane-cell-body">
                  {session ? (
                    <TerminalView
                      // Keyed on the pane as well as the session, so the same
                      // session opened in two panes gets two terminals rather
                      // than one element React keeps moving between them.
                      key={`${paneId}:${session.id}`}
                      sessionId={session.id}
                      visible
                      fontSize={terminalFontSize}
                      fontFamily={terminalFontFamily}
                      copyOnSelect={copyOnSelect}
                    />
                  ) : (
                    // An instruction, not a placeholder. The sidebar fills the
                    // focused pane, so the first sentence names something that
                    // is one click away on the left; the button is the other
                    // half, for the case this pane exists to serve — you split
                    // the window in order to run a second agent, and there is
                    // not a second one yet.
                    <PageEmpty
                      title="Nothing in this pane yet"
                      action={{ label: 'New session', onClick: () => newSession() }}
                    >
                      Pick a session in the sidebar and it opens here.
                    </PageEmpty>
                  )}
                </div>
              </div>
            )
          }}
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
                  // What is actually in the pty. Without it the pane writes
                  // agent copy over a plain shell — see `ChatViewProps`.
                  provider={session.provider}
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

  /**
   * The tab the window's heading is about.
   *
   * While the window is split that is the *focused pane's* session, not the tab
   * that happened to be active before the split — the title, the folder chip
   * and the session-details dialog all read from here, so they follow the pane
   * you are working in the way everything else does.
   */
  const headingTab = splitting
    ? tabs.find((tab) => tab.id === focusedId) ?? activeTab
    : activeTab

  const heading = showingPanel && panel
    ? { title: panelSpec(panel).label, subtitle: panelSpec(panel).blurb, folder: null }
    : headingTab
      ? {
          title: labelOf(headingTab),
          subtitle: null,
          // The path is a control now rather than a caption — see FolderChip.
          folder: headingTab.kind === 'session' ? headingTab.projectPath ?? null : null,
        }
      // No subtitle. "Nothing open yet." is the sidebar's line, and it is there to
      // explain why the list beneath it is empty — a job this heading does not
      // share. Saying it here too put the same sentence on screen twice, a few
      // centimetres apart, while the page in the middle was already explaining
      // the same emptiness with a button. The title alone is enough.
      : { title: BRAND.name, subtitle: null, folder: null }

  /**
   * What the mode switch is showing, and what it will not offer.
   *
   * Read rather than stored: `panes` already knows whether the window is split
   * and `sessionView` already knows how the focused session is drawn, so a
   * third piece of state saying the same thing could only ever be the one that
   * is wrong.
   */
  const mode: WorkspaceMode = splitting
    ? 'split'
    : focusedId
      ? sessionView[focusedId] ?? 'terminal'
      : 'terminal'

  return (
    <div className="app" data-sidebar-peek={sidebar.peeking || undefined}>
      {/*
        The reveal strip: eight pixels of window edge that peek the rail out.
        Only present while the rail is away, and it sits under the traffic
        lights' own row so it can never swallow a click meant for them.
      */}
      {!sidebar.revealed && (
        <div
          className="sidebar-edge"
          onPointerEnter={sidebar.beginPeek}
          aria-hidden="true"
        />
      )}

      {sidebar.revealed && (
        <Sidebar
          width={sidebar.width}
          projects={projects}
          tabs={tabs}
          activeTabId={focusedId ?? activeTab?.id ?? null}
          activePanel={panel}
          unread={unreadIds}
          peeking={sidebar.peeking && sidebar.collapsed}
          // Above Settings, in the foot. Mounted here rather than inside the
          // sidebar so the component stays where the wiring test can see it and
          // where its bridge subscription belongs.
          update={<UpdateBanner />}
          onSelectTab={selectTab}
          onCloseTab={closeTab}
          onSelectPanel={showPanel}
          onNewSession={newSession}
          onNewBrowserTab={newBrowserTab}
          onOpenProject={openProject}
          onCloseProject={closeProject}
          onOpenSettings={() => openSettings()}
          onToggleCollapsed={sidebar.toggleCollapsed}
          onPeekStart={sidebar.beginPeek}
          onPeekEnd={sidebar.endPeek}
          onStartResize={sidebar.startResize}
        />
      )}

      <main className="main">
        <WindowToolbar
          title={heading.title}
          subtitle={heading.subtitle}
          meta={
            heading.folder ? (
              <FolderChip
                path={heading.folder}
                options={projects}
                onPick={(path) => newSession(path)}
                onBrowse={() => void openProject()}
              />
            ) : null
          }
          /*
           * The *pinned* state, not the visible one.
           *
           * A peeked rail floats over the toolbar rather than taking room from
           * it, so the traffic lights are still sitting on the toolbar and it
           * still needs their 82px of clearance. Passing `!revealed` here made
           * that padding come and go with the peek, which slid the window's
           * title 66px sideways every time a pointer brushed the left edge.
           * The reveal button goes with it and is simply covered by the rail
           * while it is out — the same control, in the same place, either way.
           */
          sidebarHidden={sidebar.collapsed}
          onRevealSidebar={sidebar.pin}
          onEdgeEnter={sidebar.beginPeek}
        >
          {/*
            One control, and only where it means something.

            Swarm draws every terminal at once, so "how is *the* session shown"
            has no session to be about; a view from the sidebar is not a session
            at all. In both cases the switch is absent rather than disabled —
            there is nothing to say about a mode for something that is not on
            screen.
          */}
          {(activeSession || splitting) && !showingPanel && !swarm ? (
            <ModeSwitch mode={mode} onChange={setMode} />
          ) : null}
        </WindowToolbar>

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
        cwd={focusedSession?.projectPath ?? activeProjectPath}
        // The session in front of you, not whatever the store last marked
        // active — those disagree the moment you switch to a browser page, and
        // the dialog was heading one session's numbers with another's name.
        session={
          focusedSession
            ? { startedAt: focusedSession.createdAt, resumed: focusedSession.resumed }
            : null
        }
        sessionTitle={focusedSession?.title}
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
