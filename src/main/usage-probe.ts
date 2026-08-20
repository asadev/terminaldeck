/**
 * The usage figure, fetched without touching a session anybody is working in.
 *
 * ## What this replaces, and why it had to be replaced
 *
 * Until now the only way this app could make Claude Code state its plan limits
 * was to type `/usage` into one of its own terminals and read the panel that
 * came up. That worked, and Asad has now complained about it three times, most
 * recently with a recording of the panel sitting over a live conversation:
 *
 *   > *"find out some other way to keep the bar refresh otherwise we will
 *   > remove it completely if it will be heavy"*
 *
 * So the panel is not a cost to be tuned down; it is a cost to be removed. What
 * follows is the two sources that were found to replace it, both measured on
 * this machine against Claude Code 2.1.234 on 2026-08-18, and the price of each.
 *
 * ## Source one: the file the CLI already keeps
 *
 * `<configDir>/.claude.json` carries a `cachedUsageUtilization` block, and it is
 * exactly the answer:
 *
 *     "cachedUsageUtilization": {
 *       "fetchedAtMs": 1787051450329,
 *       "accountUuid": "06b8b3e9-…",
 *       "utilization": {
 *         "five_hour": { "utilization": 0,  "resets_at": "2026-08-18T16:00:00Z" },
 *         "seven_day": { "utilization": 34, "resets_at": "2026-08-23T23:00:00Z" },
 *         "limits": [ { "kind": "weekly_scoped", "percent": 0,
 *                       "scope": { "model": { "display_name": "Fable" } } } ] } }
 *
 * Free to read, instant, and it carries the one field that makes it safe to use
 * — `fetchedAtMs`, the moment the *CLI* fetched it, which becomes `reportedAt`
 * on every reading built from it. `usage-window.ts` is written around exactly
 * this distinction and its header names this very block as the thing that
 * nearly shipped a wrong bar: on the day it was written the block was 21.3
 * hours old and described a window that had already ended.
 *
 * That header was right, and it is worth being precise about *why*, because the
 * reason is what this module is built on. Nothing refreshes that block as a
 * side effect of working. The binary writes it from one function, which is
 * reached only when something explicitly asks the API for usage — the `/usage`
 * panel, or the control request below — and the write is throttled to once per
 * five minutes. The CLI trusts its own copy for an hour and then ignores it.
 * Both numbers are read out of the binary rather than guessed; see
 * {@link CLI_CACHE_TTL_MS}.
 *
 * So the file is a perfect *cache* and a hopeless *source*. On its own it goes
 * stale and stays stale. It is read here first anyway, for three reasons that
 * cost nothing: a bar that mounts has a figure immediately instead of in four
 * seconds, a reading taken by his own terminal `claude` running `/usage` is
 * picked up for free, and an app that has just started knows what it knew
 * before it was closed.
 *
 * ## Source two: asking the CLI, in a process of our own
 *
 * Claude Code answers a `get_usage` control request when it is driven over
 * stdio in SDK mode. That is a whole `claude` of our own, in a scratch working
 * directory, under the same account — and never a session anybody can see:
 *
 *     claude -p --input-format stream-json --output-format stream-json --verbose
 *     -> {"type":"control_request","request_id":"…","request":{"subtype":"initialize"}}
 *     <- {"type":"control_response","response":{"subtype":"success",…}}
 *     -> {"type":"control_request","request_id":"…","request":{"subtype":"get_usage"}}
 *     <- {"type":"control_response","response":{"subtype":"success","response":{
 *          "subscription_type":"max","rate_limits_available":true,
 *          "rate_limits":{"five_hour":{"utilization":2,…},"seven_day":{…}},
 *          "session":{"total_cost_usd":0,…}}}}
 *
 * **What it costs, measured rather than estimated.** Three runs against his own
 * login and three against a second account in this app's own profiles:
 *
 * | | boot | fetch | answer | process life |
 * |---|---|---|---|---|
 * | his own install | 1.03–1.15s | 2.25–2.57s | 3.27–3.59s | 3.8–4.2s |
 * | a Deck profile  | 1.03–1.07s | 0.40–0.50s | 1.43–1.57s | 2.0–2.1s |
 *
 * `total_cost_usd` came back `0` on every run and `total_api_duration_ms` `0`:
 * no message request is made, so **no tokens are spent**. `five_hour` did not
 * move across three runs a minute apart, so the fetch does not consume the
 * window it reports. Peak RSS of the child was 636MB for about four seconds,
 * which is the honest ugly number in this — it is a whole CLI, briefly.
 *
 * **What it leaves behind.** Diffed against a copy taken beforehand, the only
 * keys that changed in `.claude.json` were the CLI's own caches —
 * `cachedUsageUtilization`, `cachedGrowthBookFeatures`, `cachedExperimentData`,
 * `clientDataCacheSlots`. `numStartups` did not move. No transcript was
 * written, no entry appeared under `projects`, no `session-env` file was
 * created, and no setting was touched.
 *
 * **One thing it would have left behind, and does not.** Session hooks *do* run
 * in this mode. Proven by putting a `SessionStart` hook in a scratch project and
 * watching it fire; with `--setting-sources ""` it did not. Without that flag
 * this app would quietly trip his `SessionStart` and `SessionEnd` hooks — pawl,
 * Vibeyard — every time it refreshed a bar. See {@link PROBE_ARGS}.
 *
 * ## What was rejected
 *
 * **Reading the token and calling `GET /api/oauth/usage` directly.** That is
 * what the CLI does, and it is one HTTP request rather than a process. It is
 * refused on the rule in `ACCOUNT-MODEL.md`: this app never holds a
 * credential, and on macOS the credential is in the login keychain under an
 * item whose ACL names Claude Code and not this app, so reading it means a
 * system prompt on his screen — the exact interruption this whole exercise
 * exists to remove. The control request gets the same data with the CLI doing
 * its own authentication, and this process never sees a token.
 *
 * **Waiting for what sessions print on their own.** Claude Code volunteers a
 * limit line only when it is near a limit. `plan-limit.ts` already reads those
 * and keeps doing so; it costs nothing and it is silent most of the time, which
 * is why it cannot be the only source.
 *
 * ## The known fragility, stated rather than hidden
 *
 * The SDK spells this request
 * `usage_EXPERIMENTAL_MAY_CHANGE_DO_NOT_RELY_ON_THIS_API_YET`, and this repo
 * has a standing rule about building on undocumented CLI surface — written out
 * for `GEMINI_FORCE_FILE_STORAGE` in `provider-accounts.ts` — because a flag
 * that is renamed in a later release fails silently and takes something real
 * with it.
 *
 * The rule is kept here by making the failure harmless rather than by avoiding
 * the surface. If `get_usage` is renamed or removed, this returns an `error`
 * with the CLI's own sentence in it, the bar says the figure could not be
 * refreshed and shows the age of the last one, and **nothing else in the app
 * changes**: no session is typed into, no login is touched, no credential is
 * read. That is a bar that stops updating, which is precisely the outcome the
 * brief authorised as acceptable — and it is visible on screen the same day
 * rather than silent.
 */

