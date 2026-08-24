import { Fragment, useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { WorkspaceTabStrip } from './browser/WorkspaceTabStrip'
import type { ProviderId, SessionMeta, SessionStatus } from '@shared/types'
import { StoreProvider, useStore, type Session } from './state/store'
import { TerminalView } from './components/TerminalView'
import { MachineSessionPane } from './machines/MachineLinks'
import { hereName } from './machines/types'
import { useMachines } from './machines/useMachines'
// The account chip over a session on one of his own machines, and the two calls
// behind it. See `machines/machine-account.ts` for why the read is here rather
// than inside the control cluster beside it.
import { MachineAccountChip } from './machines/MachineAccountChip'
import { switchMachineAccount, useMachineAccount } from './machines/machine-account'
import { EmptyState } from './components/EmptyState'
import { SettingsWindow } from './settings/SettingsWindow'
import type { SectionId } from './settings/settings-schema'
import { NewSessionDialog, type StartServer } from './components/NewSessionDialog'
import { HelpDialog } from './components/HelpPanel'
import { JoinRemoteDialog } from './components/JoinRemoteDialog'
import { SessionInspector } from './components/SessionInspector'
import { AlertsWindow, withInsights } from './components/AlertsPanel'
import { useProjectAlerts } from './alerts-feed'
import { openLinkExternally } from './link'
import { sendToTerminal } from './chat/attach/mentions'
import { markSeen, readSeen, unreadCount, writeSeen, type SeenAlerts } from './alerts-unread'
import {
  canResumeProvider,
  CloseSessionConfirm,
  CONFIRM_CLOSE_KEY,
  needsCloseConfirm,
  RISKY_STATUSES,
} from './components/CloseSessionConfirm'
import { CommandPalette, type PaletteCommand } from './components/CommandPalette'
import { ShortcutsSheet } from './components/ShortcutsSheet'
import { Onboarding } from './components/Onboarding'
import { ChatView } from './components/ChatView'
import { PageEmpty } from './components/PageEmpty'
import { BRAND } from '@shared/brand'
import { setBindings } from './browser/binding-view'
import { UpdateBanner } from './updates/UpdateBanner'
import { HooksOffer } from './components/HooksOffer'
import { ModeSwitch, type SessionViewMode, type WorkspaceMode } from './shell/ModeSwitch'
import { BrowserWorkspace } from './browser/BrowserWorkspace'
import { SwarmGrid } from './layout/SwarmGrid'
import { SplitView } from './layout/SplitView'
import { SLOT_ATTR, slotStyle, usePaneSlots } from './layout/pane-slots'
import {
  closePane,
  emptyLayout,
  focusedTabId,
  moveFocus,
  primaryPane,
  tabIds,
  type PaneLayout,
} from './layout/pane-tree'
import {
  closePaneOrCollapse,
  isSplit,
  pruneClosedPanes,
  replaceTabInPanes,
  seedSplit,
  showInFocusedPane,
  splitFocused,
} from './layout/panes'
import { CopilotConsent } from './copilot/CopilotConsent'
import { CopilotSetup } from './copilot/CopilotSetup'
import { CopilotRestart } from './copilot/CopilotRestart'
import { CopilotView } from './copilot/CopilotView'
import { defaultPane } from './copilot/copilot-model'
import { useConsent } from './copilot/useConsent'
import { useCopilot } from './copilot/useCopilot'
import { useCopilotSetup } from './copilot/useCopilotSetup'
import { partitionByOrigin, startedByCopilot, turnOf } from './copilot/session-origin'
import { useHeldSessions } from './held-sessions'
import { useKnownSignIns } from './accounts'
import { switchNames, useSwitchAccount } from './session-switch'
import { SwitchAccountConfirm } from './components/SwitchAccountConfirm'
import { Sidebar } from './shell/Sidebar'
import { WindowToolbar } from './shell/WindowToolbar'
import { FolderTitle } from './shell/FolderChip'
import { AccountChip } from './shell/AccountChip'
import type { ChromeSession } from './shell/agent-presence'
import { PaneBar } from './shell/PaneBar'
import { SessionControls } from './shell/SessionControls'
// What stands in that cluster's place over a session running on one of his
// other machines, so the space it leaves is explained rather than merely empty.
// Which computer a session's controls have to be asked of. See the module's own
// note: it is the router that made the model, effort and fast-mode cluster reach
// a session on a paired machine and on a server.
import type { ControlsTarget } from './shell/controls-target'
import { endOfLocalSession, endOfMachineSession, shellGone, type SessionEnd } from './shell/session-end'
import { PanelView } from './shell/PanelView'
import { useSidebar } from './shell/useSidebar'
import { PANELS, panelSpec, type PanelId } from './shell/panels'
import { machineIsClosed, type ClosedMachine } from './shell/machine-groups'
import { registerNavigator } from './copilot/driving/navigator'
import { FeaturesProvider, useFeatures } from './features/FeaturesProvider'
import { useControlOffer } from './features/offer'
import { availableFeatures } from './features/state'
import {
  asSessionStatus,
  machineTabId,
  nextActiveId,
  readMachineTabId,
  readServerTabId,
  serverTabId,
  sessionLabel,
  tabLabel,
  type WorkspaceTab,
} from './shell/workspace-tabs'
import { ServerSessionPane } from './machines/servers/ServerSessionPane'
import { ServerChatPane } from './machines/servers/ServerChatPane'
import { serverChatWired, useServerSignIn } from './machines/servers/server-chat'
import { agentCommand, ServerAccountChip } from './machines/servers/ServerAccountChip'
import { MachineSessions } from './machines/new-session-context'
import { MachineSessionViews } from './machines/session-view-context'
import { ServerSessions } from './machines/servers/session-context'
import { asServers, resolveServersBridge } from './machines/servers/types'
import {
  newShellKey,
  renameServersIn,
  serverSessionEnded,
  serverSessionGroups,
  serverTabs,
  withoutServer,
  withoutServerSession,
  withServerSession,
  type ServerSession,
} from './machines/servers/server-sessions'
import {
  AUTO_SELECTION,
  paneForTab,
  resolveActiveTab,
  showTabSelection,
  type TabSelection,
} from './shell/tab-selection'
import {
  forgetWindowInStrip,
  keepNewWindowInStrip,
  keepWindowBesideInStrip,
  removeWindowFromStrip,
  replaceWindowInStrip,
  stripIsPresent,
} from './browser/workspace-strip'
import { sessionAnchor } from './browser/strip-arrangement'
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

/**
 * A close waiting on the user.
 *
 * Four subjects now: one session here, every session in a project, one session
 * on another machine, and every session on another machine. The last two are not
 * variants of the first two and are kept apart for the reason `CloseSubject`
 * gives — the sentence a person reads has to name the right thing, and *"the
 * machine itself stays connected"* is the one fact they actually want at that
 * moment.
 */
type PendingClose =
  | { kind: 'session'; tab: WorkspaceTab }
  | {
      kind: 'project'
      path: string
      name: string
      status: SessionStatus
      count: number
    }
  | {
      kind: 'machine-session'
      machineId: string
      sessionId: string
      name: string
      status: SessionStatus
    }
  | {
      kind: 'machine'
      machineId: string
      name: string
      status: SessionStatus
      count: number
    }
  /*
   * And the two a server adds. `name` is the *server's* name on both, not the
   * terminal's, because that is what the dialog has to identify — a row called
   * "Session 2" names nothing on its own, and the one fact a person needs at
   * this moment is which machine it is on.
   */
  | {
      kind: 'server-session'
      tabId: string
      name: string
      status: SessionStatus
    }
  | {
      kind: 'server'
      serverId: string
      name: string
      status: SessionStatus
      count: number
    }

/**
 * The three facts the session chrome needs about a session, off the store.
 *
 * `WorkspaceTab` deliberately does not carry the agent or the exit code — a tab
 * is a thing on a bar, and a browser page is one too — so the chip's questions
 * ("is there an agent in this", "has it ended") have to be answered from the
 * session list. Null for a tab that is not a session, which is exactly what
 * `AccountChip` reads as "I am being asked about a folder".
 */
function chromeSession(
  id: string | null,
  sessions: readonly Session[],
): ChromeSession | null {
  if (id === null) return null
  const found = sessions.find((session) => session.id === id)
  return found
    ? {
        id: found.id,
        provider: found.provider,
        exited: found.exitCode !== null,
      }
    : null
}

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
    replaceSession,
    removeProject,
    removeSession,
    setActiveSession,
    setSessionStatus,
    setSessionExit,
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
   * the rail, the window it opens, and the split below that keeps the copilot's
   * *own* session out of the ordinary session list.
   *
   * It starts nothing. `useCopilot` only reads; the copilot is spawned when its
   * window is opened, which is the moment somebody has said they want to talk to
   * it — an agent CLI bills for what it does, and a standing charge for opening
   * the app is not something anybody agreed to.
   */
  const copilot = useCopilot()

  /**
   * What the copilot is called, and whether anybody has ever been asked.
   *
   * One read of the copilot's own instruction file, feeding the three places its
   * name is printed — the pinned row, the tab pill and the bar — and the one
   * decision that has to be made before it starts: whether to put the setup flow
   * in front of it. `useCopilotSetup` carries why the name lives in that file
   * rather than in a setting.
   *
   * It reads and never writes, exactly like `useCopilot` above, so mounting it
   * cannot create a copilot, a folder or a file.
   */
  const copilotSetup = useCopilotSetup()
  const [copilotSetupOpen, setCopilotSetupOpen] = useState(false)

  /**
   * The fleet, and the copilot, told apart — because they are not the same list
   * even though they are the same kind of thing.
   *
   * The copilot **is** a session. That is the whole design, and it is what makes
   * the transcript viewer, chat mode, the cost pane, the alert watcher and —
   * since 2026-08-17 — the tab strip, the account chip and the model / effort /
   * fast-mode / connectors cluster work on it with no changes at all. Asad:
   * *"nothing should be less than that. And it can stay as a window pill with
   * the other windows."*
   *
   * What it is not is one of **your project's sessions**. It lives in a folder
   * of its own that is not a project you work in, it has a pinned row of its own
   * at the top of the rail, and it is not part of the fleet that the dashboard
   * counts, the swarm grid tiles, the alert scanner reads or the auto-titler
   * renames. Drawn into those it would put its home folder in the sidebar as a
   * project with itself as a row inside it, three centimetres under the pinned
   * entry that claims to be the one place it lives.
   *
   * So there are two lists, and the difference between them is exactly one
   * session:
   *
   *  - `sessions` — the fleet. Everything that is not the copilot. Every count,
   *    every scan, every grid and the rail's project runs read this.
   *  - `windowSessions` — the fleet plus the copilot. Everything that *draws a
   *    session as a window* reads this: the tab list, the heading, the control
   *    cluster, the terminals, the panes.
   *
   * The split is **by id, and only by id.**
   *
   * ## It used to be by folder as well, and that was the bug
   *
   * Asad, 2026-08-17: *"If I am opening same as copilot folder, it is taking me
   * directly to the commander. It should be able to open another option of the
   * separate session also in the same folder. But in that case it will not call
   * itself as commander — it will just be a normal another session."*
   *
   * He is exactly right about what it should do, and the folder clause is what
   * stopped it. Reproduced in the harness: start a session whose cwd is the
   * copilot's own folder and it is filtered out of `sessions` altogether — no
   * row in the rail, no tab in the strip, nothing on screen. `showTab` then
   * names an id that resolves to no tab, `resolveActiveTab` falls back to
   * `tabs[0]`, and what you are looking at is whatever else was open. With the
   * copilot the only other window, that is the copilot: *"it is taking me
   * directly to the commander."*
   *
   * The identity layer already makes the distinction he is asking for — only the
   * copilot's own session is launched with `--append-system-prompt-file`, so a
   * plain session started in that folder is a plain session and knows nothing
   * about being an assistant. The routing was the only thing insisting otherwise.
   *
   * ## What the folder clause was for, and what replaces it
   *
   * Two things, and each gets its own answer rather than one clause doing both
   * badly:
   *
   *  - **A copilot session that has exited but is still in the list.** Nothing
   *    removes a session from the store when its process ends — it stays with
   *    `status: 'exited'` — while `copilot:state` drops its `sessionId` the
   *    moment it goes. So the id alone is not enough at that instant, and
   *    {@link copilotIds} below is: every id this window has *ever* seen
   *    `copilot:state` name is remembered, so an ended copilot stays recognised
   *    as the copilot instead of reappearing as somebody's session.
   *  - **The project heading its cwd would create.** That is `projects` below,
   *    which still hides the folder — but now only while it is nothing but the
   *    copilot's home. Open a session of your own in there and the heading
   *    appears, because at that point it genuinely is a folder you are working in
   *    and its sessions need somewhere to be listed.
   *
   * Until `copilot:state` answers, nothing is filtered and the row is briefly
   * visible. That is the honest trade: the alternative is holding the whole
   * session list back on an IPC round trip, which would delay every session a
   * person cares about in order to hide one they do not.
   */
  const copilotSessionId = copilot.state?.sessionId ?? null
  const copilotRoot = copilot.state?.paths?.root ?? null
  /**
   * Every session id that has been the copilot's, in this window's lifetime.
   *
   * A ref rather than state because nothing is drawn *from* it — it only ever
   * subtracts a row that would otherwise be drawn — and because it must not
   * cause a render of its own: it is written during render, from the value the
   * same render is filtering with, so the answer it gives can never be one frame
   * behind the list it is being applied to.
   *
   * It grows by at most one entry per copilot restart and is thrown away with
   * the renderer, which is also exactly the right lifetime: a session id names a
   * pty in this main process, and after a restart `session:list` returns only
   * live ptys, so an ended copilot is not in the list for anyone to mistake.
   */
  const copilotIds = useRef<Set<string>>(new Set())
  if (copilotSessionId !== null) copilotIds.current.add(copilotSessionId)
  const sessions = useMemo(
    () => storedSessions.filter((session) => !copilotIds.current.has(session.id)),
    // `copilotSessionId` is a dependency even though the filter does not read
    // it: it is what the set is grown from, and without it the list would not be
    // recomputed on the render where the copilot's own id first arrives.
    [storedSessions, copilotSessionId],
  )
  /**
   * The copilot's own `SessionMeta`, when it is running and this window has seen
   * it arrive.
   *
   * Both halves are needed and neither is enough. `copilot:state` knows the id
   * of the pty; the store knows the account it was spawned under, its title, its
   * status and its provider — the facts the bar, the chip and the control
   * cluster are made of. Null while the copilot is stopped, and null for the
   * moment between `ensureCopilot` returning and `session:created` landing here,
   * which is what `copilotPending` below covers.
   */
  const copilotSession = useMemo(
    () =>
      copilotSessionId === null
        ? null
        : storedSessions.find((session) => session.id === copilotSessionId) ?? null,
    [storedSessions, copilotSessionId],
  )
  /** The fleet plus the copilot. See the note above for which list is which. */
  const windowSessions = useMemo(
    () => (copilotSession ? [...sessions, copilotSession] : sessions),
    [sessions, copilotSession],
  )
  /**
   * The projects in the rail — the copilot's home among them only once it is
   * also somewhere you are working.
   *
   * The copilot's cwd is a real folder with real files in it, and it is not a
   * project: listing it unasked would put the assistant's memory directory in
   * the rail with the assistant itself as a row inside it, three centimetres
   * under the pinned entry that claims to be the one place it lives.
   *
   * But *"it should be able to open another option of the separate session also
   * in the same folder"* — and a session with no heading to sit under is a
   * session in the rail's orphan bucket, which is where sessions go when their
   * project has been closed out from under them. That is not what happened here.
   * So the heading appears exactly when there is one of his own sessions in
   * there to need it, and disappears again when the last one closes.
   */
  const projects = useMemo(
    () =>
      storedProjects.filter(
        (project) =>
          project.path !== copilotRoot ||
          sessions.some((session) => session.projectPath === copilotRoot),
      ),
    [storedProjects, copilotRoot, sessions],
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

  /**
   * The sessions that were open, did not come back, and are being kept.
   *
   * Subscribed here rather than inside the rail for the same reason
   * `UpdateBanner` is mounted here: this is where the window's bridge
   * subscriptions live and where `wiring.test.ts` can see them. The rail draws
   * rows from a prop and knows nothing about IPC, which is what lets it be
   * rendered in a test and in `.harness/` without one.
   *
   * Unconditional, and not behind a feature. A held row is the app reporting
   * that it failed to do something a person asked for, and a report that can be
   * switched off is a report that will be off on the machine where it mattered.
   */
  const held = useHeldSessions()
  /**
   * Running the session you already have as a different account.
   *
   * Asad, 2026-08-17: *"when I change account from the dropdown it starts a new
   * session with that account, instead of changing it in the same session."* The
   * account chip's menu now asks for a switch rather than a second session, and
   * this is the state behind that ask: which switch is being considered, what it
   * would do, and what went wrong if it did.
   *
   * It lives up here beside the other bridge-backed state, and not in the chip,
   * for two reasons. The chip is mounted once per pane and once in the toolbar,
   * so a sheet owned by it could be opened by whichever copy happened to be
   * clicked — and the thing that has to happen on success is a change to the
   * *window*: the tab, the pane and the strip position all move from one session
   * id to another, and none of those are the chip's to touch.
   */
  const switcher = useSwitchAccount()
  /**
   * Sessions with an account switch waiting for the next message, by the name
   * of the account they are waiting to become.
   *
   * Window state rather than a read of the main process's register, because the
   * only thing drawn from it is a hint on a chip and the register is authoritative
   * about a thing that has already been agreed. It is written when the main
   * process confirms the arming, and cleared by both of the events that end one —
   * so it can go stale only by this window being closed, which takes the chip
   * with it.
   */
  const [armedSwitches, setArmedSwitches] = useState<Record<string, string>>({})
  /**
   * The addresses the account menu has already read, for the sheet's title.
   *
   * A store read and nothing more — no probe. `finish.test.ts` enumerates which
   * surfaces are allowed to *ask*, because asking spawns the agent's CLI once per
   * account; the chip's menu has already paid that cost by the time this sheet
   * can exist, since opening the menu is the only way to reach it.
   */
  const knownSignIns = useKnownSignIns()
  const [extraTabs, setExtraTabs] = useState<WorkspaceTab[]>([])
  /** Makes a page's id unique when two are opened in the same millisecond. */
  const tabSeq = useRef(0)
  /**
   * What the window is showing — and, since 2026-08-17, whether it is showing
   * anything on purpose.
   *
   * This was `string | null`, and the `null` was carrying two different answers:
   * "nobody has chosen yet", which is a launch and should show the first session
   * you have open, and "the person just took the last tab off the bar", which
   * should leave an empty pane. Resolving both to `tabs[0]` is why the last tab
   * in the strip could not be closed — it came straight back as a transient tab,
   * because `shownTabs` always draws whatever is active. `shell/tab-selection.ts`
   * carries the full account and owns the resolution.
   */
  const [selection, setSelection] = useState<TabSelection>(AUTO_SELECTION)
  /**
   * The copilot's window has been asked for and its session has not arrived yet.
   *
   * Spawning it is a `sandbox-exec` proof and a CLI launch — seconds, not
   * frames — and its tab is derived from the running session, so without this
   * the pinned row would be a button that did nothing visible for that whole
   * time. While it is set, the window draws the copilot's own starting state,
   * and the effect below hands it over to a real tab the moment there is one.
   */
  const [copilotPending, setCopilotPending] = useState(false)
  /**
   * The action-log row the copilot's window should open on, when something
   * asked "why does this session exist".
   *
   * The same mechanism `panelFocus` is for the views, kept separate for the same
   * reason it is separate from the panel itself: a plain open must not land you
   * where a link once sent you.
   */
  const [copilotTurn, setCopilotTurn] = useState<string | null>(null)
  /**
   * The machine the copilot page has been switched to, or null for this one.
   *
   * ## Why the bar needs it, said as the defect it was
   *
   * `CopilotView` has had a machine switch at the top since 2026-08-20 and the
   * window's bar knew nothing about it. So with a paired PC chosen, the bar over
   * that PC's conversation still drew **this** Mac's copilot: its account chip,
   * its model and effort, and a Restart wired to `useCopilot`. Restart there is
   * not a mislabelled button — it is a button that ends a conversation on a
   * computer that is not on screen, which is the one class of defect this bar
   * has spent the week removing. *"A control that looks right and acts on the
   * wrong computer."*
   *
   * ## Why the answer is to withdraw them rather than to re-point them
   *
   * Because there is nothing on the wire to re-point them at. `copilot.chat`
   * carries parsed turns and a state report and nothing else — no account, no
   * model, no effort, and no restart verb — which is the same reason a session
   * on a paired machine gets no account chip and no control cluster, decided one
   * ternary down and stated there. So the copilot page follows the rule the rest
   * of the bar already follows for another machine: the facts it cannot have are
   * absent, and *silently* absent, because a missing control is not something a
   * toolbar explains.
   *
   * The machine's **name** is the one thing that is added, in the subtitle slot
   * a remote session's machine already uses, because which computer is on screen
   * is the fact that must never go missing.
   */
  const [copilotMachine, setCopilotMachine] = useState<{ id: string; name: string } | null>(null)
  /*
   * Stable, and it compares before it writes.
   *
   * `CopilotView` reports on mount and on every change; an inline arrow here
   * would be a new function each render, and storing a fresh object for an
   * unchanged machine would re-render the whole window for nothing.
   */
  const onCopilotMachine = useCallback((machine: { id: string; name: string } | null) => {
    setCopilotMachine((current) => {
      if (current === null && machine === null) return current
      if (current !== null && machine !== null && current.id === machine.id && current.name === machine.name) {
        return current
      }
      return machine
    })
  }, [])
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
  /*
   * The layout, readable from a callback that must not be rebuilt when it
   * changes. `selectTab` is handed to the rail, the strip, the palette and the
   * keyboard dispatcher, and it has to know whether the window is split — but
   * listing `panes` would hand all four a new function on every drag of a
   * divider.
   */
  const panesRef = useRef<PaneLayout>(panes)
  panesRef.current = panes
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
   * The machines this window can reach, read here rather than in Settings.
   *
   * The rail lists them and the New Session dialog offers them, and neither can
   * read a settings panel's state — which is why this moved up here. See
   * `useMachines`, and his instruction behind it: *"Remote sessions belong in
   * the sidebar, alongside local ones."*
   */
  const machines = useMachines()
  /**
   * The remote session on screen, or null when a local one is.
   *
   * Deliberately *not* a `WorkspaceTab`. A remote session is not this window's
   * to keep: it lives on the far machine, it outlives this app being closed, and
   * a tab strip entry for it would promise a ✕ that ends something this window
   * does not own. Opening one covers the pane the way a sidebar view does, and
   * selecting any local tab puts it away — see `selectTab`.
   */
  const [openMachineSession, setOpenMachineSession] = useState<
    { machineId: string; sessionId: string } | null
  >(null)
  /**
   * Every remote session this window has opened, whether or not it is in front.
   *
   * ## Why this list exists, in his words
   *
   *   > *"If I go to other page and come back, it will start from beginning
   *   > again… If I come to this one, it will again start from the beginning."*
   *
   * `mainView` draws one thing. So opening Files, Settings or another session
   * unmounted the remote pane, which detached from the far machine and disposed
   * its terminal — and coming back attached again, which is a round trip to
   * another computer and up to two megabytes of replay, every visit. The screen
   * no longer *scrolls* through that replay (`terminal-backfill.ts`), but a
   * terminal that has to be rebuilt from another machine is still a terminal
   * that reloads, and reloading is what he is describing.
   *
   * So the panes are mounted beside the pane and hidden, exactly as the shells
   * open on servers are and as the local terminals are one level down. Coming
   * back to one is then the same event as coming back to a local session:
   * nothing happens, because it never went away.
   *
   * It is *these* rather than `machineTabs` — which is every session on every
   * paired machine — because attaching to a session nobody has opened would put
   * a machine's whole afternoon on this window's wire for nothing.
   */
  const [machineSessionPanes, setMachineSessionPanes] = useState<
    readonly { machineId: string; sessionId: string }[]
  >([])
  /**
   * The way to a server, and nothing else read from one.
   *
   * `resolveServersBridge` is pure — it looks at what the preload actually
   * carries and answers the object or null — so asking for it here costs no IPC
   * and dials nothing. That matters: this window holds the shells people open on
   * servers, and it must not become a second thing that reads the servers list
   * on every launch. The list belongs to the Machines panel, which reads it once
   * when somebody opens it.
   */
  const serversBridge = useMemo(() => resolveServersBridge(), [])
  /**
   * The stored servers, for the New session dialog's *Where* list.
   *
   * ## Read on the press, not on a timer and not at launch
   *
   * Reading the list dials nothing — a row is a name, an address and a username
   * — but it is still a round trip through the main process, and the standing
   * rule is *events, not polling*. Opening the dialog is the event. That also
   * settles staleness without a subscription: a server added, renamed or
   * forgotten on the Machines panel is picked up the next time this dialog
   * opens, which is before anybody could pick it here.
   *
   * Empty is the ordinary case — most people have no servers — and it draws no
   * server rows at all, which leaves the dialog exactly as it was.
   */
  const [startServers, setStartServers] = useState<readonly StartServer[]>([])
  /**
   * The shells this window has open on servers.
   *
   * Held here rather than inside the Machines panel, and that placement is the
   * whole of what makes a server session a session. A panel's state stops
   * existing when the panel closes; that is exactly what used to happen to a
   * terminal on a server, and it is why one had no row in the rail, no pill, no
   * ⌘W and nothing you could drag to the top while a session on a paired laptop
   * had all four. Asad, for the third night running about machines that are not
   * this one: *"the shape of the application should not be changing for local
   * and remote devices. It should act like that same."*
   *
   * `machines/servers/server-sessions.ts` holds every rule about this list and
   * has no React in it, so what a row is called and what closing one takes with
   * it can be pinned without a window.
   */
  const [serverSessions, setServerSessions] = useState<readonly ServerSession[]>([])
  /**
   * Which of those is on screen, by tab id, or null when something else is.
   *
   * One id rather than the pair `openMachineSession` carries, because the pair
   * has to be re-joined into a tab id at four call sites and this one is read as
   * an id at all of them. `readServerTabId` takes it back apart where the two
   * halves are actually needed.
   */
  const [openServerSession, setOpenServerSession] = useState<string | null>(null)
  /**
   * Machines whose group has been closed, and is therefore not drawn.
   *
   * ## What Close means, in his words
   *
   * He reasons it out in the recording and lands somewhere exact: *"Close you
   * will not give — but you can actually give, because it should not disconnect
   * the remote account. It will just close all of the sessions from that PC.
   * Yeah, you can give this close too, so it will go from here, but whenever you
   * want to start, you can start as a new session and you can start from that
   * device."*
   *
   * Three separate things, and this state is only the second: the sessions end
   * (the `close` frames), **the group goes from the rail** (this), and the
   * pairing survives untouched (nothing here goes near `forgetMachine`).
   *
   * ## Why hiding is not the same as having no sessions
   *
   * A connected machine with nothing running on it is a real and ordinary state
   * and the rail says so — "Nothing running there." — so if Close only ended the
   * sessions, the group would stay on screen looking exactly as it did before,
   * minus its rows. That is a press that appears not to have worked. It goes,
   * and it comes back the moment there is something on it again, which is what
   * *"whenever you want to start, you can start as a new session"* asks for:
   * starting one from the New Session dialog puts a session on that machine, the
   * effect below sees it, and the group is there with it.
   *
   * ## Why each entry remembers *which* sessions were closed
   *
   * The first spelling of this was a list of machine ids and it did not work,
   * and the way it failed is worth keeping because it is not obvious from
   * reading it. Hiding a group and then un-hiding it "once something is running
   * there again" is a race with the round trip: at the instant Close is pressed
   * the sessions are still listed — they end on the other computer, a frame or
   * two later — so the rule un-hid the group in the same render that hid it and
   * the press appeared to do nothing at all. Found by driving it, not by reading
   * it; the code is correct on the page and wrong on the screen.
   *
   * So an entry carries the ids that were running when Close was pressed, and
   * the group is hidden while **every** session on that machine is one of them.
   * The sessions draining away keeps it hidden; a session appearing that nobody
   * here closed brings it straight back, which is exactly *"whenever you want to
   * start, you can start as a new session and you can start from that device."*
   *
   * Not persisted, deliberately. A closed group is a view state — the same
   * category as a folded project — and a machine that stayed hidden across a
   * relaunch would be a machine somebody had to remember they had hidden.
   */
  const [closedMachines, setClosedMachines] = useState<readonly ClosedMachine[]>([])
  /** Which machine the New Session dialog opens on. Null is this one. */
  const [newSessionMachine, setNewSessionMachine] = useState<string | null>(null)
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
   * Whether "continue the last session" can actually continue anything.
   *
   * The two surfaces that offer it — the palette row and the ＋'s sibling on a
   * project heading — spawn through `newSessionIn(path, true)`, and
   * `host-core.ts` resolves that as
   * `input.resume && resumeArgs.length > 0 ? resumeArgs : args`. So on an agent
   * with no resume command the request quietly becomes a *fresh* session and
   * nothing says so. Claude has `--continue` and Codex has `resume --last`;
   * Gemini deliberately has neither (see `agent-catalog.ts`, which explains that
   * its flag errors on an empty history) and a shell has no such idea at all.
   *
   * Asked of the default agent because that is the one those two presses would
   * start — neither of them asks which agent to run, which is precisely what
   * makes them the named-command exception to *"everywhere it should be
   * consistent and it should be asking same things to me"*.
   */
  const canResumeDefault = canResumeProvider(
    isProviderId(defaultProvider) ? defaultProvider : undefined,
  )

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

  /**
   * One session, as a window.
   *
   * Extracted so the copilot goes through it too. It is a session, so every
   * fact a tab carries about a session is true of it — the status dot, the
   * account it runs as, the folder it was spawned in — and a second spelling of
   * this object for the copilot would be the place those started to differ.
   */
  const windowTab = (session: Session): WorkspaceTab => ({
    id: session.id,
    kind: 'session' as const,
    label: session.title,
    status: session.status,
    projectPath: session.projectPath,
    // What this tab is called, in a name that outlives its own pty, so the
    // arrangement of the strip can be put back after a restart. Read off the
    // session rather than derived from it: the main process mints it when it
    // writes the session down, which is the only place a *tab* can be told
    // apart from an identical one beside it. Absent means this session is not
    // one a launch brings back, and therefore not part of the arrangement. See
    // `browser/strip-arrangement.ts`.
    anchor: sessionAnchor(session),
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
  })

  /** Sessions first, then anything else the user opened, in one list. */
  const tabs: WorkspaceTab[] = [
    ...sessions.map(windowTab),
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
    /*
     * And the copilot, which is a window like the rest of them.
     *
     * Asad, 2026-08-17: *"it can stay as a window pill with the other windows."*
     * So it is here, with `isCopilot` on it — the flag that the handful of
     * genuinely different behaviours hang off, and nothing else. Everything that
     * asks `kind === 'session'` gets a yes: the strip draws its status dot, the
     * bar carries its name and account and control cluster, the mode switch
     * offers it Terminal, Chat and Split, and a pane can hold it.
     *
     * **Last**, deliberately. `tabs[0]` is what a window with no selection falls
     * back to, ⌘1–9 counts from the front, and ⌘⇧[ / ⌘⇧] walk this order — so
     * putting the copilot at the head would quietly make it the thing every
     * launch opened on and the thing ⌘1 meant. It is opened from its own pinned
     * row, which is one press at the very top of the rail.
     *
     * Present only while it is running, because the tab *is* the session: stop
     * the copilot and its window goes, the same way any session's window goes
     * when its process ends. The pinned row starts it again.
     */
    /*
     * `label` is overwritten with the copilot's own name, and that is the one
     * field of `windowTab`'s that is wrong for this tab: a session's label is its
     * title, and the copilot's title is its *folder's* name — which
     * `sessionLabel` would then turn into "Session 4" beside a rail row saying
     * Nova. The name is user data read out of its instruction file, so it
     * arrives here rather than being reached for by `tabLabel`, which has no way
     * to ask.
     */
    ...(copilotSession
      ? [
          {
            ...windowTab(copilotSession),
            label: copilotSetup.name,
            isCopilot: true as const,
          },
        ]
      : []),
  ]

  /**
   * The sessions running on other machines, as tabs.
   *
   * ## Why they are tabs at all now
   *
   * They were not, for one night. A remote session covered the pane the way a
   * sidebar view does and had no pill in the strip, on the argument that a ✕ on
   * that pill would promise to end something this window does not own. Asad
   * looked at that and asked for the opposite, directly: *"When I click on any
   * session — the shape of the icon, top bar header is not same, and I cannot
   * drag it up there… So it should be there on the top, just like the normal
   * internal local session."* So the decision is reversed, and the ✕ is answered
   * by the `close` verb on the wire rather than by leaving the pill out.
   *
   * ## Why they are a second list rather than part of `tabs`
   *
   * `tabs` is *this window's* windows, and half a dozen things downstream treat
   * it as exactly that: `closeTabNow` reaches for `window.deck.killSession`,
   * `resolveActiveTab` falls back to `tabs[0]` at launch, the swarm mounts a
   * terminal per entry, and the panes model holds ids it expects to be able to
   * draw. Folding a session that lives on another computer into that array would
   * have meant qualifying every one of those with "unless it is remote" — a
   * shape of bug per site rather than a decision in one place, which is the
   * argument `WorkspaceTab.isCopilot` already makes about a third `TabKind`.
   *
   * So they are built here, joined to `tabs` for exactly the two surfaces that
   * are meant to list *everything you have open* — the strip and the rail — and
   * routed by id everywhere else. `machineTabId` is the one function that knows
   * how the two handles join, and `readMachineTabId` is how a click comes back.
   *
   * ## `closable` is the far machine's answer, not a decoration
   *
   * It is the `close` capability off the link. A machine paired to an older
   * build never advertises it, and a tab that carried `closable: true` there
   * would draw a ✕ that sends a frame into silence. False means the pill has no
   * ✕ at all — absent rather than drawn and inert, which is the rule this whole
   * pass is being held to.
   */
  const machineTabs: WorkspaceTab[] = machines.machines
    .filter((row) => !machineIsClosed(closedMachines, row.machine.id, row.link?.sessions ?? []))
    .flatMap((row) =>
      (row.link?.sessions ?? []).map((session): WorkspaceTab => ({
        id: machineTabId(row.machine.id, session.id),
        kind: 'session',
        label: session.title,
        status: asSessionStatus(session.status),
        // The far machine's folder, carried so the tooltip and the qualifier can
        // say which of two identically-named sessions this is. Nothing that
        // *opens* a path reads it — see the `heading` further down, which hands
        // `FolderChip` a null for exactly this reason: this path exists on a
        // different computer, and a chip that opened nothing would be the dead
        // control this pass is removing.
        ...(session.cwd ? { projectPath: session.cwd } : {}),
        machine: { id: row.machine.id, name: row.machine.name },
        closable: row.link?.capabilities.includes('close') === true,
      })),
    )

  /**
   * What every linked machine says it is running, as one string.
   *
   * A dependency, not a value anything reads. The two effects below have to run
   * when the *set* of live sessions changes and not on every render — and
   * `machines.machines` is a fresh array each time the link state is pushed, so
   * listing it would be the same thing as listing nothing.
   */
  const linkedMachineSessions = machines.machines
    .map((row) => (row.link ? `${row.machine.id}:${row.link.sessions.map((s) => s.id).join(',')}` : ''))
    .join('|')

  /** The rows themselves, for the pruning effect. See the string above. */
  const machinesRef = useRef(machines.machines)
  machinesRef.current = machines.machines

  /*
   * The machine channels, read out once.
   *
   * A property on a mutable object does not stay narrowed inside a callback, and
   * the panes at the bottom of this component are built in one — so the guard
   * and the value have to be the same binding or the pane is handed a `null`
   * bridge that TypeScript cannot rule out.
   */
  const machinesBridge = machines.bridge

  // Opening one is what puts a pane on the list. It stays there afterwards,
  // which is the whole point — see `machineSessionPanes`.
  useEffect(() => {
    if (openMachineSession === null) return
    const { machineId, sessionId } = openMachineSession
    setMachineSessionPanes((open) =>
      open.some((pane) => pane.machineId === machineId && pane.sessionId === sessionId)
        ? open
        : [...open, { machineId, sessionId }],
    )
  }, [openMachineSession])

  /*
   * And so is putting one in a pane of a split.
   *
   * `openMachineSession` is the *unsplit* window's answer and is deliberately
   * cleared on the way into a split — see `splitPanes` — so without this a
   * remote session dropped into a pane would have a bar, a hole and nothing to
   * fill it. Read off the layout for the same reason the effect above is read
   * off the window: whichever surface says a session is on screen is the one
   * that has to mount it.
   *
   * Additive only, like the one above. A pane retargeted to something else does
   * not take the terminal down: the whole point of this list is that it survives
   * the session being switched away from, and the prune below is what removes an
   * entry, on the far machine's own word.
   */
  const paneMachineIds = isSplit(panes) ? tabIds(panes).join('|') : ''
  useEffect(() => {
    if (paneMachineIds === '') return
    const wanted = paneMachineIds
      .split('|')
      .map((id) => readMachineTabId(id))
      .filter((entry): entry is { machineId: string; sessionId: string } => entry !== null)
    if (wanted.length === 0) return
    setMachineSessionPanes((open) => {
      const missing = wanted.filter(
        (want) =>
          !open.some((pane) => pane.machineId === want.machineId && pane.sessionId === want.sessionId),
      )
      return missing.length === 0 ? open : [...open, ...missing]
    })
  }, [paneMachineIds])

  /*
   * And a session that has ended over there takes its pane with it.
   *
   * Read through a ref rather than depended on, so this runs when the far
   * machine's list actually changes rather than on every render.
   *
   * A machine with **no link right now keeps its panes**, and that is the
   * load-bearing half: a link drops and reconnects on its own, and a pane thrown
   * away during those seconds is exactly the reload this list exists to remove.
   * Only a machine that is connected and says the session is gone is believed.
   */
  useEffect(() => {
    setMachineSessionPanes((open) => {
      const kept = open.filter((pane) => {
        const row = machinesRef.current.find((entry) => entry.machine.id === pane.machineId)
        if (!row?.link) return true
        return row.link.sessions.some((session) => session.id === pane.sessionId)
      })
      return kept.length === open.length ? open : kept
    })
  }, [linkedMachineSessions])

  /**
   * The far end's id for each open server shell, by tab id.
   *
   * ## Why the window has to hold this at all
   *
   * Because the bar over a server terminal now carries the same model, effort
   * and fast-mode cluster every other session gets — *"I don't see it in server
   * sessions and in the remote sessions both"* — and that cluster addresses a
   * server shell by the id the main process holds its SSH channel under. That id
   * is minted on the far side of `servers:shell:open`, which only `ServerTerminal`
   * calls, so until it was reported upwards it lived and died inside that
   * component's effect.
   *
   * It is deliberately *not* `ServerSession.shellKey`. The key is this window's
   * handle, minted before anything is opened so a tab can exist while the shell
   * is still being asked for; this is the handle the channel actually has. Two
   * ids for one shell is not a design anybody would choose, but the alternative
   * — waiting for the far end before drawing a tab — is a tab that appears a
   * second after the click that made it.
   *
   * Absent while a shell is opening, which is the honest state: there is nothing
   * to read a screen off yet, and the cluster simply has no session id until
   * there is.
   */
  const [serverShellIds, setServerShellIds] = useState<Record<string, string>>({})

  const serverShellOpened = useCallback((tabId: string, shellId: string) => {
    setServerShellIds((current) => (current[tabId] === shellId ? current : { ...current, [tabId]: shellId }))
  }, [])

  /**
   * The shells open on servers, as tabs.
   *
   * A third list for the same reason `machineTabs` is a second one: `tabs` is
   * *this window's* windows and half a dozen things downstream treat it as
   * exactly that — `closeTabNow` reaches for `window.deck.killSession`,
   * `resolveActiveTab` falls back to `tabs[0]` at launch, the swarm mounts a
   * terminal per entry. Folding a shell that runs on somebody's server into that
   * array would mean qualifying every one of those with "unless it is a server",
   * which is a shape of bug per site rather than a decision in one place.
   *
   * Built by `serverTabs` rather than here so that what a server tab *is* can be
   * asserted without a window around it.
   */
  const serverSessionTabs: WorkspaceTab[] = serverTabs(serverSessions, serverShellIds)

  /**
   * The set of open server shells, as one string.
   *
   * A dependency, not a value anything reads — the same device
   * `linkedMachineSessions` is, for the same reason: `serverSessions` is a fresh
   * array whenever anything about a shell changes, so an effect that listed it
   * would run on every status tick rather than when a shell appears or goes.
   */
  const serverSessionKey = serverSessions.map((entry) => entry.tabId).join('|')

  /**
   * Everything the strip and the rail list — this window's, the machines' and
   * the servers'.
   *
   * One array for the two surfaces whose whole job is to answer *what do I have
   * open*, and it is the same array for both so they cannot disagree about it.
   * The promoted order the strip persists is keyed by tab id, so a remote
   * session pinned to the top stays pinned across a renderer reload exactly as a
   * local one does.
   */
  const openTabs: WorkspaceTab[] = [...tabs, ...machineTabs, ...serverSessionTabs]

  /**
   * What a pane is allowed to go on naming — everything open, plus the remote
   * sessions this window has a pane for and cannot currently ask about.
   *
   * `pruneClosedPanes` closes a pane whose window is not in the list it is
   * handed, so the list has to be the *authority* on what exists. It used to be
   * `tabs`, which is this window's own sessions and pages, and that was correct
   * while a pane could hold nothing else. Now that a pane can hold a session on
   * a paired machine or a terminal on a server, handing it `tabs` would close
   * those panes on the very next render — the same class of bug that made a
   * browser page impossible to put in a pane, one argument narrower than the
   * thing it decides.
   *
   * The second half is the one that is easy to get wrong. `machineTabs` is built
   * from each machine's *live* roster, so a link that drops for three seconds
   * empties it — and pruning on that would tear a hand-made layout apart every
   * time the relay reconnected. `machineSessionPanes` keeps its entries through
   * a dropped link on exactly that argument, so the panes for a machine that is
   * not answering are kept here too. A machine that *is* answering and says the
   * session is gone is believed, because then its tab is genuinely absent from
   * `machineTabs` while the machine is in the list.
   */
  const panePruneList: readonly { id: string }[] = [
    ...openTabs,
    ...machineSessionPanes
      .filter((pane) => {
        const row = machines.machines.find((entry) => entry.machine.id === pane.machineId)
        return !row?.link
      })
      .map((pane) => ({ id: machineTabId(pane.machineId, pane.sessionId) })),
  ]

  /**
   * Forget a machine was ever closed, once work nobody here closed is on it.
   *
   * {@link machineIsClosed} already answers the question during a render, so
   * this does not decide anything the screen depends on — it keeps the entry
   * from outliving its meaning. Without it, a machine that had been closed, then
   * started fresh on, would go back into hiding the moment that fresh session
   * ended: the entry would still be there and the *new* ids would be gone with
   * it, so `every` would be satisfied again by an empty list and the group would
   * vanish for a reason nobody could see.
   *
   * A machine that is not in the list at all is **kept** rather than pruned. It
   * is offline or forgotten, so it is not drawn either way, and dropping the
   * entry would mean a machine that reconnects with the same sessions still
   * running — a close that never landed — came back un-hidden with work on it
   * that this window believes it ended. `closeMachineNow` handles the refusal it
   * can see; this is the case it cannot.
   */
  useEffect(() => {
    setClosedMachines((current) => {
      const next = current.filter((entry) => {
        const row = machines.machines.find((one) => one.machine.id === entry.id)
        return row === undefined || machineIsClosed(current, entry.id, row.link?.sessions ?? [])
      })
      return next.length === current.length ? current : next
    })
  }, [machines.machines])

  const activeTab = resolveActiveTab(selection, tabs)
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
    // The copilot is called whatever it was named, in the bar, in the strip and
    // in the rail. Without this it would be numbered like the session it is —
    // and its title is its own folder's name, which is precisely what
    // `sessionLabel` turns into "Session N". The name is user data read out of
    // its instruction file and put on the tab where the tab is built, above;
    // `tabLabel` in `workspace-tabs.ts` reads it from the same place, so the two
    // are the same rule stated where each is read.
    if (tab.isCopilot) return tab.label
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
   * group is the list, and the copilot's own window carries this so a person
   * standing in front of the thing that started them can open each one. Named
   * through `labelOf` rather than off `tab.label` so the window and the row say
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
   * The same, plus the copilot, for the callbacks that are about *windows*.
   *
   * The two lists are told apart at the top of this component, and the rule for
   * picking one is there: anything that draws or focuses a session as a window
   * reads this, and anything about the project's fleet reads `sessionsRef`. The
   * three callers below — the tab that is shown instead, the pane that takes
   * focus, the pane that survives a close — are all "which session is on screen
   * now", and a copilot missing from that answer is a window whose terminal is
   * drawn and whose store never learns it is the active one.
   */
  const windowSessionsRef = useRef(windowSessions)
  windowSessionsRef.current = windowSessions
  /*
   * The sessions on other machines, for the three closes that act on them.
   *
   * A ref for the same reason the two above are refs: `machineTabs` is rebuilt
   * on every push from `machines:state`, which on a live link is often, and a
   * callback that listed it as a dependency would be a new function on every one
   * of those pushes — re-registering whatever holds it, for a list it only reads
   * at the moment somebody presses something.
   */
  const machineTabsRef = useRef(machineTabs)
  machineTabsRef.current = machineTabs
  /*
   * And the shells open on servers, for the three closes that act on those.
   *
   * A ref for the same reason: the list is rebuilt whenever anything anywhere in
   * this window opens or closes, and a callback that depended on it would be a
   * new function each time — handed to the rail, the strip and the keyboard
   * dispatcher — for a list it only reads at the instant somebody presses
   * something.
   */
  const serverSessionsRef = useRef(serverSessions)
  serverSessionsRef.current = serverSessions
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
  /*
   * And the same list widened to every computer, for the two callers that must
   * not be narrower than the pane model: the Split command, which seeds a pane
   * from whatever you are looking at, and the prune, which decides what a pane
   * may keep naming. See `panePruneList`.
   */
  const openTabsRef = useRef(openTabs)
  openTabsRef.current = openTabs
  const panePruneRef = useRef(panePruneList)
  panePruneRef.current = panePruneList
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

  /**
   * The project the window is *working in* — which is deliberately not the
   * copilot's folder, even while the copilot's window is the one in front.
   *
   * This one answer drives ⌘T's folder, the alert scanner, the dashboard, the
   * file tree and Source control. The copilot's cwd is a real folder with real
   * files in it — its `CLAUDE.md` and its `memory/`, and Settings → Copilot
   * lists them — but it is its home, not a project you work in: it is filtered
   * out of `projects` for exactly that reason. Letting it through here would
   * mean opening the copilot silently re-pointed New session at the assistant's
   * memory folder, and started scanning it for alerts.
   *
   * So the copilot's window keeps the project you were in, which is also the
   * honest answer to "which folder would a new session open in" while you are
   * talking to it about that project.
   */
  const activeProjectPath =
    (activeSession?.isCopilot ? null : activeSession?.projectPath) ??
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
   * The pane area itself, and where inside it each pane's hole is.
   *
   * A session on a paired machine and a terminal on a server are mounted beside
   * the pane tree rather than inside it — they cannot be unmounted without
   * replaying a scrollback over the relay or closing an SSH shell — so a pane
   * that holds one draws an empty body and this measures it. See
   * `layout/pane-slots.ts` for the whole argument, including why a portal is not
   * the answer.
   *
   * The signature is the arrangement, so a layout change re-measures on the
   * render that caused it rather than a frame later; the observers inside the
   * hook cover a divider being dragged and the window being resized.
   */
  const panesHostRef = useRef<HTMLDivElement>(null)
  const paneSlots = usePaneSlots(panesHostRef, splitting, splitting ? tabIds(panes).join('|') : '')

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

  /**
   * The tab whose *view* is on screen — which is not always the local one.
   *
   * `focusedId` above is the local answer: the focused pane's tab while split,
   * the selected tab otherwise. It was also the only answer, and everything
   * about how the window is *drawn* was keyed on it — `sessionView[focusedId]`,
   * `setSessionView({[focusedId]: next})`, the rail's highlight. With a session
   * on a paired machine or a terminal on a server filling the pane, that is the
   * id of a session **that is not on screen**, so pressing Terminal/Chat read
   * and wrote the mode of a different session entirely: the switch could show
   * Chat over a remote terminal because some local tab was in chat mode, and
   * pressing it turned that local tab back into a terminal while the remote
   * pane carried on unchanged. Nothing on screen moved, which is the worst
   * shape a control can have.
   *
   * So the window has one answer for "what am I looking at" and it is this one.
   * `focusedId` keeps its own meaning — the *local* session the app acts on,
   * which is what `setActiveSession`, the store's selection and every pty call
   * still need — and the two are deliberately different values rather than one
   * value with a comment.
   *
   * While the window is split, the panes already name what they hold, whichever
   * computer it is on, so the focused pane is the whole answer.
   */
  const shownTabId: string | null = splitting
    ? focusedId
    : openMachineSession !== null
      ? machineTabId(openMachineSession.machineId, openMachineSession.sessionId)
      : openServerSession !== null
        ? openServerSession
        : focusedId

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
   * **Every kind of window, not only the sessions and not only this machine's.**
   * A pane may hold a browser page, a session on a paired machine or a terminal
   * on a server, and handed a narrower list this call declares those panes dead
   * and collapses the whole hand-made layout on the render after one was opened
   * — which is exactly what happened when the globe was first wired to the
   * focused pane, and why it was backed out. `panePruneList` is the authority
   * and `layout/panes.ts` carries the long version. The deps are the lists that
   * authority is built from, as the two flattened strings rather than the arrays
   * themselves, because every one of those arrays is rebuilt on every render.
   */
  useEffect(() => {
    setPanes((current) => pruneClosedPanes(current, panePruneRef.current))
  }, [sessions, extraTabs, features, linkedMachineSessions, serverSessionKey])

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
      setSelection(showTabSelection(id))
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
      /*
       * A start can be refused, and this is where that stops being a throw.
       *
       * `session:create` rejects when the agent that was asked for cannot run —
       * it used to answer by starting a plain shell instead, and making a
       * failure look like a success is the bug this whole change is about. What
       * a rejection must not become is an unhandled promise nobody sees: the
       * main process has already held the request and pushed it to the rail,
       * where it is a row saying what did not start and offering to try again,
       * so everything below this line — remembering the folder, adding the
       * project, opening a tab — is work about a session that does not exist.
       *
       * Returned rather than rethrown for the same reason: every caller of this
       * function is a button handler, and a button handler that throws is an
       * unhandled rejection in the console and nothing on screen.
       */
      const meta = await window.deck
        .createSession({
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
        .catch(() => null)
      if (!meta) return
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
   * The switch was confirmed: put the replacement where the old session was.
   *
   * The main process has already done the hard half — started the replacement,
   * then stopped the original, in that order so a failure costs nothing — and
   * what is left is entirely about the *window*. A new process means a new
   * session id, and four things in this window are keyed by that id. Every one
   * of them has to move, and each one left behind is somebody's arrangement
   * quietly rebuilding itself because a process restarted:
   *
   *  - the **session list**, in place, keeping a name the person typed;
   *  - the **panes**, all of them, since `splitFocused` deliberately puts one
   *    session in two — and this has to happen before the next prune, which
   *    would otherwise find the old id gone and collapse the split;
   *  - the **strip**, at the same index, because that bar holds an arrangement
   *    somebody made by hand and a tab that jumps to the end is that arrangement
   *    being rearranged by something that was not a drag;
   *  - the **selection**, so the window is still showing what it was showing.
   *
   * Ordered store-first: the tab has to exist before anything points at it, and
   * `pruneClosedPanes` runs off the tab list on the very next render.
   */
  const confirmAccountSwitch = useCallback(() => {
    const asking = switcher.asking
    if (!asking) return
    void switcher.confirm().then((meta) => {
      // Null is a refusal or a failure. The sheet is holding the reason and the
      // old session is still running, so there is nothing for the window to do.
      if (!meta) return
      const previous = asking.sessionId
      replaceSession(previous, meta)
      setPanes((current) => replaceTabInPanes(current, previous, meta.id))
      replaceWindowInStrip(previous, meta.id)
      setSelection((current) =>
        current.kind === 'tab' && current.id === previous ? showTabSelection(meta.id) : current,
      )
    })
  }, [replaceSession, switcher])

  /**
   * Arm the same switch for his next message instead of making it now.
   *
   * Nothing is swapped here and nothing will be for a while: the session runs
   * on untouched until he sends something, and the replacement arrives through
   * `onSessionSwitched` below. That is the whole difference between the two
   * buttons on the sheet, and it is why this one has no `.then`.
   */
  const deferAccountSwitch = useCallback(() => {
    /*
     * The name is captured before the call, not after.
     *
     * `defer` shuts the sheet on success, which clears the plan the name comes
     * from — so reading it afterwards reads null and the chip would promise a
     * switch to nobody. It is only committed once the main process has said it
     * took the arming, because a hint drawn from a button press rather than from
     * an answer is the shape of dishonesty this feature is fenced against.
     */
    const sessionId = switcher.asking?.sessionId ?? null
    const name = switcher.plan?.to?.name ?? null
    void switcher.defer().then((armed) => {
      if (!armed || sessionId === null || name === null) return
      setArmedSwitches((current) => ({ ...current, [sessionId]: name }))
    })
  }, [switcher])

  /**
   * Put the replacement where the old session was.
   *
   * The same four moves `confirmAccountSwitch` makes, lifted out because the
   * deferred switch needs every one of them and arrives by a different route:
   * nothing in the window asked for it, so there is no promise to hang the swap
   * off — it lands as an event, inside a keystroke, and the window has to do
   * exactly what it would have done had it been the one to ask.
   */
  const adoptSwitched = useCallback(
    (previous: string, meta: SessionMeta) => {
      replaceSession(previous, meta)
      setPanes((current) => replaceTabInPanes(current, previous, meta.id))
      replaceWindowInStrip(previous, meta.id)
      setSelection((current) =>
        current.kind === 'tab' && current.id === previous ? showTabSelection(meta.id) : current,
      )
    },
    [replaceSession],
  )

  /**
   * A switch that was armed for his next message has happened.
   *
   * Subscribed for the whole life of the window rather than while a sheet is
   * open, because that is the point of the feature: the sheet was shut long
   * before this fires and he is looking at a terminal, not at a dialog. Nothing
   * is announced on success on purpose — the tab is the tab it was, the account
   * chip above it now reads the other account, and that *is* the feedback. An
   * extra banner for something he asked for and can already see would be the
   * app congratulating itself.
   */
  useEffect(() => {
    const off = window.deck.onSessionSwitched?.((previous, meta) => {
      adoptSwitched(previous, meta)
      // The promise has been kept, so it stops being drawn. Keyed by the *old*
      // id, which is the one it was armed against; the replacement is a session
      // nothing is armed on.
      setArmedSwitches(({ [previous]: _done, ...rest }) => rest)
    })
    return off
  }, [adoptSwitched])

  /**
   * And one that did not take.
   *
   * Nothing is swapped, deliberately. The main process starts the replacement
   * before it stops anything, so the session named here is still running as it
   * was — drawing the new account now would be the app showing a switch that
   * did not happen, which is the one rule this feature must not break.
   *
   * It is put back in front of him rather than logged, because he armed this
   * and then stopped thinking about it: a failure nobody is told about reads as
   * the account silently refusing to change. The sheet is the right home for it
   * — it is the surface that already knows how to say "this session is still
   * running as it was" — and reopening it also names the account that was not
   * reached, which a bare sentence could not.
   */
  useEffect(() => {
    const off = window.deck.onSessionSwitchFailed?.((sessionId, profileId, why) => {
      // `ask` first, so the sheet fills in with the two account names and the
      // tab's label; then the reason on top of it. `ask` clears `problem` as it
      // opens, which is why the order is this way round and not the other.
      switcher.ask({ sessionId, profileId })
      switcher.report(why)
      // It is not going to happen, so the chip must stop saying it will.
      setArmedSwitches(({ [sessionId]: _failed, ...rest }) => rest)
    })
    return off
  }, [switcher])

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
      /*
       * No folder anywhere, and an account was named: a sign-in.
       *
       * This fell through to the folder chooser, which is the state a new user
       * is in the first time they add an account — the button whose own steps
       * read *"Sign in, in the terminal that opens"* put a directory picker on
       * screen instead, and cancelling it did nothing whatsoever. A login runs
       * inside the account's own CLI and that CLI has to run somewhere; *where*
       * is not a question the person signing in has an opinion about, so it is
       * not asked. Home is the answer the main process gives — `project:home`.
       *
       * Optional-called and caught on both sides: a window whose preload predates
       * this channel, and a main process that answers with nothing, both land
       * back on the chooser — which is exactly what this path always did.
       */
      else if (profileId) {
        void Promise.resolve(window.deck.homeFolder?.())
          .catch(() => null)
          .then((home) =>
            home ? newSessionIn(home, resume, profileId, runAs) : openProjectAs(profileId, runAs),
          )
      }
      // No folder and no account — a first launch. The chooser is not "a dialog
      // in the way" at that point, it is the only question left.
      else void openProjectAs(profileId, runAs)
    },
    [activeProjectPath, newSessionIn, openProjectAs],
  )

  /**
   * Every route to a new session, and there is now exactly one of them — apart
   * from one button this file cannot reach, named at the bottom of this note.
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
   * flow all call. What is gone is any *button in this window's chrome* that
   * reaches it without asking.
   *
   * ## One button still goes round this, and it is not in this file
   *
   * That last sentence read "any *button*" until 2026-08-19, when an audit of
   * the recorded reviews read it as a closed invariant and it is wrong by one.
   * The paired-machine card on Settings → Remote draws its own **New session** —
   * `machines/MachineLinks.tsx`, in the `machines-actions` row — and its handler
   * calls `bridge.createMachineSession(machine.id, link.folders?.[0] ?? '')`.
   * That is the quick window he asked to have taken away, wearing a different
   * frame: nothing asks which agent, nothing asks which login, and the folder is
   * whichever one happens to be first in the list that machine advertised rather
   * than one anybody picked. Its own test pins the direct spawn, so it is
   * current intent rather than something left behind.
   *
   * The sentence is corrected rather than deleted. The invariant it states is
   * still the one this function is holding to and still what every control in
   * the rail, the strip, the palette and the menu obeys; it was simply never
   * true of the whole app, and a comment that overstates is exactly how the next
   * reader is told a gap is closed.
   *
   * ## What closing it takes, so the next person does not have to find it twice
   *
   * One call site, and this function is already what it should call:
   * `openNewSessionDialog(null, machine.id)` — the same press the rail's machine
   * heading makes below, which lands on the dialog's machine step with the
   * folder and the agent still to answer. What it needs is a way *up*: that page
   * is four components above this one and on the far side of `PanelView`'s
   * switch, so a callback cannot be threaded down without widening the file that
   * draws all ten views. The route already exists for the identical problem one
   * subject over — `machines/servers/session-context.ts` publishes the window's
   * server-shell opener as a context, `null` meaning "no window around me, so
   * draw no control", and `ServerAdvanced` reads it. A machine opener wants the
   * same shape.
   *
   * Not built here, on purpose: the context and the button both live in files
   * this pass does not own, and a provider with nothing reading it is dead code
   * that reads like a finished feature. Naming it with its shape is worth more
   * than half of it.
   */
  const openNewSessionDialog = useCallback(
    (
      path?: string | null,
      /**
       * Which machine to start on, when the press already answered that.
       *
       * Null and `undefined` are the same answer — this machine — and that is
       * the honest default: every existing caller means here, and a parameter
       * that made them all say so would be a rewrite of four call sites to
       * express what they already meant.
       */
      machineId?: string | null,
    ) => {
      setNewSessionPath(path ?? null)
      setNewSessionMachine(machineId ?? null)
      setNewSessionOpen(true)
    },
    [],
  )

  /*
   * The servers, re-read each time the dialog opens. See `startServers`.
   *
   * The failure path sets an empty list rather than a message: the dialog's
   * Where section is an *offer*, and an offer nobody can make is one that is not
   * drawn. A person with an unreadable servers list still gets exactly the
   * dialog they had before servers existed, and the Machines panel is where a
   * broken servers list is reported, because that is the screen about servers.
   */
  useEffect(() => {
    if (!newSessionOpen || serversBridge === null) return
    let cancelled = false
    void serversBridge.listServers().then(
      (raw) => {
        if (!cancelled) {
          setStartServers(asServers(raw).map((row) => ({ id: row.id, name: row.name })))
        }
      },
      () => {
        if (!cancelled) setStartServers([])
      },
    )
    return () => {
      cancelled = true
    }
  }, [newSessionOpen, serversBridge])

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
   * ## `null` empties the window, and until 2026-08-17 it did not
   *
   * It means there is nothing left on the bar to fall back to, and the window
   * used to answer that by drawing `tabs[0]` — so the last tab you took off came
   * straight back, in italic, as a transient tab. Asad: *"if there are three or
   * two windows open and I close all of them, the last one I will not be able to
   * close from the top bar."* A control that redraws itself the instant you press
   * it is a control that does not work.
   *
   * The reasoning behind the old behaviour was coherent — "a window showing a
   * terminal must have a tab naming it", which is why `shownTabs` always draws
   * the active tab — but that invariant is one the app chose, not one the user
   * asked for, and the honest way to keep it is to stop showing a terminal.
   * Closing every tab leaves an **empty pane**, the way closing every tab in a
   * browser leaves you somewhere sensible rather than refusing.
   *
   * Nothing is closed by this. Every session is still running and still in the
   * rail, which is the model of the strip itself: *"side panel will have
   * everything inside, and above we just set a view which one we want to see."*
   *
   * ## It has to route, or the ✕ works on this computer only — 2026-08-21
   *
   * Asad, inside a terminal on Office PC with its own tab active: *"Now if I am
   * on this session and I want to close this session from here, from top bar, I
   * think I cannot because I am inside. So either it should not matter if I am
   * inside or not."*
   *
   * `openMachineSession` and `openServerSession` are where this window keeps
   * *"which session on another computer is filling the pane"*, and
   * `railActiveTabId` prefers them over every local tab, because when one is on
   * screen it is what is on screen. This handler used to move the local
   * selection and nothing else — so after taking a server tab off the bar, the
   * server terminal was still mounted in front, `railActiveTabId` still resolved
   * to its id, and `shownTabs` drew it again as a transient tab at the end of the
   * row. In his frames the pill visibly *moves* from third place to last and
   * stays selected, which is that, exactly.
   *
   * `paneForTab` is the routing, and it is the whole of the fix: a local id puts
   * both panes away, a remote or server id moves the pane to the window being
   * shown instead, and `null` puts both away for a window somebody has emptied.
   * The four kinds of session then leave the bar identically, which is what he
   * asked for — *"regardless of whatever the session it is, even the commander."*
   *
   * It is a function rather than two more branches here because `selectTab`
   * below asks the identical question — *given an id, where does that window
   * live* — and the copy of it that drifts is always the one nobody navigates
   * with. `selectTab` still answers it inline, with its own wiring tests over
   * that shape; when it is next opened it should come through here too.
   *
   * What it still does not do is end anything. `paneForTab` reaches no pty, no
   * machine and no server; the session keeps running and keeps its row in the
   * rail, and Delete on that row is still the only thing in this app that ends
   * one.
   */
  const showInstead = useCallback(
    (id: string | null) => {
      const pane = paneForTab(id)
      setOpenMachineSession(pane.machine)
      setOpenServerSession(pane.server)
      /*
       * A window on another computer is drawn by `mainView` as the whole pane
       * rather than as a tab, so the local selection is not what says it is on
       * screen and must not be moved to name it — `selectTab` returns at the
       * same point and for the same reason. Leaving it alone is also what keeps
       * the covering view: pressing ✕ while reading Files must leave you in
       * Files, whichever machine the tab belonged to.
       */
      if (!pane.local) return
      setSelection(showTabSelection(id))
      if (id === null) return
      if (windowSessionsRef.current.some((session) => session.id === id)) setActiveSession(id)
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

  /**
   * Open a browser page.
   *
   * `url` is empty for the globe — a new tab goes to the start page — and set
   * when a *link* asked for this tab: a repository in the GitHub panel, or a
   * `target="_blank"` inside a page the browser is already showing. Both
   * arrive through `onOpenLinkTab` below, and both are the same act as pressing
   * the globe, so they take the same route and get the same treatment on the
   * bar rather than a second path that could drift from it.
   */
  const newBrowserTab = useCallback(
    (target?: string, hostMachineId?: string) => {
      /*
       * Only a string is an address, and this is the boundary that says so.
       *
       * This function is handed to `onNewBrowserTab` in two components, and both
       * put it straight on a button's `onClick` — so React calls it with a
       * `MouseEvent`. TypeScript cannot see that: `(target?: string) => void` is
       * assignable to `() => void`, because a handler that ignores its argument
       * and one that reads it are the same type. Both call sites now pass
       * `() => newBrowserTab()` and this line means the next one does not have to
       * remember.
       *
       * It was not hypothetical for long. On 2026-08-17 the event travelled from
       * here as `WorkspaceTab.url`, arrived in `BrowserWorkspace` as `initialUrl`,
       * became a tab's `draft`, and threw `input.trim is not a function` out of
       * `resolveOmnibox` during render — which the error boundary turned into
       * "New tab stopped working" across every pane in the window.
       */
      const url = typeof target === 'string' ? target : ''
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
      /*
       * Unique even when two arrive in the same millisecond.
       *
       * `Date.now()` alone was enough while the only way in was a click on the
       * globe. It is not any more: a page is allowed to open two `target="_blank"`
       * links from one gesture, and two tabs sharing an id would be two React
       * children with the same key, one strip entry for both, and a ✕ that closes
       * whichever the map happened to keep.
       */
      tabSeq.current += 1
      const id = `browser:${Date.now()}:${tabSeq.current}`
      setExtraTabs((prev) => [
        ...prev,
        {
          id,
          kind: 'browser',
          label: 'New tab',
          closable: true,
          url,
          /*
           * Which machine's network this page belongs on, when a session on
           * another machine is what asked for it.
           *
           * Spread conditionally, because absent and empty have to be the same
           * thing to every reader — see {@link WorkspaceTab.hostMachineId}.
           */
          ...(typeof hostMachineId === 'string' && hostMachineId !== ''
            ? { hostMachineId }
            : {}),
        },
      ])
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
      /*
       * Handed back, so a caller that has to *say* which window it opened can.
       *
       * The shim holds an agent's `curl` open while this runs and then prints
       * "Opened in B2"; the main process reserved that number before asking, and
       * this id is what it attaches the number to. Without a return value the
       * only way to connect the two would be to guess at the newest tab, which is
       * wrong the moment a page opens two links from one gesture — the same race
       * `tabSeq` above exists for.
       */
      return id
    },
    [showTab, features],
  )

  const selectTab = useCallback(
    (id: string) => {
      /*
       * A session on another machine, opened in the pane the way a local one is.
       *
       * First, and it is the whole of what makes a remote pill behave like a
       * local one: every route into "show me this" — a click on the rail, a
       * click on the pill, ⌘1–9, the command palette — arrives here, so putting
       * the routing at the top means there is one road rather than a second one
       * that will drift. `readMachineTabId` is the only code that knows how the
       * machine and the session were joined into an id.
       *
       * `clearPanel` for the reason the rail's own handler used to give: a
       * remote terminal drawn behind a covering view would be a session nobody
       * could see, running keystrokes nobody sent.
       */
      const remote = readMachineTabId(id)
      if (remote) {
        clearPanel()
        setCopilotPending(false)
        /*
         * While the window is split, it fills the pane you are looking at —
         * exactly as a local session or a browser page does, and for the same
         * reason: the rail is a list of what you have open, not a layout editor,
         * and a click that took the whole frame back would be the list undoing
         * the arrangement rather than driving it. Taking the frame is what this
         * did unconditionally, which is half of why a remote session could not
         * be *put* in a pane at all.
         */
        if (isSplit(panesRef.current)) {
          setPanes((current) => showInFocusedPane(current, id))
          return
        }
        setOpenMachineSession(remote)
        setOpenServerSession(null)
        return
      }
      /*
       * A terminal on a server, shown the same way and by the same road.
       *
       * Second rather than first only because the machine test was already
       * here; the two are independent and either order is correct. What matters
       * is that both are *above* `showTab`, so every route into "show me this"
       * — the rail, the pill, ⌘1–9, the palette — arrives at one place and
       * routes once. `readServerTabId` is the only code that knows how the two
       * handles were joined into this id.
       */
      if (readServerTabId(id)) {
        clearPanel()
        setCopilotPending(false)
        // And into the focused pane while split, for the reason above.
        if (isSplit(panesRef.current)) {
          setPanes((current) => showInFocusedPane(current, id))
          return
        }
        setOpenMachineSession(null)
        setOpenServerSession(id)
        return
      }
      showTab(id)
      /*
       * A remote session filling the window is put away by any local navigation.
       *
       * It covers the pane the way a sidebar view does — see `mainView` — so the
       * thing that reveals what is underneath is the same thing that reveals it
       * for a panel: choosing something else. Without this line, clicking a
       * local session in the rail would highlight its row and leave the far
       * machine's terminal on screen, which is the app disagreeing with itself
       * about what is selected.
       */
      setOpenMachineSession(null)
      /* And the same for a terminal on a server, which covers the pane in
         exactly the same way and has to be revealed from under by exactly the
         same act. */
      setOpenServerSession(null)
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
      // Navigating anywhere cancels a copilot open that has not landed yet.
      // Otherwise the effect below would yank the window onto the copilot
      // seconds after somebody changed their mind and clicked something else.
      setCopilotPending(false)
      // Terminals key off the store's active session; keep the two in step or
      // switching to a session shows the previously focused terminal. A page
      // has no session to make active, and must not overwrite the one that is.
      // `windowSessions`, because the copilot is one of the sessions a click can
      // land on now — the pinned row, a pill, or ⌘1–9.
      if (!windowSessions.some((session) => session.id === id)) return
      setActiveSession(id)
    },
    [windowSessions, setActiveSession, showTab, clearPanel],
  )

  /**
   * A row in the rail, pressed — which opens that window *beside* the one you
   * are in rather than replacing it.
   *
   * ## What he asked for
   *
   * Asad, 2026-08-17: *"If I am clicking different ones, instead of switching,
   * whenever I click on side panel on anyone, it should open a new window
   * instead of switching. It should open its own new window next to it."*
   *
   * A "window" here is a pill in the top bar — that is the word he uses for them
   * throughout the same recording (*"why the other ones are going from the
   * windows tab bar?"*) — so this is not a second `BrowserWindow`. It is the
   * difference between the bar holding one pill that keeps being overwritten and
   * the bar accumulating the windows you opened, which is what every tabbed
   * application does and what he was expecting.
   *
   * ## And it is the fix for the complaint two minutes later
   *
   * *"If I click on commander, they go away."* Reproduced in the harness: click
   * three rows in turn and the strip reads `Session 1`, then `Session 2`, then
   * `Update Claude Code…` — one pill, replaced each time. None of them was ever
   * *kept*; each was drawn only because `shownTabs` always draws the active tab,
   * so each evaporated the moment the next thing was opened. Opening the copilot
   * was simply the next thing. He worked out for himself that the sessions
   * involved were the copilot's and said that part *"makes sense"* — but then:
   * *"they should still stay if they are opened in the top bar."* They do now,
   * because opening one from the rail is what puts it there.
   *
   * ## Why this is a separate callback from `selectTab`
   *
   * `selectTab` is still what a pill in the strip, ⌘1–9 and ⌘⇧[ / ⌘⇧] call.
   * Those are moves *between windows you already have*, and a strip that
   * promoted on its own click would be promoting a tab that is either already
   * promoted or is the transient one you are looking at — no-ops at best, and at
   * worst a bar that pins whatever you glance at. Opening from the rail is the
   * deliberate act; this is called there and nowhere else, which is the same
   * line `keepNewWindowInStrip` draws for a window that is *created*.
   */
  const openTabWindow = useCallback(
    (id: string) => {
      // The anchor is read before the selection moves, because "next to it"
      // means next to the window you were in when you pressed the row.
      const anchor = activeTab?.id ?? null
      /*
       * The window you were already looking at is kept as well.
       *
       * Measured after the first version of this, in the harness: launch, then
       * click the second row. `Session 1` was in the bar — transient, because a
       * fresh window falls back to `tabs[0]` and `shownTabs` always draws
       * whatever is active — and it vanished the instant the second window
       * opened. Which is the complaint again, one window later: he watched
       * something leave the bar that he had not asked to leave.
       *
       * So opening a second window keeps the first. It is bounded to this one
       * act — a press on a rail row — and it is not "promote whatever is
       * active": nothing here fires on a pill click, on ⌘1–9, or on a session
       * merely becoming current. And it cannot resurrect a tab somebody took
       * off the bar on purpose, because the pill's own ✕ moves the selection
       * away as it goes, so a demoted tab is never the anchor.
       */
      if (anchor !== null && anchor !== id) keepNewWindowInStrip(anchor)
      keepWindowBesideInStrip(id, anchor)
      selectTab(id)
    },
    [activeTab, selectTab],
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

  /**
   * The process ended: the record's own exit code, written down.
   *
   * ## Why this was missing and how it hid
   *
   * `session:exit` had three subscribers in this renderer — the alerts feed,
   * the Overview board and the copilot's naming — and none of them put the code
   * back on the session. `SessionMeta.exitCode` was therefore read once, at
   * launch, and stayed `null` for every session this window ever started.
   *
   * The status arriving beside it is what hid it. `session:status` carries
   * `'exited'` at the same moment, so the rail's dot went grey and the tab said
   * the right thing, while every consumer that asks the *record* was told the
   * session was alive. `controlsFor` is the one that shows: it answers
   * `exited: local.exitCode !== null`, so a killed agent kept a pressable
   * `Opus 5 1M ⌄ · Ultracode ⌄ · Connectors ⌄` on the bar above a terminal
   * reading `[process exited]`, and `localSessionEnd` — the pane's own reading
   * — could never fire at all.
   *
   * Its own effect rather than a line in the one above, because they are two
   * channels: a status is a classification of output and can be re-broadcast at
   * any time, and this is the operating system answering once.
   */
  useEffect(() => {
    return window.deck.onSessionExit((id, exitCode) => {
      setSessionExit(id, exitCode)
    })
  }, [setSessionExit])

  /**
   * A link, arriving as a browser page in this window.
   *
   * Both kinds come down this one channel because both are the same request
   * seen from the main process: `window.open` from this app's own UI — a
   * repository, a pull request, an issue in the GitHub panel — and
   * `target="_blank"` inside a page the embedded browser is already showing.
   * Neither gets a window of Chromium's; both get a tab of ours. See
   * `main/link-open.ts` for the decision and for why a guest page is answered
   * more strictly than the app shell is.
   *
   * ## When the browser is not installed
   *
   * The link still opens — in the real browser. That is the one place this
   * differs from the globe, which *installs* the browser pane because pressing
   * the globe is asking for one. Pressing a repository is not: somebody who has
   * switched the browser off in Features has said what they want, and quietly
   * installing a pane in answer to a link would be the app arguing with them.
   * The link opening somewhere is the requirement; opening here is the default.
   */
  /**
   * Which browser windows belong to which session, pushed from the main
   * process.
   *
   * Read-only, and there is deliberately no second copy: the relation is owned
   * by `main/browser-binding.ts`, because the two things that read it — a shim's
   * HTTP request from inside a session, and a hook response an agent's turn is
   * blocked on — both arrive there and neither can wait for a renderer. What
   * this does is take the pushed view into the store the chips and the pane bar
   * read.
   *
   * Asked for once as well as subscribed to. A push reaches whoever is
   * listening at the time it is sent, and a window that has just reloaded is
   * not: without the first call this window would draw no chips at all until
   * something else changed, which is the "built, and never wired to boot"
   * failure this file keeps finding.
   */
  useEffect(() => {
    void window.deck
      .browserBindings?.()
      .then(setBindings)
      .catch(() => undefined)
    return window.deck.onBrowserBindings?.(setBindings)
  }, [])

  useEffect(
    () =>
      window.deck.onOpenLinkTab((request) => {
        const { url, requestId } = request
        /*
         * And which machine asked, which this handler used to drop on the floor.
         *
         * `LinkTabRequest` has carried a machine id since the binding was built
         * and nothing downstream of here read it, so a page opened by a session
         * on his PC arrived as an ordinary tab on this Mac's network — the
         * localhost it loaded was this computer's. It now travels to the pane,
         * which points its machine picker there and reaches the address through
         * that machine's tunnel. The window is still this window: *"keep the
         * same one browser window for every device."*
         */
        const hostMachineId = typeof request.machineId === 'string' ? request.machineId : ''
        if (!features.on('browser')) {
          /*
           * Somebody waiting for an answer is told, rather than having the link
           * opened for them.
           *
           * The waiting caller is the shim, holding an agent's `curl` open, and
           * it opens the URL itself the moment it hears `system`. Opening it
           * here as well would put the same page on screen twice. Without a
           * `requestId` nobody is waiting and this is the ordinary link that has
           * always gone straight out.
           */
          if (requestId) {
            window.deck.browserLinkOpened({
              requestId,
              refused: `${BRAND.name}'s browser is switched off in Features — opened in your default browser.`,
            })
            return
          }
          openLinkExternally(url)
          return
        }
        const tabId = newBrowserTab(url, hostMachineId)
        // Answered in the same handler, synchronously, because the id exists by
        // now and the caller is a process that is blocked. Every request that
        // carries an id is answered on every path through here — an unanswered
        // one is a session waiting out a two-second timeout for nothing.
        if (requestId) window.deck.browserLinkOpened({ requestId, tabId })
      }),
    [features, newBrowserTab],
  )


  /**
   * A session this window did not close, and that is not there any more.
   *
   * The mirror of `onSessionCreated`, and it was the missing half. Closing a tab
   * goes through `closeTabNow` below, which kills the pty and removes the row in
   * the same breath — so the only ending this window ever heard about was one it
   * caused itself. Everything else left a row behind: the copilot's
   * `sessions.stop`, a paired phone stopping one, a routine.
   *
   * Watched on 2026-08-18: the copilot stopped a session it had started,
   * `sessions_list` came back with only the copilot in it, and *"Copilot
   * sessions → Session 1"* was still in the rail — a row that could not be typed
   * into, re-attached, or got rid of short of quitting the app.
   *
   * Deliberately **not** `onSessionExit`. A process that ends by itself keeps its
   * place in the main process, keeps its scrollback, and keeps its tab, because
   * reading what it printed before it died is the reason that tab is still worth
   * having. `session:removed` is the app letting go of the session entirely, and
   * the main process filters the account switch out of it — see `RemovalReason`
   * — so nothing here has to know about that case.
   *
   * Everything that remembers the session forgets it together, exactly as
   * `closeTabNow` does: a stale unread dot is untidy, and a finish banner for a
   * session that no longer exists is a click that goes nowhere.
   *
   * It sits here rather than beside `onSessionCreated` for one dull reason —
   * `notifier` is declared further down this component, and a hook cannot read a
   * binding that does not exist yet.
   */
  useEffect(
    () =>
      window.deck.onSessionRemoved?.((id) => {
        unread.forget(id)
        notifier.forget(id)
        titler.forget(id)
        // Including the top bar. The strip prunes its own order, but only while
        // it is on screen and only for tabs it has watched arrive — see
        // `forgetWindowInStrip` for the ids that leak past both.
        forgetWindowInStrip(id)
        removeSession(id)
      }),
    [removeSession, unread, notifier, titler],
  )

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
      // The strip too: this is the app letting go of the window, and an id left
      // in the promoted order counts against its cap for the rest of the run.
      // See `forgetWindowInStrip`.
      forgetWindowInStrip(id)
      if (tab?.kind === 'session') {
        void window.deck.killSession(id)
        removeSession(id)
      } else {
        // The main process holds the session ↔ browser relation, and it cannot
        // see a tab leave a React array. Its number is *not* handed out again:
        // closing B1 leaves B2 called B2, because an agent told to look at a
        // renumbered window points confidently at the wrong page.
        window.deck.browserWindowClosed?.(id)
        setExtraTabs((prev) => prev.filter((t) => t.id !== id))
      }
      // `nextActiveId` answers null when that was the last window, and null now
      // means an empty pane rather than "fall back to the first thing open" —
      // which is the same correction `showInstead` above carries the argument
      // for. Closing the only thing you had open leaves you looking at nothing,
      // which is what you asked for.
      setSelection(showTabSelection(following))
    },
    [tabs, removeSession, unread, notifier, titler],
  )

  /**
   * The main process asking for one of these browser windows to be closed.
   *
   * The mirror of `onOpenLinkTab`, and it exists for the same reason that one
   * does: the relation and the drive live in main, the *rows* live here, and a
   * view torn down without its row leaves a strip entry that cannot be opened,
   * attached or got rid of. So the close goes through `closeTabNow`, which is
   * the exact path the tab's own ✕ takes — the binding map is told, the number
   * is not handed out again, and the selection moves as it would have.
   *
   * Answered on every path, including the one where there is no such tab: the
   * caller is a tool call somebody is waiting on, and `false` is a real answer
   * — the window has already gone — rather than a five-second silence.
   */
  useEffect(
    () =>
      window.deck.onBrowserDriveClose?.((raw) => {
        const request = raw as { id?: unknown; tabId?: unknown }
        if (typeof request?.id !== 'string' || request.id === '') return
        const tabId = typeof request.tabId === 'string' ? request.tabId : ''
        const tab = tabs.find((entry) => entry.id === tabId && entry.kind === 'browser')
        if (tab) closeTabNow(tabId)
        window.deck.browserDriveClosed?.(request.id, tab !== undefined)
      }),
    [tabs, closeTabNow],
  )

  /**
   * The main process asking for one of these browser windows to be shown.
   *
   * Not a courtesy. A `WebContentsView` is laid out by the pane only while it is
   * the tab on screen, so a background one has a 0×0 viewport: every driven
   * click aimed at it is dropped and `capturePage()` answers that it has no
   * visible surface. Both were measured against two windows attached to one
   * session. So a driven click brings its window forward first, which is also
   * the only arrangement in which the drive banner is doing its job.
   */
  useEffect(
    () =>
      window.deck.onBrowserDriveShow?.((raw) => {
        const request = raw as { id?: unknown; tabId?: unknown }
        if (typeof request?.id !== 'string' || request.id === '') return
        const tabId = typeof request.tabId === 'string' ? request.tabId : ''
        const tab = tabs.find((entry) => entry.id === tabId && entry.kind === 'browser')
        /*
         * Already in front is already done, and saying so costs nothing while
         * doing it again costs something real: `showTab` clears whatever
         * sidebar panel is open, so a re-show on every driven click would close
         * a panel the person opened, over and over, for no change on screen.
         */
        if (tab && activeTab?.id !== tabId) showTab(tabId)
        window.deck.browserDriveShown?.(request.id, tab !== undefined)
      }),
    [tabs, showTab, activeTab],
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

  /**
   * Close a project, asking first — always, and about the whole of it.
   *
   * *"Always ask before closing anything from the side panel."* This used to
   * count the sessions in the folder that were `working` or `input` and skip the
   * dialog when there were none, which meant the ✕ on a project heading closed
   * four calm agents outright with no confirmation at all. Reproduced in the
   * harness: four rows, one press, everything gone. Closing a project is the
   * single most destructive control in this window and it was the quietest.
   *
   * `count` is now every session in the folder rather than only the busy ones,
   * because that is the number the dialog is telling you about: *"Closing this
   * project closes 4 sessions."* Counting only the busy ones made the sentence
   * describe a subset of what the button was about to do.
   *
   * An empty folder still asks. It costs one press and it is the one case where
   * the person cannot be surprised by the answer; making it the exception would
   * put a rule back that the whole change is about removing.
   */
  const closeProject = useCallback(
    (path: string) => {
      const inside = sessionsRef.current.filter((session) => session.projectPath === path)
      if (!confirmClose) {
        closeProjectNow(path)
        return
      }
      setPendingClose({
        kind: 'project',
        path,
        name: folderNameOf(path) ?? path,
        // The most alarming state among them, so the dialog's wording is about
        // the worst thing this press will interrupt rather than about whichever
        // session happens to be first in the list.
        status: inside.find((session) => RISKY_STATUSES.has(session.status))?.status ?? 'idle',
        count: inside.length,
      })
    },
    [closeProjectNow, confirmClose],
  )

  /**
   * End one session on another machine, having already asked.
   *
   * `machines.closeSession` answers *the request left this computer*, and that
   * is deliberately all it answers: the session ends over there, and the row
   * leaving `machines:state` is what says it happened. So nothing here waits and
   * nothing here removes a row — the push does, which is the same arrangement
   * `startSession` has in the other direction.
   *
   * A refusal is reported rather than swallowed. The window only draws the ✕
   * when the far machine advertised `close`, so a `false` here means something
   * changed between the draw and the press — the link dropped, the session had
   * already exited — and a ✕ that quietly does nothing is the exact complaint
   * this pass exists to remove. The rail is re-read so whatever is actually true
   * over there is on screen a moment later.
   */
  const closeMachineSessionNow = useCallback(
    (machineId: string, sessionId: string) => {
      void machines.closeSession(machineId, sessionId).then((sent) => {
        if (!sent) machines.reread()
      })
      /*
       * And put the pane away if that was the session filling it.
       *
       * Immediately, rather than waiting for the row to disappear. A terminal
       * bound to a session that is being killed is a terminal whose bytes have
       * stopped, and leaving it on screen for the round trip would show a live-
       * looking window over a dead process. `MachineSessionPane` detaches on
       * unmount, so this is also what takes the subscription down.
       */
      setOpenMachineSession((current) =>
        current && current.machineId === machineId && current.sessionId === sessionId
          ? null
          : current,
      )
      /*
       * And take its pane off the list that keeps one mounted.
       *
       * Without this the terminal would stay in the window — hidden, attached to
       * a session that is ending — until the far machine's next push happened to
       * drop it. Here rather than left to the pruning effect because this end
       * already knows: it just asked for the session to end.
       */
      setMachineSessionPanes((open) =>
        open.filter((pane) => pane.machineId !== machineId || pane.sessionId !== sessionId),
      )
    },
    [machines],
  )

  /** The same, asking first — the rule every close in this window follows. */
  const closeMachineSession = useCallback(
    (machineId: string, sessionId: string) => {
      const tab = machineTabsRef.current.find(
        (entry) => entry.machine?.id === machineId && entry.id === machineTabId(machineId, sessionId),
      )
      if (!confirmClose) {
        closeMachineSessionNow(machineId, sessionId)
        return
      }
      setPendingClose({
        kind: 'machine-session',
        machineId,
        sessionId,
        name: tab?.label || 'Session',
        status: tab?.status ?? 'idle',
      })
    },
    [confirmClose, closeMachineSessionNow],
  )

  /**
   * End every session on one machine, and leave the machine paired.
   *
   * His words, worked out on the recording: *"Close you will not give — but you
   * can actually give, because it should not disconnect the remote account. It
   * will just close all of the sessions from that PC. Yeah, you can give this
   * close too, so it will go from here, but whenever you want to start, you can
   * start as a new session and you can start from that device."*
   *
   * So: a `close` per session, the group hidden, and nothing whatsoever touching
   * the pairing. `forgetMachine` exists and is on the Remote screen, where
   * un-pairing belongs; this cannot reach it, which is the point.
   *
   * The frames go out together rather than in sequence. They are independent —
   * each names one session — and awaiting them one at a time would leave a group
   * emptying row by row over a slow link, which reads as something failing
   * part-way rather than as one act.
   */
  const closeMachineNow = useCallback(
    (machineId: string) => {
      const handles = machineTabsRef.current
        .filter((tab) => tab.machine?.id === machineId)
        .map((tab) => readMachineTabId(tab.id))
        .filter((handle): handle is { machineId: string; sessionId: string } => handle !== null)

      /*
       * Hidden against the ids that are running *now*, which is what makes the
       * group go away on the press rather than a round trip later. See
       * `machineIsClosed` for why the ids and not a bare flag.
       */
      setClosedMachines((current) => [
        ...current.filter((entry) => entry.id !== machineId),
        { id: machineId, sessions: handles.map((handle) => handle.sessionId) },
      ])
      // A remote session on screen belongs to one of those, so the pane goes
      // with them rather than being left pointed at a process that is ending.
      setOpenMachineSession((current) => (current?.machineId === machineId ? null : current))

      void Promise.all(
        handles.map((handle) => machines.closeSession(handle.machineId, handle.sessionId)),
      ).then((results) => {
        /*
         * A refusal puts the group back, rather than leaving work hidden.
         *
         * The window only draws Close when the far machine advertised `close`,
         * so a `false` here means something changed between the draw and the
         * press — the link dropped, the machine went to sleep mid-frame. The
         * sessions are then still running over there, and a hidden group would
         * be this app quietly deciding that work it failed to end no longer
         * exists. Re-reading is what puts the truth back on screen.
         */
        if (results.every((sent) => sent)) return
        setClosedMachines((current) => current.filter((entry) => entry.id !== machineId))
        machines.reread()
      })
    },
    [machines],
  )

  /**
   * The same, asking once — and once is the requirement rather than a nicety.
   *
   * *"Closing several sessions at once deserves one confirmation naming how
   * many, not one dialog per session."* So the count is carried into the dialog
   * and the sentence is built from it, exactly as closing a project already
   * does. An empty machine still asks, for the reason `closeProject` gives about
   * an empty folder: it costs one press, it is the one case where the answer
   * cannot surprise anybody, and making it the exception puts back the rule this
   * is removing.
   */
  const closeMachine = useCallback(
    (machineId: string) => {
      const on = machineTabsRef.current.filter((tab) => tab.machine?.id === machineId)
      if (!confirmClose) {
        closeMachineNow(machineId)
        return
      }
      setPendingClose({
        kind: 'machine',
        machineId,
        name: on[0]?.machine?.name ?? 'that machine',
        // The most alarming state among them, so the wording is about the worst
        // thing this press interrupts rather than about whichever session
        // happens to be first — the same rule `closeProject` follows.
        status: on.find((tab) => RISKY_STATUSES.has(tab.status ?? 'idle'))?.status ?? 'idle',
        count: on.length,
      })
    },
    [confirmClose, closeMachineNow],
  )

  /* ------------------------------------------------------ shells on servers -- */

  /**
   * Open a terminal on a server, and put the window on it.
   *
   * ## Why the tab exists before the shell does
   *
   * The far end's handle for a shell does not exist until a connection is up and
   * the shell has been opened, which is a round trip across the internet to a
   * machine that may be asleep. A press that waited for it would leave the
   * window with nothing on screen for a second or more, and a failure would have
   * nowhere to be reported. So the window mints its own key, opens the tab on it
   * at once, and the pane below asks for the shell — which is also where a
   * refusal is said, in the terminal itself, where the person is already looking.
   *
   * ## The dialog reaches this too, since 2026-08-19
   *
   * This note used to say the New session dialog was *not* a route to a server,
   * and the argument was that the dialog asks three questions — which folder,
   * which agent, which login — that this app could answer none of about a
   * stranger's machine. Two of the three still stand and are now stated on
   * screen: a server session is a login shell, so the Agent cards and the Login
   * pop-up are absent there with a sentence saying they are programs on this
   * Mac. The third was simply untrue, and Asad said so — *"it should give me a
   * window to choose the path from server to start a session."* The folders are
   * knowable; nothing had asked. `ServerFolderPicker` asks, over SFTP.
   *
   * So the dialog now routes here rather than growing a second way to mint a
   * terminal on a server, which is what makes the server page's own button and
   * the rail's New session the same act arrived at from two places.
   *
   * `keepNewWindowInStrip`, because this window *created* this one: *"if I open
   * any new session and any new browser from the header, it should automatically
   * open in the top bar."* That is the difference from a session on a paired
   * machine, which was already running over there and is merely being looked at.
   */
  const openServerShell = useCallback(
    (serverId: string, serverName: string, startIn: string | null = null, run: string | null = null) => {
      const key = newShellKey()
      setServerSessions((current) => withServerSession(current, serverId, serverName, key, startIn, run))
      const id = serverTabId(serverId, key)
      /*
       * The same three things selecting a remote session does, and for the same
       * reason: a terminal drawn behind a covering view would be a session
       * nobody can see, taking keystrokes nobody sent.
       */
      clearPanel()
      setCopilotPending(false)
      setOpenMachineSession(null)
      setOpenServerSession(id)
      keepNewWindowInStrip(id)
    },
    [clearPanel],
  )

  /**
   * End one terminal on a server.
   *
   * Taking the row off the list **is** the close. The pane is mounted for as
   * long as its tab exists and its teardown closes the shell on the far end —
   * see `ServerSessionPane`, which carries the argument for why it is mounted
   * that way. So there is no request to send from here and nothing to await: the
   * unmount this state change causes is the act.
   *
   * That also settles what a failure would mean, which is nothing: the shell
   * lives on a connection this window is holding, so letting go of it cannot be
   * refused by anything at the far end. There is nothing over there to refuse.
   */
  const closeServerSessionNow = useCallback((tabId: string) => {
    setServerSessions((current) => withoutServerSession(current, tabId))
    // And put the pane away if that was the one filling the window. Immediately,
    // rather than waiting for a list to settle: a terminal whose shell is being
    // closed is a terminal whose bytes have stopped.
    setOpenServerSession((current) => (current === tabId ? null : current))
  }, [])

  /** The same, asking first — the rule every close in this window follows. */
  const closeServerSession = useCallback(
    (tabId: string) => {
      if (!confirmClose) {
        closeServerSessionNow(tabId)
        return
      }
      const entry = serverSessionsRef.current.find((one) => one.tabId === tabId)
      setPendingClose({
        kind: 'server-session',
        tabId,
        name: entry?.serverName ?? 'that server',
        status: entry?.status ?? 'idle',
      })
    },
    [confirmClose, closeServerSessionNow],
  )

  /**
   * End every terminal open on one server, and keep the server.
   *
   * Exactly what Close means on a machine's heading, one kind down: *"it should
   * not disconnect the remote account. It will just close all of the sessions
   * from that PC."* Here the terminals end, the group goes because a server's
   * heading is only drawn while something is open on it, and nothing about the
   * stored server changes — it keeps its name and its sign-in and is one press
   * from another terminal. Forgetting a server is a different act with its own
   * button on its own page, and this cannot reach it.
   *
   * There is no `closedServers` set to mirror `closedMachines`. That set exists
   * because a machine's sessions end on the *other* computer, so at the instant
   * Close is pressed they are all still listed and the group would un-hide in
   * the same render that hid it. Nothing here is asked of anybody else: the list
   * is this window's, and removing from it is the close.
   */
  const closeServerNow = useCallback((serverId: string) => {
    setServerSessions((current) => withoutServer(current, serverId))
    setOpenServerSession((current) => {
      if (current === null) return null
      return readServerTabId(current)?.serverId === serverId ? null : current
    })
  }, [])

  /**
   * The same, asking once — and once rather than per terminal, for the reason
   * closing a machine already gives: *"Closing several sessions at once deserves
   * one confirmation naming how many, not one dialog per session."*
   */
  const closeServer = useCallback(
    (serverId: string) => {
      const on = serverSessionsRef.current.filter((entry) => entry.serverId === serverId)
      if (!confirmClose) {
        closeServerNow(serverId)
        return
      }
      setPendingClose({
        kind: 'server',
        serverId,
        name: on[0]?.serverName ?? 'that server',
        // The most alarming state among them, so the wording is about the worst
        // thing this press interrupts — the same rule the other two group closes
        // follow.
        status: on.find((entry) => RISKY_STATUSES.has(entry.status))?.status ?? 'idle',
        count: on.length,
      })
    },
    [confirmClose, closeServerNow],
  )

  /**
   * The far end has gone: somebody typed `exit`, the link dropped, the machine
   * went away.
   *
   * The row stays and its dot goes to `exited`, which is what a local session
   * does when its process ends — the tab is still there, still readable, and
   * still closed by hand. Removing it here instead would take the last thing the
   * shell printed off the screen at the exact moment somebody wants to read it.
   */
  const serverShellEnded = useCallback((tabId: string) => {
    setServerSessions((current) => serverSessionEnded(current, tabId))
    // The id is dropped with the shell. Keeping it would leave the bar
    // addressing a channel the main process has already closed, which reads back
    // as a session that is "no longer running" — true, but arriving from a stale
    // handle rather than from the row that is plainly gone.
    setServerShellIds((current) => {
      if (!(tabId in current)) return current
      const next = { ...current }
      delete next[tabId]
      return next
    })
  }, [])


  /**
   * The same shells, as the browser's send-to-session picker needs them.
   *
   * The two halves joined once, here, rather than in the panel: the window is
   * the only place that holds both the rows and the handles the far end
   * answered with, and a browser panel reaching for either of them would be a
   * second owner of a list that has exactly one.
   *
   * It is passed to **both** mount sites of `BrowserWorkspace` below, for the
   * reason `tabId` is: the split pane and the flat one are two mounts of the
   * same window, and a prop given to one of them is a feature that disappears
   * when somebody splits the window.
   */
  const browserServerShells = useMemo(
    () =>
      serverSessions.map((entry) => ({
        tabId: entry.tabId,
        serverId: entry.serverId,
        serverName: entry.serverName,
        // Empty until the server has answered `servers:shell:open`. The picker
        // lists the row and says it is still opening rather than hiding it —
        // see `resolveTarget`.
        shellId: serverShellIds[entry.tabId] ?? '',
        startIn: entry.startIn ?? '',
        ended: entry.status === 'exited',
      })),
    [serverSessions, serverShellIds],
  )

  /**
   * What the Machines panel is handed so its pages can open one of these.
   *
   * A context rather than a prop, because the only route from here to a server's
   * page is `PanelView`, which draws all ten views off a `PanelId` and takes no
   * per-view props. `machines/servers/session-context.ts` carries the argument.
   */
  const serverSessionOpener = useMemo(
    () => ({
      open: openServerShell,
      openOn: (serverId: string) =>
        serverSessionsRef.current.filter((entry) => entry.serverId === serverId).length,
      renamed: (serverId: string, name: string) =>
        setServerSessions((current) => renameServersIn(current, [{ id: serverId, name }])),
    }),
    [openServerShell],
  )

  /**
   * What the Machines page is handed so a machine's card can start a session on
   * it — the dialog, on its folder step, with the machine already answered.
   *
   * The last of the presses the 2026-08-17 review was about: *"the sidebar +
   * opens [an agent] directly instead of asking session type. Everywhere should
   * ask the same thing."* Everywhere meant the chrome, and one button was not in
   * the chrome — **New session** on a paired machine's card, which called
   * `createMachineSession` with the first folder that machine happened to
   * advertise. The long note above `openNewSessionDialog` describes the gap and
   * what closing it took; this is the line it said was missing.
   *
   * `openNewSessionDialog(null, machineId)` — character for character the call
   * the rail's machine heading makes below, because they are the same press made
   * in two places, and a second expression here is how the two would drift.
   *
   * A context rather than a prop, for the same reason the server opener above is
   * one: `PanelView` draws all ten views off a `PanelId` and takes no per-view
   * props, and the button is three components below it.
   */
  const machineSessionOpener = useMemo(
    () => ({
      open: (machineId: string) => openNewSessionDialog(null, machineId),
    }),
    [openNewSessionDialog],
  )

  /**
   * What the Machines page is handed so that pressing a session on a machine's
   * card lands on the window's session view — the only one there is now.
   *
   * That card used to draw the session's terminal itself, in the panel, under a
   * title and a Close and with none of the bar: no controls, no usage, no
   * account, no Terminal/Chat, no Split. It was the last second in-session view
   * in the app, and the complaint it belongs to is the one
   * `shell/session-view-parity.test.ts` is named for: *"every time I tell you I
   * want exactly same identical view of every type of session inside, including
   * remote session, including local session"*.
   *
   * `selectTab(machineTabId(...))` and nothing else, because that is the road
   * every other route into "show me this" already takes — the rail, the pill,
   * ⌘1–9, the palette — and it is the road that clears the panel, hands the far
   * session the frame when the window is whole and the focused pane when it is
   * split. A second expression here would be a second answer to those three
   * questions, which is how this drifted in the first place.
   *
   * A context of its own rather than a second method on `machineSessionOpener`
   * above, for the reason `machines/session-view-context.ts` gives at length:
   * that opener carries a machine id and nothing else *on purpose*, and
   * `shell/new-session-route.test.ts` counts its methods to keep it that way.
   */
  const machineSessionViewer = useMemo(
    () => ({
      show: (machineId: string, sessionId: string) =>
        selectTab(machineTabId(machineId, sessionId)),
    }),
    [selectTab],
  )

  /**
   * Close, asking first. Always.
   *
   * `CloseSessionConfirm` was written, tested and left on the unreachable list
   * while Settings offered a switch called "Confirm closing an active session"
   * that turned nothing on. The gate lives here rather than in the dialog for
   * the reason its own comment gives: a component that decides for itself
   * whether to appear can only decline by rendering nothing, which leaves the
   * user having pressed Close with no dialog and no session closed.
   *
   * It used to ask only about `working` and `input`. *"Always ask before closing
   * anything from the side panel."* — so the status no longer decides whether,
   * only what the dialog says. `needsCloseConfirm` carries the argument and the
   * one thing that still switches it off, which is the person.
   */
  const closeTab = useCallback(
    (id: string) => {
      /*
       * A session on another machine, ended where it is running.
       *
       * First, because the id is not in `tabs` and everything below this line
       * assumes it is. `readMachineTabId` is the one place that knows how the
       * two handles were joined, so this is the whole of the routing.
       *
       * It is genuinely a close, not a "take the pill off the bar". That is the
       * decision Asad reversed on 2026-08-18 — the pill exists because he asked
       * for it, and the ✕ on it means what Close on the machine's heading means:
       * *"It will just close all of the sessions from that PC… it should not
       * disconnect the remote account."* One session's worth of that.
       */
      const remote = readMachineTabId(id)
      if (remote) {
        closeMachineSession(remote.machineId, remote.sessionId)
        return
      }
      /*
       * A terminal on a server, ended where it is running.
       *
       * Beside the machine case and meaning the same thing, one kind down: this
       * is a close and not a "take the pill off the bar". The shell exists
       * because this window is holding a connection to it, so letting go of it
       * ends it — and the server itself is untouched, which is what the
       * confirmation says in its second clause.
       */
      if (readServerTabId(id)) {
        closeServerSession(id)
        return
      }
      const tab = tabs.find((t) => t.id === id)
      /*
       * ⌘W on the copilot **puts it away**. It does not end it.
       *
       * The copilot is a singleton with no row in the rail, so it has no ✕ that
       * ends a session — deliberately, because a second ✕ a few pixels from the
       * session rows meaning something else is the confusion `Sidebar.tsx`
       * carries a paragraph about. That leaves ⌘W as the one path in this window
       * that could have reached `killSession` for it, and killing the copilot
       * from a chord that says "close this window" is exactly the ending-with-no-
       * way-back this feature must not have.
       *
       * So it does what the ✕ on its own pill does: takes the pill off the bar,
       * moves to the neighbour, and leaves the process running. Stopping it is a
       * named act with its own button, in its toolbar and in Settings → Copilot,
       * and both of those are restartable from the pinned row.
       */
      if (tab?.isCopilot) {
        const removal = removeWindowFromStrip(id, tabs, activeTab?.id ?? null)
        // `undefined` means it was not the tab on screen, so nothing moves —
        // the same three-valued answer the strip's own ✕ acts on.
        if (removal.select !== undefined) showInstead(removal.select)
        return
      }
      /*
       * `tab.status ?? 'idle'` rather than `tab.status &&`.
       *
       * The old spelling silently skipped the confirmation for any session whose
       * status had not arrived yet — a session restored at launch, one a phone
       * started, one whose first status push has not landed. Those are exactly
       * the sessions a person knows least about, and they were the ones closing
       * without a word.
       *
       * A browser page is not asked about and never was: nothing is running in
       * it, and its ✕ takes a page off a list.
       */
      if (tab?.kind === 'session' && needsCloseConfirm(tab.status ?? 'idle', confirmClose)) {
        setPendingClose({ kind: 'session', tab })
        return
      }
      closeTabNow(id)
    },
    [tabs, activeTab, showInstead, confirmClose, closeTabNow, closeMachineSession, closeServerSession],
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
      // And a remote session on screen, for the reason `selectTab` gives: it
      // covers the pane, so anything that fills the pane has to take it back.
      setOpenMachineSession(null)
      /* And a terminal on a server, which covers the pane in the same way. It
         is only put *away*, never closed: the shell keeps running and its pane
         stays mounted behind the view, so coming back to it finds the scrollback
         where it was left. `ServerSessionPane` carries the argument for why that
         pane is mounted for as long as its tab exists. */
      setOpenServerSession(null)
      // Going to a view cancels a copilot open that has not landed yet — see
      // `selectTab`, which does the same for the same reason.
      setCopilotPending(false)
    },
    [selectPanel],
  )

  /**
   * Open the copilot's window — the pinned row, the palette row, and the "why
   * does this exist" link on a session the copilot started.
   *
   * ## Three things in one press, because the copilot is a session that may not
   * exist yet
   *
   * `ensure()` starts it if it is not running, and is idempotent by contract, so
   * pressing this twice is one copilot. That is what makes opening the window
   * the moment it is spawned — an agent CLI bills for what it does, and a
   * standing charge for launching the app is not something anybody agreed to.
   *
   * Its tab is derived from the running session, so when there is one this is a
   * plain `showTab` plus `keepNewWindowInStrip` — the same pair every *created*
   * window gets, because this is that act: *"if I open any new session… it
   * should automatically open in the top bar… If I want to remove it from there
   * and keep only side panel, I should have to do it myself specifically."*
   * When there is not one yet, `copilotPending` holds the window on the
   * copilot's own starting state until the effect below can hand it a real tab.
   *
   * `turn` is the action-log row the window should open on, and it is cleared on
   * a plain open for the reason `panelFocus` is: a door has to open onto the
   * thing it named, and the next plain press must not land you there again.
   */
  const showCopilot = useCallback(
    (turn?: string | null) => {
      setCopilotTurn(turn ?? null)
      copilot.ensure()
      if (copilotSessionId === null) {
        setCopilotPending(true)
        clearPanel()
        return
      }
      /*
       * `selectTab`, not `showTab`, and the difference only shows up in a split:
       * a click in the rail fills the pane you are *looking at* rather than
       * taking the whole window back, and the copilot is one of the windows that
       * rule is about. With `showTab` the selection moved and the layout did
       * not, so pressing Copilot while the window was split changed nothing on
       * screen — the same class of defect as a page that could not be reached
       * from the rail while split.
       *
       * It also clears `copilotPending`, which is right: the window it was
       * waiting for is the one being shown.
       */
      selectTab(copilotSessionId)
      keepNewWindowInStrip(copilotSessionId)
    },
    [copilot, copilotSessionId, clearPanel, selectTab],
  )

  /**
   * The same door, with the first-run questions in front of it.
   *
   * Asad, 2026-08-17: *"Maybe we can give a few steps flow before someone sets
   * up the copilot… so it will ask those questions in the flow, and the copilot
   * will always know about this and act that way always."* The flow is **before**
   * — nothing is spawned and nothing is billed until it finishes, which is the
   * difference between showing somebody what their assistant is about to become
   * and letting them discover it afterwards.
   *
   * Asked as a promise rather than read off state, and `useCopilotSetup` carries
   * why: the answer lives in a file, the click can land before the read does,
   * and concluding "never set up" from a state that has merely not loaded would
   * put these questions in front of somebody who answered them last week. It
   * resolves from the answer in hand when there is one, so the ordinary press
   * costs a microtask.
   *
   * Once it has run, this is `showCopilot` and nothing else — there is no second
   * chance to be nagged, and the flow is re-offered only from Settings.
   */
  const openCopilot = useCallback(
    (turn?: string | null) => {
      void copilotSetup.hasRun().then((ran) => {
        if (ran) {
          showCopilot(turn)
          return
        }
        setCopilotTurn(turn ?? null)
        setCopilotSetupOpen(true)
      })
    },
    [copilotSetup, showCopilot],
  )

  /**
   * The copilot has finished starting, so the window it was asked for arrives.
   *
   * An effect rather than an `await` inside {@link openCopilot}, because the id
   * does not come back from `ensureCopilot` alone: the session has to reach this
   * window through `session:created` before there is a tab to select, and those
   * are two different arrivals. Watching for the id is the only thing that is
   * true of both orders.
   */
  useEffect(() => {
    if (!copilotPending || copilotSessionId === null) return
    setCopilotPending(false)
    selectTab(copilotSessionId)
    keepNewWindowInStrip(copilotSessionId)
  }, [copilotPending, copilotSessionId, selectTab])

  /**
   * Whether the copilot's own window is the thing on screen.
   *
   * The same expression the pane is mounted with further down — deliberately,
   * because the effect under this one turns on it and a second opinion about
   * "is the copilot in front" is how the seeding would come to fire while he is
   * looking at the pane it re-seeds.
   */
  const copilotOnScreen =
    copilotSession !== null && activeTab?.id === copilotSession.id && !showingPanel

  /**
   * Which half of the copilot the window opens on — the terminal, every time
   * it is opened.
   *
   * `defaultPane` says the terminal, always — *"and always terminal should be
   * the default view"* — and it says so without being told anything, which is
   * why this effect no longer watches the copilot's stage. It used to: the
   * seeded pane depended on whether the sign-in probe had come back yet, so the
   * window opened on whichever half a race had settled on.
   *
   * It goes into the same `sessionView` map every other session's mode lives in
   * — so the window's own mode switch reads and writes it, and there is one
   * answer to "how is this drawn" rather than two.
   *
   * ## Why leaving the page forgets the switch
   *
   * This used to seed once per app launch and never again, which made *always*
   * mean *on every cold start*. Press Chat, go to Overview, come back to the
   * copilot and it opened on Chat — and opening the copilot again is exactly
   * what that is, from where he is sitting. **"Always"** was filmed as a rule
   * about opening it, not about launching the app.
   *
   * So the entry is dropped the moment the page is left, and the seeding below
   * puts the terminal back on the next entry. Pressing Chat still stands for as
   * long as he is on the page — the switch is not being taken away from him,
   * only the memory of it between visits, which is the thing he called a
   * default.
   */
  useEffect(() => {
    if (copilotSessionId === null) return
    if (!copilotOnScreen) {
      setSessionView((views) => {
        if (!(copilotSessionId in views)) return views
        const next = { ...views }
        delete next[copilotSessionId]
        return next
      })
      return
    }
    setSessionView((views) =>
      copilotSessionId in views ? views : { ...views, [copilotSessionId]: defaultPane() },
    )
  }, [copilotSessionId, copilotOnScreen])

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
    /*
     * The panes become the authority on what is on screen, so the two
     * whole-window answers are put away.
     *
     * They are not a *second* place a remote session can be — they are the
     * unsplit window's way of saying "this fills the frame", and a split frame
     * has no such thing. Leaving them set meant `heading`, `modesBlocked` and
     * every pane's visibility disagreeing about whether the server terminal was
     * the whole window or one of two panes. `seedSplit` has already been handed
     * `shownTabId`, so whatever was on screen is in the first pane before this
     * takes effect, and `closeSplit` puts it back.
     */
    setOpenMachineSession(null)
    setOpenServerSession(null)
    setPanes((current) =>
      /*
       * `openTabsRef`, not `sessionsRef` and no longer `tabsRef`. Pressing Split
       * while a page is in front used to seed the first pane from the session
       * list, so the page you were reading disappeared the moment you split;
       * pressing it over a session on a paired machine or a terminal on a server
       * did the same thing to that session, because those are not in `tabs`
       * either. `shownTabId` rather than `focusedId` for the identical reason —
       * it is the tab actually on screen, on whichever computer.
       */
      isSplit(current) ? splitFocused(current) : seedSplit(openTabsRef.current, shownTabId),
    )
  }, [clearPanel, shownTabId])

  /**
   * Leave the layout behind and go back to one session filling the window.
   *
   * The window that comes back is the pane you were working in, whichever
   * computer that pane's session is on. `paneForTab` is the routing — the same
   * function the strip's ✕ uses, asked the same question: *given an id, where
   * does that window live*. Without it, collapsing a split whose focused pane
   * held a terminal on a server would leave `openServerSession` null, and the
   * unsplit window would fall back to whatever local tab happened to be active
   * — the session you had been typing into replaced by one you had not chosen.
   *
   * The `local` half is what `setMode` used to do on its own. It is here
   * because three other things collapse a split — the palette's swarm toggle,
   * the dashboard's session count, closing the second-to-last pane — and each of
   * them needs the window to land somewhere honest too.
   */
  const closeSplit = useCallback(() => {
    const landing = paneForTab(shownTabId)
    setOpenMachineSession(landing.machine)
    setOpenServerSession(landing.server)
    if (landing.local && shownTabId !== null) {
      setSelection(showTabSelection(shownTabId))
      setActiveSession(shownTabId)
    }
    setPanes(emptyLayout())
  }, [shownTabId, setActiveSession])

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
      // Which window you land on, and the selection that goes with it, is
      // `closeSplit`'s job — see there for why it moved.
      closeSplit()
      setSwarm(false)
      /*
       * `shownTabId`, not `focusedId`: the mode belongs to the session that is
       * on screen, and with a remote or server terminal filling the pane those
       * two are different ids. Writing `focusedId` there set the view of a
       * local tab nobody was looking at — see `shownTabId`.
       */
      if (shownTabId === null) return
      setSessionView((views) => ({ ...views, [shownTabId]: next }))
    },
    [splitPanes, closeSplit, shownTabId, features],
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
      setSelection(showTabSelection(survivor))
      // The survivor can be a page, which the store has no session for.
      if (windowSessionsRef.current.some((session) => session.id === survivor)) {
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
   * The four things a tour is allowed to do to this window, handed over once.
   *
   * Driving mode is mounted in `main.tsx` as a sibling of this component — it
   * has to be, because a panel inside `.app`'s flex row would push `.main`
   * narrower, refit every terminal and reflow the buffers its own highlights are
   * anchored to. Being a sibling means it cannot be passed a callback down a
   * tree it is not in, so it asks a registry instead, and this is the answer.
   *
   * The surface is deliberately four functions rather than this component's
   * command dispatcher. A tour's arguments were composed by a model out of other
   * sessions' transcripts, and a dispatcher takes ids like `session.close`; four
   * named functions cannot be talked into closing a tab, and the reason they
   * cannot is structural rather than a check somebody has to remember to write.
   * See `copilot/driving/navigator.ts`.
   */
  useEffect(
    () =>
      registerNavigator({
        selectTab,
        showPanel: (id, focus) => showPanel(id as PanelId, focus ?? null),
        setSessionMode: (sessionId, mode) => {
          setSessionView((views) => (views[sessionId] === mode ? views : { ...views, [sessionId]: mode }))
        },
        cwdOf: (sessionId) => sessionsRef.current.find((s) => s.id === sessionId)?.projectPath ?? null,
      }),
    [selectTab, showPanel],
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
    const id = focusedTabId(panes)
    if (!id) return
    setSelection(showTabSelection(id))
    /*
     * Only a session reaches the store.
     *
     * A pane can hold a browser page now, and `activeSessionId` is what the
     * composer, the chat bridge and "send this to the agent" all write to —
     * handed a `browser:…` id they would address a pty that does not exist.
     * Leaving it on the last session pane that had focus is not a fallback, it
     * is the right answer: a page beside a terminal sends to that terminal.
     */
    if (windowSessionsRef.current.some((session) => session.id === id)) setActiveSession(id)
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
      {
        id: 'session.new',
        title: 'New session…',
        group: 'Session',
        run: () => openNewSessionDialog(),
      },
      /*
       * Continue-last-session, offered only to an agent that has one.
       *
       * *"'Continue last conversation' is agent-specific"* — and it is worse
       * than agent-specific, it is silently so. `host-core.ts` spawns with
       * `input.resume && resumeArgs.length > 0 ? resumeArgs : args`, so asking
       * Gemini or a plain shell to continue starts a **fresh** session and says
       * nothing: the command appears to work and quietly does something else.
       * That is the class of defect he names more than any other.
       *
       * The section in the New session dialog is gone entirely (see
       * `NewSessionDialog.tsx` for why a real conversation picker cannot be
       * built on `CreateSessionInput` as it stands). This row is not that
       * section — it is a named command with exactly one answer, which is the
       * distinction `openNewSessionDialog` already draws — so it survives, and
       * is simply absent on an agent it cannot act for. A control that cannot
       * act is removed, not left looking live.
       */
      ...(canResumeDefault
        ? [{ id: 'session.resume', title: 'Continue last session', group: 'Session', run: () => newSession(undefined, true) }]
        : []),
      {
        id: 'project.open',
        title: 'Open a project',
        group: 'Project',
        run: () => void openProject(),
      },
      {
        id: 'palette.quickOpen',
        title: 'Open a file…',
        group: 'Project',
        run: () => setPaletteMode('files'),
      },
      {
        id: 'view.browser',
        title: 'New browser tab',
        group: 'View',
        run: () => newBrowserTab(),
      },
      {
        id: 'pane.split',
        title: 'Split the window',
        group: 'View',
        run: () => splitPanes(),
      },
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
      // It opens a *window* now, not a view — the copilot is a session and has
      // the chrome of one. The id keeps its `view.` prefix because that is what
      // the feature registry and any menu item dispatch, and renaming it to
      // describe a change the user cannot see would drop it out of both.
      {
        id: 'view.copilot',
        title: copilotSetup.name,
        group: 'View',
        run: () => openCopilot(),
      },
      {
        id: 'view.dashboard',
        title: 'Overview',
        group: 'View',
        run: () => showPanel('overview'),
      },
      {
        id: 'view.files',
        title: 'Files',
        group: 'View',
        run: () => showPanel('files'),
      },
      // `view.search` keeps its id, and therefore its ⌘⇧F chord, while what it
      // opens has moved. Searching past sessions is no longer a page — it is the
      // command palette's `?` sigil, beside `>` for commands. Renaming the id
      // would silently drop the chord out of `keymap.ts`, so the entry stays and
      // its `run` changes.
      {
        id: 'view.search',
        title: 'Search past sessions',
        group: 'View',
        run: () => setPaletteMode('sessions'),
      },
      {
        id: 'view.artifacts',
        title: 'Artifacts',
        group: 'View',
        run: () => showPanel('artifacts'),
      },
      {
        id: 'view.git',
        title: 'Source control',
        group: 'View',
        run: () => showPanel('git'),
      },
      {
        id: 'view.github',
        title: 'GitHub',
        group: 'View',
        run: () => showPanel('github'),
      },
      // The id stays `view.alerts`, and what it opens has moved — the same
      // trade `view.search` above makes, for the same reason. The id is what
      // the feature registry gates on and what a chord would bind to; renaming
      // it to `app.alerts` would drop it out of the registry's `commands` list
      // and out of whatever menu item lands on it, to describe a change the
      // user cannot see. What they can see is that the row no longer takes the
      // window away.
      {
        id: 'view.alerts',
        title: 'Alerts',
        group: 'View',
        run: () => setAlertsOpen(true),
      },
      {
        id: 'view.readiness',
        title: 'AI readiness',
        group: 'View',
        run: () => showPanel('readiness'),
      },
      {
        id: 'view.store',
        title: 'Store',
        group: 'View',
        run: () => showPanel('store'),
      },
      {
        id: 'view.mcp',
        title: 'MCP servers',
        group: 'View',
        run: () => showPanel('mcp'),
      },
      {
        id: 'view.hooks',
        title: 'Hooks',
        group: 'View',
        run: () => showPanel('hooks'),
      },
      {
        id: 'view.sidebar',
        title: 'Show or hide the sidebar',
        group: 'View',
        run: () => sidebar.toggleCollapsed(),
      },
      {
        id: 'view.inspector',
        title: 'Session details',
        group: 'App',
        run: () => setInspectorOpen(true),
      },
      {
        id: 'app.preferences',
        title: 'Settings',
        group: 'App',
        run: () => openSettings(),
      },
      {
        id: 'app.help',
        title: 'Help',
        group: 'App',
        run: () => setHelpOpen(true),
      },
      {
        id: 'app.join',
        title: 'Join a remote session',
        group: 'App',
        run: () => setJoinOpen(true),
      },
      {
        id: 'app.shortcuts',
        title: 'Keyboard shortcuts',
        group: 'App',
        run: () => setShortcutsOpen(true),
      },
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
    openCopilot,
    // The copilot's row is titled with its name, so a rename has to rebuild the
    // list — a palette that went on offering "Copilot" after somebody called it
    // Nova is a search that fails on the word they would type.
    copilotSetup.name,
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
          /*
           * ⌘W closes what is **on screen**, which since 2026-08-18 can be a
           * session on another machine.
           *
           * `activeTab` is the local answer, and while a remote session fills
           * the pane it names a tab you are not looking at — so the chord would
           * have ended a session on this computer while a different one's
           * terminal was in front of you. That was already true before a remote
           * session had a pill, and it was already wrong; giving it a pill is
           * what makes it fixable, because there is now a tab id to name.
           *
           * `openMachineSession` rather than `railActiveTabId`, which says the
           * same thing and is computed several hundred lines below this
           * callback — reading it here would be a temporal-dead-zone throw on
           * the first ⌘W of every launch.
           */
          if (openMachineSession) {
            closeTab(machineTabId(openMachineSession.machineId, openMachineSession.sessionId))
          } else if (openServerSession !== null) {
            /* The same correction for the other kind of elsewhere. It is already
               a tab id, so nothing has to be re-joined; `closeTab` routes it and
               it gets the confirmation every other close in this window gets. */
            closeTab(openServerSession)
          } else if (activeTab) {
            closeTab(activeTab.id)
          }
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
      // ⌘W closes what is on screen, and a session on another machine can be
      // what is on screen. See the `session.close` case.
      openMachineSession,
      openServerSession,
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

  /**
   * The copilot's window, wherever it is drawn.
   *
   * One expression for the two moments it can appear in, because they are the
   * same window: mounted beside the other sessions' terminals once it has a
   * session, and filling the pane on its own for the seconds between the pinned
   * row being pressed and a CLI finishing its launch. Two spellings of it would
   * be two places for a prop to go missing, which is precisely the seam
   * `wiring.test.ts` exists to watch.
   *
   * `mode` is its entry in the same `sessionView` map every other session's mode
   * lives in, written by the same segmented control in the same bar — the whole
   * of what "a window like the others" means here.
   *
   * The fallback is the **terminal**, in both branches, and it used to be the
   * conversation in both. That was visible: press the pinned row and the window
   * opened on an empty chat pane, then swapped to a terminal a second later when
   * `defaultPane` seeded the map. Two panes for one press. `defaultPane` is the
   * one rule now — always the terminal — and this agrees with it before there is
   * a session to seed for, so nothing on screen moves when the seeding lands.
   */
  const copilotMode: SessionViewMode =
    copilotSessionId === null ? 'terminal' : sessionView[copilotSessionId] ?? 'terminal'
  const copilotWindow = (visible: boolean) => (
    <CopilotView
      copilot={copilot}
      visible={visible}
      mode={copilotMode}
      focus={copilotTurn}
      startedSessions={copilotStarted}
      onOpenSession={selectTab}
      /* Which machine this page is about, for the bar above it. Spelled as a
         plain prop rather than a conditional spread so `wiring.test.ts` can see
         it: this is exactly the seam that guard was written to watch, and the
         bar drawing the local copilot's Restart over another machine's
         conversation is what happens when it goes missing. */
      onMachine={onCopilotMachine}
      fontSize={terminalFontSize}
      fontFamily={terminalFontFamily}
      copyOnSelect={copyOnSelect}
    />
  )

  /**
   * Why a session on **this** computer has stopped being one, by its id.
   *
   * Looked up rather than taken from whatever record the call site happens to
   * hold, because the three places that mount a local terminal hold three
   * different shapes — the window's own `SessionMeta`, a split pane's, and
   * `SwarmSession`, which carries a status and no exit code at all. One lookup
   * against `windowSessions` is what stops the swarm's cells being the one
   * surface in this window where a dead session still draws a live composer.
   */
  const localSessionEnd = (id: string): SessionEnd | null =>
    endOfLocalSession(windowSessions.find((entry) => entry.id === id)?.exitCode ?? null)

  /**
   * Which folder a local session is in, by id — for the press on its ended card.
   *
   * Looked up for the reason {@link localSessionEnd} is: `SwarmSession` carries
   * an id, a title and a status and no folder at all, so the swarm's cells would
   * otherwise be the one place in the window where "start another one here" had
   * to mean somewhere else.
   */
  const localSessionFolder = (id: string): string | null =>
    windowSessions.find((entry) => entry.id === id)?.projectPath ?? null

  /**
   * Why a pane showing a session on a paired machine has stopped being one.
   *
   * ## Why the window answers this and not the pane
   *
   * Because four of the five answers are facts about the **link**, and a pane
   * holds one session id and no link at all. A machine that is asleep, one that
   * was disconnected from here on purpose, one whose socket fell over and is
   * being redialled, and one that is refusing this desktop until somebody over
   * there approves it are four different events that a person acts on four
   * different ways — and `guest.ts` already publishes enough to tell them apart.
   * `endOfMachineSession` is where that reading lives; this is the lookup in
   * front of it.
   *
   * ## Why the pane survives all of them
   *
   * The prune above only drops a pane when a **connected** machine says the
   * session is gone — *"a link drops and reconnects on its own, and a pane
   * thrown away during those seconds is exactly the reload this list exists to
   * remove."* That is right, and it is also precisely how a live-looking dead
   * screen comes about: the pane stays, the terminal keeps the last frame the
   * far machine painted, and until now nothing on it changed. So the same rule
   * that keeps the pane is what makes this reading necessary.
   */
  const machinePaneEnd = (machineId: string, sessionId: string): SessionEnd | null => {
    const row = machines.machines.find((entry) => entry.machine.id === machineId) ?? null
    return endOfMachineSession(
      row?.machine.name ?? 'that machine',
      row?.link ?? null,
      row?.link?.sessions.find((session) => session.id === sessionId) ?? null,
    )
  }

  /**
   * Which session a set of controls acts on, and on which computer — for any
   * tab, of any of the three kinds.
   *
   * ## Why this is one function
   *
   *   > *"So it should not matter that which session I am in, but all of them
   *   > should show the exactly same things up there, all exact same features."*
   *
   * The window's bar and every guest pane's bar draw the same component,
   * `SessionControls`, and what made them different was not the component — it
   * was three separate expressions working out what to hand it, each written
   * beside the thing it served and each withholding a different piece. This is
   * that answer, asked once. `barControls` below is `controlsFor(barTabId)` and
   * a pane's is `controlsFor(paneTabId)`; there is no third reading anywhere.
   *
   * ## The three branches are three different lookups, not three policies
   *
   * A **server terminal** is found by its tab id in this window's own list of
   * shells, and answers `null` until the far end has handed back an id for the
   * shell — the tab exists from the moment of the click and the shell opens
   * asynchronously, so drawing the cluster before then is four chips saying
   * "Unknown" about a session that has not started. `provider` is `undefined`
   * on purpose rather than as a gap: this app did not launch whatever is in that
   * shell, so `refuseByProvider` is handed the absence it is built around and
   * consults the screen instead. A plain `sh` is refused with a sentence; a
   * `claude` somebody started in there is driven exactly as a local one is.
   *
   * A **session on a paired machine** is found in that machine's own roster, and
   * answers `null` while the link is down — falling through to a local session
   * there would put a local session's model chip on a bar above a remote pane,
   * which is the worst outcome available: a control that looks right and acts on
   * the wrong computer. Its `provider` is narrowed because it arrives as a
   * free-form string off a network; anything unrecognised becomes `undefined`,
   * which means "ask the screen".
   *
   * A **local session** is the case every caller written before any of this
   * meant, and `target: undefined` is what says so.
   */
  const controlsFor = (
    tabId: string | null,
  ): {
    sessionId: string
    cwd: string | null
    provider: ProviderId | undefined
    exited: boolean
    /**
     * Why it ended, in the same words the pane below the bar uses.
     *
     * Alongside `exited` rather than instead of it, because the two answer
     * different questions: `exited` is *may these controls act*, and this is
     * *what happened*. The bar needs the first to decide whether to draw a
     * control at all and the second only to put a sentence on the word that
     * replaces them.
     */
    end: SessionEnd | null
    target: ControlsTarget | undefined
  } | null => {
    if (tabId === null) return null
    if (readServerTabId(tabId)) {
      const row = serverSessions.find((entry) => entry.tabId === tabId) ?? null
      const shellId = serverShellIds[tabId]
      if (row === null || shellId === undefined) return null
      return {
        sessionId: shellId,
        cwd: null,
        provider: undefined,
        // The one fact this window genuinely observes about a server shell:
        // `servers:shell:closed` fired. There is no exit code on that channel
        // and none is invented here.
        exited: row.status === 'exited',
        // And no *cause* is invented either — `shellGone` is the vocabulary's
        // word for exactly this: a channel that closed, with the two things
        // that could have closed it named rather than one of them guessed.
        end: row.status === 'exited' ? shellGone(row.serverName) : null,
        target: { kind: 'server' },
      }
    }
    const remote = readMachineTabId(tabId)
    if (remote) {
      const row = machines.machines.find((entry) => entry.machine.id === remote.machineId) ?? null
      const live = row?.link?.sessions.find((session) => session.id === remote.sessionId) ?? null
      if (live === null) return null
      return {
        sessionId: live.id,
        cwd: null,
        provider: isProviderId(live.provider) ? live.provider : undefined,
        exited: live.exitCode !== null,
        // The same reading the pane below this bar draws its card from. Only the
        // `online` branch of it can be reached here — a link that is down
        // returns `null` from the lookup above, which withdraws the cluster
        // entirely rather than leaving chips over a machine nobody can reach.
        end: machinePaneEnd(remote.machineId, remote.sessionId),
        target: { kind: 'machine', machineId: remote.machineId },
      }
    }
    const local = windowSessions.find((entry) => entry.id === tabId) ?? null
    if (local === null) return null
    return {
      sessionId: local.id,
      cwd: local.projectPath ?? null,
      provider: local.provider,
      /* The session's real exit code, never a literal. The cluster reads the
         screen to tell a shell with an agent in it from a plain one, and a
         killed CLI leaves its banner on the last frame — so a hardcoded `false`
         would keep live model and effort chips on the bar of a session whose
         process is already gone. */
      exited: local.exitCode !== null,
      end: endOfLocalSession(local.exitCode),
      target: undefined,
    }
  }

  /**
   * Which computer a tab's session runs on, when it is not this one.
   *
   * Read off the tab rather than by taking its id apart, because the tab is
   * where the machine's *name* is — `machineTabs` and `serverTabs` both carry it
   * — and a pane bar has to print a name, not an id. Null for one of this
   * window's own sessions, a browser page or the copilot, which is the test
   * every caller here actually wants.
   */
  const paneWhere = (tab: WorkspaceTab): { tab: WorkspaceTab; where: string } | null =>
    tab.machine
      ? { tab, where: tab.machine.name }
      : tab.server
        ? { tab, where: tab.server.name }
        : null

  const mainView = () => {
    /*
     * A terminal on a server is on screen, and this function draws nothing.
     *
     * First, and the *nothing* is the point. Every other pane in this window is
     * mounted by this function and unmounted when something else takes the pane
     * — which is safe for all of them, because a local terminal is redrawn from
     * the main process's scrollback, a browser page lives in the main process,
     * and a session on a paired machine is replayed by that machine when this
     * end attaches again. A shell on a server has none of those: nothing at the
     * far end is keeping it, and nothing on this side is recording what it
     * printed. So its pane is mounted beside this one, for as long as its tab
     * exists, and hidden rather than unmounted — see the block at the bottom of
     * this component and the note on `ServerSessionPane`.
     *
     * Returning null rather than falling through matters. Without it the branch
     * below would mount every local terminal and show whichever one `activeTab`
     * fell back to, underneath an opaque pane — a terminal nobody can see, with
     * the keyboard, taking keystrokes meant for the server.
     *
     * **Unless the window is split.** A split names what every pane holds, on
     * whichever computer, and the server pane is placed over the hole its own
     * pane leaves rather than over the whole frame — see `layout/pane-slots.ts`.
     * Returning null here regardless is what made splitting over a server
     * terminal draw an empty window: this function is the only thing that mounts
     * `SplitView`, so a `splitPanes()` from the command palette (which nothing
     * blocked) left a window with a mode switch reading Split and nothing under
     * it.
     */
    if (!splitting && openServerSession !== null) return null
    /*
     * A session on another machine is on screen, and this function draws
     * nothing — for the reason the branch above draws nothing for a server.
     *
     * Its pane used to be *returned from here*, and that placement is half of
     * what he filmed: `mainView` draws one thing, so a trip to Files or Settings
     * unmounted the terminal, detached from the far machine, and made coming
     * back a fresh attach and a fresh replay. *"If I go to other page and come
     * back, it will start from beginning again."* The panes are mounted beside
     * this one now and hidden — see `machineSessionPanes` and the block at the
     * bottom of this component.
     *
     * Still decided above the panel branch, because that ordering is the
     * feature: his complaint about remote was that it lived on a page of its own
     * with its own vocabulary — *"the Remote page is for connecting only, not
     * controlling"* — and opening one from the rail puts it where every other
     * session goes, in the same frame, in the same terminal, with the same
     * theme.
     *
     * And below the split, for the reason the branch above is: a pane holding a
     * remote session is a pane, and the layout has to be drawn for it to have
     * one.
     */
    if (!splitting && openMachineSession !== null && machines.bridge !== null) return null
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
          /* How a page sends the window to another one. The MCP page's Store
             control uses it, so there is one store and several doors into it. */
          onShowPanel={showPanel}
          /* There was a `copilot` object here. It went with the copilot's page:
             the copilot is a window now, rendered beside the other sessions'
             terminals further down this file, because that is where a session is
             rendered. See `copilot/identity.ts`. */
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

    /*
     * The copilot, asked for and not started yet.
     *
     * Above the empty branches because it is the one case where the window has
     * something to show and no tab to show it from: spawning the copilot is a
     * CLI launch, its tab is derived from the running session, and without this
     * the pinned row would be a press that produced nothing on screen for
     * several seconds. `CopilotView` draws its own "Starting the copilot…" here,
     * and — if the start refuses — the CLI's own sentence with the button that
     * retries it, which is exactly the state that must not be invisible.
     */
    if (copilotPending && copilotSession === null) return copilotWindow(true)

    /*
     * A launch, with nothing open anywhere — and the launch screen is a door:
     * open a project.
     *
     * Split from the *emptied* window below, which used to be the same branch
     * and is not the same state. Here there is genuinely nothing; there, four
     * agents are running and the person has taken the last tab off the bar.
     */
    if (tabs.length === 0) return <EmptyState onOpenProject={openProject} />

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
          //
          // Through the dialog, like every other New session in this window.
          // *"It is not asking me for this kind of pop-ups when I am opening
          // from here. Everywhere it should be consistent and it should be
          // asking same things to me."* This one spawned straight into the
          // active folder on the default agent — the exact behaviour he was
          // objecting to, surviving in the two places nobody had looked.
          onNewSession={() => openNewSessionDialog()}
          renderCell={({ session }) => (
            <TerminalView
              sessionId={session.id}
              visible
              fontSize={terminalFontSize}
              fontFamily={terminalFontFamily}
              copyOnSelect={copyOnSelect}
              /* Off the record rather than off the exit *event*, so the mark
                 survives the pane being rebuilt — see the prop's own note. */
              end={localSessionEnd(session.id)}
              /* The press on the ended card, through the same dialog every other
                 New session in this window opens — on this session's folder. */
              onReopen={() => openNewSessionDialog(localSessionFolder(session.id))}
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
            const paneTab = tabId ? openTabs.find((entry) => entry.id === tabId) ?? null : null
            /*
             * `openTabs`, not `tabs`, and that one word is most of what makes a
             * server terminal splittable at all.
             *
             *   > *"Like I cannot even split"* / *"I cannot make it to the chat
             *   > view"*
             *
             * `tabs` is this window's own sessions and pages. A pane holding a
             * session on a paired machine or a terminal on a server found
             * nothing in it, so it drew "Nothing in this pane yet" over a live
             * terminal — which is why the refusal upstream was honest at the
             * time and is not any more.
             */
            const elsewhere = paneTab === null ? null : paneWhere(paneTab)
            const sessionTab = paneTab?.kind === 'session' && elsewhere === null ? paneTab : null
            const pageTab = paneTab?.kind === 'browser' ? paneTab : null
            const session = sessionTab
              ? windowSessions.find((entry) => entry.id === sessionTab.id) ?? null
              : null
            /* The same expression the window's own bar uses, asked about this
               pane's tab. One function, three kinds — see `controlsFor`. */
            const paneControls = controlsFor(elsewhere ? elsewhere.tab.id : session?.id ?? null)

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
                      elsewhere
                        ? {
                            kind: 'elsewhere',
                            title: tabLabel(elsewhere.tab, openTabs),
                            where: `on ${elsewhere.where}`,
                            status: elsewhere.tab.status ?? 'idle',
                          }
                        : session && sessionTab
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
                            // The same pair the window's bar passes, about this
                            // pane's own session. Without them a guest pane
                            // would keep opening a *third* session while the
                            // pane the click happened in carried on unchanged.
                            chrome: chromeSession(session.id, sessions),
                            onSwitchAccount: (sessionId, accountId) =>
                              switcher.ask({ sessionId, profileId: accountId }),
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
                      paneControls ? (
                        <SessionControls
                          sessionId={paneControls.sessionId}
                          cwd={paneControls.cwd}
                          provider={paneControls.provider}
                          /* Never a literal. `controlsFor` computes it per kind
                             from the record that actually knows — this window's
                             session list, the far machine's roster, the server
                             shell's own status. The cluster reads this pane's
                             screen to tell a shell with an agent in it from a
                             plain one, and a killed CLI leaves its banner on the
                             last frame, so a hardcoded `false` would keep live
                             model and effort chips on the bar of a session whose
                             process is already gone. */
                          exited={paneControls.exited}
                          /* And why, so the word that replaces the chips carries
                             the same sentence the card in the pane does. */
                          end={paneControls.end}
                          onOpenConnectors={openConnectors}
                          /* Which computer this pane's session is on. `undefined`
                             for one of this window's own, which is what every
                             caller written before there were three kinds meant. */
                          target={paneControls.target}
                        />
                      ) : undefined
                    }
                  />
                )}
                <div className="pane-cell-body">
                  {elsewhere ? (
                    /*
                     * The hole a terminal that lives elsewhere is drawn over.
                     *
                     * Empty, deliberately. The terminal itself is mounted beside
                     * the pane tree, for as long as its tab exists, because
                     * unmounting it either replays a whole scrollback over the
                     * relay or closes an SSH shell for real — see
                     * `layout/pane-slots.ts` for the measurement, and the block
                     * at the bottom of this component for the mounts. This
                     * element is what tells it where to be.
                     */
                    <div className="pane-remote-slot" {...{ [SLOT_ATTR]: elsewhere.tab.id }} />
                  ) : session ? (
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
                      end={localSessionEnd(session.id)}
                      onReopen={() => openNewSessionDialog(localSessionFolder(session.id))}
                    />
                  ) : pageTab ? (
                    /*
                     * A live page, in a pane, beside a terminal — drawn over
                     * this hole rather than inside it.
                     *
                     * It used to be mounted right here, and that was the last
                     * page in the app that still reloaded when somebody did
                     * something else. Unmounting a `BrowserWorkspace` closes its
                     * `WebContentsView` for real, so moving the page out of the
                     * always-mounted list below and into this subtree was a
                     * remount: press Split and the site you were reading
                     * reloaded, at its start address, under a person who asked
                     * for a layout and not for a refresh. Leaving the split did
                     * it again, in the other direction.
                     *
                     * So the pane keeps the page's *place* and nothing else. The
                     * panel stays mounted where it was, this measures the hole,
                     * and `layout/pane-slots.ts` hands it the rectangle — the
                     * same arrangement a session on a paired machine and a shell
                     * on a server already have, and its note is the argument for
                     * it, including why a portal is not the answer.
                     */
                    <div className="pane-remote-slot" {...{ [SLOT_ATTR]: pageTab.id }} />
                  ) : (
                    // An instruction, not a placeholder. The sidebar fills the
                    // focused pane, so the first sentence names something that
                    // is one click away on the left; the button is the other
                    // half, for the case this pane exists to serve — you split
                    // the window in order to run a second agent, and there is
                    // not a second one yet.
                    <PageEmpty
                      title="Nothing in this pane yet"
                      // The dialog, like every other New session — see the
                      // swarm grid's opener above for his words on it. The
                      // empty pane below this branch already went through the
                      // dialog, so this pane and that one were asking different
                      // questions for the same press.
                      action={{
                        label: 'New session',
                        onClick: () => openNewSessionDialog(),
                      }}
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

    /*
     * The window, emptied on purpose.
     *
     * Asad, 2026-08-17: *"if there are three or two windows open and I close all
     * of them, the last one I will not be able to close from the top bar."* It
     * came straight back because a null selection resolved to `tabs[0]`, and
     * `shownTabs` always draws whatever is active — so the ✕ redrew the tab it
     * had just removed. Now the pane goes to its own empty state, the same
     * "Nothing in this pane yet" a split pane shows, because it is the same
     * situation: nothing is closed, every session is still running and one click
     * away in the rail, and the strip above still holds its two openers.
     *
     * Below `swarm` and `splitting` on purpose. Both of those draw sessions the
     * strip's selection has nothing to do with — a grid of every terminal, or a
     * hand-made layout of panes — and taking the last pill off the bar must not
     * throw away an arrangement that is still on screen and still holding two
     * agents. Above it, this branch would have done exactly that.
     */
    if (!activeTab) {
      return (
        <PageEmpty
          title="Nothing in this pane yet"
          action={{
            label: 'New session',
            onClick: () => openNewSessionDialog(),
          }}
        >
          Pick a session in the sidebar and it opens here.
        </PageEmpty>
      )
    }

    /*
     * Every terminal stays mounted and is shown or hidden, so a session keeps
     * its scrollback when you switch away and come back.
     *
     * The browser pages used to be mounted here too, and that placement is the
     * whole of what he filmed on 2026-08-20: *"if this link is loaded, page is
     * loaded, I go to session. If I come back, this is all gone, so it
     * refreshes."* This function returns **one** thing, and half a dozen
     * branches above return before this one — a session on a paired machine, a
     * terminal on a server, a sidebar view, a split, the swarm grid — so
     * whichever of them took the frame unmounted every page in the window at
     * once, and unmounting a `BrowserWorkspace` closes its `WebContentsView`
     * for real (see the cleanup effect in that file). Coming back mounted a new
     * component, which opened a new blank tab.
     *
     * Measured before it was moved, on a machine with nothing remote paired to
     * it at all: with `http://example.com/` loaded in a page, clicking **Files**
     * in the rail took the guest target out of `/json/list` entirely, and
     * clicking the page's own tab again brought back `about:blank` and an empty
     * address bar. Switching to a *local* session, which falls through to this
     * branch, left the target alive. So the remote session he was looking at is
     * a trigger and not the cause — the cause is being drawn from a function
     * that draws one thing.
     *
     * They are mounted beside the pane now, in `.panes`, exactly as the server
     * shells and the remote sessions already are and for the identical reason.
     */
    return (
      <>
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
                end={localSessionEnd(session.id)}
                onReopen={() => openNewSessionDialog(localSessionFolder(session.id))}
              />
              {active && mode === 'chat' ? (
                <ChatView
                  cwd={session.projectPath ?? null}
                  // Which conversation this pane is a view of. Without it the
                  // pane reads the folder's newest transcript, which is any
                  // `claude` running here — including ones this app did not
                  // start.
                  session={{
                    startedAt: session.createdAt,
                    resumed: session.resumed,
                    // And, where this app named the conversation itself, the
                    // name — which turns the attribution from a deduction about
                    // clocks into a file lookup. See `SessionScope`.
                    ...(session.agentSessionId === undefined
                      ? {}
                      : { agentSessionId: session.agentSessionId }),
                  }}
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
                    //
                    // Through `sendToTerminal`, and never as one write with a
                    // `\r` on the end. The CLI classifies a stdin chunk of 64
                    // bytes or more as pasted text, where a carriage return is a
                    // newline rather than submit — so the single-write form put
                    // every message longer than half a line into the agent's
                    // input box and left it there. Measured in the packed app on
                    // 2026-08-22 and photographed; see `mentions.ts`.
                    void sendToTerminal(text, (data) =>
                      window.deck.writeToSession(session.id, data),
                    )
                  }}
                />
              ) : null}
            </Fragment>
          )
        })}
        {/*
          The copilot, mounted beside them and hidden the same way.

          Not in the `sessions` map above, because it is not one of the project's
          sessions — see the two lists at the top of this component — and because
          it has a little to say that no other session does: a sign-in
          explanation on a first run, the turn that opened it, the tours it drove.
          `CopilotView` draws those above its pane and nothing at all when there
          is nothing to say, which is the ordinary case.

          Mounted whenever it is running rather than only while it is in front,
          for the same reason every terminal above is: a remount redraws from the
          main process's scrollback, and a login prompt somebody is halfway
          through would scroll away under them.

          `mode` is its entry in the same `sessionView` map, written by the same
          segmented control in the same bar. That is the whole of what "a window
          like the others" means here — there is no second switch and no second
          piece of state.
        */}
        {copilotSession && copilotWindow(copilotOnScreen)}
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
    ? /* `openTabs`, not `tabs`: a pane can hold a session on a paired machine or
         a terminal on a server now, and looked up in this window's own list
         those come back `null` — a split whose host pane held a server shell
         drew a bar with no name, no controls and no folder over a live
         terminal. */
      (hostPane?.tabId ? openTabs.find((tab) => tab.id === hostPane.tabId) ?? null : null)
    : activeTab

  /**
   * The tab the window's own bar acts on.
   *
   * The **host** pane while split — see `hostPane` for why the bar belongs to
   * the pane with no box rather than to the focused one — and whatever is on
   * screen otherwise, on whichever computer. One id, handed to `controlsFor`, so
   * the cluster on this bar and the name beside it cannot come to be about two
   * different sessions.
   */
  const barTabId: string | null = splitting ? hostPane?.tabId ?? null : shownTabId

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
  /**
   * The remote session on screen, as the bar names it.
   *
   * Read from the machines view rather than remembered beside the id, because
   * the far machine renames its own sessions — an agent that titles itself, a
   * session that exits — and a name captured when the row was clicked would go
   * stale on a screen whose whole claim is that it feels like a local one.
   */
  const openMachine = openMachineSession
    ? machines.machines.find((row) => row.machine.id === openMachineSession.machineId) ?? null
    : null
  const openRemoteSession = openMachine?.link?.sessions.find(
    (session) => session.id === openMachineSession?.sessionId,
  )

  /**
   * Whose login that remote session is running as, and the logins that machine
   * has to offer instead.
   *
   * Asad, 2026-08-20: *"Then also bring the account selection here for the
   * remote sessions too."* Read from the far machine rather than resolved here,
   * which is the whole of it — see `machines/machine-account.ts`. Null and null
   * for a local session, where the chip below has its own sources.
   */
  const machineAccount = useMachineAccount(
    openMachineSession?.machineId ?? null,
    openMachineSession?.sessionId ?? null,
  )
  /** A switch in flight over the wire, which makes every row inert while it runs. */
  const [machineSwitching, setMachineSwitching] = useState(false)
  /**
   * What the far machine said about a switch that did not happen.
   *
   * Transient and only ever after a press. It is not a caption: the rule he
   * repeated most is about sentences that sit on screen explaining things
   * nobody asked, and this appears because somebody pressed a row and the
   * answer was no — which is the one case the same review insists must never be
   * silent. It clears itself, because an outcome nobody is waiting for any more
   * is clutter.
   */
  const [machineSwitchProblem, setMachineSwitchProblem] = useState<string | null>(null)
  useEffect(() => {
    if (machineSwitchProblem === null) return
    const timer = setTimeout(() => setMachineSwitchProblem(null), 8000)
    return () => clearTimeout(timer)
  }, [machineSwitchProblem])

  /**
   * Run the remote session on screen as one of that machine's other logins.
   *
   * The far end performs the same switch its own window performs — same plan,
   * same conversation guard, same survival probe — and answers with the id the
   * session has afterwards, because a switch replaces the process. Following
   * that id is what keeps the pane pointed at the session it was pointed at:
   * without it this window would sit attached to a pty that machine has already
   * killed.
   */
  const switchMachineSession = useCallback(
    (machineId: string, sessionId: string, accountId: string) => {
      setMachineSwitching(true)
      setMachineSwitchProblem(null)
      void switchMachineAccount(machineId, sessionId, accountId)
        .then((answer) => {
          setMachineSwitching(false)
          if (!answer.ok) {
            setMachineSwitchProblem(answer.message === '' ? 'That account could not be used.' : answer.message)
            return
          }
          /*
           * Nothing is announced on success, on purpose. The chip above the
           * terminal now reads the other account and the conversation is the one
           * that machine resumed — that *is* the feedback, and a banner for
           * something he asked for and can already see would be the app
           * congratulating itself. The local switch takes the same position.
           */
          if (answer.session !== null && answer.session !== sessionId) {
            setOpenMachineSession((current) =>
              current && current.machineId === machineId && current.sessionId === sessionId
                ? { machineId, sessionId: answer.session as string }
                : current,
            )
          }
          // The far list has a new row and has lost one. Its own push says so —
          // see `RemoteEndpoint.sessionsChanged` — and this asks as well, because
          // the pane on screen is pointed at the new id already and a list that
          // has not caught up would prune it.
          machines.reread()
          machineAccount.reload()
        })
        .catch(() => {
          setMachineSwitching(false)
          setMachineSwitchProblem('That machine did not answer.')
        })
    },
    [machineAccount, machines],
  )

  /**
   * The terminal on a server the bar is naming, when it is naming one.
   *
   * Found in the tab list rather than remembered beside the id, exactly as the
   * remote one above is, so that the bar and the rail cannot come to disagree
   * about what a row is called — `serverTabs` builds both from one list.
   */
  const openServerTab = openServerSession
    ? serverSessionTabs.find((tab) => tab.id === openServerSession) ?? null
    : null

  const heading = openServerTab
    ? {
        /*
         * Its own number, and the server underneath.
         *
         * `tabLabel` rather than `labelOf`, because `labelOf` numbers a session
         * among the tabs *this window owns* and a shell on a server is not one
         * of those — it would have been counted against local sessions in a
         * folder it has nothing to do with. `tabLabel` counts siblings on the
         * same machine, which for these is the other terminals on the same
         * server, and is the same function the strip and the rail use. Three
         * surfaces, one number.
         *
         * No `folder`: a shell on a server starts wherever that sign-in lands
         * and this app has not asked where that is, so there is nothing true to
         * put on a chip that opens a path on *this* computer. And no `account`,
         * for the reason the whole control cluster is withdrawn below.
         */
        title: tabLabel(openServerTab, openTabs),
        subtitle: openServerTab.server ? `on ${openServerTab.server.name}` : null,
        folder: null,
        account: null,
      }
    : openMachineSession
    ? {
        // Its own title, and the machine underneath — the one fact that makes
        // this window different from the identical-looking local one above it.
        //
        // The folder *is* passed now, and the paragraph that used to be here
        // saying it must not be was arguing from a file that has since changed
        // underneath it. It read: "`FolderChip` opens a path on this computer,
        // and a chip that opened nothing would be the dead control this whole
        // pass is removing." That was true of the dropdown; the dropdown went on
        // 2026-08-16 and what is exported now is `FolderTitle`, a mono `<span>`
        // with a tooltip that opens nothing at all. So there is no dead control
        // to avoid, and withholding it was costing a real thing: the far
        // machine's path was being smeared into this subtitle in proportional
        // text while every local session got it on the chip. Same fact, same
        // chip, same place — which is the whole of what was being asked for.
        //
        // The machine's name stays in the subtitle slot, because `meta` replaces
        // the subtitle rather than joining it and losing which computer this is
        // running on would be a far worse trade than the one just made.
        title: openRemoteSession?.title ?? 'Session',
        subtitle: openMachine ? `on ${openMachine.machine.name}` : null,
        folder: openRemoteSession?.cwd ?? null,
        // No login, and this one really is absent. Which account an agent was
        // spawned under is not a fact any frame on the wire carries, and the
        // chip is a menu whose every row acts on a local session. See the note
        // that stands in the control cluster's place on the bar.
        account: null,
      }
    : showingPanel && panel
    ? // No subtitle. Each view used to print a sentence here — "Browse the
      // project and read any file in it." under a page called Files — and the
      // whole set is deleted rather than reworded; `shell/panels.ts` carries
      // the argument and no longer has a field to hold one.
      { title: panelSpec(panel).label, subtitle: null, folder: null, account: null }
    : headingTab?.isCopilot && copilotMachine !== null
      ? /*
         * The copilot, with its page switched to another machine.
         *
         * Its own name — the copilot is named per install and the far one has a
         * name of its own, but nothing on `copilot.chat` carries it, and
         * inventing a second name for this window would be worse than reusing
         * the one on the tab — and the machine underneath, in the slot a remote
         * *session* already puts its machine in. That subtitle is the whole
         * reason this branch exists: which computer is on screen is the fact
         * that must never go missing.
         *
         * No folder and no account, and they are the same absence. The folder
         * chip would name this Mac's copilot directory over a PC's conversation,
         * and which account that PC's copilot runs as is not a fact any frame
         * carries. See `copilotMachine`.
         */
        {
          title: labelOf(headingTab),
          subtitle: `on ${copilotMachine.name}`,
          folder: null,
          account: null,
        }
      : headingTab
      ? {
          /*
           * `tabLabel` for a window on another computer, `labelOf` for one of
           * this window's own.
           *
           * `labelOf` numbers a session among the tabs *this window owns*, which
           * for a shell on somebody's server is a number counted against local
           * sessions in a folder it has nothing to do with. `tabLabel` counts
           * siblings on the same machine — the other terminals on that server,
           * the other sessions on that PC — and is the same function the strip
           * and the rail use, so three surfaces print one number.
           *
           * Only reachable while the window is split, because unsplit the tab in
           * front is resolved from this window's own list and the two branches
           * above already name a remote session and a server terminal. It is
           * written for both kinds anyway rather than for the server alone: a
           * host pane holding a remote session is the same situation and the
           * next person to open this file should not have to discover that.
           */
          title:
            headingTab.machine || headingTab.server ? tabLabel(headingTab, openTabs) : labelOf(headingTab),
          // Which computer it is on — the one fact that makes this bar
          // different from the identical-looking local one.
          subtitle: headingTab.machine
            ? `on ${headingTab.machine.name}`
            : headingTab.server
              ? `on ${headingTab.server.name}`
              : null,
          // The path is a control now rather than a caption — see FolderChip.
          folder: headingTab.kind === 'session' ? headingTab.projectPath ?? null : null,
          // And so is the account, beside it — see AccountChip. Null for a
          // session that has none, where the chip falls back to saying which
          // account a *new* session here would use.
          account: headingTab.kind === 'session' ? headingTab.account ?? null : null,
        }
      : copilotPending
            ? // The copilot, starting, with no tab yet. It is named because there is
              // something true to name — the window below is its own starting state —
              // and because a bar reading "Terminal Deck" over it would say the app
              // had nothing open while a CLI was being spawned three lines down.
              {
                title: copilotSetup.name,
                subtitle: null,
                folder: null,
                account: null,
              }
            : splitting || tabs.length > 0
              ? // Two states with one right answer, which is to say nothing.
                //
                // A split whose host pane has not been filled: printing the app's own
                // name over an empty pane would read as "nothing is open" while two
                // sessions run beside it, and falling back to the *guest's* name is the
                // claim this bar must never make. The pane's body already says what it
                // is; the bar keeps the mode switch, which is the only way back out.
                //
                // And, since 2026-08-17, a window whose last tab has been taken off the
                // bar. Every session is still running and still in the rail, so the app's
                // name would be as wrong here as it is over an empty pane — and naming
                // whichever session happens to be first is precisely the fallback that
                // made the ✕ on the last tab look broken.
                { title: null, subtitle: null, folder: null, account: null }
              : // No subtitle. "Nothing open yet." is the sidebar's line, and it is there to
                // explain why the list beneath it is empty — a job this heading does not
                // share. Saying it here too put the same sentence on screen twice, a few
                // centimetres apart, while the page in the middle was already explaining
                // the same emptiness with a button. The title alone is enough.
                {
                  title: BRAND.name,
                  subtitle: null,
                  folder: null,
                  account: null,
                }

  /**
   * The folder the heading's two chips act on.
   *
   * Bound to a `const` rather than read off `heading` at each use so it narrows
   * inside the callbacks: a property access is re-widened inside a closure, and
   * both chips hand this folder to a callback that starts a session in it.
   */
  const headingFolder = heading.folder

  /**
   * Which login the coding agent in that server account's home is signed in as,
   * for the bar over a terminal on a server.
   *
   * ## It is not this session's account, and the chip says what it is instead
   *
   * Every other bar in this app names the account its session runs under because
   * this app started that session. Nothing on the SSH side carries it. A
   * transcript line records `cwd`, `gitBranch`, `version` and its own
   * `sessionId` and says nothing whatever about a login, and this app did not
   * spawn whatever somebody typed into that terminal.
   *
   * This slot used to conclude "so there is no honest account *chip* here" and
   * drew a plain word. Asad, inside exactly this bar: *"when I am inside the
   * server, I cannot even change the accounts."* The conclusion mistook one
   * impossible verb for all of them: switching *this* terminal's agent is
   * indeed not on offer and the menu says so in as many words, but starting a
   * new terminal on that server with one of its signed-in agents running is
   * real, and so is going to where the sign-ins are changed. See
   * `ServerAccountChip` for the whole argument.
   *
   * It costs no round trip of its own — `servers:shell:account` reads it out of
   * the probe the server page already runs, and answers null only while the
   * first ask is in flight, which is the one moment there genuinely is nothing
   * to say. Null draws nothing at all, the same silent degrade the connectors
   * chip beside it makes.
   */
  const headingServerTabId = openServerTab?.id ?? (headingTab?.server ? headingTab.id : null)
  const serverSignIn = useServerSignIn(
    serversBridge,
    headingServerTabId === null ? null : serverShellIds[headingServerTabId] ?? null,
  )
  /**
   * The server under the heading — id for the verbs, name for the sentences.
   *
   * Whichever of the two the bar is naming: the pane on screen, or a server
   * tab that is the heading without being the open pane.
   */
  const headingServer = (openServerTab ?? headingTab)?.server ?? null

  /**
   * The session the window's control cluster acts on, and which computer it is on.
   *
   * ## What this replaces, and why it is one object rather than three mounts
   *
   * The bar used to draw the control cluster only when
   * `openMachineSession === null && openServerSession === null`, with a
   * paragraph explaining that the model, the effort and fast mode are read off a
   * *local* pty by *local* session id and that no frame on the wire carried any
   * of them. Both halves of that were true and neither is any more:
   * `CAPABILITY.controls` carries the question to a paired machine, and
   * `servers:controls:*` drives the same two functions against the SSH channel a
   * server terminal already is. Asad asked for this three times, most recently:
   *
   *   > *"I still don't see all of these things inside like this header with
   *   > model, high effort and all of these things — I don't see it in server
   *   > sessions and in the remote sessions both."*
   *
   * One object feeding one mount, rather than three mounts with three gates,
   * because *"the same identical options"* is a claim about sameness — three
   * call sites are three things to keep in step, and the first one to drift
   * would be the remote one nobody looks at.
   *
   * ## The branches moved, and that is the point
   *
   * They used to be spelled out here, three of them, and a guest pane's bar had
   * a fourth copy of the local one — so a pane could never hold a session on
   * another computer, because the only expression that knew how to reach one
   * lived in the window's bar. They are `controlsFor` now, above `mainView`,
   * where both callers can see it: this line and every pane. What is left here
   * is the two gates that are genuinely about the *window* rather than about a
   * session — the swarm grid and a sidebar view, neither of which has a session
   * bar for the cluster to sit on.
   *
   * `cwd` is null for both remote branches, in there. It is only ever used for
   * two things — the transcript the model is read from, and the folder the
   * connectors are resolved in — and both are files on **this** computer. A
   * paired machine reads its own; a server has none here. Passing a far path
   * would have resolved this machine's project connectors under somebody else's
   * session on any machine where the two happen to share a checkout path.
   */
  const barControls =
    swarm ||
    showingPanel ||
    /* The copilot's page, switched to another machine. The tab is this window's
       own — so `controlsFor` would find this Mac's copilot session and draw a
       model picker for it — while the pane underneath is a conversation on a
       PC. `headingSession` used to carry this guard; it is here now because
       this is the only thing that was still reading it. */
    (headingTab?.isCopilot === true && copilotMachine !== null)
      ? null
      : controlsFor(barTabId)

  /**
   * Which segments of the mode switch cannot act on what is on screen, and why.
   *
   * ## Why the switch is drawn at all now
   *
   * It used to vanish over a session on a paired machine or a terminal on a
   * server, and vanishing was wrong for the segment that works: **Terminal is
   * exactly what both of those are already showing**. Withdrawing the whole
   * control because two of its three answers were unreachable left an empty
   * stretch of toolbar, and an empty stretch of toolbar cannot tell "not built"
   * from "not possible".
   *
   * ## Split is no longer one of them
   *
   *   > *"Like I cannot even split"*
   *
   * It said: *"Split arranges this window's own panes, and a terminal on a
   * server is mounted beside them so its scrollback survives being switched away
   * from."* Both halves of that were true and the conclusion was not. The panes
   * hold every kind of tab now, and a terminal that has to stay mounted is drawn
   * over the hole its own pane leaves rather than being moved into it — see
   * `layout/pane-slots.ts`. Nothing about the scrollback changed; what changed
   * is that the pane tree stopped being the only thing allowed to say where a
   * rectangle is.
   *
   * ## Chat is no longer one of them either
   *
   * Chat renders a conversation out of the agent's own transcript file. For a
   * session on a **paired machine** that file is read by the machine it is on
   * and the collapsed bubbles travel — `chat.read` / `chat.rows`, the same wire
   * the phone client already uses.
   *
   * For a terminal on a **server** the sentence here used to say that there was
   * a pty over SSH and nothing that read the far filesystem, *"so the transcript
   * would have to be found and tailed over that channel."* That was an accurate
   * description of a hole rather than a reason, and it is what has been done:
   * `servers/chat.ts` finds the file — by matching each transcript's own first
   * line against the moment this window opened the shell, which is the same
   * deduction `session-transcript.ts` makes locally out of birth times — and
   * `connection.ts` reads byte ranges out of it over SFTP as the agent appends.
   *
   * Two things still refuse, and both name what is missing rather than a mode:
   * a preload with no such channel, and a terminal the server has not answered
   * for yet. Neither is a wording choice — `serverChatWired` is a question about
   * *this build*, and a shell with no far id has nothing to read from.
   *
   * ## Keyed on what is on screen
   *
   * `shownTabId`, like the `view` beside it. These two used to come from
   * different places — the sentence from the window's `openMachineSession`, the
   * view from the local focused tab — so the switch could be live over a session
   * it was refusing to act on and refuse over one it was not showing.
   */
  const shownIsServer = shownTabId !== null && readServerTabId(shownTabId) !== null
  /** The far end's id for the terminal on screen, once the server has answered. */
  const shownServerShellId = shownIsServer && shownTabId !== null ? serverShellIds[shownTabId] ?? null : null
  const modesBlocked: Partial<Record<WorkspaceMode, string>> | undefined = !shownIsServer
    ? undefined
    : !serverChatWired(serversBridge)
      ? {
          chat: 'Chat reads the agent’s own transcript file off that server, and this build has no channel for reading one. Updating the app brings it back.',
        }
      : shownServerShellId === null
        ? { chat: 'This terminal is still opening on the server, so there is nothing to read a conversation out of yet.' }
        : undefined

  /**
   * What the mode switch is showing, and what it will not offer.
   *
   * Read rather than stored: `panes` already knows whether the window is split
   * and `sessionView` already knows how the focused session is drawn, so a
   * third piece of state saying the same thing could only ever be the one that
   * is wrong.
   *
   * Both halves are handed over, because `mode` collapses to `split` the moment
   * there are panes and the switch still has to name the view underneath — it
   * labels its toggle with it, and it hands it back when the split is closed so
   * that splitting while reading a chat does not quietly turn the session into a
   * terminal. `sessionMode` is the same expression `mode` falls through to, not
   * a second reading of anything.
   */
  const sessionMode: SessionViewMode = shownTabId ? sessionView[shownTabId] ?? 'terminal' : 'terminal'
  const mode: WorkspaceMode = splitting ? 'split' : sessionMode

  /**
   * Whether there is a tab strip, and therefore which bar is the window's top
   * band.
   *
   * Asked once, here, and handed to both — the strip only draws itself when
   * this is true, and the session bar only reserves room for the traffic lights
   * and draws the reveal button when it is false. Two components deciding it
   * separately is how you get two reveal buttons, or none.
   */
  const hasStrip = stripIsPresent(openTabs)

  /**
   * The tab the rail and the strip should draw as selected.
   *
   * One value for the two of them, because they are answering the same question
   * and a window where the highlighted row and the highlighted pill disagree is
   * the defect `covered` was written for, in a third costume.
   *
   * `shownTabId` is that question already answered, once, at the top of this
   * component: a remote session or a server terminal when one fills the pane
   * (it *is* what is on screen, exactly as it was before it had a pill), the
   * focused pane while split, and the selected tab otherwise. This used to
   * repeat the three branches here, which meant the rail and the mode switch
   * each had their own copy of "what am I looking at" and only one of them was
   * right. `activeTab` remains the fallback for a window whose focused pane
   * holds nothing.
   */
  const railActiveTabId = shownTabId ?? activeTab?.id ?? null

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
   *
   * ## And it is absent over an emptied window
   *
   * With every tab taken off the bar there is no heading, no folder, no account
   * and no mode to switch — `heading` above resolves to a title of `null` for
   * exactly that reason — so what would be left is 48 pixels of empty chrome
   * under the strip. The strip is already the top band in that state (it draws
   * whenever anything is open), so it carries the lights, the drag and the
   * reveal, and this bar has nothing to add.
   *
   * `!hasStrip` keeps it for the launch screen, where there is no strip at all
   * and this bar *is* the top band — which is the first thing anybody sees, and
   * the one case where the app's own name over an empty window is the truth.
   */
  const showSessionBar =
    // A remote session gets the bar too — it is a session, and the bar is where
    // its name and its machine are said.
    openMachineSession !== null ||
    // And a terminal on a server, which is a session in exactly the same sense
    // and whose bar says which machine it is on.
    openServerSession !== null ||
    showingPanel ||
    splitting ||
    !hasStrip ||
    (headingTab !== null && headingTab.kind !== 'browser') ||
    copilotPending

  /**
   * Everything a *pane* is holding, which is what "on screen" means while the
   * window is split.
   *
   * It used to have a second job — telling the always-mounted list which pages
   * to skip, because the split branch mounted those itself. It does not any
   * more: mounting a page in a pane was a remount, and a remount closes the
   * `WebContentsView`, so entering a split reloaded the page the pane was
   * holding. Every page is mounted in one place now and the pane draws a hole.
   *
   * Empty whenever the window is not split, and that is not a shortcut: a
   * layout left over from a closed split still names tabs, and reading them as
   * held would keep answering for an arrangement that is no longer on screen.
   */
  const splitHeldTabIds = new Set<string>(splitting ? tabIds(panes) : [])

  /**
   * Whether a session that lives on another computer is the thing on screen.
   *
   * Two arrangements and one question. Split, a pane names it and the pane has
   * to be drawn at all — a sidebar view or the swarm grid takes the frame ahead
   * of the layout, so the panes underneath are covered and every terminal in
   * them is hidden with it. Unsplit, `openMachineSession` / `openServerSession`
   * are the window's answer, and `showPanel` already clears both.
   *
   * Asked here, once, rather than at each of the two mount lists: they are the
   * same question about two kinds of far session, and the copy that drifts is
   * always the one nobody has open.
   */
  const remoteOnScreen = (tabId: string): boolean =>
    splitting ? !showingPanel && !swarm && splitHeldTabIds.has(tabId) : railActiveTabId === tabId

  /**
   * The one browser page that is genuinely on screen, or null.
   *
   * Every branch that used to take the frame *by unmounting the pages* is
   * spelled out here instead, because that is what the move into `.panes` costs:
   * the pages no longer disappear when something covers them, so each of them
   * has to be told it is covered. Getting this wrong does not lose a page any
   * more — it paints one over Files.
   */
  const visiblePageId =
    activeTab?.kind === 'browser' &&
    !showingPanel &&
    !splitting &&
    !swarm &&
    openMachineSession === null &&
    openServerSession === null &&
    !(copilotPending && copilotSession === null)
      ? activeTab.id
      : null

  /**
   * Whether a page is the thing on screen — split or not.
   *
   * Two arrangements and one question, exactly as `remoteOnScreen` above is for
   * the two kinds of far session, and split off from `visiblePageId` for the
   * same reason: that expression answers *the one page filling the window*,
   * which is null the moment the window is split, and a split can have a page in
   * every pane.
   *
   * The second clause is the frame between a layout change and the re-measure.
   * A page that a pane is holding has no rectangle for that one frame, so it has
   * nothing to be drawn into — and an in-flow panel with no box lands under the
   * split instead of in it. Hidden for a frame is the honest answer; the native
   * view is parked and comes back with the hole it belongs in.
   */
  const pageOnScreen = (tabId: string): boolean =>
    splitting
      ? remoteOnScreen(tabId) && paneSlots[tabId] !== undefined
      : tabId === visiblePageId

  return (
    /*
      The window's list of terminals open on servers, offered to whatever inside
      it needs to add one.

      A provider rather than a prop because the only route from here to a
      server's page is `PanelView`, which draws all ten views off a `PanelId` and
      takes no per-view props — widening it for one panel would put a
      server-shaped argument on the component that draws every view. The default
      is `null` rather than a no-op, so a panel rendered outside a window says it
      has nowhere to put a terminal instead of drawing a control that swallows
      the press.
    */
    <ServerSessions.Provider value={serverSessionOpener}>
    {/*
      The window's route to the new-session dialog, offered to the Machines page.

      Nested rather than merged into the opener above it, because the two are
      different destinations that happen to be reached from the same page: that
      one opens a shell on a server, this one opens the dialog pointed at a
      paired machine. One object with both on it would be a bundle whose name
      could only be "things the machines page can do", and every consumer would
      take a dependency on the half it does not use.
    */}
    <MachineSessions.Provider value={machineSessionOpener}>
    {/*
      And the window's one view of a session on a paired machine, so that the
      Machines page can send somebody to it rather than drawing a lesser copy.

      A third nesting rather than a third key on either object above, for the
      reason the second gives: three destinations reached from one page are not
      one bundle. See `machines/session-view-context.ts`.
    */}
    <MachineSessionViews.Provider value={machineSessionViewer}>
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
          /*
            Which row is highlighted — including a remote one.

            `railActiveTabId` rather than `activeTab?.id`, because a session on
            another machine is a tab now and has to be able to be the selected
            one. That is what replaced the `activeMachineSession` pair this
            component used to take: two ways of saying "this one is on screen"
            is two answers to the question the rail asks most often.
          */
          activeTabId={railActiveTabId}
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
          /* The sessions that did not come back, as rows under the projects
             they belonged to. This is the only place in the window a person is
             told; the alternative — which is what shipped — was a warning in a
             log file and a window that looked completely normal. */
          held={held.rows}
          heldRetrying={held.retrying}
          onRetryHeld={held.retry}
          onForgetHeld={held.forget}
          peeking={sidebar.peeking && sidebar.collapsed}
          // Above Settings, in the foot. Mounted here rather than inside the
          // sidebar so the components stay where the wiring test can see them
          // and where their bridge subscriptions belong. The offer rides the
          // same slot because it is the same category of thing — the app
          // talking to you about itself — and on the one launch both could
          // appear (a fresh install with an update already out), the ask
          // stands above the news.
          update={
            <>
              <HooksOffer />
              <UpdateBanner />
            </>
          }
          /* The pinned row's status dot, its sentence, and whether the window
             it opens is the one on screen. One connection, read here, so the
             rail and the window cannot disagree about whether it is running.

             `active` is asked here rather than derived from `activeTabId`
             because the copilot's tab is deliberately not among the `tabs` the
             rail draws — it has this row instead, which is the whole point of a
             singleton having one home. `copilotPending` counts: the window is
             showing the copilot's own starting state, so the row that asked for
             it is current. */
          copilot={{
            stage: copilot.stage,
            state: copilot.state,
            active: !showingPanel && (copilotPending || (activeTab?.isCopilot ?? false)),
            // What it was named, or this app's own word for one nobody has named.
            name: copilotSetup.name,
          }}
          /* Both the pinned row and the "why does this exist" links, which pass
             the turn they want the window to land on. There is nothing to
             navigate to any more — the copilot is a window, so this opens one. */
          onOpenCopilot={(focus) => openCopilot(focus)}
          /* Opens the window *beside* the one you are in rather than replacing
             it — see `openTabWindow`, which carries his words and the two
             complaints it answers at once. The strip below keeps plain
             `selectTab`, because moving between pills is not opening anything. */
          onSelectTab={openTabWindow}
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
          /* Whether the resume glyph on a project heading exists at all. See
             `canResumeDefault`: on an agent with no resume command it started a
             fresh session and said nothing, which is the one thing this app has
             been told repeatedly not to do. */
          canResume={canResumeDefault}
          // Wrapped, not passed. The rail puts this straight on a button's
          // onClick, so passing it bare hands React's MouseEvent in as the
          // address — see the guard at the top of `newBrowserTab`.
          onNewBrowserTab={() => newBrowserTab()}
          onOpenProject={openProject}
          onCloseProject={closeProject}
          onOpenSettings={() => openSettings()}
          // Opens the sheet. It does not touch `panel`, which is what makes the
          // bell a pop-up rather than a navigation: whatever you were looking
          // at is still on screen behind it, and closing puts you back with
          // nothing to restore.
          onOpenAlerts={() => setAlertsOpen(true)}
          /*
            The machines, and the three things the rail does with them.

            Assembled here rather than in the rail, for the reason every other
            list it takes is: the rail draws what it is handed, and deciding
            which machines are worth listing is `reachableMachines` — one rule,
            read by this section and by the New Session dialog's machine step, so
            a machine you can pick in the dialog is always one you can see here.

            The sessions arrive as `WorkspaceTab`s off `machineTabs`, which is
            what lets the rail draw them with `rowsFor` — the same function that
            draws a project's sessions, so a remote row gets the identical status
            dot, drag, promote toggle and ✕ a local one has. That is the fix he
            asked for in as many words: *"You don't need to give icon of the
            remote next to all of them — only above there, next to the PC."*

            A group whose Close has been pressed is not in `machineTabs` at all,
            so it is not here either; see `closedMachines`.
          */
          machines={machines.machines
            .filter(
              (row) => !machineIsClosed(closedMachines, row.machine.id, row.link?.sessions ?? []),
            )
            .map((row) => ({
              machineId: row.machine.id,
              name: row.machine.name,
              sessions: machineTabs.filter((tab) => tab.machine?.id === row.machine.id),
              // The far machine's own answer, not this build's hope. A PC on an
              // older build advertises everything except this, and Close there
              // says why it cannot act rather than sending a frame into silence.
              canClose: row.link?.capabilities.includes('close') === true,
            }))}
          /*
            The same dialog, with the machine already chosen.

            *"New session → pick the machine → pick its folder → continue."* This
            press answers the first question, so the dialog opens on the second —
            which is the difference between a shortcut and a second flow.
          */
          onNewMachineSession={(machineId) => openNewSessionDialog(null, machineId)}
          onCloseMachine={closeMachine}
          /*
            And the terminals open on servers, grouped by the server they are on.

            Built by `serverSessionGroups` from the same list the strip's pills
            come from, so the rail and the strip cannot come to disagree about
            what is open — which is the whole reason `openTabs` is one array.

            A heading appears here only while something is open on that server,
            unlike a machine's, which is drawn whenever the machine is reachable.
            `server-sessions.ts` carries the argument: reachability is a live fact
            about a paired desktop and worth a row, and a server has no
            equivalent — it is a stored address this app never dials to find out
            about, so a heading per stored server would be a permanent row saying
            nothing in the list whose entire job is to answer what you have open.
          */
          servers={serverSessionGroups(serverSessions).map((group) => ({
            serverId: group.serverId,
            name: group.name,
            sessions: serverSessionTabs.filter((tab) => tab.server?.id === group.serverId),
          }))}
          /*
            No dialog behind this one, and that is the difference from the ＋
            above rather than an omission. The New session dialog asks which
            folder, which agent and which login, and this app can answer none of
            those about somebody else's server. So the press opens a shell, which
            is the honest floor.
          */
          onNewServerSession={(serverId) => {
            const group = serverSessionsRef.current.find((entry) => entry.serverId === serverId)
            if (group) openServerShell(serverId, group.serverName)
          }}
          onCloseServer={closeServer}
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

          Both kinds of tab carry a ✕ and the two do opposite things, which is
          the shape of 2026-08-20: *"for the windows it will completely close,
          and for the sessions it will just close from the top bar, but it will
          still stay in the side panel."* So the strip is handed two different
          handlers — `showInstead` for the session ✕, which only moves what is on
          screen, and `closeTab` for the browser one, which really ends the
          window. Nothing here can end a session; that stays the rail's ⋯ →
          Delete, with its confirmation.
        */}
        {hasStrip && (
          <WorkspaceTabStrip
            /* Everything open, this window's and the machines'. A remote session
               is a pill up here now, because he asked for one directly: *"it
               should be there on the top, just like the normal internal local
               session."* */
            tabs={openTabs}
            activeTabId={railActiveTabId}
            /* A sidebar view is filling the window, so none of these tabs is
               what is on screen — the bar below is headed with the view's name.
               The tab stays drawn, because it is what you will come back to;
               it just stops claiming to be the selected one.

               A remote session used to be listed here as a second reason to
               cover the strip, on the grounds that it filled the pane and had no
               pill of its own to be selected. It has one now, so covering the
               strip for it would be the strip refusing to point at a tab it is
               drawing — which is the very defect this prop exists to prevent, in
               the opposite direction. */
            covered={showingPanel}
            onSelect={selectTab}
            /* The ✕ on a session tab. It takes the tab off the bar and ends
               nothing, so the only thing this window has to do about it is stop
               showing a tab that is no longer up there — which is all
               `showInstead` does. Not `selectTab`: that is a navigation and
               would pull a covering view (Files, Overview) off the window, so
               tidying a tab while reading Files would throw you out of Files.

               A remote session's ✕ comes through here too, and must: the tab is
               taken off the bar and the session keeps running on its machine.
               The handler that once let a pill up here end one on its machine is
               deleted, not rewired — `WorkspaceTabStrip.tsx` names it, and two
               tests assert that no prop by that name is passed from this tag. */
            onShowInstead={showInstead}
            /* The ✕ on a browser tab, which is the other thing entirely.

               It closes the window. Not "takes it off the strip", because as of
               2026-08-20 the rail lists sessions only — *"Browser windows will
               not be on the side bar at all"* — so a page taken off the strip
               would be open, bound to a session, and drawn nowhere. `closeTab`
               routes it down the same path ⌘W takes, which tells the main
               process the window is gone; a page is never asked about, because
               there is no work in one to lose. */
            onCloseWindow={closeTab}
            /* The two icons pinned in the bar's trailing corner. The terminal
               opens the dialog,
               not a session — the same single route the rail's button takes —
               and the globe opens a page on the start page. */
            onNewSession={() => openNewSessionDialog()}
            // Wrapped for the same reason as the rail's globe above: the strip
            // puts this on a button, and a button hands its handler an event.
            onNewBrowserTab={() => newBrowserTab()}
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
                /*
                 * And only while that heading is one of *this* window's sessions.
                 *
                 * `headingTab` is `activeTab`, which is a local tab — but the title
                 * above it is `heading.title`, which a session on another machine or
                 * on a server overrides. So with a remote session on screen this bar
                 * was drawing the remote name and handing the rename the id of a
                 * local session sitting behind it: double-click, type, and you had
                 * silently renamed a session you were not looking at, while the
                 * heading carried on showing the remote name because it never came
                 * from the tab in the first place. A control acting on something
                 * other than the thing it is drawn over.
                 *
                 * Null is the honest answer rather than a stopgap: `SessionTitle`
                 * draws its plain heading for it, and there is nothing to route a
                 * rename to — no frame on the wire renames a session on another
                 * machine, and a shell on a server has no session record to rename.
                 *
                 * Written without any angle bracket in it on purpose. `wiring.test.ts`
                 * reads this opening tag by scanning for the first unbraced `(gt)`,
                 * so a tag name quoted in a comment between props truncates the tag
                 * and the seam check silently stops seeing every prop after it.
                 */
                sessionId={
                  !showingPanel &&
                  openMachineSession === null &&
                  openServerSession === null &&
                  headingTab?.kind === 'session'
                    ? headingTab.id
                    : null
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
                   session you are about to start.

                   The folder half is now the same for a session on one of his
                   other machines: same chip, same mono, same place. Only the
                   thing beside it changes, and the note below says why. */
                    <div className="toolbar-chips">
                      <FolderTitle path={headingFolder} />
                      {/*
                    And beside it, the second fact — which is a different fact
                    for a session running somewhere else.

                    `meta` *replaces* the subtitle rather than joining it, so
                    giving a remote session the folder chip would have taken the
                    machine's name off the bar altogether, and which computer a
                    session is running on is the one thing that must never stop
                    being visible. It moves here instead, in the slot the account
                    holds for a local session, and it is `heading.subtitle`
                    itself rather than a second composition of the same words so
                    the two cannot drift.

                    And then the account, which is now on this line too. The note
                    that stood here said the chip could not be: *"which account an
                    agent on another machine was spawned under is not a fact any
                    frame on the wire carries. It would be a menu of choices that
                    reach the wrong computer."* Both halves are answered rather
                    than argued with. `CAPABILITY.account` carries the fact, and
                    the rows reach the far machine's own switch — the same
                    operation the window at *that* desk performs — so the menu
                    acts on the session it is drawn over. Asad: *"Then also bring
                    the account selection here for the remote sessions too."*

                    A machine whose build predates the capability answers
                    nothing, and the chip is then **absent** rather than empty.
                    That is his most repeated finding applied to itself — *"a
                    dropdown only when some exist. Hide it when empty."* — and it
                    is the same silent degrade the connectors chip beside it makes
                    for the same machine, with no sentence anywhere saying so.
                  */}
                      {openMachineSession !== null ? (
                        <>
                          {heading.subtitle !== null ? (
                            <>
                              <span className="toolbar-chip-sep" aria-hidden="true" />
                              <span className="toolbar-subtitle">{heading.subtitle}</span>
                            </>
                          ) : null}
                          {machineAccount.current !== null || machineAccount.accounts.length > 0 ? (
                            <>
                              <span className="toolbar-chip-sep" aria-hidden="true" />
                              <MachineAccountChip
                                current={machineAccount.current}
                                accounts={machineAccount.accounts}
                                busy={machineSwitching}
                                /* Asked again as the menu opens, which is the
                                   moment somebody is about to read it. An account
                                   list changes when somebody adds or signs one in
                                   over there, not when the session prints — so
                                   this deliberately does not ride the output
                                   events the model chip rides. */
                                onOpen={machineAccount.reload}
                                onPick={(accountId) =>
                                  switchMachineSession(
                                    openMachineSession.machineId,
                                    openMachineSession.sessionId,
                                    accountId,
                                  )
                                }
                              />
                              {/* And the only sentence this line ever draws,
                                  which appears because somebody pressed a row and
                                  the far machine said no. It clears itself. */}
                              {machineSwitchProblem === null ? null : (
                                <span className="machine-switch-host">
                                  <span className="machine-switch-problem" role="status">
                                    {machineSwitchProblem}
                                  </span>
                                </span>
                              )}
                            </>
                          ) : null}
                        </>
                      ) : (
                        <>
                          <span className="toolbar-chip-sep" aria-hidden="true" />
                          <AccountChip
                            current={heading.account}
                            /* The account this session is waiting to become, when
                               one is armed. Named on the chip because arming a
                               deferred switch otherwise has no visible effect at
                               all until the next message, which reads as a button
                               that did nothing. */
                            pendingAccount={
                              focusedSession ? (armedSwitches[focusedSession.id] ?? null) : null
                            }
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
                            onPick={(accountId, runAs) => newSession(headingFolder, false, accountId, runAs)}
                            /*
                             * The session this chip is over, and what a row does to it.
                             *
                             * Both, or neither: `session` is how the chip knows there is
                             * an agent running to switch, and `onSwitchAccount` is how it
                             * knows this caller can actually perform one. With only the
                             * first it would draw a switch-shaped menu whose rows opened
                             * a second session, which is the reported bug wearing the fix
                             * as a costume.
                             *
                             * Spelled as plain props rather than a conditional spread so
                             * `wiring.test.ts` can see them — a spread is invisible to
                             * that guard, and this is exactly the seam it watches.
                             */
                            session={chromeSession(
                              !showingPanel && headingTab?.kind === 'session' ? headingTab.id : null,
                              sessions,
                            )}
                            onSwitchAccount={(sessionId, accountId) =>
                              switcher.ask({ sessionId, profileId: accountId })
                            }
                            onManage={() => openSettings('profiles')}
                          />
                        </>
                      )}
                    </div>
                  ) : headingServerTabId !== null && serverSignIn !== null && headingServer !== null ? (
                    /*
                      A terminal on a server, which has no folder chip — and an
                      account chip now, where a bare word stood.

                      The folder is genuinely absent — a shell lands wherever
                      that sign-in lands and a path here would be resolved
                      against this Mac — so the branch above draws nothing and
                      this one takes the row. The subtitle comes with it, because
                      `meta` *replaces* the subtitle rather than joining it and
                      which computer a session is on is the fact that must never
                      go missing.

                      Beside it, the same chip idiom as everywhere else. The
                      words on it are still `signInLine`'s four sentences — a
                      server nobody had opened, one that would not answer, one
                      with no agent, one signed out, each said as itself, never
                      blank — but the slot is pressable now, because it has two
                      real verbs: a new terminal on that server with one of its
                      signed-in agents running, and the road to where sign-ins
                      are changed. What it still cannot do — switch *this*
                      terminal's agent — the menu says before any row is read.
                      *"when I am inside the server, I cannot even change the
                      accounts"* — `ServerAccountChip` carries the argument.
                    */
                    <div className="toolbar-chips">
                      {heading.subtitle !== null ? (
                        <>
                          <span className="toolbar-subtitle">{heading.subtitle}</span>
                          <span className="toolbar-chip-sep" aria-hidden="true" />
                        </>
                      ) : null}
                      <ServerAccountChip
                        signIn={serverSignIn}
                        serverName={headingServer.name}
                        onStartAgent={(agentId) =>
                          openServerShell(headingServer.id, headingServer.name, null, agentCommand(agentId))
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
                {/*
              And over a session on one of his own machines, or a terminal on a
              server, it is **the same mount** — which is the whole of the change.

              This is where two paragraphs used to stand explaining why it could
              not be. Both were mechanically true when they were written: every
              control here is a conversation with a pty *by session id*,
              `agent-controls.ts` performs a change by typing `/model` into that
              pty and reading the screen, and no frame on the wire named a model,
              an effort or a fast mode. What they concluded from that was the part
              that has now changed.

              A paired machine is a machine running this app, so it already has
              that module and that pty — `CAPABILITY.controls` carries the
              request there and the answer back, and the far end sets the model
              exactly as its own window would. A server is not, and the old note
              said so and stopped; what it did not check is that a server shell is
              a **real pty** — `client.shell({ term: 'xterm-256color' })` — whose
              bytes arrive in this main process, which is the only thing the
              mechanism ever needed. `servers/ipc.ts` attaches the same shadow
              terminal a local session keeps and drives the same two functions
              against it.

              The old note's caution was right and is kept where it belongs. It
              worried that typing `/model` into a plain shell "submits the word to
              whatever happens to be in front of it, which might be a database
              prompt on somebody's live machine" — and that is refused twice over
              there, by `refuseByProvider` finding no Claude Code markers on the
              screen and by `refuseToType` finding no composer to type into. The
              refusal arrives as a sentence on the chips rather than as an
              absence.

              What is still withheld is the connectors chip and the account chip,
              and only those — silently, since the note that used to name them was
              deleted. See the comment where it stood, below, for the four seams
              either of them needs.
            */}
            {barControls ? (
              <SessionControls
                sessionId={barControls.sessionId}
                cwd={barControls.cwd}
                provider={barControls.provider}
                /* Never a literal. `barControls` computes it per branch from the
               one fact each kind of session genuinely has — an exit code for
               a local or a paired-machine session, and for a server terminal
               the `servers:shell:closed` this window observed. A hardcoded
               `false` here would keep live model and effort chips on the bar
               of a session whose process is already gone: the screen those
               values are read from still carries a killed CLI's banner. */
                exited={barControls.exited}
                end={barControls.end}
                onOpenConnectors={openConnectors}
                /* Which computer to ask. Undefined for a session on this one,
               which is what every mount meant before the prop existed. */
                target={barControls.target}
              />
            ) : null}
            {/*
              And nothing beside the cluster, where a sentence used to be.

              `RemoteControlsNote` printed "Connectors and login are set on
              {machine}." here — a visible `<p>` in a 48-pixel toolbar, narrating
              which two chips are missing. Asad, 2026-08-20, on exactly this habit:
              *"I said to you, don't put any single statement in anywhere.
              Everywhere you are putting a lot of statements. We don't need to
              give the statements. We want simplicity."* A control that is absent
              is not something to write a line about; the fix is the chip, and
              until the chip exists the honest surface is an empty one.

              What it is waiting on is written down where the work is, not on
              screen: `usage-reach.ts` holds the same list for the figures beside
              it, and the two chips need the same four seams — a want on
              `CAPABILITY.usage` in `src/main/remote/protocol.ts`, a
              `SessionAccess` seam gated on `mayTouch`, a method on
              `machines/guest.ts` with its ipc and preload, and a router beside
              `controls-target.ts`.
            */}
            {/*
              And the mode switch, which is now drawn over a remote session too —
              with whichever of its two buttons cannot act on one saying why.

              It used to be withdrawn entirely, on the argument that Chat reads a
              transcript on this machine's disk and Split arranges this window's
              panes. Both of those are still true and neither was ever true of
              **Terminal**, which is exactly what a remote session and a server
              terminal are already showing — so the whole control was being taken
              away because two of its three answers were unreachable, leaving a
              gap that reads as unbuilt. `modesBlocked` carries the sentences;
              see its note for what would have to travel for either to work.

              Still absent in swarm and behind a panel, for the original reason:
              every terminal is drawn at once, or none is, so there is no session
              for a mode to be a mode of.

              And absent over another machine's copilot, where all three of its
              answers are unreachable rather than two: that pane is a parsed
              conversation and there is no second view of it to switch to —
              `remote/hidden-sessions.ts` will not put a copilot's pty on the
              network for anybody. A control with nothing left to offer is
              withdrawn rather than drawn with three reasons hanging off it.
            */}
            {(activeSession || splitting || openMachineSession !== null || openServerSession !== null) &&
            !(headingTab?.isCopilot && copilotMachine !== null) &&
            !showingPanel &&
            !swarm ? (
              <ModeSwitch
                mode={mode}
                view={sessionMode}
                onChange={setMode}
                splitOffer={!features.on('split')}
                unavailable={modesBlocked}
              />
            ) : null}
            {/*
              Restart — the one control here a session's bar does not have, and
              the only thing about this window that is *more* rather than the
              same.

              It said Stop until 2026-08-20, and Stop was a button whose only
              visible effect was this window disappearing: the copilot's tab is
              derived from its pty, so ending the pty ended the tab the button
              was drawn on. *"I don't understand what is the purpose of stop
              button."* Restart is the act somebody standing in this bar
              actually wants — a fresh conversation, same copilot, window stays
              — and switching the copilot off entirely has moved to Settings →
              Copilot, where there is room to say what it costs. The whole
              argument is in `CopilotRestart`.

              Last in the row, where the rail puts a session's ✕ at the end of
              its own row, and after the mode switch so it can never come between
              the controls and the way out of a split.

              And absent entirely while the copilot page is switched to another
              machine, which is not a tidiness rule — this button is wired to
              `useCopilot`, the copilot on *this* computer, and nothing on the
              wire restarts one anywhere else. Left drawn, it was a button over a
              PC's conversation that ended a conversation on this Mac. Silently
              absent, exactly as the account chip is over a remote session, for
              the reason stated there: a missing control is not something a
              toolbar explains.
            */}
            {headingTab?.isCopilot && copilotMachine === null && !showingPanel && !swarm ? (
              <CopilotRestart copilot={copilot} />
            ) : null}
          </WindowToolbar>
        )}

        <div className="panes" ref={panesHostRef}>
          {/* Named for whatever the bar above is naming, which is the host
              session. The fallback catches the one case with no name at all: a
              split whose host pane is still empty, where "Split view" describes
              the arrangement rather than pretending to name a session in it. */}
          <ErrorBoundary label={heading.title ?? 'Split view'}>{mainView()}</ErrorBoundary>
          {/*
            The browser pages — every one of them, always, hidden unless the one
            in front is this page.

            Here rather than inside `mainView` for the reason the server shells
            and the remote sessions are here, and the reason is his: *"if this
            link is loaded, page is loaded, I go to session. If I come back, this
            is all gone, so it refreshes."* `mainView` draws one thing and
            returns early for a remote session, a server shell, a sidebar view, a
            split and the swarm grid — so any of those unmounted every page in
            the window, and an unmounted `BrowserWorkspace` closes its
            `WebContentsView` rather than parking it. See the long note at the
            single-session branch of `mainView` for what was measured.

            `visible` is now the whole answer to "is this page the thing on
            screen", which it has to be: a hidden mount that still thought it was
            visible would composite a native page over Files.

            **Every** one of them, including the page a pane of a split is
            holding. That page used to be skipped here and mounted inside the
            pane instead, which was the last route left to the bug above: moving
            a panel between two subtrees is a remount, a remount closes the
            `WebContentsView`, and so pressing Split reloaded the site somebody
            was reading. The pane draws a hole and this mount is given its
            rectangle — see `layout/pane-slots.ts`, and the `box` prop below.
          */}
          {tabs
            .filter((tab) => tab.kind === 'browser')
            .map((tab) => (
              <BrowserWorkspace
                key={tab.id}
                // Which page is on screen, and nothing else. Folding the modal
                // flag in here would blank the workspace behind every dialog —
                // parking the native pages is what a dialog needs, and that is
                // what `parkPage` is.
                //
                // `pageOnScreen` and not `tab.id === visiblePageId`, because a
                // split can have a page in every pane and that expression is
                // null the moment the window is split.
                visible={pageOnScreen(tab.id)}
                /* Where in the pane area to draw, when a pane of a split is
                   holding it. `undefined` leaves the stylesheet's in-flow panel,
                   which is the unsplit window. See `layout/pane-slots.ts`. */
                box={slotStyle(paneSlots[tab.id])}
                parkPage={anyModalOpen}
                // Settings owns where a page opens; the panel's own button
                // writes the same setting rather than a copy of it.
                startUrl={stringSetting(settings, 'browser.startUrl')}
                // Where a *link* asked this page to open, when one did. Empty
                // for the globe, which goes to the start page.
                initialUrl={tab.url}
                // And whose network to open it on. See the split mount.
                initialMachineId={tab.hostMachineId}
                // The other mount site. See the note beside the split one.
                tabId={tab.id}
                // The terminals open on servers. See `browserServerShells`.
                serverShells={browserServerShells}
                onStartUrl={(url) => {
                  applySettings({ ...settings, 'browser.startUrl': url })
                  void window.deck.setSettings({ 'browser.startUrl': url })
                }}
                // The other mount site, and the same door. See the split one.
                onSettings={() => openSettings('browser')}
                /* The store's three-dot row. It navigates now rather than
                   opening a dialog — the store is a page holding this browser's
                   extensions beside the MCP catalogue, under one search box.
                   Same shape as `onSettings` above: the panel does not know how
                   a page in this app is opened, because it is a page inside
                   one. */
                onOpenStore={() => showPanel('store')}
                // Otherwise every browser row in the sidebar reads "New tab".
                onTitle={(title) => renameBrowserTab(tab.id, title)}
                onSendToAgent={(context) => {
                  if (activeSessionId) window.deck.writeToSession(activeSessionId, context)
                }}
              />
            ))}
          {/*
            The terminals open on servers — every one of them, always, hidden
            unless it is the one in front.

            Outside the boundary above rather than inside `mainView`, and that
            placement is the whole of what makes one of these a session you can
            leave and come back to. `mainView` returns one thing: open Settings,
            look at a session on a paired machine, split the window, and whatever
            it was drawing before is unmounted. Every other pane survives that
            because something else is holding its state — the main process's
            scrollback, the page in the main process, the far machine's replay —
            and a shell on a server has nothing holding it but the terminal it is
            written into. Unmounting it would either lose every line it had
            printed or, if the shell were left open to avoid that, strand a live
            one on somebody's machine with no way back to it.

            So they are mounted here, beside the pane, exactly as the local
            terminals and browser pages are mounted beside each other one level
            down: *"Every browser and terminal stays mounted and is shown or
            hidden, so a page keeps its scroll position and a terminal keeps its
            scrollback when you switch away and come back."*

            Nothing at all is drawn when the list is empty, which is every window
            that has never opened one, and the bridge being absent draws nothing
            either — a build whose preload has no server channels cannot have a
            row on this list in the first place.
          */}
          {serversBridge !== null &&
            serverSessions.map((entry) => {
              /*
               * The same session in two views, in one rectangle, and only one of
               * them on screen at a time.
               *
               * `sessionView` is the same map and the same segmented control
               * every local session is switched with — there is no second piece
               * of state for a server, which is the whole of what "a session
               * like the others" means here. The terminal is *hidden* rather
               * than unmounted while the conversation is up, because its
               * scrollback exists nowhere else: nothing at the far end is
               * keeping it and nothing on this side is recording it.
               *
               * The conversation is drawn only once the server has answered
               * with an id for the shell. Before that there is nothing to read a
               * transcript out of, and the mode switch says so rather than
               * opening an empty pane — see `modesBlocked`.
               */
              const onScreen = remoteOnScreen(entry.tabId)
              const shellId = serverShellIds[entry.tabId]
              const chatting =
                (sessionView[entry.tabId] ?? 'terminal') === 'chat' && shellId !== undefined
              const box = slotStyle(paneSlots[entry.tabId])
              return (
                <Fragment key={entry.tabId}>
                  <ServerSessionPane
                    serverId={entry.serverId}
                    shellKey={entry.shellKey}
                    startIn={entry.startIn}
                    run={entry.run}
                    bridge={serversBridge}
                    /* Where in the pane area to draw, when a pane is holding it. See
                       `layout/pane-slots.ts`; `undefined` leaves the stylesheet's
                       `inset: 0`, which is the unsplit window. */
                    box={box}
                    visible={onScreen && !chatting}
                    onEnded={() => serverShellEnded(entry.tabId)}
                    /* The one thing this pane knows that the bar above it needs.
                       See `serverShellIds`. */
                    onOpened={(id) => serverShellOpened(entry.tabId, id)}
                    /* Off the row rather than the servers list, which is what
                       `renameServersIn` keeps in step for exactly this kind of
                       reader. */
                    serverName={entry.serverName}
                    /* The press on the ended card. A closed SSH channel leaves
                       one question — was that the shell or the server — and this
                       app cannot answer it from here (`session-end.ts` says
                       why), so the card offers the act that finds out. Same
                       folder, so it lands where the last one did. */
                    onReopen={() =>
                      openServerShell(entry.serverId, entry.serverName, entry.startIn, entry.run)
                    }
                  />
                  {chatting && shellId !== undefined ? (
                    <ServerChatPane
                      shellId={shellId}
                      bridge={serversBridge}
                      box={box}
                      /* Mounted for as long as this session is *in* chat mode,
                         on screen or not, and told whether it is being looked
                         at. Unmounting it would drop the reader the main
                         process holds and make coming back to the tab the whole
                         tail window over SSH again; being hidden costs a DOM
                         node and switches its timer off. */
                      visible={onScreen}
                    />
                  ) : null}
                </Fragment>
              )
            })}
          {/*
            The sessions opened on paired machines — every one of them, always,
            hidden unless it is the one in front.

            Here rather than inside `mainView` for the reason the server shells
            are, and the reason is his: *"If I go to other page and come back, it
            will start from beginning again."* `mainView` draws one thing, so a
            pane returned from it is a pane that is unmounted the moment anything
            else takes the frame — which for a remote session means detaching
            from the far machine and disposing the terminal, and coming back
            means attaching again and being sent the whole scrollback again. A
            local session survives that because the main process is holding its
            output; a remote one now survives it the same way every other pane in
            this window does, by not going anywhere.

            The wrapper is what makes a terminal written for a settings pane fill
            a whole one: `.panes` is a positioned block rather than a flex
            container, so `.machines-terminal`'s own `flex: 1` has no column to
            grow in and the terminal took its natural height, leaving a band of
            empty chrome under it.

            Nothing is drawn at all before this window has opened one, which is
            every window that never touches another machine, and a build whose
            preload has no machine channels draws nothing either.
          */}
          {machinesBridge !== null &&
            machineSessionPanes.map((pane) => (
              <div
                key={`${pane.machineId}\u0000${pane.sessionId}`}
                className="remote-pane"
                /* Boxed into one pane's hole, or filling the whole pane area.
                   See `layout/pane-slots.ts`. */
                data-boxed={paneSlots[machineTabId(pane.machineId, pane.sessionId)] !== undefined}
                style={slotStyle(paneSlots[machineTabId(pane.machineId, pane.sessionId)])}
                data-visible={remoteOnScreen(machineTabId(pane.machineId, pane.sessionId))}
              >
                <MachineSessionPane
                  machineId={pane.machineId}
                  sessionId={pane.sessionId}
                  bridge={machinesBridge}
                  /* Why this pane's screen is a photograph, or null while it is
                     a session. Read here rather than in the pane because the
                     answer is mostly a fact about the *link* — see
                     `endOfMachineSession`, which is also what `controlsFor`
                     below consults, so the bar over this pane and the card
                     inside it cannot come to describe the same event
                     differently. */
                  end={machinePaneEnd(pane.machineId, pane.sessionId)}
                />
              </div>
            ))}
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
        /*
         * Settings → Copilot's "Set it up again" — the same few questions, from
         * the pane that shows what they wrote.
         *
         * It comes up here rather than being opened inside the settings sheet,
         * for the same reason `onStartSession` does: this window owns the flow,
         * and a dialog over a dialog would leave two Escape handlers on one key
         * — pressing it in the flow would take the settings sheet away with it.
         * Closing the sheet first also means the answers land in front of the
         * workspace they change, which is where their effect is visible.
         */
        onSetUpCopilot={() => {
          setPrefsOpen(false)
          setCopilotSetupOpen(true)
        }}
        // Every behavioural setting is read from one copy up here, so a change
        // made in the dialog has to land in it — otherwise the next ⌘W, the
        // next banner and the next terminal all disagree with what is on
        // screen until the app is restarted.
        onChange={applySettings}
      />
      {/*
        What switching this session's account would do, before it does it.

        Mounted unconditionally and gated on `open`, like every other dialog in
        this window — a sheet rendered only while it is wanted loses its state on
        the way in and cannot animate on the way out.

        The title of the session comes from the tab list rather than from the
        plan, because the plan is about accounts and this line is about *which
        session* is being talked about. Falling back to the empty string is
        `CloseSessionConfirm`'s answer to the same question and means the same
        thing: the sheet is shut, and nothing is being asked about.
      */}
      <SwitchAccountConfirm
        open={switcher.asking !== null}
        title={
          switcher.asking === null
            ? ''
            : (tabs.find((tab) => tab.id === switcher.asking?.sessionId)?.label ?? '')
        }
        names={switchNames(switcher.plan ?? { from: null, to: null }, knownSignIns)}
        plan={switcher.plan}
        busy={switcher.busy}
        problem={switcher.problem}
        onCancel={switcher.cancel}
        onConfirm={confirmAccountSwitch}
        canDefer={switcher.canDefer}
        onDefer={deferAccountSwitch}
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
        /*
          How many sessions this press ends.
        
          A machine's count is the sessions running on it, which is what makes
          *"Closing this machine closes 4 sessions on it"* a true sentence and
          the reason there is one dialog rather than four. One session on another
          machine is one, exactly as a local one is.
        */
        count={
          pendingClose?.kind === 'project' ||
          pendingClose?.kind === 'machine' ||
          pendingClose?.kind === 'server'
            ? pendingClose.count
            : 1
        }
        /* Which nouns the dialog uses. The act is the same in all three cases;
           what differs is what a person is being told they are closing, and
           calling a computer a project is how a confirmation stops being read. */
        subject={
          pendingClose?.kind === 'machine' || pendingClose?.kind === 'machine-session'
            ? 'machine'
            : pendingClose?.kind === 'server' || pendingClose?.kind === 'server-session'
              ? 'server'
              : 'project'
        }
        provider={
          pendingClose?.kind === 'session'
            ? sessions.find((s) => s.id === pendingClose.tab.id)?.provider
            : undefined
        }
        /* So the dialog can name the browser windows this lets go of. Only for
           a single session: a project's or a machine's dialog is about a set,
           and `B1` is a fact about one session's numbering. */
        sessionId={pendingClose?.kind === 'session' ? pendingClose.tab.id : undefined}
        onCancel={() => setPendingClose(null)}
        onConfirm={() => {
          const closing = pendingClose
          setPendingClose(null)
          if (!closing) return
          if (closing.kind === 'session') closeTabNow(closing.tab.id)
          else if (closing.kind === 'project') closeProjectNow(closing.path)
          else if (closing.kind === 'machine') closeMachineNow(closing.machineId)
          else if (closing.kind === 'server') closeServerNow(closing.serverId)
          else if (closing.kind === 'server-session') closeServerSessionNow(closing.tabId)
          else closeMachineSessionNow(closing.machineId, closing.sessionId)
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
        /*
          The machines, and which one the press already chose.

          The same `reachableMachines` rule the rail uses, so a machine offered
          here is always one with a heading over there — and `folders` is the
          list the far machine advertised to this one, never a list assembled on
          this side, which is what makes a row in that picker a row its own rule
          will accept.
        */
            machines={machines.machines.map((row) => ({
              id: row.machine.id,
              name: row.machine.name,
              folders: row.link?.folders ?? [],
            }))}
            /* And what to call this computer on that same list. Every other row
               on it is a machine's own name, and this one was a phrase — the
               shape that had the browser bar saying "This machine" about two
               different computers at once. `hereName` keeps the phrase for the
               case where the view has no name yet. */
            hereName={hereName(machines)}
            machineId={newSessionMachine}
            /*
          And the servers, which until 2026-08-19 this dialog had never heard
          of: *"its giving new session option inside the server page not with
          the main button."* Every stored one is offered — `NewSessionDialog`'s
          own note on the prop carries the argument for why filtering them on a
          live connection would show an empty list on every launch.
        */
            servers={startServers}
            serversBridge={serversBridge}
            onStartOnServer={(serverId, serverName, path) => {
              setNewSessionOpen(false)
              // The same call the server's own page makes, folder and all. A second
              // implementation here is how two doors to one act start behaving
              // differently — which is the thing this whole change is closing.
              openServerShell(serverId, serverName, path)
            }}
            onClose={() => setNewSessionOpen(false)}
            onStart={async (request, machineId) => {
              setNewSessionOpen(false)
              /*
               * A session on another machine, started the same way and landing in
               * the same place — the rail, beside the local ones.
               *
               * It returns before any of the local bookkeeping below, and every line
               * of that bookkeeping is why: `addProject` would put another
               * computer's folder in *this* one's project list, `addSession` would
               * put a session this window does not own into the store that decides
               * what ⌘W closes, and `keepNewWindowInStrip` would give it a tab with
               * a ✕ that promises to end something living on a different machine.
               *
               * What it does instead is ask the far end to start it and then open
               * it, which is the whole flow: New session → the machine → its folder
               * → a terminal.
               */
              if (machineId !== null) {
                // `startSession` waits for the session to actually exist on the far
                // machine rather than for the request to have been sent — see the
                // long note on it. Null means it refused or did not appear, and the
                // rail is the honest place for that: the machine's own heading is
                // there, and a session that turns up a moment later lands in it.
                const sessionId = await machines.startSession(machineId, request.cwd, request.provider)
                machines.reread()
                if (sessionId === null) return
                clearPanel()
                setOpenMachineSession({ machineId, sessionId })
                return
              }
              // Refusals land in the rail as a held row — see `newSessionIn`, which
              // carries the reasoning. This dialog does not draw the picker's
              // "could not start" line for it, because by the time the dialog has
              // closed the answer belongs where the session would have been.
              const meta = await window.deck.createSession(request).catch(() => null)
              if (!meta) return
              /*
               * The folder joins the rail, exactly as it does on every other route.
               *
               * `newSessionIn` has done this since the day it was written — *"a
               * session in a folder the sidebar is not listing is a session with no
               * row"* — and this path, which became the *only* path when every
               * button started opening this dialog, never did. Browse to a folder
               * the app has not seen, press Start, and the session lands in the
               * rail's orphan bucket, which means "your project was closed out from
               * under this" and is not what happened.
               *
               * It is what makes the copilot's own folder work as a place to start a
               * normal session in — *"it will just be a normal another session"* —
               * because `projects` gives that folder a heading precisely when one of
               * his sessions is in it, and nothing here would ever have put it in
               * the list for that test to pass.
               */
              addProject(request.cwd)
              void window.deck.addProject(request.cwd)
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
                ? {
                    startedAt: focusedSession.createdAt,
                    resumed: focusedSession.resumed,
                    ...(focusedSession.agentSessionId === undefined
                      ? {}
                      : { agentSessionId: focusedSession.agentSessionId }),
                  }
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
      {/*
        The few questions before a copilot's first run.

        Opened by `openCopilot` and by nothing else in this window, so it appears
        exactly once per install — in front of the first start, never after it.
        Closing it writes nothing and starts nothing, which is what makes it safe
        to dismiss; finishing it saves the answers into the copilot's own
        instruction file and *then* starts it, which is the order Asad asked for.

        `reload()` before `showCopilot()` matters: the name it was just given is
        the label on the tab that is about to be created, and a stale read here
        would open a window called "Copilot" for a copilot called Nova.
      */}
      <CopilotSetup
        open={copilotSetupOpen}
        onClose={() => setCopilotSetupOpen(false)}
        onDone={() => {
          setCopilotSetupOpen(false)
          copilotSetup.reload()
          showCopilot(copilotTurn)
        }}
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
    </MachineSessionViews.Provider>
    </MachineSessions.Provider>
    </ServerSessions.Provider>
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
