/**
 * Deriving a meaningful tab title for a session.
 *
 * A folder name is a poor label: three tabs on the same repo all read
 * `terminaldeck`, and none of them says what the agent is actually doing. This module
 * turns whatever evidence exists — a title the CLI wrote, the first prompt of
 * the conversation, the terminal's own output — into one short line, and falls
 * back to the folder name only when nothing better is available.
 *
 * Everything here is pure. The renderer supplies the bytes; this decides what
 * they mean.
 *
 * ## Where the good titles come from
 *
 * Claude Code appends bookkeeping lines to its JSONL transcript alongside the
 * conversation itself. Verified against the real transcripts in
 * `~/.claude/projects` on this machine:
 *
 *   {"type":"custom-title","customTitle":"Relay handshake requirements",…}
 *   {"type":"ai-title","aiTitle":"Build luxury car rental website with WebGL 3D experience",…}
 *   {"type":"last-prompt","lastPrompt":"does it requires a setup like…",…}
 *   {"type":"user","message":{"role":"user","content":"…"},"promptSource":"sdk",…}
 *
 * `custom-title` is what the user named the conversation, `ai-title` is what
 * the model named it — both are better than anything we could infer, so they
 * are preferred over parsing prompts. Both lines are rewritten as the
 * conversation evolves, so the LAST occurrence is the current one; the first
 * user message, by contrast, is fixed for the life of the session, which makes
 * it the stable fallback.
 */

/* -------------------------------------------------------------------------- */
/* Text hygiene                                                                */
/* -------------------------------------------------------------------------- */

/**
 * Escape sequences a terminal consumes and a human never sees.
 *
 * Deliberately a separate implementation from the main process's stripper in
 * `session-activity.ts`: that module pulls in `@xterm/headless`, and importing
 * it here would drag a terminal emulator into the renderer bundle for the sake
 * of one regex.
 *
 * Carriage returns are left alone — callers that care about lines normalise
 * them, and `unread.ts` wants them counted as the whitespace they are.
 */
const ANSI_PATTERN = new RegExp(
  [
    '\\x1b\\[[0-9;?]*[ -/]*[@-~]', // CSI, which covers every SGR colour run
    '\\x1b\\][^\\x07\\x1b]*(?:\\x07|\\x1b\\\\)', // OSC, BEL- or ST-terminated
    '\\x1b[()#][0-9A-Za-z]', // charset selection
    '\\x1b[@-Z\\\\-_]', // the remaining two-byte escapes
  ].join('|'),
  'g',
)

/** Remove terminal escape sequences, leaving the characters a human sees. */
export function stripAnsi(input: string): string {
  return input.replace(ANSI_PATTERN, '')
}

/** Longest title a tab shows before it is cut. Tabs are 132–220px wide. */
export const MAX_TITLE_LENGTH = 40

/**
 * Below this fraction of the budget a word boundary is not worth honouring.
 *
 * Cutting at the last space is only an improvement when it keeps most of the
 * budget. `Implementation-of-the-widget pipeline` has its first space at
 * character 28 of 40 — fine — but a 60-character URL has none at all, and
 * cutting at its single early slash would leave a two-character title.
 */
const WORD_BOUNDARY_FLOOR = 0.5

/** Trailing punctuation that reads as damage once the tail is gone. */
const DANGLING_PUNCTUATION = /[\s,.;:!?/\\|—–-]+$/

/**
 * Shorten to `max` characters, preferring to break between words.
 *
 * Appends an ellipsis only when something was actually removed, so a title
 * that fits is returned byte-for-byte.
 *
 * The ellipsis is spent out of the budget, not added on top of it: a label cut
 * to fit a 40-character tab and then handed back at 41 has not been cut to
 * fit, and the character the tab clips is the very one marking the cut.
 */
