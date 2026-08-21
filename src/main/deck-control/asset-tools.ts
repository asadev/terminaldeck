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
import {
  emptyReasonFor,
  fetchAssets,
  type AssetFetchResult,
} from '../browser-asset-fetch'
import { openLedger, type LedgerMode, type LedgerStore } from '../browser-asset-ledger'
import {
  chooseRendition,
  readRenditionRules,
  type RenditionProbe,
} from '../browser-asset-rendition'
import { readBlocks } from '../browser-block-watch'
import type { AssetOpen } from '../browser-asset-session'
import { blockShotDir, coveragePath, ledgerPath, runDir } from '../browser-scrape-paths'
import type { JsonSchema, ToolContext, ToolOutput, ToolSpec } from './catalogue'
import { emptySummary, withEmptiness } from './empty-result'
import { Refused, type Tier } from './surface'

/**
 * Five capabilities a scraping run cannot do without, and no crawler.
 *
 * Asad drew the line himself, and it is the reason this file is five tools
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
 *  - **`assets.fetch`** — the one that puts a file on the disk, and the
 *    composition of the first two rather than a fifth thing beside them: the
 *    ledger decides, the rendition rules choose, the bytes land exactly as the
 *    server sent them and the record says which URL produced them. Its absence
 *    is what made the other four advice rather than a pipeline — nothing in this
 *    app fetched an asset, so a run still had to do the one step every loss
 *    happened in, by itself. See `browser-asset-fetch.ts`.
 *
 * ## None of the four can answer nothing quietly
 *
 * Every result here carries `empty` and `emptyReason` from `empty-result.ts` —
 * the shape `browser.network` already uses, not a second one — because three of
 * the four have an answer that is indistinguishable from success while meaning
 * the opposite:
 *
 *  - `assets.ledger` with `op: verify` over a ledger nobody wrote to answers
 *    `{ total: 0, ok: 0, missing: [], corrupt: [] }`. That is the literal shape
 *    of a clean run, and it is what *"did this run work?"* returns after a run
 *    that recorded nothing at all.
 *  - `assets.coverage` answers `unknown` when no total could be read off the
 *    page. Its own description already says *"`unknown` is not success"*; now
 *    the result says it in a field rather than only in prose a caller may not
 *    have been shown.
 *  - `assets.rendition` with nothing reachable hands back the original URL
 *    unverified, by design — but a caller that reads `url` and fetches it must
 *    be able to tell that from a probed, confirmed upgrade.
 *  - `assets.blocks` with an empty folder means either that nothing has been
 *    blocked or that nothing was watching. Those are opposite conclusions and
 *    an empty array is the same in both.
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
 * A **paired device is refused at all five**, which is a narrower rule than it
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
  /*
   * And the list, which is where `assets.fetch` keeps its URLs.
   *
   * A redactor that handled every singular key and not the plural one would
   * write sixty thousand presigned URLs into `actions.jsonl` — each of them a
   * bearer token with a hostname on the front — while looking, in the diff,
   * exactly like the redactor that was already there.
   */
  const list = out.urls
  if (Array.isArray(list)) {
    out.urls = list.map((entry) => (typeof entry === 'string' ? scrubUrl(entry) : entry))
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
  /**
   * The thing that makes a request, bound to one profile's cookie jar.
   *
   * Injected for the same reason `probe` is — this module is exercised against a
   * real HTTP server with no Electron under it — and it is the *same jar* the
   * probe uses, which is not a coincidence to be tidied away:
   * `browser-asset-session.ts` is the single place that answers "which session",
   * precisely so a `HEAD` that says `200` and a `GET` that says `403` cannot
   * happen.
   *
   * Throws for an id that is not a profile, rather than answering with a
   * cookie-less request. The prechecks below call it for that reason alone, so
   * the refusal arrives before anything runs.
   */
  open(profileId: string | null): AssetOpen
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

const FETCH_SCHEMA: JsonSchema = {
  type: 'object',
  properties: {
    runId: { type: 'string', description: 'Names this run\u2019s ledger and folder. The same id resumes it.' },
    dir: {
      type: 'string',
      description: 'An absolute folder to write the files into. It is made if it is not there.',
    },
    urls: {
      type: 'array',
      items: { type: 'string' },
      description:
        'The asset URLs as the page gave them, best first. Each is fetched in turn; the orchestration ' +
        'of how many batches to run belongs outside this app.',
    },
    rules: {
      type: 'array',
      items: RULE_SCHEMA,
      description:
        'Rewrites to try for a bigger copy. The upgraded URL is fetched first and the original is ' +
        'always the last candidate and is always tried, so a bad rule costs quality, never the asset.',
    },
    mode: {
      type: 'string',
      enum: ['resume', 'refetch'],
      description:
        'resume skips an asset only when the file is on disk, the right length, and hashes to the ' +
        'digest recorded for it. refetch does not read the ledger at all. Default resume.',
    },
    profileId: {
      type: 'string',
      description:
        'Fetch from this browser profile\u2019s cookie jar \u2014 the same jar the page and the probe use. ' +
        'Needed for anything behind a login or a signed cookie. Omit for a public CDN.',
    },
    minBytes: { type: 'number', description: 'Refuse anything smaller than this many bytes.' },
    requireLarger: {
      type: 'boolean',
      description:
        'Probe the original too and refuse an upgrade that is not larger. Default true. Turning it ' +
        'off is how a server quietly re-serving the small copy gets recorded as an upgrade.',
    },
  },
  required: ['runId', 'dir', 'urls'],
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
   * Refused for a paired device, at all five. See the header.
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
   * Refuse a profile id that is not one of ours, before anything runs.
   *
   * By asking the very thing that would make the request. `deps.open` throws for
   * an id that names no partition rather than answering with a cookie-less
   * client — and a cookie-less request is the one wrong answer here that
   * *succeeds*: the run fetches the logged-out copy of every asset, writes them
   * all to disk, and reports success. A precheck that re-implemented the rule
   * would be a second answer to the question `browser-asset-session.ts` exists
   * to answer once.
   *
   * Both `assets.rendition` and `assets.fetch` call it, because they name the
   * same jar and a probe that used a different one from the fetch is the
   * `HEAD 200` / `GET 403` run nobody can diagnose.
   */
  const mayFetchAs = (args: Record<string, unknown>): void => {
    const profileId = optStr(args, 'profileId')
    try {
      deps.open(profileId)
    } catch (error) {
      throw new Refused(
        'not-permitted',
        error instanceof Error ? error.message : 'that profile could not be used',
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
    const key = `${mode}\0${path}`
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
      mayFetchAs(args)
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
        value: withEmptiness(choice, {
          /*
           * Reachability, not the URL, is what this call produced.
           *
           * `chooseRendition` never answers "nothing" — the worst case is the
           * original URL with `reachable: false`, which is deliberate and is
           * still the right thing to hand back, because a `HEAD` that failed is
           * not proof the asset is missing. But a caller cannot be left to
           * notice the difference between *that* URL and one that was probed and
           * confirmed by reading a boolean four fields down, so it is `empty`
           * too: nothing here was verified.
           */
          produced: choice.reachable ? 1 : 0,
          whenNone:
            'no candidate answered — not the rewrites and not the original, so nothing about this URL ' +
            'has been confirmed. It is still returned and still worth fetching. The host may refuse ' +
            'HEAD requests, or the asset may be behind a login, in which case pass profileId so the ' +
            'probe uses that jar. See attempts for what each candidate said.',
        }),
        summary: {
          upgraded: choice.upgraded,
          fellBack: choice.fellBack,
          reachable: choice.reachable,
          ruleId: choice.ruleId,
          tried: choice.attempts.length,
          ...emptySummary(choice.reachable ? 1 : 0),
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
          value: withEmptiness(
            { ...decision, mode, ledger: store.path },
            // A decision is always produced, and both of its values are a
            // finding: `skip` is the answer that cost him 48,473 assets, so it
            // is emphatically not "nothing happened". It carries its own reason.
            { produced: 1, whenNone: '' },
          ),
          summary: {
            action: decision.action,
            reason: decision.reason,
            ledgerWasWrong: decision.ledgerWasWrong,
            ...emptySummary(1),
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
          value: withEmptiness(
            { entry, ledger: store.path, guarantee: NO_TRANSFORM_GUARANTEE },
            // The file was stat'd and hashed above or this line was not reached.
            { produced: 1, whenNone: '' },
          ),
          summary: { url: scrubUrl(url), bytes, digest, ...emptySummary(1) },
        }
      }

      if (op === 'verify') {
        const verdict = await store.verify()
        return {
          value: withEmptiness(
            { ...verdict, ledger: store.path },
            {
              /*
               * The one that matters most in this file.
               *
               * `verify` is what *"did this run work?"* means, and over a ledger
               * with no entries it answers `total: 0, ok: 0, missing: [],
               * corrupt: []` — which is byte-for-byte the shape of a run where
               * everything was fine. Three scripts reported success while doing
               * nothing this week; this is where the fourth would have.
               */
              produced: verdict.total,
              whenNone:
                'this ledger has no entries, so nothing was checked and this is not a statement about ' +
                `any file. If assets have been downloaded for run ${runId}, they were never recorded — ` +
                'call this tool with op record after each fetch, or the resume will re-download ' +
                'everything and the verify will go on saying nothing.',
            },
          ),
          summary: {
            total: verdict.total,
            ok: verdict.ok,
            missing: verdict.missing.length,
            corrupt: verdict.corrupt.length,
            ...emptySummary(verdict.total),
          },
        }
      }

      const tally = store.tally()
      /*
       * Everything the ledger knows about, read or written. `known` is what was
       * on disk at open and `recorded` is what this process has added since, so
       * a ledger that has just written its first entry is not empty even though
       * it was when it was opened.
       */
      const holds = tally.known + tally.recorded
      return {
        value: withEmptiness(
          {
            ...tally,
            mode,
            line: store.summary(),
            ledger: store.path,
            folder: runDir(deps.userData(), runId),
          },
          {
            produced: holds,
            whenNone:
              `nothing has ever been recorded into the ${runId} ledger, so these counts are not a ` +
              'picture of a run — they are the picture of a ledger nobody wrote to. A run that is ' +
              'fetching assets and not calling op record gets exactly this, and will re-download all ' +
              'of them next time.',
          },
        ),
        summary: { ...tally, mode, ...emptySummary(holds) },
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
          value: withEmptiness(
            { ...summary, checks, log: path },
            {
              produced: checks.length,
              /*
               * `coverageSummary` already answers `ok: false` with this sentence
               * for an empty run, which is the right verdict and the wrong place
               * to leave it alone: `ok` is one boolean among five counters that
               * are all zero, and zero shorts reads like good news.
               */
              whenNone:
                `no coverage check was made in run ${runId}, so nothing here says it captured ` +
                'everything it should have. Call this tool with op check, the page text and how many ' +
                'items you got, once per page — a run with no checks is how 7% of a dataset shipped ' +
                'as a complete one.',
            },
          ),
          summary: {
            ok: summary.ok,
            short: summary.short,
            unknown: summary.unknown,
            over: summary.over,
            complete: summary.complete,
            ...emptySummary(checks.length),
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
      /*
       * The comparison is the product, and there is no comparison without a
       * stated total. `captured` came from the caller; on its own it is a number
       * this tool was told, not a number it checked.
       */
      const compared = check.stated === null ? 0 : 1
      return {
        value: withEmptiness(
          {
            ...check,
            statedFrom: given !== null ? 'given' : read === null ? 'nothing' : 'text',
            reading: read,
            recorded: written,
            log: path,
          },
          {
            produced: compared,
            whenNone:
              'nothing on this page stated a total, so there was nothing to compare against and this ' +
              'page cannot be called complete — the verdict is unknown, which is not a pass. Give ' +
              'pattern, a regular expression whose first group is the total, or stated when you ' +
              'already know it from somewhere the page does not print.',
          },
        ),
        summary: {
          verdict: check.verdict,
          stated: check.stated,
          captured: check.captured,
          missing: check.missing,
          recorded: written,
          ...emptySummary(compared),
        },
      }
    },
  }

  /**
   * How many URLs one call may carry.
   *
   * A cap rather than "as many as you like", because the result carries a row
   * per asset and a caller that handed this sixty thousand would get back a
   * result nothing can read and a call that runs for an hour with no way to see
   * inside it. Batches are the unit; *"the orchestration can live outside"*.
   */
  const MAX_FETCH_URLS = 200

  const readUrlList = (args: Record<string, unknown>): string[] => {
    const raw = args.urls
    if (!Array.isArray(raw)) throw new Refused('not-permitted', 'urls must be a list of addresses')
    if (raw.length === 0) {
      throw new Refused('not-permitted', 'urls is empty, so there is nothing to fetch')
    }
    if (raw.length > MAX_FETCH_URLS) {
      throw new Refused(
        'not-permitted',
        `that is more than ${MAX_FETCH_URLS} urls in one call — split it into batches, which is what ` +
          'the run id is for',
      )
    }
    const out: string[] = []
    for (const entry of raw) {
      if (typeof entry !== 'string' || !/^https?:\/\//i.test(entry)) {
        throw new Refused('not-permitted', 'every url must be an http or https address')
      }
      out.push(entry)
    }
    return out
  }

  const fetchTool: ToolSpec = {
    id: 'assets.fetch',
    wire: 'assets_fetch',
    tier: 'act',
    title: 'Fetch assets to disk, byte for byte',
    description:
      'Downloads the assets you name into a folder, through the browser profile you name, so the ' +
      'cookies and the clearance are the ones this browser already has. The bytes on disk are exactly ' +
      'the bytes the server sent — nothing rewrites them, a body shorter than the length promised is ' +
      'thrown away, and no partial download is left under a real name. A rewrite rule is tried first ' +
      'and the original is always the last candidate and is always tried, so a bad rule costs quality ' +
      'and never the asset; the row says which URL produced the bytes. The ledger skips on the digest ' +
      'of the file on disk, never on the URL alone. Every asset comes back fetched, fell-back, ' +
      'skipped or failed, with a reason.',
    inputSchema: FETCH_SCHEMA,
    redactArgs: scrubUrlArgs,
    precheck: (args, context) => {
      mayUse(context, 'assets.fetch')
      str(args, 'runId')
      const dir = str(args, 'dir')
      if (!isAbsolute(dir)) {
        throw new Refused(
          'not-permitted',
          'dir must be absolute. A relative one would be resolved against a working directory nobody ' +
            'chose, and sixty thousand files would land somewhere nobody could find them.',
        )
      }
      readUrlList(args)
      const mode = optStr(args, 'mode')
      if (mode !== null && mode !== 'resume' && mode !== 'refetch') {
        throw new Refused('not-permitted', 'mode must be resume or refetch')
      }
      try {
        readRenditionRules(args.rules)
      } catch (error) {
        throw new Refused(
          'not-permitted',
          error instanceof Error ? error.message : 'those rules could not be read',
        )
      }
      mayFetchAs(args)
    },
    summary: (args) => {
      const urls = Array.isArray(args.urls) ? args.urls.length : 0
      const mode = optStr(args, 'mode') ?? 'resume'
      return `Fetch ${urls} asset${urls === 1 ? '' : 's'} into ${optStr(args, 'dir') ?? '?'} (${mode})`
    },
    run: async (args): Promise<ToolOutput> => {
      const runId = str(args, 'runId')
      const dir = str(args, 'dir')
      const urls = readUrlList(args)
      const rules = readRenditionRules(args.rules)
      const mode: LedgerMode = optStr(args, 'mode') === 'refetch' ? 'refetch' : 'resume'
      const profileId = optStr(args, 'profileId')
      const minBytes = optNum(args, 'minBytes')
      const store = ledgerFor(runId, mode)

      const batch = await fetchAssets({
        urls,
        dir,
        rules,
        // The same jar for the probe and for the fetch. See `deps.open`.
        probe: (candidate) => deps.probe(candidate, profileId === null ? {} : { profileId }),
        open: deps.open(profileId),
        ledger: store,
        options: {
          ...(minBytes === null ? {} : { minBytes: Math.max(0, Math.trunc(minBytes)) }),
          ...(args.requireLarger === undefined ? {} : { requireLarger: args.requireLarger === true }),
        },
      })

      /*
       * `empty` and `emptyReason`, from `empty-result.ts` rather than a second
       * shape invented here.
       *
       * `produced` is the number of files written, which is what this call is
       * *for*: a batch where every asset was already on disk and a batch where
       * every request failed are both `empty: true`, and the reason is what
       * separates them — one is a finished resume, the other is a run that got
       * nothing and must not be read as finished. `emptyReasonFor` writes that
       * sentence, because only the tally knows which it was.
       */
      return {
        value: withEmptiness(
          {
            runId,
            mode,
            dir: batch.dir,
            ledger: store.path,
            folder: runDir(deps.userData(), runId),
            guarantee: batch.guarantee,
            line: batch.line,
            tally: batch.tally,
            results: batch.results.map((result: AssetFetchResult) => ({
              url: result.url,
              outcome: result.outcome,
              fetchedUrl: result.fetchedUrl,
              ruleId: result.ruleId,
              path: result.path,
              bytes: result.bytes,
              digest: result.digest,
              reason: result.reason,
              line: result.line,
              ledgerWasWrong: result.ledgerWasWrong,
              attempts: result.attempts,
              probed: result.probed,
            })),
          },
          { produced: batch.tally.fetched, whenNone: emptyReasonFor(batch.tally) },
        ),
        // Counts only. The log is an audit trail, not a second copy of the run.
        summary: { ...batch.tally, mode, dir },
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
      const caught = readBlocks(dir)
      const all = caught
        .filter((shot) => since === null || shot.at >= since)
        .sort((left, right) => right.at - left.at)
      const shots = all.slice(0, limit)
      /*
       * Two opposite readings of the same empty array, and the caller has to be
       * handed both. "Nothing has blocked us" is the good one. "Nothing was
       * watching" is the one that ends with a run whose failures were never
       * photographed — and by then the challenge that caused them has rotated
       * and cannot be photographed at all.
       *
       * Composed here, not inside the call below, so `since` narrowing an
       * otherwise-full folder to nothing says so. `caught` is the read that
       * already happened; this branch adds no second walk of the directory.
       */
      const foundNothing =
        since === null
          ? 'no page has been photographed refusing us. Either nothing has been blocked, or nothing ' +
            'has been driven through this browser since the app started — an empty folder does not ' +
            'tell the two apart.'
          : `no page has been photographed refusing us since ${new Date(since).toISOString()}. ` +
            (caught.length > 0
              ? `There are ${caught.length} older ones: drop since to see them.`
              : 'There are none at all in this folder.')
      return {
        value: withEmptiness(
          {
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
          { produced: all.length, whenNone: foundNothing },
        ),
        summary: { total: all.length, listed: shots.length, ...emptySummary(all.length) },
      }
    },
  }

  return [renditionTool, ledgerTool, fetchTool, coverageTool, blocksTool]
}

export { ASSET_TOOL_NAMES } from './asset-tool-names'
