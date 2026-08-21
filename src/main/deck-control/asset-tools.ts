import { statSync } from 'node:fs'
import { isAbsolute } from 'node:path'
import {
  digestFile,
  NO_TRANSFORM_GUARANTEE,
} from '../browser-asset-digest'
import {
  compareCoverage,
  coverageSummary,
  readCoverage,
  recordCoverage,
  statedTotal,
  type CoverageCheck,
} from '../browser-asset-coverage'
import { openLedger, type LedgerMode, type LedgerStore } from '../browser-asset-ledger'
import {
  chooseRendition,
  readRenditionRules,
  type RenditionProbe,
} from '../browser-asset-rendition'
import { readBlocks } from '../browser-block-watch'
import { blockShotDir, coveragePath, ledgerPath, runDir } from '../browser-scrape-paths'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * Four capabilities a scraping run cannot do without, and no crawler.
 *
 * Asad drew the line himself, and it is the reason this file is four tools
 * rather than forty:
 *
 * > *"Don't build a full scraping framework inside a terminal app. The browser
 * > should expose these capabilities cleanly; the orchestration can live
 * > outside."*
 *
 * So there is no queue here, no scheduler, no politeness delay and no notion of
 * a "site". What is here is the four things his own pipeline did not have, each
 * of which cost him a measured amount of data:
 *
 *  - **`assets.rendition`** — 62,000 images captured at 498px when the 1920px
 *    original was one word away in the URL. Rewrite rules, and a fallback to the
 *    original that cannot be restructured away.
 *  - **`assets.ledger`** — 48,473 assets skipped, during a re-download that was
 *    happening *because the files were bad*, by a resume ledger keyed on the
 *    URL. This one is keyed on the bytes.
 *  - **`assets.coverage`** — 7% of a dataset shipped as complete, because
 *    nothing compared what was captured against the total the page itself
 *    printed.
 *  - **`assets.blocks`** — the pictures the browser took by itself of the pages
 *    that refused it, which is the half of *"you cannot debug a block page you
 *    didn't capture"* that a tool can offer. The capturing is not a tool and
 *    must not be: by the time an agent has decided it was blocked, the challenge
 *    has rotated. See `browser-block-watch.ts`.
 *
 * ## Why they come through `extraTools`
 *
 * The same reason `browser-tools.ts` gives: a feature that wants to give an
 * agent a capability reaches it *through* the dispatcher rather than beside it,
 * so it is tiered, prechecked, escalated, budgeted, gated and logged like
 * everything in `catalogue.ts`. Nothing here re-implements any of that.
 *
 * ## Who may call them
 *
 * The person at this machine, the copilot, and an ordinary session — the same
 * set the browser verbs went to on 2026-08-21, and for the same sentence:
 * *"driving other browsers should be for all of the sessions"*. A run that can
 * open pages and cannot tell whether it captured all of them is the dead half of
 * the feature.
 *
 * A **paired device is refused at all four**, which is a narrower rule than it
 * looks. These tools read files by path, write into this app's own folders and
 * make requests out of this machine's browser session; the device that would be
 * calling them is on the far side of a relay and has none of that context. A
 * remote `act` grant is a real thing somebody might hand out (`surface.ts`), and
 * this must not ride in on it.
 */

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

function optNum(args: Record<string, unknown>, key: string): number | null {
  const value = args[key]
  if (value === undefined || value === null) return null
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Refused('not-permitted', `${key} must be a number`)
  }
  return value
}

function httpUrl(args: Record<string, unknown>, key: string): string {
  const value = str(args, key)
  if (!/^https?:\/\//i.test(value)) {
    throw new Refused('not-permitted', `${key} must be an http or https address`)
  }
  return value
}

/**
 * Query parameters that are credentials, blanked before anything is written down.
 *
 * `scrubArgs` in `action-log.ts` redacts by **key name**, which is exactly right
 * for an argument called `token` and no use at all here: the argument is called
 * `url`, and the credential is inside it. A presigned S3 or CloudFront URL is a
 * bearer token with a hostname on the front — anybody holding the log line can
 * fetch the object until it expires.
 *
 * The path and the host survive, because those are the whole diagnostic value of
 * having the URL in the log at all.
 */