export function truncateOnWordBoundary(text: string, max = MAX_TITLE_LENGTH): string {
  if (max <= 0) return ''
  if (text.length <= max) return text

  const budget = max - 1 // the ellipsis takes the last character
  if (budget <= 0) return '…'

  // One past the budget: a space sitting exactly at `budget` is a legal break
  // point, and slicing to `budget` alone would hide it.
  const window = text.slice(0, budget + 1)
  const lastSpace = window.lastIndexOf(' ')
  const head =
    lastSpace >= Math.floor(budget * WORD_BOUNDARY_FLOOR)
      ? window.slice(0, lastSpace)
      : text.slice(0, budget)

  // A head that was *entirely* dangling punctuation — a rule of dashes, a row
  // of dots — leaves a bare ellipsis, which says strictly less than the
  // characters it replaced. Keep the hard cut in that case.
  const trimmed = head.replace(DANGLING_PUNCTUATION, '')
  return `${trimmed.length > 0 ? trimmed : text.slice(0, budget)}…`
}

/** Wrapper blocks the CLI injects around a prompt that are not part of it. */
const INJECTED_BLOCKS = [
  /<system-reminder>[\s\S]*?<\/system-reminder>/gi,
  /<local-command-caveat>[\s\S]*?<\/local-command-caveat>/gi,
  /<command-name>[\s\S]*?<\/command-args>/gi,
  /<command-(?:name|message|args|contents)>[\s\S]*?<\/command-(?:name|message|args|contents)>/gi,
]

/** C0 controls and DEL. Tabs and newlines land here too; the `\s+` collapse below tidies up. */
const CONTROL_CHARACTERS = /[\u0000-\u001f\u007f]/g

/**
 * A UUID at the very start of a prompt.
 *
 * Found by running this module over the real transcripts on this machine:
 * three sessions opened with `b9977b73-3823-… read full context of this
 * session id`, and titling on the raw prompt spent the entire 40-character
 * budget on the identifier and showed none of the request. The id is
 * addressing, never description, so it is dropped wherever it leads.
 */
const LEADING_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b[\s:,-]*/i

/**
 * Reduce a raw prompt to one line of plain text.
 *
 * Prompt text is arbitrary user input that reaches a tab label, so control
 * characters are dropped rather than trusted to render harmlessly, and all
 * whitespace collapses so a pasted multi-line brief becomes a single line.
 */
export function cleanTitleText(raw: string): string {
  let text = stripAnsi(raw)
  for (const block of INJECTED_BLOCKS) text = text.replace(block, ' ')
  return text
    .replace(CONTROL_CHARACTERS, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(LEADING_UUID, '')
    .trim()
}

/** Openers that mean the line is machinery rather than a task description. */
const NOT_A_TASK = [
  /^\//, // a slash command: /model, /clear, /catchup
  /^</, // an un-closed injected block, so the stripper above could not pair it
  /^\[[^\]]*\]$/, // a bracketed status line, e.g. [Request interrupted by user]
  /^caveat:/i,
]

/**
 * Titles the CLI writes before it has a real one.
 *
 * `New session` is a verified `custom-title` value — two live transcripts here
 * carry it — and it is strictly less informative than the folder name it would
 * displace, which is the one thing a derived title must never be.
 */
const PLACEHOLDER_TITLES = new Set(['new session', 'new conversation', 'untitled', 'untitled session'])

/** Shorter than this and a title says less than the folder name would. */
const MIN_TITLE_LENGTH = 3

/** Is this text worth putting on a tab? */
export function isUsableTitle(text: string): boolean {
  if (text.length < MIN_TITLE_LENGTH) return false
  if (PLACEHOLDER_TITLES.has(text.toLowerCase())) return false
  return !NOT_A_TASK.some((pattern) => pattern.test(text))
}

