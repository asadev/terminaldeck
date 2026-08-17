/**
 * Is that session getting anywhere, or is it just spending money?
 *
 * `COPILOT-CAPABILITIES.md` §2.3 asks for the cheapest safety feature in the
 * whole design and the one most often skipped: noticing that an agent has been
 * retrying the same broken approach for forty minutes. Nothing on screen says
 * so. A looping session is `working` — the dot is green, output is arriving,
 * tokens are being spent — and the only way to find out today is to open the tab
 * and read it, which is exactly the thing a person running eight sessions has
 * stopped doing.
 *
 * ## What this looks at, and what it deliberately does not
 *
 * It reads the *shape* of a session's recent tool use and nothing else. Not the
 * arguments, not the results, not the prose. That is a deliberate stopping
 * point rather than a first draft:
 *
 *  - The shape is enough for the failures that actually happen. An agent stuck
 *    on a broken build runs the same command over and over and gets the same
 *    error; an agent lost in a repository reads and greps without ever writing;
 *    an agent that overflowed its context compacts and immediately re-does the
 *    thing that overflowed it. All three are visible in a list of tool names,
 *    their outcomes and their times.
 *  - The arguments are where the certainty is — "the same tool with the same
 *    input failing the same way" is a loop and not a coincidence — and reading
 *    them means parsing every `tool_use` block's `input`, which is unbounded:
 *    one `Write` call can carry a megabyte. `parseInsightLine` deliberately
 *    keeps only the id and the name for that reason, and widening it would put
 *    a per-line allocation on the inspector's read path, which is shared. That
 *    is the sharper detector `COPILOT-CAPABILITIES.md` calls "worth it later;
 *    not worth blocking on", and this is the version that ships first.
 *
 * So the verdict below is deliberately conservative and says which signal fired.
 * A person reading "Bash 14 times, 11 of them failing, nothing written" can
 * decide in a second; a person reading "looks stuck" has to go and check, which
 * is the cost this exists to remove.
 *
 * ## The numbers, and where they come from
 *
 * The thresholds are OpenClaw's tuned values, taken as facts rather than
 * invented here — warning at 10 repeats, critical at 20, over a rolling window
 * of 30 tool calls. They were arrived at against real agent traffic, which is
 * more than a number picked in this file would have behind it. What is *not*
 * copied is the third one: OpenClaw hard-stops the agent at 30. This never
 * stops anything. `COPILOT-CAPABILITIES.md` is explicit that reporting is the
 * routine's job and stopping is Asad's, and an automatic kill on a heuristic
 * built from tool names alone would eventually kill a session that was doing
 * something repetitive on purpose.
 *
 * ## The honest limit, stated in the result rather than in a comment
 *
 * This works for a session that writes a JSONL transcript, which today means
 * the Claude CLI. A plain shell writes nothing, and for a shell there is no
 * trail to read — so the verdict is `unknown` with a reason, never "no problems
 * found". Reporting silence as health is the one failure this module must not
 * have: it would make an unmonitored session look monitored.
 */

import type { ToolTrail } from './surface'

/* ------------------------------------------------------------------ tuning -- */

/**
 * How many recent tool calls are looked at.
 *
 * A rolling window rather than the whole session, because the question is
 * "is it stuck *now*". A session that thrashed for twenty minutes an hour ago
 * and has been fine since is not stuck, and a whole-session count would keep
 * reporting it as stuck for as long as it ran.
 */
export const WINDOW_CALLS = 30

/** Repeats of one tool inside the window before it is worth mentioning. */
export const REPEAT_WARNING = 10
/** Repeats before it is worth interrupting somebody about. */
export const REPEAT_CRITICAL = 20

/**
 * Failures of one tool inside the window before the repetition is a loop
 * rather than a rhythm.
 *
 * Lower than {@link REPEAT_WARNING} on purpose. Calling `Read` twelve times is
 * ordinary work; failing the same call five times is not, whatever the tool is,
 * because a working agent that fails five times in a row has run out of ideas
 * and is now guessing.
 */
