/**
 * The meta-tool, and the decision about which tools hide behind it.
 *
 * ## Why this exists
 *
 * `MAX_CATALOGUE_TOOLS` is 20 and `MAX_CATALOGUE_TOKENS` is 8,000, and on
 * 2026-08-21 the assembled catalogue was 33 tools and 10,670 estimated tokens.
 * Four lanes landed in one night — worker profiles, network capture, asset
 * checks and the tools store — and each of them was individually reasonable.
 * Neither ceiling has been raised, because the instruction written on
 * `MAX_CATALOGUE_TOKENS` before any of them landed said not to:
 *
 *   > *"do not raise the number. Add a `tools.describe` meta-tool and move the
 *   > rarely-used definitions behind it, so the standing cost is a short index
 *   > and the full schema is fetched by the one turn that needs it."*
 *
 * This is that. A tool with an {@link ToolSpec.index} is not advertised: its
 * one line joins the index in this tool's description, and its schema is handed
 * over by a call to `tools.describe` on the turn that wants it. Everything else
 * is advertised exactly as before.
 *
 * ## What was moved, and the rule that decided it
 *
 * **A tool a turn is likely to reach for *first* keeps its schema. A tool that
 * is only ever reached for after another one has already been used can be an
 * index line.** The cost of being wrong is asymmetric and that is what sets the
 * rule: a keeper that is rarely used costs a few hundred tokens on every turn
 * forever, while a disclosed tool that turns out to be a first reach costs one
 * extra round trip on the turns that want it. The second bill is the one to
 * take.
 *
 * Applied against what the tools *do*, not what they are called — several of
 * them state their own place in the order, which settled the argument:
 *
 *  - **`servers.logs`, `servers.control`** — both end their own description
 *    with *"Call servers.look first"*. Second by their own contract. `servers.look`
 *    stays: it is the door into that whole surface and it is cheap.
 *  - **`tour.play`** — 4,022 characters, an eighth of the entire budget, for the
 *    tool used least often in the catalogue. And it cannot be a first reach:
 *    every quote in a tour is checked against a real transcript before it is
 *    shown, so the turn that writes one has already read the material with
 *    `sessions.transcript` or `sessions.result`. A turn that has decided to
 *    spend twelve stops can afford one describe.
 *  - **`browser.network`, `browser.extract`, `assets.rendition`, `assets.ledger`,
 *    `assets.coverage`, `assets.blocks`** — the scraping specialisms, and the
 *    check against what they do agrees with the guess from their names. Every
 *    one of them needs something that exists only after a page has been opened
 *    and read: a page to arm, a URL the page printed, a count of what was
 *    captured, a run to look back at. `assets.blocks` is the clearest of them —
 *    it reports what a run already did.
 *  - **`browser.workers`, `browser.worker`** — the pair moves together. `browser.worker`
 *    takes a lease on a profile named by `browser.workers`, so it is second
 *    beyond argument; `browser.workers` on its own is a first reach only for a
 *    turn that has already decided to drive a worker profile, which is itself
 *    the specialism. Keeping the cheap half advertised would have advertised the
 *    entry to a mode without the mode.
 *  - **`sessions.get`** — its own description ends *"Use sessions.transcript to
 *    read it"*, and it takes a `sessionId` that comes from `sessions.list`. It
 *    is the bridge between two tools that are both kept.
 *  - **`settings.write`** — `settings.read` says *"Read this before proposing a
 *    change"* and `settings.write` says *"Call settings.read for the current
 *    list"*. The pair is explicitly ordered, so the reader stays and the writer
 *    goes behind. This also takes the only `alter`-tier built-in out of the
 *    standing listing, which is a small good thing on its own.
 *  - **`git.status`** — `git.diff` states that it is *"the tool for 'what
 *    changed'"*, and `sessions.result` already reports the files git says
 *    changed in a session's folder. `git.status` answers the narrower follow-up.
 *  - **`log.note`** — a line written *about* something that was already done.
 *    There is no turn whose first act is to note that nothing has happened.
 *
 * ## What stayed, and why the line falls there
 *
 * The eighteen keepers are the six original browser verbs, the everyday session
 * tools (`sessions.list`, `.transcript`, `.start`, `.send`, `.stop`, `.result`,
 * plus `projects.list`), the three that answer "what is going on" without being
 * asked twice (`git.diff`, `alerts.list`, `settings.read`), `app.where` — which
 * its own description says to read *before* answering anything containing the
 * word "this" — and `servers.look`.
 *
 * Eighteen plus this tool is nineteen, one under the count cap rather than
 * exactly on it. That slack is deliberate: a cap you are sitting on is a cap the
 * next lane breaches, and the next lane should have somewhere to land without
 * reopening this decision.
 *
 * ## For whoever is over budget next
 *
 * Move a tool, do not trim a description, and still do not raise either number.
 * The prose in a tool description is load-bearing — most of it exists because a
 * model got something wrong without it — so trimming it to buy room is
 * borrowing against the thing the prose is for. There are eighteen advertised
 * tools and the ones nearest the line are `sessions.stop` and `browser.close`,
 * both of which are second reaches by the rule above and were kept only because
 * they are cheap and sit in the same breath as the tool that precedes them.
 *
 * ## The security property this file must not break
 *
 * `SESSION_TOOLS` is a positive list and `session-tools.ts` argues at length for
 * why: *"'cannot find it' is the weaker half of 'cannot use it' and not a
 * substitute for it."* A tool that hands back schemas is a way to ask whether a
 * tool exists, so this one asks the same question `server.ts` asks — through
 * {@link ToolContext.granted}, which is that same set handed down — and answers
 * a name it may not describe with the sentence `server.ts` already uses for a
 * name a caller may not call: **`no tool called ${name}`**. Identical for a tool
 * that does not exist and for one that exists and is not theirs, because the
 * difference between those two is exactly what must not be learnable by trying.
 *
 * The index is filtered by the same predicate, so a caller that may use only
 * some tools reads an index of only those.
 */