/**
 * Enough of a session id to tell two apart, and short enough to sit on a row.
 *
 * Both kinds of id in this app are UUIDs — the pty's, minted by `randomUUID` in
 * `pty-manager.ts`, and the conversation's, minted by Claude Code — and the
 * first block of one is already unique across every session or conversation a
 * person will ever have. The whole id stays in whatever `title` sits beside it,
 * because that is the string you would paste into `claude --resume`.
 *
 * Here rather than beside the dialog it was written for because it is now also
 * the last resort in {@link tabQualifiers}: when two rows carry the same name in
 * the same folder, this is the fact that separates them, and it is the same
 * eight characters the Inspector and the debug panel already print for that
 * session. `NewSessionDialog.tsx` re-exports it so its callers did not move.
 *
 * ## What must never be passed to it
 *
 * A **browser window's** id. `App.tsx` mints those as `browser:<epoch-ms>:<seq>`
 * — no hyphen — so this returns the whole string, and two blank windows both
 * called `New tab` sent the qualifier ladder down to exactly that: a tab reading
 * **browser:1787199912** beside a name cut short to make room for it. The guard
 * is in `tabQualifiers` (`mayPrintId`), where the decision to print an id is
 * made, rather than here, where all this could do is return a shorter piece of a
 * string that should not have been asked about. A browser window's human name is
 * its slot — `B1` — and it has no other.
 */
export function shortSessionId(id: string): string {
  return id.split('-')[0] ?? id
}

/**
 * The floor for {@link distinguishingIdLength}.
 *
 * Four, because that is where a hex string stops reading as a fragment of
 * something and starts reading as a label you can hold in your head long enough
 * to find it again two rows down — the same reason a short git hash is not one
 * character. Below it the saving is a few pixels and the cost is a qualifier
 * nobody can repeat back.
 */
export const MIN_ID_CHARS = 4

/**
 * The fewest characters of {@link shortSessionId} that still separate a run.
 *
 * ## Why anything shorter than the block
 *
 * Measured on the rendered rail, which is 264px: a session row that has fallen
 * through to its id gives 7px to the status dot, 50px to eight monospaced hex
 * characters and 60px to the two hover actions it keeps space for — and the
 * name, the only thing on the line a person actually reads, was left at its
 * 8ch floor and printed **Update Cl…**. Asad has objected to a name losing to
 * what sits beside it once already, in those words, about the account chip
 * shrinking a name to `S…`; this is the same failure with a different
 * neighbour, and the neighbour here is a number.
 *
 * So the id gives its pixels back. Four characters cost 25px instead of 50,
 * which is a quarter of the row's text column handed to the name.
 *
 * ## Why it is computed rather than simply cut to four
 *
 * The whole reason this qualifier is drawn is that nothing else on the row
 * separates it from the row above. A blind four-character cut would be a
 * qualifier that *can* collide — 1 in 65536 for any pair, which is small and is
 * not zero — and a colliding qualifier leaves the two rows exactly as
 * indistinguishable as it found them, while looking like it answered. So the
 * length is the shortest at which every id being printed differs from every
 * other, and it is one length for the whole run: these sit in a column at the
 * end of rows whose names are all cut to the same width, and a ragged column of
 * 4s and 6s reads as data rather than as an identifier.
 *
 * In practice this returns {@link MIN_ID_CHARS} every time — the lengthening is
 * a backstop, not a behaviour anybody will see. What it buys is that the claim
 * "these two rows are different" is checked instead of assumed.
 *
 * Still a prefix of the same block the Inspector and the debug panel print, so
 * matching a row against an inspector by eye is unchanged: it was always a
 * prefix comparison, and it now compares four characters instead of eight.
 */
export function distinguishingIdLength(ids: readonly string[]): number {
  // Nothing to separate. Answered with the floor rather than with zero so that
  // a caller who asks before it knows whether it has any rows gets a length it
  // could actually cut with, instead of one that silently prints nothing.
  if (ids.length === 0) return MIN_ID_CHARS
  const heads = ids.map(shortSessionId)
  const longest = heads.reduce((most, head) => Math.max(most, head.length), 0)
  for (let length = MIN_ID_CHARS; length < longest; length += 1) {
    if (new Set(heads.map((head) => head.slice(0, length))).size === heads.length) return length
  }
  return longest
}