export const FAILURE_WARNING = 5

/**
 * Tool names that put something on disk.
 *
 * The list is Claude Code's, and it is a list of *names* rather than a
 * capability check, so it is wrong in one direction and right in the other: a
 * `Bash` call running `sed -i` writes a file and is not counted, so this can
 * report "nothing written" when something was. That is the safe direction for a
 * signal that only ever *adds* suspicion — the verdict needs a repetition
 * signal as well before it says anything at all, so a false "no writes" alone
 * changes nothing.
 *
 * `Bash` is deliberately absent even though it is the tool that most often
 * writes, because counting it as progress would make every stuck build loop —
 * the single most common real failure — look like productive work.
 */
export const WRITING_TOOLS: readonly string[] = [
  'Write',
  'Edit',
  'MultiEdit',
  'NotebookEdit',
  'StrReplace',
]

/**
 * How close to a compaction a repeat has to be to count as compaction churn.
 *
 * Three tool calls. The signature being looked for is the specific one the
 * field reports: the context fills, the CLI compacts, and the agent's very next
 * move is the thing that filled it — reading the same enormous file, re-running
 * the same enormous command. Anything further out than a couple of calls is
 * just the session carrying on.
 */
export const COMPACTION_ECHO_CALLS = 3

/* ------------------------------------------------------------------ result -- */

export type ProgressVerdict =
  /** Nothing in the window looks like repetition. */
  | 'ok'
  /** One signal fired. Worth a sentence, not worth an interruption. */
  | 'suspect'
  /** Repetition and no progress together. This is the one to report. */
  | 'looping'
  /** There is nothing to read. Never confused with `ok`. */
  | 'unknown'

export type ProgressSignal =
  /** One tool dominates the window. */
  | 'repeated-tool'
  /** One tool keeps failing. */
  | 'repeated-failure'
  /** Not one file-writing call in the whole window. */
  | 'no-writes'
  /** Compacted, and then immediately did the thing again. */
  | 'compaction-echo'

export interface ProgressFinding {
  signal: ProgressSignal
  /** The tool this is about, when it is about one. */
  tool: string | null
  /** One sentence, already written for a person. */
  detail: string
  /**
   * The number the signal fired on — calls for `repeated-tool`, failures for
   * `repeated-failure`, and null for the two signals that are not a count.
   *
   * Present because {@link detail} is English and two other places in this app
   * need the magnitude rather than the sentence: `alerts.ts` decides whether a
   * loop is a warning or a critical by comparing it against
   * {@link REPEAT_CRITICAL}, and `importance.ts` ranks one looping session
   * against another. Both were briefly written by reading the digits back out
   * of `detail` with a regular expression, which works exactly until somebody
   * improves the wording — and improving the wording is the one thing a
   * human-readable string is *for*. The number travels beside the sentence
   * instead.
   */
  count: number | null
}

export interface ProgressReport {
  verdict: ProgressVerdict
  /** Why, in the order they should be said. Empty for `ok` and `unknown`. */
  findings: ProgressFinding[]
  /** Null when the verdict is not `unknown`. */
  unknownReason: string | null
  /** Tool calls actually examined — at most {@link WINDOW_CALLS}. */
  examined: number
  /** How long the examined window covers, in ms, or null when it cannot be told. */
  spanMs: number | null
  /** True when the trail itself was a tail rather than the whole transcript. */
  partial: boolean
  /** File-writing calls inside the window. */
  writes: number
  /** Failed calls inside the window. */
  failures: number
  /**
   * Compactions inside the part of the transcript that was read.
   *
   * Not a signal on its own — a compaction is the runtime doing its job, and
   * {@link ProgressSignal.compaction-echo} is the only shape of it worth
   * reporting as a problem. It is carried because `importance.ts` needs the
   * *fact* that the session forgot something and carried on, which is worth
   * mentioning in a morning report and worth a stop on a tour, and because the
   * alternative was every caller re-reading the trail to count them.
   *
   * Counted over the read window rather than the whole session, so it moves
   * with {@link ProgressReport.partial}: on a tail this is "compactions
   * recently", never "compactions ever". `SpendReport.compactions` is the
   * whole-session number and the two are deliberately different questions.
   */
  compactions: number
}

