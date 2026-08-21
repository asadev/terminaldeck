import type { BrowserDrive } from '../browser-driver'
import {
  DEFAULT_MAX_BODY_BYTES,
  DEFAULT_MAX_ENTRIES,
  DEFAULT_MAX_TOTAL_BYTES,
  MAX_MAX_BODY_BYTES,
  MAX_MAX_ENTRIES,
  MAX_MAX_TOTAL_BYTES,
  type CaptureBounds,
} from '../browser-capture-store'
import {
  describeRules,
  interceptedKinds,
  readFetchRules,
  RESOURCE_KINDS,
} from '../browser-fetch-rules'
import {
  asTool,
  boundOf,
  mayDrive,
  TARGET_PROPERTIES,
  whereOf,
} from './browser-tools'
import type { JsonSchema, ToolOutput, ToolSpec } from './catalogue'
import { emptySummary, withEmptiness } from './empty-result'
import { Refused } from './surface'

/**
 * `browser.network` — arm a page for harvesting, and say honestly what it did.
 *
 * ## Why one tool and not three
 *
 * Because it is one capability. A page is armed for a harvest in a single act:
 * answer its images cheaply *and* record the JSON it fetches, then read it, then
 * stop and collect. Splitting that into `browser.rules` and `browser.capture`
 * would be two calls that are never made apart, two schemas on every turn, and
 * two ways to end up half-armed — a page recording nothing while the caller
 * believes it is.
 *
 * The tool count is also a real budget: `catalogue.ts` caps it at twenty for a
 * reason it states plainly — *"past twenty tools the problem is not the tokens,
 * it is that a model choosing between twenty things chooses worse"* — and the
 * shipped list is already over. Contributing one tool to it rather than three is
 * part of the design, not a compression of it.
 *
 * ## What each action must never be able to do
 *
 * **Return an empty success.** See `empty-result.ts` for the numbers behind
 * that rule. Concretely, here:
 *
 *  - `start` that would arm nothing is refused, not performed. A call with no
 *    rules and `capture: false` asks for a page that behaves exactly as it did;
 *    answering `armed: true` to it would be a control that does nothing.
 *  - `stop` with nothing armed is refused, and that refusal is deliberately
 *    *not* the same as a run that captured nothing. "There was nothing to stop"
 *    and "the run saw no traffic" send a caller in opposite directions.
 *  - Every result carries `empty` and, when it is true, a sentence saying what
 *    produced nothing and what would change it.
 *  - A `stop` whose bounds discarded anything carries `incomplete: true` and a
 *    `shortfall` naming which bound and how many. A capture with holes says so.
 */

/* --------------------------------------------------------------- the schema -- */

const NETWORK_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    action: { type: 'string', enum: ['start', 'status', 'stop'] },
    rules: { type: 'object' },
    capture: { type: 'boolean' },
    limits: { type: 'object' },
    ...TARGET_PROPERTIES,
  },
  required: ['action'],
  additionalProperties: false,
}

/* -------------------------------------------------------------- the reading -- */

type Action = 'start' | 'status' | 'stop'

function actionOf(args: Record<string, unknown>): Action {
  const raw = args.action
  if (raw === 'start' || raw === 'status' || raw === 'stop') return raw
  throw new Refused('not-permitted', 'action must be one of: start, status, stop')
}

/** Kinds whose bodies may be kept. The seven, plus the page's own document. */
const BODY_KINDS: readonly string[] = [...RESOURCE_KINDS, 'document']

interface Limits {
  bounds: CaptureBounds
  bodyKinds: Set<string>
}

/**
 * Read `limits`, refusing anything it does not understand.
 *
 * Nothing is clamped silently and nothing is ignored. A number outside the
 * range is refused with both ends named, because a bound quietly reduced to
 * something else is a caller who believes their 64 MB budget is in force while
 * a 2 MB one drops their data — which is the same failure as a resize that
 * ran before the write, in a new place.
 */
function readLimits(raw: unknown): Limits {
  const limits: Limits = {
    bounds: {
      maxBodyBytes: DEFAULT_MAX_BODY_BYTES,
      maxTotalBytes: DEFAULT_MAX_TOTAL_BYTES,
      maxEntries: DEFAULT_MAX_ENTRIES,
    },
    bodyKinds: new Set<string>(),
  }
  if (raw === undefined || raw === null) return limits
  if (typeof raw !== 'object' || Array.isArray(raw)) {
    throw new Refused('not-permitted', 'limits must be an object')
  }
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    switch (key) {
      case 'maxBodyBytes':
        limits.bounds.maxBodyBytes = whole(key, value, 1_024, MAX_MAX_BODY_BYTES)
        break
      case 'maxTotalBytes':
        limits.bounds.maxTotalBytes = whole(key, value, 1_024, MAX_MAX_TOTAL_BYTES)
        break
      case 'maxEntries':
        limits.bounds.maxEntries = whole(key, value, 1, MAX_MAX_ENTRIES)
        break
      case 'bodyKinds': {
        if (!Array.isArray(value)) {
          throw new Refused('not-permitted', `limits.bodyKinds must be a list of: ${BODY_KINDS.join(', ')}`)
        }
        for (const kind of value) {
          const name = typeof kind === 'string' ? kind.toLowerCase() : ''
          if (!BODY_KINDS.includes(name)) {
            throw new Refused(
              'not-permitted',
              `${String(kind)} is not a kind whose bodies can be kept. Use one of: ${BODY_KINDS.join(', ')}.`,
            )
          }
          limits.bodyKinds.add(name)
        }
        break
      }
      default:
        throw new Refused(
          'not-permitted',
          `${key} is not one of the limits this takes. It takes: bodyKinds, maxBodyBytes, maxTotalBytes, maxEntries.`,
        )
    }
  }
  return limits
}

