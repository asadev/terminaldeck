/**
 * `tools.run` — call any tool by name, for clients that can only call what they
 * were shown.
 *
 * ## Why this exists
 *
 * `describe-tool.ts` keeps the standing catalogue small by holding most tools
 * behind `tools.describe`: a one-line index on every turn, the full schema on
 * the turn that asks. That works for a client that will send a `tools/call`
 * naming a tool it was never listed. claude.ai's custom connectors and
 * ChatGPT's developer-mode connectors are not those clients — they build the
 * model's tool list from `tools/list` and nothing else, so a tool behind the
 * index is one their model can read about and never reach. For an AI app
 * outside this one, that is most of what the owner asked for:
 *
 *   > *"Everything that I can do manually should be able to do through the
 *   > MCP."*
 *
 * So `tools.run` is one listed tool whose arguments are another tool's name and
 * that tool's arguments. `tools.describe` says what the arguments are; this
 * sends them.
 *
 * ## It is not a door, it is the same door
 *
 * `DeckControl.call` recognises this tool before anything else and re-enters
 * itself with the named tool — so the call that runs is judged exactly as if it
 * had been sent directly: the same schema check, precheck, tier (after
 * escalation), budget, confirmation and log row. There is no row for the
 * wrapper, because the row that matters names the tool that ran, and there is
 * no budget charged twice. A `tools.run` that ran something with fewer checks
 * than calling it directly would be the "lower door" `control.ts` says does not
 * exist.
 *
 * ## The property it must not break
 *
 * `describe-tool.ts` states it: a tool this caller may not use answers exactly
 * like a tool that does not exist. Here that is `no tool called <name>`, the
 * sentence `server.ts` and `tools.describe` already use, produced by one branch
 * for both cases — so a session holding only the browser verbs cannot learn
 * that `sessions.start` exists by asking this tool to run it.
 *
 * ## Who is shown it
 *
 * Callers on an access key, always — they are who it is for. The in-app
 * copilot's listing is left exactly as it was, at the count and token budget
 * `catalogue-cost.test.ts` pins; a session's allow-list does not name it, so a
 * session neither sees nor reaches it.
 */

import type { ToolSpec } from './catalogue'

export const RUN_ID = 'tools.run'
export const RUN_WIRE = 'tools_run'

/** What the model reads. Short: it is paid on every turn of a key caller. */
const RUN_DESCRIPTION =
  'Call one of the tools listed under tools_describe, by name. Get its arguments from tools_describe first, ' +
  'then pass them here as `arguments`. It runs with exactly the same permissions, confirmations and limits as ' +
  'calling the tool directly, and answers with that tool’s own result.'

/**
 * The listing-only spec.
 *
 * Its `run` is never reached — `DeckControl.call` intercepts the id first — and
 * it throws to make that loud if the interception is ever removed, rather than
 * quietly succeeding at doing nothing.
 */
export function runToolSpec(): ToolSpec {
  return {
    id: RUN_ID,
    wire: RUN_WIRE,
    // The tier is the inner tool's, decided when it is known. This one only
    // drives the advertised hints, and `server.ts` replaces those per caller so
    // a "Look only" key is not told this can change things and a "Full
    // control" key is not told it cannot.
    tier: 'read',
    title: 'Run a tool by name',
    description: RUN_DESCRIPTION,
    inputSchema: {
      type: 'object',
      properties: {
        name: { type: 'string', description: 'The tool to run, e.g. sessions_get. See tools_describe.' },
        arguments: {
          type: 'object',
          description: 'That tool’s arguments, exactly as tools_describe lists them.',
          additionalProperties: true,
        },
      },
      required: ['name'],
      additionalProperties: false,
    },
    summary: (args) => {
      const target = runTarget(args)
      return target.ok ? `Run ${target.name}` : 'Run a tool'
    },
    run: async () => {
      throw new Error('deck-control: tools.run must be dispatched by DeckControl.call, never run directly')
    },
  }
}

export type RunTarget = { ok: true; name: string; args: Record<string, unknown> } | { ok: false; problem: string }

/**
 * The tool named and its arguments, or why there is none.
 *
 * Tolerant of `arguments` arriving as a JSON string, because a model handed an
 * open object schema sometimes serialises it — and refusing that costs a turn
 * to teach it nothing. Anything that is not an object after that is refused.
 */
export function runTarget(args: Record<string, unknown>): RunTarget {
  const name = args.name
  if (typeof name !== 'string' || name.trim() === '') {
    return { ok: false, problem: 'name is required: the tool to run, as tools_describe lists it' }
  }
  let inner: unknown = args.arguments ?? {}
  if (typeof inner === 'string') {
    try {
      inner = inner.trim() === '' ? {} : JSON.parse(inner)
    } catch {
      return { ok: false, problem: 'arguments must be an object of that tool’s arguments' }
    }
  }
  if (typeof inner !== 'object' || inner === null || Array.isArray(inner)) {
    return { ok: false, problem: 'arguments must be an object of that tool’s arguments' }
  }
  return { ok: true, name: name.trim(), args: inner as Record<string, unknown> }
}