import { spawn } from 'node:child_process'
import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'
import type { AgentBinary } from './agent-binaries'
import { killTree, systemRootOf } from './kill-tree'
import { identifyLimit, windowForScope, type PlanLimit } from './plan-limit'
import { currentPlatform, withPath, type Platform } from './platform/host'
import { findProfile, getState, sessionEnv, systemProfileFor, type Profile } from './profiles'
import { agentBinaries, loginPath, PROVIDERS } from './providers'
import { launchSpec } from './tool-probe'
import {
  fractionFromPercent,
  readingId,
  resetAtEpoch,
  type UsageAccountRef,
  type UsageWindowReading,
} from './usage-window'

/* -------------------------------------------------------------------------- */
/* Constants, all of them read off something real                              */
/* -------------------------------------------------------------------------- */

/**
 * How long Claude Code itself trusts `cachedUsageUtilization`.
 *
 * An hour, read out of the 2.1.234 binary: the function that reads the block
 * back returns null once `Date.now() - fetchedAtMs` exceeds `3600000`. Adopted
 * rather than invented so that this app and the CLI never disagree about
 * whether the same file is worth believing.
 *
 * It is deliberately far longer than the staleness this app draws by —
 * `STALE_WINDOW_FRACTION` retires a five-hour reading after twenty-five minutes
 * — because the two answer different questions. This one is "may this be
 * parsed at all"; that one is "may a live bar be drawn from it". A reading
 * between the two is still shown, with its age on it.
 */
export const CLI_CACHE_TTL_MS = 3_600_000

/**
 * How often the CLI rewrites the block, however often it is asked.
 *
 * Five minutes, from the same binary: the writer returns early when the held
 * copy is younger than `300000`. Recorded here because it is the reason a file
 * read taken straight after a successful probe can still show the *previous*
 * fetch, which would otherwise look like a bug in this module.
 */
export const CLI_CACHE_WRITE_THROTTLE_MS = 300_000

/**
 * How long the whole probe gets before it is killed.
 *
 * The slowest measured answer was 3.6 seconds end to end, on his own account,
 * where the fetch alone took 2.6. Fifteen is that with four times the slack,
 * and it is bounded on the other side by what a person waiting on a bar will
 * sit through. A kill is not a failure state anybody has to act on: the last
 * reading is still on screen with its age, and the next attempt is one event
 * away.
 */
