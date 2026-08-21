import { createHash } from 'node:crypto'
import { createWriteStream, existsSync, mkdirSync, statSync, unlinkSync, renameSync } from 'node:fs'
import { join, resolve, sep } from 'node:path'
import { pipeline } from 'node:stream/promises'
import { Readable } from 'node:stream'
import { digestFile, NO_TRANSFORM_GUARANTEE } from './browser-asset-digest'
import type { LedgerReason, LedgerStore } from './browser-asset-ledger'
import {
  acceptsRendition,
  chooseRendition,
  renditionCandidates,
  type RenditionAttempt,
  type RenditionCandidate,
  type RenditionOptions,
  type RenditionProbeFn,
  type RenditionRule,
} from './browser-asset-rendition'
import { downloadName, freeDownloadPath } from './browser-download-names'
import { cancelBody, type AssetOpen, type AssetResponse } from './browser-asset-session'

/**
 * The half of the pipeline that actually puts a file on the disk.
 *
 * ## What was missing
 *
 * Three modules were built around this one and it was not here.
 * `browser-asset-rendition.ts` answers *which URL you should fetch*.
 * `browser-asset-ledger.ts` answers *whether you already have it*, about a file
 * the caller says it has, at a path the caller supplies.
 * `browser-asset-coverage.ts` compares two numbers. Not one of them opens a
 * socket. Grepping all of it for `net.request`, `will-download`, `downloadURL`
 * and `fetch(` found nothing, which means the advice was complete and the
 * fetching was not built: the run still had to do the one step every loss
 * happened in, by itself, with none of this applying to it.
 *
 * This module is that step, and it is deliberately the *composition* of the
 * three rather than a fourth thing beside them.
 *
 * ## 1. The bytes are the bytes (his item 5)
 *
 *   > *"Never modify downloaded bytes. Ever."*
 *
 * A pass that resized every image before the write cost him 58% of every file in
 * a run, with no original left anywhere. So the body goes from the response into
 * a `.part` file through a two-argument `pipeline` — a source and a sink, with
 * nothing between them — and is renamed into place only once it is whole. That
 * is `browser-downloads.ts`'s shape, which is the one already proved
 * byte-identical against a real socket by `browser-download-bytes.test.ts`, and
 * `browser-asset-fetch.test.ts` proves it again for this path. This file is on
 * the scanned list in `browser-asset-digest.test.ts`, so the *source* is refused
 * the idioms a transform is written in as well.
 *
 * Two things follow from "whole", and both are failures that have been seen:
 *
 *  - a body shorter than the `Content-Length` the server stated is a truncation,
 *    and the `.part` is deleted rather than renamed. A run that renamed it would
 *    have a file of the right name and the wrong length, which the ledger will
 *    then happily record and skip for ever.
 *  - a `.part` never becomes a file on any failing path. There is no branch here
 *    that leaves a partial download under a real name.
 *
 * ## 2. The upgrade falls back for real (his item 6)
 *
 * `chooseRendition` probes the candidates and picks one. A probe is a `HEAD`, or
 * a one-byte `GET`, and a `HEAD` that answered `200` is **not** a promise about
 * the `GET` that follows it — signed URLs sign the method, CDNs answer the two
 * differently, and a candidate can rot between the two requests.
 *
 * So the fallback lives *here*, at fetch time, and not only in the probe: the
 * candidates are walked with real `GET`s, and the original URL is the last one
 * and is always tried. A rewrite rule that 404s costs quality, never the asset.
 * `fetchedUrl` on the result is the URL that actually produced the bytes, and it
 * is what goes into the ledger — so *"why is this one small"* is answerable from
 * the record rather than from a re-run.
 *
 * The order degrades and never climbs. When the probe chose a candidate, the
 * walk starts there and continues *down* the list; the upgrades the probe
 * already refused are not retried, because the probe refused them for reasons a
 * `GET` cannot disprove — chiefly that the server answered `200` with the same
 * small copy. Only when nothing answered the probe at all (`reachable: false`,
 * which is what a server that refuses `HEAD` outright looks like) is the whole
 * list walked.
 *
 * ## 3. The ledger decides, on the bytes (his item 7)
 *
 * Every asset asks {@link LedgerStore.decide} first, and a `skip` is a skip: no
 * request is made. That is the whole value of a resume. What makes it safe is
 * that the ledger is keyed on the URL **and** the digest of the file on disk —
 * his was keyed on the URL alone, recognised all 48,473 assets of a re-download
 * that was happening *because the files were bad*, skipped every one, and exited
 * reporting success. `mode: 'refetch'` does not read the ledger at all.
 *
 * One consequence is worth stating because the alternative is quietly worse:
 * when the ledger has an entry for a URL and has decided to fetch it anyway —
 * the file is missing, the wrong length, the wrong digest — the bytes are
 * written **to the path the entry names**, replacing it. A run that instead
 * wrote `photo (2).jpg` beside it would finish with two files per asset and
 * nothing on disk saying which of them is the good one, which is precisely the
 * state he was trying to get out of. The replacement is still atomic: `.part`
 * first, rename after, so the bad file survives until the good one is complete.
 *
 * ## What this is not
 *
 * Not a crawler, not a queue, not a scheduler — *"the orchestration can live
 * outside"*. {@link fetchAssets} takes a list of URLs and walks it one at a time.
 * One at a time is a decision, not an omission: these requests go out of a
 * profile's own session, carrying the cookies and the clearance that make the
 * site answer at all, and the fastest way to lose those is to open thirty
 * sockets at once from the jar that holds them. Whatever is running the crawl
 * decides how many batches to have in flight.
 */

