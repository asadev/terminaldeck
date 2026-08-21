/**
 * The scraping panel's reasoning, kept out of its markup.
 *
 * `ScrapingPanel.tsx` is a `Modal`, and a `Modal` portals into `<body>`, which
 * `renderToStaticMarkup` — the only rendering this project's test run does —
 * refuses. So the decisions live here, where they can be run: what a worker row
 * says when the engine has not answered for it, what a lift is refused for, when
 * a coverage check is allowed to read as complete, and which tool may install.
 * `HistoryPanel.tsx` and `history-view.ts` are split for the same reason.
 *
 * Every function in this file is written against one rule, and it is the rule
 * the whole panel exists to keep: **nothing may report success it has not
 * verified.** A number nobody measured is `null` here and says so on screen; a
 * check with no stated total is `unknown` and never `complete`; a tool whose
 * identity could not be established cannot be installed.
 */

import type { BrowserProfile } from './accounts-bridge'
import {
  type CaptureStatus,
  type CoverageCheck,
  type FleetConfig,
  type RequestRule,
  type RequestRules,
  type ResourceType,
  type ScrapingStatus,
  type ToolListing,
} from './scraping-bridge'

/* -------------------------------------------------------------- measuring -- */

/**
 * What the panel says where a number should be and there is none.
 *
 * Not `0`, not `—`, not a blank cell. All three read as a measurement — a dash
 * especially, which every table in the world uses for "none" — and the fact
 * being reported here is that *nobody counted*, which is a different thing from
 * counting none. He shipped 7% of a dataset believing it was complete; this
 * string is the smallest possible piece of the fix.
 */
export const NOT_MEASURED = 'not measured'

/**
 * A count with its unit, or {@link NOT_MEASURED}.
 *
 * `0` is a real measurement and is printed as one — "0 dropped" is a fact worth
 * having, and it is the fact this panel is least able to fake, because it can
 * only come from an engine that counted.
 */
export function countLine(value: number | null, one: string, many: string): string {
  if (value === null) return NOT_MEASURED
  return `${value.toLocaleString()} ${value === 1 ? one : many}`
}

/** The same bargain for a size. `formatBytes` lives in `SessionModal.tsx`. */
export function bytesLine(value: number | null, format: (bytes: number) => string): string {
  return value === null ? NOT_MEASURED : format(value)
}

/* --------------------------------------------------------------- requests -- */

/** The three answers a request can get, in the order the row draws them. */
export const REQUEST_RULES = ['allow', 'block', 'fulfill'] as const satisfies readonly RequestRule[]

export function ruleLabel(rule: RequestRule): string {
  if (rule === 'allow') return 'Allow'
  if (rule === 'block') return 'Block'
  return 'Fulfill'
}

/**
 * One rule, as a patch.
 *
 * A function rather than an object literal at the call site because a computed
 * key off a union type widens to `string` there, and the patch would stop being
 * checked against the seven types this panel can actually set.
 */
export function ruleChange(type: ResourceType, rule: RequestRule): RequestRules {
  const rules: RequestRules = {}
  rules[type] = rule
  return rules
}

/** What each resource type is called on its row. */
export function resourceLabel(type: ResourceType): string {
  if (type === 'xhr') return 'XHR'
  if (type === 'fetch') return 'Fetch'
  // `media` is already plural and `Medias` is not a word; the rest take an s.
  if (type === 'media') return 'Media'
  return `${type.charAt(0).toUpperCase()}${type.slice(1)}s`
}

/**
 * The one line that has to sit beside Fulfill, and the whole reason it exists.
 *
 * This is not a nicety. Blocking images is what cost him 16,498 floor plans: the
 * requests never went, so the page's own lazy-loading never fired, so the real
 * image URLs were never written into the document, so the scrape walked a page
 * that looked complete and collected almost none of it. A blocked request is
 * cheap and *changes the page*; a fulfilled one is nearly as cheap and leaves
 * the page believing its images loaded.
 *
 * Kept as one sentence because *"I don't want any kind of long descriptions
 * anywhere"* — and kept at all because the difference between the two middle
 * options is invisible from their names, and that invisibility has a price he
 * has already paid once.
 */