const CREDENTIAL_PARAMS =
  /^(?:x-amz-signature|x-amz-security-token|x-amz-credential|signature|sig|token|access_token|key|apikey|api_key|password|policy|expires|hmac|auth)$/i

export function scrubUrl(raw: string): string {
  let url: URL
  try {
    url = new URL(raw)
  } catch {
    return raw
  }
  let changed = false
  for (const name of [...url.searchParams.keys()]) {
    if (CREDENTIAL_PARAMS.test(name)) {
      url.searchParams.set(name, '…')
      changed = true
    }
  }
  return changed ? url.toString() : raw
}

function scrubUrlArgs(args: Record<string, unknown>): Record<string, unknown> {
  const out = { ...args }
  for (const key of ['url', 'fetchedUrl', 'pageUrl']) {
    const value = out[key]
    if (typeof value === 'string') out[key] = scrubUrl(value)
  }
  return out
}

/* ------------------------------------------------------------------- deps -- */

export interface AssetToolsDeps {
  /** Where this install keeps its own files. `app.getPath('userData')`. */
  userData(): string
  /**
   * Ask a URL what it is, without downloading it.
   *
   * Injected rather than imported so this module can be exercised with no
   * network and no Electron — which is the only way to test the part that
   * matters, which is what happens when an upgraded URL does *not* answer.
   */
  probe(url: string, options: { profileId?: string }): Promise<RenditionProbe | null>
  now?(): number
}

/* ------------------------------------------------------------- the schemas -- */

const RULE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    id: { type: 'string', description: 'What to record when this rule is the one that won.' },
    match: { type: 'string', description: 'A regular expression, tested against the whole URL.' },
    replace: { type: 'string', description: 'The replacement, with $1-style back-references.' },
    flags: { type: 'string', description: 'Regular-expression flags. Use g when the size appears twice.' },
  },
  required: ['id', 'match', 'replace'],
  additionalProperties: false,
}

const RENDITION_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    url: { type: 'string', description: 'The asset URL as the page gave it.' },
    rules: {
      type: 'array',
      items: RULE_SCHEMA,
      description:
        'Rewrites to try, best first. Each is applied to the original URL; when there is more than one, ' +
        'all of them applied together is tried first as well.',
    },
    minBytes: { type: 'number', description: 'Refuse an upgrade smaller than this many bytes.' },
    requireLarger: {
      type: 'boolean',
      description:
        'Probe the original too and refuse an upgrade that is not larger. Default true. Turning it off ' +
        'is how a server quietly re-serving the small copy gets recorded as an upgrade.',
    },
    profileId: {
      type: 'string',
      description: 'Probe from this browser profile’s cookie jar. Needed for anything behind a login.',
    },
  },
  required: ['url'],
  additionalProperties: false,
}

const LEDGER_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    runId: { type: 'string', description: 'Names this run’s ledger. The same id resumes it.' },
    op: {
      type: 'string',
      enum: ['decide', 'record', 'verify', 'summary'],
      description:
        'decide: should this URL be fetched? record: write down one that was. verify: check every ' +
        'recorded file against its digest. summary: the counts so far.',
    },
    mode: {
      type: 'string',
      enum: ['resume', 'refetch'],
      description:
        'resume consults the ledger. refetch does not read it at all, for a deliberate re-download. ' +
        'Default resume.',
    },
    url: { type: 'string', description: 'For decide and record: the URL that was asked for.' },
    path: { type: 'string', description: 'For record: the absolute path the file was written to.' },
    fetchedUrl: { type: 'string', description: 'For record: what was actually fetched, if not url.' },
    ruleId: { type: 'string', description: 'For record: the rendition rule that won, if any.' },
    expectDigest: {
      type: 'string',
      description:
        'For decide: what this run believes the file should hash to. A mismatch is a fetch even when ' +
        'the file on disk is internally consistent.',
    },
  },
  required: ['runId', 'op'],
  additionalProperties: false,
}

