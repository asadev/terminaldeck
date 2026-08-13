/**
 * How long to wait before trying the socket again.
 *
 * A phone drops this connection constantly and for reasons that have nothing
 * to do with the desktop being down: the screen locks, the radio hands off from
 * wifi to cellular, the tunnel re-keys, a lift happens. So the two failure
 * modes to avoid pull in opposite directions — reconnecting in a tight loop
 * burns battery and hammers the desktop's accept loop, while a fixed long wait
 * leaves the terminal dead for twenty seconds after a two-hundred-millisecond
 * blip.
 *
 * Hence: start fast enough that a blip is invisible, grow, cap, and reset the
 * moment anything works. The caller also resets on `online` and on the tab
 * becoming visible again, because at that point the schedule is describing a
 * network condition that has already ended.
 */

export interface BackoffOptions {
  /** Wait before the first retry. */
  firstMs: number
  /** Ceiling. Reached after roughly seven attempts with the defaults. */
  maxMs: number
  /** Growth per attempt. */
  factor: number
  /** Fraction of each delay that is randomised away, 0–1. */
  jitter: number
}

export const RECONNECT_BACKOFF: BackoffOptions = {
  firstMs: 400,
  maxMs: 20_000,
  factor: 1.8,
  jitter: 0.3,
}

/**
 * The delay for a zero-based attempt number.
 *
 * The jitter is subtractive — it only ever shortens a delay. Additive jitter
 * would let a wait exceed `maxMs`, and the cap is a promise to the user about
 * the longest the app can look broken after the network returns.
 */
export function backoffDelay(
  attempt: number,
  random: () => number = Math.random,
  options: BackoffOptions = RECONNECT_BACKOFF,
): number {
  const step = Math.max(0, Math.floor(attempt))
  const raw = options.firstMs * Math.pow(options.factor, step)
  const capped = Math.min(options.maxMs, raw)
  const spread = capped * options.jitter * random()
  return Math.max(0, Math.round(capped - spread))
}

/** The schedule as a small object, so the caller never tracks the counter itself. */
export class Backoff {
  private attempt = 0

  constructor(
    private readonly options: BackoffOptions = RECONNECT_BACKOFF,
    private readonly random: () => number = Math.random,
  ) {}

  /** Attempts made since the last reset. Shown to the user, so it is public. */
  get attempts(): number {
    return this.attempt
  }

  /** The next delay, and advance the schedule. */
  next(): number {
    const delay = backoffDelay(this.attempt, this.random, this.options)
    this.attempt += 1
    return delay
  }

  /** Back to the top. Called on a successful connection, not on a successful socket. */
  reset(): void {
    this.attempt = 0
  }
}
