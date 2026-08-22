import { appendFileSync, mkdirSync, writeFileSync } from 'node:fs'
import { posix } from 'node:path'
import { writeFileAtomic } from './atomic-write'

// Capture paths are server paths and manifest keys — a run recorded on a Linux
// box, read back by key elsewhere — so they are joined with `/` on every host.
const { join } = posix

/**
 * Where a page's background traffic is written down, and the rule that nothing
 * is written down quietly.
 *
 * ## Why capture at all: the data is almost never in the HTML
 *
 * A modern listing page ships a shell and then asks its own API for the
 * contents. The HTML has forty divs and a spinner; the JSON has the price, the
 * agent, the coordinates, the floor-plan URLs and the *total count*. Reading
 * the DOM gets you what a person can see. Reading what the page asked for gets
 * you what the page was given, which is strictly more and is already parsed.
 *
 * So every background response is recorded — unasked, alongside whatever the
 * caller does to the page — and the JSON bodies are kept.
 *
 * ## The rule this file exists to enforce
 *
 * **A capture with holes in it says so.** Every one of the numbers behind this
 * work is a silent hole: 48,473 assets skipped by a resume ledger that then
 * reported success; three scripts that reported success while doing nothing; 7%
 * of a dataset shipped as complete. A capture that quietly dropped the bodies it
 * could not get would be the next entry on that list, and it would be the worst
 * one, because the file it produced would look exactly like a good one.
 *
 * So a body that could not be kept is still an **entry**, with a state saying
 * which way it was lost, and the counts of each are in the summary and in the
 * tool's result. `bodyState` is never absent and never guessed.
 *
 * ## Append-only, one line per response
 *
 * `capture.jsonl`, appended as each response lands, so a run that is killed
 * half way keeps everything it had captured up to that point. A JSON array
 * rewritten per entry would cost O(n²) writes and lose the lot on a crash — and
 * a crawl is exactly the workload that gets killed half way.
 *
 * ## Where it lands
 *
 * `<userData>/browser-captures/<profile>/<run>/`, which is the download store's
 * convention read one level further: durable, inside the app's own data
 * directory, and **per profile**, because a profile is a separate cookie jar
 * and therefore a separate person's traffic. Two profiles' captures sharing a
 * folder would put one login's private JSON in with another's.
 */

/* ------------------------------------------------------------------ shape -- */

/**
 * What became of a response body. Seven states, and no eighth called "absent".
 *
 * The distinction between `lost` and `too-large` is the one that matters most:
 * the first means the browser could not give it to us, and re-running might
 * help; the second means we refused it, and re-running with a higher bound
 * will. A caller cannot choose between those unless the record tells it which.
 */
export type BodyState =
  /** On disk at {@link CaptureEntry.bodyPath}. */
  | 'saved'
  /** This kind of response was not one the run asked to keep bodies for. */
  | 'not-requested'
  /** Bigger than the per-body bound. The real size is on the entry. */
  | 'too-large'
  /** The run's total byte budget was already spent. */
  | 'over-budget'
  /** Asked for and refused: evicted from Chromium's buffer, or the channel was shut. */
  | 'lost'
  /** The response never finished — the page navigated away, or the window closed. */
  | 'unfinished'
  /** The request itself failed. `message` carries Chromium's reason. */
  | 'failed'

export interface CaptureEntry {
  /** Sequence within this run, from 1. Also the body file's prefix. */
  n: number
  url: string
  method: string
  /** Our own vocabulary — image, xhr, fetch… — or Chromium's when it is not one of ours. */
  kind: string
  status: number
  mimeType: string
  /** Bytes of body, as measured or as reported. 0 when there was none. */
  bytes: number
  bodyState: BodyState
  /** Relative to the run directory, so the manifest survives being moved. Empty unless `saved`. */
  bodyPath: string
  /** A safe subset of the response headers. See {@link KEPT_HEADERS}. */
  headers: Record<string, string>
  /** Why, for every state that is not `saved` or `not-requested`. Empty otherwise. */
  message: string
  at: number
}

