import { Terminal } from '@xterm/headless'
import type { SessionStatus } from '../shared/types'

/** Strip ANSI escapes, OSC sequences and carriage returns so patterns match
 *  against what a human actually sees, not the control codes. */
export function stripAnsi(input: string): string {
  return input
    // CSI / SGR sequences
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '')
    // OSC sequences, terminated by BEL or ST
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '')
    // Remaining two-character escapes
    .replace(/\x1b[()#][0-9A-Za-z]/g, '')
    .replace(/\x1b./g, '')
    .replace(/\r/g, '\n')
}

/**
 * Agent CLIs signal their state in the text they draw. These are the tells
 * that survive across versions — a spinner hint while thinking, a prompt box
 * when ready, an explicit question when blocked on a decision.
 */
const WORKING = [
  /esc to interrupt/i,
  /\btokens?\b.*\besc\b/i,
  /^\s*[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/m,
  /thinking[.…]/i,
]

/** A decision is being asked for — this is louder than merely idle. */
const NEEDS_INPUT = [
  /\bdo you want\b/i,
  /\(y\/n\)/i,
  /\[y\/N\]/i,
  /\byes\b.*\bno\b.*\?\s*$/i,
  /^\s*❯?\s*\d+\.\s/m,
  /press enter to continue/i,
  /overwrite\?/i,
]

/**
 * Ready and waiting for a prompt.
 *
 * Verified against real captured output: Claude Code draws its prompt as a
 * bare `❯` (U+276F) — not `>` — and then renders a horizontal rule and a
 * permissions hint BELOW it. So the prompt is never the final line, which is
 * why this is matched across a small window rather than at the very end.
 */
const WAITING = [
  /^\s*❯\s*$/m, // Claude Code, empty prompt
  /^\s*│\s*>\s*│?\s*$/m, // boxed prompt styles
  /^\s*>\s*$/m,
  /^.*[%$#]\s*$/m, // shell prompts
]

function matchesAny(patterns: RegExp[], text: string): boolean {
  return patterns.some((re) => re.test(text))
}

/** The last few non-empty lines — what the user is actually looking at now. */
function lastLines(text: string, count: number): string {
  const lines = text.split('\n').filter((l) => l.trim() !== '')
  return lines.slice(-count).join('\n')
}

/**
 * Classify a session from the tail of its visible output.
 *
 * Only the END of the output decides between waiting and needing input.
 * Scanning the whole buffer means a question asked and answered ten minutes
 * ago keeps the session flagged as blocked forever — verified against a real
 * PTY, where a finished command left the tab stuck on "needs input".
 *
 * Pure and synchronous so it can be tested without a terminal.
 */
export function classify(tail: string, exited: boolean): SessionStatus {
  if (exited) return 'exited'
  const text = stripAnsi(tail)

  // A spinner wins outright: output is still streaming, and a prompt box is
  // frequently still on screen above an in-flight response.
  if (matchesAny(WORKING, lastLines(text, 12))) return 'working'

  // An empty prompt near the bottom means it is ready for you, regardless of
  // what was asked earlier. Six lines because agent CLIs draw a rule and a
  // status hint beneath the prompt itself.
  const recent = lastLines(text, 6)
  if (matchesAny(WAITING, recent)) return 'waiting'

  // Only then does an unanswered question count as blocking.
  if (matchesAny(NEEDS_INPUT, lastLines(text, 10))) return 'input'

  return 'idle'
}

const SETTLE_MS = 700

/**
 * Watches one session's output and reports status transitions.
 *
 * It maintains a real (headless) terminal rather than scanning the raw byte
 * stream. Agent CLIs are full-screen TUIs that repaint using cursor-positioning
 * escapes, so the tail of the *stream* bears no relation to what is on the
 * *screen* — verified in the running app, where Claude's "1. Yes / 2. No"
 * prompt was plainly visible yet never appeared at the end of the stream.
 * Feeding an emulator and reading its viewport is the only way to ask
 * "what does the user actually see right now?".
 *
 * While bytes arrive the session is "working". Once output settles for
 * SETTLE_MS the screen is classified — mid-stream, "still thinking" and
 * "waiting for you" are indistinguishable, so the pause is the signal.
 */
export class ActivityTracker {
  private term: Terminal
  private status: SessionStatus = 'idle'
  private timer: NodeJS.Timeout | undefined
  private exited = false
  /**
   * True unless the host has been told nobody is attached. Defaults to watched,
   * so the desktop — which has a window in front of a person from the moment a
   * session exists — behaves exactly as it did before idle mode was written.
   */
  private watched = true

  constructor(
    private readonly id: string,
    private readonly onChange: (id: string, status: SessionStatus) => void,
    cols = 100,
    rows = 30,
  ) {
    this.term = new Terminal({ cols, rows, allowProposedApi: true, scrollback: 200 })
  }

  push(chunk: string): void {
    if (this.exited) return
    // Written even while unwatched, and this is the half that must not be
    // skipped. The emulator is the session's screen; a gap in what it was fed
    // is a screen that no longer matches the real terminal, and no later byte
    // repairs it — an agent sitting at a prompt sends nothing at all. Idling is
    // allowed to stop *asking what the screen says*; it is not allowed to lose
    // the screen.
    this.term.write(chunk)
    if (!this.watched) return
    this.set('working')

    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      // Flush pending writes before reading, or the viewport lags the output.
      this.term.write('', () => this.set(classify(this.visibleText(), false)))
    }, SETTLE_MS)
  }

  /**
   * Whether anybody is listening to the status this tracker produces.
   *
   * The headless host's idle mode drives this from the attach and detach events
   * — see `idle.ts`. With nothing attached there is no window and no phone to
   * receive a status change, so classifying every settle is work done for
   * nobody: a timer armed per output chunk, and a full sweep of the viewport
   * each time it fires, on every live session, forever.
   *
   * Going unwatched cancels the pending classification. Coming back runs one
   * immediately rather than waiting for the next byte, because the case that
   * matters is exactly the one where no next byte is coming: an agent that
   * finished and is waiting for an answer produces no output, and a phone
   * attaching to it must not be told the session is still working because the
   * last thing this tracker heard was output.
   */
  setWatched(watched: boolean): void {
    if (watched === this.watched) return
    this.watched = watched
    if (this.exited) return
    clearTimeout(this.timer)
    if (!watched) return
    this.timer = setTimeout(() => {
      this.term.write('', () => this.set(classify(this.visibleText(), false)))
    }, 0)
  }

  resize(cols: number, rows: number): void {
    try {
      this.term.resize(Math.max(cols, 1), Math.max(rows, 1))
    } catch {
      /* ignore invalid dimensions during teardown */
    }
  }

  /**
   * The visible viewport, as the user sees it.
   *
   * Public because the status classifier is not the only thing that needs to
   * know what is on screen: the chat controls read the permission-mode footer
   * and the CLI's replies to slash commands from this same buffer. One shadow
   * terminal per session, read by everyone — a second one fed the same bytes
   * would drift the moment a resize was missed on one of them.
   */
  settledText(): Promise<string> {
    // xterm parses what it is written asynchronously, so reading the buffer
    // straight after a write returns the screen as it was BEFORE that write.
    // Verified: running the readers over real captured output without this
    // flush reported "unknown" for every screen, including ones plainly
    // showing the answer. Writing an empty string queues a callback behind
    // whatever is still pending, which is how `classify` above already does it.
    return new Promise((resolve) => this.term.write('', () => resolve(this.visibleText())))
  }

  visibleText(): string {
    const buf = this.term.buffer.active
    const lines: string[] = []
    for (let y = 0; y < this.term.rows; y++) {
      const line = buf.getLine(buf.viewportY + y)
      if (line) lines.push(line.translateToString(true))
    }
    return lines.join('\n')
  }

  markExited(): void {
    this.exited = true
    clearTimeout(this.timer)
    this.set('exited')
  }

  dispose(): void {
    clearTimeout(this.timer)
    this.term.dispose()
  }

  private set(next: SessionStatus): void {
    if (next === this.status) return
    this.status = next
    this.onChange(this.id, next)
  }
}
