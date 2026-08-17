import { useEffect, useRef, useState, type DragEvent, type MouseEvent, type ReactNode } from 'react'
import { ALERTS_GLYPH } from '../components/AlertsPanel'
import { StatusDot } from '../components/StatusDot'
import type { Project } from '../state/store'
import { useSessionRename } from '../state/session-rename'
import { folderName, MAX_TITLE_LENGTH } from '../session-title'
import { tip } from '../keymap'
import { demote, MAX_PROMOTED, promote, usePromotedOrder } from '../browser/workspace-strip'
import { accountRail, useKnownSignIns } from '../accounts'
import { CopilotEntry } from '../copilot/CopilotEntry'
import type { CopilotStage, CopilotStateView } from '../copilot/copilot-model'
import { partitionByOrigin, turnOf } from '../copilot/session-origin'
import { PANEL_GROUPS, PANELS, type PanelId, type PanelSpec } from './panels'
import {
  accountsWorthShowing,
  KIND_ICON,
  sessionLabel,
  startTabDrag,
  tabQualifiers,
  type WorkspaceTab,
} from './workspace-tabs'

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
  copilot?: { stage: CopilotStage; state: CopilotStateView | null; active?: boolean } | null
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
const DISCLOSURE = 'M9.5 6.5l5.5 5.5-5.5 5.5'
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
  alerts = true,
  alertCount = 0,
  unread = [],
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

  /** Folded projects, by path. Local: it is a view state, not a preference. */
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

  const labelFor = (tab: WorkspaceTab, index: number, projectName?: string): string =>
    tab.kind === 'session' ? sessionLabel(tab.label, index, projectName) : tab.label

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
    run: WorkspaceTab[],
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
    tab.kind === 'session' && sessionRename.available

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
    const rowTitle = [
      label,
      qualifier,
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
              aria-label={`Close ${label}`}
              title={
                tab.kind === 'session'
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
          {projects.length === 0 && browserTabs.length === 0 && (
            <p className="sb-empty">Nothing open yet.</p>
          )}

          {projects.map((project) => (
            <div key={project.path} className="sb-project">
              <div className="sb-row sb-project-head">
                {/* A disclosure, the way a macOS sidebar folds a group. It used
                    to start a session, which is what the ＋ beside it does — one
                    affordance, one meaning. */}
                <button
                  type="button"
                  className="sb-row-main"
                  title={project.path}
                  aria-expanded={!folded.has(project.path)}
                  onClick={() => toggleFold(project.path)}
                >
                  <Glyph
                    path={DISCLOSURE}
                    size={12}
                    className={`sb-disclosure${folded.has(project.path) ? '' : ' open'}`}
                  />
                  <span className="sb-project-name">{project.name}</span>
                </button>
                <button
                  type="button"
                  className="sb-row-action"
                  onClick={() => onNewSession(project.path, true)}
                  aria-label={`Continue the last session in ${project.name}`}
                  title={tip('Continue last session', 'session.resume')}
                >
                  <Glyph path={RESUME} size={13} />
                </button>
                <button
                  type="button"
                  className="sb-row-action"
                  onClick={() => onNewSession(project.path)}
                  aria-label={`New session in ${project.name}`}
                  title={tip('New session', 'session.new')}
                >
                  <Glyph path={PLUS} size={13} />
                </button>
                <button
                  type="button"
                  className="sb-row-action"
                  onClick={() => onCloseProject(project.path)}
                  aria-label={`Close ${project.name}`}
                  title="Close project"
                >
                  <Glyph path={CLOSE} size={13} />
                </button>
              </div>
              {!folded.has(project.path) && (
                <ul className="sb-list sb-sessions">
                  {rowsFor(sessionsIn(project.path), project.name)}
                </ul>
              )}
            </div>
          ))}

          {orphaned.length > 0 && <ul className="sb-list">{rowsFor(orphaned)}</ul>}
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