export interface CaptureCounts {
  /** Every response seen. */
  entries: number
  bodies: number
  lost: number
  tooLarge: number
  overBudget: number
  unfinished: number
  failed: number
  notRequested: number
  /** Bytes actually written to disk. */
  bytes: number
}

/**
 * Which page a run's folder came from.
 *
 * Both ends, because a harvest navigates: a run armed on a listing page and
 * stopped three pages later would otherwise be a folder of JSON with no record
 * of what produced it — which is most of the way to being useless, and is the
 * same shape of half-answer as a dataset that never states its own total.
 */
export interface CapturePage {
  /** Where the page was when the run was armed. */
  armedUrl: string
  /** Where it was when the run stopped, and what it called itself. */
  stoppedUrl: string
  title: string
}

export interface CaptureSummary extends CaptureCounts {
  dir: string
  manifest: string
  page: CapturePage
  startedAt: number
  endedAt: number
  /** True when a bound stopped something being kept. The caller must see this. */
  incomplete: boolean
  /** One sentence naming what was dropped and by which bound. Empty when nothing was. */
  shortfall: string
  /**
   * True exactly when this run recorded nothing at all — the shape
   * `empty-result.ts` gives every tool result, carried here too because the
   * summary file is itself a result: an orchestrator reads it off disk long
   * after the tool call that produced it has scrolled away, and a person's
   * own browse-run (`browser-profile-arm.ts`) has no tool call at all. A
   * folder holding only an all-zero summary must say in words that it is not
   * a small success.
   */
  empty: boolean
  /** Why, when `empty`. Empty string otherwise. */
  emptyReason: string
}

/* ------------------------------------------------------------- the bounds -- */

/**
 * Defaults, and every one of them is a number that will drop something.
 *
 * That is not an argument against having them — a capture with no ceiling fills
 * a disk — it is the reason {@link CaptureSummary.shortfall} exists. A bound
 * that silently discards is the failure this whole piece of work is about; a
 * bound that discards and says exactly what it discarded is a budget.
 */
export const DEFAULT_MAX_BODY_BYTES = 2 * 1024 * 1024
export const MAX_MAX_BODY_BYTES = 64 * 1024 * 1024
export const DEFAULT_MAX_TOTAL_BYTES = 256 * 1024 * 1024
export const MAX_MAX_TOTAL_BYTES = 4 * 1024 * 1024 * 1024
export const DEFAULT_MAX_ENTRIES = 20_000
export const MAX_MAX_ENTRIES = 200_000

export interface CaptureBounds {
  maxBodyBytes: number
  maxTotalBytes: number
  maxEntries: number
}

export function defaultBounds(): CaptureBounds {
  return {
    maxBodyBytes: DEFAULT_MAX_BODY_BYTES,
    maxTotalBytes: DEFAULT_MAX_TOTAL_BYTES,
    maxEntries: DEFAULT_MAX_ENTRIES,
  }
}

/* ------------------------------------------------------------- the folder -- */

/** `<userData>/browser-captures`. One folder, beside `browser-downloads.json`. */
export function captureRoot(userData: string): string {
  return join(userData, 'browser-captures')
}

/**
 * One run's folder.
 *
 * The profile comes first so that everything one cookie jar ever produced is
 * under one path — which is what makes "delete this profile's traffic" a single
 * `rm -r` rather than a search.
 */
export function captureDir(userData: string, profileId: string, runId: string): string {
  return join(captureRoot(userData), safeSegment(profileId), safeSegment(runId))
}

/**
 * One path component that cannot be anything but a component.
 *
 * Deliberately not `downloadName` from `browser-downloads.ts`, for the reason
 * that function gives about not being `safeName`: that one tidies a name a
 * *server* suggested and is allowed to be permissive about spaces and dots,
 * and this one narrows an identifier to an alphabet. If either grows a case,
 * read the other.
 */