/**
 * Last path segment — the fallback title, and what the sidebar calls a project.
 *
 * Both separators, because this app runs on Windows. Splitting on `/` alone
 * returns the *whole* path for `C:\Users\Imza\Projects\app`, so every surface
 * that asks this for a name — a project row, a tab's qualifier, the folder on a
 * held session's row, the "in <folder>" line in two pickers — printed a full
 * Windows path where a word belongs. Seen on `DESKTOP-DDGMNCV` on 2026-08-17, in
 * a rail 264px wide.
 *
 * A backslash is a legal character in a POSIX directory name, so this is not
 * free: a folder literally called `a\b` on a Mac now reads as `b`. That is the
 * right trade and it is the same one `basename` on Windows makes — the alternative
 * is a name that is wrong on every path on one of the two platforms this ships
 * to, rather than on a directory nobody has.
 */
export function folderName(path: string): string {
  const segments = path.split(/[\\/]/).filter(Boolean)
  return segments[segments.length - 1] ?? path
}

/**
 * Shapes a shell writes into its own window title, which are not names.
 *
 * A login shell sets the terminal's title from its prompt — `\e]0;%n@%m: %~\a`
 * in the stock zsh and bash profiles — so the string that arrives here as a
 * session's "title" is routinely `apple@Mac-mini: ~/Projects/terminaldeck`. That
 * is a machine and a path, and Asad reported exactly what it does to the rail:
 * *"in the side panel it is showing the full machine and path, everything in the
 * pill. It should not show. It should only show the name of the session."*
 *
 * Both halves are already stated by where the row sits. A session under a
 * project heading is under its folder's name, and a session under a machine
 * heading is under that machine's name — so printing them again on the line
 * costs the name its room and says nothing the eye did not already have. The
 * whole string still reaches the row's tooltip through `where`, which is where
 * every other identifying-but-redundant fact on that row goes.
 *
 * Three shapes, and no more, because a fourth guess starts eating real titles:
 *
 *  - `user@host`, with or without a `: path` after it. No spaces are allowed
 *    around the `@` or before the `:`, so an English sentence cannot match.
 *  - `host: ~/path` or `host: /path` — the same prompt without a user in it,
 *    and `host: C:\\path` for the Windows half. The tail must begin with `~`,
 *    `/` or a drive letter and a backslash, so `Fix: the login race` is safe.
 *  - A bare path, POSIX or Windows. `NOT_A_TASK` already refuses these when a
 *    title is being *derived*; this is the same judgement applied to a title
 *    that arrived from somewhere else — the far machine's own store, or a shell
 *    that titled itself before any agent ran.
 */
const MACHINE_AND_PATH = [
  /^[^\s@:]+@[^\s@:]+(?::.*)?$/,
  /^[\w.-]+:\s*(?:[~/]|[A-Za-z]:\\).*$/,
  /^~?\/[^\s]*$/,
  /^[A-Za-z]:\\/,
]

/**
 * Is this "title" just the machine and the folder the shell is sitting in?
 *
 * Asked at the point of *display* rather than when the title is stored, because
 * the string is still the honest answer to "what did this terminal call itself"
 * and the Inspector is entitled to print it. What is being decided here is only
 * whether it is worth a row's name — see {@link sessionLabel}, which falls
 * through to `Session N` when it is not.
 */
export function isMachineAndPath(title: string): boolean {
  const text = title.trim()
  if (text === '') return false
  return MACHINE_AND_PATH.some((pattern) => pattern.test(text))
}

/**
 * The label for a session whose folder name is no label at all.
 *
 * `folderName('')` is `''`, and a cwd that is empty or whitespace is not
 * hypothetical — it is what a session restored from a partly-written store
 * carries. The fallback exists to be the one source that cannot fail, so it
 * must not hand back a tab with nothing written on it.
 */
