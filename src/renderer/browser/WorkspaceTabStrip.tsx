import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type DragEvent,
  type KeyboardEvent,
} from 'react'
import { StatusDot } from '../components/StatusDot'
import { tip } from '../keymap'
import { bindKey, SessionBindChips, WindowBindChip } from './BindChip'
import {
  dragStartedOnControl,
  isTabDrag,
  KIND_ICON,
  middleEllipsis,
  readTabDrag,
  startTabDrag,
  STRIP_LABEL_BUDGET,
  tabIcon,
  machineTabId,
  tabIdentities,
  tabTooltip,
  type WorkspaceTab,
} from '../shell/workspace-tabs'
import {
  defaultStorage,
  demote,
  dropIndex,
  promote,
  pruneOrder,
  removeFromStrip,
  shownTabs,
  usePromotedOrder,
} from './workspace-strip'
import './WorkspaceTabStrip.css'

/**
 * The tab strip along the top — the window's own top band, shaped the way a
 * browser shapes one.
 *
 * ## Where this file lives, and why that is temporary
 *
 * It belongs in `src/renderer/shell/` beside `Sidebar.tsx` and
 * `WindowToolbar.tsx` — it is shell chrome, and it holds terminals as well as
 * browser pages. It is here because this change was made while six agents were
 * editing the same working tree and `shell/` was another agent's. Moving it is a
 * `git mv` and two import paths; nothing about it is browser-specific.
 *
 * ## The shape, which is the point
 *
 * Asad sent a screenshot of Chrome's tab bar and asked for that. What is in
 * that picture is not "rounded tabs" — it is a **selected tab that is the same
 * surface as the page under it**: the tab's fill is the page's fill, its bottom
 * edge does not exist, and the little flares at its feet carry that surface out
 * across the bar's own hairline. Everything else in the row is a faint fill
 * that stops one pixel above that hairline, so the tab you are in stays the
 * only one joined to anything — see the note over `.strip-tab:not([data-active])`
 * for why it is a gradient and not a colour.
 *
 * That idiom does one thing no highlight can: it says *which pane this tab
 * opens* by drawing the tab and the pane as one object. What was here before
 * was a detached pill floating on a bar — legible, and saying nothing about the
 * thing underneath it. `--tab-active` is `--bg-primary`, which is exactly what
 * `.toolbar[data-under-strip]` and `.panes` are painted, so the join is a real
 * one in both themes rather than a hex that happens to match in one of them.
 *
 * ## What is on a tab, and what deliberately is not
 *
 * A tab carries its icon, its status, its name, a qualifier when its name alone
 * is ambiguous (see {@link tabIdentities}) — and one ✕, which means a different
 * thing on each kind of tab. That difference is the section after next.
 *
 * There is no ＋ on it: *"pills of the windows will not show that plus button
 * inside. There will be a terminal and browser globe icon next to the last
 * window."* Those two live at the end of the row, after the last tab, and are
 * the only things in this bar that open anything.
 *
 * There is no fold-away arrow on it either: *"the arrow inside the pill also
 * doesn't need to be there, because we will not move windows down to the side
 * panel from there."* It had become a second control for what the ✕ now does.
 *
 * ## The two ✕s, which are not the same control — 2026-08-20
 *
 * Every tab has one, and pressing it destroys a browser window or destroys
 * nothing at all depending on which kind of tab it sits on. Asad said sessions
 * close from the sidebar, and then said what he had meant by it:
 *
 *   > *"from the windows it should be able to close it, but at least from the
 *   > top bar. But to completely close and delete will be only sidebar… for the
 *   > windows it will completely close, and for the sessions it will just close
 *   > from the top bar, but it will still stay in the side panel."*
 *
 * So **a browser tab's ✕ ends the window** — a page is listed in no other panel,
 * so "off the bar" would leave it open, bound to a session, and drawn nowhere —
 * and **a session tab's ✕ takes the tab off this bar and stops there**: the pty
 * keeps running, the rail keeps the row, the status dot keeps moving. Ending a
 * session for real is the rail's ⋯ → Delete, which asks first. Nothing on this
 * bar ends a session, and that is why `onEndRemote` — which once let this ✕ end
 * one running on another machine — is gone rather than rewired.
 *
 * Two identical glyphs a centimetre apart with opposite outcomes is a real
 * hazard, so the difference is carried in the two places a glyph cannot carry
 * it. `[data-ends]` goes on the browser one only: it is what paints
 * `--color-critical` under the pointer, and it is the same mark the rail's
 * destructive control wears. And each title names its own act in one phrase —
 * *Take off the bar*, *Close this page*. A phrase and not a sentence, because
 * the standing instruction this round is no explanatory prose on screen; the
 * reasoning lives here instead.
 *
 * A session tab leaves the strip three ways — its ✕, a drag out of the bar, and
 * the toggle on its row in the rail. All three are the same act, a *view*
 * changing, which is why none of them asks anything first.
 *
 * ## The drag, in both directions
 *
 * - **Into the strip.** A sidebar row is the drag source; this is the drop
 *   target. The contract is `TAB_DRAG_MIME` in `shell/workspace-tabs.ts`.
 * - **Within the strip.** Dragging a promoted tab sideways reorders it.
 * - **Out of the strip.** Dropping a promoted tab anywhere that is not the strip
 *   folds it back into the side panel. That is `onDragEnd` seeing that nothing
 *   in here accepted the drop, which is deliberately *not* the same as requiring
 *   the sidebar to be a drop target: the rail is already showing the tab, so
 *   "put it back" needs no receiver.
 *
 * Every one of those is a mouse gesture, so none of them is the whole feature.
 * ⌥← and ⌥→ move a focused tab along the strip, and the sidebar row has a
 * toggle that puts a window here and takes it back without a drag at all — see
 * `usePromotedOrder`, which is how the two ends share one list.
 *
 * A browser window takes part in none of it. It is not promoted, it cannot be
 * folded away, and dropping it outside the bar leaves it exactly where it was:
 * the rail no longer lists pages, so the only thing "out of the strip" could
 * mean for one is *nowhere*. See {@link shownTabs}.
 */

