import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { WorkspaceTabStrip } from './browser/WorkspaceTabStrip'
import type { ProviderId, SessionStatus } from '@shared/types'
import { StoreProvider, useStore } from './state/store'
import { TerminalView } from './components/TerminalView'
import { EmptyState } from './components/EmptyState'
import { SettingsWindow } from './settings/SettingsWindow'
import type { SectionId } from './settings/settings-schema'
import { NewSessionDialog } from './components/NewSessionDialog'
import { HelpDialog } from './components/HelpPanel'
import { JoinRemoteDialog } from './components/JoinRemoteDialog'
import { SessionInspector } from './components/SessionInspector'
import { AlertsWindow, withInsights } from './components/AlertsPanel'
import { useProjectAlerts } from './alerts-feed'
import { markSeen, readSeen, unreadCount, writeSeen, type SeenAlerts } from './alerts-unread'
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
import { UpdateBanner } from './updates/UpdateBanner'
import { ModeSwitch, type SessionViewMode, type WorkspaceMode } from './shell/ModeSwitch'
import { BrowserWorkspace } from './browser/BrowserWorkspace'
import { SwarmGrid } from './layout/SwarmGrid'
import { SplitView } from './layout/SplitView'
import {
  closePane,
  emptyLayout,
  focusedTabId,
  moveFocus,
  primaryPane,
  type PaneLayout,
} from './layout/pane-tree'
import {
  closePaneOrCollapse,
  isSplit,
  pruneClosedPanes,
  seedSplit,
  showInFocusedPane,
  splitFocused,
} from './layout/panes'
import { CopilotConsent } from './copilot/CopilotConsent'
import { useConsent } from './copilot/useConsent'
import { useCopilot } from './copilot/useCopilot'
import { partitionByOrigin, startedByCopilot, turnOf } from './copilot/session-origin'
import { Sidebar } from './shell/Sidebar'
import { WindowToolbar } from './shell/WindowToolbar'
import { FolderTitle } from './shell/FolderChip'
import { AccountChip } from './shell/AccountChip'
import { PaneBar } from './shell/PaneBar'
import { SessionControls } from './shell/SessionControls'
import { PanelView } from './shell/PanelView'
import { useSidebar } from './shell/useSidebar'
import { PANELS, panelSpec, type PanelId } from './shell/panels'
import { FeaturesProvider, useFeatures } from './features/FeaturesProvider'
import { useControlOffer } from './features/offer'
import { availableFeatures } from './features/state'
import { nextActiveId, sessionLabel, type WorkspaceTab } from './shell/workspace-tabs'
import { keepNewWindowInStrip, stripIsPresent } from './browser/workspace-strip'
import { ErrorBoundary } from './shell/ErrorBoundary'
import { Tooltips } from './shell/Tooltips'
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