export const FULFILL_NOTE =
  'Block stops the request, so lazy-loading never fires and the page never reveals its real URLs. Fulfill answers it with a correctly-sized transparent placeholder, so it does.'

/* ---------------------------------------------------------------- workers -- */

/** One row of the Workers list: a profile, whether it is enrolled, what it is doing. */
export interface WorkerRow {
  profileId: string
  /** The profile's name, or the id when the profile is gone. */
  name: string
  /** The one character its badge draws, `''` for the name's initial. */
  avatar: string
  /** Enrolled as a worker in the stored fleet. */
  enrolled: boolean
  /**
   * What it is doing, as the engine reported it, or `'unreported'`.
   *
   * `'unreported'` is not `'idle'`. Idle says a worker is up and waiting, which
   * is a claim about a process; unreported says the engine did not mention this
   * one, which is all a panel can honestly know when a profile is enrolled and
   * nothing has answered for it.
   */
  state: 'idle' | 'busy' | 'starting' | 'stopped' | 'unreported'
  /** Requests it has made. Measured, or `null`. */
  requests: number | null
  /** True when this row is a worker whose profile no longer exists. */
  orphaned: boolean
}

export function workerStateLabel(state: WorkerRow['state']): string {
  if (state === 'busy') return 'Busy'
  if (state === 'starting') return 'Starting'
  if (state === 'idle') return 'Idle'
  if (state === 'stopped') return 'Stopped'
  return 'Not reported'
}

/**
 * The Workers list: what is enrolled, joined to what is running.
 *
 * Two sources, and they can disagree in both directions, which is the whole
 * reason this is a function:
 *
 *  - a profile enrolled in the stored fleet that the engine never mentioned is
 *    still a row, marked `unreported` — dropping it would hide a worker somebody
 *    configured, and inventing `idle` for it would report a process nobody saw;
 *  - a worker the engine reports whose profile has been deleted is still a row,
 *    marked `orphaned`, because it is running against a partition that no longer
 *    has a name and that is worth seeing rather than tidying away.
 *
 * The order is the fleet's own, then the orphans. Nothing is sorted by state:
 * a list that reorders itself as workers become busy is a list you cannot click.
 */
export function workerRows(
  fleet: FleetConfig | null,
  status: ScrapingStatus | null,
  profiles: readonly BrowserProfile[],
): WorkerRow[] {
  const byProfile = new Map(profiles.map((profile) => [profile.id, profile]))
  const live = new Map((status?.workers ?? []).map((worker) => [worker.profileId, worker]))
  const rows: WorkerRow[] = []

  for (const profileId of fleet?.profileIds ?? []) {
    const profile = byProfile.get(profileId)
    const worker = live.get(profileId)
    rows.push({
      profileId,
      name: profile?.name ?? profileId,
      avatar: profile?.avatar ?? '',
      enrolled: true,
      state: worker ? worker.state : 'unreported',
      requests: worker?.requests ?? null,
      orphaned: profile === undefined,
    })
  }

  for (const worker of status?.workers ?? []) {
    if (rows.some((row) => row.profileId === worker.profileId)) continue
    const profile = byProfile.get(worker.profileId)
    rows.push({
      profileId: worker.profileId,
      name: profile?.name ?? worker.profileId,
      avatar: profile?.avatar ?? '',
      enrolled: false,
      state: worker.state,
      requests: worker.requests,
      orphaned: profile === undefined,
    })
  }

  return rows
}

/**
 * The one line above the list: how many, and how many are working.
 *
 * The count of rows is a fact this panel holds; the count of *busy* ones is a
 * fact only an engine can report, so on a build that reports nothing it is said
 * to be unmeasured rather than quietly rendered as none. A fleet line reading
 * "4 workers · 0 busy" while four of them are hammering a site is precisely the
 * class of number this panel is built to never print.
 */
export function fleetLine(rows: readonly WorkerRow[], measured: boolean): string {
  const head = countLine(rows.length, 'worker', 'workers')
  if (!measured) return `${head} · busy ${NOT_MEASURED}`
  return `${head} · ${rows.filter((row) => row.state === 'busy').length} busy`
}