const COVERAGE_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    runId: { type: 'string' },
    op: {
      type: 'string',
      enum: ['check', 'summary'],
      description: 'check: compare one page. summary: every check this run recorded. Default check.',
    },
    captured: { type: 'number', description: 'How many items this run actually got from the page.' },
    text: {
      type: 'string',
      description:
        'Text from the page, from browser.read. The page’s own stated total is read out of this.',
    },
    pattern: {
      type: 'string',
      description:
        'A regular expression whose first group is the stated total. Give one whenever you can — ' +
        'without it only generic shapes are tried, and two that disagree produce no answer at all.',
    },
    flags: { type: 'string' },
    stated: {
      type: 'number',
      description: 'The total, when you already know it. Used instead of reading text.',
    },
    tolerance: { type: 'number', description: 'How many items short is still complete. Default 0.' },
    what: { type: 'string', description: 'What was being counted, for the record.' },
    pageUrl: { type: 'string', description: 'The page this is about, for the record.' },
  },
  required: ['runId'],
  additionalProperties: false,
}

const BLOCKS_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    limit: { type: 'number', description: 'How many, newest first. Default 20.' },
    since: { type: 'number', description: 'Only blocks captured after this epoch millisecond.' },
  },
  additionalProperties: false,
}

/* --------------------------------------------------------------- the tools -- */

