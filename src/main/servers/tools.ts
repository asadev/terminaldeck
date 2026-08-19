/**
 * The three tools that let the copilot into the server room, and the gate on
 * each of them.
 *
 * `SERVERS-DESIGN.md` §6, and the sentence that governs the whole file:
 *
 * > Full control of a production server driven by an agent is the largest blast
 * > radius in this product. Not the largest so far — the largest there is. The
 * > copilot can already start sessions and write settings on *this* machine,
 * > which is recoverable by somebody sitting at it. A server is somebody's live
 * > website, reached from a machine they are not sitting at, and the person who
 * > notices first may be a customer.
 *
 * Nothing here is a new permission system. `deck-control/` already has tiers, an
 * escalation hook, a precheck, a consent gate and an append-only action log, and
 * this file is a *use* of them — contributed through `DeckControlOptions.extraTools`,
 * which exists for exactly this and whose own comment says so: a feature that
 * wants to give the copilot a capability reaches it **through** the dispatcher
 * rather than beside it, so it is prechecked, tiered, escalated, budgeted, gated
 * and logged like everything else.
 *
 * ## There is no `servers.run`, and there will not be one in v1
 *
 * §6.1. An arbitrary-command tool is the whole machine, and it makes every rule
 * in the design document decorative: an agent that can run a command does not
 * need `servers.restart` and is not bound by its consequence sentence, its
 * class, or its way back. So the copilot gets the **named actions only** —
 * every one of which is Safe, Reversible or Kept by §4.1 — and the unbounded
 * shell stays a thing a person does with their own hands in zone three.
 *
 * This is a real restriction with a real cost: **the copilot cannot fix a
 * server in a way we did not anticipate.** That cost is accepted deliberately,
 * and it is the kind of thing to revisit against a permission model that has
 * been used in anger, not before. `no-run-tool.test.ts` fails if anything here
 * grows a free-text command argument.
 *
 * ## Why three tools and not eight
 *
 * The design document lists eight tool names. Eight tool *definitions* is not
 * what it is asking for, and shipping them that way would break something
 * measurable: `catalogue.ts` holds the whole tool listing to
 * `MAX_CATALOGUE_TOOLS` = 20 and `MAX_CATALOGUE_TOKENS` = 8,000, because every
 * definition sits in the context of *every* request the copilot makes, and the
 * app already contributes fourteen built-ins plus five browser tools plus the
 * tour. That header's instruction to whoever runs out is explicit: **do not
 * raise the number, disclose progressively.**
 *
 * So the eight names become three definitions with the same eight behaviours:
 * one read tool that answers both "which servers" and "what is on this one",
 * one bounded log reader, and one control tool whose `action` is a closed enum.
 * The enum is not a compromise on safety — it is the same closed list §4.2
 * defines, checked in one place, and it is *harder* to widen accidentally than
 * six near-identical specs would be.
 *
 * ## A guest never gets this, under any circumstances
 *
 * `servers.control` refuses a remote caller outright, before the tier is even
 * consulted, and `grants.ts` refuses to mint or honour a grant for one. Two
 * checks for one rule, guarding two different events — a grant existing and a
 * grant being used — because a hole in either is a hole.
 *
 * The precedent is one level down and it is exactly this shape.
 * `deck-control/surface.ts` records why `sessions.start` had to learn who was
 * asking: *"a tool's effect for a remote caller may never exceed what that
 * device's own protocol frames already permit."* There is **no server frame in
 * the remote protocol at all**, so the permitted effect is nothing. Reading is
 * allowed — a phone asking "is the website up" discloses nothing it could not
 * see by visiting the website — and changing is not.
 */

import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from '../deck-control/catalogue'
import { Refused, type Tier } from '../deck-control/surface'
import {
  ACTION_IDS,
  ActionFailed,
  ActionRefused,
  DEFAULT_LOG_LINES,
  MAX_LOG_LINES,
  previewOf,
  type ActionId,
  type ServerRoom,
} from './actions'
import type { ServerGrants } from './grants'

/* ---------------------------------------------------------------- helpers -- */

function str(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Refused('not-permitted', `${key} is required and must be a non-empty string`)
  }
  return value
}

function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new Refused('not-permitted', `${key} must be a string`)
  return value
}

function optInt(args: Record<string, unknown>, key: string, fallback: number, min: number, max: number): number {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Refused('not-permitted', `${key} must be a number`)
  }
  return Math.min(Math.max(Math.trunc(value), min), max)
}

/**
 * The actions the copilot may name.
 *
 * Derived from {@link ACTION_IDS} minus the three that make no sense through a
 * tool, rather than typed out again — a second list is a list that eventually
 * disagrees, and the disagreement here would be a tool naming an action that
 * does not exist or, worse, an action existing that the enum forgot to exclude.
 *
 * `open` and `copy-address` are excluded because they happen on *this*
 * computer: opening a browser tab and putting something on the clipboard are
 * things done for a person who is looking, and an agent doing either at 03:00
 * is a surprise rather than a capability.
 */