/* ---------------------------------------------------------------- the check -- */

/**
 * Look at the tail of a session's tool use and say whether it is getting
 * anywhere.
 *
 * Pure, and takes the trail rather than a path, so the whole of the judgement
 * is exercisable without a transcript, a session or a filesystem — which is
 * what lets the thresholds above be tested at their exact boundaries instead of
 * approximately, against a fixture somebody assembled by hand.
 */
export function assessProgress(trail: ToolTrail | null): ProgressReport {
  if (trail === null) {
    return unknown('This session keeps no transcript, so there is nothing to read its behaviour from.')
  }

  const window = trail.events.slice(-WINDOW_CALLS)
  if (window.length === 0) {
    return unknown(
      trail.partial
        ? 'No tool calls in the part of the transcript that was read.'
        : 'This session has not called a tool yet.',
    )
  }

  const counts = new Map<string, { calls: number; failures: number }>()
  let writes = 0
  let failures = 0
  for (const event of window) {
    const entry = counts.get(event.name) ?? { calls: 0, failures: 0 }
    entry.calls += 1
    if (event.failed === true) {
      entry.failures += 1
      failures += 1
    }
    counts.set(event.name, entry)
    if (WRITING_TOOLS.includes(event.name)) writes += 1
  }

  const findings: ProgressFinding[] = []

  /*
   * Ranked before it is reported, and by failures first.
   *
   * Two tools can both cross the repeat threshold in one window, and the
   * sentence a person needs is about the one that is *failing* — "Bash 12
   * times, 9 of them failing" is a diagnosis and "Read 14 times" beside it is
   * noise. Sorting here rather than reporting in map order also makes the
   * output stable, which matters because this text ends up in an action log
   * that people diff against itself.
   */
  const ranked = [...counts.entries()].sort(
    (a, b) => b[1].failures - a[1].failures || b[1].calls - a[1].calls || a[0].localeCompare(b[0]),
  )

  for (const [name, stat] of ranked) {
    if (stat.failures >= FAILURE_WARNING) {
      findings.push({
        signal: 'repeated-failure',
        tool: name,
        detail: `${name} failed ${stat.failures} times in the last ${window.length} tool calls.`,
        count: stat.failures,
      })
    }
    if (stat.calls >= REPEAT_WARNING) {
      findings.push({
        signal: 'repeated-tool',
        tool: name,
        detail:
          stat.calls >= REPEAT_CRITICAL
            ? `${name} has been called ${stat.calls} times in the last ${window.length} tool calls — it is nearly all this session is doing.`
            : `${name} accounts for ${stat.calls} of the last ${window.length} tool calls.`,
        count: stat.calls,
      })
    }
  }

  const echo = compactionEcho(trail)
  if (echo !== null) findings.push(echo)

  /*
   * "Nothing was written" is only worth saying when something else already
   * looked wrong.
   *
   * On its own it is the normal state of every session that is reading,
   * planning, searching or answering a question, which is most of them most of
   * the time. Reported unconditionally it would fire on almost everything and
   * the signal would be worth nothing within a day — which is how a supervision
   * surface dies. It earns its place as the second half of a pair: repetition
   * *and* no output is the shape of a loop, and repetition with files landing
   * is the shape of work.
   */
  const repeating = findings.length > 0
  if (repeating && writes === 0) {
    findings.push({
      signal: 'no-writes',
      tool: null,
      detail: `Nothing has been written to a file in the last ${window.length} tool calls.`,
      count: null,
    })
  }

  const verdict: ProgressVerdict = !repeating ? 'ok' : writes === 0 ? 'looping' : 'suspect'

  return {
    verdict,
    findings,
    unknownReason: null,
    examined: window.length,
    spanMs: spanOf(window),
    partial: trail.partial,
    writes,
    failures,
    compactions: trail.compactions.length,
  }
}