/* ------------------------------------------------------------------ shape -- */

/**
 * What became of one asset.
 *
 * Four values, which are the four things that can honestly be said, and every
 * one of them is distinguishable in the result rather than inferred from a
 * count:
 *
 *  - `fetched` — bytes landed, from the URL the probe chose.
 *  - `fell-back` — bytes landed, from something lower down the list, because
 *    what was chosen did not answer. The file is real; the quality may not be
 *    what was asked for, and that is the sentence on the row.
 *  - `skipped` — the ledger has it, on disk, at the right length, matching its
 *    digest. Nothing was requested.
 *  - `failed` — nothing landed. `reason` says what went wrong, `attempts` says
 *    it for every URL that was tried.
 */
export type AssetOutcome = 'fetched' | 'fell-back' | 'skipped' | 'failed'

/** One URL, actually requested, and what came back. */
export interface AssetAttempt {
  url: string
  /** The rendition rule behind this URL, or `''` for the original. */
  ruleId: string
  ok: boolean
  status: number | null
  /** Bytes written for this attempt. `null` when nothing was written. */
  bytes: number | null
  /** Why it was refused. Empty when it was accepted. */
  reason: string
}

export interface AssetFetchResult {
  /** What was asked for. The ledger's key, and never rewritten. */
  url: string
  outcome: AssetOutcome
  /** The URL that produced the bytes on disk. `''` when none did. */
  fetchedUrl: string
  /** The rule behind {@link fetchedUrl}, or `''` for the original. */
  ruleId: string
  upgraded: boolean
  /** The bytes came from lower down the list than what was chosen. */
  fellBack: boolean
  /** Where the file is. For a skip, where the ledger says it already is. */
  path: string
  bytes: number
  digest: string
  /** Why it was skipped, or why it failed. Empty when it simply worked. */
  reason: string
  /** One sentence, for a log or a tool result. Always present. */
  line: string
  /** The ledger's own word for its decision. */
  ledgerReason: LedgerReason
  /** The ledger claimed a file and the disk disagreed. See the ledger's header. */
  ledgerWasWrong: boolean
  /** What the probes said, before anything was requested for real. */
  probed: RenditionAttempt[]
  /** What the `GET`s said. The audit trail for the fallback. */
  attempts: AssetAttempt[]
}

