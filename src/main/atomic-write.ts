/**
 * Replace a file's contents without ever leaving a half-written one behind —
 * and, on Windows, without silently failing to replace it at all.
 *
 * ## The part every caller already had
 *
 * Write a temp file, `rename` it over the target. A crash between the two
 * leaves the old file intact, which is the whole point: `state.json` truncated
 * by a power cut reads as "no projects" and wipes the user's list on next
 * launch. Four places in `src/main` wrote that dance out by hand
 * (`store.ts`, `settings-extra.ts` twice, `profiles.ts`) and three more do it
 * elsewhere in the tree; this is the same dance, once, with the two things they
 * were all missing.
 *
 * ## The part that only matters on Windows, and matters a lot
 *
 * POSIX `rename(2)` **always** replaces the destination — that is the guarantee
 * the pattern rests on, and it is why this has never once failed on a Mac.
 * Windows has no such guarantee. `MoveFileEx(MOVEFILE_REPLACE_EXISTING)` fails
 * with `EPERM`/`EACCES`/`EBUSY` if *any* process holds the destination open
 * without `FILE_SHARE_DELETE`, and on an ordinary Windows PC several things do
 * exactly that, for a few milliseconds at a time, immediately after a file is
 * written: Defender's real-time scan opens what was just closed, so does the
 * search indexer, so does every backup agent, and so does a second window of
 * this app reading its own settings.
 *
 * The failure is therefore intermittent and unreproducible, which is the worst
 * shape a save bug can have. `store.ts` swallowed it into `console.error`, so a
 * Windows user's project list, theme and window bounds simply stopped
 * persisting with nothing on screen to say so; `settings-extra.ts` let it reach
 * the caller, so the same collision surfaced as "could not save" with no cause
 * named. Neither is a bug a person can act on, and neither can happen on macOS.
 *
 * A short bounded retry closes it: the interfering handle is held for
 * milliseconds, not seconds. Five attempts about 20 ms apart covers roughly a
 * tenth of a second of contention and then gives up honestly rather than
 * spinning — a rename that is still refused after that is a real permission
 * problem, and hiding it behind a longer wait would turn a diagnosable error
 * into a hang.
 *
 * The retry is Windows-only on purpose. On POSIX a rename that fails is failing
 * for a reason that will not improve — `ENOSPC`, `EROFS`, `EXDEV` — and
 * retrying it would add a tenth of a second to every real error while changing
 * no outcome.
 *
 * ## Why the temp name carries the pid
 *
 * A fixed `${file}.tmp` is a shared name, and two processes writing the same
 * settings at once therefore write the same temp file: one truncates the
 * other's half-finished bytes and both rename it into place. That is not
 * hypothetical here — a second window of this app is an ordinary thing to have
 * open, and on Windows the two collide over `%APPDATA%`. `remote/secret-file.ts`
 * has carried the pid for exactly this reason since it was written ("The temp
 * name carries the pid"); the application's own state files did not get it.
 *
 * A counter is appended as well, because one process can be part-way through
 * two writes of two different files whose *temp* names would otherwise be
 * distinct anyway — but also because a leftover temp from a crashed earlier run
 * with the same recycled pid must not be mistaken for ours.
 */

import { renameSync, unlinkSync, writeFileSync } from 'node:fs'
import { currentPlatform, isWindows, type Platform } from './platform/host'

/**
 * How many times a refused rename is retried, and how long between attempts.
 *
 * Exported so a test can assert the shape of the retry rather than infer it
 * from a duration, and so the two numbers are readable together — the product
 * of them is the claim being made about how long a scanner holds a handle.
 */
export const RENAME_ATTEMPTS = 5
export const RENAME_RETRY_MS = 20

/**
 * The Windows error codes that mean "somebody else has it open right now",
 * as opposed to "you may not do this at all".
 *
 * `EPERM` is the one `MoveFileEx` actually returns for a sharing violation,
 * which reads as a permission problem and is not one. `EACCES` and `EBUSY`
 * arrive from the same class of collision through different layers, and all
 * three are worth one more attempt. Anything else — a read-only volume, a full
 * disk, a path that is not there — is reported immediately.
 */