export const PROBE_TIMEOUT_MS = 15_000

/**
 * The arguments the probe is run with, and why each one is there.
 *
 * `-p` with the two stream-json formats is what puts the CLI into the mode that
 * answers control requests at all; `--verbose` is required alongside them.
 *
 * The rest are all about spending nothing and disturbing nothing:
 *
 * - `--setting-sources ""` is the one that matters most. Session hooks really
 *   do fire in this mode — proven with a `SessionStart` hook in a scratch
 *   project, which fired under `--setting-sources project` and did not fire
 *   with this — and his machine has `SessionStart`, `SessionEnd` and a dozen
 *   more wired to pawl and to Vibeyard. Refreshing a bar must not look like a
 *   session starting to every tool he has watching.
 * - `--strict-mcp-config` on its own — no `--mcp-config` beside it — stops the
 *   CLI launching his MCP servers to answer a question that has nothing to do
 *   with them. Measured with and without: same answer, and it keeps a
 *   brace-and-quote JSON argument off a Windows command line, which is the one
 *   shape `spawn(..., { shell: true })` cannot be trusted to pass through.
 * - `--no-session-persistence` because there is no conversation here to save,
 *   and a phantom entry in his session list would be exactly the kind of
 *   leftover this app is not allowed to create.
 * - `--disable-slash-commands` because nothing is going to type one.
 */
export const PROBE_ARGS = [
  '-p',
  '--input-format',
  'stream-json',
  '--output-format',
  'stream-json',
  '--verbose',
  '--setting-sources',
  '',
  '--strict-mcp-config',
  '--no-session-persistence',
  '--disable-slash-commands',
] as const

/**
 * {@link PROBE_ARGS}, spelled for the launcher that will actually receive them.
 *
 * `spawn(..., { shell: true })` hands the whole line to `cmd.exe`, which splits
 * it on spaces and drops anything that is not quoted — and one of these
 * arguments is the *empty string*, which is what switches every settings file
 * off. Unquoted it disappears entirely, `--setting-sources` swallows the next
 * flag as its value, and the probe silently starts running his `SessionStart`
 * hooks again: a failure that looks like nothing at all from here.
 *
 * So each argument is wrapped when the shell is in the way, and left exactly as
 * it is when it is not — which is every platform but Windows, and Windows
 * whenever the runnable copy is a real executable rather than a `.cmd` shim.
 * None of these arguments contains a quote or a backslash, so wrapping is the
 * whole of the escaping needed; anything that changes that must revisit this.
 */
function argsFor(shell: boolean): string[] {
  if (!shell) return [...PROBE_ARGS]
  return PROBE_ARGS.map((arg) => (/^[A-Za-z0-9._\-]+$/.test(arg) ? arg : `"${arg}"`))
}

/* -------------------------------------------------------------------------- */
/* Reading the CLI's own numbers                                               */
/* -------------------------------------------------------------------------- */

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

/**
 * One window as the CLI's API reports it.
 *
 * `utilization` is a percentage and `null` means the window is not in force for
 * this account — never zero. `resets_at` is an ISO 8601 string here, unlike
 * Codex's Unix seconds and unlike the words the `/usage` panel prints, which is
 * a small gift: it is comparable to the clock, so `usageFreshness` can tell
 * whether a reading has outlived the window it describes.
 */
interface RawWindow {
  utilization: number | null
  resets_at: string | null
}

function readWindow(value: unknown): RawWindow | null {
  if (!isRecord(value)) return null
  const used = value.utilization
  const resets = value.resets_at
  return {
    utilization: typeof used === 'number' && Number.isFinite(used) ? used : null,
    resets_at: typeof resets === 'string' && resets.trim() !== '' ? resets : null,
  }
}

/**
 * The titles Claude Code gives these windows, taken from the CLI rather than
 * composed here.
 *
 * `usage-window.ts` requires a reading's label to be the source's own words,
 * and these are: the 2.1.234 binary's own formatter pairs `five_hour` with
 * `"Current session"`, `seven_day` with `"Current week (all models)"` and
 * `seven_day_sonnet` with `"Current week (Sonnet only)"`, and builds a
 * model-scoped one as `` `Current week (${display_name})` ``. Those are the
 * same strings the `/usage` panel draws and therefore the same strings
 * `plan-limit.ts` parses off the screen — which is what lets a reading from
 * either source land on the same id and merge instead of doubling the bar.
 *
 * `seven_day_sonnet` is titled only for a subscription the CLI titles it for
 * (max, team, or an account whose type it did not state). Copied exactly,
 * because showing a Sonnet-only row to somebody whose plan has no such window
 * would be inventing a limit.
 */