/**
 * What the "workers in total" field can do, and the line beside it.
 *
 * A total rather than a delta, and it only ever adds — which is exactly the
 * kind of control somebody presses twice and then wonders why there are twelve
 * of them. So the line always states what is there now, and `total` is `null`
 * whenever pressing would do nothing: the button is then not drawn at all,
 * rather than drawn and inert.
 *
 * Nothing here removes a worker. A worker's clearance is bound to its cookie
 * jar and cannot be earned again by making a new one, so a field that could
 * count down would be a field that quietly destroys the expensive part.
 */
export function mintPlan(typed: string, have: number): { total: number | null; line: string } {
  const wanted = Number.parseInt(typed.trim(), 10)
  if (!Number.isFinite(wanted) || wanted <= 0) {
    return { total: null, line: 'Type how many workers you want in total.' }
  }
  if (wanted <= have) {
    return {
      total: null,
      line: `${countLine(have, 'worker', 'workers')} now. This is a total and it only ever adds — type a bigger number to make more.`,
    }
  }
  return {
    total: wanted,
    line: `${countLine(have, 'worker', 'workers')} now, so this makes ${wanted - have} more.`,
  }
}

/**
 * Why a profile that was picked did not become a worker.
 *
 * The engine refuses two of these in silence — the default profile, and a fleet
 * already at its limit — and a silent refusal on a dropdown is a control that
 * appears to work. The panel cannot know which of the two it was, so it says
 * both rather than guessing one.
 */
export const NOT_ENROLLED =
  'The default profile cannot be a worker — it holds every login from before this feature existed — and a fleet has a limit.'

/** Profiles that are not workers yet — what Add offers. */
export function enrollable(
  fleet: FleetConfig | null,
  profiles: readonly BrowserProfile[],
): BrowserProfile[] {
  const taken = new Set(fleet?.profileIds ?? [])
  return profiles.filter((profile) => !taken.has(profile.id))
}

/* ------------------------------------------------------------------- lift -- */

/**
 * Why this lift cannot be done, or `''`.
 *
 * Every one of these is a sentence rather than a disabled button with no reason,
 * because a greyed control with nothing beside it is the other half of the
 * complaint this browser panel was rebuilt for. The order matters: the first
 * thing missing is the thing to say.
 */
export function liftBlockedReason(
  pageOpen: boolean,
  fromProfileId: string,
  intoProfileIds: readonly string[],
): string {
  // The page first, because the page is the *source*: the session is taken off
  // whatever is in front of the person, and with nothing in front there is
  // nothing this button could take no matter what else is chosen.
  if (!pageOpen) return 'Open the site in this window and sign in to it — the session is taken from the page in front of you.'
  if (fromProfileId === '') return 'Choose the profile that is signed in.'
  if (intoProfileIds.length === 0) return 'Choose at least one worker to inject it into.'
  if (intoProfileIds.includes(fromProfileId)) {
    return 'A profile cannot be lifted into itself.'
  }
  return ''
}

/**
 * The sentence on the confirm button's own line, naming both ends.
 *
 * Both ends, always, and never a count on its own: *"copy into 4 workers"* is
 * the shape of confirmation somebody presses without reading. A lift moves a
 * live logged-in session into other profiles on disk, and the two facts that
 * make it dangerous are which account and which profiles — so both are spelled
 * out, by name, on the control that does it.
 */
export function liftLine(fromName: string, intoNames: readonly string[]): string {
  const into =
    intoNames.length === 1
      ? intoNames[0]
      : `${intoNames.slice(0, -1).join(', ')} and ${intoNames[intoNames.length - 1]}`
  return `Copy the signed-in session from ${fromName} into ${into}.`
}

/**
 * What a lift somebody asked for reads as in the inbox.
 *
 * The asker is named first because it is the fact that decides the answer: a
 * lift request is not a task to be completed, it is a *claim on his logins made
 * by something that is not him*, and the panel's job is to make that visible
 * rather than to make it convenient.
 */
export function liftRequestLine(
  askedBy: string,
  fromName: string,
  intoNames: readonly string[],
): string {
  // "Something", not "An agent" and not the empty string: the panel does not
  // know what asked when the request did not say, and naming it would be the
  // panel inventing the one fact this row exists to report.
  const who = askedBy.trim() === '' ? 'Something' : askedBy.trim()
  const what = liftLine(fromName, intoNames)
  return `${who} asked to ${what.charAt(0).toLowerCase()}${what.slice(1)}`
}