/**
 * The specific shape worth naming: compacted, then straight back into it.
 *
 * A compaction is not itself a problem — it is the runtime doing its job. What
 * is a problem is a session whose first move afterwards is the move that filled
 * the window, because that is a session that will fill it again, compact again,
 * and keep paying the compaction for as long as somebody lets it. The check is
 * deliberately narrow: the tool that dominated the calls *before* the
 * compaction has to be the tool called immediately *after* it.
 */
function compactionEcho(trail: ToolTrail): ProgressFinding | null {
  const compaction = trail.compactions.at(-1)
  if (compaction === undefined) return null

  const before = trail.events.filter((event) => event.at > 0 && event.at <= compaction.at)
  const after = trail.events.filter((event) => event.at > compaction.at)
  if (before.length === 0 || after.length === 0) return null

  const dominant = mostCommon(before.slice(-WINDOW_CALLS).map((event) => event.name))
  if (dominant === null) return null

  const echoed = after.slice(0, COMPACTION_ECHO_CALLS).some((event) => event.name === dominant)
  if (!echoed) return null

  return {
    signal: 'compaction-echo',
    tool: dominant,
    detail: `The session compacted and went straight back to ${dominant}, which is what filled the context.`,
    // Not a count. The signal is a *sequence* — compaction, then the same tool
    // within three calls — and a number here would have to be one of the two
    // things it is not: how many compactions there were, or how many calls
    // followed. Null says "this signal has no magnitude" rather than inventing
    // one, which is the same call `ProgressReport.spanMs` makes about a window
    // whose timestamps are unusable.
    count: null,
  }
}

function mostCommon(names: readonly string[]): string | null {
  const counts = new Map<string, number>()
  for (const name of names) counts.set(name, (counts.get(name) ?? 0) + 1)
  let best: string | null = null
  let bestCount = 0
  for (const [name, count] of counts) {
    // Strictly greater, so a tie keeps the first-seen name and the answer does
    // not depend on Map iteration order changing under a future edit.
    if (count > bestCount) {
      best = name
      bestCount = count
    }
  }
  return best
}

/**
 * How long the examined window covers.
 *
 * Null rather than zero when the times are unusable. `parseInsightLine` writes
 * `at: 0` for a line with no timestamp, and a span computed from a zero would
 * read as "this session has been looping since 1970", which is the kind of
 * number a model will put in a sentence.
 */
function spanOf(window: readonly { at: number }[]): number | null {
  const times = window.map((event) => event.at).filter((at) => at > 0)
  if (times.length < 2) return null
  return Math.max(...times) - Math.min(...times)
}

function unknown(reason: string): ProgressReport {
  return {
    verdict: 'unknown',
    findings: [],
    unknownReason: reason,
    examined: 0,
    spanMs: null,
    partial: false,
    writes: 0,
    failures: 0,
    compactions: 0,
  }
}

/**
 * The one-line form, for an action log row and for a routine's headline.
 *
 * Written here rather than at each call site because there are three of them —
 * the tool result, the report rollup and the routine's log line — and three
 * hand-written summaries of one verdict is how two of them end up disagreeing
 * about what `suspect` means.
 */
export function progressSentence(report: ProgressReport): string {
  switch (report.verdict) {
    case 'unknown':
      return report.unknownReason ?? 'Nothing to read.'
    case 'ok':
      return `Making progress — ${report.writes} file write${report.writes === 1 ? '' : 's'} in the last ${report.examined} tool calls.`
    case 'suspect':
      return `Repeating itself, but still writing files. ${report.findings[0]?.detail ?? ''}`.trim()
    case 'looping':
      return `Looks stuck. ${report.findings.map((finding) => finding.detail).join(' ')}`.trim()
  }
}
