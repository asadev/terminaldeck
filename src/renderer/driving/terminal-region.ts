import { NEEDLE_CHARS, needleOf, normalizeLine } from '../../shared/quote-match'
import { clipRect, type ClippedRect, type Rect } from './geometry'

/**
 * From a range of terminal *content* to a rectangle on the screen.
 *
 * ## The problem, stated exactly
 *
 * The focus overlay has to draw a box around a passage of terminal output. A
 * passage of terminal output is not a DOM node you can measure. What it is
 * depends on which of three things you mean, and only one of them is stable:
 *
 * | | stable across | breaks on |
 * |---|---|---|
 * | a pixel rectangle | nothing | scroll, resize, font change, new output |
 * | a viewport row number | new output while scrolled up | any scroll |
 * | an **absolute buffer line** | scroll, new output, resize-without-reflow | buffer trim, reflow |
 * | the **text itself** | everything | the text being overwritten |
 *
 * So the anchor is the text, the absolute buffer line is a cache of where the
 * text was last found, and the pixel rectangle is derived fresh on every frame
 * that could have moved it. Nothing positional is ever stored across a frame.
 *
 * ## Why not xterm's decoration API
 *
 * `registerMarker` + `registerDecoration` exist, the app already passes
 * `allowProposedApi: true`, and the obvious plan is to let xterm own the
 * positioning. Three facts, read out of the installed renderer
 * (`@xterm/xterm` 6.0.0, `src/browser/decorations/BufferDecorationRenderer.ts`),
 * make it the wrong tool *for this job* even though it is the right tool for
 * marking a line:
 *
 * 1. A decoration is hidden **entirely** when its marker line leaves the
 *    viewport — `if (line < 0 || line >= rows) element.style.display = 'none'`.
 *    A nineteen-line region scrolled one row off the top disappears completely,
 *    taking eighteen visible lines with it. Working around that means one
 *    marker and one decoration per line, styled as a set, which is nineteen DOM
 *    elements and nineteen disposables to keep in step with a dim that lives
 *    somewhere else entirely.
 * 2. Every decoration is hidden while the alternate screen buffer is active. A
 *    session sitting in `vim` or a full-screen TUI cannot be marked at all.
 *    That is a state to detect and degrade for, not a bug to route around —
 *    and it is easier to detect here than to discover as "the box did not
 *    appear".
 * 3. The decoration's element lives inside xterm's own container, while the
 *    dim is a window-level overlay. Two independent positioning systems that
 *    must agree pixel-for-pixel is a defect generator; the box and the hole in
 *    the scrim have to be *the same rectangle*, computed once.
 *
 * The arithmetic below is what that renderer does anyway — `top = (line −
 * ydisp) × cellHeight` — so this is not a reimplementation of something
 * cleverer, it is the same three multiplications with the region kept whole.
 *
 * ## Where the cell size comes from
 *
 * Measured, not asked for. xterm sizes `.xterm-screen` to exactly
 * `cols × cellWidth` by `rows × cellHeight`, so:
 *
 *     cellHeight = screen.height / rows
 *     cellWidth  = screen.width  / cols
 *
 * Verified against the running app: a 33-row terminal reported a screen height
 * of 743 px and a per-row `style.height` of 22.5152 px — and 743 / 33 =
 * 22.5152. Deriving it this way rather than reading xterm's private
 * `_renderService.dimensions` means font-size changes, zoom and DPR all come
 * out right with no code that knows about any of them, because all three change
 * the screen element's box and the row count together.
 *
 * ## The four states, and what each one did on a real pty
 *
 * `.harness/` cannot render this half: there is no pty behind it, so there is
 * no buffer to scan and no screen element to measure. So the terminal path was
 * driven in the packaged renderer against a live shell, and the four states
 * every claim above predicts a specific behaviour for were each looked at.
 * Recorded here rather than in a document because these are the numbers a
 * future change has to keep producing, and a document is not where somebody
 * editing this file looks.
 *
 * 1. **Fully on screen.** A four-line passage at absolute lines 45–48, viewport
 *    top at 26. Box drawn at the four lines, all four edges present, width the
 *    longest line plus a cell rather than all 144 columns.
 * 2. **Half scrolled off the top.** Viewport top moved to 46, so line 45 was
 *    above it. The remaining three lines stayed boxed, `edges.top` went false,
 *    the top border and the top half of the glow were suppressed and the two
 *    top corners squared. This is the state xterm's own decoration renderer
 *    answers with `display: none` — the whole nineteen-line box disappearing
 *    because one line left the viewport — and it is the single reason the
 *    geometry is computed here instead.
 * 3. **After a resize that reflows.** The pane narrowed from 144 to 82 columns,
 *    which re-wrapped a 600-character line above the passage from 5 rows to 8
 *    and moved the passage's first absolute line from 9 to 12. The box stayed
 *    on the same three lines of text and moved to their new position: the
 *    cached index was thrown away on resize (see `FocusOverlay`'s `reflowed`)
 *    and the text was found again. Nothing was kept that could have drifted.
 * 4. **While the session is in `vim`.** Entering the alternate buffer with a
 *    box up removed it in the same frame — no ring, no scrim, no residue —
 *    and `:q!` brought it back at the same coordinates. The overlay reports
 *    `alternate-buffer` for this rather than boxing a screen that has no
 *    scrollback to anchor in.
 *
 * And the one that is not a state but a stream: with output still arriving,
 * each row the buffer scrolled moved the ring up by exactly one cell height
 * (22 px measured, viewport top 0 → 1, ring y 148 → 126), and when the passage
 * passed the top edge entirely the overlay stopped drawing rather than clamping
 * the box to the top of the pane.
 */

