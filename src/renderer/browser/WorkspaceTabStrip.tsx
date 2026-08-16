import { useCallback, useEffect, useRef, useState, type DragEvent, type KeyboardEvent } from 'react'
import { StatusDot } from '../components/StatusDot'
import {
  isTabDrag,
  KIND_ICON,
  middleEllipsis,
  readTabDrag,
  startTabDrag,
  STRIP_LABEL_BUDGET,
  tabLabel,
  tabTooltip,
  type WorkspaceTab,
} from '../shell/workspace-tabs'
import {
  demote,
  dropIndex,
  promote,
  pruneOrder,
  stripTabs,
  usePromotedOrder,
} from './workspace-strip'
import './WorkspaceTabStrip.css'

/**
 * The tab strip along the top: the windows you promoted out of the side panel.
 *
 * ## Where this file lives, and why that is temporary
 *
 * It belongs in `src/renderer/shell/` beside `Sidebar.tsx` and
 * `WindowToolbar.tsx` — it is shell chrome, and it holds terminals as well as
 * browser pages. It is here because this change was made while six agents were
 * editing the same working tree and `shell/` was another agent's. Moving it is a
 * `git mv` and two import paths; nothing about it is browser-specific.
 *
 * ## What he asked for
 *
 * From the recording of 2026-08-16: *"we should be able to just drag and drop in
 * the top whatever we want to see in the top, and the rest we can fold inside
 * the side panel."* So this is not a tab bar in the usual sense — it is not the
 * list of what is open, because the sidebar is already that and doing it twice
 * is the "four pieces of chrome answering one question" this app removed a
 * strip for once before. It is the subset you chose, and the only thing that
 * puts a tab in it is you.
 *
 * ## The drag, in both directions
 *
 * - **Into the strip.** A sidebar row is the drag source; this is the drop
 *   target. The contract is `TAB_DRAG_MIME` in `shell/workspace-tabs.ts` and
 *   the source needs three lines — see the note on {@link WorkspaceTabStrip}'s
 *   props.
 * - **Within the strip.** Dragging a promoted tab sideways reorders it. Handled
 *   entirely here, because both ends are this component.
 * - **Out of the strip.** Dropping a promoted tab anywhere that is not the strip
 *   folds it back into the side panel. That is `onDragEnd` seeing that nothing
 *   in here accepted the drop, which is deliberately *not* the same as requiring
 *   the sidebar to be a drop target: the rail is already showing the tab, so
 *   "put it back" needs no receiver.
 *
 * Every one of those is a mouse gesture, so none of them is the whole feature.
 * Each tab carries a fold-away control, ⌥← and ⌥→ move a focused tab along the
 * strip, and the sidebar row has a toggle that puts a window here without a
 * drag at all — see `usePromotedOrder`, which is how the two ends share one
 * list.
 */

export interface WorkspaceTabStripProps {
  /** Every window that is open — the same list the sidebar renders. */
  tabs: readonly WorkspaceTab[]
  /** The tab the window is currently showing, or null. */
  activeTabId: string | null
  onSelect(id: string): void
  /**
   * Close the window itself, not just fold it away.
   *
   * Optional: without it a strip tab offers only "fold back into the side
   * panel", which is the safe half. A control that looks like a close button
   * and silently does something else would be worse than no control.
   */
  onClose?: (id: string) => void
  /** Injectable for tests. Defaults to `window.localStorage`. */
  storage?: Storage | null
}

