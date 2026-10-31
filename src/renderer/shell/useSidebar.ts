import { useCallback, useEffect, useRef, useState } from 'react'
import { setRailPanelWidth, useRailPanel } from '../copilot/driving/rail-panel'
import { isPanelId, type PanelId } from './panels'
import { RAIL_DEFAULT, readRailWidth, trackRailDrag } from './rail-width'

const WIDTH_KEY = 'deck.sidebar.width'
const COLLAPSED_KEY = 'deck.sidebar.collapsed'
const PANEL_KEY = 'deck.sidebar.panel'

/**
 * How long the peeked sidebar waits after the pointer leaves before sliding
 * back.
 *
 * This is a grace period, not a poll: the pointer crosses the sidebar's edge
 * on its way to a row near that edge, and without the grace the panel closes
 * under the cursor mid-reach. Long enough to survive a diagonal, short enough
 * that a deliberate move away feels immediate. There is no matching delay on
 * the way in — the reveal strip is eight pixels wide, so arriving on it is
 * already a deliberate act, and a delay there would make the panel feel stuck.
 */
export const PEEK_CLOSE_MS = 160

/**
 * Which view the window shows after somebody asks for one.
 *
 * A one-line function with a name, because the line it replaces was a bug and
 * a bug this shape has to stay killed. See `selectPanel` for the whole account;
 * the short version is that this used to answer `null` when the requested view
 * was already open, and every navigation in the app — including the Files
 * page's own "open this file" — went through it.
 *
 * Pure and exported so it can be pinned: there is no DOM in this project's
 * tests, so a hook cannot be driven, and the decision has to live somewhere a
 * test can reach it.
 */
export function panelAfterSelect(current: PanelId | null, asked: PanelId): PanelId {
  return current === asked ? current : asked
}

/**
 * The sidebar's width, whether it is pinned, whether it is being peeked at, and
 * which view it has selected.
 *
 * `panel` is nullable, and that is the whole shape of the shell: null means the
 * window is showing whatever session or page you have open, and a PanelId means
 * the sidebar has taken the window over with one of its views.
 *
 * ## Pinned, peeked, and why they are two states
 *
 * `collapsed` is a *preference* — "I do not want the sidebar taking up room" —
 * and it is persisted. `peeking` is a *gesture* — "show it to me for a second"
 * — and it is not. Reaching for the left edge of the window slides the sidebar
 * out over the content; taking the pointer away puts it back; clicking the
 * arrow in its gutter pins it, which is to say clears the preference. That is
 * the behaviour of the app this was modelled on, and the reason it works is
 * that the transient state never writes to the persistent one: a mouse passing
 * over the edge on its way somewhere else must not change what the window looks
 * like the next time it is opened.
 *
 * Persisted to localStorage rather than the main-process store: this is window
 * chrome, it changes on every frame of a drag, and round-tripping that through
 * IPC would be wasteful.
 */
