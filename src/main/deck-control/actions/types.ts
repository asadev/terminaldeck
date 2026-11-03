/**
 * What "an outside AI can do everything a person can" is checked against.
 *
 * ## Why a table and not a promise
 *
 * The ask was that a copilot in any other application — reaching this app over
 * MCP — can do *every single thing* a person does by hand. A claim like that is
 * true on the day it is written and false the week after, when a feature lands
 * with a button and no tool. So the claim is a table: every action the window
 * can ask the main process for (every `invoke`/`send` channel in the preload)
 * is listed here once, and each one says which tool does the same thing, or why
 * no caller from outside may have it. `actions.test.ts` reads the preload and
 * fails on a channel that is missing, listed twice, or still `null` — so a new
 * button without a tool is a red test, not a forgotten paragraph.
 *
 * ## What an entry may say
 *
 *  - `{ tool }` — the deck-control tool id (dotted) that reaches the same
 *    effect. An array when the effect is split across several.
 *  - `{ skip }` — one plain sentence on why this is deliberately not a tool.
 *    The honest reasons are few: it is plumbing between the window and the main
 *    process with no effect a person chooses (a subscribe, a resize, a frame
 *    report); it hands back a secret in the clear; or it is a live keystroke
 *    stream that `sessions.send` / `sessions.keys` already cover. "Nobody would
 *    want it" is not a reason — the person asking for this said *everything*.
 *  - `null` — not decided yet. Fails the test on purpose.
 */

export type Coverage = { tool: string | readonly string[] } | { skip: string } | null

export type CoverageMap = Readonly<Record<string, Coverage>>