/** The slice of xterm's `Terminal` this needs. Structural, so tests need no xterm. */
export interface TerminalMetrics {
  /** `.xterm-screen` in window CSS pixels. */
  screen: Rect
  cols: number
  rows: number
}

export interface CellSize {
  width: number
  height: number
}

/**
 * One character cell, in window CSS pixels.
 *
 * Returns null rather than dividing by zero when the terminal is not laid out —
 * a hidden tab reports a 0×0 screen and `cols`/`rows` from the last time it was
 * measured, and the honest answer there is "no geometry", not `Infinity`.
 */
export function cellSize(metrics: TerminalMetrics): CellSize | null {
  if (metrics.cols <= 0 || metrics.rows <= 0) return null
  if (metrics.screen.width <= 0 || metrics.screen.height <= 0) return null
  return {
    width: metrics.screen.width / metrics.cols,
    height: metrics.screen.height / metrics.rows,
  }
}

/**
 * A passage of output, in absolute buffer coordinates.
 *
 * "Absolute" means counted from the start of the scrollback, which is what
 * `buffer.baseY`, `buffer.viewportY` and `IMarker.line` are all in. It is not a
 * viewport row and the two are only equal when the terminal is scrolled to the
 * very top.
 */
export interface BufferRegion {
  /** First absolute buffer line, inclusive. */
  line: number
  /** How many lines the passage covers. At least 1. */
  lines: number
  /** First column, inclusive. */
  startCol: number
  /** Last column, exclusive. */
  endCol: number
}

/**
 * Where a region is on screen right now, clipped to the terminal's viewport.
 *
 * `viewportY` is `buffer.active.viewportY` — the absolute line currently drawn
 * at the top row. **Everything about scrolling and about new output is this one
 * subtraction.** When the reader scrolls up, `viewportY` falls and the box
 * moves down. When output arrives and the terminal is following the tail,
 * `viewportY` rises and the box moves up, because the content it is pointing at
 * genuinely moved up. Neither case is special-cased anywhere, and neither can
 * drift out of step, because there is no stored position to drift.
 *
 * Returns null when the passage is entirely outside the viewport. That is a
 * real state with a real answer — the caller stops drawing and can scroll the
 * terminal back to it — and it is deliberately not clamped to the pane's edge,
 * because a box pinned to the top of a terminal is a box claiming the passage
 * is at the top of the terminal.
 */
export function regionRect(
  region: BufferRegion,
  viewportY: number,
  metrics: TerminalMetrics,
): ClippedRect | null {
  const cell = cellSize(metrics)
  if (cell === null) return null

  const row = region.line - viewportY
  const raw: Rect = {
    x: metrics.screen.x + region.startCol * cell.width,
    y: metrics.screen.y + row * cell.height,
    width: Math.max(0, region.endCol - region.startCol) * cell.width,
    height: Math.max(1, region.lines) * cell.height,
  }
  return clipRect(raw, metrics.screen)
}

/* ------------------------------------------------------------- locating -- */

/**
 * How far back through the scrollback a quote is looked for.
 *
 * 4 000 lines, matching `SCROLLBACK_LIMIT` in `pty-manager.ts` rather than
 * xterm's own `scrollback: 10_000`. Beyond the main process's retention there
 * is nothing the copilot could have read in order to quote it, so searching
 * further can only find a coincidence.
 */
export const SEARCH_BACK = 4000

/**
 * The longest a region may be.
 *
 * More than a screenful on any window this app runs in, so the cap never bites
 * a legitimate passage; it exists so a quote that accidentally matches at the
 * top of a 4 000-line buffer cannot produce a box four thousand lines tall.
 */
export const MAX_REGION_LINES = 40