export interface AssetFetchTally {
  asked: number
  /** Files written. Includes the ones that fell back. */
  fetched: number
  /** Of {@link fetched}, how many came from a rewrite rule. */
  upgraded: number
  /** Of {@link fetched}, how many came from lower than what was chosen. */
  fellBack: number
  skipped: number
  failed: number
  /** Bytes written by this batch. */
  bytes: number
  /**
   * Of {@link fetched}, how many were fetched because the ledger was wrong.
   *
   * Counted separately for the reason `browser-asset-ledger.ts` gives: a ledger
   * that is confidently wrong is a much worse condition than one that is merely
   * incomplete, and a batch full of these is not a resume.
   */
  ledgerWasWrong: number
}

export interface AssetFetchBatch {
  dir: string
  results: AssetFetchResult[]
  tally: AssetFetchTally
  /** One line summarising the batch, loud when anything is wrong. */
  line: string
  /** Quoted where it is relied on. See `browser-asset-digest.ts`. */
  guarantee: string
}

/* ---------------------------------------------------------------- helpers -- */

/**
 * Where a body is streamed while it is still arriving.
 *
 * Named from the URL's hash rather than from the file's eventual name, for two
 * reasons that both cost a file otherwise: the eventual name is not known until
 * the response headers are read, and two assets in one batch whose URLs end in
 * `photo.jpg` must not share a staging file. A `.part` left behind by a killed
 * process is identifiable — it is the hash of the URL that was in flight.
 */
export function partPathFor(dir: string, url: string): string {
  return join(dir, `${createHash('sha256').update(url).digest('hex').slice(0, 16)}.part`)
}

/** Is `path` inside `dir`? Used before a ledger entry's path is written to. */
export function insideDir(dir: string, path: string): boolean {
  const root = resolve(dir)
  const target = resolve(path)
  return target === root || target.startsWith(root.endsWith(sep) ? root : root + sep)
}

/**
 * The filename to use, from the response and then from the URL.
 *
 * `Content-Disposition` first because it is the name the server actually chose,
 * which for a signed CDN path is often the only real one. Both sources are
 * attacker input and both go through `downloadName`.
 */
export function nameFor(url: string, disposition: string): string {
  const quoted = /filename\*?=(?:UTF-8'')?"?([^";]+)"?/i.exec(disposition)
  if (quoted !== null) {
    let decoded = quoted[1]
    try {
      decoded = decodeURIComponent(decoded)
    } catch {
      // A name with a stray percent in it is a name, not an encoding.
    }
    const named = downloadName(decoded)
    if (named !== 'download') return named
  }
  let last = ''
  try {
    const parsed = new URL(url)
    last = parsed.pathname.split('/').filter((part) => part !== '').pop() ?? ''
    try {
      last = decodeURIComponent(last)
    } catch {
      // As above.
    }
  } catch {
    last = ''
  }
  return downloadName(last)
}

function headerOf(response: AssetResponse, name: string): string {
  return response.headers.get(name) ?? ''
}

function statedLength(response: AssetResponse): number | null {
  const raw = headerOf(response, 'content-length')
  if (raw === '') return null
  const value = Number(raw)
  return Number.isSafeInteger(value) && value >= 0 ? value : null
}

function contentTypeOf(response: AssetResponse): string {
  return headerOf(response, 'content-type').split(';')[0].trim().toLowerCase()
}

function drop(path: string): void {
  try {
    unlinkSync(path)
  } catch {
    // Already gone, or never made. Either way there is nothing to clean up, and
    // failing to tidy is not a reason to lose the result that says what happened.
  }
}

/**
 * Stream a body onto a path, and answer how many bytes landed.
 *
 * The `pipeline` has two arguments — a source and a sink. There is deliberately
 * no third. A transform inserted here is the change that discarded 58% of every
 * image in one of his runs, and `browser-asset-digest.test.ts` scans this file's
 * source for the idioms one is written in.
 */
