/**
 * The tail of a session's tool use, read once and shared by everything that
 * asks "is that agent getting anywhere".
 *
 * This function was written inside `deck-control/live-surface.ts`, private to
 * the copilot's surface, and it stayed there for exactly as long as the copilot
 * was the only thing that wanted it. `alerts.ts` now wants it too — a looping
 * session has to be *noticed*, not only answerable when somebody thinks to ask
 * — and `alerts.ts` cannot import the surface, because the surface imports
 * `alerts.ts`. The choice was a second reader or a shared one, and a second
 * reader of this file is the thing this repository has been bitten by before:
 * `parseInsightLine` carries three documented surprises about the JSONL (one
 * API request emits many lines, a compaction is a `system` line with a subtype,
 * an assistant line can be a tool call and a usage record at once) and a
 * parallel parser drifts away from it on the fourth surprise, silently, in
 * whichever of the two nobody is looking at.
 *
 * So it lives here, above both of them, and the alert panel and the copilot are
 * reading the same bytes to reach the same verdict. That matters more than
 * tidiness: `COPILOT-DESIGN.md`'s whole argument for the copilot being a
 * session rather than a bespoke agent is that the person can see the machinery,
 * and a copilot that says "this looks stuck" while the alerts panel says
 * nothing is a copilot describing a machine the person is not looking at.
 *
 * ## Why a tail and not the file
 *
 * `readInsightLines` in `session-insights.ts` reads the *whole* transcript —
 * measured at ~680 ms and ~160 MB of peak RSS on the 154 MB transcript on this
 * machine — which is the right trade for the inspector, where a person has
 * asked about one session and is watching a spinner. It is the wrong trade for
 * both callers here: the copilot asks this across every session at once, and
 * the alerts scanner asks it on a timer, unprompted, on the main process.
 *
 * The cost of starting mid-file is one torn line at the front, which
 * `JSON.parse` refuses and the loop skips, and a `tool_result` whose `tool_use`
 * fell outside the window — which is why {@link ToolEvent.failed} has a third
 * value rather than defaulting to false.
 */

import { open, stat } from 'node:fs/promises'
import { StringDecoder } from 'node:string_decoder'
import { parseInsightLine } from './session-insights'
import type { ToolEvent, ToolTrail } from './deck-control/surface'

/** Bytes read per chunk. Matches `readInsightLines`, for the same reason. */
const CHUNK_BYTES = 1024 * 1024

/**
 * How much of the end of a transcript is parsed for behaviour, by default.
 *
 * Two megabytes is roughly the last few hundred turns of a busy session, which
 * comfortably contains the thirty tool calls `deck-control/progress.ts` looks
 * at, and it is a seventy-seventh of the largest transcript measured here.
 *
 * Declared beside the reader rather than beside either caller. It is a property
 * of *this* read — how far back the file is worth walking to answer a question
 * about the last few minutes — and two callers each choosing their own window
 * is two answers to "is it looping" that can disagree about a session neither
 * of them is wrong about.
 */
export const TRAIL_WINDOW_BYTES = 2 * 1024 * 1024

/**
 * Parse the last `windowBytes` of a transcript into tool calls and results.
 *
 * Never throws for a missing, unreadable or non-file path: every caller is
 * scanning a set of sessions and one bad path must not cost the others their
 * answer. An empty trail is distinguishable from a healthy one downstream —
 * `assessProgress` returns `unknown` with a reason for it, not `ok`.
 */
export async function readToolTrail(path: string, windowBytes: number): Promise<ToolTrail> {
  let size = 0
  try {
    const info = await stat(path)
    if (!info.isFile()) return emptyTrail()
    size = info.size
  } catch {
    return emptyTrail()
  }

  const fromByte = Math.max(0, size - Math.max(0, windowBytes))
  let handle
  try {
    handle = await open(path, 'r')
  } catch {
    // Listed a moment ago, gone or unreadable now. The same forgiveness the
    // `stat` above gets, for the same reason: a transcript deleted between the
    // directory listing and this read is ordinary, and it must not reject the
    // scan that was reading nine others.
    return emptyTrail()
  }

  const decoder = new StringDecoder('utf8')
  const uses: Array<{ id: string; name: string; at: number }> = []
  const failures = new Map<string, boolean>()
  const compactions: ToolTrail['compactions'] = []
  let offset = fromByte
  let partialLine = ''

  try {
    while (offset < size) {
      const length = Math.min(CHUNK_BYTES, size - offset)
      const buffer = Buffer.allocUnsafe(length)
      const { bytesRead } = await handle.read(buffer, 0, length, offset)
      // Truncated between the stat and the read; stop rather than spin.
      if (bytesRead === 0) break
      offset += bytesRead

      const text = partialLine + decoder.write(buffer.subarray(0, bytesRead))
      const chunk = text.split('\n')
      partialLine = chunk.pop() ?? ''
      for (const line of chunk) absorb(line, uses, failures, compactions)
    }
  } finally {
    await handle.close()
  }
  // A live session's last line is usually complete.
  if (partialLine.length > 0) absorb(partialLine, uses, failures, compactions)

  const events: ToolEvent[] = uses.map((use) => ({
    at: use.at,
    name: use.name,
    failed: failures.has(use.id) ? (failures.get(use.id) as boolean) : null,
  }))

  return { events, compactions, fileBytes: size, fromByte, partial: fromByte > 0 }
}

function absorb(
  line: string,
  uses: Array<{ id: string; name: string; at: number }>,
  failures: Map<string, boolean>,
  compactions: ToolTrail['compactions'],
): void {
  const parsed = parseInsightLine(line)
  if (parsed === null) return
  for (const use of parsed.toolUses) uses.push({ id: use.id, name: use.name, at: parsed.at })
  for (const result of parsed.toolResults) failures.set(result.id, result.failed)
  if (parsed.compaction !== null) {
    compactions.push({
      at: parsed.at,
      preTokens: parsed.compaction.preTokens,
      postTokens: parsed.compaction.postTokens,
      trigger: parsed.compaction.trigger,
    })
  }
}

export function emptyTrail(): ToolTrail {
  return { events: [], compactions: [], fileBytes: 0, fromByte: 0, partial: false }
}