import { advertiseTool, type ToolSpec } from './catalogue'
import { Refused } from './surface'

/** The canonical id and the wire spelling, in one place because five files name them. */
export const DESCRIBE_ID = 'tools.describe'
export const DESCRIBE_WIRE = 'tools_describe'

/**
 * Most names a describe call may carry at once.
 *
 * Generous — it is more than the number of tools that are ever held behind this
 * one — because the failure it guards against is not a large answer, it is an
 * unbounded loop asking for the same name ten thousand times. A turn that
 * genuinely wants every disclosed schema should be able to get them in one call
 * rather than being pushed into fifteen.
 */
export const MAX_DESCRIBE_NAMES = 20

/**
 * May this caller see this tool at all?
 *
 * The one predicate, exported and used by `server.ts` for both of its handlers
 * and by this tool for its index and its answers. Three callers, one answer: a
 * second copy of this comparison is how listing and calling drift apart, and
 * they must not, because "cannot find it" and "cannot use it" are two halves of
 * one grant.
 *
 * Both spellings are checked because the wire name and the dotted id are two
 * spellings of one tool and a caller chooses which to send.
 */
export function visibleTo(
  granted: ReadonlySet<string> | undefined,
  spec: { id: string; wire: string },
): boolean {
  return granted === undefined || granted.has(spec.id) || granted.has(spec.wire)
}

/** One line of the index: the wire name a caller would send, and what it is for. */
function indexLine(spec: ToolSpec): string {
  return `${spec.wire} — ${spec.index ?? spec.title}`
}

/**
 * The standing description, without the index.
 *
 * Deliberately short. This text is paid on every turn beside the index itself,
 * and everything a model needs in order to use it correctly is two facts: the
 * names below are real tools, and this is how you get their arguments.
 */
const DESCRIBE_DESCRIPTION =
  'Get the full schema for one of the tools listed below. They are real tools you can call; ' +
  'their arguments are fetched here rather than sent on every turn. ' +
  'Ask for the ones you need, then call them.'

/**
 * The index, as it is appended to the description above.
 *
 * Built per listing rather than once, because it has to be the index of what
 * *this* caller may reach. A caller granted six tools must not read a line
 * about a seventh.
 */
export function describeIndex(behind: readonly ToolSpec[]): string {
  return behind.map(indexLine).join('\n')
}

/**
 * The listing that actually crosses to the model, from the tools a caller may see.
 *
 * Takes an already-filtered list, so the filtering happens once at the transport
 * and this function is only ever asked "of these, which are advertised in full".
 * `catalogue-cost.test.ts` measures the result of this function, because this is
 * the payload — measuring the catalogue behind it would be measuring the thing
 * progressive disclosure exists to stop paying for.
 */
