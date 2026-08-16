import { useRef, useState, type DragEvent, type MouseEvent, type ReactNode } from 'react'
import { StatusDot } from '../components/StatusDot'
import type { Project } from '../state/store'
import { useSessionRename } from '../state/session-rename'
import { MAX_TITLE_LENGTH } from '../session-title'
import { tip } from '../keymap'
import { demote, MAX_PROMOTED, promote, usePromotedOrder } from '../browser/workspace-strip'
import { PANEL_GROUPS, PANELS, type PanelId, type PanelSpec } from './panels'
import {
  accountsWorthShowing,
  KIND_ICON,
  sessionLabel,
  startTabDrag,
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
  /** Session ids with output nobody has looked at yet. */
  unread?: readonly string[]
  /**
   * Where the top strip's promoted order is kept. Injectable for tests, and
   * spelled the same way as `WorkspaceTabStrip`'s own prop on purpose: the two
   * components have to meet on one store, so a test that gives one of them a
   * stand-in has to be able to give the other the same one.
   */
  storage?: Storage | null
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
  onSelectTab(id: string): void
  onCloseTab(id: string): void
  onSelectPanel(id: PanelId): void
  onNewSession(projectPath?: string, resume?: boolean): void
  /**
   * Open the New session dialog instead of starting one immediately.
   *
   * Optional, and the control is absent rather than inert without it — this
   * component cannot open that dialog itself, it is mounted in `App.tsx`, and a
   * chevron that did nothing would be worse than no chevron.
   *
   * Why it belongs beside the button at all: pressing New session spawns a
   * session on the remembered folder and the default agent, with nothing on
   * screen saying which either of them is. That is the right default — a
   * dialog in front of ⌘T was removed on purpose — but the panel that *does*
   * say is reachable only from the command palette, so the one place in the
   * window where sessions are started offers no way to ask.
   */
  onNewSessionOptions?: () => void
  onNewBrowserTab(): void
  onOpenProject(): void
  onCloseProject(path: string): void
  onOpenSettings(): void
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
const CHEVRON_DOWN = 'M6.5 9.5 12 15l5.5-5.5'
const RESUME = 'M4 12a8 8 0 1 0 2.7-6M4 4.5v4h4'
const CLOSE = 'M6.5 6.5l11 11M17.5 6.5l-11 11'
/**
 * Rename. A pencil lying on the 45° diagonal — nib at the bottom-left, a
 * rounded ferrule at the top-right, and the band across it that says which end
 * is which. Drawn here rather than borrowed, like every other glyph in this
 * file, and at the same 1.5 stroke as its neighbours so the row does not gain a
 * heavier mark than the one that closes it.
 */
const PENCIL = 'M4.5 19.5 5.4 16.4 16.4 5.4a1.55 1.55 0 0 1 2.2 2.2L7.6 18.6zM14.4 7.4 16.6 9.6'
/**
 * Send this window to the top strip: an arrow rising into a bar.
 *
 * The mirror image of the fold-away glyph on a strip tab, which is an arrow
 * going left into a bar — one gesture drawn twice so the pair reads as out and
 * back rather than as two unrelated controls. Not a pin, not a star: both of
 * those mean "favourite" everywhere else, and this is a placement, not a
 * rating.
 */
const TO_STRIP = 'M5 4.5h14M12 20V9M8 13l4-4 4 4'
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
  unread = [],
  storage,
  badges,
  peeking = false,
  update,
  onSelectTab,
  onCloseTab,
  onSelectPanel,
  onNewSession,
  onNewSessionOptions,
  onNewBrowserTab,
  onOpenProject,
  onCloseProject,
  onOpenSettings,
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

  const beginRename = (id: string, label: string): void => {
    editing.current = true
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

  /** Folded projects, by path. Local: it is a view state, not a preference. */
  const [folded, setFolded] = useState<ReadonlySet<string>>(new Set())
  const toggleFold = (path: string) =>
    setFolded((current) => {
      const next = new Set(current)
      if (!next.delete(path)) next.add(path)
      return next
    })

  const browserTabs = tabs.filter((tab) => tab.kind === 'browser')
  const sessionsIn = (path: string) =>
    tabs.filter((tab) => tab.kind === 'session' && tab.projectPath === path)
  /** Sessions whose project has been closed out from under them. */
  const orphaned = tabs.filter(
    (tab) =>
      tab.kind === 'session' && !projects.some((project) => project.path === tab.projectPath),
  )

  const labelFor = (tab: WorkspaceTab, index: number, projectName?: string): string =>
    tab.kind === 'session' ? sessionLabel(tab.label, index, projectName) : tab.label

  /**
   * Whether the rows have to name the account each session belongs to.
   *
   * Only once more than one is in play — see `accountsWorthShowing`. Two
   * sessions in the same folder under two logins are otherwise the same row
   * twice, which is the thing this app must never make someone guess about.
   */
  const showAccounts = accountsWorthShowing(tabs)

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

  const tabRow = (tab: WorkspaceTab, label: string) => {
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
              onBlur={() => endRename(true)}
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
    return (
      <li key={tab.id}>
        <div
          className={`sb-row sb-open${!activePanel && tab.id === activeTabId ? ' active' : ''}${
            unread.includes(tab.id) ? ' unread' : ''
          }`}
          draggable
          data-dragging={tab.id === draggingId || undefined}
          onDragStart={(event) => beginDrag(event, tab, label)}
          onDragEnd={() => setDraggingId(null)}
        >
          <button
            type="button"
            className="sb-row-main"
            title={
              showAccounts && tab.account ? `${label} — signed in as ${tab.account.name}` : label
            }
            aria-current={!activePanel && tab.id === activeTabId}
            onClick={() => onSelectTab(tab.id)}
          >
            {tab.kind === 'session' ? (
              <StatusDot status={tab.status ?? 'idle'} />
            ) : (
              <Glyph path={KIND_ICON.browser} size={15} />
            )}
            <span className="sb-label">{label}</span>
            {showAccounts && tab.account && (
              <span className="sb-account">{tab.account.name}</span>
            )}
          </button>
          {/* Mail's idiom: a dot for a row with something new in it. It hides
              under the close button on hover, because at that point the pointer
              is on its way somewhere else. */}
          {unread.includes(tab.id) && <span className="sb-unread" aria-label="Unread output" />}
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
          {canRename(tab) && (
            <button
              type="button"
              className="sb-row-action sb-rename"
              aria-label={`Rename ${label}`}
              title={`Rename ${label}`}
              onClick={() => beginRename(tab.id, label)}
            >
              <Glyph path={PENCIL} size={13} />
            </button>
          )}
          {tab.closable && (
            <button
              type="button"
              className="sb-row-action sb-close"
              aria-label={`Close ${label}`}
              title={`Close ${label}`}
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
          title={tip('New session', 'session.new')}
        >
          <Glyph path={PLUS} size={16} />
          <span>New session</span>
        </button>
        {/*
          The second half of a split button: press for a session, press the
          chevron to be asked. The press itself is untouched — one click, the
          remembered folder, the default agent — because the dialog that used
          to stand in front of it was removed on purpose. What was missing is
          any way to ask *from here*: the panel that names the folder and the
          agent is behind a command-palette entry, so the one place in the
          window where sessions get started could not reach it.

          Drawn only when a host wired it, since this component cannot open
          that dialog itself. See `onNewSessionOptions`.
        */}
        {onNewSessionOptions && (
          <button
            type="button"
            className="sb-new-more"
            onClick={onNewSessionOptions}
            aria-label="New session with options"
            title={tip('New session with options', 'session.newDialog')}
          >
            <Glyph path={CHEVRON_DOWN} size={14} />
          </button>
        )}
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

      <div className="sidebar-scroll">
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
                  {sessionsIn(project.path).map((tab, index) =>
                    tabRow(tab, labelFor(tab, index, project.name)),
                  )}
                </ul>
              )}
            </div>
          ))}

          {orphaned.length > 0 && (
            <ul className="sb-list">
              {orphaned.map((tab, index) => tabRow(tab, labelFor(tab, index)))}
            </ul>
          )}
          {browserTabs.length > 0 && (
            <ul className="sb-list">{browserTabs.map((tab) => tabRow(tab, tab.label))}</ul>
          )}
        </section>
      </div>

      {/*
        The foot: the app talking about itself, in the order you would want to
        hear it. An update is news and goes on top; Alerts is a standing list
        and goes under it; Settings is where you go when you have decided to
        change something, and stays at the bottom-left where every app of this
        shape puts it.

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

        <button
          type="button"
          className="sb-row sb-settings"
          onClick={onOpenSettings}
          title={tip('Settings', 'app.preferences')}
        >
          <Glyph path={GEAR} />
          <span className="sb-label">Settings</span>
        </button>
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