export function safeSegment(raw: string): string {
  const flat = raw.replace(/[^A-Za-z0-9._-]/g, '-').replace(/^[.-]+/, '')
  return flat === '' ? 'unknown' : flat.slice(0, 64)
}

/**
 * Response headers worth keeping, and no others.
 *
 * An allow-list rather than a deny-list, which is the same argument
 * `browser-cdp.ts` makes about its own tables: a header nobody thought about is
 * dropped by default rather than by having been remembered. The one that must
 * never be here is `set-cookie` — a captured session cookie written into a JSON
 * file beside the data is a credential leaked into a scrape output, and the
 * output is the thing most likely to be copied somewhere else.
 *
 * `link` earns its place: paginated APIs put `rel="next"` there and nowhere
 * else, so a crawl that dropped it would have to guess at page two.
 */
export const KEPT_HEADERS: readonly string[] = [
  'content-type',
  'content-length',
  'content-encoding',
  'content-range',
  'etag',
  'last-modified',
  'link',
  'x-total-count',
  'x-total-results',
]

const KEPT = new Set(KEPT_HEADERS)

export function keptHeaders(raw: unknown): Record<string, string> {
  const out: Record<string, string> = {}
  if (typeof raw !== 'object' || raw === null) return out
  for (const [name, value] of Object.entries(raw as Record<string, unknown>)) {
    const key = name.toLowerCase()
    if (!KEPT.has(key)) continue
    if (typeof value !== 'string') continue
    out[key] = value.length > 400 ? `${value.slice(0, 400)}…` : value
  }
  return out
}

/* --------------------------------------------------------------- the file -- */

/** What a captured body is called on disk. */
export function bodyFileName(n: number, url: string, mimeType: string): string {
  let stem = 'response'
  try {
    const path = new URL(url).pathname
    const last = path.split('/').filter((part) => part !== '').pop() ?? ''
    const cleaned = last.replace(/\.[A-Za-z0-9]{1,8}$/, '').replace(/[^A-Za-z0-9._-]/g, '-')
    if (cleaned !== '') stem = cleaned.slice(0, 60)
  } catch {
    // A URL that will not parse still gets a body and still gets a name.
  }
  return `${String(n).padStart(6, '0')}-${stem}${extensionFor(mimeType)}`
}

function extensionFor(mimeType: string): string {
  const type = mimeType.split(';')[0].trim().toLowerCase()
  if (type === 'application/json' || type.endsWith('+json')) return '.json'
  if (type === 'text/html') return '.html'
  if (type === 'text/css') return '.css'
  if (type === 'text/javascript' || type === 'application/javascript') return '.js'
  if (type === 'text/xml' || type === 'application/xml' || type.endsWith('+xml')) return '.xml'
  if (type.startsWith('text/')) return '.txt'
  if (type === 'image/png') return '.png'
  if (type === 'image/jpeg') return '.jpg'
  if (type === 'image/webp') return '.webp'
  return '.bin'
}

/* -------------------------------------------------------------- the store -- */

export interface CaptureStoreDeps {
  /** Epoch ms, injected so a test can freeze it. */
  now(): number
  /** Injected for the same reason every other store here injects its writes. */
  mkdir?(dir: string): void
  append?(file: string, line: string): void
  write?(file: string, bytes: Buffer | string): void
}

/**
 * One capture run: a folder, a manifest, and a set of counts that never lie.
 *
 * Constructed per arm, closed per disarm. Deliberately not a singleton — two
 * windows can be capturing at once, into two folders, and a shared sequence
 * number between them would produce a manifest whose `n` skips.
 */
export class CaptureStore {
  private seq = 0
  private readonly counts: CaptureCounts = {
    entries: 0,
    bodies: 0,
    lost: 0,
    tooLarge: 0,
    overBudget: 0,
    unfinished: 0,
    failed: 0,
    notRequested: 0,
    bytes: 0,
  }
  private readonly startedAt: number
  private opened = false
  private page: CapturePage = { armedUrl: '', stoppedUrl: '', title: '' }
  /** The first thing that went wrong with the folder itself, if anything did. */
  private fault = ''

