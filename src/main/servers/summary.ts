/**
 * ONE STORED SERVER, REDUCED TO WHAT MAY CROSS THE BRIDGE.
 *
 * ## Why this is a function and not four lines in `index.ts`
 *
 * It was four lines in `index.ts`, and the comment above them made the right
 * argument: *"named fields rather than the stored row, so that a field added to
 * the store later has to be **chosen** to cross the bridge instead of arriving
 * because nobody stopped it."* That rule stands and this file keeps it — the
 * field list below is still written out by hand, and a new `StoredServer` field
 * still crosses only when somebody types it here.
 *
 * What it did not have was a test. `index.ts` is the Electron entry point: it
 * calls `app.whenReady`, and nothing in the suite can reach inside it. So the
 * one place in the codebase that decides *which facts about a server a person
 * is allowed to see* was the one place with no test at all, and the whole class
 * of bug that shape invites duly happened — `port` was simply not in the list,
 * and the app told four screens that a server on 2222 was at `192.0.2.11`. It
 * typechecked perfectly, because a missing optional field is not an error
 * anywhere.
 *
 * Moving the list into a pure function costs one import at the call site and
 * buys `summary.test.ts`, which runs a **real `ServerStore`** over a real file
 * and checks both directions: that everything a screen needs arrives, and that
 * nothing a screen must never have does.
 *
 * ## The two halves of the line, and which is which
 *
 * §3.7: *"the renderer learns that a server has a saved sign-in, and never what
 * it is."* Three fields here are about the sign-in and the identity without
 * being either — `credential` is a *kind*, `hostKey` is public by construction,
 * `drivesWindows` is a permission whose state a screen must be able to show —
 * and the argument for each is written where the field is declared, on
 * {@link ServerSummary}. `credentials.ts` holds the parts that never move, and
 * `credentials-never-cross.test.ts` is the standing guard on that.
 */

import type { ServerSummary } from './actions'
import type { StoredServer } from './store'

/**
 * What one stored server looks like to everything past the main process.
 *
 * Every field is named. `addedAt`, `lastConnectedAt` and `startIn` are stored
 * and deliberately not here — no surface draws them — and adding one is a
 * decision somebody makes in this function rather than something that happens
 * because a store grew a column.
 */
export function serverSummary(row: StoredServer): ServerSummary {
  return {
    id: row.id,
    name: row.name,
    address: row.address,
    /*
     * Where the machine actually is. The address without it is not a shorter
     * answer, it is a wrong one: `192.0.2.11` for a server on 2222 is a string
     * a person pastes into `ssh` and gets refused by a machine this app is
     * connected to. `shared/server-where.ts` owns what is *done* with it — the
     * usual port is not printed, anything else always is — and this line only
     * has to make sure the number gets far enough to be asked about.
     */
    port: row.port,
    username: row.username,
    // The *kind* of sign-in kept, which is not the sign-in. It is what lets a
    // screen say "kept on this computer" instead of "this build did not say".
    credential: row.credential,
    // Public by construction — the same string `ssh-keyscan` prints — and the
    // entire point of the identity screen is that it can be compared.
    ...(row.hostKey === null ? {} : { hostKey: row.hostKey }),
    // Whether sessions on it may act on browser windows here. A permission
    // whose state the screen cannot see is a control that cannot be trusted.
    drivesWindows: row.drivesWindows,
  }
}