/* ----------------------------------------------------------------- checks -- */

/** How a coverage check reads, and how the row is toned. */
export interface CoverageVerdict {
  tone: 'complete' | 'short' | 'unknown'
  line: string
}

/**
 * Did the run get what the page said it had?
 *
 * The `unknown` case is the important one and it is deliberately not folded into
 * either of the others. A page whose stated total could not be found, or a run
 * nobody counted, produces **no verdict at all** — not "complete", not "looks
 * fine". That is the exact failure being guarded: 7% of a dataset was shipped as
 * complete because nothing ever compared it to a number the page itself printed.
 */
export function coverageVerdict(check: CoverageCheck | null): CoverageVerdict {
  if (check === null) return { tone: 'unknown', line: 'No check has run.' }
  if (check.stated === null) {
    return { tone: 'unknown', line: 'The page did not state a total the pattern could find.' }
  }
  if (check.got === null) {
    return { tone: 'unknown', line: `The page stated ${check.stated.toLocaleString()}; nothing counted what was taken.` }
  }
  const got = check.got.toLocaleString()
  const stated = check.stated.toLocaleString()
  if (check.got >= check.stated) return { tone: 'complete', line: `${got} of ${stated} stated.` }
  const percent = Math.floor((check.got / check.stated) * 100)
  return { tone: 'short', line: `${got} of ${stated} stated — ${percent}%.` }
}

/* ---------------------------------------------------------------- capture -- */

/**
 * What was lost when a bound was hit.
 *
 * A capture store with a limit silently discards, and a silent discard is the
 * same class of event as a skipped asset: the run finishes, the folder looks
 * full, and nothing on screen ever said that the oldest 900 responses are gone.
 */
export function droppedLine(capture: CaptureStatus | null): string {
  if (capture === null || capture.dropped === null) return `Dropped: ${NOT_MEASURED}.`
  if (capture.dropped === 0) return 'Nothing dropped.'
  const what = countLine(capture.dropped, 'response', 'responses')
  return capture.droppedReason === ''
    ? `${what} dropped.`
    : `${what} dropped — ${capture.droppedReason}.`
}

/* ------------------------------------------------------------------ store -- */

/**
 * May this tool be installed?
 *
 * `verified` and nothing else. Not "verified or unknown", not "unknown with a
 * warning", not "unverified once the person confirms" — the store either proved
 * the tool is what it claims or it did not, and a build that cannot evaluate a
 * signature has not proved anything. This is the second lock on that door; the
 * first is in the store itself, and both exist because an install is code
 * arriving on his disk on the strength of a name.
 */
export function canInstall(tool: ToolListing): boolean {
  return !tool.installed && tool.identity === 'verified'
}

/** Why Install is not offered, or `''` when it is. */
export function installBlockedReason(tool: ToolListing): string {
  if (tool.installed) return ''
  if (tool.identity === 'verified') return ''
  if (tool.identity === 'mismatch') return 'What arrived is not what this listing signed. It will not install.'
  if (tool.identity === 'unverified') return 'This tool is not signed, so it cannot be installed.'
  return 'This build could not check the signature, so it will not install.'
}

/**
 * What a tool may reach, before it is on disk.
 *
 * A tool that declares nothing says so in those words. It is not the same as a
 * tool that reaches nothing, and the panel is not entitled to say the second on
 * the strength of the first.
 */
export function reachLine(tool: ToolListing): string {
  return tool.reach.length === 0 ? 'It does not declare what it reaches.' : tool.reach.join(' · ')
}

/* ----------------------------------------------------------------- scopes -- */

/**
 * Which of these settings belong to one profile, and which to the browser.
 *
 * Said on every section rather than once at the top, because the panel edits
 * both kinds on one screen and *"which profile is this"* is the question a
 * per-profile setting has to answer at the point of the control. The fleet is
 * browser-wide because a worker *is* a profile — a list of profiles cannot
 * itself be per profile — and the store is browser-wide because a tool is
 * installed into the app, not into a cookie jar.
 */
export type SettingScope = 'profile' | 'browser'

export function scopeLabel(scope: SettingScope, profileName: string): string {
  return scope === 'browser' ? 'This browser' : profileName === '' ? 'This profile' : profileName
}
