import { defineConfig } from 'vitest/config'

/**
 * The only thing this file configures is **how long a test may take on
 * Windows**, and it exists because that turned out to be a property of the
 * runner rather than of any code here.
 *
 * ## What was measured
 *
 * `src/main/copilot-home.test.ts` has not changed in weeks. Fifty-five tests,
 * all of them a handful of `mkdir`/`stat`/`writeFile` calls in a fresh
 * temporary directory. Its total, on `windows-latest`, run by run:
 *
 *      298 ms   4a50e69   run 32026102997
 *      399 ms   baf9b1d   run 32085514286
 *      401 ms   486defc   run 32085041045
 *      795 ms   3024a58   run 32086548577
 *     7644 ms   3024a58   run 32086051108   ← the same commit as the line above
 *    25263 ms   bfdc4c6   run 32116910629
 *
 * Identical bytes, a **25x** spread, and the 7644 ms is from a run that was
 * green — it passed only because no single test crossed 5 s on its way through.
 *
 * The run that failed makes the same point from the inside. In that file, in
 * that run, `describes the one-file-per-fact memory convention with an example`
 * — which compares two strings and touches no disk — took **215 ms**, while
 * `names no path at all, so it survives the folder moving`, three tests later,
 * took **2 ms**. The two that failed are `() => {}`, not `async`, so nothing
 * about them can be waiting on anything; they took 7821 ms and 6064 ms to make
 * about ten filesystem calls each. That is a process that was not running, not
 * a function that was slow.
 *
 * It is not vitest oversubscribing the machine either. Reconstructing the run
 * from its own timestamps, the peak was **three** test files in flight on a
 * four-vCPU runner, and through the twenty-one seconds in which both of those
 * tests failed only **two** were executing at all.
 *
 * ## Why a global allowance rather than a number per test
 *
 * Because the lottery is not attached to any particular test. Nothing about
 * `copilot-home.test.ts` earned this; it was the file resident when the runner
 * stalled, and next week it will be a different one. A number pushed into
 * whichever file lost the draw is the "raised number with no reason" that lets a
 * real regression hide behind a plausible-looking literal — and it would have to
 * be done again, somewhere else, after the next red run.
 *
 * A test whose cost is genuinely structural still states its own ceiling with
 * its own reasoning: `readiness.test.ts` does exactly that for the tests that
 * shell out to real `git`.
 *
 * ## Why this cannot slacken the machine the work is done on
 *
 * The POSIX branch is vitest's own default, unchanged, so every run on a
 * developer's machine still fails at five seconds — which is where a genuine
 * slowdown introduced while writing code will be caught. The Windows branch
 * exists to absorb a runner that has demonstrated 25x scheduling variance on
 * unchanged code, and it is still far below anything a hang costs: a test that
 * never settles is still red, thirty seconds later, and the whole suite runs in
 * about 150 s inside a 45-minute job.
 */
const WINDOWS_SCHEDULING_ALLOWANCE_MS = 30_000

/**
 * A worker died once on the Windows runner, and this is the trail.
 *
 * 2026-08-19, the second CI run that had ever included Windows: every test
 * passed — `474 passed | 7 skipped` — and the job still exited 1 with a
 * pool-level `Worker exited unexpectedly`, no test attached to it. Repeated
 * afterwards on the same code: two Windows runs, both green. So it is rare
 * rather than deterministic, and it is not a failing assertion.
 *
 * What is known. The step's stderr carries many `AttachConsole failed` lines,
 * which is Windows' console-attach talking, so a native child is involved; the
 * suspects are the tests that spawn one. It is not `agent-controls-conpty` —
 * that reads a captured fixture rather than spawning — and it is not
 * `confine/pty`, which is macOS-only.
 *
 * **The arithmetic names it, next time it happens.** The summary counts every
 * file that reported, so `passed + skipped` one short of the total is the
 * crashed file, by subtraction. Diffing the reporter's per-file lines against
 * `find src -name '*.test.ts*'` narrows it in one pass; running Windows with
 * `--reporter=verbose` names it outright. Neither is on by default, because a
 * slower job on every push is a poor trade for an event seen once — but do not
 * spend an afternoon guessing when two commands answer it.
 *
 * It is written down rather than mitigated because a mitigation nobody can
 * reproduce is a change that might do nothing, dressed as a fix. A flaky gate
 * gets ignored, and a gate nobody trusts is how Windows drifted for months in
 * the first place — so if this recurs, chase it rather than retry it.
 */

export default defineConfig({
  test: {
    testTimeout: process.platform === 'win32' ? WINDOWS_SCHEDULING_ALLOWANCE_MS : 5_000,
    // `beforeEach` in these files is usually one `mkdtemp`, and it is starved by
    // exactly the same thing the test bodies are — so the two move together
    // rather than leaving a hook to fail at ten seconds for the same reason.
    hookTimeout: process.platform === 'win32' ? WINDOWS_SCHEDULING_ALLOWANCE_MS : 10_000,
  },
})
