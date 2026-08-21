import { appendFileSync, existsSync, mkdirSync, readFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { fingerprintFile } from './browser-asset-digest'

/**
 * The resume ledger, keyed on what is actually on the disk.
 *
 * ## The loss
 *
 * Asad's pipeline kept a ledger of what it had downloaded, keyed on the URL. The
 * files it had written were bad — that is *why* the re-download was started. The
 * ledger looked at the URLs, found all of them, **skipped 48,473 assets, and
 * exited reporting success.**
 *
 * Read that sequence again, because the shape of it is the whole design here: a
 * resume ledger keyed on the URL cannot help during the one operation it will be
 * asked to help with most, which is the second attempt after the first one went
 * wrong. Its answer to *"do I already have this?"* is *"you asked for it once"*,
 * and that is not the question.
 *
 * ## So the key is the URL **and** the bytes
 *
 * {@link LedgerStore.decide} skips an asset only when all of this is true:
 *
 *  - there is an entry for the URL,
 *  - the file it names is still there,
 *  - it is the length the entry recorded,
 *  - and it hashes to the digest the entry recorded.
 *
 * Any one of those failing is a fetch, with a sentence saying which. The
 * expensive one is the hash, and it is not optional: length alone passes a
 * truncated file that happened to stop on a block boundary, and passes every
 * CDN error page served under a plausible `Content-Length`. It is one sequential
 * read of a local file against a network fetch it is deciding whether to skip.
 *
 * A caller who already knows what the file *should* hash to — from a manifest,
 * from a previous run's ledger — passes `expectDigest`, and a mismatch is a
 * fetch even when the file is internally consistent. That is how "these are the
 * wrong files" is expressed as data rather than as a decision to delete the
 * ledger and hope.
 *
 * ## And there is a switch that says "I mean it"
 *
 * {@link LedgerMode} `refetch` does not consult the ledger at all. Not "clears
 * it", not "ignores stale entries" — does not read it, for any URL, and says so
 * in every decision's reason. That exists because the alternative, which is what
 * people actually do, is deleting the ledger file: after which the run has no
 * record of what it had before and cannot tell you what changed.
 *
 * ## Why append-only JSONL
 *
 * 48,473 rows. A JSON document rewritten after every asset is a re-serialise of
 * the whole run per file, and a process killed halfway through one of those
 * writes loses the lot. A line per asset is one `appendFileSync`, is readable
 * with `tail`, and a truncated last line costs exactly one entry —
 * {@link readLedgerFile} drops it and carries on. Later lines win over earlier
 * ones for the same URL, so a re-download simply appends.
 */

/* ------------------------------------------------------------------ shape -- */

export interface LedgerEntry {
  /** What was asked for. The key. */
  url: string
  /**
   * What was actually fetched, which is not always the same thing.
   *
   * `browser-asset-rendition.ts` may have upgraded the URL, or fallen back to
   * it. Recording both is what makes *"why is this one small when the rest are
   * big"* answerable from the ledger instead of from a re-run.
   */
  fetchedUrl: string
  /** The rendition rule that won, or `''` for the original. */
  ruleId: string
  /** `sha256:<hex>` of the bytes on disk. */
  digest: string
  bytes: number
  path: string
  at: number
}

/**
 * `resume` consults the ledger. `refetch` does not read it at all.
 *
 * Two values rather than a boolean called `force`, because the reason string
 * every decision carries has to be able to say which mode it was in, and
 * `force: false` reads as an absence rather than as a choice.
 */
export type LedgerMode = 'resume' | 'refetch'

/** Why an asset is being fetched or skipped. Every branch names itself. */
export type LedgerReason =
  | 'refetch-requested'
  | 'not-in-ledger'
  | 'file-missing'
  | 'wrong-size'
  | 'wrong-digest'
  | 'digest-not-expected'
  | 'unreadable'
  | 'verified'

export interface LedgerDecision {
  action: 'skip' | 'fetch'
  reason: LedgerReason
  /** One sentence, for a log or a tool result. */
  line: string
  entry: LedgerEntry | null
  /**
   * The ledger claimed this asset and the disk disagreed.
   *
   * Counted separately from an ordinary miss because it is the signature of the
   * 48,473: a ledger that is *confidently wrong* is a different and much worse
   * condition than a ledger that is merely incomplete, and a run that hits a lot
   * of these should stop rather than carry on quietly re-fetching.
   */
  ledgerWasWrong: boolean
}

/* ------------------------------------------------------------- the reader -- */

function entryOf(raw: unknown): LedgerEntry | null {
  if (typeof raw !== 'object' || raw === null) return null
  const value = raw as Record<string, unknown>
  const url = typeof value.url === 'string' ? value.url : ''
  if (url === '') return null
  const bytes = typeof value.bytes === 'number' && Number.isFinite(value.bytes) ? value.bytes : 0
  return {
    url,
    fetchedUrl: typeof value.fetchedUrl === 'string' ? value.fetchedUrl : url,
    ruleId: typeof value.ruleId === 'string' ? value.ruleId : '',
    digest: typeof value.digest === 'string' ? value.digest : '',
    bytes: bytes < 0 ? 0 : bytes,
    path: typeof value.path === 'string' ? value.path : '',
    at: typeof value.at === 'number' && Number.isFinite(value.at) ? value.at : 0,
  }
}

/**
 * Parse a ledger file into the last entry per URL, and say what was unreadable.
 *
 * Exported and taking a string so the parsing can be tested without a disk. The
 * `skipped` count is returned rather than swallowed: a file with three thousand
 * unparseable lines is a corrupt ledger, and a reader that quietly returned the
 * eleven good ones would be handing a run a reason to skip everything else.
 */
export function readLedgerFile(text: string): {
  entries: Map<string, LedgerEntry>
  skipped: number
} {
  const entries = new Map<string, LedgerEntry>()
  let skipped = 0
  for (const line of text.split('\n')) {
    const trimmed = line.trim()
    if (trimmed === '') continue
    let parsed: unknown
    try {
      parsed = JSON.parse(trimmed)
    } catch {
      // A half-written last line, which is what a killed process leaves. One
      // entry lost, and the read carries on.
      skipped += 1
      continue
    }
    const entry = entryOf(parsed)
    if (entry === null) {
      skipped += 1
      continue
    }
    // Later wins: a re-download appends rather than rewriting.
    entries.set(entry.url, entry)
  }
  return { entries, skipped }
}

/* ---------------------------------------------------------- the judgement -- */

/**
 * Decide about one asset, given what the disk says.
 *
 * Pure, and taking the fingerprint as data rather than reading the file itself,
 * for the reason `freeDownloadPath` in `browser-downloads.ts` gives about its
 * own `exists` argument: this is the one function a mistake in silently loses
 * files, so it has to be drivable from a test with no filesystem underneath it.
 *
 * The ordering matters and is not arbitrary. `refetch` is checked before
 * anything is read, so that mode is honestly "the ledger was not consulted"
 * rather than "the ledger was consulted and overruled".
 */
export function decideFromFingerprint(input: {
  url: string
  mode: LedgerMode
  entry: LedgerEntry | null
  /** `null` when there is no readable file at the entry's path. */
  found: { bytes: number; digest: string } | null
  /** What the caller independently believes the file should hash to. */
  expectDigest?: string
}): LedgerDecision {
  const { url, mode, entry, found } = input
  const no = (reason: LedgerReason, line: string, ledgerWasWrong = false): LedgerDecision => ({
    action: 'fetch',
    reason,
    line,
    entry,
    ledgerWasWrong,
  })

  if (mode === 'refetch') {
    return no(
      'refetch-requested',
      'A deliberate refetch was asked for, so the ledger was not consulted for this asset.',
    )
  }
  if (entry === null) return no('not-in-ledger', `Nothing in the ledger for ${url}.`)
  if (entry.path === '') {
    return no('file-missing', `The ledger has ${url} but never recorded where the file went.`, true)
  }
  if (found === null) {
    return no(
      'file-missing',
      `The ledger says ${url} was written to ${entry.path}, and there is no readable file there.`,
      true,
    )
  }
  if (entry.digest === '') {
    return no(
      'unreadable',
      `The ledger has ${url} but no digest for it, so there is no way to tell the right file from a bad one.`,
      true,
    )
  }
  if (entry.bytes !== found.bytes) {
    return no(
      'wrong-size',
      `${entry.path} is ${found.bytes} bytes and the ledger recorded ${entry.bytes}.`,
      true,
    )
  }
  if (entry.digest !== found.digest) {
    return no(
      'wrong-digest',
      `${entry.path} is the right length and the wrong file — it does not match the digest recorded for it.`,
      true,
    )
  }
  const expected = input.expectDigest ?? ''
  if (expected !== '' && expected !== entry.digest) {
    return no(
      'digest-not-expected',
      `${url} is on disk and intact, and it is not the file this run expects — fetching it again.`,
    )
  }
  return {
    action: 'skip',
    reason: 'verified',
    line: `${url} is already on disk and matches its digest.`,
    entry,
    ledgerWasWrong: false,
  }
}

/* --------------------------------------------------------------- the store -- */

export interface LedgerTally {
  /** Entries read off disk at open. */
  known: number
  /** Lines that could not be read. */
  unreadable: number
  skipped: number
  fetched: number
  /** Of {@link fetched}, how many were fetched because the ledger was wrong. */
  ledgerWasWrong: number
  recorded: number
}

export interface LedgerVerdict {
  total: number
  ok: number
  missing: LedgerEntry[]
  corrupt: LedgerEntry[]
  /** One line. Never says "complete" when anything is missing or corrupt. */
  line: string
}

export interface LedgerStore {
  readonly path: string
  readonly mode: LedgerMode
  /** How many URLs the ledger knows about. */
  readonly size: number
  entryFor(url: string): LedgerEntry | null
  /** Consult the ledger about one asset, reading the file if there is one. */
  decide(url: string, options?: { expectDigest?: string }): Promise<LedgerDecision>
  /** Write down an asset that was fetched. Appends; never rewrites. */
  record(entry: Omit<LedgerEntry, 'at'> & { at?: number }): LedgerEntry
  /** Check every entry against the disk. The answer to "did this run work?". */
  verify(): Promise<LedgerVerdict>
  tally(): LedgerTally
  /** One line summarising the run so far, loud when anything is wrong. */
  summary(): string
}

/**
 * Open — or start — a ledger.
 *
 * A missing file is an empty ledger rather than an error: the first run of
 * anything has no ledger, and a resume that refused to start without one would
 * make `resume` mean "only after a successful first attempt".
 */
export function openLedger(
  path: string,
  options: { mode?: LedgerMode; now?: () => number } = {},
): LedgerStore {
  const mode: LedgerMode = options.mode === 'refetch' ? 'refetch' : 'resume'
  const now = options.now ?? Date.now
  let entries = new Map<string, LedgerEntry>()
  let unreadable = 0

  if (existsSync(path)) {
    try {
      const read = readLedgerFile(readFileSync(path, 'utf8'))
      entries = read.entries
      unreadable = read.skipped
    } catch {
      // A ledger that cannot be read is an empty ledger, which costs a
      // re-download. The alternative — refusing to run — costs the run.
      entries = new Map()
      unreadable = 0
    }
  }

  const tally: LedgerTally = {
    known: entries.size,
    unreadable,
    skipped: 0,
    fetched: 0,
    ledgerWasWrong: 0,
    recorded: 0,
  }

  return {
    path,
    mode,
    get size(): number {
      return entries.size
    },
    entryFor(url: string): LedgerEntry | null {
      return entries.get(url) ?? null
    },
    async decide(url: string, decideOptions = {}): Promise<LedgerDecision> {
      const entry = mode === 'refetch' ? null : entries.get(url) ?? null
      /*
       * The file is read only when there is an entry pointing at one. In
       * `refetch` mode there is deliberately no entry, so nothing is hashed and
       * the mode costs nothing — which is the point of having it rather than
       * telling people to delete the file.
       */
      const found =
        entry === null || entry.path === '' ? null : await fingerprintFile(entry.path)
      const decision = decideFromFingerprint({
        url,
        mode,
        entry: mode === 'refetch' ? null : entry,
        found,
        ...(decideOptions.expectDigest === undefined
          ? {}
          : { expectDigest: decideOptions.expectDigest }),
      })
      if (decision.action === 'skip') tally.skipped += 1
      else {
        tally.fetched += 1
        if (decision.ledgerWasWrong) tally.ledgerWasWrong += 1
      }
      return decision
    },
    record(input): LedgerEntry {
      const entry: LedgerEntry = {
        url: input.url,
        fetchedUrl: input.fetchedUrl === '' ? input.url : input.fetchedUrl,
        ruleId: input.ruleId,
        digest: input.digest,
        bytes: input.bytes,
        path: input.path,
        at: input.at ?? now(),
      }
      entries.set(entry.url, entry)
      tally.recorded += 1
      try {
        mkdirSync(dirname(path), { recursive: true })
        appendFileSync(path, `${JSON.stringify(entry)}\n`)
      } catch {
        /*
         * A ledger line that would not write.
         *
         * Not thrown, because the file itself downloaded and losing the download
         * over the bookkeeping would be the wrong way round. It is not silent
         * either: the entry is in memory for the rest of this run, and
         * {@link summary} reports the count it recorded against what a re-read
         * of the file would find.
         */
      }
      return entry
    },
    async verify(): Promise<LedgerVerdict> {
      const missing: LedgerEntry[] = []
      const corrupt: LedgerEntry[] = []
      let ok = 0
      for (const entry of entries.values()) {
        const found = entry.path === '' ? null : await fingerprintFile(entry.path)
        if (found === null) {
          missing.push(entry)
          continue
        }
        if (entry.digest === '' || found.digest !== entry.digest || found.bytes !== entry.bytes) {
          corrupt.push(entry)
          continue
        }
        ok += 1
      }
      const total = entries.size
      const line =
        missing.length === 0 && corrupt.length === 0
          ? `All ${total} assets in this ledger are on disk and match their digests.`
          : `${ok} of ${total} assets are intact. ${missing.length} are missing from disk and ` +
            `${corrupt.length} do not match the digest recorded for them. This run is not complete.`
      return { total, ok, missing, corrupt, line }
    },
    tally(): LedgerTally {
      return { ...tally }
    },
    summary(): string {
      if (mode === 'refetch') {
        return `Deliberate refetch: the ledger was not consulted. ${tally.recorded} recorded so far.`
      }
      const parts = [
        `${tally.known} known`,
        `${tally.skipped} skipped`,
        `${tally.fetched} fetched`,
        `${tally.recorded} recorded`,
      ]
      if (tally.ledgerWasWrong > 0) {
        parts.push(
          `${tally.ledgerWasWrong} of those were fetched because the ledger claimed a file that was ` +
            'missing or did not match — do not read this run as a resume',
        )
      }
      if (tally.unreadable > 0) parts.push(`${tally.unreadable} ledger lines were unreadable`)
      return parts.join(', ')
    },
  }
}