export interface WorkspaceTabStripProps {
  /** Every window that is open — the same list the sidebar renders. */
  tabs: readonly WorkspaceTab[]
  /**
   * The tab the window is currently showing, or null.
   *
   * This must be the *same* answer the bar below it heads itself with — while
   * the window is split that is the focused pane's session, not the tab that
   * happened to be active before the split. A strip and a title that disagree
   * about which session you are in is the defect this prop's caller was fixed
   * for; see `shownTabs`.
   */
  activeTabId: string | null
  /**
   * One of the sidebar's views — Overview, Files, Source control — is covering
   * the window, so none of these tabs is what you are looking at.
   *
   * The tab stays *drawn*, because it is what you will come back to and a strip
   * that emptied itself every time you glanced at Files would shuffle under the
   * pointer. What it stops doing is claiming to be selected: with Overview
   * filling the pane and its name in the bar below, a highlighted "Session 1" up
   * here is the two halves of the chrome disagreeing about what is on screen —
   * the same defect, in a different costume, as a title bar naming a session
   * with no tab. `Sidebar.tsx` has always de-highlighted its rows for this
   * exact reason (`!activePanel && …`); this is the strip catching up.
   */
  covered?: boolean
  onSelect(id: string): void
  /**
   * The ✕ on a **session** tab took the tab off the bar, and it was the tab on
   * screen — so show this instead. `null` means there is nothing left up here.
   *
   * Separate from {@link onSelect}, and the difference is load-bearing rather
   * than tidy: `onSelect` is a *navigation* and pulls any covering view off the
   * window, which is right for a click on a tab and wrong here. Taking the tab
   * you will come back to off the bar, while you are reading Files, must not
   * throw you out of Files.
   *
   * Optional, and its absence takes the whole session ✕ with it rather than
   * leaving one that half-works. Taking the *active* tab off the bar is the
   * ordinary press — it is the tab whose ✕ is showing without a hover — and
   * without this the strip immediately redraws that tab as transient, so the
   * press looks like it did nothing. Same rule as {@link onCloseWindow}: no
   * handler, no control.
   */
  onShowInstead?(id: string | null): void
  /**
   * The ✕ on a **browser** tab: close the window.
   *
   * A real close, unlike the ✕ on the session tab beside it — see the note at
   * the top of this file for the sentence that decided it. A browser window is
   * listed nowhere else in this app now, so "take it off the strip" is not a
   * state it can be in: the page would still be open, still bound to whatever
   * session it was bound to, and unreachable.
   *
   * The caller routes it through the same path ⌘W and the rail take, so a page
   * closes the way everything else in this window closes; nothing about that
   * decision is made in this file.
   *
   * Optional, and absent is a real state rather than a dead control: a host
   * with no way to close a page — a test, the harness mounting this bare —
   * draws no ✕ at all.
   */
  onCloseWindow?(id: string): void
  /**
   * The terminal icon after the last tab.
   *
   * It opens the **new-session dialog**, not a session: *"we just always wanted
   * this pop-up to come up so we choose which type of terminal we want to
   * open."* Optional, and the icon is absent rather than inert without it.
   */
  onNewSession?: () => void
  /** The globe beside it — a browser page on the start page. Absent, not inert. */
  onNewBrowserTab?: () => void
  /**
   * The sidebar is pinned away, so the traffic lights are sitting on *this*
   * bar and the control that brings the rail back has to be here.
   *
   * There is exactly one of those controls in the window at any moment: the
   * rail's own gutter draws it while the rail is out, this strip draws it while
   * the strip is the top band, and `WindowToolbar` draws it only when there is
   * no strip at all.
   */
  sidebarHidden?: boolean
  onRevealSidebar?: () => void
  /** The pointer reaching the window's left edge, which peeks the rail out. */
  onEdgeEnter?: () => void
  /** Injectable for tests. Defaults to `defaultStorage()` — session storage. */
  storage?: Storage | null
}

