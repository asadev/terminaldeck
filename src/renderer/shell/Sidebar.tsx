import { useEffect, useRef, useState, type DragEvent, type MouseEvent, type ReactNode } from 'react'
import { ALERTS_GLYPH } from '../components/AlertsPanel'
import { StatusDot } from '../components/StatusDot'
import type { Project } from '../state/store'
import { useSessionRename } from '../state/session-rename'
import { folderName, MAX_TITLE_LENGTH } from '../session-title'
import { tip } from '../keymap'
import { demote, MAX_PROMOTED, promote, usePromotedOrder } from '../browser/workspace-strip'
import { accountRail, useKnownSignIns } from '../accounts'
import { heldAgentName, type HeldSessionView } from '../held-sessions'
import { CopilotEntry } from '../copilot/CopilotEntry'
import { SERVER_ICON } from '../machines/servers/glyph'
import type { CopilotStage, CopilotStateView } from '../copilot/copilot-model'
import { partitionByOrigin, turnOf } from '../copilot/session-origin'
import { PANEL_GROUPS, PANELS, type PanelId, type PanelSpec } from './panels'
import {
  accountsWorthShowing,
  dragStartedOnControl,
  KIND_ICON,
  MACHINE_ICON,
  sessionLabel,
  startTabDrag,
  tabQualifiers,
  type WorkspaceTab,
} from './workspace-tabs'
import { GroupHead } from './GroupHead'

/**
 * One reachable machine, as the rail lists it.
 *
 * Flattened rather than the `Machine`/`MachineLinkState` pair the machines
 * bridge answers with, for the reason every other prop on this component is
 * flattened: the rail draws what it is handed and asks nothing, so a shape that
 * carried a link's `state`, its `retryAt` and its capabilities would be inviting
 * this file to start deciding whether a machine is worth listing. That decision
 * is `reachableMachines`, one level up.
 */
export interface SidebarMachine {
  machineId: string
  name: string
  /**
   * What is running there, as tabs.
   *
   * `WorkspaceTab`s rather than the three fields this used to carry, and the
   * change is the whole of *"the rows underneath take the identical icons a
   * local session row takes"*. They go through `rowsFor` now — the same function
   * that draws a project's sessions — so they get the status dot, the drag to
   * the top strip, the promote toggle and the ✕ without any of it being written
   * twice. A row built from a private shape could only ever have been a copy of
   * that function that drifts from it.
   *
   * Each tab's `machine` field says which machine it is on, and its id is minted
   * by `machineTabId` so that one function owns the joining of the two handles.
   */
  sessions: readonly WorkspaceTab[]
  /**
   * Whether that machine will accept a request to end a session.
   *
   * It is the `close` capability off the link, asked one level up like every
   * other decision this component is handed. False is not hypothetical: the verb
   * is newer than the protocol, a machine paired to an older build advertises
   * everything except this, and the honest answer there is a Close that says why
   * it cannot act rather than one that sends a frame into silence.
   */
  canClose: boolean
}

/**
 * One server this window has a shell open on, as the rail lists it.
 *
 * Flattened like {@link SidebarMachine} beside it, and deliberately shorter than
 * it by one field. There is no `canClose`: a machine's ✕ has to ask the far end
 * to end a session it owns, and a machine paired to an older build never
 * advertised the verb — so the honest answer there is a Close that says why it
 * cannot act. A server owns nothing. The shell exists because this window is
 * holding a connection to it, so closing it is this window letting go, and there
 * is no version of anything at the far end that can refuse.
 */
export interface SidebarServer {
  serverId: string
  name: string
  /** What is open there, as tabs, drawn by the same `rowsFor` a project uses. */
  sessions: readonly WorkspaceTab[]
}

interface Props {
  width: number
  projects: Project[]
  tabs: WorkspaceTab[]
  /** The open session or page, whether or not a view is covering it. */
  activeTabId: string | null
  /** The view covering the window, or null when a session/page is on screen. */
  activePanel: PanelId | null
  /**
   * The views to list, which is every view whose feature is installed.
   *
   * A prop rather than a read of the feature state, because this component is
   * the window's inventory of what you have open and the decision about what
   * exists belongs one level up, with the rest of the gating. It defaults to all
   * of them so that rendering a `Sidebar` on its own — a test, a harness — shows
   * the app rather than a fresh install's subset of it.
   */
  panels?: readonly PanelSpec[]
  /**
   * Whether the browser feature is installed and on, i.e. whether the globe
   * beside New session opens a pane or offers one.
   *
   * It used to decide whether the button was drawn at all, and the result was
   * the failure a feature store actually causes: uninstalling the browser pane
   * deleted the globe with nothing in its place, so the app looked like one
   * that had never had a browser. The button stays either way — see
   * `browserOffer`.
   */
  browser?: boolean
  /**
   * The hover label for the globe when the feature is *not* on, from
   * `useControlOffer`. Null when it is on and the globe is an ordinary control.
   *
   * A string rather than a feature id for the same reason `panels` is a list
   * rather than a lookup: this component is the window's inventory of what you
   * have open, and every decision about what exists is made one level up.
   */
  browserOffer?: string | null
  /**
   * The machines this window can reach, and what is running on each.
   *
   * A prop rather than a read of `useMachines`, exactly like `panels` and
   * `browser` above: this component is the window's inventory of what you have
   * open, and every decision about what *exists* is made one level up. Empty by
   * default so a `Sidebar` rendered on its own — a test, the harness — draws the
   * app rather than requiring a machines bridge to exist.
   */
  machines?: readonly SidebarMachine[]
  /**
   * The servers this window has a shell open on, and the shells under each.
   *
   * A prop for the same reason `machines` is: this component is the window's
   * inventory of what you have open, and every decision about what *exists* is
   * made one level up. Empty by default, which is the ordinary case — a person
   * who has never opened a terminal on a server sees nothing here at all.
   *
   * Unlike `machines`, a group here appears only when something is open on it.
   * `machines/servers/server-sessions.ts` carries the argument in full; the
   * short version is that a machine's heading is drawn because the machine is
   * *reachable*, which is a live fact worth a row, and a server has no
   * equivalent state — it is a stored address that this app never dials to find
   * out about, so a heading per stored server would be a permanent row saying
   * nothing in the list whose whole job is to answer what you have open.
   */
  servers?: readonly SidebarServer[]
  /*
   * There was an `activeMachineSession` here — a `{ machineId, sessionId }` pair
   * naming the remote session on screen, so this rail could highlight its row.
   *
   * It is gone, and what replaced it is `activeTabId` carrying that session's
   * tab id like any other. The pair existed because a remote session had no tab,
   * and the argument for keeping it a pair was that joining two handles into one
   * string would make every caller learn the joining rule. That is still true and
   * is still the reason `machineTabId` exists — it is the one function that
   * knows the rule, and both ends of this now call it. What changed is that a
   * remote session *has* a tab, so a second way of saying "this one is selected"
   * would be two answers to the question the rail asks most often.
   */
  /**
   * Whether to draw the bell beside Settings — i.e. whether the Alerts feature
   * is installed and on.
   *
   * A boolean here and the question asked in `App.tsx`, exactly like `browser`
   * above: this component is the window's inventory of what you have open, and
   * every decision about what *exists* is made one level up, next to the rest
   * of the gating. It defaults to true so a `Sidebar` rendered on its own shows
   * the app rather than a subset of it.
   *
   * Unlike the globe, an absent bell is not drawn as an offer. The globe is the
   * only way into the browser pane; Alerts is still reachable by name from the
   * command palette, which is where the offer to install it appears.
   */
  alerts?: boolean
  /**
   * How many alerts are waiting, for the dot on the bell and for its
   * accessible name.
   *
   * Zero draws no dot — a mark that is always lit is a mark that says nothing.
   * Nothing in `App.tsx` feeds this yet and that is deliberate rather than
   * unfinished: the only thing that knows the number is a scan that reads every
   * transcript in the project, and running that on a timer for a dot nobody
   * asked for is a cost the window should not pay by default. The contract is
   * here, drawn and tested, for whatever ends up owning that scan.
   */
  alertCount?: number
  /** Session ids with output nobody has looked at yet. */
  unread?: readonly string[]
  /**
   * The sessions that were open, did not come back, and are being kept.
   *
   * A row under the project it belonged to, saying what did not start and why,
   * with Try again beside it. `renderer/held-sessions.ts` has the account of the
   * bug this closes and `main/session-held.ts` the mechanism; what matters here
   * is that the rail is where it has to be *seen*. When four of Asad's sessions
   * failed to restart on 2026-08-16 the app wrote a warning to a log nobody had
   * opened and drew a window that looked completely normal.
   *
   * Defaults to none, like every other optional prop on this component, so a
   * `Sidebar` rendered bare shows the app rather than a subset of it — and so
   * that the ordinary case, which is every launch where nothing failed, adds
   * nothing to the rail at all.
   */
  held?: readonly HeldSessionView[]
  /** Held keys with an attempt in flight, so the row can say so and not fire twice. */
  heldRetrying?: readonly string[]
  onRetryHeld?(key: string): void
  onForgetHeld?(key: string): void
  /**
   * Where the top strip's promoted order is kept — session storage, so an
   * arrangement survives a renderer reload and not an app restart; see
   * `defaultStorage`. Injectable for tests, and spelled the same way as
   * `WorkspaceTabStrip`'s own prop on purpose: the two components have to meet
   * on one store, so a test that gives one of them a stand-in has to be able to
   * give the other the same one.
   */
  storage?: Storage | null
  /**
   * A count on a panel row, drawn as `.sb-badge`.
   *
   * Nothing in `App.tsx` has ever passed this, and until 2026-08-17 the only
   * thing that exercised it was the Alerts test — Alerts was the one view with
   * a number, and it is a dialog now with a dot of its own (`alertCount`). So
   * this is a facility for the nine remaining rows that no row currently uses.
   * Left in place rather than deleted because removing it is a decision about
   * those rows, not about Alerts, and this change is about Alerts.
   */
  badges?: Partial<Record<PanelId, number>>
  /**
   * Showing because the pointer is near the edge, rather than because it is
   * pinned. It floats over the content in that state instead of taking room
   * from it, and the arrow in its gutter offers to keep it.
   */
  peeking?: boolean
  /**
   * The update notice, rendered above Settings.
   *
   * Passed in rather than imported so it stays mounted from `App.tsx`, which is
   * where the wiring test can see it and where its bridge subscription belongs.
   * It sits here because an update is the same category of thing as Alerts and
   * Settings — the app talking to you about itself — and none of the three has
   * anything to do with the work in the middle of the window.
   */
  update?: ReactNode
  /**
   * What this window knows about the copilot, for the pinned row at the top.
   *
   * Optional, and absent is a real state rather than a missing prop: the row is
   * still drawn and still opens the window — it simply carries no status dot and
   * makes no claim. That is what a `Sidebar` mounted on its own in a test or in
   * `.harness/` should show, for the same reason `panels` defaults to all of
   * them: the component is the window's inventory, and rendering it bare should
   * show the app rather than a subset of it.
   *
   * `active` is whether the copilot's own window is the one on screen. It is
   * asked of the caller rather than derived from `activeTabId`, because the
   * copilot's tab is deliberately not in the `tabs` this component draws — see
   * the filter in the body.
   */
  copilot?: {
    stage: CopilotStage
    state: CopilotStateView | null
    active?: boolean
    /**
     * What it is called — user data, read out of its own instruction file by
     * `useCopilotSetup` and passed down rather than reached for here.
     *
     * A prop and not an import, because a rail mounted on its own in a test or
     * the harness has nobody to ask; `CopilotEntry` falls back to this app's
     * word for an unnamed copilot, which is the same fallback every other reader
     * of the name uses.
     */
    name?: string
  } | null
  /**
   * Open the copilot's window, optionally landing on one turn of its action log.
   *
   * The `focus` argument is what makes the copilot-sessions group's "why does
   * this exist" a real link rather than a heading: it is the id of the turn that
   * started the session, and it now travels into the copilot's own window, which
   * draws that row above its conversation. It used to travel to a page through
   * `showPanel(id, focus)`; the destination moved when the copilot stopped being
   * a page, and the link did not have to.
   */
  onOpenCopilot?(focus?: string | null): void
  onSelectTab(id: string): void
  onCloseTab(id: string): void
  onSelectPanel(id: PanelId): void
  /**
   * Start a session — or, for every caller here except Continue, *ask* how.
   *
   * The rail says nothing about which of those two it is, and that is the
   * point: the decision is one line in `App.tsx`, where the dialog is mounted,
   * and it went the other way on 2026-08-17. Asad: *"if we click directly on
   * the whole button it opens a quick window. We don't want this quick window
   * at all. We just always wanted this pop-up to come up so we choose which
   * type of terminal we want to open."*
   *
   * So there is one prop and one press. A `onNewSessionOptions` used to sit
   * beside this one, drawn as the chevron half of a split button, and it is
   * gone: *"remove this drop-down button at all from the side panel."* Two
   * controls one pixel apart that start a session in two different ways is
   * precisely the thing he was objecting to, and the fix is not to relabel the
   * second one.
   *
   * `resume` is the exception and stays immediate. Continuing the last
   * conversation in a folder is not a question about which kind of terminal to
   * open — it is a named command with one answer.
   */
  onNewSession(projectPath?: string, resume?: boolean): void
  /**
   * Whether the agent a new session would run has a resume command at all.
   *
   * Decides whether the Continue-last-session glyph exists on a project heading.
   * Defaults to false, so a host that does not answer the question draws no
   * control rather than one that silently starts a fresh session — see the
   * button itself, and `canResumeDefault` in `App.tsx`.
   */
  canResume?: boolean
  onNewBrowserTab(): void
  onOpenProject(): void
  onCloseProject(path: string): void
  onOpenSettings(): void
  /**
   * Open the alerts pop-up.
   *
   * Beside `onOpenSettings` and not part of `onSelectPanel`, because that is
   * the difference the whole change is about: *"notifications should be a
   * pop-up just like settings, not a full page."* Selecting a panel navigates
   * the window; these two open something over it and leave the window alone.
   */
  onOpenAlerts(): void
  /** Start a session on another machine — the same dialog, machine already chosen. */
  onNewMachineSession?(machineId: string): void
  /**
   * End every session on one machine, and leave the machine paired.
   *
   * The rail reports the press and owns none of it. What it costs — one
   * confirmation naming how many sessions rather than one dialog per session,
   * the `close` frames themselves, and the group folding away afterwards — lives
   * in `App.tsx` beside the rest of the machine state, for the same reason
   * `machines` is a prop: every decision about what exists is made one level up.
   */
  onCloseMachine?(machineId: string): void
  /**
   * Open another terminal on one server.
   *
   * No dialog behind it, and that is the difference from the machine ＋ above
   * rather than an omission. The New session dialog exists to ask three
   * questions — which folder, which agent, which login — and this app can answer
   * none of them about somebody else's server: it has no list of folders over
   * there, no account there, and no way to know what is installed. A dialog with
   * every field blank is a step, not a question. So the press opens a shell,
   * which is the honest floor, and the door to anything more is the server's own
   * page.
   */
  onNewServerSession?(serverId: string): void
  /**
   * Close every terminal open on one server, and keep the server.
   *
   * Exactly what Close means on a machine's heading, one kind down: *"it should
   * not disconnect the remote account. It will just close all of the sessions
   * from that PC."* Here the sessions end, the group goes because it is empty,
   * and nothing about the stored server changes — it is still in the Machines
   * panel, still with its sign-in, one press from another terminal. Forgetting a
   * server is a different act with its own button on its own page, and this
   * cannot reach it.
   */
  onCloseServer?(serverId: string): void
  /** Keep it open (peeking) or put it away (pinned). */
  onToggleCollapsed(): void
  onPeekStart(): void
  onPeekEnd(): void
  onStartResize(event: MouseEvent): void
}

