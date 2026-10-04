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
 *
 * ## By area, once the index itself became the bill (0.16.0)
 *
 * The rule above worked for fifteen tools and then the release that made
 * "everything I can do manually" reachable added a hundred and twenty more, each
 * with an honest one-line index. The lines alone came to ~3,850 tokens and the
 * assembled listing to ~9,250, over `MAX_CATALOGUE_TOKENS` — and
 * `catalogue-cost.test.ts` was passing only because its list left four sources
 * out. The same mistake that file's header records twice, a third time.
 *
 * So the index has two shapes and the size of what is held back picks between
 * them. A caller with a handful of held-back tools — an ordinary session, which
 * holds eight scraping tools — reads them by name, exactly as before: one line
 * each is cheaper than an extra round trip. A caller with more than
 * {@link INLINE_INDEX_MAX} reads **areas**: five lines naming what each covers
 * and how many tools it holds, and `tools.describe {area}` answers with that
 * area's one-liners. Names still answer with schemas. So a turn that wants one
 * tool it has not seen pays two short calls instead of every turn paying for a
 * hundred and thirty-five lines.
 *
 * The security property is unchanged and carried into the new shape: the areas
 * listed, the counts beside them and the lines an area answers with are all
 * built from what this caller may see. An area with nothing in it for this
 * caller is not listed, and asking for it answers **`no area called X`** — the
 * same sentence an area that does not exist gets, from the same branch.
 */

import { advertiseTool, type ToolSpec } from './catalogue'
import { RUN_ID } from './run-tool'
import { Refused } from './surface'
import { BRAND } from '../../shared/brand'

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
 * Most tools held back before the index is given by area instead of by name.
 *
 * Twelve, because that is where the two shapes cost about the same: twelve
 * lines of ~110 characters against five area lines and the extra call a turn
 * then makes. An ordinary session (eight held-back tools) stays on names; the
 * copilot and every access-key caller (over a hundred) get areas.
 */
export const INLINE_INDEX_MAX = 12

/** One area of the catalogue, as the standing description names it. */
export interface ToolArea {
  /** What a caller passes as `area`. One plain word. */
  id: string
  /** What the area covers, for a model choosing between five. */
  covers: string
  /** The tool-id prefixes (the part before the first dot) that belong here. */
  prefixes: readonly string[]
}

/**
 * The areas, and which tool prefixes fall in each.
 *
 * A table here rather than a field on `ToolSpec`, because a hundred and fifty
 * tools in a dozen files written by four lanes would each have to remember it,
 * and the one that forgot would be invisible. A prefix nobody listed still gets
 * an area — its own name — so a tool can never be stranded; and
 * `describe-tool.test.ts` fails the day the assembled catalogue holds a prefix
 * this table does not, which is the prompt to put it where it belongs.
 *
 * Grouped by what a person would be trying to do, not by which lane built the
 * tool: the Store's community shelf is skills, MCP servers and hooks for the
 * agents, so it is under agents even though the browser lane wrote it.
 */
export const TOOL_AREAS: readonly ToolArea[] = [
  {
    id: 'sessions',
    covers:
      'sessions beyond the listed tools (wait for an answer, press keys, read the screen, rename, switch account, ' +
      'held sessions), past conversations, projects, files, git, dev servers, the overview, and Stays Fixed checks ' +
      '(that nothing which already worked has changed)',
    /*
     * `fixed` is Stays Fixed, the regression check on a project's own page — a
     * project tool, so it sits with projects, files and git rather than in an
     * area of its own that a model would have to guess the meaning of.
     */
    prefixes: ['sessions', 'chats', 'projects', 'files', 'git', 'dev', 'dashboard', 'artifacts', 'alerts', 'log', 'tour', 'fixed'],
  },
  {
    id: 'browser',
    covers:
      'the built-in browser beyond the listed verbs: windows, toolbar, downloads, history, profiles, saved logins, ' +
      'site data, imports, extensions, sign-in help, scraping, worker profiles and downloading files',
    prefixes: ['browser', 'assets'],
  },
  {
    id: 'machines',
    covers:
      'other paired computers and their sessions, servers (sites, logs, terminals), who can reach this computer, and GitHub',
    prefixes: ['machines', 'servers', 'remote', 'github'],
  },
  {
    id: 'agents',
    covers:
      'the coding agents, their logins, models and controls, their MCP servers and hooks, routines, usage and cost, ' +
      'dictation, setup and readiness checks, and the community store',
    prefixes: ['agents', 'accounts', 'mcp', 'hooks', 'routines', 'usage', 'voice', 'setup', 'readiness', 'store'],
  },
  {
    /*
     * Its own area rather than a corner of `machines`, added in 0.16.0. A
     * simulator is not another computer and nothing about reaching it is like
     * reaching one; what a model looking for "tap the app" needs is one word
     * that obviously means phones.
     */
    id: 'devices',
    covers:
      'iOS Simulators, Android emulators and USB Android phones on this Mac: list, start, see, tap, swipe, type, ' +
      'buttons, the elements on screen, and what a person marked with Annotate',
    prefixes: ['devices'],
  },
  {
    id: 'app',
    covers:
      `this app itself: version, logs, diagnostics, updates, settings, notifications, ${BRAND.assistant}, clicks in ` +
      'its window, sessions in windows of their own and the monitors, opening links, and what this tool server covers',
    prefixes: ['app', 'settings', 'updates', 'notifications', 'hoot', 'ui', 'windows', 'links', 'tools'],
  },
]

