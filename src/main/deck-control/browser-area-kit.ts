import type { ToolContext } from './catalogue'
import { Refused, type Tier } from './surface'

/**
 * The small parts every 0.16.0 browser tool is made of: reading an argument,
 * reading which action was asked for, and the one refusal they all share.
 *
 * ## Why one action argument per tool, and not one tool per button
 *
 * Asad asked for *"every single thing in very much detail. Everything that I can
 * do manually should be able to do through the MCP"*, and the browser is where
 * that is the most buttons: downloads, history, profiles, saved logins, site
 * data, the Chrome import, the scraping panel, two stores, the windows and every
 * control on a page's toolbar. One tool per button would be well over a hundred
 * tools, and `catalogue.ts` is plain about what that does — a model choosing
 * between thirty things chooses worse, and every definition is paid for on every
 * turn. So each panel is one tool, named for the panel, and the button is an
 * `action`. Every one of them carries an `index` line and is fetched through
 * `tools.describe`, so the standing cost of the whole set is a dozen lines.
 *
 * ## Why the tier is worked out from the action, upwards only
 *
 * A tool's `tier` is its gentlest action, and {@link escalateBy} raises it for
 * the rest. `control.ts` only ever takes the higher of the two, so an action
 * this file has never heard of — a model's typo — reads as `alter` rather than
 * as `read`, and is then refused by the tool with the list of real ones before
 * anything happens. The dangerous reading of an argument nobody understands is
 * the one to take; `control.ts` takes it too when an escalation rule throws.
 */

/** A string argument that must be there. Refused, not thrown, so it reaches the log as a rule. */
export function str(args: Record<string, unknown>, key: string): string {
  const value = args[key]
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new Refused('not-permitted', `${key} is required and must be a non-empty string`)
  }
  return value
}

/** A string argument that may be absent. Empty counts as absent. */
export function optStr(args: Record<string, unknown>, key: string): string | null {
  const value = args[key]
  if (value === undefined || value === null || value === '') return null
  if (typeof value !== 'string') throw new Refused('not-permitted', `${key} must be a string`)
  return value
}

/** A whole number, clamped into range rather than refused — the way every other tool here reads one. */
export function optInt(
  args: Record<string, unknown>,
  key: string,
  fallback: number,
  min: number,
  max: number,
): number {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    throw new Refused('not-permitted', `${key} must be a number`)
  }
  return Math.min(Math.max(Math.trunc(value), min), max)
}

/** True or false, or the fallback when it was left out. */
export function optBool(args: Record<string, unknown>, key: string, fallback: boolean): boolean {
  const value = args[key]
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'boolean') throw new Refused('not-permitted', `${key} must be true or false`)
  return value
}

/**
 * Which action was asked for, or the refusal that lists the real ones.
 *
 * The refusal names every action because a model that sent `remove` to a tool
 * whose verb is `delete` needs the word, not a "no" — the same reason
 * `extension-tools.ts` names the listing call in its own refusal.
 */
export function actionOf<A extends string>(
  args: Record<string, unknown>,
  actions: readonly A[],
  fallback: A,
): A {
  const raw = args.action
  if (raw === undefined || raw === null || raw === '') return fallback
  if (typeof raw !== 'string' || !actions.includes(raw as A)) {
    throw new Refused('not-permitted', `action must be one of: ${actions.join(', ')}`)
  }
  return raw as A
}

/**
 * The tier for an action, for a tool's `escalate`.
 *
 * Never throws — `control.ts` runs this ahead of the precheck — and answers
 * `alter` for anything it does not recognise. See the header for why that is
 * the right direction.
 */
export function escalateBy<A extends string>(
  tiers: Readonly<Record<A, Tier>>,
  fallback: NoInfer<A>,
): (args: Record<string, unknown>) => Tier {
  return (args) => {
    const raw = args.action
    const action = raw === undefined || raw === null || raw === '' ? fallback : raw
    if (typeof action !== 'string') return 'alter'
    return Object.prototype.hasOwnProperty.call(tiers, action) ? tiers[action as A] : 'alter'
  }
}

/**
 * Refuse an ordinary session.
 *
 * None of these tools is on `SESSION_TOOLS`, so a session cannot reach them
 * through the transport at all; this is the second lock, for the same reason
 * `boundOf` refuses a session naming another session's window. A session may
 * act on the windows the person attached to it, through the six browser verbs,
 * and on nothing else in the browser: not the downloads list, not the history,
 * not the profiles and not the other windows. A tool whose only safety was a
 * list in another file is one edit away from handing a shell on a server the
 * whole of somebody's browser.
 */
export function notASession(context: ToolContext, tool: string): void {
  if (context.caller?.kind === 'session') {
    throw new Refused(
      'not-permitted',
      `${tool} is the browser's own settings, and a session reaches only the windows attached to it. ` +
        'Use browser.open, browser.read and browser.step on those.',
    )
  }
}

/**
 * A profile named by a caller, as an id — or the profile switched on when it
 * named none.
 *
 * By name or by id, because a person says "the Work profile" and a model that
 * listed profiles has both. The name match is case-insensitive and exact; a
 * near miss is refused with the names that exist rather than guessed at,
 * because a guessed profile is somebody else's logins.
 */
export function profileIdOf(
  named: string | null,
  profiles: readonly { id: string; name: string }[],
  current: string,
): string {
  if (named === null) return current
  const byId = profiles.find((profile) => profile.id === named)
  if (byId) return byId.id
  const wanted = named.trim().toLowerCase()
  const byName = profiles.find((profile) => profile.name.trim().toLowerCase() === wanted)
  if (byName) return byName.id
  throw new Refused(
    'not-permitted',
    `there is no browser profile called ${named}. These exist: ${profiles.map((p) => p.name).join(', ') || 'none'}.`,
  )
}
