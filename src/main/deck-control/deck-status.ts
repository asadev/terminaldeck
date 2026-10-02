/**
 * What the tool server is, right now — one answer for the Settings pane and for
 * a caller asking over the server itself.
 *
 * `deck-control:status` composed this inline in `index.ts` for the window. The
 * `tools.status` tool asks the same question from the other side — an AI in
 * another app wanting to know whether its confirmation is still on screen, or
 * whether the log it is being recorded in is actually being written — and two
 * compositions of one status are two answers that drift by a field. So the
 * composition is here, and both call it.
 *
 * Deliberately not the token and not the config path. Neither a renderer nor a
 * tool caller has a use for either, and a secret that reaches page code — or a
 * tool result that leaves this machine — is one screenshot from leaving.
 */

import type { ActionLog } from './action-log'
import type { CatalogueCost } from './catalogue'
import type { ConsentBroker } from './consent'
import type { DeckControl } from './control'
import type { Tier } from './surface'

export interface DeckControlStatus {
  running: true
  port: number
  server: string
  tools: Array<{ id: string; tier: Tier; title: string }>
  catalogue: CatalogueCost
  pendingConfirmations: number
  copilotSessions: string[]
  logFile: string
  logging: boolean
}

export function deckControlStatus(parts: {
  port: number
  server: string
  control: Pick<DeckControl, 'tools' | 'cost' | 'copilotSessions'>
  consent: Pick<ConsentBroker, 'list'>
  log: Pick<ActionLog, 'file' | 'broken'>
}): DeckControlStatus {
  return {
    running: true,
    port: parts.port,
    server: parts.server,
    tools: parts.control.tools().map((spec) => ({ id: spec.id, tier: spec.tier, title: spec.title })),
    /*
     * What the tool surface costs the copilot in context, every turn.
     *
     * Reported rather than kept internal because it is a number that only grows
     * and nobody would ever go looking for it. A settings pane that can show
     * "11 tools, about 2,200 tokens on every question" makes the standing charge
     * visible to the person paying it — and to the next agent about to add a
     * twelfth. See `MAX_CATALOGUE_TOKENS`.
     */
    catalogue: parts.control.cost(),
    pendingConfirmations: parts.consent.list().length,
    copilotSessions: parts.control.copilotSessions(),
    logFile: parts.log.file,
    // Said out loud rather than left to look quiet. A log that stopped
    // recording because the disk is full is a very different state from a
    // copilot that has not been asked to do anything.
    logging: !parts.log.broken,
  }
}