const UNNAMED_SESSION = 'Session'

/* -------------------------------------------------------------------------- */
/* Reading the evidence                                                        */
/* -------------------------------------------------------------------------- */

/** Which piece of evidence a title came from, weakest last. */
export type TitleSource = 'user' | 'custom' | 'ai' | 'prompt' | 'output' | 'folder'

export interface DerivedTitle {
  title: string
  source: TitleSource
}

/**
 * Ceiling on a transcript line we will hand to `JSON.parse`.
 *
 * Transcripts are mostly attachments, and a single one can run to megabytes —
 * a pasted file, a screenshot. None of them carries a title, and parsing them
 * to discover that would cost more than the whole feature is worth. A prompt
 * long enough to be skipped by this is also long enough that its first forty
 * characters were never going to be a good label.
 */
const MAX_SCANNED_LINE_BYTES = 256 * 1024

/**
 * Cheap substring gate before parsing.
 *
 * Roughly nine in ten transcript lines are assistant messages, attachments and
 * queue bookkeeping. Testing for the three keys that can hold a title first
 * keeps a large transcript from becoming a large heap of parsed objects.
 */
function mayCarryTitle(line: string): boolean {
  return (
    line.includes('"customTitle"') ||
    line.includes('"aiTitle"') ||
    line.includes('"type":"user"') ||
    line.includes('"type": "user"')
  )
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === 'string' && value.trim().length > 0 ? value : null
}

/** Clean a candidate and keep it only if it is worth showing. */
function usableOrNull(value: unknown): string | null {
  const raw = nonEmptyString(value)
  if (!raw) return null
  const cleaned = cleanTitleText(raw)
  return isUsableTitle(cleaned) ? cleaned : null
}

/**
 * Pull the text out of a `user` message.
 *
 * Content is either a bare string — how Claude Code records a typed prompt —
 * or an array of blocks, of which only `text` blocks are the user speaking.
 * `tool_result` blocks are the transcript of the agent's own work and are
 * skipped: they are the majority of user-role lines by count.
 */
function userMessageText(message: unknown): string | null {
  if (!isRecord(message)) return null
  const content = message.content
  if (typeof content === 'string') return content
  if (!Array.isArray(content)) return null

  const parts: string[] = []
  for (const block of content) {
    if (!isRecord(block) || block.type !== 'text') continue
    const text = nonEmptyString(block.text)
    if (text) parts.push(text)
  }
  return parts.length > 0 ? parts.join(' ') : null
}

/**
 * Best title available from a session's JSONL transcript lines.
 *
 * Lines may arrive in any quantity and any state of truncation — a transcript
 * is appended to live, so its last line is routinely half-written. Malformed
 * lines are skipped rather than thrown on.
 */
export function titleFromTranscript(lines: Iterable<string>): DerivedTitle | null {
  let custom: string | null = null
  let ai: string | null = null
  let firstPrompt: string | null = null

  for (const line of lines) {
    if (line.length === 0 || line.length > MAX_SCANNED_LINE_BYTES) continue
    if (!mayCarryTitle(line)) continue

    let raw: unknown
    try {
      raw = JSON.parse(line)
    } catch {
      continue
    }
    if (!isRecord(raw)) continue

    // Both title lines are rewritten as the conversation goes on, so keep
    // overwriting: the last one seen is the current one. Each source is
    // validated as it is captured rather than after the winner is picked —
    // otherwise a placeholder `custom-title` outranks a perfectly good
    // `ai-title` and then fails, losing both.
    if (raw.type === 'custom-title') {
      custom = usableOrNull(raw.customTitle) ?? custom
      continue
    }
    if (raw.type === 'ai-title') {
      ai = usableOrNull(raw.aiTitle) ?? ai
      continue
    }
    if (raw.type !== 'user' || firstPrompt !== null) continue

    // `isMeta` marks the CLI talking to itself (the local-command caveat), and
    // `isSidechain` marks a sub-agent's prompt — neither is the user's task.
    if (raw.isMeta === true || raw.isSidechain === true) continue

    const text = userMessageText(raw.message)
    if (!text) continue
    const cleaned = cleanTitleText(text)
    if (isUsableTitle(cleaned)) firstPrompt = cleaned
  }

  if (custom) return { title: custom, source: 'custom' }
  if (ai) return { title: ai, source: 'ai' }
  if (firstPrompt) return { title: firstPrompt, source: 'prompt' }
  return null
}