function Workspace() {
  const {
    projects: storedProjects,
    sessions: storedSessions,
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

  /**
   * Which features this install has, and therefore which halves of this window
   * exist at all.
   *
   * Read here, once, and asked *by surface* everywhere below — `commandOn`,
   * `panelOn`, `on('browser')` — rather than by keeping a list of what to hide.
   * The registry owns which surface belongs to which feature; this file only
   * has to remember to ask.
   */
  const features = useFeatures()
  /**
   * What the globe beside New session says when the browser pane is not there.
   *
   * Null while the feature is on, which is what tells the sidebar to draw an
   * ordinary control. The rail is deliberately not allowed to ask the registry
   * anything itself — every decision about what exists is made here.
   */
  const browserOffer = useControlOffer('sidebar.browser')

  /**
   * The window's one connection to the copilot, held here because three places
   * have to agree about it and must not each ask separately: the pinned row in
   * the rail, the page it opens, and the filter below that keeps the copilot's
   * *own* session out of the ordinary session list.
   *
   * It starts nothing. `useCopilot` only reads; the copilot is spawned when its
   * page is opened, which is the moment somebody has said they want to talk to
   * it — an agent CLI bills for what it does, and a standing charge for opening
   * the app is not something anybody agreed to.
   */
  const copilot = useCopilot()

  /**
   * Everything open, minus the copilot itself.
   *
   * The copilot **is** a session — that is the whole design, and it is what
   * makes the transcript viewer, chat mode, the cost pane and the alert watcher
   * work on it with no changes at all. The cost of that is right here: it is in
   * `session:list` like any other, so a window that drew what it was handed
   * would put the copilot's folder in the sidebar as a project, its session as a
   * row inside it, and its terminal in the workspace — all while the pinned
   * entry at the top of the rail claims to be the one place the copilot lives.
   * Two things on screen contradicting each other, and one of them a second
   * xterm bound to a pty another view is already resizing.
   *
   * So it comes out here, once, by id and by folder. By **both**, because the
   * two answers arrive at different moments: the id identifies the running
   * process, and the folder catches the row for a copilot session that has
   * exited but is still in the list, and catches the project heading its cwd
   * would otherwise create. Neither is guessed — both come from
   * `copilot:state`, which is the module that decides where the copilot lives.
   *
   * Until that answer lands, nothing is filtered and the row is briefly visible.
   * That is the honest trade: the alternative is holding the whole session list
   * back on an IPC round trip, which would delay every session a person cares
   * about in order to hide one they do not.
   */
  const copilotSessionId = copilot.state?.sessionId ?? null
  const copilotRoot = copilot.state?.paths?.root ?? null
  const sessions = useMemo(
    () =>
      storedSessions.filter(
        (session) => session.id !== copilotSessionId && session.projectPath !== copilotRoot,
      ),
    [storedSessions, copilotSessionId, copilotRoot],
  )
  const projects = useMemo(
    () => storedProjects.filter((project) => project.path !== copilotRoot),
    [storedProjects, copilotRoot],
  )

  /**
   * This window, registered as the one that answers the copilot's alter-tier
   * confirmations.
   *
   * Mounted unconditionally rather than with the copilot's page, and that is the
   * whole point of it being here. `deck-control` refuses every alter call with
   * `no-approver` until a window has volunteered, and the copilot can be asked
   * to do something — by a routine, by a paired device — while nobody is looking
   * at its page. A gate whose answerer only exists on one screen is a gate that
   * is shut everywhere else.
   */
  const consent = useConsent()

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
  /**
   * The folder the New session dialog should open on, when the press that
   * opened it named one.
   *
   * Null means "wherever I am", which the dialog resolves to `activeProjectPath`
   * — the answer for ⌘T, for the rail's own button and for the terminal glyph in
   * the strip. The ＋ on a project heading is the one press that means a
   * *specific* folder, and it used to spawn straight into it; now that every
   * route goes through the dialog, that intent has to survive the trip or the
   * press quietly changes which project it is about.
   */
  const [newSessionPath, setNewSessionPath] = useState<string | null>(null)
  const [helpOpen, setHelpOpen] = useState(false)
  const [joinOpen, setJoinOpen] = useState(false)
  const [inspectorOpen, setInspectorOpen] = useState(false)
  /**
   * The alerts sheet.
   *
   * A dialog flag beside the other six rather than a `PanelId`, and that is the
   * whole of the change: *"and notifications should be a pop-up just like
   * settings, not a full page."* Every route in — the bell on the rail, the
   * command palette's row, the menu command that lands in `run` — sets this.
   * Nothing navigates.
   */
  const [alertsOpen, setAlertsOpen] = useState(false)
  const [paletteMode, setPaletteMode] = useState<'files' | 'commands' | 'sessions' | null>(null)
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
  /*
   * Which agent a new session would run. Read here as well as inside
   * `newSessionIn` because the account chip has to describe the same decision
   * before it is made — an account only means something to an agent that reads
   * a config directory, and this setting is what decides that.
   */
  const defaultProvider = stringSetting(settings, 'general.defaultProvider')

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
    alertsOpen || pendingClose !== null || paletteMode !== null ||
    // The copilot's confirmation counts, and it is the one that would fail
    // worst without it: a browser page is a native WebContentsView layered
    // above the HTML, so a permission dialog opened while a page was on screen
    // would be *behind* the page — invisible, unanswerable, and refused two
    // minutes later by a timeout nobody could have prevented.
    consent.question !== null

  /** Sessions first, then anything else the user opened, in one list. */
  const tabs: WorkspaceTab[] = [
    ...sessions.map((session) => ({
      id: session.id,
      kind: 'session' as const,
      label: session.title,
      status: session.status,
      projectPath: session.projectPath,
      // The account this session actually runs as, filled in by the main
      // process at spawn. Absent for a shell and for any agent whose login this
      // app cannot isolate — see `SessionMeta.profileId`. The sidebar shows it
      // only when there is more than one in play; two sessions in one folder
      // under two accounts have to be tellable apart, and one account on every
      // row is noise.
      // `provider` goes with it so the account chip can draw the agent's mark
      // without opening the account list — see `WorkspaceTab.account`.
      ...(session.profileId && session.profileName
        ? {
            account: {
              id: session.profileId,
              name: session.profileName,
              provider: session.provider,
            },
          }
        : {}),
      // Who wanted this session, and which copilot turn started it. Carried
      // straight off `SessionMeta` — the main process writes both at spawn —
      // so the rail can group what the copilot started under its own heading
      // and link each row back to the turn that explains it. Conditional, so
      // "no origin" crosses into the tab as an absent key rather than as
      // `undefined`, which is the same distinction `PtyManager` preserves.
      ...(session.origin ? { origin: session.origin } : {}),
      ...(session.originRunId ? { originRunId: session.originRunId } : {}),
      closable: true,
    })),
    /*
     * Pages other than sessions — which today means browser tabs, and only
     * while the browser is installed.
     *
     * Hidden rather than closed. Uninstalling is not meant to throw away what
     * you have open: the tab list is kept exactly as it was, so installing the
     * browser again brings the same pages back, which is the same promise the
     * store makes about everything else — the code never left, so neither did
     * this.
     */
    ...extraTabs.filter((tab) => tab.kind !== 'browser' || features.on('browser')),
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
    /*
     * Siblings are the sessions listed *beside* this one, which since the
     * copilot got its own group means sessions of the same origin as well as
     * the same folder.
     *
     * Counting across both would number a copilot session by its position in a
     * list it is not drawn in — "Session 13" here, "Session 1" in the rail's
     * Copilot sessions group — which is one session wearing two names in two
     * places on the same screen.
     */
    const own = startedByCopilot(tab)
    const siblings = tabs.filter(
      (t) => t.kind === 'session' && t.projectPath === tab.projectPath && startedByCopilot(t) === own,
    )
    return sessionLabel(
      tab.label,
      siblings.findIndex((t) => t.id === tab.id),
      folderNameOf(tab.projectPath),
    )
  }

  /**
   * The sessions the copilot started, named the way the rail names them.
   *
   * The forward half of "why does this exist": the rail's Copilot sessions
   * group is the list, and the copilot's own page carries this so a person
   * standing in front of the thing that started them can open each one. Named
   * through `labelOf` rather than off `tab.label` so the page and the row say
   * the same words — an untitled session is "Session 3" in both places or in
   * neither.
   */
  const copilotStarted = partitionByOrigin(tabs).copilot.map((tab) => ({
    id: tab.id,
    label: labelOf(tab),
    runId: turnOf(tab),
  }))

  /**
   * Latest sessions and switches, for the callbacks that must not re-register.
   * Assigned during render, so an effect that runs after it always sees the
   * values of the render it belongs to.
   */
  const sessionsRef = useRef(sessions)
  sessionsRef.current = sessions
  /*
   * Everything open, for the same reason and read the same way.
   *
   * The prune and the Split command both need the *whole* list — a pane can
   * hold a page as readily as a session — and both run from callbacks that must
   * not re-register on every render. `tabs` is rebuilt each render by design,
   * so a ref is what lets an effect see the current one without making the
   * array itself a dependency.
   */
  const tabsRef = useRef(tabs)
  tabsRef.current = tabs
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

  /**
   * Alerts, fetched once for the whole window.
   *
   * Two surfaces read this and it is deliberately one feed: the dot on the bell
   * in the rail, and the sheet the bell opens. The sheet used to fetch for
   * itself, which is why the dot never lit — a dialog only exists while it is
   * open, so with the scan inside it there was nothing producing a report for
   * anything else to count, and `Sidebar`'s `alertCount` sat there drawn,
   * tested and fed by nobody.
   *
   * `alerts-feed.ts` carries the argument about *when* it scans; the short
   * version is that it subscribes to session events rather than keeping a
   * clock, because a scan reads every transcript in the project and the app's
   * standing rule is events, not polling.
   *
   * The predicate is what keeps a busy machine honest. `session:status` is
   * machine-wide, and `alerts.ts` filters live sessions by project before any
   * rule sees them, so an agent going idle in another folder cannot change this
   * folder's alerts — scanning to rediscover that is the one avoidable cost
   * here, and it grows with exactly the way this app is used.
   *
   * A null path is how the feed is told to do nothing, so switching Alerts off
   * in Settings stops the scanning as well as the drawing. `off` is the state
   * somebody chose deliberately, and a feature that is off but still reading
   * every transcript in the project is the kind of thing that makes turning a
   * feature off pointless.
   */
  const alertsFeed = useProjectAlerts(features.on('alerts') ? activeProjectPath : null, {
    sessionInProject: (id) =>
      sessions.find((session) => session.id === id)?.projectPath === activeProjectPath,
  })

  /**
   * The same filter the sheet applies, applied to the same report.
   *
   * Both the count and the "you have seen this" record are computed from the
   * *shown* alerts rather than the raw ones, so switching off "Show insight
   * alerts" cannot leave a dot standing for four rows the sheet would refuse to
   * draw — which is the version of this defect that would be hardest to
   * diagnose, because the panel behind the dot would look empty and correct.
   */
  const showInsightAlerts = booleanSetting(settings, 'general.showInsightAlerts')
  const shownAlerts = useMemo(
    () => (alertsFeed.report ? withInsights(alertsFeed.report, showInsightAlerts) : null),
    [alertsFeed.report, showInsightAlerts],
  )
  const [alertsSeen, setAlertsSeen] = useState<SeenAlerts>(() =>
    readSeen(globalThis.localStorage ?? null),
  )
  const alertCount = shownAlerts
    ? unreadCount(shownAlerts.alerts, alertsSeen, activeProjectPath)
    : 0

  /**
   * Opening the sheet is what marks an alert read. See `alerts-unread.ts` for
   * why that is the only clearing event and why an escalated alert counts as a
   * new one.
   *
   * It runs on every report while the sheet is open, not only on the open, and
   * that is the case worth stating: the feed keeps scanning behind the dialog,
   * so an alert that appears while you are reading the list has been put in
   * front of you as surely as the ones that were there when you pressed the
   * bell. Marking only at open would light the dot on a sheet you are looking
   * at. `markSeen` returns the same object when nothing changed, which is what
   * stops this effect from writing to disk on every scan.
   */
  useEffect(() => {
    if (!alertsOpen || activeProjectPath === null || shownAlerts === null) return
    const next = markSeen(alertsSeen, activeProjectPath, shownAlerts.alerts)
    if (next === alertsSeen) return
    writeSeen(globalThis.localStorage ?? null, next)
    setAlertsSeen(next)
  }, [alertsOpen, activeProjectPath, shownAlerts, alertsSeen])

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
  const focusedId = splitting ? focusedTabId(panes) : activeTab?.id ?? null
  const focusedSession = focusedId
    ? sessions.find((session) => session.id === focusedId) ?? null
    : null

  useEffect(() => unread.subscribe((snapshot) => setUnreadIds(snapshot.ids)), [unread])

  /**
   * A pane naming something that no longer exists is a hole with no
   * explanation, and `focusedTabId` would keep answering with an id the
   * store has already forgotten — so the chrome and the inspector would be
   * reading a dead session's name. Driven off the open list rather than off
   * each close path, because a session can leave four different ways (⌘W, the
   * row's ✕, the process exiting, a whole project closing) and only one of them
   * is a place a caller could remember to prune.
   *
   * **`tabs`, not `sessions`.** A pane may hold a browser page, and handed the
   * session list this call declares that pane dead and collapses the whole
   * hand-made layout on the render after the page was opened — which is exactly
   * what happened when the globe was first wired to the focused pane, and why
   * it was backed out. `layout/panes.ts` carries the long version. The deps are
   * the two lists `tabs` is built from plus the feature registry that filters
   * it, because `tabs` itself is a fresh array on every render.
   */
  useEffect(() => {
    setPanes((current) => pruneClosedPanes(current, tabsRef.current))
  }, [sessions, extraTabs, features])

  /**
   * A layout that belongs to a feature that has just gone.
   *
   * Uninstalling split view or swarm from the store while the window is showing
   * one of them would otherwise leave the feature on screen, running, with
   * nothing in the app left to turn it off — the mode switch has no Split
   * segment to press by then, and the palette row is gone. Off has to mean gone
   * from what is in front of you, not only from the menus.
   *
   * Both fall back to the single-session view, which is what the window is
   * without either of them.
   */
  useEffect(() => {
    // The same layout back when there is nothing to collapse: a fresh object
    // here would be a new state, and a new state is a render, on every change
    // to any feature.
    if (!features.on('split')) setPanes((current) => (isSplit(current) ? emptyLayout() : current))
    if (!features.on('swarm')) setSwarm(false)
  }, [features])

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
    async (path: string, resume = false, profileId?: string, runAs?: ProviderId) => {
      /*
       * The default agent is *sent*, not assumed.
       *
       * `session:create` used to go out with no provider at all, so the main
       * process fell back to Claude Code whatever General said — someone whose
       * default was Plain shell got Claude from the sidebar button while the
       * new-session dialog, which does read the setting, pre-selected Shell.
       * The app disagreed with itself about its own preference.
       *
       * `runAs` overrides it, and only the two callers that are starting a
       * session *for an account* pass one. An account is a login of one
       * specific CLI, so those two have already decided which agent this is —
       * pressing Sign in beside a Codex account, or picking a Codex account
       * from the chip, means Codex whatever General says. Without it the
       * request went out on the default agent, `resolveProfileId` refused to
       * run one agent's account under another's session, and the account was
       * silently dropped: reported as *"if I add any new account it just
       * redirects me to claude only"*.
       */
      const provider = runAs ?? stringSetting(settings, 'general.defaultProvider')
      const meta = await window.deck.createSession({
        cwd: path,
        cols: 100,
        rows: 30,
        resume,
        ...(isProviderId(provider) ? { provider } : {}),
        /*
         * The account, when one was picked for *this* session.
         *
         * Left off otherwise, and that is not the same as sending null: absent
         * means "resolve it", and the main process then applies this folder's
         * account, or the default one, in that order. Sending a fixed id from
         * here would freeze today's answer and quietly ignore a per-folder
         * account the user set afterwards. `profiles.ts` owns that chain.
         */
        ...(profileId ? { profileId } : {}),
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
      /*
       * And keep it up there. *"If I want to remove it from there and keep only
       * side panel, I should have to do it myself specifically."*
       *
       * Without this the new session did appear on the bar — `shownTabs` always
       * draws the tab you are looking at — but as a *transient* tab, which is
       * gone the moment you click another one. See `keepInStrip`, which is also
       * where the reasoning lives for why this is at the three places a window
       * is *created* and not wherever one becomes active.
       */
      keepNewWindowInStrip(meta.id)
    },
    [addProject, addSession, showTab, settings],
  )

  /**
   * Choose a folder, then start a session in it — optionally under a chosen
   * account.
   *
   * The account matters on exactly one path and it is the one that would have
   * been missed: signing an account in on a machine with nothing open. There is
   * no folder to fall back on there, so the chooser comes up first, and the
   * account has to survive that detour or the session opens under the wrong
   * login and the sign-in lands on the wrong account.
   */
  const openProjectAs = useCallback(
    async (profileId?: string, runAs?: ProviderId) => {
      const path = await window.deck.pickProjectFolder()
      if (!path) return
      // Through `newSessionIn`, so the first session in a project starts on the
      // same agent every other one does — and is registered the same way. This
      // call used to build its own request and left the provider off it.
      await newSessionIn(path, false, profileId, runAs)
      setOnboardingDone(true)
    },
    [newSessionIn],
  )

  /*
   * The no-argument form, which is what every button binds to.
   *
   * Separate on purpose: `onClick={openProject}` hands the handler a
   * MouseEvent as its first argument, and a function whose first parameter is
   * an account id would take that event as an account.
   */
  const openProject = useCallback(() => {
    void openProjectAs()
  }, [openProjectAs])

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
    (path?: string, resume = false, profileId?: string, runAs?: ProviderId) => {
      const target = path ?? activeProjectPath ?? lastFolderRef.current
      if (target) void newSessionIn(target, resume, profileId, runAs)
      // No folder anywhere — a first launch. The chooser is not "a dialog in
      // the way" at that point, it is the only question left, and the account
      // travels through it — with the agent it is a login of, which has to
      // survive the detour for the same reason the account does.
      else void openProjectAs(profileId, runAs)
    },
    [activeProjectPath, newSessionIn, openProjectAs],
  )

  /**
   * Every route to a new session, and there is now exactly one of them.
   *
   * Asad, 2026-08-17: *"if we click directly on the whole button it opens a
   * quick window. We don't want this quick window at all. We just always wanted
   * this pop-up to come up so we choose which type of terminal we want to
   * open… 'Remember these choices for this project' is good enough."*
   *
   * That last clause is what makes this affordable. A dialog in front of every
   * ⌘T is a tax if it asks the same four questions every time; it is not one if
   * it remembers what you answered for this folder and reduces to a single
   * confirmation. `NewSessionDialog` already stores that per project and
   * pre-fills from it, and `⌘↵` starts without touching the mouse — so the
   * cost of losing the quick path is one keystroke, and what is bought back is
   * that the app never again spawns an agent nobody named.
   *
   * The direct spawn is *not* deleted — `newSession` above is still what the
   * dialog's Start, Continue-last-session, the account chip and the sign-in
   * flow all call. What is gone is any *button* that reaches it without asking.
   */
  const openNewSessionDialog = useCallback((path?: string) => {
    setNewSessionPath(path ?? null)
    setNewSessionOpen(true)
  }, [])

  /**
   * A tab has been taken off the top bar and it was the one on screen.
   *
   * Deliberately not `selectTab`. That one is a navigation and clears whatever
   * view is covering the window, which is right for a click on a tab and wrong
   * here: pressing ✕ on the tab you will come back to, while you are reading
   * Files, must leave you in Files. Everything else it does — the store's
   * active session, the focused pane in a split — still has to happen, or the
   * terminal on screen and the tab that names it disagree.
   *
   * `null` is a real answer and not a failure: it means nothing is left on the
   * bar to fall back to. It does not blank the window — `activeTab` above has
   * resolved a null selection to `tabs[0]` since long before this bar existed,
   * so the last tab you take off is replaced by the first session you have
   * open, drawn as a transient tab. That is the right outcome and not an
   * accident of the fallback: a window that is showing a terminal must have a
   * tab naming it, which is the whole reason `shownTabs` always draws the
   * active one.
   */
  const showInstead = useCallback(
    (id: string | null) => {
      setActiveTabId(id)
      if (id === null) return
      if (sessionsRef.current.some((session) => session.id === id)) setActiveSession(id)
      setPanes((current) => (isSplit(current) ? showInFocusedPane(current, id) : current))
    },
    [setActiveSession],
  )

  /**
   * A page reporting what it is called, which is what its tab and its pane bar
   * both print.
   *
   * Lifted out of the panel's `onTitle` because there are two panels now — one
   * filling the window, one inside a pane — and a second copy of the
   * same-array-back rule is how the two would come to differ about whether an
   * unchanged title is a state change. It is not: `prev.map` always builds a new
   * array, a new array is a new state, a new state is a render, and the render
   * reports the title again.
   */
  const renameBrowserTab = useCallback((id: string, title: string) => {
    setExtraTabs((prev) =>
      prev.some((entry) => entry.id === id && entry.label !== title)
        ? prev.map((entry) => (entry.id === id ? { ...entry, label: title } : entry))
        : prev,
    )
  }, [])

  const newBrowserTab = useCallback(() => {
    /*
     * Asking for a browser tab you do not have installs the pane and opens one.
     *
     * The same bargain `setMode('split')` makes, and for the same reason: the
     * globe beside New session is drawn as an offer in that state (see
     * `useControlOffer`), so this is not a surprise — and a pane appearing under
     * the pointer that asked for it is a better "where to find it" than any
     * sentence about somewhere else.
     */
    if (!features.on('browser')) features.install('browser')
    const id = `browser:${Date.now()}`
    setExtraTabs((prev) => [...prev, { id, kind: 'browser', label: 'New tab', closable: true }])
    showTab(id)
    /*
     * Started while the window is split: the page belongs in the pane you are
     * looking at, which is the same rule `newSessionIn` follows.
     *
     * This line was written once before and taken straight back out, because it
     * did select the tab and it also destroyed the split — a pane holding an id
     * that was not in the *session* list was a dead pane, and the prune
     * collapsed the layout on the next render. It was pinned as "never call
     * `setPanes` from here", which pinned the workaround.
     *
     * What made it safe is not this call site. It is that a pane holds a tab
     * rather than a session and the prune is told about pages — see
     * `layout/panes.ts` — so there is no longer anything special about a page
     * for the layout to choke on. Without this, a page opened from the globe
     * while split arrives on the bar unselected and stays behind the split,
     * which is where the whole defect was first seen.
     */
    setPanes((current) => (isSplit(current) ? showInFocusedPane(current, id) : current))
    // Kept on the bar, exactly as a new session is — *"if I open any new session
    // and any new browser from the header, it should automatically open in the
    // top bar"*. The globe at the end of the strip is one of this function's
    // three callers; the sidebar's globe and the palette's New browser tab are
    // the others, and all three open a window in the same sense, so all three
    // keep it. See `keepInStrip`.
    keepNewWindowInStrip(id)
  }, [showTab, features])

  const selectTab = useCallback(
    (id: string) => {
      showTab(id)
      /*
       * While the window is split, a sidebar row or a tab fills the pane you
       * are looking at rather than taking the whole window back.
       *
       * This is the sentence that makes the two models one model. The list
       * keeps meaning exactly what it always meant — "show me this" — and the
       * only thing that changed is where "show" happens to be. It is
       * deliberately not "open it in a new pane": the sidebar is a list of what
       * you have open, not a layout editor, and a click that quietly multiplied
       * your panes would be the list fighting the layout.
       *
       * This used to sit *after* an early return for anything that was not a
       * session, so while split there was no route to a browser page at all:
       * picking one selected a tab whose content the window had nowhere to
       * draw. That early return was not a rule about navigation, it was the
       * pane model refusing to hold a page — see `layout/panes.ts`.
       */
      setPanes((current) => (isSplit(current) ? showInFocusedPane(current, id) : current))
      // Terminals key off the store's active session; keep the two in step or
      // switching to a session shows the previously focused terminal. A page
      // has no session to make active, and must not overwrite the one that is.
      if (!sessions.some((session) => session.id === id)) return
      setActiveSession(id)
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

  /**
   * Where the Connectors chip in a session's controls goes.
   *
   * The app already has one connector surface — the MCP servers view, with its
   * add form, its inspector and its account of what each server exposes — and
   * what was missing was a way to reach it from the session you are running in.
   * So the chip opens that view rather than growing a second list of servers in
   * a popover, which would be a second MCP system drifting from the first from
   * the day it shipped.
   *
   * Null when the view is not installed in this build, which is what makes the
   * chip say so instead of quietly doing nothing: a feature can be uninstalled
   * here, and a control that would have opened it must admit that rather than
   * vanish. See `SessionControls.tsx`.
   */
  const openConnectors = features.panelOn('mcp') ? () => showPanel('mcp') : null

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
      // `tabsRef`, not `sessionsRef`: pressing Split while a page is in front
      // used to seed the first pane from the session list, so the page you were
      // reading simply disappeared the moment you split the window.
      isSplit(current) ? splitFocused(current) : seedSplit(tabsRef.current, focusedId),
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
        /*
         * Asking for split you do not have installs it and splits.
         *
         * The segment is drawn as an offer in that state, so this is not a
         * surprise — and it is the best "where to find it" the store could
         * possibly give, because the thing appears under the pointer that asked
         * for it rather than in a sentence about somewhere else.
         */
        if (!features.on('split')) features.install('split')
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
    [splitPanes, closeSplit, focusedId, setActiveSession, features],
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
      const survivor = focusedTabId(closePane(panes, paneId))
      const next = closePaneOrCollapse(panes, paneId)
      setPanes(next)
      if (isSplit(next) || !survivor) return
      setActiveTabId(survivor)
      // The survivor can be a page, which the store has no session for.
      if (sessionsRef.current.some((session) => session.id === survivor)) {
        setActiveSession(survivor)
      }
    },
    [panes, setActiveSession],
  )

  /**
   * Close whichever pane has the keyboard — the only way to close the *host*.
   *
   * Every guest pane draws its own ✕, in its own bar. The host has neither, and
   * that is deliberate: its chrome lives in the window's toolbar so that the
   * split reads as one main session with something beside it, and a bar drawn
   * for the host purely to hold a close button would put back the symmetry the
   * whole arrangement exists to avoid.
   *
   * What it must not do is leave the host unclosable. With two panes there is
   * an equivalent route — focus the guest, press Terminal, and the split
   * collapses onto it — but with three there is none, and "you can only ever
   * close the panes you added" is a rule nobody would guess. So the act gets a
   * name in the palette instead of a glyph on the screen, which is where people
   * look for a capability they cannot see. It is offered only while there is a
   * split, because outside one it would be a row that does nothing.
   */
  const closeFocusedPane = useCallback(() => {
    const paneId = panes.focusedPaneId
    if (paneId) closePaneAt(paneId)
  }, [panes.focusedPaneId, closePaneAt])

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
    const id = focusedTabId(panes)
    if (!id) return
    setActiveTabId(id)
    /*
     * Only a session reaches the store.
     *
     * A pane can hold a browser page now, and `activeSessionId` is what the
     * composer, the chat bridge and "send this to the agent" all write to —
     * handed a `browser:…` id they would address a pty that does not exist.
     * Leaving it on the last session pane that had focus is not a fallback, it
     * is the right answer: a page beside a terminal sends to that terminal.
     */
    if (sessionsRef.current.some((session) => session.id === id)) setActiveSession(id)
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
      // ⌘T, and it opens the dialog. There is no second "New session with
      // options…" row any more: it was the same destination under a second
      // name, which is exactly the two-doors-one-room shape this app keeps
      // removing. ⌘⇧T and the application menu's "New Session…" still work —
      // they arrive as `session.newDialog` and are aliased in `run` below,
      // because that accelerator is printed by an Electron menu in the main
      // process and a chord this window silently stopped answering to would be
      // worse than a duplicate row.
      { id: 'session.new', title: 'New session…', group: 'Session', run: () => openNewSessionDialog() },
      { id: 'session.resume', title: 'Continue last session', group: 'Session', run: () => newSession(undefined, true) },
      { id: 'project.open', title: 'Open a project', group: 'Project', run: () => void openProject() },
      { id: 'palette.quickOpen', title: 'Open a file…', group: 'Project', run: () => setPaletteMode('files') },
      { id: 'view.browser', title: 'New browser tab', group: 'View', run: () => newBrowserTab() },
      { id: 'pane.split', title: 'Split the window', group: 'View', run: () => splitPanes() },
      /*
       * Only while there is a split, because outside one it would be a row that
       * runs and does nothing — the exact shape the note beside ⌘D calls
       * indistinguishable from a broken command.
       *
       * It exists at all because the host pane has no ✕ of its own: its chrome
       * is up in the window's toolbar, which is what makes the split read as a
       * main session with a guest beside it. See `closeFocusedPane`.
       */
      ...(splitting
        ? [
            {
              id: 'pane.close',
              title: 'Close the focused pane',
              group: 'View',
              run: closeFocusedPane,
            },
          ]
        : []),
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
      // No chord, deliberately. The rail's pinned row is one press away at the
      // very top of the window, so a shortcut would be a third route to
      // something already reachable in one — and every chord spent is one fewer
      // left for the sessions this app is actually about. The palette row still
      // earns its place: it is where somebody looks for a thing by name.
      { id: 'view.copilot', title: 'Copilot', group: 'View', run: () => showPanel('copilot') },
      { id: 'view.dashboard', title: 'Overview', group: 'View', run: () => showPanel('overview') },
      { id: 'view.files', title: 'Files', group: 'View', run: () => showPanel('files') },
      // `view.search` keeps its id, and therefore its ⌘⇧F chord, while what it
      // opens has moved. Searching past sessions is no longer a page — it is the
      // command palette's `?` sigil, beside `>` for commands. Renaming the id
      // would silently drop the chord out of `keymap.ts`, so the entry stays and
      // its `run` changes.
      { id: 'view.search', title: 'Search past sessions', group: 'View', run: () => setPaletteMode('sessions') },
      { id: 'view.artifacts', title: 'Artifacts', group: 'View', run: () => showPanel('artifacts') },
      { id: 'view.git', title: 'Source control', group: 'View', run: () => showPanel('git') },
      { id: 'view.github', title: 'GitHub', group: 'View', run: () => showPanel('github') },
      // The id stays `view.alerts`, and what it opens has moved — the same
      // trade `view.search` above makes, for the same reason. The id is what
      // the feature registry gates on and what a chord would bind to; renaming
      // it to `app.alerts` would drop it out of the registry's `commands` list
      // and out of whatever menu item lands on it, to describe a change the
      // user cannot see. What they can see is that the row no longer takes the
      // window away.
      { id: 'view.alerts', title: 'Alerts', group: 'View', run: () => setAlertsOpen(true) },
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
    /*
     * Every uninstalled feature, offered by name.
     *
     * This is the palette's half of the discoverability fix, and it is the half
     * that matters most: the palette is where people look for a capability they
     * cannot see. Without these rows, typing "split" into a window whose split
     * view is uninstalled returns nothing at all, and nothing at all is how
     * somebody concludes the app cannot do it. With them it returns "Install
     * Split view", which is the same keystroke answering the same question.
     *
     * The description rides along as keywords, so "cost" finds Cost and usage
     * and "microphone" finds voice dictation without either word having to be
     * squeezed into the title.
     */
    const offers: Omit<PaletteCommand, 'shortcut'>[] = availableFeatures(features.state).map(
      (entry) => ({
        id: `features.install.${entry.id}`,
        title: `Install ${entry.name}`,
        group: 'Features',
        keywords: entry.summary,
        run: () => features.install(entry.id),
      }),
    )

    return [...rows, ...offers].map((row) => {
      const chord = chordFor(row.id)
      return {
        ...row,
        // A row for a feature that is not installed is not offered as though it
        // worked. It is not silently dropped either — `run` below turns the
        // same command into the store, so the menu item and the chord that
        // reach this id land somewhere that explains itself.
        enabled: features.commandOn(row.id),
        ...(chord === null ? {} : { shortcut: chord }),
      }
    })
  }, [
    newSession,
    newBrowserTab,
    openNewSessionDialog,
    openProject,
    showPanel,
    openSettings,
    sidebar,
    splitPanes,
    splitting,
    closeFocusedPane,
    closeSplit,
    features,
  ])

  /**
   * One dispatcher for every command, whatever fired it: a menu item, a chord
   * or a row in the palette. The three used to be three switch statements, and
   * the shortcuts sheet documented chords none of them implemented.
   */
  const run = useCallback(
    (id: string): boolean => {
      /*
       * A command whose feature is not installed opens the store instead.
       *
       * The chord is the case this exists for: the palette row is hidden and
       * the sidebar row is gone, but ⌘D is muscle memory and the keymap still
       * answers to it. Doing nothing at all would be indistinguishable from a
       * broken shortcut. Landing in Features says what happened and offers the
       * thing back, one click away, which is the same answer every other empty
       * place in this window gives.
       */
      const owner = features.featureForCommand(id)
      if (owner && !features.on(owner)) {
        openSettings('features')
        return true
      }
      const command = commands.find((c) => c.id === id)
      if (command) {
        void command.run()
        return true
      }
      switch (id) {
        case 'session.close':
          if (activeTab) closeTab(activeTab.id)
          return true
        // ⌘⇧T, and the application menu's "New Session…". One destination with
        // two chords is fine; two destinations would not be. See the palette
        // rows above for why the second row went and this alias stayed.
        case 'session.newDialog':
          openNewSessionDialog()
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
          setPaletteMode('sessions')
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
      openNewSessionDialog,
      openSettings,
      selectTab,
      sessions,
      focusNeighbour,
      features,
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
          /*
            What the copilot's page can reach. Spelled out as an object like
            `dashboard` below, and for the same reason: every one of these is a
            thing the page cannot work out for itself, and passing it here is
            what stops the page growing a second connection to the copilot that
            would disagree with the rail's.

            The terminal settings are the same three the session terminals read,
            so the copilot's terminal is not a differently-shaped terminal.
          */
          copilot={{
            copilot,
            startedSessions: copilotStarted,
            onOpenSession: selectTab,
            fontSize: terminalFontSize,
            fontFamily: terminalFontFamily,
            copyOnSelect,
          }}
          /* `showInsights` and `onAlertAction` used to be handed down here.
             They belong to the AlertsWindow sheet now — mounted at the bottom
             of this file — because Alerts is a dialog over the window rather
             than one of the views inside it.

             Written without angle brackets on purpose: `wiring.test.ts` finds a
             component's opening tag by searching for the first `<Name` in the
             file, so a comment naming one as JSX hands it a tag with no props
             in it and every seam it guards silently reports "missing". */
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
            /*
             * The session count is a door onto swarm view, so it is only a door
             * while swarm is installed. Omitted rather than passed and ignored:
             * the widget draws the number as plain text when it has nowhere to
             * go, which is exactly right — the count is still true, it just
             * stops promising a click.
             */
            ...(features.on('swarm')
              ? {
                  onShowSessions: () => {
                    clearPanel()
                    closeSplit()
                    setSwarm(true)
                  },
                }
              : {}),
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
          renderPane={({ paneId, tabId, focused, primary }) => {
            /*
             * A pane holds a *tab*, which is a session or a page.
             *
             * It held a session id until 2026-08-17, and that is the whole of
             * why a browser page in a pane was impossible: the prune effect
             * above is driven off the open list, and a pane naming something
             * that was not in it was a dead pane. See `layout/panes.ts`.
             *
             * Only the tabs a pane actually holds are mounted here. That is the
             * same bargain the terminals have always made in this branch —
             * entering a split remounts, and the main process holds each
             * session's scrollback so a remount is a redraw from a buffer. For
             * a page it is not free: a page open on the bar but not in a pane
             * has no view while the split is up, and comes back at its start
             * address when the split is closed. That is not a regression (this
             * branch used to mount no pages at all, which is why none of them
             * could be seen) but it is the next thing to fix here, and it wants
             * the split kept mounted behind a sidebar page rather than a change
             * in this expression.
             */
            const paneTab = tabId ? tabs.find((entry) => entry.id === tabId) ?? null : null
            const sessionTab = paneTab?.kind === 'session' ? paneTab : null
            const pageTab = paneTab?.kind === 'browser' ? paneTab : null
            const session = sessionTab
              ? sessions.find((entry) => entry.id === sessionTab.id) ?? null
              : null

            return (
              <div className="pane-cell" data-focused={focused} data-primary={primary}>
                {/*
                  A *guest* pane's own chrome, describing that pane's content.

                  The account chip used to be drawn once for the whole window
                  while the window could show two sessions from two projects
                  under two accounts — so whatever it said was wrong for at
                  least one of them, with nothing on screen to say which.

                  `!primary` is the correction of 2026-08-17. A first pass gave
                  every pane one of these and emptied the window's bar out, and
                  that threw away the thing that made one pane read as the
                  session: *"If we make both exactly the same placement — if the
                  name and the account come down — then there is no reason to
                  keep one of them in a box, because all the sizes, everything,
                  is the same. So let's keep the main."* The host's name, folder
                  and account stay upstairs in the window's toolbar, where they
                  sat before anybody split anything, and the window's bar is
                  unambiguous about *which* pane it means precisely because the
                  host is the pane with no box and no bar of its own.

                  The per-pane argument survives for the guests, unchanged: a
                  pty has one cwd and one config directory, fixed at spawn, and
                  a guest has no other place on screen to say so.
                */}
                {!primary && (
                  <PaneBar
                    paneId={paneId}
                    focused={focused}
                    onClose={closePaneAt}
                    subject={
                      session && sessionTab
                        ? {
                            kind: 'session',
                            id: session.id,
                            title: labelOf(sessionTab),
                            status: session.status,
                            folder: session.projectPath ?? null,
                            // The account this session is actually running as,
                            // off its own `SessionMeta` — not the window's, and
                            // not the other pane's.
                            account: sessionTab.account ?? null,
                            // Spelled as a plain prop for the same reason the
                            // window's bar spells it out: `wiring.test.ts`
                            // cannot see through a conditional spread, and this
                            // is the seam it watches.
                            provider: isProviderId(defaultProvider) ? defaultProvider : undefined,
                            onPickAccount: (accountId, runAs) =>
                              newSession(session.projectPath ?? undefined, false, accountId, runAs),
                            onManageAccounts: () => openSettings('profiles'),
                          }
                        : pageTab
                          ? { kind: 'page', title: pageTab.label }
                          : { kind: 'empty' }
                    }
                    /*
                      This guest's own model, effort, fast mode and connectors,
                      acting on this guest's own pty.

                      The same component the window's bar carries for the host —
                      mounted once per pane, each with its own `sessionId`, which
                      is what makes "which session is this the model of" have the
                      same answer as "which terminal is it drawn over". `provider`
                      is the session's own, not `defaultProvider`: the chip above
                      is about the account a *new* session would use, and this is
                      about the CLI already running in this one.
                    */
                    controls={
                      session ? (
                        <SessionControls
                          sessionId={session.id}
                          cwd={session.projectPath ?? null}
                          provider={session.provider}
                          onOpenConnectors={openConnectors}
                        />
                      ) : undefined
                    }
                  />
                )}
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
                  ) : pageTab ? (
                    /*
                     * A live page, in a pane, beside a terminal.
                     *
                     * The panel measures its own rectangle and pushes it to the
                     * main process — the page is a native view floating over
                     * this tree — so it needs nothing from the split beyond
                     * being mounted inside it. Dragging the divider resizes the
                     * stage, the ResizeObserver in there fires, and the view
                     * follows.
                     *
                     * `visible` is the pane's own answer and not the window's:
                     * a sidebar page covering the window has to park it, the
                     * same as it does for a page filling the window.
                     */
                    <BrowserWorkspace
                      key={`${paneId}:${pageTab.id}`}
                      visible={!showingPanel}
                      parkPage={anyModalOpen}
                      startUrl={stringSetting(settings, 'browser.startUrl')}
                      onStartUrl={(url) => {
                        applySettings({ ...settings, 'browser.startUrl': url })
                        void window.deck.setSettings({ 'browser.startUrl': url })
                      }}
                      onTitle={(title) => renameBrowserTab(pageTab.id, title)}
                      onSendToAgent={(context) => {
                        // The store's active session, which while the window is
                        // split is the last *session* pane that had focus — a
                        // page taking focus deliberately does not overwrite it
                        // (see the effect that mirrors focus into the store).
                        // So "send to the agent" from a page beside a terminal
                        // reaches that terminal.
                        if (activeSessionId) window.deck.writeToSession(activeSessionId, context)
                      }}
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
              onTitle={(title) => renameBrowserTab(tab.id, title)}
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
   * The pane the window's own bar is about, while the window is split.
   *
   * The **host** — first in visual order, the one `SplitView` draws flush with
   * the window and does not box — and deliberately not the focused one. The bar
   * has to belong to a pane a reader can point at, and the only pane it can
   * belong to without being ambiguous is the one that has no box and no bar of
   * its own. A heading that followed focus would be the original bug in a
   * costume: still one heading over two sessions, just changing its mind.
   *
   * `primaryPane` rather than `listPanes(panes)[0]` because `SplitView` asks
   * the same question to decide which pane to box, and the two answers have to
   * be the same answer.
   */
  const hostPane = splitting ? primaryPane(panes) : null

  /**
   * The tab the window's heading is about.
   *
   * Split, that is whatever the host pane holds — a session, a page, or nothing
   * at all while a pane is waiting to be filled. Unsplit it is simply the tab
   * in front, and nothing here has changed from what it always was.
   *
   * No fallback to `activeTab` while split, and that is not an oversight: the
   * fallback would put the *guest's* name in the window's bar the moment the
   * host pane was empty, which is exactly the claim this bar must never make.
   * An empty host says so in its own body — `PageEmpty` below — and this bar
   * says nothing.
   */
  const headingTab = splitting
    ? (hostPane?.tabId ? tabs.find((tab) => tab.id === hostPane.tabId) ?? null : null)
    : activeTab

  /**
   * Whether the pane the bar is naming has the keyboard.
   *
   * Always true unsplit — there is nowhere else for focus to be. Split, it is
   * how the host pane says it is focused at all: it has no border to hang a
   * ring on, by design, so its identity dims instead, to exactly the weight an
   * unfocused guest's bar dims to. Watching the two swap as you click between
   * panes is what teaches "the top bar is the pane with no box", which is
   * otherwise a convention a first-time user has to guess.
   */
  const headingFocused = !splitting || (hostPane !== null && hostPane.id === panes.focusedPaneId)

  /**
   * The running session the window's bar is about, when it is about one.
   *
   * The bar's own controls — model, effort, fast mode, connectors — act on this
   * and on nothing else. Resolved from the *same* `headingTab` the bar's name,
   * folder and account come from, deliberately: the controls have to belong to
   * whichever session that bar is claiming, or the window would be naming one
   * session and setting the model of another, which is the confusion the split
   * chrome was reorganised to end.
   *
   * The tab is not enough on its own. `provider` — what is actually running in
   * the pty — lives on the session record rather than on the tab, and it is the
   * thing that decides whether these are offered at all: a `/bin/zsh -l` has no
   * model to set. Null while a sidebar view is filling the window, where the
   * bar's heading is a page's name and there is no session under it.
   */
  const headingSession =
    !showingPanel && headingTab?.kind === 'session'
      ? sessions.find((entry) => entry.id === headingTab.id) ?? null
      : null

  /**
   * What the window's own bar says — and while the window is split, it says the
   * *host* pane's name, folder and account.
   *
   * This was emptied out for a day. Every pane grew a bar of its own and this
   * one was left with the mode switch, on the argument that a name, a folder
   * and an account are facts about one session and this bar spans two. The
   * facts part is true and is why the guests keep their bars. What it missed is
   * that the host is not one of two interchangeable halves — Asad, 2026-08-17:
   *
   *   > *"We wanted to keep it in the top bar, under the pills of windows, so
   *   > it feels like a main session and the other ones like secondary
   *   > sessions. If we make both exactly the same placement — if the name and
   *   > the account come down — then there is no reason to keep one of them in
   *   > a box, because all the sizes, everything, is the same."*
   *
   * So the host's chrome never moves. Unsplit and split are the same expression
   * for it, which is the point: splitting a window does not relocate the
   * session you were already working in, it puts something beside it.
   */
  const heading = showingPanel && panel
    ? { title: panelSpec(panel).label, subtitle: panelSpec(panel).blurb, folder: null, account: null }
    : headingTab
      ? {
          title: labelOf(headingTab),
          subtitle: null,
          // The path is a control now rather than a caption — see FolderChip.
          folder: headingTab.kind === 'session' ? headingTab.projectPath ?? null : null,
          // And so is the account, beside it — see AccountChip. Null for a
          // session that has none, where the chip falls back to saying which
          // account a *new* session here would use.
          account: headingTab.kind === 'session' ? headingTab.account ?? null : null,
        }
      : splitting
        // A split whose host pane has not been filled. There is no name to
        // print, and printing the app's own name over an empty pane would read
        // as "nothing is open" while two sessions are running beside it. The
        // pane's body already says what it is; the bar keeps the mode switch.
        ? { title: null, subtitle: null, folder: null, account: null }
        // No subtitle. "Nothing open yet." is the sidebar's line, and it is there to
        // explain why the list beneath it is empty — a job this heading does not
        // share. Saying it here too put the same sentence on screen twice, a few
        // centimetres apart, while the page in the middle was already explaining
        // the same emptiness with a button. The title alone is enough.
        : { title: BRAND.name, subtitle: null, folder: null, account: null }

  /**
   * The folder the heading's two chips act on.
   *
   * Bound to a `const` rather than read off `heading` at each use so it narrows
   * inside the callbacks: a property access is re-widened inside a closure, and
   * both chips hand this folder to a callback that starts a session in it.
   */
  const headingFolder = heading.folder

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

  /**
   * Whether there is a tab strip, and therefore which bar is the window's top
   * band.
   *
   * Asked once, here, and handed to both — the strip only draws itself when
   * this is true, and the session bar only reserves room for the traffic lights
   * and draws the reveal button when it is false. Two components deciding it
   * separately is how you get two reveal buttons, or none.
   */
  const hasStrip = stripIsPresent(tabs)

  /**
   * The session bar, absent inside a browser page.
   *
   * *"If I am inside the browser, this whole bar header is useless."* It is: the
   * bar's four contents are a session's name, its folder, its login and whether
   * it is drawn as a terminal or a conversation, and a web page has none of
   * those. A sidebar view still gets it, because a view has a name and that name
   * is the heading of the page underneath.
   *
   * A *split* always gets it, whatever the host pane holds. Two reasons, and
   * either one on its own would be enough. The bar carries the host session's
   * name, folder and account, which is the whole of how a reader tells the two
   * panes' logins apart. And it carries the mode switch, which is the only way
   * back out of a split — dropping the bar because the host pane happens to
   * hold a web page would shut the door behind the user.
   */
  const showSessionBar = showingPanel || splitting || headingTab?.kind !== 'browser'

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
          // The rows this install has. A view whose feature is uninstalled has
          // no row at all rather than a disabled one — and the palette offers
          // it back by name, which is where somebody looks for a thing they
          // cannot see.
          panels={PANELS.filter((entry) => features.panelOn(entry.id))}
          browser={features.on('browser')}
          browserOffer={browserOffer?.title ?? null}
          /*
            The bell beside Settings, and whether there is one.

            Asked here rather than in the rail for the same reason `panels` and
            `browser` are: every decision about what exists is made next to the
            rest of the gating. `controlOn` rather than `on('alerts')` because
            the bell is what the registry declares — `sidebar.alerts` — and
            naming the surface keeps the question true if the surface ever
            changes hands.
          */
          alerts={features.controlOn('sidebar.alerts')}
          /* The number on the bell: alerts this project has that the sheet has
             not shown you. Computed above from the one feed the sheet reads, so
             the dot and the list cannot disagree. */
          alertCount={alertCount}
          unread={unreadIds}
          peeking={sidebar.peeking && sidebar.collapsed}
          // Above Settings, in the foot. Mounted here rather than inside the
          // sidebar so the component stays where the wiring test can see it and
          // where its bridge subscription belongs.
          update={<UpdateBanner />}
          /* The pinned row's status dot and its sentence. One connection, read
             here, so the rail and the page it opens cannot disagree about
             whether the copilot is running. */
          copilot={{ stage: copilot.stage, state: copilot.state }}
          /* Only the rows that link back to a turn use this; the pinned row
             navigates through `onSelectPanel` like every other view. */
          onOpenCopilot={(focus) => showPanel('copilot', focus ?? null)}
          onSelectTab={selectTab}
          onCloseTab={closeTab}
          onSelectPanel={showPanel}
          /*
            One route, and it is the dialog — including the ＋ on a project
            heading, which is why the folder is carried through rather than
            dropped. *"We just always wanted this pop-up to come up so we choose
            which type of terminal we want to open."*

            Continue-last-session is the exception and is deliberately still
            immediate: it is not a question about what kind of terminal to open,
            it is a named command with one answer, and putting a dialog in front
            of it would be a second thing he did not ask for.
          */
          onNewSession={(projectPath, resume) =>
            resume ? newSession(projectPath, true) : openNewSessionDialog(projectPath)
          }
          onNewBrowserTab={newBrowserTab}
          onOpenProject={openProject}
          onCloseProject={closeProject}
          onOpenSettings={() => openSettings()}
          // Opens the sheet. It does not touch `panel`, which is what makes the
          // bell a pop-up rather than a navigation: whatever you were looking
          // at is still on screen behind it, and closing puts you back with
          // nothing to restore.
          onOpenAlerts={() => setAlertsOpen(true)}
          onToggleCollapsed={sidebar.toggleCollapsed}
          onPeekStart={sidebar.beginPeek}
          onPeekEnd={sidebar.endPeek}
          onStartResize={sidebar.startResize}
        />
      )}

      <main className="main">
        {/*
          The tab strip, and it is the window's top band now — Asad, 2026-08-16:
          "this tabs should be upside, and this session and all this whole bar
          including chat, split, terminal should be under this, not above,
          because if I am inside the browser this whole bar header is useless."

          The two bars answer different questions and that is why the order
          matters. This one is the *window's*: what you have open, true whatever
          is on screen. The one under it is the *session's*, and inside a browser
          page it is not rendered at all rather than emptied — so this bar also
          takes on what a top band has to do, which is hold the traffic lights,
          move the window, and carry the control that brings a pinned-away rail
          back. See `hasStrip`, which is the one place that decides which of the
          two is first.

          `focusedId ?? activeTab?.id`: the same expression the sidebar and the
          heading below are given. Passing `activeTab?.id` alone was the reason a
          split window's title named one session while the strip highlighted
          another — and, further back, why the title could name a session with no
          tab in the strip at all. `shownTabs` closes the other half of that by
          always drawing the active tab, promoted or not.

          There is no `onClose` on this bar any more, and its absence is the
          behaviour change of 2026-08-17. The ✕ on a tab takes the tab off the
          strip and stops: *"it should not delete the session… side panel will
          have everything inside, and above we just set a view which one we want
          to see."* The only ✕ that ends a session is the rail's, which still
          goes through `closeTab` and its confirmation.
        */}
        {hasStrip && (
          <WorkspaceTabStrip
            tabs={tabs}
            activeTabId={focusedId ?? activeTab?.id ?? null}
            /* A sidebar view is filling the window, so none of these tabs is
               what is on screen — the bar below is headed with the view's name.
               The tab stays drawn, because it is what you will come back to;
               it just stops claiming to be the selected one. */
            covered={showingPanel}
            onSelect={selectTab}
            onShowInstead={showInstead}
            /* The two icons after the last tab. The terminal opens the dialog,
               not a session — the same single route the rail's button takes —
               and the globe opens a page on the start page. */
            onNewSession={() => openNewSessionDialog()}
            onNewBrowserTab={newBrowserTab}
            sidebarHidden={sidebar.collapsed}
            onRevealSidebar={sidebar.pin}
            onEdgeEnter={sidebar.beginPeek}
          />
        )}

        {showSessionBar && (
          <WindowToolbar
            title={heading.title}
            /* Which session that title is the name of, so the heading can be
               renamed where it is written rather than only in the rail — see
               `SessionTitle`. Null for a sidebar view, whose heading is the
               app's word for a page and not anybody's session.

               Split makes no difference here and must not: the heading is the
               host session's, in the same place, so double-click and F2 rename
               it in the same place. A guest's name is renamed in the guest's
               own bar, which carries the same control. */
            sessionId={
              !showingPanel && headingTab?.kind === 'session' ? headingTab.id : null
            }
            /* The host pane's focus, said in the host pane's chrome — which is
               up here. Without it the pane drawn flush with the window has no
               focus mark at all, because it deliberately has no border to ring. */
            headingFocused={headingFocused}
            subtitle={heading.subtitle}
            meta={
              headingFolder ? (
                /* Where, and who. The folder is a plain title — a pty has one
                   working directory for its whole life, so a menu here could
                   only ever have offered to start a different session, and he
                   asked for the word instead. The account beside it keeps its
                   menu, because picking a login *is* a real decision about the
                   session you are about to start. */
                <div className="toolbar-chips">
                  <FolderTitle path={headingFolder} />
                  <span className="toolbar-chip-sep" aria-hidden="true" />
                  <AccountChip
                    current={heading.account}
                    projectPath={headingFolder}
                    /*
                     * The agent a session started from this chip would run — the
                     * same setting `newSessionIn` sends, read the same way, so the
                     * menu cannot promise an account that the spawn then drops.
                     * Undefined when the stored value is not a provider id, which
                     * is the honest answer to "which agent" and leaves the menu
                     * saying nothing rather than explaining a reason it has not
                     * established. Spelled as a plain prop rather than a
                     * conditional spread so `wiring.test.ts` can see it: a spread
                     * is invisible to that guard, and this is exactly the seam it
                     * was written to watch.
                     */
                    provider={isProviderId(defaultProvider) ? defaultProvider : undefined}
                    /* The account *and* the agent it is a login of. The menu
                       lists accounts of every agent now, so picking a Codex one
                       and starting the default agent would hand a Codex config
                       directory to Claude — which `resolveProfileId` declines,
                       leaving the click with nothing to show for itself. */
                    onPick={(accountId, runAs) =>
                      newSession(headingFolder, false, accountId, runAs)
                    }
                    onManage={() => openSettings('profiles')}
                  />
                </div>
              ) : null
            }
            /*
             * The *pinned* state, not the visible one.
             *
             * A peeked rail floats over the bar rather than taking room from
             * it, so the traffic lights are still sitting on the chrome and it
             * still needs their 82px of clearance. Passing `!revealed` here made
             * that padding come and go with the peek, which slid the window's
             * title 66px sideways every time a pointer brushed the left edge.
             * The reveal button goes with it and is simply covered by the rail
             * while it is out — the same control, in the same place, either way.
             */
            sidebarHidden={sidebar.collapsed}
            /* With a strip above, none of that is this bar's job any more: the
               lights are up there and so is the one reveal button. */
            underStrip={hasStrip}
            // Which page is under the bar, so the heading can line up with
            // it. Null for a session, whose terminal fills the window.
            page={showingPanel ? panel : null}
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
            {/*
              The host session's own controls, on the window's own bar.

              Asad, twice: *"the model selection, all of the things that a chat
              session used to have. I mean efforts, fast mode, model selection,
              and add plugin connectors … they should be on the top bar."* They
              existed and were folded into the chat composer, which a session
              drawn as a terminal never shows — so the model could not be seen,
              let alone changed, without switching the whole pane to Chat first.

              Before the mode switch, because these are facts about the session
              and that is a fact about the window, and the window's is the one
              that must never move: it is how you get back out of a split.

              Absent in swarm, for the same reason the mode switch is: every
              terminal is drawn at once and there is no single session for a
              model to be the model of.
            */}
            {headingSession && !swarm ? (
              <SessionControls
                sessionId={headingSession.id}
                cwd={headingSession.projectPath ?? null}
                provider={headingSession.provider}
                onOpenConnectors={openConnectors}
              />
            ) : null}
            {(activeSession || splitting) && !showingPanel && !swarm ? (
              <ModeSwitch mode={mode} onChange={setMode} splitOffer={!features.on('split')} />
            ) : null}
          </WindowToolbar>
        )}

        <div className="panes">
          {/* Named for whatever the bar above is naming, which is the host
              session. The fallback catches the one case with no name at all: a
              split whose host pane is still empty, where "Split view" describes
              the arrangement rather than pretending to name a session in it. */}
          <ErrorBoundary label={heading.title ?? 'Split view'}>{mainView()}</ErrorBoundary>
        </div>
      </main>

      <SettingsWindow
        open={prefsOpen}
        initialSection={prefsSection}
        onClose={() => setPrefsOpen(false)}
        /*
         * Signing an account in means opening a session under it, because the
         * agent's login runs inside its own terminal and this app never handles
         * a credential. The settings window cannot do that on its own — the
         * session store lives here — so Accounts asks, and this closes the
         * window and starts the session the user is about to log in with.
         */
        onStartSession={({ profileId, provider }) => {
          setPrefsOpen(false)
          // The agent the account is a login of, not the default coding tool.
          // Signing a Codex account in used to open Claude — see `newSessionIn`.
          newSession(undefined, false, profileId, provider)
        }}
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
        /* The folder the press named, or the one you are in. The ＋ on a project
           heading is the only caller that names one, and before this dialog
           became the single route it did not have to — it spawned into that
           folder directly. Dropping the argument here would have turned "new
           session in terminaldeck" into "new session in whatever is on screen",
           which is a press that quietly does something else. */
        projectPath={newSessionPath ?? activeProjectPath}
        onClose={() => setNewSessionOpen(false)}
        onStart={async (request) => {
          setNewSessionOpen(false)
          const meta = await window.deck.createSession(request)
          addSession(meta)
          showTab(meta.id)
          /*
             The bar keeps it — and this is the one that answers what he asked
             for, because the strip's terminal glyph opens *this* dialog rather
             than a session (*"we just always wanted this pop-up to come up so we
             choose which type of terminal we want to open"*).

             Which means the rail's New session button, the ＋ on a project
             heading and ⌘T all land here too, and all of them keep their window
             as well. That is deliberate rather than incidental: they are the
             same act, arrived at from four places, and a session that stays on
             the bar when it was started from the header and vanishes when it was
             started from the rail would be the window disagreeing with itself
             about what a new session is. Restoring a reload's sessions and
             accepting one started on a paired phone are *not* this act, and
             neither of them promotes anything.
          */
          keepNewWindowInStrip(meta.id)
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
      {/*
        The copilot's alter-tier confirmation.

        Mounted here with the rest of the dialogs, and — unlike every one of
        them — not behind a flag this window sets. The question comes from the
        main process, so it can arrive while somebody is deep in a terminal with
        no thought of the copilot at all. That is exactly the case it exists for:
        `deck-control` will not write a setting, stop one of your sessions or
        create a routine unless this appears and somebody presses Allow.

        It is not gated on a feature either. There is no "copilot" switch in the
        feature store, and if there ever is, the gate belongs on the tools rather
        than on the dialog: a build that can be asked and cannot draw the
        question is a build where the answer is decided by a timeout.
      */}
      <CopilotConsent
        question={consent.question}
        waiting={consent.waiting}
        titles={consent.titles}
        onAnswer={consent.answer}
      />
      <AlertsWindow
        /*
         * Gated on the feature here, not only on the bell.
         *
         * The page this replaces was gated twice — the rail dropped the row and
         * `PanelView` drew the offer for anyone who was already on it when the
         * feature went off — and the sheet needs the same second half. Without
         * it, switching Alerts off in Settings while the sheet is open leaves a
         * dialog on screen for something the app no longer has. `open` is
         * resolved on render rather than repaired in an effect, for the reason
         * the settings rail gives about its own selected pane: the wrong thing
         * must not be shown for even one frame.
         */
        open={alertsOpen && features.on('alerts')}
        onClose={() => setAlertsOpen(false)}
        projectPath={activeProjectPath}
        /* The raw report and the switch, not the filtered one: the panel applies
           `withInsights` itself, and handing it a report that had already been
           filtered would leave two places deciding the same thing. */
        report={alertsFeed.report}
        busy={alertsFeed.busy}
        error={alertsFeed.error}
        available={alertsFeed.available}
        onRescan={alertsFeed.rescan}
        showInsights={showInsightAlerts}
        /*
         * Every alert's button, given somewhere to go. Each of the five kinds
         * names a target the app can already show; the panel raised them and
         * nothing listened, so pressing one re-ran the scan behind it and left
         * you exactly where you were.
         */
        onAction={(action) => {
          /*
           * The sheet closes first, whatever the action turns out to be.
           *
           * All five of them act on the window *behind* this dialog — a panel,
           * a tab, a terminal, another sheet — and a modal is precisely the
           * thing that makes those unreachable while it is up. Leaving it open
           * would have been the same defect the actions were given handlers to
           * fix: press the button, something happens somewhere you cannot see,
           * and the surface in front of you is unchanged.
           */
          setAlertsOpen(false)
          /*
           * A session-targeted alert names Claude's own conversation id, taken
           * from the transcript — not this window's tab id, which the main
           * process mints. They coincide only when the app started the session.
           * So the match is attempted, and where it fails the action lands on
           * the inspector, which reads the project's transcripts and can
           * therefore show the very session the alert is about. What it never
           * does is guess: `/compact` is a write, and a write to the wrong
           * session is worse than a button that took you somewhere slightly
           * broader.
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
      />
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
      {/*
        Every hover label in the window, in the app's own type instead of the
        OS's. It takes no props and renders nothing until something is hovered:
        being mounted *is* the wiring, which is why `wiring.test.ts` asserts the
        tag rather than any attribute of it. Last in the tree so its portal is
        appended after the dialogs' — a tooltip inside a modal has to win the
        stacking race against the sheet it is drawn on.
      */}
      <Tooltips />
    </div>
  )
}

export function App() {
  return (
    <StoreProvider>
      {/*
        Which features this install has, above everything that draws one.

        Mounted here rather than resolved where it is used, and read from
        `localStorage` during the first render, because every one of its answers
        decides whether a piece of chrome exists: a sidebar row, a segment of
        the mode switch, the ＋ menu's connectors. An answer that arrives one
        frame late is a window that rearranges itself in front of the user on
        every launch — see `features/state.ts`.
      */}
      <FeaturesProvider>
        <Workspace />
      </FeaturesProvider>
    </StoreProvider>
  )
}