const NAMED_WINDOWS: ReadonlyArray<{ key: string; title: string; maxTeamOnly?: true }> = [
  { key: 'five_hour', title: 'Current session' },
  { key: 'seven_day', title: 'Current week (all models)' },
  { key: 'seven_day_sonnet', title: 'Current week (Sonnet only)', maxTeamOnly: true },
]

/**
 * Turn the CLI's utilization struct into the limits `plan-limit.ts` would have
 * parsed off the panel.
 *
 * Pure, and exported so the translation can be tested against the exact JSON
 * captured from this machine without spawning anything.
 *
 * A window with `utilization: null` is dropped rather than rendered at zero —
 * the CLI's own formatter does exactly that (`if (!a || a.utilization === null)
 * continue`) and the rule in `usage-window.ts` is the same one: unknown is not
 * zero.
 */
export function limitsFromUtilization(
  utilization: unknown,
  subscriptionType: string | null,
): PlanLimit[] {
  if (!isRecord(utilization)) return []
  const titled = subscriptionType === null || subscriptionType === 'max' || subscriptionType === 'team'
  const limits: PlanLimit[] = []

  for (const spec of NAMED_WINDOWS) {
    if (spec.maxTeamOnly && !titled) continue
    const window = readWindow(utilization[spec.key])
    if (!window || window.utilization === null) continue
    const { id, scope } = identifyLimit(spec.title)
    limits.push({ id, label: spec.title, scope, percent: window.utilization, resetsAt: window.resets_at })
  }

  /*
   * The model-scoped weekly rows, which arrive in a different shape.
   *
   * They are not top-level keys — they are entries in `limits[]` with
   * `kind: "weekly_scoped"` and the model's name under `scope.model.display_name`
   * — and the CLI builds their title from that name. Read from the real block on
   * this machine, which carries one for Fable.
   *
   * The CLI additionally filters these against a list from its own config
   * before drawing them, so it can show fewer than are present. Showing all of
   * them is the deliberate difference: this app's bar exists to say how much of
   * a subscription is gone, and a weekly limit the account really has is not
   * made less true by a display preference.
   */
  const rows = utilization.limits
  if (Array.isArray(rows)) {
    for (const row of rows) {
      if (!isRecord(row) || row.kind !== 'weekly_scoped') continue
      const scopeOf = isRecord(row.scope) && isRecord(row.scope.model) ? row.scope.model : null
      const name = scopeOf && typeof scopeOf.display_name === 'string' ? scopeOf.display_name.trim() : ''
      if (name === '') continue
      const percent = typeof row.percent === 'number' && Number.isFinite(row.percent) ? row.percent : null
      if (percent === null) continue
      const title = `Current week (${name})`
      const { id, scope } = identifyLimit(title)
      limits.push({
        id,
        label: title,
        scope,
        percent,
        resetsAt: typeof row.resets_at === 'string' && row.resets_at.trim() !== '' ? row.resets_at : null,
      })
    }
  }

  // Last one wins per id, so a model-scoped row cannot be shadowed by a named
  // one that happened to identify the same way. `plan-limit.ts` builds ids the
  // same way, which is the point: a probe reading and a screen reading of the
  // same window must collide rather than stack.
  const byId = new Map<string, PlanLimit>()
  for (const limit of limits) byId.set(limit.id, limit)
  return [...byId.values()]
}

/**
 * The limits, as readings, tagged with the account and with the moment the
 * *CLI* fetched them.
 *
 * `reportedAt` is `fetchedAtMs` and not now. That single line is what makes the
 * disk cache safe to read: a block the CLI fetched forty minutes ago produces a
 * reading that is forty minutes old, ages on screen accordingly, and is refused
 * a live bar by `isDrawable` exactly as it should be.
 */
export function readingsFromUtilization(
  utilization: unknown,
  subscriptionType: string | null,
  account: UsageAccountRef,
  fetchedAtMs: number,
  observedAt = Date.now(),
): UsageWindowReading[] {
  return limitsFromUtilization(utilization, subscriptionType).map((limit) => {
    const window = windowForScope(limit.scope)
    const qualifier = limit.id.includes(':') ? limit.id.slice(limit.id.indexOf(':') + 1) : ''
    return {
      id: readingId(account, window, qualifier),
      account,
      window,
      // The API states no window length either — `five_hour` is a key, not a
      // measurement this app was handed — so this stays null for the same
      // reason it is null for a screen reading.
      windowMinutes: null,
      label: limit.label,
      used: fractionFromPercent(limit.percent),
      // An instant, which the panel could never give: the API answers ISO 8601.
      // `Date.parse` of a malformed string is NaN and `resetAtEpoch` refuses it.
      resets: resetAtEpoch(limit.resetsAt === null ? null : Date.parse(limit.resetsAt)),
      observedAt,
      reportedAt: fetchedAtMs,
      source: 'claude-usage-api',
    }
  })
}