function whole(key: string, value: unknown, min: number, max: number): number {
  if (typeof value !== 'number' || !Number.isFinite(value) || !Number.isInteger(value)) {
    throw new Refused('not-permitted', `limits.${key} must be a whole number`)
  }
  if (value < min || value > max) {
    throw new Refused('not-permitted', `limits.${key} must be between ${min} and ${max}`)
  }
  return value
}

/** Rules off the call, with both kinds of near-miss named rather than dropped. */
function rulesOf(args: Record<string, unknown>): ReturnType<typeof readFetchRules> {
  const raw = args.rules
  if (raw !== undefined && raw !== null && (typeof raw !== 'object' || Array.isArray(raw))) {
    throw new Refused('not-permitted', 'rules must be an object of kind → allow | block | cheap')
  }
  const read = readFetchRules(raw)
  if (read.unknownKinds.length > 0) {
    throw new Refused(
      'not-permitted',
      `${read.unknownKinds.join(', ')} ${read.unknownKinds.length === 1 ? 'is not a resource kind' : 'are not resource kinds'} ` +
        `a rule can name. It takes: ${RESOURCE_KINDS.join(', ')}.`,
    )
  }
  if (read.badActions.length > 0) {
    throw new Refused(
      'not-permitted',
      `${read.badActions.join(', ')} — a rule's value must be allow, block or cheap.`,
    )
  }
  return read
}

function capturing(args: Record<string, unknown>): boolean {
  return args.capture === undefined ? true : args.capture === true
}

/* ---------------------------------------------------------------- the tool -- */