function Glyph({
  path,
  size = 17,
  className,
}: {
  path: string
  size?: number
  className?: string
}) {
  return (
    <svg
      className={className ? `sb-glyph ${className}` : 'sb-glyph'}
      width={size}
      height={size}
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

const PLUS = 'M12 5.5v13M5.5 12h13'
/* `DISCLOSURE` used to be here. The only thing that drew one was the project
   heading, and that heading is `GroupHead` now — which owns the triangle along
   with the three actions beside it, so a machine's heading folds with the same
   glyph rather than a second copy of the same path. */

/**
 * The fold key for a machine's group.
 *
 * Projects and machines share one folded set — see the state's own comment — and
 * this is what keeps the two key spaces apart. A project's key is an absolute
 * path, which on every platform this app runs on begins with a separator or a
 * drive letter, so nothing prefixed like this can ever be mistaken for one.
 */
function machineFoldKey(machineId: string): string {
  return `machine:${machineId}`
}

/**
 * The fold key for a server's group.
 *
 * A third key space in the same set, kept apart from the other two the same way
 * and for the same reason. A server id and a machine id are both UUIDs, so
 * without a prefix of its own a server whose id happened to match a machine's
 * would fold both — which is not a real risk with UUIDs, and is exactly the kind
 * of thing that stops being true the day somebody keys one of them on a name.
 */
function serverFoldKey(serverId: string): string {
  return `server:${serverId}`
}
/**
 * The arrow in the gutter, and the only control that opens or closes the rail.
 *
 * It points the way the *content's* left edge is about to move, which is the
 * only reading that stays true in both directions: pinned, the arrow points
 * left and the content grows leftwards when you press it; peeked, it points
 * right and pressing it pushes the content over to make permanent room.
 */
const CHEVRON_LEFT = 'M14.5 6.5 9 12l5.5 5.5'
const CHEVRON_RIGHT = 'M9.5 6.5 15 12l-5.5 5.5'
const RESUME = 'M4 12a8 8 0 1 0 2.7-6M4 4.5v4h4'
const CLOSE = 'M6.5 6.5l11 11M17.5 6.5l-11 11'
/**
 * A session that did not come back: an outline circle with a bar through it.
 *
 * Where a live row has its `StatusDot`, so the eye finds the same column, and
 * deliberately *not* a dot in a warning colour. A held row is not a session in
 * a bad state — it is the absence of one, and painting it as a running session
 * that has gone red is the same confusion this whole change is about: the app
 * answering "we could not start your agent" with something shaped like a
 * working session.
 *
 * Not a ✕ either. That glyph is the close button four pixels to its right, and
 * a row whose leading mark reads "deleted" beside a button that means "delete"
 * would say the work is already gone. It is not; that is the point of the row.
 */
const HELD = 'M12 3.6a8.4 8.4 0 1 0 0 16.8 8.4 8.4 0 0 0 0-16.8M8.2 12h7.6'
/**
 * Send this window to the top strip: an arrow to the top-right corner.
 *
 * There was a pencil next to this until 2026-08-17 and there is not any more —
 * Asad: *"I don't want this edit button here. Just double click should make it
 * editable. That's it."* Losing it moved this control into the slot the pencil
 * was in, which is where he asked for it, and it took the glyph with it:
 * *"it should be some arrow like to the corner to maybe right top corner, not
 * straight to up and without this line above there."*
 *
 * So: a diagonal shaft with a corner bracket at its head, and no bar over the
 * top. The strip tab's fold-away control is the exact mirror of this through the
 * diagonal, so the pair reads as out and back rather than as two unrelated
 * marks. Not a pin, not a star: both of those mean "favourite" everywhere else,
 * and this is a placement, not a rating.
 */
const TO_STRIP = 'M7.5 16.5 16.5 7.5M10.5 7.5H16.5V13.5'
/**
 * "Why does this exist" — a question mark in a ring, on a copilot-started row.
 *
 * A question mark rather than an info `i`, because the row is answering a
 * question a person actually asks out loud when a tab they did not open appears
 * in their sidebar. It only ever appears on a row that *has* an answer: a
 * copilot session whose spawning turn is not known — one restored from a
 * previous run of the app, where the origin survives on the session metadata and
 * the log row is not loaded — draws no button rather than one that lands
 * nowhere.
 */
const WHY = 'M12 3.5a8.5 8.5 0 1 0 0 17 8.5 8.5 0 0 0 0-17M9.6 9.4a2.5 2.5 0 0 1 4.85.8c0 1.7-2.45 2.05-2.45 3.55M12 17.1h.01'
const GEAR =
  'M12 15.1a3.1 3.1 0 1 0 0-6.2 3.1 3.1 0 0 0 0 6.2zM19.3 14.6a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5v.2a2 2 0 1 1-4 0v-.1a1.6 1.6 0 0 0-1.1-1.5 1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1h-.2a2 2 0 1 1 0-4h.1a1.6 1.6 0 0 0 1.5-1.1 1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5v-.2a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1h.2a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z'

/**
 * The sidebar. One of them.
 *
 * What used to be here was a 48px icon rail, a 300px drawer with its own
 * header and collapse button, a tab strip in the window title bar and a
 * segmented control in a bar of its own — four pieces of chrome answering the
 * same question. This is that question asked once: what do you have open, and
 * what would you like to look at.
 *
 * The rows are quiet on purpose. Nothing here is boxed, nothing is separated by
 * a line, and the only colour is the status dot next to a session that is
 * actually doing something.
 */
export function Sidebar({
  width,
  projects,
  tabs,
  activeTabId,
  activePanel,
  panels = PANELS,
  browser = true,
  browserOffer = null,
  machines = [],
  servers = [],
  onNewMachineSession = () => {},
  onCloseMachine = () => {},
  onNewServerSession = () => {},
  onCloseServer = () => {},
  alerts = true,
  alertCount = 0,
  unread = [],
  held = [],
  heldRetrying = [],
  onRetryHeld,
  onForgetHeld,
  storage,
  badges,
  peeking = false,
  update,
  copilot = null,
  onOpenCopilot,
  onSelectTab,
  onCloseTab,
  onSelectPanel,
  onNewSession,
  canResume = false,
  onNewBrowserTab,
  onOpenProject,
  onCloseProject,
  onOpenSettings,
  onOpenAlerts,
  onToggleCollapsed,
  onPeekStart,
  onPeekEnd,
  onStartResize,
}: Props) {
  /**
   * The session row that has turned into a field, and what has been typed.
   *
   * Local, and one at a time: two rows in edit at once is two half-finished
   * names and no way to tell which the Return key belongs to.
   */
  const [renaming, setRenaming] = useState<{ id: string; draft: string } | null>(null)
  /**
   * Whether the field is still live.
   *
   * Escape and blur both end a rename and they end it in opposite ways, and
   * they can arrive in that order: cancelling unmounts the input, which in some
   * browsers fires a blur on the way out. Without this the cancel would be
   * followed by a save of the very draft it had just thrown away. The ref is
   * cleared first, so whichever of the two arrives second finds nothing to do.
   */
  const editing = useRef(false)
  const sessionRename = useSessionRename()

  /**
   * The strip's promoted order, shared with `WorkspaceTabStrip`.
   *
   * Read here so a row can say whether it is already up there, and written so
   * it can be put there without a drag — see `usePromotedOrder`. The rail is
   * the only place in the window that lists *everything*, so it is the only
   * place the non-drag route could sensibly live.
   */
  const [promotedOrder, setPromotedOrder] = usePromotedOrder(
    storage === undefined ? undefined : storage,
  )
  const stripFull = promotedOrder.length >= MAX_PROMOTED

  /**
   * The thing that follows the cursor during a drag, and the row it left.
   *
   * A browser's default drag image is a translucent photograph of the source
   * element — here, a 264px-wide sidebar row, dragged towards a strip whose
   * tabs are half that. It is the clearest possible signal that nothing has
   * been designed. `setDragImage` takes any rendered element, so the ghost is a
   * real node in this tree, styled in `shell.css` as a copy of a strip tab, and
   * filled in imperatively at `dragstart` because that handler has to hand the
   * element over *synchronously* — a React state update would arrive a frame
   * after the browser had already taken its snapshot.
   *
   * It lives off-screen rather than behind `display: none`, which is the one
   * thing that makes `setDragImage` silently fall back to the default.
   */
  const ghostRef = useRef<HTMLDivElement | null>(null)
  const ghostLabelRef = useRef<HTMLSpanElement | null>(null)
  const ghostPathRef = useRef<SVGPathElement | null>(null)
  const [draggingId, setDraggingId] = useState<string | null>(null)

  const beginDrag = (event: DragEvent<HTMLDivElement>, tab: WorkspaceTab, label: string): void => {
    /*
     * A press that landed on one of the row's own buttons is a press, not a drag.
     *
     * This is the whole of *"the ✕ sometimes does not work"*. The row is
     * `draggable`, so four pixels of hand movement between button-down and
     * button-up turns the press into a drag — and a drag **cancels the click**,
     * so the ✕ under the finger never hears about it. Measured, with the events
     * logged, rather than reasoned about; `dragStartedOnControl` carries the
     * evidence and explains why the check is a hit-test on the press point
     * instead of the two spellings that look right and are not.
     *
     * Refusing here rather than in each button means the guard covers the ✕, the
     * promote toggle and the "why does this exist" link at once, and covers the
     * next control anybody adds as soon as it wears `data-no-drag`.
     */
    if (dragStartedOnControl(event.clientX, event.clientY)) {
      event.preventDefault()
      return
    }
    startTabDrag(event.dataTransfer, tab.id)
    setDraggingId(tab.id)

    const ghost = ghostRef.current
    if (!ghost || !ghostLabelRef.current || !ghostPathRef.current) return
    // `textContent`, never `innerHTML`: a session's title is written by the
    // agent running in it, and this app does not hand agent output to a parser.
    ghostLabelRef.current.textContent = label
    ghostPathRef.current.setAttribute('d', KIND_ICON[tab.kind])
    // Held near its leading edge, the way a browser holds a dragged tab — so
    // the pointer is over the tab rather than trailing a card behind it.
    event.dataTransfer.setDragImage(ghost, 16, 13)
  }

  /** Put a window in the top strip, or fold it back into this rail. */
  const togglePromoted = (id: string): void => {
    setPromotedOrder(
      promotedOrder.includes(id)
        ? demote(promotedOrder, id)
        : promote(promotedOrder, id, promotedOrder.length),
    )
  }

  /**
   * Whether the *user* has done anything since the rename field opened.
   *
   * This exists because of a focus steal that is invisible in a screenshot and
   * was found by driving the real app. Double-clicking a row that is not already
   * the open session does two things: the first click switches to that session,
   * and the second opens the field. The terminal for the newly-selected session
   * then focuses its own textarea — measured, with timestamps, in the running
   * window: the field appears at t+73ms, `xterm-helper-textarea` takes focus at
   * t+75ms, and the field is gone at t+76ms, because a blur means "save and
   * close" and the field never got to see a keystroke. Renaming worked on the
   * row you were already in and silently did nothing on any other, which is the
   * worst shape a bug can have.
   *
   * `relatedTarget` cannot tell the two cases apart on its own — a real click
   * into the terminal reports the same element as the steal does. What does tell
   * them apart is that a click or a keypress is a thing the user *did*, and it
   * arrives before the focus moves. So a blur with no user action behind it is
   * not a dismissal, and the field takes its focus back instead of closing.
   */
  const userActed = useRef(false)

  const beginRename = (id: string, label: string): void => {
    editing.current = true
    userActed.current = false
    setRenaming({ id, draft: label })
  }

  /** End the rename, keeping what was typed or throwing it away. */
  const endRename = (save: boolean): void => {
    if (!editing.current) return
    editing.current = false
    // A blank field is a cancel — `userSessionTitle` refuses it, and a session
    // called nothing is a row in this rail with nothing written on it.
    if (save && renaming) sessionRename.rename(renaming.id, renaming.draft)
    setRenaming(null)
  }

  /*
   * Mark anything the user does while a rename field is open.
   *
   * On the document and in the capture phase, so it sees the action wherever it
   * lands — including the click that dismisses the field, which by definition
   * happens somewhere other than the field. Registered only while a field is
   * open, and reset by `beginRename`, so the double-click that *opened* it does
   * not count as an action taken since.
   */
  useEffect(() => {
    if (!renaming) return
    const mark = (): void => {
      userActed.current = true
    }
    document.addEventListener('pointerdown', mark, true)
    document.addEventListener('keydown', mark, true)
    return () => {
      document.removeEventListener('pointerdown', mark, true)
      document.removeEventListener('keydown', mark, true)
    }
  }, [renaming])

  /**
   * Folded groups, by key. Local: it is a view state, not a preference.
   *
   * One set for projects and machines together, because folding is one gesture
   * and a second set would be a second place for it to get out of step. A
   * project's key is its path and a machine's is {@link machineFoldKey}, which
   * prefixes the id — an absolute path and a prefixed UUID cannot collide, and
   * the prefix is what makes that a stated rule instead of a coincidence.
   */
  const [folded, setFolded] = useState<ReadonlySet<string>>(new Set())
  const toggleFold = (path: string) =>
    setFolded((current) => {
      const next = new Set(current)
      if (!next.delete(path)) next.add(path)
      return next
    })

  /**
   * Everything open — minus the copilot itself.
   *
   * The copilot became a window on 2026-08-17, which means it is in `tabs` like
   * every other session: a pill in the strip, a terminal in the pane, the full
   * control cluster in the bar. What it must not become is a *row down here*,
   * because it already has one — the pinned entry at the top, which is where
   * Asad asked for it and which is the only place a singleton belongs. Drawn
   * both ways it would be the same session listed twice in one rail, once at the
   * very top and once under a project heading for its own home folder, three
   * centimetres apart.
   *
   * By `isCopilot` rather than by folder, because that flag is the fact — see
   * `WorkspaceTab.isCopilot`, which also explains why it is not the same
   * question as `origin === 'copilot'` immediately below.
   */
  const listed = tabs.filter((tab) => !tab.isCopilot)

  const browserTabs = listed.filter((tab) => tab.kind === 'browser')

  /**
   * Yours, and the copilot's, split once.
   *
   * A session the copilot started is an ordinary session in every way that
   * matters — same folder, same account, same confinement, same ✕ — and it is
   * not ordinary in one: nobody in this window asked for it. Dropping it into
   * the run under your project heading, between two sessions you opened
   * yourself, with nothing saying where it came from, is the one thing an app
   * that can start processes on its own must not do. So they come out here and
   * go under a heading of their own, below.
   *
   * Split in one pass rather than filtered twice, because the two halves have
   * to partition: a session in neither is a row missing from the rail, and one
   * in both is a row drawn twice. See `copilot/session-origin.ts`.
   */
  const { mine: ownTabs, copilot: copilotTabs } = partitionByOrigin(listed)

  const sessionsIn = (path: string) =>
    ownTabs.filter((tab) => tab.kind === 'session' && tab.projectPath === path)
  /** Sessions whose project has been closed out from under them. */
  const orphaned = ownTabs.filter(
    (tab) =>
      tab.kind === 'session' && !projects.some((project) => project.path === tab.projectPath),
  )

  /** Held sessions for one project, in the order they were tabs in. */
  const heldIn = (path: string) => held.filter((row) => row.cwd === path)
  /**
   * Held sessions with no project heading to sit under.
   *
   * The common cause is the one that produced the entry: `restoreOpenSessions`
   * adds a project row for every remembered folder that still exists, so a held
   * session with no project is usually a *skipped* one — the folder was not
   * there when the app looked. Those are the rows it is most important not to
   * drop, because "the folder it ran in is no longer on this machine" is
   * frequently a volume that has not mounted or a distribution that has not
   * woken, and the row is the only offer to try again.
   */
  const heldLoose = held.filter((row) => !projects.some((project) => project.path === row.cwd))

  const labelFor = (tab: WorkspaceTab, index: number, projectName?: string): string =>
    tab.kind === 'session' ? sessionLabel(tab.label, index, projectName) : tab.label

  /**
   * One held session, as a row.
   *
   * Two lines rather than one, and the second line is the whole reason the row
   * exists: a rail that said only "Claude Code — did not start" would be the
   * app admitting a failure and still making somebody go and find out what it
   * was. The sentence is the main process's own, verbatim, and is the same one
   * in the app log — one event, one explanation, wherever you read it.
   *
   * The folder is named only when there is no heading above already naming it.
   * Under `terminaldeck`, a row reading "Claude Code — terminaldeck" is the same
   * word twice, twenty pixels apart; the same argument `rowsFor` makes about
   * qualifiers.
   *
   * When it *is* named, it goes on the second line rather than beside the agent,
   * and that was measured rather than chosen: `Claude Code — ClaudeImza` on a
   * 264px rail comes out as **Claude Code — Claude…**, so the one row that has
   * to identify its own folder was the one row whose folder was cut off. The
   * second line wraps, so it has the width, and the agent — which is what the
   * row is *about* — keeps the line it was already readable on.
   *
   * Try again is a `sb-row-action` like every other hover control on a rail row,
   * but this one is drawn always rather than on hover. A control that appears
   * only under the pointer is fine for closing a tab you can see; it is wrong
   * for the single offer to recover work, on a row a person is reading precisely
   * because something went wrong.
   */
  const heldRow = (row: HeldSessionView, nameFolder: boolean) => {
    const agent = heldAgentName(row.provider)
    const trying = heldRetrying.includes(row.key)
    return (
      <li key={row.key} className="sb-held">
        <div className="sb-row sb-held-row">
          <Glyph path={HELD} size={15} className="sb-held-mark" />
          <span className="sb-label">{agent}</span>
          <button
            type="button"
            className="sb-row-action sb-held-retry"
            // `title` carries the folder as well, because the label above drops
            // it under a project heading and this is the one control whose
            // press starts a process somewhere.
            title={trying ? `Starting ${agent} in ${row.cwd}…` : `Try ${agent} again in ${row.cwd}`}
            aria-label={`Try ${agent} again in ${row.cwd}`}
            disabled={trying || !onRetryHeld}
            onClick={() => onRetryHeld?.(row.key)}
          >
            <Glyph path={RESUME} size={13} />
          </button>
          <button
            type="button"
            className="sb-row-action"
            title="Stop keeping this session"
            aria-label={`Stop keeping ${agent} in ${row.cwd}`}
            disabled={!onForgetHeld}
            onClick={() => onForgetHeld?.(row.key)}
          >
            <Glyph path={CLOSE} size={13} />
          </button>
        </div>
        {/* Not `aria-hidden`, and not a `title`: this sentence is the content of
            the row for anyone reading it with anything. The folder is a span in
            front of it rather than words folded into it — the reason is the main
            process's own sentence, verbatim, and the log carries the same one. */}
        <p className="sb-held-why">
          {nameFolder && <span className="sb-held-where">{folderName(row.cwd)}</span>}
          {trying ? 'Trying again…' : row.reason}
        </p>
      </li>
    )
  }

  /**
   * One run of rows, with a qualifier on any that its name alone cannot
   * identify.
   *
   * Per run rather than over the whole rail, because a run is what a person
   * compares: two sessions called "Session 1" under two different project
   * headings are already told apart by the heading, and qualifying those would
   * put the folder name on a row three pixels below the same word. Inside one
   * run the folder is by definition no help either — which is why
   * `tabQualifiers` falls through it to the session id.
   */
  /**
   * `projectName` is a string for a run that sits under one project heading,
   * and a function for one that does not.
   *
   * The Copilot sessions group is the second kind: it is one flat run that can
   * hold sessions from several folders, so there is no single heading to be
   * redundant with — and without a folder name per row, `sessionLabel` finds a
   * session still wearing its folder's name, decides that name is worth
   * showing, and prints **terminaldeck** where the copilot's own page prints
   * **Session 1**. Two names for one session, twenty pixels apart. Seen on
   * screen, which is the only way this class of thing ever gets found here.
   */
  const rowsFor = (
    run: readonly WorkspaceTab[],
    projectName?: string | ((tab: WorkspaceTab) => string | undefined),
  ) => {
    const nameOf = typeof projectName === 'function' ? projectName : () => projectName
    const labels = run.map((tab, index) => labelFor(tab, index, nameOf(tab)))
    // `showAccounts`, not `namesAccounts`: the question is whether the caption
    // is on the line, and on a rail too narrow to carry one it is not — so
    // there the account separates nothing and the id still has to.
    const qualifiers = tabQualifiers(run, labels, { accountsShown: showAccounts })
    return run.map((tab, index) => tabRow(tab, labels[index], qualifiers[index]))
  }

  /**
   * Whether the rows have to name the account each session belongs to.
   *
   * Only once more than one is in play — see `accountsWorthShowing`. Two
   * sessions in the same folder under two logins are otherwise the same row
   * twice, which is the thing this app must never make someone guess about.
   *
   * Two answers, not one, and the difference is the whole of the fix for a name
   * cut down to `S…`. `namesAccounts` is whether the fact is worth stating at
   * all; `showAccounts` is whether this rail is wide enough to state it on the
   * line without eating the session's name. When they disagree the fact moves
   * into the row's tooltip, because the name is the thing the row exists to
   * carry and the account is the thing that gives.
   */
  // Asked of the rows this rail actually draws. The copilot has an account like
  // any session, but it is not one of these rows — counting it would let it be
  // the second account that puts a caption on every other row in the list.
  const namesAccounts = accountsWorthShowing(listed)
  const showAccounts = accountsWorthShowing(listed, width)

  /**
   * The sign-in answers this window has already read, and not one probe more.
   *
   * The rail is the hard case for identity: it draws a row per session, it is on
   * screen for the whole life of the window, and asking who an account is signed
   * in as spawns that agent's CLI. A hook per row would start a process per row
   * on every mount — which is why the account chip probes exactly one account
   * and its menu probes the list only when opened.
   *
   * So this asks nobody. `useKnownSignIns` is a read of the answers those two
   * surfaces already paid for, and rows fall to the lower rungs of
   * `accountRail` — a chosen name, or nothing plus a tooltip — until one lands.
   * The payoff is the bug itself: the rail said `Default` while the chip forty
   * pixels above it said `app.imatch.ae@gmail.com`, and both now read the same
   * answer out of the same store in the same frame.
   */
  const knownSignIns = useKnownSignIns()

  /**
   * Whether this row offers a rename.
   *
   * Sessions only. A browser tab is named by the page it is showing, and the
   * next navigation would overwrite anything typed here — an app cannot offer
   * to keep a name it is about to replace. And only where there is a session
   * list to write into: outside a provider the affordance is absent rather than
   * drawn and inert, which is the rule this window holds itself to.
   */
  const canRename = (tab: WorkspaceTab): boolean =>
    /*
     * And not a session on another machine.
     *
     * `sessionRename` writes into *this* app's session store, keyed by session
     * id, and a remote session's id belongs to a store on a different computer.
     * Renaming one would have written a row nothing reads, so the field would
     * have accepted a name and the row would have gone back to what it said
     * before — a control that appears to work and does not, which is worse than
     * one that is absent. The far machine names its own sessions and pushes the
     * name; there is no verb on the wire for renaming one, so there is no
     * gesture here either.
     */
    /*
     * And not a shell on a server, for the same reason one letter along.
     *
     * `sessionRename` writes into this app's session store keyed by session id,
     * and a server shell has no row in that store at all — it is a tab this
     * window holds and nothing else. The field would have accepted a name and
     * the row would have gone straight back to what it said, which is a control
     * that appears to work and does not.
     */
    tab.kind === 'session' && !tab.machine && !tab.server && sessionRename.available

  const tabRow = (tab: WorkspaceTab, label: string, qualifier: string | null = null) => {
    /*
     * The row, become a field.
     *
     * In place, in the row the name is already on — the same gesture the
     * account chip's rows use, rather than a second one invented here. A form,
     * so Return submits with no button beside the field: the rail is 264px
     * wide and a Save button on that line would leave the name about ten
     * characters to live in.
     *
     * The status dot stays, and that is not decoration: without it the row
     * loses 15px of lead-in and the text jumps sideways at the moment the field
     * appears, which reads as the row having been replaced rather than opened.
     */
    if (renaming?.id === tab.id) {
      return (
        <li key={tab.id}>
          <form
            className="sb-row sb-open sb-renaming"
            onSubmit={(event) => {
              event.preventDefault()
              endRename(true)
            }}
          >
            {tab.kind === 'session' ? (
              <StatusDot status={tab.status ?? 'idle'} />
            ) : (
              <Glyph path={KIND_ICON.browser} size={15} />
            )}
            <input
              className="sb-rename-input"
              value={renaming.draft}
              // The same budget every other title in this app is cut to. Held
              // at the field as well as in `userSessionTitle` so the limit is
              // visible while typing rather than applied silently on save.
              maxLength={MAX_TITLE_LENGTH}
              autoFocus
              aria-label={`New name for ${label}`}
              onChange={(event) => setRenaming({ id: tab.id, draft: event.target.value })}
              onKeyDown={(event) => {
                if (event.key !== 'Escape') return
                event.preventDefault()
                // Stopped so Escape does not travel on to anything else in the
                // window that treats it as "close" — the field is the innermost
                // thing open. The same rule `useChipMenu` follows.
                event.stopPropagation()
                endRename(false)
              }}
              // Clicking away keeps the name, the way a Finder or an editor
              // sidebar does. The account chip's field has no blur rule because
              // it lives inside a menu that dismisses itself; this one has
              // nothing to dismiss it, so without this it would sit open for as
              // long as the app ran.
              //
              // Unless nothing the user did caused the blur — see `userActed`.
              // The terminal of a session you have just switched to focuses
              // itself a couple of milliseconds after this field appears, and
              // treating that as "clicked away" closed the field before a
              // single key could be typed. The focus is taken back on the next
              // frame rather than inside the handler, because a `focus()` in
              // the middle of a `blur` is a fight the browser arbitrates and
              // Chromium does not always give to the caller.
              onBlur={(event) => {
                if (!userActed.current) {
                  const field = event.currentTarget
                  requestAnimationFrame(() => field.focus())
                  return
                }
                endRename(true)
              }}
            />
          </form>
        </li>
      )
    }

    /*
     * The drag source for the top strip.
     *
     * The strip has always been able to *receive* a tab — `workspace-tabs.ts`
     * defines the contract and `WorkspaceTabStrip` implements the drop — but
     * nothing in the app was ever draggable, so the feature looked built and did
     * nothing at all. Asad found it by trying to use it.
     *
     * `draggable` sits on the row rather than on the button inside it, so the
     * whole row is the grabbable thing; and the payload goes through
     * `startTabDrag` rather than a hand-written `setData`, because it travels
     * under a private MIME type. That matters more than it looks: a tab offered
     * as `text/plain` would be droppable into every terminal in this window, and
     * dropping a session onto a terminal would type its id at whatever agent is
     * running there.
     *
     * What `draggable` alone does not do is say any of that before the mouse
     * goes down. The three attributes below are the rest of the gesture: a grab
     * cursor from `shell.css`, a drag image that is the tab rather than a
     * photograph of this whole row, and a row that visibly empties while its
     * contents are somewhere else.
     */
    const promoted = promotedOrder.includes(tab.id)
    const renameable = canRename(tab)
    /** The copilot turn that started this session, or null. See `WHY`. */
    const turn = turnOf(tab)
    /*
     * What the row says about itself on hover.
     *
     * The rename hint is in here because the gesture that opens it is now a
     * double-click, and a gesture leaves nothing on screen. The button that used
     * to advertise it has gone — *"I don't want this edit button here"* — so the
     * only honest way to keep a hidden gesture discoverable is to say it in the
     * one place a person already looks when they wonder what a row can do. F2 is
     * named beside it because a double-click cannot be performed from a
     * keyboard, and losing the pencil must not mean losing the rename for anyone
     * who does not use a mouse.
     */
    /*
     * Who the row is running as, in words nobody generated.
     *
     * `tab.account.name` used to be printed here and on the line — the profile
     * *key* the main process mints for the machine's own install, so every row
     * in the rail read "Default" while the chip above the terminal read the
     * address. His words, and the reason this pass exists: *"Inside the terminal
     * page it is still showing selected account as Default and not showing the
     * email ID."*
     *
     * `accountRail` returns both halves off one rung, so the caption and this
     * sentence can never describe different things: the mailbox on the line, the
     * whole address in the tooltip, and — where the login has no address and no
     * name a person chose — nothing on the line and the install named in full
     * here. Which is the same trade the narrow rail already makes.
     */
    const rail = tab.account ? accountRail(tab.account, knownSignIns[tab.account.id]) : null
    /*
     * And where it is running, on the rows where that is not this computer.
     *
     * The row itself deliberately says nothing about it — that is the whole of
     * *"you don't need to give icon of the remote next to all of them"* — so the
     * hover is where the machine and its folder are stated. It is the same trade
     * the account caption already makes on a narrow rail: the identifying fact
     * moves off the line rather than being dropped, and the line keeps the name,
     * which is what the row exists to carry.
     *
     * The folder is the far machine's and is deliberately not offered anywhere
     * that would try to open it; see the `heading` in `App.tsx`, which hands
     * `FolderChip` a null for exactly this reason.
     */
    const where = tab.machine
      ? tab.projectPath
        ? `${tab.projectPath} on ${tab.machine.name}`
        : `on ${tab.machine.name}`
      : /*
           And the other kind of elsewhere, on the same line and for the same
           reason. The row itself says nothing about being on a server — the mark
           is on the heading and on nothing else, which is what he asked for
           about the machine rows: *"You don't need to give icon of the remote
           next to all of them — only above there."* No folder is named, because
           a shell on a server starts wherever that sign-in lands and this app
           has not asked where that is; claiming one would be the first lie on a
           screen built not to tell any.
        */
        tab.server
        ? `on ${tab.server.name}`
        : null
    const rowTitle = [
      label,
      qualifier,
      where,
      namesAccounts && rail ? rail.note : null,
      renameable ? 'double-click or F2 to rename' : null,
    ]
      .filter(Boolean)
      .join(' — ')
    return (
      <li key={tab.id}>
        <div
          className={`sb-row sb-open${!activePanel && tab.id === activeTabId ? ' active' : ''}${
            unread.includes(tab.id) ? ' unread' : ''
          }`}
          draggable
          data-dragging={tab.id === draggingId || undefined}
          /*
           * How the copilot's focus overlay says "that session, in the list".
           *
           * On the row rather than on `.sb-row-main` so the highlight covers the
           * whole row including its status dot and its actions — the row is the
           * thing a person means when they point at a session here, and a box
           * around only the label would look like a box around a word.
           */
          data-drive-anchor={`session-row:${tab.id}`}
          onDragStart={(event) => beginDrag(event, tab, label)}
          onDragEnd={() => setDraggingId(null)}
        >
          <button
            type="button"
            className="sb-row-main"
            title={rowTitle}
            aria-current={!activePanel && tab.id === activeTabId}
            onClick={() => onSelectTab(tab.id)}
            /*
             * The rename, in place of the button that used to open it.
             *
             * A double-click on a name that turns it into a field is the gesture
             * every file manager and every editor sidebar already has, which is
             * why he expected it here and was surprised to find a pencil
             * instead. The row's single click is unaffected: the browser
             * dispatches both clicks of a double-click as well, so this opens
             * the field on a row that has already been selected — which is the
             * right order anyway.
             */
            onDoubleClick={renameable ? () => beginRename(tab.id, label) : undefined}
            /*
             * The same thing from the keyboard. F2 rather than Return, because
             * Return on a focused button is "press it" and stealing that would
             * make the row unopenable without a mouse — the opposite of the
             * problem this is solving.
             */
            onKeyDown={
              renameable
                ? (event) => {
                    if (event.key !== 'F2') return
                    event.preventDefault()
                    beginRename(tab.id, label)
                  }
                : undefined
            }
          >
            {tab.kind === 'session' ? (
              <StatusDot status={tab.status ?? 'idle'} />
            ) : (
              <Glyph path={KIND_ICON.browser} size={15} />
            )}
            <span className="sb-label">{label}</span>
            {/*
              The fact that tells this row from the one beside it, and only when
              there is one to tell. Two sessions in a folder whose agents wrote
              the same sentence are the same row twice — reported exactly that
              way — and after the name, the folder and the account have all
              failed to separate them, the head of the session id is what is
              left. It reads as an identifier rather than as a word because it
              is one; `.sb-qualifier` sets it in the mono face for that reason.
            */}
            {qualifier && <span className="sb-qualifier">{qualifier}</span>}
            {/*
              And not both. Measured on the rendered rail at 264px: a row
              carrying a name, an eight-character id and an account caption has
              about 200px of line for roughly 250px of content, so the name was
              cut to `Update Cl…` and the account to **`a…`** — the same
              two-character stub the account column was reported for at a narrow
              width, arrived at from the other direction.

              The qualifier is what gives nothing up, because a row only has one
              when nothing else on it identifies it — including the account,
              which by then has already failed to separate this row from its
              twin (see `tabQualifiers`). So on those rows the caption is the
              least informative thing on the line, and it goes where it goes
              whenever this rail runs out of room: into the row's tooltip.
            */}
            {showAccounts && !qualifier && rail?.short && (
              <span className="sb-account">{rail.short}</span>
            )}
          </button>
          {/* Mail's idiom: a dot for a row with something new in it. It hides
              under the close button on hover, because at that point the pointer
              is on its way somewhere else. */}
          {unread.includes(tab.id) && <span className="sb-unread" aria-label="Unread output" />}
          {/*
            The link back to the turn that started this session.

            Half of the promise that "why does this exist" is one click in
            either direction — the copilot's own page holds the other half,
            listing what it started. It travels as a `focus` through the same
            `showPanel(id, focus)` a dashboard tile uses to land on the rows it
            counted, so this is an existing road rather than a new one.

            Drawn only when there is a turn to open. A copilot session restored
            from a previous run carries its origin on its metadata and has no
            log row loaded to point at, and a button that lands nowhere is worse
            than an absent one.
          */}
          {turn !== null && onOpenCopilot && (
            <button
              type="button"
              className="sb-row-action"
              // See `beginDrag`: the row is draggable, and without this marker a
              // press that slides a few pixels becomes a drag and this button's
              // click is cancelled.
              data-no-drag=""
              aria-label={`Why ${label} exists — open the copilot turn that started it`}
              title="Started by the copilot — open that turn"
              onClick={() => onOpenCopilot(turn)}
            >
              <Glyph path={WHY} size={13} />
            </button>
          )}
          {/*
            The same promotion, without the drag.

            A gesture that exists only under a mouse is half a feature, and this
            one is also invisible until somebody happens to try it. A button in
            the row is both halves at once: it is reachable from the keyboard
            like every other row action — `.sb-row:focus-within` reveals them —
            and it is the only thing in the window that *teaches* that a session
            can be sent to the top.

            It stays lit once the window is up there, rather than fading with
            the rest of the hover controls, because that is then the only thing
            on either side of the window saying which of these rows the strip is
            showing. `aria-pressed` says the same in words, and both read the
            one shared order, so they cannot disagree with the strip.
          */}
          <button
            type="button"
            className="sb-row-action sb-promote"
            // See `beginDrag`. This one is the sharpest case of the defect: the
            // button exists so the promotion can be done *without* a drag, and a
            // press on it was being eaten by the drag it was there to replace.
            data-no-drag=""
            aria-pressed={promoted}
            disabled={!promoted && stripFull}
            aria-label={
              promoted ? `Fold ${label} back into the sidebar` : `Show ${label} at the top`
            }
            title={
              promoted
                ? 'Fold back into the sidebar'
                : stripFull
                  ? `The top strip is full (${MAX_PROMOTED})`
                  : 'Show at the top'
            }
            onClick={() => togglePromoted(tab.id)}
          >
            <Glyph path={TO_STRIP} size={13} />
          </button>
          {/*
            The ✕ that actually ends things — and the one place in the window
            where that is true.

            There is a second ✕ in this window, on the tab in the top bar, and
            since 2026-08-17 it does something entirely different: it takes the
            tab off the bar and leaves the session running, right here, in this
            list. *"it should not delete the session… side panel will have
            everything inside, and above we just set a view which one we want to
            see."*

            Two identical glyphs with two outcomes, one of which is
            irreversible, is not a difference a person can be expected to
            remember. So this one says the consequence in its tooltip rather
            than naming the verb, and it turns `--color-critical` under the
            pointer while the strip's stays grey — see `.sb-close:hover`. The
            confirmation behind it is the third layer and the only one that
            catches somebody who was not looking.
          */}
          {tab.closable && (
            <button
              type="button"
              className="sb-row-action sb-close"
              // See `beginDrag`. This is the control he reported: without the
              // marker, a press that slides four pixels starts a drag of the row
              // and the close never happens.
              data-no-drag=""
              /*
                What this ✕ costs, said in the words of where the session is.

                A remote row's ✕ ends the session **on that machine** and leaves
                the machine paired — the same thing Close on its heading means,
                one session's worth: *"It will just close all of the sessions
                from that PC… it should not disconnect the remote account."* A
                person hovering the ✕ on a row that belongs to a computer they
                are not sitting at is owed both halves of that, because the
                second half is the one they are actually worried about.
              */
              aria-label={
                tab.machine
                  ? `Close ${label} on ${tab.machine.name}`
                  : tab.server
                    ? `Close ${label} on ${tab.server.name}`
                    : `Close ${label}`
              }
              title={
                tab.machine
                  ? `Close ${label} — ends the session on ${tab.machine.name}. That machine stays connected.`
                  : tab.server
                    ? /* Both halves again, and the second is the one that is
                         actually worrying somebody hovering a ✕ on a row that
                         belongs to a live server: this ends the terminal and
                         touches nothing else on the machine. */
                      `Close ${label} — ends this terminal on ${tab.server.name}. The server itself is left alone.`
                    : tab.kind === 'session'
                      ? `Close ${label} — ends the session`
                      : `Close ${label}`
              }
              onClick={() => onCloseTab(tab.id)}
            >
              <Glyph path={CLOSE} size={13} />
            </button>
          )}
        </div>
      </li>
    )
  }

  /** Views that live at the foot rather than in a labelled run. */
  const footPanels = panels.filter((panel) => panel.group === 'foot')

  return (
    <aside
      className="sidebar"
      style={{ width }}
      data-peek={peeking || undefined}
      aria-label="Sidebar"
      // The pointer arriving anywhere on the rail keeps a peek alive; the
      // pointer leaving starts the grace period. Both are no-ops while the rail
      // is pinned, because `beginPeek`/`endPeek` only move a state the pinned
      // sidebar does not read.
      onPointerEnter={onPeekStart}
      onPointerLeave={onPeekEnd}
    >
      {/* The traffic lights live over this, and now so does the one control
          that opens and closes the rail — which is what "next to the window
          buttons" means. It used to sit in the toolbar, on the far side of the
          window's own divider from the thing it acts on. */}
      <div className="sidebar-gutter">
        <button
          type="button"
          className="sidebar-arrow"
          onClick={onToggleCollapsed}
          aria-label={peeking ? 'Keep the sidebar open' : 'Hide the sidebar'}
          aria-expanded={!peeking}
          title={
            peeking
              ? tip('Keep the sidebar open', 'view.sidebar')
              : tip('Hide the sidebar', 'view.sidebar')
          }
        >
          <Glyph path={peeking ? CHEVRON_RIGHT : CHEVRON_LEFT} size={16} />
        </button>
      </div>

      <div className="sidebar-actions">
        <button
          type="button"
          className="sb-new"
          onClick={() => onNewSession()}
          // The ellipsis is the promise that a question is coming, which is the
          // whole of what changed here — the same word with no ellipsis used to
          // mean a session appearing with no questions asked.
          title={tip('New session…', 'session.new')}
        >
          <Glyph path={PLUS} size={16} />
          <span>New session</span>
        </button>
        {/*
          There was a chevron here until 2026-08-17 — the second half of a split
          button, where the press started a session and the chevron asked how.
          It is gone, and by name: *"remove this drop-down button at all from
          the side panel."*

          It was answering a real problem the wrong way round. Pressing New
          session spawned into the remembered folder on the default agent with
          nothing on screen saying which either of them was, so a way to ask was
          added *beside* it. The answer he wanted was for the button itself to
          ask. It does; there are two actions on this line now, and they are the
          two kinds of window this app opens.
        */}
        {/*
          Drawn whether or not the feature is installed, and it does the right
          thing either way: with the browser pane on it opens a tab, without it
          the same press installs the pane and opens one. What changes is the
          hover label and the offer dot — the shared mark in app.css — so the
          button reads as "there is something here" rather than as a control
          that is greyed out or, as it was, as nothing at all.
        */}
        {(browser || browserOffer !== null) && (
          <button
            type="button"
            className="sb-new-alt"
            data-offer={browserOffer !== null || undefined}
            onClick={onNewBrowserTab}
            aria-label={browserOffer ?? 'New browser tab'}
            title={browserOffer ?? 'New browser tab'}
          >
            <Glyph path={KIND_ICON.browser} size={16} />
          </button>
        )}
      </div>

      {/*
        `scroll-fade` because this is the rail's own scroll edge, and it was the
        sixth surface in the app found slicing a row in half at one.

        Measured on the rendered window: the region ended at y=832 with a
        session row sitting at 817, so the bottom row read as a horizontal cut
        through the middle of its letters, three pixels above the Remote and
        Settings foot. Every other scrolling region in this app already answers
        that with the one class in `app.css`, whose mask is driven by the scroll
        position so an unscrolled rail does not dim its own first row. There was
        no argument for the rail being the exception — only that nobody had put
        it on. `finish.test.ts` now lists this file beside the other five, so a
        seventh cannot be added without one.
      */}
      <div className="sidebar-scroll scroll-fade">
        {/*
          The pinned block, above the views and above what you have open.

          Placed by hand rather than looped out of `panels`, and that is the
          shape of the 2026-08-17 change: the copilot is not a view any more, so
          there is no `PanelSpec` to find here. It is a **window** — a pill in
          the strip, its own toolbar, its own account chip — and this row is how
          you reach it, exactly as the session rows below are how you reach
          those. Its name and glyph come from `copilot/identity.ts`, which is
          where they went when they left `panels.ts`.

          `onOpenCopilot`, not `onSelectPanel`: there is nowhere to navigate to.
          The same handler serves the "why does this exist" links further down,
          which pass the turn they want the window to land on. Drawn whether or
          not the window supplied one — the row is part of the app's inventory
          and a rail rendered bare should show the app rather than a subset of
          it, which is the same argument `panels` and `copilot` both default on.
        */}
        <CopilotEntry
          stage={copilot?.stage ?? null}
          state={copilot?.state ?? null}
          active={copilot?.active ?? false}
          {...(copilot?.name === undefined ? {} : { name: copilot.name })}
          onOpen={() => onOpenCopilot?.()}
        />

        {PANEL_GROUPS.map((group) => {
          const inGroup = panels.filter((panel) => panel.group === group.id)
          // A heading over nothing. Uninstalling every integration used to leave
          // the word "Integrations" sitting above a gap, which reads as a list
          // that failed to load rather than one that is empty on purpose.
          if (inGroup.length === 0) return null
          return (
            <section key={group.id} className="sb-group">
              <h2 className="sb-group-label">{group.label}</h2>
              <ul className="sb-list">
                {inGroup.map((panel) => {
                  const count = badges?.[panel.id] ?? 0
                  return (
                    <li key={panel.id}>
                      <button
                        type="button"
                        className={`sb-row sb-nav${activePanel === panel.id ? ' active' : ''}`}
                        aria-current={activePanel === panel.id}
                        // Read out of the keymap for this platform, never typed
                        // here: the rail used to carry its own ⌘1/⌘2/⌘3 tooltips
                        // and every one of them was wrong.
                        title={panel.command ? tip(panel.label, panel.command) : panel.label}
                        onClick={() => onSelectPanel(panel.id)}
                      >
                        <Glyph path={panel.icon} />
                        <span className="sb-label">{panel.label}</span>
                        {count > 0 && <span className="sb-badge">{count > 99 ? '99+' : count}</span>}
                      </button>
                    </li>
                  )
                })}
              </ul>
            </section>
          )
        })}

        <section className="sb-group">
          <div className="sb-group-head">
            <h2 className="sb-group-label">Open</h2>
            <button
              type="button"
              className="sb-group-action"
              onClick={onOpenProject}
              aria-label="Open a project"
              title={tip('Open a project', 'project.open')}
            >
              <Glyph path={PLUS} size={14} />
            </button>
          </div>

          {/* A statement, not a third way to do the same thing. The ＋ beside
              the heading opens a project, and the page filling the window says
              so with a button of its own — this line only has to explain why
              the list under it is empty. */}
          {/* `held` counts. A launch where every session failed to come back
              leaves no projects and no tabs, and without this the rail would
              print "Nothing open yet." directly above four rows saying your
              sessions did not start — the app contradicting itself in one
              glance, in the exact situation where a person is trying to work
              out what happened. */}
          {/* And the other machines count too.
 
              A shell opened on a server draws its own group *below* this one,
              so a rail with nothing local on it printed "Nothing open yet."
              two rows above a live session on somebody's server — the same
              self-contradiction the note above describes, arriving from the
              other direction. Found on screen during the walk of 2026-08-18,
              on a rail that had a server session open at the time.
 
              Sessions rather than groups, and the difference is real: a paired
              machine that is reachable and idle draws a heading with no rows
              under it, and over *that* the line is true — there is genuinely
              nothing open. A server group only exists while something is open
              on it, so it always counts. */}
          {projects.length === 0 &&
            browserTabs.length === 0 &&
            held.length === 0 &&
            machines.every((group) => group.sessions.length === 0) &&
            servers.every((group) => group.sessions.length === 0) && (
              <p className="sb-empty">Nothing open yet.</p>
            )}

          {projects.map((project) => (
            <div key={project.path} className="sb-project">
              {/*
                The heading, and it is the same component a machine's heading is.

                It used to be written out here — a fold arrow, a name, and three
                hover actions — and a machine's heading was written out
                separately, which is what produced the complaint this change
                answers: *"You will give this exactly same, like this kind of
                pill to drop, with same drop-down, same button — continue last
                session, new session, or close."* Two pieces of markup that must
                look identical forever is how they stop looking identical, so the
                markup moved into `GroupHead.tsx` whole and both callers use it.

                Every label and tooltip is still decided here, because they are
                the one thing that genuinely differs and the difference is about
                truth rather than wording — see the note in that file about the
                ⌘T on this ＋ and why a machine's ＋ must not carry it.
              */}
              <GroupHead
                name={project.name}
                title={project.path}
                open={!folded.has(project.path)}
                onToggle={() => toggleFold(project.path)}
                /*
                  Continue-last-session, and only where there is one to continue.

                  *"'Continue last conversation' is agent-specific."* It is, and
                  silently: `host-core.ts` falls back to the ordinary arguments
                  when the agent has no resume command, so on Gemini or a plain
                  shell this glyph started a **fresh** session and said nothing.
                  A control that cannot act is absent rather than live — see
                  `canResumeDefault` in `App.tsx`, which is where the question is
                  asked and why it is asked of the default agent.
                */
                {...(canResume
                  ? {
                      resume: {
                        label: `Continue the last session in ${project.name}`,
                        title: tip('Continue last session', 'session.resume'),
                        onPress: () => onNewSession(project.path, true),
                      },
                    }
                  : {})}
                add={{
                  label: `New session in ${project.name}`,
                  title: tip('New session', 'session.new'),
                  onPress: () => onNewSession(project.path),
                }}
                close={{
                  label: `Close ${project.name}`,
                  title: 'Close project',
                  onPress: () => onCloseProject(project.path),
                }}
              />
              {!folded.has(project.path) && (
                <ul className="sb-list sb-sessions">
                  {rowsFor(sessionsIn(project.path), project.name)}
                  {/* Under the sessions that did come back, not above them: the
                      list you scan first is the work that is running. Inside the
                      same `<ul>` so a held row sits exactly where that session's
                      row was, which is the whole promise the rail is making. */}
                  {heldIn(project.path).map((row) => heldRow(row, false))}
                </ul>
              )}
            </div>
          ))}

          {orphaned.length > 0 && <ul className="sb-list">{rowsFor(orphaned)}</ul>}
          {/* Held sessions whose folder has no heading — see `heldLoose`. They
              name their folder, because nothing above them does. */}
          {heldLoose.length > 0 && (
            <ul className="sb-list">{heldLoose.map((row) => heldRow(row, true))}</ul>
          )}
          {browserTabs.length > 0 && (
            <ul className="sb-list">{browserTabs.map((tab) => tabRow(tab, tab.label))}</ul>
          )}
        </section>

        {/*
          What the copilot started, under a heading of its own.

          Below "Open" rather than above it, because these are still windows you
          have open and the list you scan first is your own work. What the
          heading buys is that no row in your projects is a session you did not
          ask for — see `partitionByOrigin` — and that a person can tell at a
          glance whether the machine has been busy on its own.

          Rendered only when there are any. A heading over nothing reads as a
          list that failed to load, which is the same argument the Integrations
          run makes a few lines up.
        */}
        {copilotTabs.length > 0 && (
          <section className="sb-group">
            <h2 className="sb-group-label">Copilot sessions</h2>
            {/* The folder per row, because this run spans folders — see
                `rowsFor`. `tabQualifiers` then adds the folder name to any two
                rows the numbering alone cannot separate. */}
            <ul className="sb-list">
              {rowsFor(copilotTabs, (tab) =>
                tab.projectPath ? folderName(tab.projectPath) : undefined,
              )}
            </ul>
          </section>
        )}

        {/*
          Sessions on another machine, beside your own and not on a page of
          their own.

          Asad, 2026-08-17, having looked at the Remote page: *"The Remote page
          is for connecting only, not controlling. This is shit."* and then the
          instruction — *"Remote sessions belong in the sidebar, alongside local
          ones."* Until then they existed only inside Settings → Remote, in a
          pane that stopped existing when that panel closed, which is the whole
          of what he was objecting to.

          One heading per machine rather than one heading called "Remote",
          because two machines' sessions in one list is a list where the row you
          want is identified by nothing.

          ## The mark is on the heading and on nothing else

          It used to be on every row as well, and that is the thing he asked to
          have taken away, 2026-08-18: *"You don't need to give icon of the
          remote next to all of them — only above there, next to the PC, the
          remote device."* The rows below now go through `rowsFor` — the same
          function the project groups use — so a remote session is drawn by the
          same code, with the same status dot, the same drag, the same promote
          toggle and the same ✕ as a session running here. Being under this
          heading is what says where it is running, and repeating that on every
          line said nothing while making the whole group look foreign, which was
          the complaint underneath the complaint.

          Drawn only when a machine is reachable. A heading over nothing reads as
          a list that failed to load — the same argument every other section on
          this rail makes.
        */}
        {machines.map((group) => {
          const open = !folded.has(machineFoldKey(group.machineId))
          return (
            <section className="sb-group sb-project" key={group.machineId}>
              <GroupHead
                name={group.name}
                title={`${group.name} — ${group.sessions.length === 1 ? '1 session' : `${group.sessions.length} sessions`}`}
                open={open}
                onToggle={() => toggleFold(machineFoldKey(group.machineId))}
                icon={MACHINE_ICON}
                /*
                  There is no `resume` here, and the absence is the honest
                  answer rather than an omission.

                  He asked for the same three controls a project has, and two of
                  them are here. Continue-last-session is not, because it cannot
                  act: `create` on the wire carries a cwd and a provider and
                  **not** a resume flag — `protocol.ts` says so in as many words
                  and calls it a live gap, named rather than closed — so a glyph
                  here would send a request the far machine answers by starting a
                  *fresh* session, silently. That is the exact defect the project
                  heading's own Continue was fixed for a night earlier, and
                  drawing it again on a different heading would be reintroducing
                  it. A machine group also has no folder of its own to continue
                  in, which is the second half of the same problem: a project
                  heading *is* a folder, and a machine is a computer with many.

                  `GroupHead` makes the control optional for precisely this
                  reason, and it is the same rule the project heading follows
                  when the default agent has no resume command.

                  ## What it would take, named so it is not reconstructed twice

                  A `resume` on the `create` frame is necessary and **not
                  sufficient**, and that is the trap. The wire's own note lists
                  resume among the things deliberately left off and says why:
                  continuing the newest conversation *"is real and the desktop
                  supports it, but only for providers that have a resume flag; a
                  toggle that silently does nothing for a plain shell is a fake
                  feature."* `machines/guest.ts` already sends one and the far
                  end still drops it. So closing this means the far machine
                  answering the per-provider question as well — which agent that
                  session would run and whether *that* agent can continue
                  anything — and refusing out loud when it cannot. A flag widened
                  into the type without that answer puts this glyph back on
                  screen doing the exact silent-fresh-session it was withheld
                  for, on every machine sitting at a plain shell.

                  The folder is the second half and does not come free either. A
                  machine heading has no folder to continue *in*, so the control
                  would have to name one — the newest session's, most likely,
                  which is another fact the far end would have to report and this
                  side would have to print, or the press means "continue
                  something over there" and nothing more.
                */
                add={{
                  label: `New session on ${group.name}`,
                  // Deliberately not `tip(…, 'session.new')`. ⌘T starts a session
                  // on *this* computer, and printing it beside a button that
                  // starts one somewhere else would be the app claiming a key
                  // that goes to a different machine.
                  title: `New session on ${group.name}`,
                  onPress: () => onNewMachineSession(group.machineId),
                }}
                /*
                  Close, and what he decided it means.

                  He talks himself through it in the recording and lands
                  somewhere exact: *"Close you will not give — but you can
                  actually give, because it should not disconnect the remote
                  account. It will just close all of the sessions from that PC.
                  Yeah, you can give this close too, so it will go from here, but
                  whenever you want to start, you can start as a new session and
                  you can start from that device."*

                  So it ends the sessions, the group folds away, and the machine
                  stays paired — New session brings it straight back. The rail
                  does none of that: it reports the press, and `App.tsx` owns the
                  confirmation, the `close` frames and the hiding, next to the
                  rest of the machine state.
                */
                close={{
                  label: `Close the sessions on ${group.name}`,
                  title: `Close the sessions on ${group.name}. It stays connected.`,
                  onPress: () => onCloseMachine(group.machineId),
                  disabledReason: group.canClose
                    ? null
                    : `${group.name} is running a version of this app that cannot end sessions from here.`,
                }}
              />
              {open &&
                (group.sessions.length === 0 ? (
                  // Said rather than left blank. A machine that is connected and
                  // has nothing running is a real and ordinary state, and an
                  // empty heading is indistinguishable from one that failed to
                  // fill.
                  <p className="sb-empty">Nothing running there.</p>
                ) : (
                  <ul className="sb-list sb-sessions">{rowsFor(group.sessions)}</ul>
                ))}
            </section>
          )
        })}

        {/*
          Terminals open on servers, under the server they are open on.

          The same shape as the machine groups directly above, and that sameness
          is the whole point of this section existing at all. Asad, for the third
          night running about machines that are not this one: *"Keep the same one
          browser window for every device… the shape of the application should
          not be changing for local and remote devices. It should act like that
          same."* Until this, opening a shell on a server produced a rectangle
          inside a settings-shaped panel — no row here, no pill above, no ⌘W,
          nothing you could drag to the top — while a session on a paired laptop
          got all four. That is a server being given a lesser product than a
          laptop, and it is the defect this section closes.

          Below the machines rather than above them, deliberately. The order of
          this rail is how close a thing is to you: your projects, then the
          computers you also sit at, then the machines nobody sits at.

          ## One difference from the group above, and it is not an omission

          A machine's heading is drawn whenever the machine is reachable, empty
          or not. A server's is drawn only when something is open on it. The
          reason is in `server-sessions.ts`: reachability is a live fact about a
          paired desktop and worth a row, and a server has no equivalent — it is
          a stored address this app never dials to find out about — so a heading
          per stored server would be a permanent row saying nothing, in the list
          whose entire job is to answer what you have open.
        */}
        {servers.map((group) => {
          const open = !folded.has(serverFoldKey(group.serverId))
          return (
            <section className="sb-group sb-project" key={group.serverId}>
              <GroupHead
                name={group.name}
                title={`${group.name} — ${group.sessions.length === 1 ? '1 session' : `${group.sessions.length} sessions`}`}
                open={open}
                onToggle={() => toggleFold(serverFoldKey(group.serverId))}
                icon={SERVER_ICON}
                /*
                  No `resume`, for a plainer reason than the machine heading's.
                  There is nothing to continue: a shell on a server leaves
                  nothing behind it when it ends — no transcript on this side, and
                  nothing on the far side that was keeping it — so a glyph here
                  could only ever open a fresh one wearing the word "continue".
                */
                add={{
                  label: `New terminal on ${group.name}`,
                  /*
                    Deliberately not `tip(…, 'session.new')`, exactly as the
                    machine heading's is not. ⌘T starts a session on *this*
                    computer, and printing it beside a button that opens one
                    somewhere else would be the app claiming a key that goes
                    elsewhere.
                  */
                  title: `New terminal on ${group.name}`,
                  onPress: () => onNewServerSession(group.serverId),
                }}
                /*
                  Close ends the terminals and keeps the server.

                  The same sentence the machine heading makes, one kind down, and
                  the second half is the one a person is actually worried about:
                  the server stays in the Machines panel with its sign-in intact.
                  Forgetting one is a different act, on the server's own page,
                  and this cannot reach it. There is no `disabledReason` because
                  there is no state in which this cannot act — see
                  `SidebarServer`.
                */
                close={{
                  label: `Close the terminals on ${group.name}`,
                  title: `Close the terminals on ${group.name}. The server itself is left alone.`,
                  onPress: () => onCloseServer(group.serverId),
                  disabledReason: null,
                }}
              />
              {open && <ul className="sb-list sb-sessions">{rowsFor(group.sessions)}</ul>}
            </section>
          )
        })}

      </div>

      {/*
        The foot: the app talking about itself, in the order you would want to
        hear it. An update is news and goes on top; Settings is where you go
        when you have decided to change something, and stays at the bottom-left
        where every app of this shape puts it, with the bell at the end of its
        line.

        All three used to be somewhere else — the update strip across the top of
        the work, Alerts in the toolbar's right-hand corner competing with the
        controls you use while working — which put three unrelated interruptions
        in the two places your eye is trying to read.
      */}
      <div className="sidebar-foot">
        {update && <div className="sidebar-update">{update}</div>}

        {footPanels.map((panel) => {
          const count = badges?.[panel.id] ?? 0
          return (
            <button
              key={panel.id}
              type="button"
              className={`sb-row sb-nav${activePanel === panel.id ? ' active' : ''}`}
              aria-current={activePanel === panel.id}
              title={panel.command ? tip(panel.label, panel.command) : panel.label}
              onClick={() => onSelectPanel(panel.id)}
            >
              <Glyph path={panel.icon} />
              <span className="sb-label">{panel.label}</span>
              {count > 0 && <span className="sb-badge">{count > 99 ? '99+' : count}</span>}
            </button>
          )
        })}

        {/*
          The last line of the rail: two things you open, neither of which is a
          place you go.

          *"For the alerts icon, let's not keep it a complete separate pill.
          Let's make it a small icon next to the settings pill… if we click on
          it, it just opens the notifications."* — and then, about what "opens"
          had to mean: *"and notifications should be a pop-up just like
          settings, not a full page."* So the bell sits at the end of the
          Settings line and both controls do the same kind of thing: put a sheet
          over the window and leave the window exactly where it was.

          Which is why neither of them has an `active` state. A row in the rail
          is drawn as current because a page is filling the window and you need
          to know which; a dialog closes and there is nothing to have been
          current about. Marking the bell while its sheet is open would be the
          rail claiming a navigation that never happened.

          What the bell must not lose is the count. A notification list whose
          only mark is inside itself is a list nobody opens — so the number is a
          dot on the glyph, and the number itself is spoken in the label,
          because a 30px glyph has nowhere to print "3" and a mark with no text
          is a mark a screen reader cannot report at all.
        */}
        <div className="sidebar-settings">
          <button
            type="button"
            className="sb-row sb-settings"
            onClick={onOpenSettings}
            title={tip('Settings', 'app.preferences')}
          >
            <Glyph path={GEAR} />
            <span className="sb-label">Settings</span>
          </button>

          {alerts && (
            <button
              type="button"
              className="sb-icon"
              aria-label={alertCount > 0 ? `Alerts (${alertCount})` : 'Alerts'}
              title="Alerts"
              onClick={onOpenAlerts}
            >
              <Glyph path={ALERTS_GLYPH} size={16} />
              {alertCount > 0 && <span className="sb-icon-dot" aria-hidden="true" />}
            </button>
          )}
        </div>
      </div>

      <div
        className="sidebar-resize"
        onMouseDown={onStartResize}
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize sidebar"
      />

      {/*
        What follows the cursor while a row is being dragged.

        Drawn as a strip tab, because that is what the row is about to become —
        the drag then shows the outcome rather than the input, which is the
        whole difference between this and the browser's default ghost of the
        row. One node reused by every row: its label and icon are written into
        it at `dragstart`, which is the only moment `setDragImage` can be
        called, and a per-row copy would put 40 hidden nodes in the rail to say
        the same thing.

        `aria-hidden` and no text of its own at rest: nothing here is content,
        and a screen reader reading a leftover title out of the corner of the
        sidebar would be a bug with no visible symptom.
      */}
      <div className="tab-ghost" ref={ghostRef} aria-hidden="true">
        <svg
          width="15"
          height="15"
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="1.5"
          strokeLinecap="round"
          strokeLinejoin="round"
        >
          <path ref={ghostPathRef} d={KIND_ICON.session} />
        </svg>
        <span className="tab-ghost-label" ref={ghostLabelRef} />
      </div>
    </aside>
  )
}