export const CONTROL_ACTIONS: readonly ActionId[] = ACTION_IDS.filter(
  (id) => id !== 'open' && id !== 'copy-address' && id !== 'logs',
)

/** Turn this layer's refusals into the dispatcher's, so the log keeps them apart. */
async function asTool<T>(body: () => Promise<T>): Promise<T> {
  try {
    return await body()
  } catch (error) {
    /*
     * `ActionRefused` is a rule — "we don't have a previous version recorded",
     * "we can't tell how this was set up". `ActionFailed` is the server saying
     * no. Both reach the action log as refusals rather than as crashes, which
     * is what keeps "the copilot was told no" a different row from "the copilot
     * broke". `browser-tools.ts` does the same translation for `DriveRefused`
     * and its comment carries the argument.
     */
    if (error instanceof ActionRefused) throw new Refused('not-permitted', error.sentence)
    if (error instanceof ActionFailed) throw new Refused('not-permitted', error.sentence)
    throw error
  }
}

/* ---------------------------------------------------------------- schemas -- */

const LOOK_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    serverId: {
      type: 'string',
      description: 'Which server. Leave it out to get the list of servers instead.',
    },
  },
  additionalProperties: false,
}

const LOGS_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    serverId: { type: 'string' },
    cardId: { type: 'string', description: 'The id of the site, app or database, from servers.look.' },
    lines: { type: 'integer', description: `How many lines from the end. Default ${DEFAULT_LOG_LINES}, max ${MAX_LOG_LINES}.` },
  },
  required: ['serverId', 'cardId'],
  additionalProperties: false,
}

const CONTROL_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    serverId: { type: 'string' },
    cardId: { type: 'string', description: 'The id of the site, app or database, from servers.look.' },
    action: { type: 'string', enum: [...CONTROL_ACTIONS] },
  },
  required: ['serverId', 'cardId', 'action'],
  additionalProperties: false,
}

/* ------------------------------------------------------------------ tools -- */

export interface ServerToolsDeps {
  room: ServerRoom
  grants: ServerGrants
}

