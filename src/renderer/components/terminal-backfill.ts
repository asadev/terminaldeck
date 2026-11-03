/**
 * Why a terminal that is being filled in does not paint until it is full.
 *
 * ## The defect, which he filmed
 *
 *   > *"If I click on any of the remote session, it will start from the
 *   > beginning and scroll the full page, and it will have this kind of
 *   > glitches, then it will recover. Why it's not keeping itself to the end
 *   > once it is loaded? … If I go to other page and come back, it will start
 *   > from beginning again."*
 *
 * Opening a session replays what it has already printed — that is the feature,
 * and it is what makes a session you left on another machine worth opening at
 * all. What was wrong is that the replay was **watched**: the whole afternoon's
 * output scrolled past, a screen at a time, before settling at the bottom.
 *
 * ## Why writing it "all at once" does not fix it
 *
 * The obvious reading is that the backlog arrives in pieces — and it does: the
 * far machine sends up to 64 `output` frames of 32 KB each
 * (`MAX_REPLAY_CHUNKS`, `OUTPUT_CHUNK_BYTES`), so a busy session is dozens of
 * separate writes. But collapsing them into one `term.write` changes nothing,
 * because xterm never parses a large write in one go. From its own
 * `WriteBuffer.ts` (`@xterm/xterm@6.0.0`):
 *
 *     const WRITE_TIMEOUT_MS = 12;
 *     // "The max number of ms to spend on writes before allowing the renderer
 *     //  to catch up with a 0ms setTimeout."
 *
 * `write()` schedules `_innerWrite` on a macrotask and yields back to the event
 * loop every 12 ms until the buffer is drained. Every one of those yields is a
 * frame the renderer paints — and each frame is the viewport scrolled a little
 * further down the backlog. Two megabytes of scrollback is therefore *always*
 * a few seconds of animated history, whether it arrives as one write or sixty.
 * Writing it *more slowly* would make it worse; writing it faster is not
 * possible.
 *
 * So the fix cannot be about how the bytes are written. It is about what is on
 * screen while they are: nothing. The surface is held at `opacity: 0` while the
 * backlog is written, and revealed once — scrolled to the bottom — when xterm
 * says it has parsed it. What a person sees is an empty terminal for a moment
 * and then the session, already at its latest output.
 *
 * ## `opacity`, not `visibility` and not `display`
 *
 * `display: none` takes the element's box away, and xterm measures the element
 * it was opened on: a fit against a hidden host computes a nonsense column
 * count, which is the "reflow of scrambled output" `RemoteTerminal` already
 * guards against by fitting before it attaches.
 *
 * `visibility: hidden` keeps the box but makes the subtree unfocusable, and
 * both terminals call `focus()` on the frame they become visible — the
 * keyboard would land nowhere until the person clicked.
 *
 * `opacity: 0` keeps layout, keeps focus, and costs one composited layer that
 * draws nothing. It is the only one of the three that changes what is *seen*
 * and nothing else.
 *
 * ## Knowing when the backlog has finished
 *
 * There are two answers and this module takes whichever arrives first.
 *
 * A **local** session knows exactly: the backlog is one string, read once from
 * the main process, and {@link Backfill.release} is called with it.
 *
 * A session on another machine has no end-of-replay marker on the wire — the
 * frames carry `replay: true` and the run of them simply stops. So the caller
 * releases on the first frame that is *not* replay, and {@link
 * BackfillOptions.quiet} covers the ordinary case where there is no such frame,
 * because the session is idle and waiting for input. Adding a marker to the
 * protocol would have been the exact answer, and would also have meant a phone
 * or an older desktop on the far end never sending one — a fix that works only
 * between two machines updated on the same day is not a fix.
 *
 * {@link BackfillOptions.limit} is the backstop under both: the screen is never
 * held for longer than that, whatever else is or is not still arriving. A
 * terminal that stayed blank because a read never came back would be a worse
 * bug than the one this file exists to remove.
 */

/** The slice of xterm's `Terminal` this needs. Structural, so a test needs no DOM. */
export interface FilledTerminal {
  write(data: string, done?: () => void): void
  scrollToBottom(): void
}

/** The element the terminal was opened on. Structural for the same reason. */
export interface FilledSurface {
  readonly style: { opacity: string }
}

export interface BackfillOptions {
  /**
   * Milliseconds of silence that mean the backlog has stopped arriving.
   *
   * Only for a caller that cannot be told — a session on another machine, where
   * the run of `replay` frames ends without saying so. Omitted for a local
   * session, which is handed its backlog in one piece and releases explicitly.
   */
  quiet?: number
  /**
   * The longest the screen may be held, whatever is still arriving.
   *
   * Not a tuning knob: it is the promise that this module can only ever delay a
   * terminal, never hide one.
   */
  limit?: number
}

export interface Backfill {
  /** One chunk. Held while the terminal is still being filled; written after. */
  push(data: string): void
  /**
   * The backlog is complete. Writes what was held — `backlog` first, because a
   * caller that has one has the *older* bytes — and reveals the screen once
   * xterm has parsed it.
   *
   * Safe to call more than once; every call after the first does nothing.
   */
  release(backlog?: string): void
  /** The terminal is going away. Drops the timers and stops touching it. */
  stop(): void
}

/** Silence that means a far machine has finished replaying. */
export const QUIET_MS = 150

/** The longest any terminal is held. See {@link BackfillOptions.limit}. */
export const HOLD_LIMIT_MS = 2000

/**
 * Hold a terminal's screen until it has been filled in, then show it once.
 *
 * Call it as the terminal is built, before anything is written to it, and call
 * {@link Backfill.stop} from the same cleanup that disposes the terminal.
 */
export function holdUntilFilled(
  term: FilledTerminal,
  surface: FilledSurface,
  { quiet, limit = HOLD_LIMIT_MS }: BackfillOptions = {},
): Backfill {
  const held: string[] = []
  let holding = true
  let alive = true
  let quietly: ReturnType<typeof setTimeout> | null = null
  let deadline: ReturnType<typeof setTimeout> | null = null

  surface.style.opacity = '0'

  const stopClocks = (): void => {
    if (quietly !== null) clearTimeout(quietly)
    if (deadline !== null) clearTimeout(deadline)
    quietly = null
    deadline = null
  }

  /*
   * Guarded on `alive` because this runs from xterm's write callback, which is
   * a task scheduled inside the terminal — a session closed while its backlog
   * was still parsing would otherwise reach a disposed terminal.
   */
  const reveal = (): void => {
    if (!alive) return
    term.scrollToBottom()
    surface.style.opacity = ''
  }

  const release = (backlog = ''): void => {
    if (!holding) return
    holding = false
    stopClocks()
    const text = backlog + held.join('')
    held.length = 0
    if (text === '') {
      reveal()
      return
    }
    // Revealed from the callback rather than on the next line: `write` returns
    // as soon as the data is queued, and the whole point of this file is that
    // the screen appears when the bytes are *on* it.
    term.write(text, reveal)
  }

  deadline = setTimeout(() => release(), limit)

  return {
    push(data) {
      if (!holding) {
        term.write(data)
        return
      }
      held.push(data)
      if (quiet === undefined) return
      if (quietly !== null) clearTimeout(quietly)
      quietly = setTimeout(() => release(), quiet)
    },
    release,
    stop() {
      holding = false
      alive = false
      stopClocks()
      // The opacity is deliberately left as it is. The element belongs to the
      // component that is being torn down, and a terminal put back up runs this
      // function again from the top.
    },
  }
}