/** Points the way the content's left edge moves — the same glyph the rail uses. */
const CHEVRON_RIGHT = 'M9.5 6.5 15 12l-5.5 5.5'

const CLOSE = 'M7 7l10 10M17 7L7 17'

function Glyph({ path, size = 14 }: { path: string; size?: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d={path} />
    </svg>
  )
}

export function WorkspaceTabStrip({
  tabs,
  activeTabId,
  covered = false,
  onSelect,
  onShowInstead,
  onCloseWindow,
  onNewSession,
  onNewBrowserTab,
  sidebarHidden = false,
  onRevealSidebar,
  onEdgeEnter,
  storage,
}: WorkspaceTabStripProps) {
  const store = storage === undefined ? defaultStorage() : storage

  const [order, setOrder] = usePromotedOrder(store)
  /** The gap the pointer is currently over, or null when nothing is being dragged. */
  const [dropAt, setDropAt] = useState<number | null>(null)
  /**
   * A tab drag is happening *somewhere in this window*.
   *
   * Not the same question as "the pointer is over the strip", which is what
   * `dropAt` answers, and the distinction is the whole reason this exists: a
   * strip that only lights up once you are already on top of it is a target you
   * have to find before it will admit it is a target. Armed, it says so from the
   * moment the drag starts, which is while you are still deciding where to go.
   */
  const [armed, setArmed] = useState(false)
  /** The tab this strip is the source of, so a drop elsewhere can demote it. */
  const dragging = useRef<string | null>(null)
  /** The same id as React state, for the source tab's own lifted look. */
  const [draggingId, setDraggingId] = useState<string | null>(null)
  /** Set by our own drop handler, so `onDragEnd` can tell a reorder from a fold. */
  const droppedHere = useRef(false)
  const listRef = useRef<HTMLDivElement | null>(null)

  const shown = shownTabs(order, tabs, activeTabId)
  /** Which tab is *on screen*, as opposed to which one the window will return to. */
  const selectedId = covered ? null : activeTabId
  const identities = tabIdentities(
    shown.map((entry) => entry.tab),
    tabs,
  )

  /**
   * What to call the session a browser window is attached to, or null.
   *
   * The binding knows *which* session holds a window; only this strip knows
   * what that session is called. Null when the session is not on this strip —
   * which happens, because a window stays attached to a session whose tab has
   * been folded off the bar — and null is drawn as an absent phrase rather than
   * as a raw session id, which is not a name anybody would recognise.
   */
  const sessionNameFor = (sessionId: string, machineId: string): string | null => {
    const wanted = machineId === '' ? sessionId : machineTabId(machineId, sessionId)
    const tab = tabs.find((entry) => entry.id === wanted)
    if (!tab) return null
    const identity = identities.get(tab.id)
    if (!identity) return tab.label
    return identity.qualifier ? `${identity.label} — ${identity.qualifier}` : identity.label
  }

  /**
   * Every tab id this window has ever had on screen.
   *
   * The difference between "closed" and "has not arrived yet", which is a
   * distinction the tab list alone cannot make and the one the prune below
   * depends on — see {@link pruneOrder}. A ref rather than state because
   * nothing is drawn from it; it exists so that a promoted tab is forgotten
   * only after this window has watched it go.
   */
  const seen = useRef<Set<string>>(new Set())

  /*
   * Persist the arrangement, minus the windows that have closed.
   *
   * Pruned on the way *out* rather than on the way in, because the result is
   * written straight through to storage and a wrong answer here is permanent.
   * That has already happened once: a reload fills the session list in waves,
   * so for a few frames `tabs` is a partial view of what is open, and pruning
   * against it deleted the ids that had not arrived yet — five promoted tabs in,
   * four out, reproduced four times out of four. The `tabs.length === 0` guard
   * was written for that hazard and only covers its first frame; `seen` covers
   * the rest of it.
   *
   * The store writes through to storage itself and ignores a set that changes
   * nothing, which is what stops this effect from re-triggering on the array it
   * just produced.
   */
  useEffect(() => {
    if (tabs.length === 0) return
    for (const tab of tabs) seen.current.add(tab.id)
    setOrder(pruneOrder(order, tabs, seen.current))
  }, [order, setOrder, tabs])

  /*
   * Bring the tab you are in into view.
   *
   * The strip scrolls, and since it started always holding the active tab it can
   * hold more tabs than fit — so "the title bar and the strip agree about which
   * session is active" is only true if the tab it agrees about is on screen.
   * Seen in the running app with six tabs on a 1440px window: the heading read
   * "Session 3" and the tab of that name was past the right edge, which is the
   * same silence as having no tab at all.
   *
   * `nearest` in both axes: horizontally it scrolls the least it can, and
   * vertically it must do nothing whatsoever — the default (`start`) would take
   * the whole window with it, because `scrollIntoView` walks every scrollable
   * ancestor and the pane below is one.
   *
   * Keyed on the selection rather than on the tab list, so scrolling the strip
   * by hand to look at something else is not undone on the next render.
   */
  useEffect(() => {
    if (selectedId === null) return
    listRef.current
      ?.querySelector(`[data-strip-tab][data-tab-id="${CSS.escape(selectedId)}"]`)
      ?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }, [selectedId])

  /*
   * Watching the window's drags, rather than being told about them.
   *
   * The drag starts in `Sidebar.tsx`, which has no reference to this component
   * and should not gain one for a piece of visual feedback. `dragstart` and
   * `dragover` both bubble to the document during any drag in this window, and
   * `isTabDrag` reads only `types`, which is readable while the payload itself
   * is in protected mode — so this is the real drag state, not an inference
   * from one.
   *
   * Disarmed on `dragend`, which fires on the source for *every* drag including
   * one cancelled with Escape, and on `drop` for the case where the source has
   * already been unmounted by the drop it caused.
   */
  useEffect(() => {
    const arm = (event: globalThis.DragEvent): void => {
      if (isTabDrag(event.dataTransfer)) setArmed(true)
    }
    const disarm = (): void => {
      setArmed(false)
      setDropAt(null)
    }
    document.addEventListener('dragstart', arm)
    document.addEventListener('dragover', arm)
    document.addEventListener('dragend', disarm)
    document.addEventListener('drop', disarm)
    return () => {
      document.removeEventListener('dragstart', arm)
      document.removeEventListener('dragover', arm)
      document.removeEventListener('dragend', disarm)
      document.removeEventListener('drop', disarm)
    }
  }, [])

  const boxes = useCallback((): Array<{ left: number; width: number }> => {
    const node = listRef.current
    if (!node) return []
    return Array.from(node.querySelectorAll('[data-strip-tab]')).map((child) => {
      const box = child.getBoundingClientRect()
      return { left: box.left, width: box.width }
    })
  }, [])

  const onDragOver = (event: DragEvent<HTMLDivElement>): void => {
    if (!isTabDrag(event.dataTransfer)) return
    // Without `preventDefault` on dragover the browser refuses the drop, and
    // the symptom is a drag that visibly does nothing — no error, no cursor
    // change, nothing to search for.
    event.preventDefault()
    event.dataTransfer.dropEffect = 'move'
    setDropAt(dropIndex(boxes(), event.clientX))
  }

  const onDrop = (event: DragEvent<HTMLDivElement>): void => {
    const id = readTabDrag(event.dataTransfer)
    setDropAt(null)
    if (!id) return
    event.preventDefault()
    droppedHere.current = true
    // Only a window that is actually open. A stale id from a previous run's
    // storage, or a drag from somewhere that speaks the same MIME type, would
    // otherwise put a permanent ghost in the strip.
    if (!tabs.some((tab) => tab.id === id)) return
    setOrder(promote(order, id, dropIndex(boxes(), event.clientX)))
    onSelect(id)
  }

  const onDragEnd = (): void => {
    const id = dragging.current
    dragging.current = null
    setDraggingId(null)
    setDropAt(null)
    // Dropped outside the strip: fold it back into the side panel, where it has
    // been listed the whole time. Nothing else has to accept the drop for this
    // to work, which is why demotion does not wait on `Sidebar.tsx`.
    //
    // Sessions only. The rail stopped listing browser windows on 2026-08-20, so
    // "fold it back" has nowhere to fold one to — `shownTabs` would draw it
    // again on the next frame anyway, and the only visible effect of demoting it
    // would be the page jumping to the end of the row for no reason the person
    // dragging it could name.
    const kind = tabs.find((tab) => tab.id === id)?.kind
    if (id && kind === 'session' && !droppedHere.current) setOrder(demote(order, id))
    droppedHere.current = false
  }

  /**
   * The ✕ on a session tab: take the view off the bar, leave the work alone.
   *
   * Both halves come out of {@link removeFromStrip} rather than being decided
   * here, because the second half is the one that is easy to get wrong and
   * impossible to see in a screenshot: the strip always draws the tab you are
   * looking at, so taking *that* tab off has to move the window somewhere else
   * or the press appears to do nothing at all.
   *
   * The rail's own toggle calls plain `demote` instead, and that is not a
   * second answer to the same question: it takes a tab off the bar while you
   * are still looking at it, so there is no selection to move. The correction
   * is needed only where the press and the thing on screen are the same tab.
   */
  const removeTab = (id: string): void => {
    const result = removeFromStrip(order, tabs, id, activeTabId)
    setOrder(result.order)
    if (result.select !== undefined) onShowInstead?.(result.select)
  }

  /**
   * ⌥← and ⌥→ on a focused tab: the reorder drag, without a mouse.
   *
   * The option key rather than the arrows alone, because a bare ←/→ in a
   * `tablist` is *move focus between tabs*, which is what a screen-reader user
   * expects the browser to give them and what this must not steal.
   */
  const moveByKey = (event: KeyboardEvent<HTMLDivElement>, id: string, index: number): void => {
    if (!event.altKey || (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight')) return
    event.preventDefault()
    setOrder(promote(order, id, index + (event.key === 'ArrowLeft' ? -1 : 1)))
  }

  /**
   * The control that brings the pinned-away rail back, when the lights are here.
   *
   * Rendered by this bar only while this bar is the window's top band, which is
   * whenever the strip exists at all — `WindowToolbar` draws the same control in
   * the same place in the one case where there is no strip. Two of them, or none,
   * are both bugs the render test pins.
   */
  const reveal = sidebarHidden && onRevealSidebar && (
    <button
      type="button"
      className="strip-reveal"
      onClick={onRevealSidebar}
      // The same hover that peeks the rail out from the window edge, so
      // reaching for this button reveals the thing it opens before the click
      // lands — the button is the commitment, the approach is the preview.
      onPointerEnter={onEdgeEnter}
      aria-label="Show sidebar"
      aria-expanded={false}
      title="Show the sidebar"
    >
      <Glyph path={CHEVRON_RIGHT} size={18} />
    </button>
  )

  /**
   * The two icons in the bar's trailing corner, and the only things in this bar
   * that open anything.
   *
   * *"There will be a terminal and browser globe icon next to the last window.
   * Whatever the icon we click accordingly it will open the next window."* So
   * they are one press each, with no menu in between — the menu was what the ＋
   * needed in order to offer two commands from one target, and two targets need
   * no menu at all.
   *
   * ## Why they left the scrolling rail — 2026-08-20
   *
   * They used to ride *inside* it, after the last tab, on the argument that
   * "next to the last window" is a position relative to the tabs rather than to
   * the window. That argument is right about the words and wrong about the
   * result, and the frame says so: with the strip full, the rail scrolls, the
   * openers scroll with it, and the globe ends up sitting on top of the last
   * tab's name — *"these two buttons to start new session and new window are
   * like coming above the tab. So they should be always in the corner and
   * whenever we start new, these will become smaller."*
   *
   * "These will become smaller" is the tabs, and it is the other half of the
   * fix: the corner is reserved out of the bar's width, the rail gets what is
   * left, and the tabs give room rather than running underneath a control. So
   * this block is a sibling of `.strip-rail` now instead of its last child, and
   * the openers are the one part of the bar that never moves.
   *
   * The terminal opens the **dialog**, which is the whole of the change he asked
   * for in the same breath: *"if we click directly on the whole button it opens
   * a quick window. We don't want this quick window at all."* The globe opens a
   * browser page, which lands on the start page that lists what is listening.
   *
   * They are outside the `tablist`, because they are not tabs and a tablist
   * whose children are not all tabs is a promise to a screen reader that the
   * markup does not keep.
   */
  const openers = (onNewSession || onNewBrowserTab) && (
    <div className="strip-openers">
      {onNewSession && (
        <button
          type="button"
          className="strip-open"
          onClick={onNewSession}
          aria-label="New session"
          title={tip('New session…', 'session.new')}
        >
          <Glyph path={KIND_ICON.session} size={16} />
        </button>
      )}
      {onNewBrowserTab && (
        <button
          type="button"
          className="strip-open"
          onClick={onNewBrowserTab}
          aria-label="New browser tab"
          title={tip('New browser tab', 'view.browser')}
        >
          <Glyph path={KIND_ICON.browser} size={16} />
        </button>
      )}
    </div>
  )

  /*
   * Nothing exists to draw, so there is nothing to be the top band of.
   *
   * `stripIsPresent` in `workspace-strip.ts` is the same question asked by
   * `App.tsx`, which has to know whether the bar below it is the top band
   * instead — the traffic lights and the window drag go to whichever of the two
   * is first, and both believing they are first is 82 pixels of nothing at the
   * top-left of the window.
   */
  if (tabs.length === 0) return null

  if (shown.length === 0) {
    /*
     * Tabs exist, none is promoted, and nothing is active either.
     *
     * Not what taking the last tab off with its ✕ produces, and that is worth
     * writing down because it is the obvious guess. `removeFromStrip` answers
     * `select: null` there, and `App.tsx` has resolved a null selection to
     * `tabs[0]` since long before this bar existed — so the window keeps showing
     * a session and this bar keeps showing that session's tab, transient. The
     * two are the same rule: a window that is displaying a terminal must have a
     * tab naming it.
     *
     * So this is a host that says `activeTabId: null` while something is open —
     * the harness, and the defensive case. It stays a real drop target, it says
     * the one thing about this bar that nothing else in the window says, and it
     * keeps both openers, because an empty bar is exactly where somebody wants
     * to start something.
     */
    return (
      <div
        className="strip strip-empty"
        data-sidebar-collapsed={sidebarHidden || undefined}
        data-armed={armed || undefined}
        data-over={dropAt !== null || undefined}
        onDragOver={onDragOver}
        onDragLeave={() => setDropAt(null)}
        onDrop={onDrop}
      >
        {reveal}
        <p className="strip-hint">Drag a session or a page here to keep it along the top.</p>
        {openers}
      </div>
    )
  }

  return (
    <div
      className="strip"
      data-sidebar-collapsed={sidebarHidden || undefined}
      data-armed={armed || undefined}
    >
      {reveal}
      {/*
        The tabs scroll; the bar does not.

        Two elements rather than one, for reasons that all bite only once the
        strip is full. The reveal button is positioned against the bar, and an
        absolutely-positioned child of a scrolling box scrolls *with* its
        contents — so on a window with twelve tabs and the rail put away, the one
        control that brings the rail back would slide off the left edge and the
        tabs would run underneath where it used to be. The `tablist` inside must
        contain nothing but tabs. And the two openers are the bar's fixed corner
        now, which only means anything if there is a box that scrolls and a box
        that does not.
      */}
      <div
        className="strip-rail"
        onDragOver={onDragOver}
        onDragLeave={() => setDropAt(null)}
        onDrop={onDrop}
      >
        <div className="strip-list" role="tablist" aria-label="Open tabs" ref={listRef}>
          {shown.map(({ tab, promoted }, index) => {
            /*
             * The name, then whatever it takes to tell it from its neighbour,
             * then the cut — in that order. The qualifier is a separate element
             * rather than part of the string so the stylesheet can make the
             * *qualifier* give when the tab runs out of room: the identifier
             * must never be the thing that shrinks, which is the same rule the
             * sidebar row now holds against the account chip.
             */
            const { label: full, qualifier } = identities.get(tab.id) ?? {
              label: tab.label,
              qualifier: null,
            }
            const label = middleEllipsis(full, STRIP_LABEL_BUDGET)
            const spoken = qualifier ? `${full} — ${qualifier}` : full
            return (
              <div
                key={tab.id}
                data-strip-tab=""
                data-tab-id={tab.id}
                className="strip-tab"
                data-active={tab.id === selectedId || undefined}
                data-transient={!promoted || undefined}
                data-drop-before={dropAt === index || undefined}
                data-dragging={tab.id === draggingId || undefined}
                draggable
                onDragStart={(event) => {
                  /*
                   * A press on the tab's own ✕ is a press, not a drag.
                   *
                   * The same defect as the sidebar row's — see
                   * `dragStartedOnControl`, which holds the measurement — but it
                   * fails worse here, and that is worth spelling out. On the rail
                   * a swallowed press does nothing. Here the drag *completes*
                   * four pixels away, lands back on this strip, and reorders it:
                   * the user pressed ✕ on the second tab and the second tab moved
                   * to third place. A control that rearranges the bar when asked
                   * to remove something from it is worse than one that is inert.
                   */
                  if (dragStartedOnControl(event.clientX, event.clientY)) {
                    event.preventDefault()
                    return
                  }
                  dragging.current = tab.id
                  setDraggingId(tab.id)
                  droppedHere.current = false
                  startTabDrag(event.dataTransfer, tab.id)
                }}
                onDragEnd={onDragEnd}
                onKeyDown={(event) => moveByKey(event, tab.id, index)}
              >
                {/*
                  The two flares at the tab's feet, which are what makes it read
                  as continuous with the pane rather than as a plate resting on
                  a bar. A real element rather than the tab's own `::before` and
                  `::after`: the insertion caret already owns `::before`, and a
                  shape that disappears whenever something is being dragged past
                  would be a very confusing bug to look at. Drawn for every tab
                  and painted only for the selected one, so nothing has to be
                  mounted or unmounted as the selection moves.
                */}
                <span className="strip-tab-skirt" aria-hidden="true" />
                <button
                  type="button"
                  role="tab"
                  aria-selected={tab.id === selectedId}
                  className="strip-tab-face"
                  /* The whole title and the folder it runs in — the two things a
                     24-character tab cannot say for itself, and the pair that tells
                     three sessions in one project apart. */
                  title={tabTooltip(tab, spoken)}
                  onClick={() => onSelect(tab.id)}
                >
                  <svg
                    className="strip-tab-icon"
                    width="15"
                    height="15"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.5"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    aria-hidden="true"
                  >
                    {/* Its kind's mark, except for the copilot — the only
                        window in here there is exactly one of, which keeps the
                        compass it wears in the rail so the row and the pill are
                        recognisably one thing. See `tabIcon`. */}
                    <path d={tabIcon(tab)} />
                  </svg>
                  {/* The app's own status dot, not a second one drawn here: it owns
                      the colour, the fill and — the part that matters — the words a
                      screen reader says for each state, and a private copy would drift
                      from the sidebar's. A browser page has no status and gets no
                      mark, rather than a grey one that means nothing. */}
                  {tab.kind === 'session' && tab.status && <StatusDot status={tab.status} />}
                  <span className="strip-tab-label">{label}</span>
                  {qualifier && <span className="strip-tab-qualifier">{qualifier}</span>}
                  {/*
                    Which browser windows this session has, or which session this
                    browser window belongs to — the same relation, seen from
                    whichever end this pill is.

                    This is the slot the paragraph above deliberately left empty,
                    and it stays empty for a page that is attached to nothing:
                    the objection there was to a mark that means nothing, and
                    `B2` is not one. It is a chip rather than a dot precisely so
                    that it cannot be read as a third status — see `BindChip`.

                    No third *dot*: `StatusDot` keeps its slot and keeps owning
                    run state, which is a different question from where a link
                    from this session opens.
                  */}
                  {tab.kind === 'session' && <SessionBindChips {...bindKey(tab)} sessionName={spoken} />}
                  {tab.kind === 'browser' && (
                    <WindowBindChip browserTabId={tab.id} nameFor={sessionNameFor} />
                  )}
                </button>

                {/*
                  Two ✕s that look the same and mean opposite things —
                  2026-08-20. Read both branches together; neither is safe to
                  change on its own.

                  ## The session one: off the bar, nothing ended

                  *"for the sessions it will just close from the top bar, but it
                  will still stay in the side panel."* So it demotes and stops:
                  the pty runs, the rail keeps the row, the status dot keeps
                  moving. That reading is only available *because* the rail has
                  the row — which is the whole reason the browser branch below
                  cannot borrow it.

                  This is the branch a remote session takes too. `onEndRemote`
                  used to send one down the other road, ending it on its machine
                  from a glyph identical to this one; that is deleted rather than
                  rewired, because nothing on this bar may end a session.

                  ## The browser one: a real close

                  Because a page is listed nowhere else: *"Browser windows will
                  not be on the side bar at all."* With the rail out of the
                  picture, "off the strip" would leave a window open, bound to a
                  session, and drawn in no panel — so the only honest thing this
                  control can do is end it. It goes through the caller's usual
                  path, which is the same one ⌘W takes, so the main process
                  learns the window is gone and the number it was wearing is not
                  handed out again.

                  Nothing is asked first, and that is unchanged: there is no
                  process in a page to interrupt. The confirmation exists for
                  work that would be lost.

                  ## What keeps them apart on screen

                  `[data-ends]` on the browser one and not the session one. It is
                  the whole difference in the stylesheet: `--color-critical`
                  under the pointer for the ✕ that destroys something, plain grey
                  for the one that tidies. Plus a title each, two or three words,
                  naming the act rather than explaining it — no prose on screen
                  this round, so the argument is up here instead.

                  ## Absent rather than inert, on both

                  A host that cannot finish the act draws no ✕ for it — a test,
                  the harness mounting this bare. For the session that means
                  `onShowInstead`, without which taking the tab you are looking
                  at off the bar would visibly do nothing; see the prop.
                */}
                {tab.kind === 'session' && onShowInstead !== undefined && (
                  <button
                    type="button"
                    className="strip-tab-close"
                    // No `data-ends`. It is the only thing telling this ✕ apart
                    // from the one on the tab beside it, and this one ends
                    // nothing, so it must not wear the mark that says it does.
                    //
                    // See the guard in `onDragStart` above: the tab is draggable,
                    // and without this marker a press that slides a few pixels
                    // reorders the strip instead of taking this tab off it.
                    data-no-drag=""
                    aria-label={`Take ${full} off the bar`}
                    title="Take off the bar"
                    onClick={() => removeTab(tab.id)}
                  >
                    <Glyph path={CLOSE} />
                  </button>
                )}
                {tab.kind === 'browser' && onCloseWindow !== undefined && (
                  <button
                    type="button"
                    className="strip-tab-close"
                    data-ends=""
                    // See the guard in `onDragStart` above: the tab is draggable,
                    // and without this marker a press that slides a few pixels
                    // reorders the strip instead of closing this window.
                    data-no-drag=""
                    aria-label={`Close ${full}`}
                    title="Close this page"
                    onClick={() => onCloseWindow(tab.id)}
                  >
                    <Glyph path={CLOSE} />
                  </button>
                )}
              </div>
            )
          })}

          {/* The gap at the end, drawn only while something is being dragged past
              the last tab — otherwise the strip ends in an unexplained line. */}
          {dropAt === shown.length && <span className="strip-drop-end" aria-hidden="true" />}
        </div>
      </div>

      {openers}
    </div>
  )
}