export function serverTools({ room, grants }: ServerToolsDeps): ToolSpec[] {
  /** The server exists, or the call stops here rather than at a dialog. */
  const known = (serverId: string): void => {
    if (!room.knows(serverId)) {
      throw new Refused('not-permitted', `There is no server with the id ${serverId} in this app.`)
    }
  }

  /**
   * Everything `servers.control` refuses before the tier is consulted.
   *
   * Order matters and is deliberate. Remote first, because it is the rule that
   * can never be satisfied and a person must never be shown a dialog for it —
   * §6.2's *"the copilot is never blocked from asking; it is blocked from doing
   * silently"* is about the local copilot, and a phone is not that. Then the
   * server id. Then the facts.
   */
  const controlPrecheck = (args: Record<string, unknown>, context: ToolContext): void => {
    if (context.caller.kind !== 'local') {
      throw new Refused(
        'not-granted',
        'Changing anything on a server only works for the person at this machine. A paired device cannot do ' +
          'it and cannot be given permission to. Say what you would have done and let them do it.',
      )
    }
    const serverId = str(args, 'serverId')
    known(serverId)
    const cardId = str(args, 'cardId')
    const action = str(args, 'action')
    if (!(CONTROL_ACTIONS as readonly string[]).includes(action)) {
      throw new Refused('not-permitted', `action must be one of: ${CONTROL_ACTIONS.join(', ')}`)
    }
    /*
     * §6.2's second precheck: *"any action on a server whose facts say the
     * action `cannot` be performed."* Those facts come from a look, so a
     * control call on a server nobody has looked at is refused with an
     * instruction rather than allowed through to a dialog. That is a stronger
     * rule than the document asks for and it is the right direction: it makes
     * the fact check unconditional instead of conditional on a cache being
     * warm, and "look before you act" is a thing a model can obey.
     */
    const seen = room.cached(serverId)
    if (seen === null) {
      throw new Refused(
        'not-permitted',
        `Call servers.look on ${serverId} first. Nothing on this server can be changed before this app has ` +
          'seen what is on it.',
      )
    }
    const card = seen.cards.find((row) => row.id === cardId)
    if (card === undefined) {
      throw new Refused('not-permitted', `There is nothing called ${cardId} on that server.`)
    }
    const absent = seen.absent[cardId]?.find((row) => row.actionId === action)
    if (absent !== undefined) throw new Refused('not-permitted', absent.because)
    if (!(seen.offered[cardId] ?? []).includes(action as ActionId)) {
      throw new Refused('not-permitted', `${action} is not something this app can do to ${card.name}.`)
    }
  }

  const lookTool: ToolSpec = {
    id: 'servers.look',
    wire: 'servers_look',
    tier: 'read',
    title: 'Look at a server',
    description:
      'With no serverId: every server this app knows, by name and address. With one: what is running on it — ' +
      'its websites, apps and databases, whether each is running, and what this app can do to each. Facts it ' +
      'could not establish are reported as such rather than guessed; read `cannot` before concluding anything ' +
      'is absent. Nothing here is a credential. Call this before servers.control on any server.',
    inputSchema: LOOK_SCHEMA,
    precheck: (args) => {
      const serverId = optStr(args, 'serverId')
      if (serverId !== null) known(serverId)
    },
    summary: (args) => {
      const serverId = optStr(args, 'serverId')
      return serverId === null ? 'List the servers this app knows' : `Look at what is running on ${serverId}`
    },
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const serverId = optStr(args, 'serverId')
        if (serverId === null) {
          const servers = room.list()
          return { value: { servers }, summary: { servers: servers.length } }
        }
        const seen = await room.look(serverId)
        return {
          value: seen,
          summary: {
            serverId,
            cards: seen.cards.length,
            notRunning: seen.cards.filter((card) => card.running === false).length,
            couldNotCheck: seen.cannot.length,
          },
        }
      }),
  }

  const logsTool: ToolSpec = {
    id: 'servers.logs',
    wire: 'servers_logs',
    tier: 'read',
    title: 'Read a server’s recent output',
    description:
      'The last lines one site, app or database on a server has printed, newest last. Fetched once — there is ' +
      'no follow mode, so ask for more lines rather than calling this repeatedly.',
    inputSchema: LOGS_SCHEMA,
    precheck: (args) => {
      known(str(args, 'serverId'))
      str(args, 'cardId')
    },
    summary: (args) => `Read the recent output of ${optStr(args, 'cardId') ?? '?'} on ${optStr(args, 'serverId') ?? '?'}`,
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const lines = optInt(args, 'lines', DEFAULT_LOG_LINES, 1, MAX_LOG_LINES)
        const result = await room.logs(str(args, 'serverId'), str(args, 'cardId'), lines)
        return { value: result, summary: { lines: result.lines.length } }
      }),
  }

  const controlTool: ToolSpec = {
    id: 'servers.control',
    wire: 'servers_control',
    tier: 'alter',
    title: 'Start, stop, update or copy something on a server',
    description:
      'Do one named thing to one site, app or database: start, restart, stop, update, go-back or backup. There ' +
      'is no way to run a command of your own — these are the only things this app can do to a server, and each ' +
      'one either changes nothing or can be put back. Unless the person has given you control of that ' +
      'particular server, every call asks them first, in the app, with the exact consequence written out. Call ' +
      'servers.look first.',
    inputSchema: CONTROL_SCHEMA,
    /**
     * The tier cannot be static, because the answer depends on *which* server.
     *
     * The same shape `browser-tools.ts` already uses for a browser origin —
     * `drive.originGranted(origin) ? 'act' : 'alter'` — and for the same
     * reason. `control.ts` takes the *higher* of this and the declared tier, so
     * the declaration is `alter` and this can only ever move it down to `act`
     * for a server that has been explicitly granted. A bug here cannot weaken
     * the gate below `alter`.
     */
    escalate: (args, context): Tier => {
      const serverId = optStr(args, 'serverId')
      if (serverId === null) return 'alter'
      return grants.granted(serverId, context.caller) ? 'act' : 'alter'
    },
    precheck: controlPrecheck,
    summary: (args) => {
      const serverId = optStr(args, 'serverId') ?? '?'
      const cardId = optStr(args, 'cardId') ?? '?'
      const action = optStr(args, 'action') ?? '?'
      /*
       * §4.3: the consequence sentence is written where the action is
       * implemented, and rendered by three surfaces. This one asks the room for
       * the *same* preview the dialog and the card draw, so the copilot's
       * consent question cannot describe something different from what the
       * button describes.
       *
       * `summary` is synchronous — `control.ts` calls it while assembling the
       * consent request — so it reads the cached view the precheck has already
       * insisted on. Falling back to a plain sentence rather than throwing: a
       * summary that throws would turn a refusable call into a crash, and the
       * precheck has already refused every case where the cache is cold.
       */
      const seen = room.cached(serverId)
      const card = seen?.cards.find((row) => row.id === cardId)
      if (seen === undefined || seen === null || card === undefined) {
        return `${action} ${cardId} on ${serverId}`
      }
      return previewOf(action as ActionId, { serverId, card, facts: seen.facts }).sentence
    },
    run: async (args): Promise<ToolOutput> =>
      asTool(async () => {
        const serverId = str(args, 'serverId')
        const cardId = str(args, 'cardId')
        const action = str(args, 'action') as ActionId
        const outcome = await room.act(serverId, cardId, action)
        return {
          value: outcome,
          summary: { serverId, cardId, action, wayBack: outcome.wayBack?.actionId ?? null },
        }
      }),
  }

  return [lookTool, logsTool, controlTool]
}