/* -------------------------------------------------------------------------- */
/* Source one: the file                                                        */
/* -------------------------------------------------------------------------- */

/**
 * Which profile an account ref names, so its environment can be rebuilt.
 *
 * Goes back to `profiles.ts` rather than reading `account.configDir` because of
 * one trap that has already been written down twice in this repo and confirmed
 * a third time while this module was being measured: `CLAUDE_CONFIG_DIR` set to
 * `$HOME/.claude` is *not* the same as leaving it unset. Set that way the probe
 * answered `subscription_type: null, rate_limits_available: false` about a live
 * Max login — the CLI looks for `~/.claude/.claude.json` and finds nothing,
 * and its keychain item is namespaced per directory so the credential is not
 * found either. `sessionEnv` returns `{}` for the system profile precisely to
 * avoid that, and it is the only correct source of this answer.
 */
function profileFor(account: UsageAccountRef): Profile | null {
  const state = getState()
  const found = account.id === null ? null : findProfile(state, account.id)
  if (found && found.provider === 'claude') return found

  /*
   * The id resolved to nothing, and what happens next used to be the defect.
   *
   * It fell through to the machine's own install unconditionally, which is a
   * substitution rather than a fallback: everything below would then read the
   * *default* login's `.claude.json`, or start a `claude` under the default
   * login, and hand the answer back to a caller that stamps it with the account
   * it was asked about. One account's figures drawn under another account's name
   * is the single thing this feature is not allowed to do — Asad recorded
   * exactly that on 2026-08-19, and could only tell because he happened to have
   * the other account open in another app at the time.
   *
   * The ref carries its own directory, so there is no need to guess at one. Two
   * answers below and neither is a substitution:
   *
   *  - the directory *is* the machine's own install, so the system profile is
   *    the right record and its empty environment is load-bearing — see
   *    `profiles.ts` on why `CLAUDE_CONFIG_DIR=$HOME/.claude` makes a working
   *    login read as unconfigured;
   *  - the directory is some other account's, whose record this app no longer
   *    has: deleted since the reading was taken, or a ref rebuilt from a stored
   *    one. That directory is read, because that is the account being asked
   *    about, and reading it is the only answer that is about the right login.
   *
   * A ref that names no directory at all is genuinely unattributed, and there is
   * nothing to read for it. Null, and every caller turns that into "nothing was
   * read" with a sentence rather than into somebody else's number.
   */
  const system = systemProfileFor('claude', state)
  const dir = account.configDir
  if (dir === null) return null
  if (resolve(dir) === resolve(system.configDir)) return system
  return {
    ...system,
    id: account.id ?? dir,
    name: account.name ?? dir,
    configDir: dir,
    // Not the machine's own install, so `sessionEnv` must export the directory
    // rather than returning `{}`.
    system: false,
  }
}

/**
 * The account's `.claude.json`, at the path the CLI itself would use, or null
 * when this app cannot say which file that is.
 *
 * Not `join(configDir, '.claude.json')`, which is wrong for exactly one account
 * and it is the commonest one: a default install keeps its config at
 * `~/.claude.json`, *one level above* `~/.claude`. `sessionEnv` is the only
 * thing that knows the difference — it returns `{}` for the system profile
 * precisely so that nothing sets `CLAUDE_CONFIG_DIR` to a path the CLI would
 * then read the wrong file under — so the answer is composed from what it
 * exports rather than from the directory.
 */
export function claudeConfigJsonPath(account: UsageAccountRef): string | null {
  const profile = profileFor(account)
  if (profile === null) return null
  const env = sessionEnv(profile, 'claude')
  const dir = env.CLAUDE_CONFIG_DIR?.trim()
  return dir && dir.length > 0 ? join(dir, '.claude.json') : join(homedir(), '.claude.json')
}

export interface CachedUsageRead {
  readings: UsageWindowReading[]
  /** When the CLI fetched the block, or null when there was nothing to read. */
  fetchedAtMs: number | null
}

/**
 * Read whatever the CLI last wrote for this account. Never throws.
 *
 * A missing file, a half-written one, a block for a *different* account — all
 * of them are "nothing known", because every one of them would otherwise become
 * a figure on screen with no source behind it. The account check is not
 * theoretical: `.claude.json` holds one `oauthAccount`, and somebody who signs
 * a directory into a second login leaves the old block sitting there until the
 * CLI overwrites it.
 */