/** The area a tool belongs to. An unlisted prefix is an area of its own name. */
export function areaOf(spec: { id: string }): string {
  const prefix = spec.id.split('.')[0] ?? spec.id
  return TOOL_AREAS.find((area) => area.prefixes.includes(prefix))?.id ?? prefix
}

function areaCovers(id: string): string {
  return TOOL_AREAS.find((area) => area.id === id)?.covers ?? `the ${id} tools`
}

/** The areas a set of held-back tools falls into, in the table's order, each with its count. */
function areasOf(behind: readonly ToolSpec[]): Array<{ id: string; count: number }> {
  const counts = new Map<string, number>()
  for (const spec of behind) counts.set(areaOf(spec), (counts.get(areaOf(spec)) ?? 0) + 1)
  const order = TOOL_AREAS.map((area) => area.id)
  return [...counts]
    .sort(([a], [b]) => {
      const ia = order.indexOf(a)
      const ib = order.indexOf(b)
      return (ia === -1 ? order.length : ia) - (ib === -1 ? order.length : ib) || a.localeCompare(b)
    })
    .map(([id, count]) => ({ id, count }))
}

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
  spec: { id: string; wire: string; aliases?: readonly string[] },
): boolean {
  return (
    granted === undefined ||
    granted.has(spec.id) ||
    granted.has(spec.wire) ||
    // A grant written with a tool's old name still covers it. See `ToolSpec.aliases`.
    (spec.aliases ?? []).some((alias) => granted.has(alias))
  )
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
 * The standing description when the index is given by area.
 *
 * Three facts and no more, because it is paid on every turn: there are many
 * more tools than are listed, they are grouped like this, and this is the order
 * to ask in — area, then names, then the call.
 */
const AREA_DESCRIPTION =
  'Most of this server’s tools are held back to keep this list short, grouped into the areas below. ' +
  'Call this with an area to list what it has, then with the tool names you want to get their arguments, ' +
  'then call them.'

/** The area index, as it is appended to {@link AREA_DESCRIPTION}. */
export function areaIndex(behind: readonly ToolSpec[]): string {
  return areasOf(behind)
    .map(({ id, count }) => `${id} — ${areaCovers(id)} (${count} tools)`)
    .join('\n')
}

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
/**
 * One tool as a given caller's listing treats it, or null when it is not theirs.
 *
 * Two audience rules, applied in one place so the listing and `tools.describe`
 * cannot disagree: a `keys` tool does not exist for anybody but an AI app on a
 * key, and a tool with a `keyIndex` is held back with that line for such an app
 * while staying in full for everybody else. See `ToolSpec.audience`.
 */
export function asListedFor(spec: ToolSpec, keyCaller: boolean): ToolSpec | null {
  if (spec.audience === 'keys' && !keyCaller) return null
  if (keyCaller && spec.keyIndex !== undefined && spec.index === undefined) return { ...spec, index: spec.keyIndex }
  return spec
}

export function advertisedCatalogue(
  visible: readonly ToolSpec[],
  /**
   * Advertise `tools.run` as well. True for an AI app on an access key, which
   * can only call what it is listed; false — the default — for every listing
   * that existed before it, so the copilot's is byte-identical to what
   * `catalogue-cost.test.ts` measured. See `run-tool.ts`.
   */
  options: { run?: boolean } = {},
): ToolSpec[] {
  /*
   * `run` is also "this is an AI app on a key", which is what decides the two
   * audience rules — see `asListedFor`.
   */
  const keyCaller = options.run === true
  const mine = visible.map((spec) => asListedFor(spec, keyCaller)).filter((spec): spec is ToolSpec => spec !== null)
  const behind = mine.filter((spec) => spec.index !== undefined)
  const full = mine.filter(
    (spec) =>
      spec.index === undefined && spec.id !== DESCRIBE_ID && (spec.id !== RUN_ID || options.run === true),
  )
  if (behind.length === 0) return full
  const describe = mine.find((spec) => spec.id === DESCRIBE_ID)
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
  /*
   * One more sentence for a caller that is shown `tools.run`, because a client
   * that can only call listed tools must be told *how* to call these — "then
   * call them" is true for the copilot and a dead end for claude.ai.
   */
  const how = options.run === true ? ' Your client can only call listed tools, so call these through tools_run.' : ''
  const description =
    behind.length > INLINE_INDEX_MAX
      ? `${AREA_DESCRIPTION}${how}\n\n${areaIndex(behind)}`
      : `${describe.description}${how}\n\n${describeIndex(behind)}`
  return [...full, { ...describe, description }]
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
      properties: {
        /*
         * No `enum`, deliberately. The schema is the same object for every
         * caller, so an enum would name every area to a session that may see
         * one — the leak the area index is careful not to make. The areas a
         * caller may ask for are the ones its own description lists.
         */
        area: { type: 'string', description: 'One area from the list below, to see the tools in it.' },
        tools: { type: 'array', items: { type: 'string' }, description: 'Tool names, to get their full arguments.' },
      },
      additionalProperties: false,
    },
    summary: (args) => {
      const names = asNames(args)
      const area = asArea(args)
      if (area !== null && names.length === 0) return `Describe the ${area} tools`
      return names.length === 0 ? 'Describe tools' : `Describe ${names.join(', ')}`
    },
    run: async (args, context) => {
      const names = asNames(args)
      const area = asArea(args)
      if (names.length === 0 && area === null) {
        throw new Refused(
          'not-permitted',
          'name an area to see what it has, or tools to get their arguments',
        )
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

      /*
       * An area: its tools, as one-liners, of what this caller may see.
       *
       * Held-back tools come with their line and tier; tools already in the
       * listing are only named, since their schemas are in front of the model.
       * The meta-tools themselves are left out — describing `tools.describe`
       * inside its own answer is a line that helps nobody.
       *
       * One branch for "no such area" and "nothing in it for you", for the
       * reason the tool branch below gives, and with its wording's shape.
       */
      let areaAnswer: Record<string, unknown> | null = null
      if (area !== null) {
        const keyCaller = context.caller?.kind === 'key'
        const inside = catalogue
          .map((spec) => asListedFor(spec, keyCaller))
          .filter((spec): spec is ToolSpec => spec !== null)
          .filter((spec) => spec.id !== DESCRIBE_ID && areaOf(spec) === area && visibleTo(context.granted, spec))
        if (inside.length === 0) {
          unknown.push(`no area called ${area}`)
        } else {
          areaAnswer = {
            area,
            covers: areaCovers(area),
            // `held`, not `tools`: `tools` is always the schemas a name asked
            // for, so a call naming an area *and* tools gets both, unmixed.
            held: inside
              .filter((spec) => spec.index !== undefined)
              .map((spec) => ({ name: spec.wire, tier: spec.tier, does: spec.index ?? spec.title })),
            alreadyListed: inside.filter((spec) => spec.index === undefined).map((spec) => spec.wire),
          }
        }
      }

      for (const name of names) {
        const found = catalogue.find(
          (entry) => entry.id === name || entry.wire === name || (entry.aliases ?? []).includes(name),
        )
        // A tool for another audience does not exist for this caller.
        const spec = found === undefined ? undefined : (asListedFor(found, context.caller?.kind === 'key') ?? undefined)
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
        value: {
          ...(areaAnswer === null ? {} : areaAnswer),
          ...(names.length === 0 ? {} : { tools: described }),
          ...(unknown.length === 0 ? {} : { unknown }),
        },
        // Counts, not the schemas. The action log is an audit trail and a
        // describe call's payload is text the model was going to be sent anyway.
        summary: {
          ...(area === null ? {} : { area, held: areaAnswer === null ? 0 : (areaAnswer.held as unknown[]).length }),
          described: described.length,
          unknown: unknown.length,
        },
      }
    },
  }
}

/** The `area` argument, trimmed and lower-cased, or null. */
function asArea(args: Record<string, unknown>): string | null {
  const raw = args['area']
  if (typeof raw !== 'string') return null
  const area = raw.trim().toLowerCase()
  return area === '' ? null : area
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