  constructor(
    readonly dir: string,
    readonly bounds: CaptureBounds,
    private readonly deps: CaptureStoreDeps,
  ) {
    this.startedAt = deps.now()
  }

  get manifestPath(): string {
    return join(this.dir, 'capture.jsonl')
  }

  get bodiesDir(): string {
    return join(this.dir, 'bodies')
  }

  /** Where the page was when this run was armed. */
  noteArmed(url: string): void {
    this.page = { ...this.page, armedUrl: url }
  }

  /** Where it ended up, and what it called itself. Read into the summary. */
  noteStopped(url: string, title: string): void {
    this.page = { ...this.page, stoppedUrl: url, title }
  }

  /** How many entries are still allowed. Zero means the cap has been reached. */
  get remaining(): number {
    return Math.max(0, this.bounds.maxEntries - this.counts.entries)
  }

  /**
   * Make the folder.
   *
   * Throws, and is the one method here that does. Everything after this point is
   * called from a network event where a throw would leave a request paused and a
   * page hanging, so the failure that *can* be reported to a caller is reported
   * at the one moment there is a caller to report it to.
   */
  open(): void {
    if (this.opened) return
    const mkdir = this.deps.mkdir ?? ((dir: string) => void mkdirSync(dir, { recursive: true }))
    mkdir(this.bodiesDir)
    this.opened = true
  }

  /**
   * Whether a body of this size may be kept, and why not when it may not.
   *
   * Asked before the bytes are written rather than after, because the answer
   * decides what the entry says — and an entry that claimed `saved` for a file
   * that was never written is precisely the class of lie this module exists to
   * make impossible.
   */
  admits(bytes: number): { ok: true } | { ok: false; state: BodyState; message: string } {
    if (bytes > this.bounds.maxBodyBytes) {
      return {
        ok: false,
        state: 'too-large',
        message: `${bytes} bytes is over the ${this.bounds.maxBodyBytes}-byte per-body bound; raise maxBodyBytes to keep it`,
      }
    }
    if (this.counts.bytes + bytes > this.bounds.maxTotalBytes) {
      return {
        ok: false,
        state: 'over-budget',
        message: `the run's ${this.bounds.maxTotalBytes}-byte budget is spent; raise maxTotalBytes to keep the rest`,
      }
    }
    return { ok: true }
  }

  /**
   * Write one entry, and its body when there is one to write.
   *
   * `body` present is a *request* to save it, not a promise that it will be:
   * {@link admits} decides, and whichever way it goes the entry records the
   * outcome. A caller cannot end up believing a body is on disk because it
   * handed one over.
   */
  add(
    input: Omit<CaptureEntry, 'n' | 'bodyPath' | 'at' | 'bytes'> & { bytes?: number },
    body?: Buffer,
  ): CaptureEntry {
    this.seq += 1
    const n = this.seq
    let state = input.bodyState
    let message = input.message
    let bodyPath = ''
    let bytes = input.bytes ?? body?.length ?? 0

    if (body !== undefined && state === 'saved') {
      const verdict = this.admits(body.length)
      if (verdict.ok) {
        const name = bodyFileName(n, input.url, input.mimeType)
        try {
          this.open()
          const write =
            this.deps.write ?? ((file: string, data: Buffer | string) => void writeFileSync(file, data))
          write(join(this.bodiesDir, name), body)
          bodyPath = join('bodies', name)
          bytes = body.length
        } catch (error) {
          state = 'lost'
          message = `could not write the body to disk: ${reason(error)}`
          bytes = body.length
        }
      } else {
        state = verdict.state
        message = verdict.message
        bytes = body.length
      }
    }

    const entry: CaptureEntry = {
      n,
      url: input.url,
      method: input.method,
      kind: input.kind,
      status: input.status,
      mimeType: input.mimeType,
      bytes,
      bodyState: state,
      bodyPath,
      headers: input.headers,
      message,
      at: this.deps.now(),
    }
    this.tally(entry)
    this.appendLine(entry)
    return entry
  }

