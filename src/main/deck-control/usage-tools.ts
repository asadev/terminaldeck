/**
 * What the agents are using up: plan limits, context windows, and cost.
 *
 * Three tools over the usage bar and the cost tiles:
 *
 *  - `usage.read` — a session's account's plan limits (`usage:read`) and how
 *    full its context window is (`usage:context`), in one answer, because the
 *    question a person asks is "how much room is left" and the two halves of
 *    that live on one bar.
 *  - `usage.refresh` — bring the plan figures up to date (`usage:refresh`).
 *  - `usage.cost` — what a project, or one session in it, has cost
 *    (`cost:project`, `cost:sessions`, `cost:session`).
 *
 * ## Why refresh is `act` and the reads are not
 *
 * Reading is cheap and changes nothing: a file tail, measured at a few
 * milliseconds. A refresh may start a `claude` of this app's own to read
 * `/usage` from — `usage-probe.ts` measured a whole Claude Code boot, 725 MB
 * and about three seconds — which is real work done on the person's machine
 * under their login. It never types into one of their sessions; that path was
 * removed on purpose and this does not bring it back.
 *
 * ## The cost header in `catalogue.ts` is out of date, and this is why
 *
 * It said nothing exposes cost because the cost work was landing in parallel.
 * That work landed: `cost-ipc.ts` has stable reads, and they are named for this
 * file (`readProjectCost`, `listProjectTranscripts`, `readSessionCost`) so the
 * tile and the tool cannot add up the same transcripts differently.
 */

import { requireKnownFolder, requireSession, type ToolSpec } from './catalogue'
import { optBool, optInt, optStr, str } from './agents-area-args'
import { Refused } from './surface'

/** A transcript in a project's store, as `cost:sessions` lists it. */
export interface TranscriptFileLike {
  path: string
  sessionId: string
  modifiedAt: number
}

export interface UsageToolDeps {
  /** `readUsage(sessionId, options)` — null for every login on the machine. */
  read(sessionId: string | null): Promise<unknown>
  /** `readSessionContext(sessionId, options)`. */
  context(sessionId: string): Promise<unknown>
  /** `refreshUsage(sessionId, options, force)`. */
  refresh(sessionId: string, force: boolean): Promise<unknown>
  /** `readProjectCost`. */
  projectCost(projectPath: string): Promise<unknown>
  /** `listProjectTranscripts`. */
  transcripts(projectPath: string): Promise<TranscriptFileLike[]>
  /** `readSessionCost` — refuses a path outside the transcript store. */
  sessionCost(transcriptPath: string): Promise<unknown>
}

/** Most transcripts listed in one answer. A busy folder has hundreds. */
export const MAX_COST_SESSIONS = 100

export function usageTools(deps: UsageToolDeps): ToolSpec[] {
  return [
    {
      id: 'usage.read',
      wire: 'usage_read',
      tier: 'read',
      title: 'Read plan limits and context use',
      description:
        'For a session: how much of its account’s plan limits are used and when they reset (as far as the ' +
        'agent has reported them), and how full its context window is. With no sessionId: the limits of every ' +
        'login on this computer. A figure the agent has not reported is said to be missing, never guessed. ' +
        'usage.refresh fetches fresh plan figures.',
      index: 'Read plan-limit use and context-window fullness for a session or every login.',
      inputSchema: {
        type: 'object',
        properties: { sessionId: { type: 'string', description: 'A session from sessions.list. Omit for every login.' } },
        additionalProperties: false,
      },
      summary: (args) => `Read usage${optStr(args, 'sessionId') === null ? '' : ` for session ${optStr(args, 'sessionId')}`}`,
      run: async (args, context) => {
        const id = optStr(args, 'sessionId')
        if (id === null) return { value: { limits: await deps.read(null) }, summary: { sessionId: null } }
        const session = requireSession(context, id)
        const [limits, contextWindow] = await Promise.all([deps.read(session.id), deps.context(session.id)])
        return { value: { sessionId: session.id, limits, contextWindow }, summary: { sessionId: session.id } }
      },
    },

    {
      id: 'usage.refresh',
      wire: 'usage_refresh',
      tier: 'act',
      title: 'Refresh plan limits',
      description:
        'Bring a session’s account’s plan-limit figures up to date. Reads what is on disk first and, only if ' +
        'that is not enough, runs a short Claude Code of its own to ask — it never types into the session. ' +
        'Skips when the figures are fresh or the login has no plan limits, unless force is true.',
      index: 'Fetch fresh plan-limit figures for a session’s account.',
      inputSchema: {
        type: 'object',
        properties: {
          sessionId: { type: 'string' },
          force: { type: 'boolean', description: 'Ask even when the figures are recent. Default false.' },
        },
        required: ['sessionId'],
        additionalProperties: false,
      },
      summary: (args) => `Refresh the plan limits for session ${optStr(args, 'sessionId') ?? '?'}`,
      run: async (args, context) => {
        const session = requireSession(context, str(args, 'sessionId'))
        const result = await deps.refresh(session.id, optBool(args, 'force', false))
        return { value: result, summary: { sessionId: session.id } }
      },
    },

    {
      id: 'usage.cost',
      wire: 'usage_cost',
      tier: 'read',
      title: 'Read what a project has cost',
      description:
        'Token use and cost for an open folder: the totals across its recent sessions and the list of its ' +
        'session transcripts, newest first. Give transcriptPath (from that list) to get one session’s ' +
        'breakdown instead. Counted once per request even where a transcript repeats it, exactly as the ' +
        'app’s own cost tiles count.',
      index: 'Read token use and cost for a folder, or for one session in it.',
      inputSchema: {
        type: 'object',
        properties: {
          projectPath: { type: 'string', description: 'An open folder. See projects.list.' },
          transcriptPath: { type: 'string', description: 'One of that folder’s transcripts, for one session.' },
          limit: { type: 'number', description: `How many transcripts to list. Default 20, max ${MAX_COST_SESSIONS}.` },
        },
        required: ['projectPath'],
        additionalProperties: false,
      },
      precheck: (args, context) => {
        requireKnownFolder(context.surface, str(args, 'projectPath'))
      },
      summary: (args) =>
        optStr(args, 'transcriptPath') === null
          ? `Read the cost of ${optStr(args, 'projectPath') ?? '?'}`
          : `Read the cost of one session in ${optStr(args, 'projectPath') ?? '?'}`,
      run: async (args, context) => {
        const path = requireKnownFolder(context.surface, str(args, 'projectPath'))
        const transcripts = await deps.transcripts(path)
        const wanted = optStr(args, 'transcriptPath')
        if (wanted !== null) {
          /*
           * Only a transcript of *this* folder. `readSessionCost` already
           * refuses anything outside the transcript store; this narrows it to
           * the folder the caller named, so a known folder cannot be used as a
           * pass to read the cost of every other project on the machine.
           */
          if (!transcripts.some((file) => file.path === wanted)) {
            throw new Refused(
              'not-permitted',
              `${wanted} is not one of ${path}’s transcripts. usage.cost without transcriptPath lists them.`,
            )
          }
          return { value: { session: await deps.sessionCost(wanted) }, summary: { projectPath: path, session: true } }
        }
        const limit = optInt(args, 'limit', 20, 1, MAX_COST_SESSIONS)
        return {
          value: {
            project: await deps.projectCost(path),
            transcripts: transcripts.slice(0, limit),
            totalTranscripts: transcripts.length,
          },
          summary: { projectPath: path, transcripts: transcripts.length },
        }
      },
    },
  ]
}