async function writeBody(body: unknown, path: string): Promise<number> {
  const source =
    body !== null &&
    typeof body === 'object' &&
    typeof (body as { [Symbol.asyncIterator]?: unknown })[Symbol.asyncIterator] === 'function'
      ? (body as AsyncIterable<Uint8Array>)
      : Readable.fromWeb(body as never)
  await pipeline(source, createWriteStream(path))
  try {
    return statSync(path).size
  } catch {
    return 0
  }
}

/* ------------------------------------------------------------- one attempt -- */

interface AttemptOutcome {
  attempt: AssetAttempt
  /** Bytes are at the `.part` path. */
  landed: boolean
  /** The name the server gave, when it gave one. */
  name: string
}

/**
 * Ask one candidate URL for its bytes, into the staging file.
 *
 * Every refusal here is a refusal of *this candidate*, never of the asset: the
 * caller carries on down the list to the original. Which is why nothing in here
 * throws — a socket that was reset is an attempt with a reason on it, and the
 * next candidate is still worth trying.
 */
async function fetchCandidate(input: {
  candidate: RenditionCandidate
  open: AssetOpen
  partPath: string
  minBytes: number
  timeoutMs: number
}): Promise<AttemptOutcome> {
  const { candidate, partPath } = input
  const no = (status: number | null, reason: string, bytes: number | null = null): AttemptOutcome => ({
    attempt: { url: candidate.url, ruleId: candidate.ruleId, ok: false, status, bytes, reason },
    landed: false,
    name: '',
  })

  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), input.timeoutMs)
  timer.unref?.()
  let response: AssetResponse
  try {
    response = await input.open(candidate.url, { method: 'GET', signal: controller.signal })
  } catch (error) {
    clearTimeout(timer)
    return no(null, error instanceof Error ? error.message : 'the request failed')
  }

  /*
   * The status and the content type are judged by `acceptsRendition`, which is
   * the same function the probe stage uses. One judgement, so a server that
   * answers 200 with an HTML error page under a `.jpg` name is refused
   * identically whether it was met by a HEAD or by this GET.
   *
   * `requireLarger` is off here and that is not a weakening: comparing the
   * upgrade against the original is a comparison between two *probes*, it was
   * made before this function was reached, and re-making it here would need a
   * second request for the original of every asset that is about to be fetched.
   */
  const stated = statedLength(response)
  const verdict = acceptsRendition({
    candidateUrl: candidate.url,
    probe: { status: response.status, bytes: stated, contentType: contentTypeOf(response) },
    options: { minBytes: input.minBytes, requireLarger: false },
  })
  if (!verdict.ok) {
    clearTimeout(timer)
    // The body is not wanted and the socket should not be held open for it.
    await cancelBody(response)
    return no(response.status, verdict.reason)
  }
  if (response.body === null || response.body === undefined) {
    clearTimeout(timer)
    return no(response.status, 'the server answered with no body at all')
  }

  let written: number
  try {
    written = await writeBody(response.body, partPath)
  } catch (error) {
    clearTimeout(timer)
    drop(partPath)
    return no(
      response.status,
      `the body stopped part-way — ${error instanceof Error ? error.message : 'unknown reason'}`,
    )
  }
  clearTimeout(timer)

  if (written === 0) {
    drop(partPath)
    return no(response.status, 'the server answered with nothing', 0)
  }
  /*
   * Short of what was promised.
   *
   * A connection that dies late looks exactly like a complete small file once
   * the socket is closed, and the only thing that can tell them apart is the
   * length the server stated. Renaming this would put a truncated file under a
   * real name, which the ledger would then record, verify against itself and
   * skip for ever — the 48,473 again, one layer down.
   */
  if (stated !== null && stated > 0 && written < stated) {
    drop(partPath)
    return no(response.status, `only ${written} bytes of the ${stated} the server promised`, written)
  }
  if (input.minBytes > 0 && written < input.minBytes) {
    drop(partPath)
    return no(
      response.status,
      `${written} bytes is below the ${input.minBytes} this run will accept`,
      written,
    )
  }

  return {
    attempt: {
      url: candidate.url,
      ruleId: candidate.ruleId,
      ok: true,
      status: response.status,
      bytes: written,
      reason: '',
    },
    landed: true,
    name: nameFor(candidate.url, headerOf(response, 'content-disposition')),
  }
}

