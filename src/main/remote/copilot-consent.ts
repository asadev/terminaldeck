/**
 * A confirmation, as a connected device has to be able to read it.
 *
 * ## Why this is its own file
 *
 * `copilot-wiring.ts` is where the other translations live, and this one cannot
 * go there: that file imports the profile system, the records fence and the
 * transcript reader, so it drags most of the main process behind it. This is
 * imported by `copilot-runs.ts`, which is exercised against a fake clock, a fake
 * session layer and no Electron at all — and the consent path is the one that
 * most needs to be drivable in that state, because what it does is refuse things
 * under conditions the app is not in.
 *
 * ## Two shapes for one question, and the difference is the whole point
 *
 * A pending row says *something needs attention*. A question says *decide*.
 * They carry different fields because a consent prompt without enough context
 * becomes a reflex Yes, and a gate that is always answered yes is worse than no
 * gate at all — it looks like protection while providing none.
 *
 * So the row that goes to every watcher carries the tool, the desktop's own
 * sentence and the countdown, and **not the arguments**. The arguments of a
 * pending alter call are the most sensitive thing on this surface: a settings
 * key and its new value, a session id and the text about to be typed into it. A
 * device that cannot answer has no decision to make with them.
 *
 * The question that goes to the one device that *can* answer carries all of it,
 * verbatim, in the tool's own order. That is not generosity; it is the minimum a
 * person needs to answer honestly, and withholding it would produce exactly the
 * reflex Yes this design is trying to avoid.
 *
 * ## Nothing is re-composed on the client
 *
 * `summary` is written by the tool that is about to run, on this machine, by the
 * code that knows what it will do. A client that wrote its own sentence would be
 * describing an action it did not implement, and the first time the two drifted
 * somebody would approve one thing having read another. The clients are told to
 * render these strings and never to build them; `COPILOT-REMOTE.md` §4.6 states
 * it as a constraint on any phone-side approval and it survives unchanged.
 */

import type { ConsentRequest } from '../deck-control/consent'
import type { CopilotConsentQuestion, CopilotPendingRow } from './protocol'

/**
 * One waiting confirmation, as a device *watches* it.
 *
 * Rebuilt field by field rather than spread, for the reason
 * `copilot-wiring.ts`'s header gives about every row that crosses to a device:
 * `ConsentRequest` is this app's own type and carries `args`, so a pass-through
 * would put the arguments of a pending settings change on a screen that has no
 * decision to make with them — and would keep doing it for every field added to
 * that type in future, with nobody having decided that it should.
 *
 * `mine` is computed on this desktop and passed in. It is not derivable from
 * anything else on the row, deliberately: `origin` is not here, because *which
 * other device asked for this* is not a device's business and an opaque id would
 * only invite a client to display it.
 */
/**
 * The sentence a phone shows, with the asking app's name on it when an app asked.
 *
 * The phone's sheet leads with the summary and has no headline of its own that
 * says who asked, so the name goes in front of the sentence — the same words the
 * activity log uses. The desktop puts it in its headline instead and shows the
 * summary bare (`ConsentRequest.askedBy`).
 */
function phoneSummary(request: ConsentRequest): string {
  return request.askedBy === undefined ? request.summary : `From “${request.askedBy}”: ${request.summary}`
}

export function toPendingRow(request: ConsentRequest, mine: boolean): CopilotPendingRow {
  return {
    id: request.id,
    tool: request.tool,
    summary: phoneSummary(request),
    requestedAt: request.requestedAt,
    expiresAt: request.expiresAt,
    mine,
  }
}

/**
 * One confirmation this device may answer, with everything needed to judge it.
 *
 * Sent only to the surface that raised it, so `origin` is here — that surface
 * already knows it is itself, and the field is what lets a client say *your
 * copilot asked for this* rather than leaving a person to guess which of their
 * agents is about to change something.
 *
 * `args` crosses whole. They have already been through `scrubArgs` on the way
 * into the log and into the broker, so what is here is the same text the desktop
 * dialog shows — one set of arguments, one rendering, and no chance of a phone
 * and a Mac describing the same pending action differently.
 */
export function toConsentQuestion(request: ConsentRequest): CopilotConsentQuestion {
  return {
    id: request.id,
    tool: request.tool,
    tier: request.tier,
    summary: phoneSummary(request),
    args: request.args,
    /*
     * A key's question carries who asked *in words* where the surface id would
     * go. A phone that does not recognise an origin shows it verbatim, and
     * `key:<uuid>` on a consent sheet tells a person nothing about which app
     * is about to change their machine — the context-free prompt §4.3 says
     * becomes a reflex Yes. The id is not needed out there: answering goes by
     * the question's own id, and the broker checks who may.
     */
    origin: request.label !== undefined && request.origin.startsWith('key:') ? request.label : request.origin,
    requestedAt: request.requestedAt,
    expiresAt: request.expiresAt,
  }
}