  private tally(entry: CaptureEntry): void {
    this.counts.entries += 1
    switch (entry.bodyState) {
      case 'saved':
        this.counts.bodies += 1
        this.counts.bytes += entry.bytes
        break
      case 'lost':
        this.counts.lost += 1
        break
      case 'too-large':
        this.counts.tooLarge += 1
        break
      case 'over-budget':
        this.counts.overBudget += 1
        break
      case 'unfinished':
        this.counts.unfinished += 1
        break
      case 'failed':
        this.counts.failed += 1
        break
      case 'not-requested':
        this.counts.notRequested += 1
        break
    }
  }

  private appendLine(entry: CaptureEntry): void {
    try {
      this.open()
      const append =
        this.deps.append ?? ((file: string, line: string) => void appendFileSync(file, line))
      append(this.manifestPath, `${JSON.stringify(entry)}\n`)
    } catch (error) {
      // The counts still stand and the summary still says how many there were,
      // so a manifest this could not extend is a shortfall rather than a
      // silence. Recorded once; a disk that refuses one line refuses them all.
      if (this.fault === '') this.fault = `could not write the manifest: ${reason(error)}`
    }
  }

  /** Everything counted so far. A copy: nothing outside this class may tally. */
  snapshot(): CaptureCounts {
    return { ...this.counts }
  }

  /**
   * Close the run and write `capture-summary.json` beside the manifest.
   *
   * The summary is the thing an orchestrator reads to decide whether the run is
   * usable, so it carries `incomplete` and `shortfall` rather than making a
   * reader derive them from seven counters.
   */
  close(): CaptureSummary {
    const empty = this.counts.entries === 0
    const summary: CaptureSummary = {
      ...this.counts,
      dir: this.dir,
      manifest: this.manifestPath,
      page: { ...this.page },
      startedAt: this.startedAt,
      endedAt: this.deps.now(),
      incomplete: this.incomplete(),
      shortfall: this.shortfall(),
      empty,
      emptyReason: empty
        ? 'this run recorded nothing: no background response was seen while it was armed. Either ' +
          'the page loaded nothing in that window, or its data does not come over XHR or fetch.'
        : '',
    }
    try {
      this.open()
      const write =
        this.deps.write ?? ((file: string, data: Buffer | string) => writeFileAtomic(file, String(data)))
      write(join(this.dir, 'capture-summary.json'), `${JSON.stringify(summary, null, 2)}\n`)
    } catch {
      // The summary is also the return value of the tool call, so a disk that
      // would not take the file has not taken the answer away from the caller.
    }
    return summary
  }

  private incomplete(): boolean {
    return (
      this.fault !== '' ||
      this.counts.lost > 0 ||
      this.counts.tooLarge > 0 ||
      this.counts.overBudget > 0 ||
      this.counts.unfinished > 0 ||
      this.remaining === 0
    )
  }

  /** One sentence naming what was dropped and which bound dropped it. */
  private shortfall(): string {
    const parts: string[] = []
    if (this.counts.tooLarge > 0) {
      parts.push(
        `${this.counts.tooLarge} over the ${this.bounds.maxBodyBytes}-byte per-body bound (maxBodyBytes)`,
      )
    }
    if (this.counts.overBudget > 0) {
      parts.push(
        `${this.counts.overBudget} after the ${this.bounds.maxTotalBytes}-byte run budget was spent (maxTotalBytes)`,
      )
    }
    if (this.counts.lost > 0) {
      parts.push(`${this.counts.lost} the browser would not hand back`)
    }
    if (this.counts.unfinished > 0) {
      parts.push(`${this.counts.unfinished} still in flight when capture stopped`)
    }
    if (this.remaining === 0) {
      parts.push(`the ${this.bounds.maxEntries}-entry cap was reached, so later responses were not seen`)
    }
    if (this.fault !== '') parts.push(this.fault)
    return parts.length === 0 ? '' : `bodies not kept: ${parts.join('; ')}`
  }
}

function reason(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