export async function readCachedUsage(
  account: UsageAccountRef,
  now = Date.now(),
): Promise<CachedUsageRead> {
  const empty: CachedUsageRead = { readings: [], fetchedAtMs: null }
  const path = claudeConfigJsonPath(account)
  // No file this app can name for that account. "Nothing known" and not the
  // machine's own block, which is what a substitution here would have produced
  // — see `profileFor`.
  if (path === null) return empty
  let parsed: unknown
  try {
    parsed = JSON.parse(await readFile(path, 'utf8'))
  } catch {
    return empty
  }
  if (!isRecord(parsed)) return empty
  const block = parsed.cachedUsageUtilization
  if (!isRecord(block)) return empty
  const fetchedAtMs = block.fetchedAtMs
  if (typeof fetchedAtMs !== 'number' || !Number.isFinite(fetchedAtMs) || fetchedAtMs <= 0) return empty
  // The CLI's own ceiling, adopted rather than invented — see CLI_CACHE_TTL_MS.
  // Older than this and the CLI ignores its own copy, so nothing here should
  // present it as a reading.
  if (now - fetchedAtMs > CLI_CACHE_TTL_MS) return { readings: [], fetchedAtMs }

  const held = isRecord(parsed.oauthAccount) ? parsed.oauthAccount.accountUuid : undefined
  const stamped = block.accountUuid
  if (typeof held === 'string' && typeof stamped === 'string' && held !== stamped) {
    return { readings: [], fetchedAtMs }
  }

  /*
   * The plan, read off the same file rather than assumed.
   *
   * Only one row depends on it — `Current week (Sonnet only)`, which the CLI
   * titles for max and team accounts — and reading it here keeps the file path
   * and the probe path producing the same set of rows for the same login. An
   * unreadable value is left null, which is the case the CLI itself treats as
   * "title it anyway".
   */
  const oauth = isRecord(parsed.oauthAccount) ? parsed.oauthAccount : null
  const orgType = oauth && typeof oauth.organizationType === 'string' ? oauth.organizationType : null
  const plan = orgType === null ? null : orgType.replace(/^claude_/, '')

  return {
    readings: readingsFromUtilization(block.utilization, plan, account, fetchedAtMs, now),
    fetchedAtMs,
  }
}

/* -------------------------------------------------------------------------- */
/* Source two: the probe                                                       */
/* -------------------------------------------------------------------------- */

export type ProbeOutcome =
  | 'ok'
  /** The account answered, and has no subscription windows to report. */
  | 'no-limits'
  /** The CLI said this directory is not signed in. */
  | 'signed-out'
  /** No runnable `claude` on this machine. */
  | 'no-binary'
  /** It was killed at {@link PROBE_TIMEOUT_MS}, or it answered something else. */
  | 'unreadable'

export interface UsageProbeResult {
  outcome: ProbeOutcome
  readings: UsageWindowReading[]
  /** One sentence for the screen, in every outcome including `ok`. */
  detail: string
  /** Exactly what was run, so the answer can be reproduced in a terminal. */
  command: string
  /** Wall clock from spawn to answer, for the record and for the tests. */
  elapsedMs: number
  finishedAt: number
}

/** Everything the probe needs that is not the account. Injected by tests. */
export interface UsageProbeOptions {
  platform?: Platform
  /** The PATH to run under. Production passes nothing and gets the login PATH. */
  path?: string
  /** The binary resolution, when the caller already has one. */
  binary?: AgentBinary
  timeoutMs?: number
  /**
   * The transport itself, replaced wholesale in tests.
   *
   * Injected at this seam rather than at `spawn` because what is worth testing
   * is the translation either side of it — which JSON goes out, what comes back
   * becomes — and a test that drove a real `claude` would be measuring his
   * machine and his subscription instead.
   */
  ask?(
    command: string,
    args: string[],
    options: {
      env: NodeJS.ProcessEnv
      cwd: string
      timeoutMs: number
      shell: boolean
      /**
       * Threaded through rather than read here, because what has to be done
       * when the probe is finished with its child differs by platform and
       * `platform/host.ts` forbids deciding that from `process.platform`
       * anywhere but in itself. See `kill-tree.ts` for what it decides.
       */
      platform: Platform
    },
  ): Promise<ProbeAnswer>
}

/** What one run of the control protocol came back with. */
export interface ProbeAnswer {
  /** The `response` object of a successful `get_usage`, or null. */
  usage: Record<string, unknown> | null
  /** The CLI's own error sentence, when it sent one. */
  error: string | null
  /** True when the child was killed rather than answering. */
  killed: boolean
}

/**
 * Drive one `claude` through the control protocol and ask it for usage.
 *
 * Nothing is ever written to the child but the two control requests, and no
 * user message is sent — which is the whole reason this costs no tokens. The
 * child is killed as soon as the answer is in hand rather than being left to
 * exit on its own, because an idle CLI holding half a gigabyte for no reason is
 * a cost with nothing on the other side of it.
 *
 * "Killed" means the whole tree, not the process handle: on Windows the handle
 * is a command processor and the CLI is underneath it. That distinction, and
 * why the naive call leaked on Windows only, is argued in `kill-tree.ts`.
 */
