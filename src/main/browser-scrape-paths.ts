import { join } from 'node:path'

/**
 * Where a scraping run's own records live.
 *
 * One module because three of them have to agree — the ledger, the coverage log
 * and the block screenshots are all *"the run"*, and a run whose evidence is
 * scattered across three conventions is a run nobody goes back to.
 *
 * Under `<userData>` rather than beside the downloaded files, and that is worth
 * a sentence. The files go wherever the person's download destination says,
 * which can be a folder on another computer (`browser-downloads.ts` delivers
 * across machines). The *records* are this app's own bookkeeping about what it
 * did, they have to survive the files being moved, and they must never be mixed
 * into a folder somebody is going to zip up and send to a client.
 *
 * Nothing here creates a directory. Each writer makes its own with
 * `mkdirSync(..., { recursive: true })` at the moment it has something to write,
 * so an install that has never scraped anything does not grow empty folders.
 */

/** Everything to do with scraping, under one roof. */
export function scrapeRoot(userData: string): string {
  return join(userData, 'scrape')
}

/**
 * Screenshots of pages that refused us, and the evidence beside each one.
 *
 * Not per-run, deliberately. A block is caught by the browser as it happens —
 * `browser-block-watch.ts` is on the page's own navigation events — and at that
 * moment there may be no run at all: the person could be clicking around by
 * hand, working out why the site is unhappy. One folder means the pictures are
 * always in the same place, whoever provoked them.
 */
export function blockShotDir(userData: string): string {
  return join(scrapeRoot(userData), 'blocks')
}

/**
 * A run's own folder.
 *
 * The id is squeezed into something that is certainly one path component: it
 * arrives from a tool call, and `join` with a `../` in it writes wherever the
 * caller likes. Everything outside the allowed set becomes `-` rather than being
 * dropped, so two different ids cannot collapse onto one folder and interleave
 * their ledgers.
 */
export function runDir(userData: string, runId: string): string {
  return join(scrapeRoot(userData), 'runs', safeRunId(runId))
}

/** What a run may be called on disk. Never empty, never a traversal. */
export function safeRunId(runId: string): string {
  const flat = runId.replace(/[^A-Za-z0-9._-]/g, '-').replace(/^[.-]+/, '')
  if (flat === '') return 'run'
  return flat.length > 80 ? flat.slice(0, 80) : flat
}

/** The append-only resume ledger for a run. See `browser-asset-ledger.ts`. */
export function ledgerPath(userData: string, runId: string): string {
  return join(runDir(userData, runId), 'ledger.jsonl')
}

/** Every coverage check the run made. See `browser-asset-coverage.ts`. */
export function coveragePath(userData: string, runId: string): string {
  return join(runDir(userData, runId), 'coverage.jsonl')
}