/* ------------------------------------------------------------- one asset -- */

export interface AssetFetchInput {
  url: string
  dir: string
  rules: readonly RenditionRule[]
  probe: RenditionProbeFn
  open: AssetOpen
  ledger: LedgerStore
  options?: RenditionOptions
  /** What the caller believes the file should hash to. Passed to the ledger. */
  expectDigest?: string
  /** Names this batch has already claimed, so two URLs cannot collide. */
  taken?: Set<string>
  /** Per-request ceiling. A stalled socket must not hold up a run of 60,000. */
  timeoutMs?: number
}

/** Long enough for a large photograph on a slow CDN, short enough to give up. */
export const FETCH_TIMEOUT_MS = 120_000

/**
 * Decide, choose, fetch, verify, record — for one asset.
 *
 * Never throws. Every way this can go wrong is a result with an outcome and a
 * reason on it, because the caller is a loop over sixty thousand of these and an
 * exception out of one of them is a batch that stops in the middle and reports
 * nothing about the part it did.
 */
export async function fetchAsset(input: AssetFetchInput): Promise<AssetFetchResult> {
  const { url, dir, ledger } = input
  const taken = input.taken ?? new Set<string>()
  const options = input.options ?? {}
  const minBytes = options.minBytes ?? 0

  const decision = await ledger.decide(
    url,
    input.expectDigest === undefined ? {} : { expectDigest: input.expectDigest },
  )
  if (decision.action === 'skip') {
    const entry = decision.entry
    return {
      url,
      outcome: 'skipped',
      fetchedUrl: entry?.fetchedUrl ?? '',
      ruleId: entry?.ruleId ?? '',
      upgraded: (entry?.ruleId ?? '') !== '',
      fellBack: false,
      path: entry?.path ?? '',
      bytes: entry?.bytes ?? 0,
      digest: entry?.digest ?? '',
      reason: decision.reason,
      line: decision.line,
      ledgerReason: decision.reason,
      ledgerWasWrong: false,
      probed: [],
      attempts: [],
    }
  }

  const fail = (reason: string, attempts: AssetAttempt[], probed: RenditionAttempt[]): AssetFetchResult => ({
    url,
    outcome: 'failed',
    fetchedUrl: '',
    ruleId: '',
    upgraded: false,
    fellBack: false,
    path: '',
    bytes: 0,
    digest: '',
    reason,
    line: `${url} was not fetched: ${reason}`,
    ledgerReason: decision.reason,
    ledgerWasWrong: decision.ledgerWasWrong,
    probed,
    attempts,
  })

  try {
    mkdirSync(dir, { recursive: true })
  } catch (error) {
    return fail(
      `${dir} could not be written to — ${error instanceof Error ? error.message : 'unknown reason'}`,
      [],
      [],
    )
  }

  const choice = await chooseRendition({ url, rules: input.rules, probe: input.probe, options })
  const candidates = renditionCandidates(url, input.rules)
  /*
   * Where the walk starts. See the header: it degrades and never climbs, so a
   * candidate the probe already refused is not requested again — unless nothing
   * answered the probe at all, which is what a server that refuses `HEAD`
   * outright looks like and is no evidence about any candidate.
   */
  const from = choice.reachable ? Math.max(0, candidates.findIndex((c) => c.url === choice.url)) : 0
  const order = candidates.slice(from)

  const partPath = partPathFor(dir, url)
  const attempts: AssetAttempt[] = []
  let landed: AttemptOutcome | null = null
  for (const candidate of order) {
    const outcome = await fetchCandidate({
      candidate,
      open: input.open,
      partPath,
      minBytes,
      timeoutMs: input.timeoutMs ?? FETCH_TIMEOUT_MS,
    })
    attempts.push(outcome.attempt)
    if (outcome.landed) {
      landed = outcome
      break
    }
  }

  if (landed === null) {
    drop(partPath)
    const why = attempts
      .map((attempt) => `${attempt.ruleId === '' ? 'original' : attempt.ruleId} — ${attempt.reason}`)
      .join('; ')
    return fail(why === '' ? 'there was nothing to try' : why, attempts, choice.attempts)
  }

  /*
   * Where it lands.
   *
   * Over the file the ledger already claims, when there is one inside this
   * folder — see the header for why a second copy beside a bad one is worse than
   * a replacement. Otherwise a free name, which is what stops two assets whose
   * URLs both end in `photo.jpg` becoming one file.
   */
  /*
   * `entryFor` rather than `decision.entry`, and that is not a way round the
   * mode. In `refetch` the decision deliberately carries no entry — the ledger
   * was not consulted about *whether* to fetch — but the previous run's path is
   * still the right place to put the replacement, and a deliberate re-download
   * that left the old bad file beside the new good one would be the worst of
   * both.
   */
  const entry = ledger.entryFor(url)
  const claimed = entry !== null && entry.path !== '' && insideDir(dir, entry.path) ? entry.path : ''
  const finalPath = claimed !== '' ? claimed : freeDownloadPath(dir, landed.name, existsSync, taken)
  taken.add(finalPath)

  try {
    renameSync(partPath, finalPath)
  } catch (error) {
    drop(partPath)
    return fail(
      `the bytes arrived and could not be put at ${finalPath} — ${
        error instanceof Error ? error.message : 'unknown reason'
      }`,
      attempts,
      choice.attempts,
    )
  }

  const digest = await digestFile(finalPath)
  const bytes = landed.attempt.bytes ?? 0
  const won = landed.attempt
  const fellBack = won.url !== choice.url || choice.fellBack

  if (digest === '') {
    /*
     * The file is there and could not be read back to fingerprint it.
     *
     * Not recorded, deliberately. An entry with no digest is an entry the next
     * run skips without anything having checked it, which is the failure this
     * whole round of work is about — so the asset is reported as failed with the
     * file's path in the sentence, and the next run fetches it again.
     */
    const why =
      `the bytes landed at ${finalPath} and could not be read back to fingerprint them, so nothing ` +
      'was written into the ledger — this asset will be fetched again'
    return {
      ...fail(why, attempts, choice.attempts),
      path: finalPath,
      bytes,
      fetchedUrl: won.url,
      ruleId: won.ruleId,
      line: `${url}: ${why}.`,
    }
  }

  ledger.record({
    url,
    fetchedUrl: won.url,
    ruleId: won.ruleId,
    digest,
    bytes,
    path: finalPath,
  })

  const upgraded = won.ruleId !== ''
  return {
    url,
    outcome: fellBack ? 'fell-back' : 'fetched',
    fetchedUrl: won.url,
    ruleId: won.ruleId,
    upgraded,
    fellBack,
    path: finalPath,
    bytes,
    digest,
    reason: '',
    line: upgraded
      ? `Fetched ${bytes} bytes from the ${won.ruleId} rewrite${fellBack ? ', after a better one did not answer' : ''}.`
      : fellBack
        ? `No upgrade held, so the original URL produced the bytes: ${describeRefusals(attempts)}`
        : `Fetched ${bytes} bytes from the original URL.`,
    ledgerReason: decision.reason,
    ledgerWasWrong: decision.ledgerWasWrong,
    probed: choice.attempts,
    attempts,
  }
}

