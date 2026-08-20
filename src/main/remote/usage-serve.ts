/**
 * What this machine answers when *another* machine asks what one of its
 * sessions has spent.
 *
 * ## Why this is its own file
 *
 * Because it is the same three reads the window at this desk performs for its
 * own usage bar, and it must stay the same three. `usage-ipc.ts` holds them
 * behind Electron IPC handlers, which a relay connection cannot call; this
 * module reaches the functions underneath those handlers so that a remote bar
 * and a local bar are two callers of one mechanism rather than two
 * implementations of one feature. Nothing about a plan window or a context
 * window is worked out here.
 *
 * It sits in `remote/` rather than beside the usage code for the ordinary
 * reason: it exists only because there is a wire. `host-core.ts` hands it to the
 * `SessionFanout`, whose having it is what makes this desktop advertise
 * `CAPABILITY.usage` at all — see `SessionAccess.usage`.
 *
 * ## The one rule that shapes it
 *
 * **The dear reading is reachable only through its own method.** Measured on
 * this machine on 2026-08-19: a plan refresh boots a whole Claude Code, 725 MB
 * peak and about three seconds, while `plan` reads memory and `context` reads a
 * bounded tail of a file the agent is already writing at 2–17 ms. If all three
 * arrived through one `read(want)` the first careless call site would put the
 * expensive one on a mount, and every tab of every remote window would cost 725
 * MB on this machine. Three methods is the guard, and it is a guard rather than
 * a style because the cost is real and is paid by whoever is sitting at *this*
 * keyboard, not by whoever is asking.
 *
 * ## And the one place it repeats something
 *
 * `context` resolves which account store to read the transcript out of, which is
 * the same resolution the `usage:context` handler performs. It is repeated —
 * ten lines of it — rather than shared, and the thing that matters is *what* is
 * shared: both ask `accountFor`, which is the single answer to "whose login is
 * this session on". Two copies of that answer is how one login's figure lands on
 * another login's bar; two copies of the call that consults it is only tidiness.
 */

import { blankContextReading, readContextWindow } from '../context-window'
import { accountFor, readUsage, refreshUsage, type UsageOptions } from '../usage-ipc'
import type { RemoteUsageAccess } from './server'

/**
 * The usage seam a paired machine reaches, built over this machine's own
 * readers.
 *
 * `options` is the same `UsageOptions` `registerUsageIpc` is given — the same
 * `describeSession` above all, because "which agent does this session run and
 * whose login did it resolve to" must have one answer on this machine whichever
 * window is asking. A second lookup here would be a second answer, and the
 * visible form of that disagreement is a remote bar attributing one account's
 * spending to another account's session.
 */
export function createUsageServe(options: UsageOptions): RemoteUsageAccess {
  return {
    /**
     * Free by construction: `readUsage` reads what this process is already
     * holding for the account, plus one file for a Codex login. It never
     * spawns, and that is the property the whole capability rests on — this is
     * what a remote bar asks for when it mounts.
     */
    plan: async (sessionId) => toRecord(await readUsage(sessionId, options)),
    /**
     * The reading that costs, and the outcome of taking it, in one answer.
     *
     * Both halves travel together because there is no push channel on this
     * wire. The local bar learns the outcome through its promise and the numbers
     * through `usage:update`; a remote bar has one round trip, and asking twice
     * would be a second chance for the half that carries the figures to go
     * missing.
     *
     * The report is read *after* the refresh has settled, never composed from
     * it: `refreshUsage` writes what it found into the account's shared
     * readings, and reading those back is what makes a remote bar show the same
     * number the window on this machine would show for the same login.
     */
    refresh: async (sessionId, force) => {
      const result = await refreshUsage(sessionId, options, force)
      const report = await readUsage(sessionId, options)
      return { ...result, report }
    },
    /**
     * How full that session's context window is — a bounded tail read of the
     * transcript, so it may be asked for as often as the far bar's own events
     * fire.
     */
    context: async (sessionId) => {
      const session = options.describeSession?.(sessionId) ?? null
      if (!session) {
        return toRecord(blankContextReading(null, 'not-reported', `No session ${sessionId} is running.`))
      }
      /*
       * Which store to look in is a question about this session's *account*, and
       * getting it wrong is not a blank figure — it is the default login's own
       * conversation in the same folder, reported as this session's. Only the
       * Claude-store agents take a scope; Codex takes `codexHome` and reads
       * nothing from it.
       */
      const store = session.provider === 'codex' ? null : accountFor('claude', session).configDir
      const codexHome = session.provider === 'codex' ? accountFor('codex', session).configDir : null
      const reading = await readContextWindow({
        provider: session.provider,
        cwd: session.cwd,
        // The conversation this app named at spawn, when it named one. Absent
        // for a resumed session and for one started outside this app, both of
        // which keep the inference and are labelled as inferred.
        ...(session.agentSessionId ? { agentSessionId: session.agentSessionId } : {}),
        ...(store === null ? {} : { scope: { configDir: store } }),
        ...(codexHome === null ? {} : { codexHome }),
      })
      return toRecord(reading)
    },
  }
}

/**
 * The far end's own reading, as the plain record the wire carries.
 *
 * A cast and not a copy, deliberately. The value is already a plain object of
 * JSON scalars — it is the same one this machine's own IPC hands its renderer —
 * and rebuilding it field by field here would be the mirror `UsageAnswerWire`
 * exists to avoid: a second, older idea of the shape that silently drops a
 * window kind the day one is added.
 */
function toRecord(value: object): Record<string, unknown> {
  return value as unknown as Record<string, unknown>
}