export function assetTools(deps: AssetToolsDeps): ToolSpec[] {
  const now = deps.now ?? Date.now

  /**
   * Refused for a paired device, at all four. See the header.
   *
   * Not gated on `attended`, and that is the one difference from the browser
   * verbs. Driving a page needs somebody there because it moves a window on
   * somebody's screen; checking whether a file on disk matches its digest does
   * not, and a scraping run at 03:00 is exactly when these matter most.
   */
  const mayUse = (context: ToolContext, tool: string): void => {
    if (context.caller.kind === 'remote') {
      throw new Refused(
        'not-granted',
        `${tool} works on files and folders on this machine, so it only runs for something on it. ` +
          'A paired device cannot call it.',
      )
    }
  }

  /**
   * One open ledger per run, kept for the life of the process.
   *
   * A ledger is tens of thousands of lines and every `decide` would otherwise
   * re-read and re-parse the whole file. Keyed by path *and* mode because
   * changing the mode changes what the store does with what it read, and a
   * cached `resume` store answering a `refetch` call would be the exact silent
   * skip this whole tool exists to stop.
   */
  const ledgers = new Map<string, LedgerStore>()
  const ledgerFor = (runId: string, mode: LedgerMode): LedgerStore => {
    const path = ledgerPath(deps.userData(), runId)
    const key = `${mode} ${path}`
    const held = ledgers.get(key)
    if (held) return held
    const store = openLedger(path, { mode, now })
    ledgers.set(key, store)
    return store
  }

  const renditionTool: ToolSpec = {
    id: 'assets.rendition',
    wire: 'assets_rendition',
    tier: 'act',
    title: 'Find the biggest copy of an asset',
    description:
      'Sites serve the same file at several sizes, usually one path segment or one query parameter ' +
      'apart. Give the URL the page printed and the rewrites worth trying, and this answers with the ' +
      'URL to actually fetch. Every candidate is probed; anything that 404s, answers with a page ' +
      'instead of a file, or comes back no bigger than the original is refused, and the original URL ' +
      'is always the last candidate and is always tried. A bad rewrite therefore costs you quality, ' +
      'never the asset. `attempts` says what was tried and why each one was refused.',
    index:
      'Given the URL a page printed, probe rewrites to find the biggest copy of that image or file that really exists.',
    inputSchema: RENDITION_SCHEMA,
    redactArgs: scrubUrlArgs,
    precheck: (args, context) => {
      mayUse(context, 'assets.rendition')
      httpUrl(args, 'url')
      try {
        readRenditionRules(args.rules)
      } catch (error) {
        throw new Refused(
          'not-permitted',
          error instanceof Error ? error.message : 'those rules could not be read',
        )
      }
    },
    summary: (args) => `Find the best rendition of ${scrubUrl(optStr(args, 'url') ?? '?')}`,
    run: async (args): Promise<ToolOutput> => {
      const url = httpUrl(args, 'url')
      const rules = readRenditionRules(args.rules)
      const profileId = optStr(args, 'profileId')
      const minBytes = optNum(args, 'minBytes')
      const choice = await chooseRendition({
        url,
        rules,
        probe: (candidate) =>
          deps.probe(candidate, profileId === null ? {} : { profileId }),
        options: {
          ...(minBytes === null ? {} : { minBytes: Math.max(0, Math.trunc(minBytes)) }),
          ...(args.requireLarger === undefined ? {} : { requireLarger: args.requireLarger === true }),
        },
      })
      return {
        value: choice,
        summary: {
          upgraded: choice.upgraded,
          fellBack: choice.fellBack,
          reachable: choice.reachable,
          ruleId: choice.ruleId,
          tried: choice.attempts.length,
        },
      }
    },
  }

  const ledgerTool: ToolSpec = {
    id: 'assets.ledger',
    wire: 'assets_ledger',
    tier: 'read',
    title: 'Resume ledger, keyed on the bytes',
    description:
      'Ask whether an asset is already downloaded, and write down the ones that are. `decide` says ' +
      'skip only when the file is still on disk, is the length recorded for it, and hashes to the ' +
      'digest recorded for it — a ledger keyed on the URL alone answers "you asked for this once", ' +
      'which is not the question during a re-download that is happening because the files were bad. ' +
      '`record` hashes the file itself; it never takes a digest from you. `mode: refetch` does not ' +
      'read the ledger at all. `verify` checks every recorded file and is what "did this run work?" ' +
      'means.',
    index:
      'Ask whether an asset is already downloaded, intact and the right length, and record the ones that are. Resume or verify a download run.',
    inputSchema: LEDGER_SCHEMA,
    redactArgs: scrubUrlArgs,
    /*
     * `record` writes a file, so it is an act; the other three read. Escalation
     * is only ever upwards — `control.ts` takes the higher of this and `tier` —
     * so this can tighten `record` and cannot loosen anything.
     */
    escalate: (args): Tier => (args.op === 'record' ? 'act' : 'read'),
    precheck: (args, context) => {
      mayUse(context, 'assets.ledger')
      str(args, 'runId')
      const op = str(args, 'op')
      if (!['decide', 'record', 'verify', 'summary'].includes(op)) {
        throw new Refused('not-permitted', 'op must be decide, record, verify or summary')
      }
      const mode = optStr(args, 'mode')
      if (mode !== null && mode !== 'resume' && mode !== 'refetch') {
        throw new Refused('not-permitted', 'mode must be resume or refetch')
      }
      if (op === 'decide' || op === 'record') str(args, 'url')
      if (op === 'record') {
        const path = str(args, 'path')
        if (!isAbsolute(path)) {
          throw new Refused(
            'not-permitted',
            'path must be absolute. A relative one would be resolved against a working directory ' +
              'nobody chose, and the ledger would record a file that is not where it says it is.',
          )
        }
      }
    },
    summary: (args) => {
      const op = optStr(args, 'op') ?? 'summary'
      const runId = optStr(args, 'runId') ?? '?'
      if (op === 'decide') return `Ask the ${runId} ledger about ${scrubUrl(optStr(args, 'url') ?? '?')}`
      if (op === 'record') return `Write ${scrubUrl(optStr(args, 'url') ?? '?')} into the ${runId} ledger`
      if (op === 'verify') return `Check every file the ${runId} ledger claims`
      return `Read the ${runId} ledger's counts`
    },
    run: async (args): Promise<ToolOutput> => {
      const runId = str(args, 'runId')
      const op = str(args, 'op')
      const mode: LedgerMode = optStr(args, 'mode') === 'refetch' ? 'refetch' : 'resume'
      const store = ledgerFor(runId, mode)

      if (op === 'decide') {
        const url = str(args, 'url')
        const expectDigest = optStr(args, 'expectDigest')
        const decision = await store.decide(
          url,
          expectDigest === null ? {} : { expectDigest },
        )
        return {
          value: { ...decision, mode, ledger: store.path },
          summary: {
            action: decision.action,
            reason: decision.reason,
            ledgerWasWrong: decision.ledgerWasWrong,
          },
        }
      }

      if (op === 'record') {
        const url = str(args, 'url')
        const path = str(args, 'path')
        /*
         * The size and the digest come from the file, never from the caller.
         *
         * A ledger that believed a digest it was handed would be a ledger that
         * skips whatever the caller says it may skip, which is the thing this
         * whole tool exists to stop. The one honest source is the bytes.
         */
        let bytes: number
        try {
          const info = statSync(path)
          if (!info.isFile()) throw new Error('that is not a file')
          bytes = info.size
        } catch (error) {
          throw new Refused(
            'not-permitted',
            `there is no file at ${path} to record — ${
              error instanceof Error ? error.message : 'unknown reason'
            }`,
          )
        }
        const digest = await digestFile(path)
        if (digest === '') {
          throw new Refused(
            'not-permitted',
            `${path} could not be read to fingerprint it, so it is not being written into the ledger. ` +
              'An entry with no digest is an entry that would be skipped on the next run without ' +
              'anything having checked it.',
          )
        }
        const entry = store.record({
          url,
          fetchedUrl: optStr(args, 'fetchedUrl') ?? url,
          ruleId: optStr(args, 'ruleId') ?? '',
          digest,
          bytes,
          path,
        })
        return {
          value: { entry, ledger: store.path, guarantee: NO_TRANSFORM_GUARANTEE },
          summary: { url: scrubUrl(url), bytes, digest },
        }
      }

      if (op === 'verify') {
        const verdict = await store.verify()
        return {
          value: { ...verdict, ledger: store.path },
          summary: {
            total: verdict.total,
            ok: verdict.ok,
            missing: verdict.missing.length,
            corrupt: verdict.corrupt.length,
          },
        }
      }

      const tally = store.tally()
      return {
        value: { ...tally, mode, line: store.summary(), ledger: store.path, folder: runDir(deps.userData(), runId) },
        summary: { ...tally, mode },
      }
    },
  }

  const coverageTool: ToolSpec = {
    id: 'assets.coverage',
    wire: 'assets_coverage',
    tier: 'act',
    title: 'Compare what you captured against what the page says exists',
    description:
      'Pages state their own totals — "showing 12 of 340". Give this the page text and how many items ' +
      'you actually got, and it says complete, short, over, or unknown, and writes the answer into the ' +
      'run so it can be read at the end. `unknown` — nothing on the page stated a total — is not ' +
      'success: it means this page cannot be called complete. Give `pattern` whenever you can; ' +
      'without one only generic shapes are tried and two that disagree deliberately produce no answer.',
    index:
      'Compare how many items you captured against the total the page itself states, and record complete, short or unknown.',
    inputSchema: COVERAGE_SCHEMA,
    redactArgs: scrubUrlArgs,
    precheck: (args, context) => {
      mayUse(context, 'assets.coverage')
      str(args, 'runId')
      const op = optStr(args, 'op') ?? 'check'
      if (op !== 'check' && op !== 'summary') {
        throw new Refused('not-permitted', 'op must be check or summary')
      }
      if (op === 'check') {
        const captured = optNum(args, 'captured')
        if (captured === null) {
          throw new Refused('not-permitted', 'captured is required — it is half of the comparison')
        }
        if (captured < 0) throw new Refused('not-permitted', 'captured cannot be negative')
        if (optStr(args, 'text') === null && optNum(args, 'stated') === null) {
          throw new Refused(
            'not-permitted',
            'give either text from the page, so the stated total can be read out of it, or stated, ' +
              'when you already know it. Without one of the two there is nothing to compare against.',
          )
        }
      }
    },
    summary: (args) =>
      (optStr(args, 'op') ?? 'check') === 'summary'
        ? `Read every coverage check in ${optStr(args, 'runId') ?? '?'}`
        : `Check ${optNum(args, 'captured') ?? '?'} captured against what the page states`,
    run: async (args): Promise<ToolOutput> => {
      const runId = str(args, 'runId')
      const path = coveragePath(deps.userData(), runId)
      const op = optStr(args, 'op') ?? 'check'

      if (op === 'summary') {
        const checks = readCoverage(path)
        const summary = coverageSummary(checks)
        return {
          value: { ...summary, checks, log: path },
          summary: {
            ok: summary.ok,
            short: summary.short,
            unknown: summary.unknown,
            over: summary.over,
            complete: summary.complete,
          },
        }
      }

      const captured = optNum(args, 'captured') ?? 0
      const given = optNum(args, 'stated')
      const text = optStr(args, 'text')
      const pattern = optStr(args, 'pattern')
      const flags = optStr(args, 'flags')

      /*
       * A stated total the caller gave wins over one read out of the text.
       *
       * They should agree, and when they do not it is because the caller knows
       * something the prose does not say — a total from an API response, a count
       * from a previous page. Reading the text anyway and reporting both is what
       * makes that disagreement visible instead of silently resolved.
       */
      const read =
        text === null
          ? null
          : statedTotal(text, {
              ...(pattern === null ? {} : { pattern }),
              ...(flags === null ? {} : { flags }),
            })
      const stated = given !== null ? Math.trunc(given) : read?.total ?? null

      const check: CoverageCheck = compareCoverage({
        stated,
        captured,
        ...(optNum(args, 'tolerance') === null ? {} : { tolerance: optNum(args, 'tolerance') as number }),
        ...(optStr(args, 'what') === null ? {} : { what: optStr(args, 'what') as string }),
        ...(optStr(args, 'pageUrl') === null ? {} : { url: scrubUrl(optStr(args, 'pageUrl') as string) }),
        now: now(),
      })
      const written = recordCoverage(path, check)
      return {
        value: {
          ...check,
          statedFrom: given !== null ? 'given' : read === null ? 'nothing' : 'text',
          reading: read,
          recorded: written,
          log: path,
        },
        summary: {
          verdict: check.verdict,
          stated: check.stated,
          captured: check.captured,
          missing: check.missing,
          recorded: written,
        },
      }
    },
  }

  const blocksTool: ToolSpec = {
    id: 'assets.blocks',
    wire: 'assets_blocks',
    tier: 'read',
    title: 'The pages that refused us, with pictures',
    description:
      'The browser photographs a page that blocks it at the moment it happens — a 403, a 429, a ' +
      'challenge, a navigation that ended somewhere unexpected — because by the time anything could ' +
      'be asked to take that picture the page has changed. This lists what it caught: the address, ' +
      'the status, which signal fired, and the path to the screenshot and to the evidence beside it.',
    index:
      'The pages that refused this browser — a 403, a 429, a challenge — with the screenshot taken at the moment it happened.',
    inputSchema: BLOCKS_SCHEMA,
    precheck: (_args, context) => mayUse(context, 'assets.blocks'),
    summary: () => 'List the block pages the browser photographed',
    run: async (args): Promise<ToolOutput> => {
      const dir = blockShotDir(deps.userData())
      const since = optNum(args, 'since')
      const limitRaw = optNum(args, 'limit')
      const limit = limitRaw === null ? 20 : Math.min(200, Math.max(1, Math.trunc(limitRaw)))
      const all = readBlocks(dir)
        .filter((shot) => since === null || shot.at >= since)
        .sort((left, right) => right.at - left.at)
      const shots = all.slice(0, limit)
      return {
        value: {
          folder: dir,
          total: all.length,
          shots: shots.map((shot) => ({
            at: shot.at,
            url: scrubUrl(shot.evidence.finalUrl || shot.evidence.requestedUrl),
            httpStatus: shot.evidence.httpStatus,
            title: shot.evidence.title,
            signals: shot.verdict.signals,
            screenshot: shot.path,
            evidence: shot.sidecar,
            note: shot.note,
          })),
        },
        summary: { total: all.length, listed: shots.length },
      }
    },
  }

  return [renditionTool, ledgerTool, coverageTool, blocksTool]
}

export { ASSET_TOOL_NAMES } from './asset-tool-names'
