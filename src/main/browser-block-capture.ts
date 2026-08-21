import { existsSync, mkdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { writeFileAtomic } from './atomic-write'
import { scrapeRoot } from './browser-scrape-paths'

/**
 * The one switch behind *"Screenshot the page when a request is blocked"*.
 *
 * ## Why this file exists at all
 *
 * The photographing has been real since the day `browser-block-watch.ts`
 * landed: `BrowserDrive.watch` attaches it to every drivable page, and
 * `assets.blocks` lists what it caught. What was not real was the **control**.
 * The Scraping panel drew a switch called `screenshotOnBlock`, wrote it into a
 * configuration patch, and nothing in `src/main` had ever read that name — so
 * the switch was a picture of a switch. That is the exact defect the whole
 * browser review is made of, and it is worse here than in most places: the
 * feature it appears to govern is one whose only failure mode is *silence*, so
 * a person who turned it off would go on being photographed and a person who
 * believed they had turned it on would never learn otherwise.
 *
 * ## On by default, and it must stay that way
 *
 * A missing entry means **on**. Not because on is nicer, but because the
 * capture has been on for every install that has this feature, and a setting
 * introduced as off would silently stop the photographing on all of them — a
 * change nobody asked for, announced by nothing, discovered when a run fails
 * and there is no picture of why. The switch is a way to say *stop*, and saying
 * nothing has never meant stop.
 *
 * ## Per profile, because the picture is
 *
 * The panel scopes this section to a profile and that is not cosmetic: a block
 * screenshot can contain a logged-in session, and which session it contains is
 * decided by which profile the page was opened in. Somebody who turns the
 * camera off for the profile that is signed into their bank has said something
 * specific, and a browser-wide flag would answer a different question than the
 * one they were asked. `browser-scrape-paths.ts` files the pictures the same
 * way for the same reason.
 *
 * ## One small JSON file, read through a cache
 *
 * `<userData>/scrape/block-capture.json`, `{ "<profileId>": false }`. It sits
 * beside the evidence it governs rather than in `settings.json`, so a profile
 * that is deleted takes its answer with it when its folder goes.
 *
 * The cache matters more than it looks. {@link readBlockCapture} is consulted
 * from inside a navigation event, on every page that settles, so a synchronous
 * disk read per navigation would be a cost paid by every page load in the app
 * to answer a question that changes when somebody clicks a switch. This process
 * is the only writer, so the cache is invalidated by writing rather than by
 * watching, and a test can drop it outright.
 */

/** The file. Not created until something is stored in it. */
export function blockCapturePath(userData: string): string {
  return join(scrapeRoot(userData), 'block-capture.json')
}

/** What a profile nobody has answered for gets. See the header: on. */
export const BLOCK_CAPTURE_DEFAULT = true

/** `userData` → the stored answers. Only ever this process's own writes. */
const cached = new Map<string, Record<string, boolean>>()

function stored(userData: string): Record<string, boolean> {
  const held = cached.get(userData)
  if (held !== undefined) return held
  const answers: Record<string, boolean> = {}
  const path = blockCapturePath(userData)
  if (existsSync(path)) {
    try {
      const parsed: unknown = JSON.parse(readFileSync(path, 'utf8'))
      if (typeof parsed === 'object' && parsed !== null) {
        for (const [id, value] of Object.entries(parsed as Record<string, unknown>)) {
          // Only a real boolean. A file somebody hand-edited into `"false"` is
          // not an answer, and reading a string as one would turn the camera off
          // on the strength of a typo.
          if (typeof value === 'boolean') answers[id] = value
        }
      }
    } catch {
      /*
       * Unreadable is not "off".
       *
       * A truncated or corrupt file means nobody's answer survives, and the
       * default is what a profile with no answer gets — so the camera stays on
       * and the person's switch shows on, which is what is actually happening.
       */
    }
  }
  cached.set(userData, answers)
  return answers
}

/** May this profile's pages be photographed when they are refused? */
export function readBlockCapture(userData: string, profileId: string): boolean {
  return stored(userData)[profileId] ?? BLOCK_CAPTURE_DEFAULT
}

/**
 * Store an answer, and hand back what now stands.
 *
 * The return value is the *stored* state rather than a boolean success, for the
 * reason the whole scraping panel is built around: a control that reports what
 * was typed rather than what was kept is a control that can lie about the one
 * thing it exists to say. A write that throws leaves the answer in memory and
 * says so by returning it — the caller has the value, the disk does not, and
 * the next restart is honest about that rather than the panel being dishonest
 * about it now.
 */
export function setBlockCapture(userData: string, profileId: string, on: boolean): boolean {
  const answers = stored(userData)
  answers[profileId] = on
  const path = blockCapturePath(userData)
  try {
    mkdirSync(scrapeRoot(userData), { recursive: true })
    writeFileAtomic(path, `${JSON.stringify(answers, null, 2)}\n`)
  } catch {
    /* In memory for this run. The next one asks the disk again. */
  }
  return answers[profileId]
}

/**
 * The profiles somebody has switched the camera **off** for.
 *
 * Read by `assets.blocks`, and it is the difference between two answers that
 * look identical. An empty list of block screenshots means *nothing refused us*,
 * or *nothing was driven*, or — since there is a switch — *the camera is off for
 * the profile the run was in*. The first two the tool already says; the third it
 * could only guess at, and a caller who acts on the wrong one spends the run
 * wondering why a site that is plainly blocking them photographs nothing.
 *
 * Only ids explicitly stored as `false`. A profile nobody has answered for is on
 * and does not belong in a sentence about what is switched off.
 */
export function blockCaptureOff(userData: string): string[] {
  return Object.entries(stored(userData))
    .filter(([, on]) => on === false)
    .map(([id]) => id)
    .sort()
}

/** Forget what has been read, so a test can point at a fresh directory. */
export function resetBlockCaptureForTests(): void {
  cached.clear()
}