export function advertisedCatalogue(visible: readonly ToolSpec[]): ToolSpec[] {
  const behind = visible.filter((spec) => spec.index !== undefined)
  const full = visible.filter((spec) => spec.index === undefined && spec.id !== DESCRIBE_ID)
  if (behind.length === 0) return full
  const describe = visible.find((spec) => spec.id === DESCRIBE_ID)
  /*
   * No describe tool for this caller, so nothing may be hidden from it.
   *
   * Reachable only through a grant that names a disclosed tool without naming
   * this one, which is a mistake rather than a policy — and the safe direction
   * out of it is the loud one. A caller that can *call* `assets.ledger` and
   * cannot find it anywhere has a capability it will never use, which is the
   * dead control this app is repeatedly about; a listing that is briefly over
   * budget is visible in `control.cost()` and in a failing test. So: advertise
   * them in full and let the budget say so.
   */
  if (describe === undefined) return [...full, ...behind]
  return [
    ...full,
    { ...describe, description: `${describe.description}\n\n${describeIndex(behind)}` },
  ]
}

/**
 * Every tool this process serves, with the meta-tool appended.
 *
 * A function rather than a line in `DeckControl`'s constructor because two
 * places need the same list and one of them is the measurement. The closure
 * over `all` is what lets `tools.describe` answer about tools contributed
 * through `extraTools` — which is the whole of tonight's problem, and the
 * reason it is appended to the assembled list rather than declared in
 * `buildCatalogue()`, which takes no arguments and knows about none of them.
 */
export function withDescribe(tools: readonly ToolSpec[]): ToolSpec[] {
  const all: ToolSpec[] = [...tools]
  all.push(describeTool({ catalogue: () => all }))
  return all
}

export interface DescribeToolDeps {
  /** Every tool this process serves, read at call time rather than captured. */
  catalogue(): readonly ToolSpec[]
}

export function describeTool(deps: DescribeToolDeps): ToolSpec {
  return {
    id: DESCRIBE_ID,
    wire: DESCRIBE_WIRE,
    /*
     * `read`, and it is a real read rather than a technicality: it reaches
     * nothing outside this process, changes nothing, and returns text that was
     * already going to be sent to this same model on this same connection. The
     * only reason it is a tool at all is *when* that text is sent.
     */
    tier: 'read',
    title: 'Get a tool’s arguments',
    description: DESCRIBE_DESCRIPTION,
    inputSchema: {
      type: 'object',
      properties: { tools: { type: 'array', items: { type: 'string' } } },
      required: ['tools'],
      additionalProperties: false,
    },
    summary: (args) => {
      const names = asNames(args)
      return names.length === 0 ? 'Describe tools' : `Describe ${names.join(', ')}`
    },
    run: async (args, context) => {
      const names = asNames(args)
      if (names.length === 0) {
        throw new Refused('not-permitted', 'tools is required: name at least one tool to describe')
      }
      if (names.length > MAX_DESCRIBE_NAMES) {
        throw new Refused(
          'not-permitted',
          `describe at most ${MAX_DESCRIBE_NAMES} tools in one call`,
        )
      }
      const catalogue = deps.catalogue()
      const described: Record<string, unknown>[] = []
      const unknown: string[] = []
      for (const name of names) {
        const spec = catalogue.find((entry) => entry.id === name || entry.wire === name)
        /*
         * One branch for both cases, on purpose.
         *
         * A tool that is not in the catalogue and a tool that is in it and not
         * on this caller's grant take the same exit and produce the same
         * sentence. Written as one condition rather than two so that no later
         * edit can make one of them say something the other does not — the
         * wording is `server.ts`'s, and matching it is the point.
         */
        if (spec === undefined || !visibleTo(context.granted, spec)) {
          unknown.push(`no tool called ${name}`)
          continue
        }
        /*
         * The same mapping `tools/list` uses, so a schema fetched here is
         * byte-identical to the one that would have been advertised. A second
         * mapping would be a second answer to "what does the model see", and
         * the whole trade this file makes is that fetching late is the same
         * information as sending early.
         */
        described.push(advertiseTool(spec))
      }
      return {
        value: { tools: described, ...(unknown.length === 0 ? {} : { unknown }) },
        // Counts, not the schemas. The action log is an audit trail and a
        // describe call's payload is text the model was going to be sent anyway.
        summary: { described: described.length, unknown: unknown.length },
      }
    },
  }
}

/**
 * The `tools` argument, as a list of strings.
 *
 * Tolerant of a bare string because a model that has been told "ask for the
 * ones you need" sends one name as often as it sends an array, and refusing
 * that costs a turn to teach it nothing. Anything else in the array is dropped
 * rather than refused — a name that is not a string cannot be a tool, so it
 * lands in `unknown` with everything else that is not a tool.
 */
function asNames(args: Record<string, unknown>): string[] {
  const raw = args['tools']
  if (typeof raw === 'string') return raw === '' ? [] : [raw]
  if (!Array.isArray(raw)) return []
  return raw.filter((entry): entry is string => typeof entry === 'string' && entry !== '')
}