const TRANSIENT = new Set(['EPERM', 'EACCES', 'EBUSY'])

function isTransient(error: unknown): boolean {
  const code = (error as { code?: unknown } | null)?.code
  return typeof code === 'string' && TRANSIENT.has(code)
}

/** Every filesystem effect this module has, so a test can watch them all. */
export interface AtomicWriteOps {
  writeFile: (path: string, data: string) => void
  rename: (from: string, to: string) => void
  unlink: (path: string) => void
  /** Block for `ms`. Blocking, not awaited: every caller here is synchronous. */
  wait: (ms: number) => void
}

/**
 * A synchronous sleep, which Node does have and which is the right tool here.
 *
 * The callers are all `writeFileSync`-shaped — `store.persist()` is called from
 * inside setters that return the new value, and making them async would push
 * the change through every caller in `index.ts`. `Atomics.wait` on a
 * `SharedArrayBuffer` nobody else can see is the supported way to block a Node
 * main thread for a bounded time; a busy loop on `Date.now()` would spin a core
 * and is the kind of thing that has already cost this project a review.
 */
function blockFor(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
}

const nodeOps: AtomicWriteOps = {
  writeFile: (path, data) => writeFileSync(path, data, 'utf8'),
  rename: (from, to) => renameSync(from, to),
  unlink: (path) => unlinkSync(path),
  wait: blockFor,
}

/**
 * Rename `from` over `to`, retrying while Windows says somebody has it open.
 *
 * Split out of {@link writeFileAtomic} so that a caller which cannot use the
 * whole of it still gets this half. `secret-file.ts` is the one that matters:
 * it opens its temp file with `wx`, fsyncs it, chmods it and — on Windows —
 * writes an ACL onto it, none of which this module knows how to do, and it was
 * finishing all that work with a bare `renameSync`. A freshly ACL'd file is
 * precisely what a scanner opens to look at, so the one write in this app that
 * must not fail — the device's private key and the credential hashes behind the
 * remote wire — was the one write with no retry behind it.
 *
 * Two implementations of the retry would have been worse than none: the point
 * of the numbers above is that they describe *how long this app is willing to
 * wait for a scanner*, and an answer that differs by caller is not an answer.
 */
export function renameWithRetry(
  from: string,
  to: string,
  platform: Platform = currentPlatform(),
  ops: AtomicWriteOps = nodeOps,
): void {
  // One attempt on POSIX: `rename(2)` replaces the destination or fails for a
  // reason a second try cannot change.
  const attempts = isWindows(platform) ? RENAME_ATTEMPTS : 1
  for (let attempt = 1; ; attempt++) {
    try {
      ops.rename(from, to)
      return
    } catch (error) {
      if (attempt < attempts && isTransient(error)) {
        ops.wait(RENAME_RETRY_MS)
        continue
      }
      throw error
    }
  }
}

/** Distinct per process and per call, for the reason in the header. */
let sequence = 0

export function tempNameFor(file: string, pid: number = process.pid): string {
  sequence += 1
  return `${file}.${pid}.${sequence}.tmp`
}

/**
 * Write `contents` over `file`, atomically.
 *
 * Throws what the filesystem threw, once the retries are spent. Callers differ
 * on what to do with that — `settings-extra.ts` lets it reach the user as
 * "could not save", `store.ts` logs it — and that decision belongs to them; the
 * one thing this must not do is report success it did not have.
 *
 * The directory is *not* created here. Every caller already does it, and each
 * of them has an opinion about the mode (`secret-file.ts` wants 0o700), so
 * folding it in would either lose that or invent a second policy.
 */
export function writeFileAtomic(
  file: string,
  contents: string,
  platform: Platform = currentPlatform(),
  ops: AtomicWriteOps = nodeOps,
): void {
  const tmp = tempNameFor(file)
  ops.writeFile(tmp, contents)
  try {
    renameWithRetry(tmp, file, platform, ops)
  } catch (error) {
    // The temp file is ours and nothing else will ever clean it up, so it goes
    // even on the failure path — otherwise a machine where the rename is
    // genuinely refused accumulates one orphan per save, forever.
    try {
      ops.unlink(tmp)
    } catch {
      /* never created, or already gone */
    }
    throw error
  }
}