async function askOverStdio(
  command: string,
  args: string[],
  options: {
    env: NodeJS.ProcessEnv
    cwd: string
    timeoutMs: number
    shell: boolean
    platform: Platform
  },
): Promise<ProbeAnswer> {
  return await new Promise<ProbeAnswer>((resolve) => {
    let settled = false
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: options.env,
      stdio: ['pipe', 'pipe', 'pipe'],
      // True only on Windows, and only when the copy that runs is a `.cmd`
      // launcher — `launchSpec` decides, exactly as it does for the sign-in
      // probe. See `argsFor` for what that costs the argument list.
      shell: options.shell,
      windowsHide: true,
    })

    const finish = (answer: ProbeAnswer): void => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      try {
        child.stdin.end()
      } catch {
        // The child may already be gone; there is nothing to close and nothing
        // to report.
      }
      /*
       * Kill the *tree*, not the handle we happen to hold.
       *
       * This was `child.kill()`, which is correct on macOS and silently wrong
       * on Windows. `options.shell` is true there whenever the runnable copy is
       * a `.cmd` shim — which is every probe, because the call below hard-codes
       * `resolved = null` — so the direct child is `cmd.exe` and the `node
       * …\claude` that is actually holding the memory is its grandchild.
       * Windows has no process group to signal and `TerminateProcess` does not
       * descend, so terminating cmd.exe left the CLI running, once per reading,
       * for the life of the app. The comment above this function says the child
       * is killed because "an idle CLI holding half a gigabyte for no reason is
       * a cost"; on Windows that cost was being paid on every refresh instead
       * of being avoided. `kill-tree.ts` carries the argument in full.
       *
       * Not awaited: the answer is already in hand and the caller must not wait
       * on a cleanup. `killTree` never rejects, so the floating promise cannot
       * become an unhandled rejection.
       */
      void killTree(child, {
        platform: options.platform,
        shell: options.shell,
        systemRoot: systemRootOf(options.env),
      })
      resolve(answer)
    }

    const timer = setTimeout(() => {
      finish({ usage: null, error: null, killed: true })
    }, options.timeoutMs)

    const send = (request: Record<string, unknown>): void => {
      try {
        child.stdin.write(`${JSON.stringify(request)}\n`)
      } catch {
        finish({ usage: null, error: null, killed: true })
      }
    }

    // The CLI emits nothing at all until it has been initialised — measured: a
    // process sent `get_usage` first sat silent until it was killed a minute
    // later. So this is not politeness, it is the handshake.
    send({ type: 'control_request', request_id: 'init', request: { subtype: 'initialize' } })

    let buffer = ''
    let asked = false
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk
      for (;;) {
        const cut = buffer.indexOf('\n')
        if (cut < 0) break
        const line = buffer.slice(0, cut)
        buffer = buffer.slice(cut + 1)
        if (line.trim() === '') continue
        let message: unknown
        try {
          message = JSON.parse(line)
        } catch {
          // A line that is not JSON is the CLI talking to a human — a warning,
          // an update notice. Not an answer and not an error; skip it.
          continue
        }
        if (!isRecord(message) || message.type !== 'control_response') continue
        const response = isRecord(message.response) ? message.response : null
        if (!response) continue
        if (response.request_id === 'init') {
          if (asked) continue
          asked = true
          if (response.subtype !== 'success') {
            finish({ usage: null, error: typeof response.error === 'string' ? response.error : null, killed: false })
            return
          }
          send({ type: 'control_request', request_id: 'usage', request: { subtype: 'get_usage' } })
          continue
        }
        if (response.request_id === 'usage') {
          finish({
            usage: response.subtype === 'success' && isRecord(response.response) ? response.response : null,
            error: typeof response.error === 'string' ? response.error : null,
            killed: false,
          })
          return
        }
      }
    })

    // stderr is drained rather than read. Something has to consume it or a
    // chatty CLI fills the pipe and blocks writing to its own stdout, which is
    // the one thing this is waiting on.
    child.stderr.resume()
    child.on('error', () => finish({ usage: null, error: null, killed: true }))
    child.on('exit', () => finish({ usage: null, error: null, killed: true }))
  })
}

/**
 * Ask this account's CLI what its plan limits are.
 *
 * Never rejects. Every failure comes back as an outcome with a sentence, for the
 * same reason `readSignIn` does it that way: a bar that goes blank when a probe
 * fails looks broken for a reason nobody can see.
 */
