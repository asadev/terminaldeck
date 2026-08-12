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

/** Ready and waiting for a prompt. */
const WAITING = [
  /│\s*>\s*$/m,
  /^\s*>\s*$/m,
  /╭─+╮[\s\S]*│\s*>/m,
  /\$\s*$/,
  /%\s*$/,
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

  // A prompt sitting at the very end means it is ready for you, regardless of
  // what was asked earlier in the buffer.
  const recent = lastLines(text, 3)
  if (matchesAny(WAITING, recent)) return 'waiting'

  // Only then does an unanswered question count as blocking.
  if (matchesAny(NEEDS_INPUT, lastLines(text, 8))) return 'input'

  return 'idle'
}

const TAIL_CHARS = 4000
const SETTLE_MS = 700

/**
 * Watches one session's output and reports status transitions.
 *
 * While bytes are arriving the session is "working". Once output settles for
 * SETTLE_MS the tail is classified, which is what distinguishes "waiting for
 * you" from "still thinking" — a distinction you cannot make from a single
 * chunk, because both look identical mid-stream.
 */
export class ActivityTracker {
  private tail = ''
  private status: SessionStatus = 'idle'
  private timer: NodeJS.Timeout | undefined
  private exited = false

  constructor(
    private readonly id: string,
    private readonly onChange: (id: string, status: SessionStatus) => void,
  ) {}

  push(chunk: string): void {
    if (this.exited) return
    this.tail = (this.tail + chunk).slice(-TAIL_CHARS)
    this.set('working')

    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.set(classify(this.tail, false)), SETTLE_MS)
  }

  markExited(): void {
    this.exited = true
    clearTimeout(this.timer)
    this.set('exited')
  }

  dispose(): void {
    clearTimeout(this.timer)
  }

  private set(next: SessionStatus): void {
    if (next === this.status) return
    this.status = next
    this.onChange(this.id, next)
  }
}