export function WorkspaceTabStrip({
  tabs,
  activeTabId,
  onSelect,
  onClose,
  storage,
}: WorkspaceTabStripProps) {
  const store =
    storage === undefined ? (typeof window === 'undefined' ? null : window.localStorage) : storage

  const [order, setOrder] = usePromotedOrder(store)
  /** The gap the pointer is currently over, or null when nothing is being dragged. */
  const [dropAt, setDropAt] = useState<number | null>(null)
  /**
   * A tab drag is happening *somewhere in this window*.
   *
   * Not the same question as "the pointer is over the strip", which is what
   * `dropAt` answers, and the distinction is the whole reason this exists: an
   * empty strip that only lights up once you are already on top of it is a
   * target you have to find before it will admit it is a target. Armed, it
   * says so from the moment the drag starts, which is while you are still
   * deciding where to go.
   */
  const [armed, setArmed] = useState(false)
  /** The tab this strip is the source of, so a drop elsewhere can demote it. */
  const dragging = useRef<string | null>(null)
  /** The same id as React state, for the source tab's own lifted look. */
  const [draggingId, setDraggingId] = useState<string | null>(null)
  /** Set by our own drop handler, so `onDragEnd` can tell a reorder from a fold. */
  const droppedHere = useRef(false)
  const listRef = useRef<HTMLDivElement | null>(null)

  const promoted = stripTabs(order, tabs)

  /*
   * Persist the arrangement, pruned to what still exists.
   *
   * Pruned on the way *out* rather than on the way in, and only when there are
   * tabs to prune against: a render that happens before the session list has
   * loaded would otherwise see an empty list, decide every promoted id is dead,
   * and erase the strip permanently.
   *
   * The store writes through to storage itself and ignores a set that changes
   * nothing, which is what stops this effect from re-triggering on the array it
   * just produced.
   */
  useEffect(() => {
    if (tabs.length === 0) return
    setOrder(pruneOrder(order, tabs))
  }, [order, setOrder, tabs])

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
    if (id && !droppedHere.current) setOrder(demote(order, id))
    droppedHere.current = false
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

  /*
   * Nothing exists to drag, so there is nothing to teach.
   *
   * The hint below is right whenever there is something in the side panel that
   * could be promoted, and wrong the moment there is not: on a fresh launch,
   * with no project open and no session started, it invites a gesture that
   * cannot be performed and takes a strip of the window forever to say so.
   * Rendered against the real build, that is exactly how it looked — a bar
   * across an otherwise empty window, above the words "Nothing open yet".
   *
   * `tabs`, not `promoted`: the question is whether a drag is *possible*, not
   * whether one has happened.
   */
  if (tabs.length === 0) return null

  if (promoted.length === 0) {
    /*
     * Nothing promoted yet, but something could be.
     *
     * Three states, quiet to loud, because they answer three different
     * questions. At rest it is a sentence in muted grey — the only thing in the
     * app that says this gesture exists. While a tab is being dragged anywhere
     * in the window it draws an edge of its own, so the place to let go is
     * visible from wherever the pointer currently is. Once the pointer is
     * actually over it, it fills with the accent, which is this app's one way
     * of saying "this one".
     *
     * No caret in this state, unlike the populated strip: a caret marks *which
     * gap* a tab will land in, and an empty strip has one gap. Drawn beside a
     * centred sentence it would read as a text cursor in the middle of a word.
     */
    return (
      <div
        className="strip strip-empty"
        data-armed={armed || undefined}
        data-over={dropAt !== null || undefined}
        onDragOver={onDragOver}
        onDragLeave={() => setDropAt(null)}
        onDrop={onDrop}
      >
        <p className="strip-hint">Drag a session or a page here to keep it along the top.</p>
      </div>
    )
  }

  return (
    <div
      className="strip"
      role="tablist"
      aria-label="Promoted windows"
      data-armed={armed || undefined}
      ref={listRef}
      onDragOver={onDragOver}
      onDragLeave={() => setDropAt(null)}
      onDrop={onDrop}
    >
      {promoted.map((tab, index) => {
        // The sidebar's name for the same window, then cut to fit — in that
        // order, so an unnamed session is "Session 2" in both places rather
        // than its folder name up here and its number down there.
        const full = tabLabel(tab, tabs)
        const label = middleEllipsis(full, STRIP_LABEL_BUDGET)
        return (
          <div
            key={tab.id}
            data-strip-tab=""
            className="strip-tab"
            data-active={tab.id === activeTabId || undefined}
            data-drop-before={dropAt === index || undefined}
            data-dragging={tab.id === draggingId || undefined}
            draggable
            onDragStart={(event) => {
              dragging.current = tab.id
              setDraggingId(tab.id)
              droppedHere.current = false
              startTabDrag(event.dataTransfer, tab.id)
            }}
            onDragEnd={onDragEnd}
            onKeyDown={(event) => moveByKey(event, tab.id, index)}
          >
            <button
              type="button"
              role="tab"
              aria-selected={tab.id === activeTabId}
              className="strip-tab-face"
              /* The whole title and the folder it runs in — the two things a
                 24-character tab cannot say for itself, and the pair that tells
                 three sessions in one project apart. */
              title={tabTooltip(tab, full)}
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
                <path d={KIND_ICON[tab.kind]} />
              </svg>
              {/* The app's own status dot, not a second one drawn here: it owns
                  the colour, the fill and — the part that matters — the words a
                  screen reader says for each state, and a private copy would drift
                  from the sidebar's. A browser page has no status and gets no
                  mark, rather than a grey one that means nothing. */}
              {tab.kind === 'session' && tab.status && <StatusDot status={tab.status} />}
              <span className="strip-tab-label">{label}</span>
            </button>

            <button
              type="button"
              className="strip-tab-fold"
              aria-label={`Fold ${full} back into the sidebar`}
              title="Fold back into the sidebar"
              onClick={() => setOrder(demote(order, tab.id))}
            >
              <svg
                width="14"
                height="14"
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.6"
                strokeLinecap="round"
                strokeLinejoin="round"
                aria-hidden="true"
              >
                {/* An arrow into a bar on the left: put this back in the rail.
                    Deliberately not an ✕ — this does not close anything, and a
                    control that looks like a close button and is not is the one
                    mistake this strip cannot afford to make. */}
                <path d="M20 12H9M13 8l-4 4 4 4M5 5v14" />
              </svg>
            </button>

            {onClose && tab.closable && (
              <button
                type="button"
                className="strip-tab-close"
                aria-label={`Close ${full}`}
                title="Close"
                onClick={() => onClose(tab.id)}
              >
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="1.6"
                  strokeLinecap="round"
                  aria-hidden="true"
                >
                  <path d="M7 7l10 10M17 7L7 17" />
                </svg>
              </button>
            )}
          </div>
        )
      })}

      {/* The gap at the end, drawn only while something is being dragged past
          the last tab — otherwise the strip ends in an unexplained line. */}
      {dropAt === promoted.length && <span className="strip-drop-end" aria-hidden="true" />}
    </div>
  )
}
