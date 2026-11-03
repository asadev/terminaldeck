/**
 * The two ceilings the worker pool actually enforces, in the one place both
 * sides of the app can read them.
 *
 * ## Why they moved here
 *
 * They were `export const`s in `src/main/browser-worker-pool.ts`, which the
 * renderer cannot import — its tsconfig does not include `src/main` — so the
 * Scraping panel's two number fields carried their own numbers instead:
 * `max={64}` beside a pool that clamps to 16, and `max={600000}` beside a pool
 * that clamps to 30,000. Typing ten minutes into "Between requests" was
 * accepted by the field, stored as thirty seconds, and only came back corrected
 * because the engine answers with what it stored. A control that accepts a
 * number it cannot keep is a control that lies for exactly one round trip, and
 * on a build where that reply is unreadable it lies for good.
 *
 * A shared module rather than a copy with a comment: a copy is a second answer
 * to one question, and the first edit to either half is the day they disagree.
 *
 * ## Why they are not settings
 *
 * Neither is a preference and neither is negotiable, which is why they live in
 * a constants file rather than in the settings schema. `browser-worker-pool.ts`
 * argues both at length and those arguments stay there; what is repeated here
 * is only the shape of them, because a number with no reason is a number the
 * next person raises.
 */

/**
 * The most workers a fleet may hold.
 *
 * Above this it is not a pool, it is a fleet of browsers, and that is not what
 * the pool is for. See `browser-worker-pool.ts`.
 */
export const MAX_WORKERS = 16

/**
 * The longest `minDelayMs + jitterMs` may add up to, in milliseconds.
 *
 * Bounded by the thing that waits: a lease is handed out by a tool call that
 * *awaits* the delay, and an MCP client gives a tool call sixty seconds — so a
 * pace past that would turn a correct delay into a timeout, which reads to a
 * model as a broken tool worth retrying immediately.
 */
export const MAX_PACE_MS = 30_000

/**
 * The most megabytes of captured responses one profile may be told to keep.
 *
 * Not a re-export like the two above, and the difference is worth stating: this
 * number is *derived* in `main/browser-scrape-settings.ts` from the capture
 * store's own byte ceiling (`MAX_MAX_TOTAL_BYTES`, 4 GiB), and moving that
 * derivation here would drag the capture store into a module the renderer
 * loads. So it is a copy — and a copy is a second answer to one question, which
 * is exactly why `browser-scrape-settings.test.ts` asserts the two are equal.
 * The guard is what makes the copy safe; without it this is the field that
 * accepted a terabyte and stored four gigabytes.
 */
export const MAX_KEEP_MB = 4096