export async function probeUsage(
  account: UsageAccountRef,
  options: UsageProbeOptions = {},
): Promise<UsageProbeResult> {
  const startedAt = Date.now()
  const platform = options.platform ?? currentPlatform()
  const bin = PROVIDERS.claude.bin ?? 'claude'
  const command = `${bin} ${PROBE_ARGS.join(' ')}`
  const done = (outcome: ProbeOutcome, readings: UsageWindowReading[], detail: string): UsageProbeResult => {
    const finishedAt = Date.now()
    return { outcome, readings, detail, command, elapsedMs: finishedAt - startedAt, finishedAt }
  }

  /*
   * Does the binary run, before anything is spawned to ask it a question?
   *
   * The same guard `profiles-signin.ts` keeps, for the same reason it was added
   * there: without it a broken npm launcher's stack trace ends up quoted on
   * screen as if it were an answer about somebody's subscription.
   */
  const binary = options.binary ?? (options.ask ? undefined : (await agentBinaries(platform)).claude)
  if (binary && binary.runnable === null) {
    return done('no-binary', [], 'Claude Code could not be started here, so its usage could not be read.')
  }

  /*
   * Which login this probe runs as, established before anything is spawned.
   *
   * A null here means the ref names an account this app can no longer place, and
   * the only alternative to refusing is running the probe under the machine's
   * own install and returning its subscription under the asked-for account's
   * name. That is the defect this whole pass exists to end, so it is a sentence
   * rather than a figure. It costs nothing on the ordinary path: every account
   * that resolves reaches the spawn exactly as before.
   */
  const profile = profileFor(account)
  if (profile === null) {
    return done(
      'unreadable',
      [],
      'This app cannot tell which login that session is running as, so its plan limits are not shown — the figures below it would be a different account’s.',
    )
  }

  const launch = launchSpec(binary?.runnable ?? bin, null, platform)
  const PATH = options.path ?? (await loginPath(platform))
  const env: NodeJS.ProcessEnv = {
    ...withPath(process.env, PATH, platform),
    ...sessionEnv(profile, 'claude'),
  }
  /*
   * The inherited identity, scrubbed.
   *
   * Deck is frequently started from a terminal that is itself inside a Claude
   * Code session, and those set `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`,
   * `CLAUDE_CODE_SESSION_ID` and friends. A child that inherits them reports
   * itself as a continuation of somebody else's session. Every one of them goes
   * except the config directory, which is the one this app means to set.
   */
  for (const key of Object.keys(env)) {
    if (key === 'CLAUDE_CONFIG_DIR') continue
    if (key === 'CLAUDECODE' || key.startsWith('CLAUDE_CODE_')) delete env[key]
  }

  const ask = options.ask ?? askOverStdio
  const answer = await ask(launch.command, argsFor(launch.shell), {
    env,
    shell: launch.shell,
    // Handed down rather than looked up inside the transport, so a test on this
    // Mac can pin what a Windows run does with its child. `launch.shell` and
    // this together are the whole of the difference: see `kill-tree.ts`.
    platform,
    // The user's home, not a project. A read of a subscription must not be
    // attributable to any repository he has open — `profiles-signin.ts` runs
    // its probe from here for the same reason.
    cwd: homedir(),
    timeoutMs: options.timeoutMs ?? PROBE_TIMEOUT_MS,
  })

  if (answer.usage === null) {
    if (answer.killed) {
      return done(
        'unreadable',
        [],
        `Claude Code did not answer within ${Math.round((options.timeoutMs ?? PROBE_TIMEOUT_MS) / 1000)} seconds, so its usage is unread.`,
      )
    }
    return done(
      'unreadable',
      [],
      answer.error === null
        ? 'Claude Code was asked for its usage and answered something this build could not read.'
        : `Claude Code could not report its usage: ${answer.error.slice(0, 160)}`,
    )
  }

  const available = answer.usage.rate_limits_available === true
  const subscription =
    typeof answer.usage.subscription_type === 'string' ? answer.usage.subscription_type : null
  if (!available) {
    /*
     * Two different facts wearing one flag, told apart by the plan.
     *
     * The CLI sets `rate_limits_available` false both for a directory that is
     * not signed in and for one signed in without a claude.ai subscription
     * behind it — an API-key login. `subscription_type` is null in the first and
     * names a plan in the second, and the sentences have to differ because only
     * one of them is something a person can do anything about.
     */
    if (subscription === null) {
      return done('signed-out', [], 'That account is not signed in to Claude Code, so it has no plan limits to report.')
    }
    return done('no-limits', [], 'This login has no subscription limits — Claude Code reports none for it.')
  }

  const readings = readingsFromUtilization(answer.usage.rate_limits, subscription, account, Date.now())
  if (readings.length === 0) {
    return done('no-limits', [], 'Claude Code reports no plan limits for this login.')
  }
  return done('ok', readings, 'Read from Claude Code, in this app’s own process — no session was touched.')
}