function describeRefusals(attempts: readonly AssetAttempt[]): string {
  const refused = attempts
    .filter((attempt) => !attempt.ok)
    .map((attempt) => `${attempt.ruleId === '' ? 'original' : attempt.ruleId} — ${attempt.reason}`)
  return refused.length === 0 ? 'no rewrite changed this URL.' : refused.join('; ')
}

/* --------------------------------------------------------------- a batch -- */

/**
 * Fetch a list of assets, one at a time, and say honestly what happened to each.
 *
 * The tally is not a substitute for the rows and the rows are not a substitute
 * for the tally: a caller deciding whether to carry on reads the tally, and a
 * person asking why one image is small reads its row.
 */
export async function fetchAssets(input: {
  urls: readonly string[]
  dir: string
  rules: readonly RenditionRule[]
  probe: RenditionProbeFn
  open: AssetOpen
  ledger: LedgerStore
  options?: RenditionOptions
  timeoutMs?: number
}): Promise<AssetFetchBatch> {
  const results: AssetFetchResult[] = []
  const taken = new Set<string>()
  for (const url of input.urls) {
    results.push(
      await fetchAsset({
        url,
        dir: input.dir,
        rules: input.rules,
        probe: input.probe,
        open: input.open,
        ledger: input.ledger,
        taken,
        ...(input.options === undefined ? {} : { options: input.options }),
        ...(input.timeoutMs === undefined ? {} : { timeoutMs: input.timeoutMs }),
      }),
    )
  }
  const tally = tallyOf(results)
  return {
    dir: input.dir,
    results,
    tally,
    line: describeBatch(tally),
    guarantee: NO_TRANSFORM_GUARANTEE,
  }
}