/**
 * The title Claude Code draws in its own chrome: a rule with the conversation
 * name inset in it, `───── some title ──`. Box-drawing horizontals are the
 * marker, and the title is whatever sits between two runs of them.
 */
const RULE_TITLE = /─{3,}\s+([^─\s][^─]*?)\s+─{2,}/

/**
 * A prompt echoed back into the scrollback after the user submits it. Claude
 * Code prints `> what the user typed`; a bare `>` is the empty input box and
 * carries nothing.
 */
const ECHOED_PROMPT = /^\s*>\s+(\S.*)$/

/** An echoed prompt this short is more likely a shell heredoc than a task. */
const MIN_ECHO_LENGTH = 8

/**
 * How much of the scrollback either scan reads.
 *
 * `output` is the session's whole retained buffer, which for a long-running
 * agent is megabytes. Scanning all of it means a full stripped copy plus an
 * array of every line, allocated on each call — and `deriveSessionTitle` is
 * documented as cheap enough to re-run whenever new evidence lands, which is
 * per chunk. 64KB is far more than either pattern needs and makes the cost of
 * a call independent of how long the session has been open.
 */
const MAX_SCANNED_OUTPUT = 64 * 1024

const LINE_BREAK = /\r\n|\r|\n/

/**
 * Lines from one end of the output, without the line the slice cut in half.
 *
 * Slicing at a character offset lands mid-line, and a half-line can still
 * match `ECHOED_PROMPT` and yield a truncated title. A drawn rule needs both
 * of its horizontal runs so it cannot half-match, but dropping the fragment
 * costs nothing and keeps both scans honest.
 */
function scanLines(output: string, end: 'head' | 'tail'): string[] {
  if (output.length <= MAX_SCANNED_OUTPUT) return stripAnsi(output).split(LINE_BREAK)

  if (end === 'tail') {
    const lines = stripAnsi(output.slice(-MAX_SCANNED_OUTPUT)).split(LINE_BREAK)
    lines.shift()
    return lines
  }
  const lines = stripAnsi(output.slice(0, MAX_SCANNED_OUTPUT)).split(LINE_BREAK)
  lines.pop()
  return lines
}

/**
 * Best title available from raw terminal output.
 *
 * Weaker evidence than the transcript — this is pattern-matching on a TUI that
 * is free to redraw itself differently next release — so it sits below the
 * transcript in `deriveSessionTitle`. It exists because it is the only source
 * that works for providers that write no transcript at all.
 *
 * The two patterns are read from opposite ends, for the same reason the
 * transcript takes the last `custom-title` but the first user message: the
 * rule is repainted with the current name on every frame, so the newest one is
 * the live title, while a prompt is echoed once and the oldest is the session's
 * opening request.
 */
export function titleFromOutput(output: string): DerivedTitle | null {
  // A drawn rule is a deliberate label, so it beats a guess at the prompt.
  const tail = scanLines(output, 'tail')
  for (let i = tail.length - 1; i >= 0; i--) {
    const match = RULE_TITLE.exec(tail[i])
    if (!match) continue
    const title = cleanTitleText(match[1])
    if (isUsableTitle(title)) return { title, source: 'output' }
  }

  for (const line of scanLines(output, 'head')) {
    const match = ECHOED_PROMPT.exec(line)
    if (!match) continue
    const title = cleanTitleText(match[1])
    if (title.length >= MIN_ECHO_LENGTH && isUsableTitle(title)) return { title, source: 'output' }
  }

  return null
}