/*
 * The comparison itself is not defined here any more, and moving it was not
 * tidying.
 *
 * `normalizeLine` and `needleOf` used to live in this file, which was the right
 * home while the renderer was the only thing asking the question. It is not any
 * more: `deck-control/tour.ts` runs the *same* check in the main process,
 * against the retained pty scrollback, before a plan is ever allowed near a
 * window. That is the gate that stops a fabricated quote reaching the screen;
 * this file is what decides where the box goes once one has passed it.
 *
 * Two copies of "is this string in that text" would agree right up until the day
 * one of them learned about a control character the other did not, and then a
 * stop would pass the gate and fail to draw — a hole in a tour with nothing to
 * blame it on. So there is one copy, in `shared/quote-match.ts`, and both sides
 * import it. They are re-exported from here because this module's own callers
 * ask this file for them, and consolidating the check was not meant to be a
 * rename.
 */
export { NEEDLE_CHARS, needleOf, normalizeLine }

/**
 * Read access to a terminal buffer, by absolute line.
 *
 * An interface rather than the `Terminal` itself so the scan is testable
 * without an xterm, a canvas or a DOM — which is the difference between the
 * hard half of this feature having tests and not having them.
 */
export interface BufferReader {
  /** Oldest absolute line still retained. */
  first: number
  /** One past the newest absolute line. */
  end: number
  /** A line's text, or null if that index is no longer in the buffer. */
  line(index: number): string | null
  /** Columns, for capping a region's width. */
  cols: number
}

/**
 * Find a quote in the buffer, most recent occurrence first.
 *
 * ## Why backwards, and why the last match wins
 *
 * Agent CLIs repaint. Claude Code redraws its status line, its spinner and the
 * box around the prompt many times a second, and a session that has run for an
 * hour contains the same string dozens of times over. Every one of those is a
 * true occurrence and only the newest is the one on screen now, so the scan
 * runs from the tail backwards and stops at the first hit it finds. Searching
 * forwards would reliably box the oldest painting of the right line — a box in
 * the wrong place, pointing at real text, which is the hardest kind of wrong to
 * notice.
 *
 * ## Why not `SearchAddon`
 *
 * It is already loaded (`TerminalView.tsx`) and it can find things. It finds
 * them by **selecting** them, and `TerminalView` wires `onSelectionChange` to
 * copy the selection to the clipboard whenever Copy-on-select is enabled. A
 * tour would silently overwrite the user's clipboard once per stop, which is
 * the sort of side effect nobody would ever connect back to a highlight.
 *
 * ## The width of the box
 *
 * Not the full terminal width. A 109-column terminal showing a 40-character
 * message would get a box with 69 columns of highlighted emptiness on the right,
 * which reads as a selected row rather than as a pointer at a passage. The
 * region's `endCol` is the longest line in it plus one cell of breathing room,
 * capped at the terminal's width.
 */
export function locateQuote(reader: BufferReader, quote: string): BufferRegion | null {
  const needle = needleOf(quote)
  if (needle === '') return null

  const quoted = quote
    .split('\n')
    .map(normalizeLine)
    .filter((line) => line !== '')
  const wanted = Math.min(quoted.length, MAX_REGION_LINES)

  const floor = Math.max(reader.first, reader.end - SEARCH_BACK)
  for (let index = reader.end - 1; index >= floor; index--) {
    const text = reader.line(index)
    if (text === null) continue
    if (!normalizeLine(text).includes(needle)) continue

    /*
     * The needle matched; now walk forward to find how much of the rest of the
     * quote is really there.
     *
     * Forward from the hit rather than requiring the whole quote up front,
     * because a repaint can truncate the tail of a passage: the first line is
     * on screen and the last three were overwritten. Boxing what is actually
     * present is right, and reporting nothing because line four went missing
     * is not.
     *
     * Blank lines inside the buffer are skipped rather than failing the match:
     * a TUI that draws a bordered box puts an empty padding row between the
     * heading and the body, and the transcript the quote came from does not.
     */
    let covered = 1
    let matched = 1
    let cursor = index + 1
    while (matched < wanted && cursor < reader.end && covered < MAX_REGION_LINES) {
      const next = reader.line(cursor)
      if (next === null) break
      const clean = normalizeLine(next)
      if (clean === '') {
        covered++
        cursor++
        continue
      }
      if (!clean.includes(quoted[matched]) && !quoted[matched].includes(clean)) break
      matched++
      covered++
      cursor++
    }

    let widest = 0
    for (let i = index; i < index + covered; i++) {
      const line = reader.line(i)
      if (line !== null) widest = Math.max(widest, line.replace(/\s+$/, '').length)
    }

    return {
      line: index,
      lines: covered,
      startCol: 0,
      // One cell of air on the right, and never wider than the terminal. The
      // floor of 8 keeps a one-word line from getting a box narrower than the
      // ring's own corner radius, which reads as a rendering artefact.
      endCol: Math.min(reader.cols, Math.max(8, widest + 1)),
    }
  }
  return null
}