export function tallyOf(results: readonly AssetFetchResult[]): AssetFetchTally {
  const tally: AssetFetchTally = {
    asked: results.length,
    fetched: 0,
    upgraded: 0,
    fellBack: 0,
    skipped: 0,
    failed: 0,
    bytes: 0,
    ledgerWasWrong: 0,
  }
  for (const result of results) {
    if (result.outcome === 'skipped') {
      tally.skipped += 1
      continue
    }
    if (result.outcome === 'failed') {
      tally.failed += 1
      continue
    }
    tally.fetched += 1
    tally.bytes += result.bytes
    if (result.upgraded) tally.upgraded += 1
    if (result.fellBack) tally.fellBack += 1
    if (result.ledgerWasWrong) tally.ledgerWasWrong += 1
  }
  return tally
}

/**
 * One line about the batch, which never reads as success when it was not.
 *
 * The order of the clauses is the order of what a person needs to know: what
 * landed, then what did not, then the one condition that means this run is not
 * the resume it looks like.
 */
export function describeBatch(tally: AssetFetchTally): string {
  const parts = [`${tally.fetched} of ${tally.asked} fetched`]
  if (tally.upgraded > 0) parts.push(`${tally.upgraded} from a rewrite`)
  if (tally.fellBack > 0) parts.push(`${tally.fellBack} fell back to a lower copy`)
  if (tally.skipped > 0) parts.push(`${tally.skipped} already on disk and verified`)
  if (tally.failed > 0) parts.push(`${tally.failed} failed`)
  if (tally.ledgerWasWrong > 0) {
    parts.push(
      `${tally.ledgerWasWrong} were fetched because the ledger claimed a file that was missing or ` +
        'did not match — do not read this batch as a resume',
    )
  }
  return parts.join(', ')
}

/**
 * Why a batch produced no files, in a sentence, or `''` when it produced some.
 *
 * This is the half of `empty-result.ts` that only this module can write. `empty`
 * is the same boolean for a batch where everything was already on disk and a
 * batch where every single request failed — and those two are opposite facts.
 * The reason is what separates them, so it names the cause rather than restating
 * the count, exactly as that module asks.
 */
export function emptyReasonFor(tally: AssetFetchTally): string {
  if (tally.fetched > 0) return ''
  if (tally.asked === 0) return 'No URLs were given, so nothing was fetched.'
  if (tally.failed === 0 && tally.skipped === tally.asked) {
    return (
      `Nothing was fetched because there was nothing to fetch: all ${tally.asked} are already on ` +
      'disk, at the length and digest the ledger recorded. Use mode: refetch if you meant to ' +
      'download them again.'
    )
  }
  if (tally.skipped === 0) {
    return (
      `Nothing was fetched: all ${tally.failed} of them failed. This is not an empty result, it is a ` +
      'failed one — read the reason on each row before treating this run as finished.'
    )
  }
  return (
    `Nothing was fetched: ${tally.failed} failed and ${tally.skipped} were already on disk. The ` +
    'failures are real and are on the rows.'
  )
}