/* -------------------------------------------------------------------------- */
/* The decision                                                                */
/* -------------------------------------------------------------------------- */

export interface TitleInput {
  /** Absolute project path. Its last segment is the guaranteed fallback. */
  cwd: string
  /** A name the user typed themselves. Nothing outranks it. */
  userTitle?: string | null
  /** JSONL lines from this session's transcript, in file order. */
  transcriptLines?: Iterable<string> | null
  /** Raw PTY output, escape sequences and all. */
  output?: string | null
  /** Character budget; the caller may shorten it for a narrow tab. */
  maxLength?: number
}

/**
 * Pick the best title for a session and cut it to fit.
 *
 * Precedence is by how much each source knows about intent: a name the user
 * typed, then a name the CLI recorded, then the first thing the user asked
 * for, then whatever the terminal drew, then the folder. Re-run it whenever
 * new evidence lands — it is cheap and has no memory, so a session that gains
 * a transcript mid-flight simply gets a better answer next call.
 */
/**
 * A name the user typed for a session, reduced to something a tab can carry —
 * or null when they did not really type one.
 *
 * The counterpart of everything above it, and deliberately a *different* set of
 * rules. Everything else in this module is guessing, so it is allowed to be
 * fussy: a two-character line, a slash command, the word "Untitled" are all
 * rejected by {@link isUsableTitle} because a bad guess is worse than falling
 * back to the folder name. None of that applies to a name somebody sat and
 * typed. If they want to call a session `ab`, or `/tmp`, that is what it is
 * called; this app does not get to overrule it and quietly show something else.
 *
 * So only two things happen here, and both are about what a tab can physically
 * do rather than about whether the name is any good:
 *
 *   - {@link cleanTitleText} runs, because a name arrives from a text field and
 *     a pasted multi-line brief, or a stray control character, would otherwise
 *     reach a `<span>` in the sidebar and the toolbar's `<h1>`. Whitespace
 *     collapses to single spaces and the ends are trimmed.
 *   - it is cut to {@link MAX_TITLE_LENGTH}, the same budget every other title
 *     in this module is cut to, because the tab that has to show it is the same
 *     width whoever wrote the words.
 *
 * Null means "nothing was typed" — an empty field, or one holding only spaces.
 * That is a cancel, not a request to be called `''`: a session with a blank
 * name is a row in the sidebar with nothing on it and no way to click back into
 * the field to fix it.
 *
 * {@link deriveSessionTitle} calls this for its own `userTitle` branch rather
 * than repeating the two steps, so there is one answer to "what does a typed
 * name become" no matter which door it came through.
 */
export function userSessionTitle(typed: string, max = MAX_TITLE_LENGTH): string | null {
  const cleaned = cleanTitleText(typed)
  if (cleaned.length === 0) return null
  return truncateOnWordBoundary(cleaned, max)
}

export function deriveSessionTitle(input: TitleInput): DerivedTitle {
  const max = input.maxLength ?? MAX_TITLE_LENGTH

  const explicit = input.userTitle == null ? null : userSessionTitle(input.userTitle, max)
  if (explicit !== null) return { title: explicit, source: 'user' }

  const found =
    (input.transcriptLines ? titleFromTranscript(input.transcriptLines) : null) ??
    (input.output ? titleFromOutput(input.output) : null)

  if (found && isUsableTitle(found.title)) {
    return { title: truncateOnWordBoundary(found.title, max), source: found.source }
  }

  const folder = cleanTitleText(folderName(input.cwd))
  return {
    title: truncateOnWordBoundary(folder.length > 0 ? folder : UNNAMED_SESSION, max),
    source: 'folder',
  }
}
