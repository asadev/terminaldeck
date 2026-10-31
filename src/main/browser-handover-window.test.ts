import { describe, expect, it } from 'vitest'
import { HANDOVER_WINDOW_MS, MCP_CALL_TIMEOUT_MS } from './browser-drive'

/**
 * The handover window has to fit inside the client's call timeout.
 *
 * A regression test with a measurement behind it rather than a taste. On
 * 2026-08-18 `browser_handover` was asked, in words, to hand a page over so a
 * password could be typed. Claude Code 2.1.234 issued the call at 20:46:40.985
 * and returned **"The operation timed out."** at 20:47:41.129 — 60.14 seconds,
 * with the banner up on screen and the person able to answer it the whole time.
 * The window was ninety seconds, so the tool could never return its own answer:
 * every unanswered handover was an *error*, the model was told it had failed,
 * and it retried in a different shape and then stopped.
 *
 * `HandoverOutcome`'s whole design is that `still-waiting` is not a failure. An
 * answer that cannot arrive before the client gives up is not an answer, so the
 * window is the thing that has to move.
 *
 * This is deliberately not "45_000 exactly": the number may be tuned. What may
 * not happen is it drifting back over the client's cap, which is how it got
 * there the first time — the comment on the old constant asserted it was "well
 * under" a timeout nobody had measured.
 */
describe('browser.handover fits inside one tool call', () => {
  it('returns before an MCP client gives up', () => {
    expect(HANDOVER_WINDOW_MS).toBeLessThan(MCP_CALL_TIMEOUT_MS)
  })

  it('leaves real headroom rather than sitting on the edge', () => {
    // A window at 59s would pass the check above and still lose the race to a
    // slow round trip or a busy renderer. A quarter of the budget spare is what
    // makes "it returns" true on a machine under load, which is exactly when
    // somebody is likely to be watching several agents at once.
    expect(MCP_CALL_TIMEOUT_MS - HANDOVER_WINDOW_MS).toBeGreaterThanOrEqual(10_000)
  })

  it('is still long enough to be worth blocking for', () => {
    // The other direction matters too: a window of a few seconds would turn one
    // password into a dozen tool calls, which is the polling `waitFor` exists to
    // prevent and which spends the dispatcher's budget on nothing.
    expect(HANDOVER_WINDOW_MS).toBeGreaterThanOrEqual(30_000)
  })
})
