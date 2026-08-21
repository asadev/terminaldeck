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
 * The root of the block evidence: one folder per profile beneath it.
 *
 * Not per-run, deliberately. A block is caught by the browser as it happens —
 * `browser-block-watch.ts` is on the page's own navigation events — and at that
 * moment there may be no run at all: the person could be clicking around by
 * hand, working out why the site is unhappy. So the pictures are not filed
 * under whatever run happened to be going; they are filed under whose browser
 * took them, which is the one thing that is always true of them.
 */
export function blockShotDir(userData: string): string {
  return join(scrapeRoot(userData), 'blocks')
}

/**
 * One profile's block screenshots.
 *
 * Per profile rather than one shared folder, and this is a privacy boundary
 * rather than tidiness. A picture of the page that refused us is a picture of
 * *whatever was on the screen* — a signed-in dashboard behind the challenge, an
 * email address in a header, a half-filled form. Two profiles exist precisely
 * so that one's session is not the other's; a folder that mixed their evidence
 * would undo that at the one moment nobody asked for a picture to be taken.
 *
 * `isolated` is the id `browser-drive-ipc.ts` files a throwaway tab under, for
 * the same reason it files that tab's captured traffic there: the partition
 * dies with the process, but the evidence must not.
 */
export function blockShotDirFor(userData: string, profileId: string): string {
  return join(blockShotDir(userData), safeProfileSegment(profileId))
}

/**
 * What a profile may be called on disk.
 *
 * The id arrives from `browser-tab.ts`, not from a tool call, so this is a belt
 * rather than the brace — but it is the same rule {@link safeRunId} states and
 * for the same reason: everything outside the allowed set becomes `-` rather
 * than being dropped, so two ids cannot collapse onto one folder and file one
 * profile's screenshots under another's name.
 */
export function safeProfileSegment(profileId: string): string {
  const flat = profileId.replace(/[^A-Za-z0-9._-]/g, '-').replace(/^[.-]+/, '')
  if (flat === '') return 'unfiled'
  return flat.length > 80 ? flat.slice(0, 80) : flat
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