export function useSidebar() {
  const [panel, setPanel] = useState<PanelId | null>(() => {
    const stored = localStorage.getItem(PANEL_KEY)
    return isPanelId(stored) ? stored : null
  })
  const [width, setWidth] = useState(() => readRailWidth(WIDTH_KEY, RAIL_DEFAULT))
  const [collapsed, setCollapsed] = useState(() => localStorage.getItem(COLLAPSED_KEY) === '1')
  const [peeking, setPeeking] = useState(false)
  const peekTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  useEffect(() => {
    if (panel) localStorage.setItem(PANEL_KEY, panel)
    else localStorage.removeItem(PANEL_KEY)
  }, [panel])
  useEffect(() => localStorage.setItem(COLLAPSED_KEY, collapsed ? '1' : '0'), [collapsed])
  useEffect(() => localStorage.setItem(WIDTH_KEY, String(width)), [width])

  const cancelPeekTimer = useCallback(() => {
    if (peekTimer.current === null) return
    clearTimeout(peekTimer.current)
    peekTimer.current = null
  }, [])

  // A timer that outlives the component fires setState into an unmounted tree.
  useEffect(() => cancelPeekTimer, [cancelPeekTimer])

  /*
   * Who has the rail's column, and how wide it is.
   *
   * Derived rather than pushed. The sidebar asks `useRailPanel` the same
   * question one tree lower to decide what to draw, so both read one store and
   * cannot disagree within a render — which they would if the panel wrote "I am
   * open" into a state this hook holds, because that write lands a frame after
   * the sidebar has already drawn at the old width.
   */
  const rail = useRailPanel()
  const panelHasColumn = rail.state === 'panel'
  const effective = panelHasColumn && rail.width !== null ? rail.width : width

  /*
   * The column's live width, published where CSS can read it.
   *
   * For the one panel that genuinely cannot join the layout: the scan's
   * (`drive-panel.css`), which is `position: fixed` on purpose — a panel that
   * pushed `.main` narrower would refit every terminal in the window and reflow
   * the buffers its own highlights are anchored to. It was sized with
   * `--sidebar-width`, the static 264px token, so on a rail dragged to 338 it
   * left a strip of the rail showing beside it — the same fault, on the same
   * edge, that the copilot's panel was moved into the rail to fix. It cannot be
   * moved, so it is given the number instead.
   *
   * On the document element rather than on `.app`, because the panel is a
   * sibling of `<App/>` rather than a child of it.
   */
  useEffect(() => {
    document.documentElement.style.setProperty('--rail-width', `${effective}px`)
  }, [effective])

  /**
   * Open a view in the window. Asking for the one already open keeps it open.
   *
   * ## This used to be a toggle, and the toggle was the thrashing
   *
   * `setPanel(current === next ? null : next)` reads as a tidy convenience and
   * it was the whole of the bug Asad recorded — a minute of the window
   * alternating between Files and a terminal, the sidebar highlighting Files
   * while the pane showed a blank shell. In his words: *"if I'm clicking on the
   * files from overview to files, for a second, it brought me to this session…
   * If I double click, it should not move to the other one. It should stay
   * there."*
   *
   * Two things were wrong with it, and only the first is the one people notice.
   *
   *  1. **A double click closed the page it had just opened.** Two clicks on a
   *     row is one gesture as far as a person is concerned, and it landed them
   *     back on a terminal they had not asked for.
   *
   *  2. **Every programmatic navigation went through it too, and one of them
   *     was a loop.** `App.tsx` routes *all* of them through `showPanel`:
   *     Source control handing a changed file to Files, the command palette
   *     opening a file, a dashboard tile, an alert's button — and the Files
   *     page itself, whose tree calls `onOpenFile` for every row you click.
   *     So clicking a file *while already on Files* meant `selectPanel('files')`
   *     with `files` already current, which closed the page and threw the
   *     window back to the session. That is reproducible in three clicks and it
   *     is what the recording caught: the page was not slow, it was leaving.
   *
   * So opening is idempotent, and it is the only meaning this function has.
   * Leaving a view is a separate act with its own name — `clearPanel`, which is
   * what selecting a session or a page in the rail calls — because "show me
   * this" and "stop showing me this" are two intentions and one of them must
   * not be able to happen by accident on the way to the other.
   *
   * It also used to un-collapse the sidebar as a side effect. That went with
   * the peek: opening a view from a *peeked* sidebar would have pinned it, so
   * glancing at the rail and clicking one row would permanently rearrange the
   * window — a gesture writing a preference, which is the one thing the two
   * states exist to keep apart.
   */
  const selectPanel = useCallback((next: PanelId) => {
    setPanel((current) => panelAfterSelect(current, next))
  }, [])

  /** Leave the views and go back to the open session or page. */
  const clearPanel = useCallback(() => setPanel(null), [])

  /** The pointer has reached the left edge, or the sidebar itself. */
  const beginPeek = useCallback(() => {
    cancelPeekTimer()
    setPeeking(true)
  }, [cancelPeekTimer])

  /** The pointer has left. Grace period, then back it goes. */
  const endPeek = useCallback(() => {
    cancelPeekTimer()
    peekTimer.current = setTimeout(() => {
      peekTimer.current = null
      setPeeking(false)
    }, PEEK_CLOSE_MS)
  }, [cancelPeekTimer])

  /** Keep it. The gesture becomes the preference. */
  const pin = useCallback(() => {
    cancelPeekTimer()
    setPeeking(false)
    setCollapsed(false)
  }, [cancelPeekTimer])

  /** Put it away. Also drops any peek, or it would stay on screen unpinned. */
  const collapse = useCallback(() => {
    cancelPeekTimer()
    setPeeking(false)
    setCollapsed(true)
  }, [cancelPeekTimer])

  /**
   * One seam, two numbers behind it.
   *
   * The separator on the rail's right edge is where both widths are dragged
   * from, because it is the *same edge* — while the copilot's panel has the
   * column there is no second boundary on screen to grab, and inventing one
   * would put two grips a pixel apart meaning almost the same thing.
   *
   * Which number it writes is decided at `mousedown` and not again: the panel
   * can open or fold under a drag that is already running, and a drag that
   * changed its mind halfway would leave both widths part-applied. The panel's
   * width is stored under its own key so that dragging the chat wider does not
   * quietly rewrite the width the rail opens at — *"we can actually make it
   * bigger and smaller, which is a great feature"* was said about the rail, and
   * a number he set there should not be spent by a panel passing through.
   */
  const startResize = useCallback(
    (event: React.MouseEvent) => {
      event.preventDefault()
      trackRailDrag(event.clientX, effective, (next) => {
        if (panelHasColumn) setRailPanelWidth(next)
        else setWidth(next)
      })
    },
    [effective, panelHasColumn],
  )

  return {
    panel,
    selectPanel,
    clearPanel,
    /**
     * How wide the rail's column is, whoever is in it.
     *
     * The copilot's panel *replaces* the rail rather than floating over it —
     * *"this should actually replace with this instead of coming in front of
     * it"* — so while it has the column this is its width, and `.sidebar` is
     * drawn at exactly that. A panel at a token width over a rail at a saved one
     * is the gap he filmed: the page starting 32px clear of a panel that had
     * already ended.
     *
     * Falls back to the rail's own width until the panel has been dragged, so
     * the first drive takes the column at the width he already chose rather than
     * jumping the seam on the way in.
     */
    width: effective,
    collapsed,
    peeking,
    /** On screen right now, pinned or not. This is what the shell renders on. */
    revealed: !collapsed || peeking,
    beginPeek,
    endPeek,
    pin,
    collapse,
    toggleCollapsed: useCallback(() => {
      // The chord and the menu item both come through here, and both mean "the
      // opposite of whatever I can see" — so a peeked sidebar is pinned rather
      // than collapsed, which is what pressing the key while looking at it
      // obviously means.
      if (collapsed) pin()
      else collapse()
    }, [collapsed, pin, collapse]),
    startResize,
  }
}
