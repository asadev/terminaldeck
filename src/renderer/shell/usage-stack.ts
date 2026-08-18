/**
 * Which windows the chrome's usage element draws, and in what order.
 *
 * ## What this is answering
 *
 * Asad, watching the top bar on 2026-08-17:
 *
 *   > *"Maybe two bars, up and down. Upper one for five hours and down one for
 *   > weekly. For weekly it will show the 55% and no need to say week here and
 *   > no even need to show the dates. For the five-hour window it will also show
 *   > the percentage and it will show the time of reset."*
 *
 * Until now the bar drew **one** window — `primaryReading`, the shortest one —
 * and put a second beside it only when that second was in trouble. That rule was
 * written to stop a quiet five-hour bar hiding a weekly limit at 97%, and it did
 * stop it, but it produced the screen he was actually looking at when he asked
 * for this: with no five-hour figure reported, the *weekly* reading became the
 * primary one, and the bar read `Week 81% ▬▬ resets Aug 21 at 2pm`. So the one
 * element on the bar said a different thing about a different period from one
 * hour to the next, and the reader had to notice the word `Week` to know which.
 *
 * Two fixed lines fix that at the root. The top line is always the five-hour
 * window and the bottom line is always the weekly one, whether or not either has
 * anything to report, so the shape of the readout does not change with its
 * contents and neither line can ever be mistaken for the other.
 *
 * ## Why the five-hour line keeps its name and the weekly line loses one
 *
 * Because he asked for exactly that, and the asymmetry is not an oversight. The
 * five-hour line is the reading he singled out for praise in the same recording
 * — *"`5 / 18% reset` … This is very nice. Very good. I don't want to make any
 * change on this pill"* — so it keeps the three things it had: the window's
 * name, the percentage and the renewal time. The weekly line is the one he
 * described fresh, and he described it without a name and without a date:
 * *"it will show the 55% and no need to say week here and no even need to show
 * the dates."*
 *
 * What names the weekly line instead is its position — directly under the line
 * that says `5h`, sharing its columns — plus the hover label and the panel,
 * which print every window's own unabridged label. This costs a reader nothing
 * and saves the bar the widest string in the whole feature: `resets Aug 21 at
 * 2pm (Asia/Dubai)` is longer than the rest of the element put together, and it
 * is a date nobody plans around.
 *
 * ## The single line, which is not a fallback
 *
 * A session whose agent reports neither of those two windows gets one line
 * carrying whatever it *does* report. That is Codex, which records a 30-day
 * limit and no others: two empty five-hour and weekly slots over a session that
 * can never fill them would be two dead readings, which is the complaint this
 * whole review turns on — *"they should not see something they cannot do
 * something about it."*
 *
 * ## And the window that is in trouble and on neither line
 *
 * Kept, because the reason it exists has not gone away. Claude Code's `/usage`
 * panel prints `Current week (all models)` **and** `Current week (Opus)`, and
 * the second is the one that actually stops people working. Only the first can
 * have the weekly line, so the second would drop off the bar entirely — and a
 * limit at 97% that is not on screen is precisely the confidently-wrong reading
 * this feature was nearly cancelled for twice. So any window that is not drawn
 * and is not quiet comes back as {@link extraAlert}, for the one spare slot on
 * the weekly line.
 */

import {
  primaryReading,
  shortWindowName,
  usageReadout,
  type UsageReadout,
  type UsageReport,
  type UsageWindowReading,
} from './usage-bar-model'

/** Which of the fixed slots a line occupies. */
export type UsageSlot = 'five-hour' | 'weekly' | 'single'

export interface UsageLine {
  slot: UsageSlot
  /**
   * The short name at the head of the line, or `''` where he asked for none.
   *
   * Empty is not "unknown" — it is a decision, and the column stays in the grid
   * so the percentages of the two lines sit on the same vertical rule. A line
   * that dropped the column instead would shift its own figure left and undo
   * the alignment that makes the pair read as one readout.
   */
  name: string
  /** Null when this window has reported nothing at all. */
  readout: UsageReadout | null
  /** Whether the renewal time belongs on this line. Five-hour only, and the
   *  single line, which is standing in for whichever window the agent has. */
  showReset: boolean
}

function findWindow(
  report: UsageReport | null,
  kind: UsageWindowReading['window'],
): UsageWindowReading | null {
  return report?.readings.find((reading) => reading.window === kind) ?? null
}

/**
 * The lines to draw, top to bottom.
 *
 * Always one or two, never none: a session with nothing reported still gets its
 * single line, which is what carries the "not reported yet" state and the
 * sentence explaining it. Drawing nothing would make an unreported reading and
 * an uninstalled feature look identical, which is the distinction the whole
 * module below this one is arranged around.
 */
export function usageLines(report: UsageReport | null, now: number): UsageLine[] {
  const five = findWindow(report, 'five-hour')
  const week = findWindow(report, 'weekly')

  if (five !== null || week !== null) {
    return [
      {
        slot: 'five-hour',
        // Not `shortWindowName(five)` — the name has to be there when the
        // reading is not, because the empty top line is exactly the state the
        // reader needs to be able to identify. `5h` is what that function
        // answers for this window anyway; stating it is what makes it survive
        // the absence.
        name: '5h',
        readout: five === null ? null : usageReadout(five, now),
        showReset: true,
      },
      {
        slot: 'weekly',
        name: '',
        readout: week === null ? null : usageReadout(week, now),
        showReset: false,
      },
    ]
  }

  const only = primaryReading(report)
  return [
    {
      slot: 'single',
      name: only === null ? 'Usage' : shortWindowName(only),
      readout: only === null ? null : usageReadout(only, now),
      showReset: true,
    },
  ]
}

/**
 * A window that is not on a line of its own and is not quiet.
 *
 * Only ever the worst one, and only ever at warning level or above. When
 * everything undrawn is comfortable this returns null and the element stays the
 * two short lines it is meant to be.
 *
 * `percent !== null` is doing real work here rather than guarding a type: a
 * reading with no figure has no level to be alarmed about, and an expired one
 * has already lost its number by the time `usageReadout` is done with it. So
 * neither can raise an alert, which is right — an alert is a claim that
 * something measured is close to a limit that is still running.
 */
export function extraAlert(
  report: UsageReport | null,
  lines: UsageLine[],
  now: number,
): UsageReadout | null {
  if (!report) return null
  const drawn = new Set(
    lines.map((line) => line.readout?.reading.id).filter((id): id is string => id !== undefined),
  )
  const loud = report.readings
    .filter((reading) => !drawn.has(reading.id))
    .map((reading) => usageReadout(reading, now))
    .filter((readout) => readout.percent !== null && readout.level !== 'ok')
  if (loud.length === 0) return null
  return loud.reduce((worst, readout) => ((readout.percent ?? 0) > (worst.percent ?? 0) ? readout : worst))
}

/**
 * Whether the leading window has a reading current enough to leave alone.
 *
 * This is the question {@link useAutoUsage} asks before it goes and fetches one,
 * and it is deliberately strict: `live` only. An `aged` reading is real and is
 * still drawn — dropping it twenty-five minutes after a `/usage` run would teach
 * a reader the feature is broken — but it is exactly the state a fetch would
 * improve, so it is not a reason to skip one.
 *
 * The leading window is the first line, which is the five-hour one wherever
 * there is a five-hour one. That is the window that moves during an afternoon
 * and the one worth spending a fetch on; the weekly figure arrives in the same
 * `/usage` panel for free.
 */
export function leadIsLive(lines: UsageLine[]): boolean {
  return lines[0]?.readout?.state === 'live'
}