export function browserNetworkTool(drive: BrowserDrive): ToolSpec {
  return {
    id: 'browser.network',
    wire: 'browser_network',
    /*
     * `act`, on the same reasoning as every other browser verb.
     *
     * It changes how one page loads and writes files into the app's own data
     * directory. It changes nothing out on the internet — a cheaply-answered
     * request never reaches the network at all — so it is not `alter`; and it
     * plainly does something to a page the person can see, so it is not `read`.
     */
    tier: 'act',
    title: 'Harvest',
    /*
     * Every word here is charged on every turn — see `MAX_CATALOGUE_TOKENS`,
     * which the shipped list sits just under. What survived the trimming is the
     * part a model cannot work out for itself: that `cheap` exists and why it
     * beats blocking, and that the valuable data is in the background requests
     * rather than in the HTML. The result shapes explain themselves at the point
     * of use, so they are not described here.
     */
    description:
      'Arm a page for harvesting. `rules` — image, media, font, stylesheet, script, xhr, fetch → allow, ' +
      'block or cheap — answers a request cheaply rather than blocking it, so lazy-loading still fires ' +
      'and the real URLs still appear. `capture` (default true) writes background XHR/fetch responses to ' +
      'disk; the data is rarely in the HTML. `limits` caps what is kept.',
    index:
      'Arm an attached page to harvest: block or cheapen request types so lazy-loading still fires, and write background XHR/fetch responses to disk.',
    inputSchema: NETWORK_SCHEMA,
    precheck: (args, context) => {
      mayDrive(context, 'browser.network')
      const action = actionOf(args)
      boundOf(args, context)
      if (action !== 'start') return
      const read = rulesOf(args)
      readLimits(args.limits)
      if (interceptedKinds(read.rules).length === 0 && !capturing(args)) {
        /*
         * Refused rather than performed, and this is the whole of item 8 in one
         * branch. A start with every rule left at `allow` and `capture: false`
         * asks for a page that behaves exactly as it already does — so
         * answering `armed: true` would be a control that reports working and
         * does nothing, which is the failure this round exists to end.
         */
        throw new Refused(
          'not-permitted',
          'that would arm nothing: no rule is set to block or cheap and capture is off. Set a rule, or ' +
            'leave capture on.',
        )
      }
    },
    summary: (args, context) => {
      const action = args.action === 'start' || args.action === 'stop' ? args.action : 'status'
      const where = whereOf(args, context)
      if (action !== 'start') return `${action === 'stop' ? 'Stop' : 'Check'} harvesting on ${where}`
      const read = readFetchRules(args.rules)
      return (
        `Arm ${where} for harvesting — rules ${describeRules(read.rules)}` +
        `${capturing(args) ? ', capturing background responses' : ''}`
      )
    },
    run: async (args, context): Promise<ToolOutput> =>
      asTool(async () => {
        const target = boundOf(args, context)?.target ?? null
        const where = target?.name ?? null
        switch (actionOf(args)) {
          case 'start': {
            const read = rulesOf(args)
            const limits = readLimits(args.limits)
            const capture = capturing(args)
            const armed = await drive.armNetwork(
              { rules: read.rules, capture, bodyKinds: limits.bodyKinds, bounds: limits.bounds },
              target,
            )
            const kinds = interceptedKinds(read.rules)
            return {
              value: withEmptiness(
                {
                  armed: true,
                  window: armed.window,
                  rules: armed.rules,
                  intercepting: kinds,
                  capturing: capture,
                  /*
                   * The folder is on the result, not only in a log.
                   *
                   * *"the orchestration can live outside"* — so whatever is
                   * running the crawl needs the path to the manifest as a
                   * value it can act on, the moment the page is armed, rather
                   * than after a stop it may never reach.
                   */
                  dir: armed.dir,
                  manifest: armed.manifest,
                  /*
                   * A previous run on this page was stopped to make room for
                   * this one, and its summary comes back rather than being
                   * dropped. A caller that armed twice by mistake still gets
                   * everything the first run captured.
                   */
                  previous: armed.previous,
                },
                {
                  produced: kinds.length + (capture ? 1 : 0),
                  // Unreachable while the precheck stands, and stated anyway:
                  // the day somebody widens that rule, this is what the caller
                  // is told instead of a silent success.
                  whenNone: 'nothing was armed — no rule blocks or cheapens anything and capture is off',
                },
              ),
              summary: {
                action: 'start',
                ...(where === null ? {} : { window: where }),
                rules: describeRules(read.rules),
                capturing: capture,
              },
            }
          }
          case 'status': {
            const status = drive.networkStatus(target)
            if (status === null) {
              return {
                value: withEmptiness(
                  { armed: false, window: where },
                  {
                    produced: 0,
                    whenNone:
                      'nothing is armed on this page. browser.network with action start arms it.',
                  },
                ),
                summary: { action: 'status', armed: false, ...emptySummary(0) },
              }
            }
            const seen = status.counts.paused + (status.captured?.entries ?? 0)
            return {
              value: withEmptiness(
                { window: where, ...status },
                {
                  produced: seen,
                  whenNone:
                    'armed, and nothing has matched yet — no request has been intercepted and no ' +
                    'background response has been seen. The page may not have loaded anything since.',
                },
              ),
              summary: {
                action: 'status',
                armed: status.armed,
                suspended: status.suspended,
                paused: status.counts.paused,
                captured: status.captured?.entries ?? 0,
                ...emptySummary(seen),
              },
            }
          }
          case 'stop': {
            const status = await drive.disarmNetwork(target)
            if (status === null) {
              /*
               * A refusal, not an empty result, and the distinction is the
               * point. "There was nothing to stop" means the arming never
               * happened — a different call was made, or on a different window —
               * and a caller told that should go back and look. "The run
               * captured nothing" means it was armed and the page was quiet.
               * One empty object for both would merge them.
               */
              throw new Refused(
                'not-permitted',
                'nothing is armed on this page, so there is nothing to stop. Arm it first with action start.',
              )
            }
            const captured = status.capture
            const seen = status.counts.paused + (captured?.entries ?? 0)
            const shortfall = [
              captured?.shortfall ?? '',
              status.counts.stuck > 0
                ? `${status.counts.stuck} paused requests could not be answered, so the page may still be waiting on them`
                : '',
              status.dropped > 0
                ? `${status.dropped} requests were never recorded because too many were open at once`
                : '',
            ]
              .filter((part) => part !== '')
              .join('; ')
            return {
              value: withEmptiness(
                {
                  window: where,
                  ...status,
                  /*
                   * Lifted out of the capture summary to the top of the result.
                   *
                   * A bound that dropped something is the one field a caller
                   * must not be able to miss, and a reader that stops at the
                   * first level of an object is the ordinary reader.
                   */
                  incomplete: (captured?.incomplete ?? false) || shortfall !== '',
                  shortfall,
                },
                {
                  produced: seen,
                  whenNone:
                    'armed, and it saw nothing: no request matched the rules and no background response ' +
                    'was recorded. Either the page loaded nothing after it was armed, or its data does ' +
                    'not come over XHR or fetch.',
                },
              ),
              summary: {
                action: 'stop',
                ...(where === null ? {} : { window: where }),
                paused: status.counts.paused,
                cheap: status.counts.cheap,
                blocked: status.counts.blocked,
                captured: captured?.entries ?? 0,
                bodies: captured?.bodies ?? 0,
                incomplete: (captured?.incomplete ?? false) || shortfall !== '',
                ...emptySummary(seen),
              },
            }
          }
        }
      }),
  }
}
