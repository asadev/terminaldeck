import type { ProviderId } from '@shared/types'
import { MAX_PROMOTED } from './workspace-strip'

/**
 * The tab strip's arrangement, written in terms that outlive the processes it
 * is an arrangement of.
 *
 * ## The failure this exists for
 *
 * Quit the app with six sessions arranged across the bar, launch it again, and
 * the bar is empty. Every session came back — `session-restore.ts` continues
 * each conversation and announces each tab — and not one of them is where it
 * was. `workspace-strip.ts` explains exactly why in its `defaultStorage` note:
 * the promoted order is a list of **session ids**, an id is a pty in a main
 * process that no longer exists, and so the order is deliberately kept in
 * `sessionStorage`, whose lifetime ends with the window. That decision is right
 * and nothing here changes it. What it leaves open is that an arrangement
 * somebody made by hand is thrown away by quitting, which is the one thing this
 * app asks people not to have to redo.
 *
 * ## The identity, which is `session-restore.ts`'s and not this file's
 *
 * `SavedSession` states it in one sentence: *"the identity that survives a
 * restart is an agent of this kind, in this folder, as this profile"* — which
 * is precisely what the main process writes into `openSessions` and precisely
 * what it hands back to `startSession` on the next launch. So that triple is
 * what an arrangement is written in, and the tab that comes back carrying it is
 * the tab the arrangement is about. Anything narrower (the folder alone) groups
 * tabs that are not the same tab; anything wider is a fact the restore does not
 * carry and could not put back.
 *
 * The renderer derives it rather than being told it, because it already holds
 * all three off `SessionMeta` and a second copy crossing the bridge would be a
 * field that can disagree with the folder beside it. `conversationScope` in
 * `session-restore.ts` keys on the same three things for a different question,
 * and the NUL separator is chosen there for the reason it is chosen here.
 *
 * ## Why the occurrence number, and why it is positional
 *
 * Two tabs can be the same agent, in the same folder, as the same account —
 * `planRestore` has a whole case about that pair — so the triple alone is not
 * an identity, it is a *group*. Numbering them by their position in the tab list
 * is the only discriminator available on either side of a restart: the ledger
 * writes `openSessions` in tab order, `planRestore` keeps that order, and this
 * window builds its list in the order sessions are announced. Nothing finer is
 * knowable — two untouched tabs of the same agent in the same folder are
 * indistinguishable in fact as well as in this string, which
 * `SavedSession.lastSeenAt` says out loud about the same pair.
 *
 * ## Only local sessions carry one
 *
 * A browser page is drawn in the strip whether or not anything promoted it (see
 * `shownTabs`), so it needs no arrangement to come back to. A session on a
 * paired machine or a shell on a server is not reopened at launch at all —
 * nothing brings one back to be positioned. A tab with no anchor is simply not
 * part of the saved arrangement, which is the honest answer rather than an id
 * that would resolve, next run, to a different window wearing the same number.
 */

/** Where the arrangement is kept. Local storage: the point is to outlive the run. */
export const ARRANGEMENT_KEY = 'terminaldeck.strip.arrangement'

/** The separator, spelled once. See the note above for why it is this character. */
const SEP = '\u0000'

/** As much of a session as the identity above is made of. */
export interface AnchorableSession {
  provider: ProviderId
  cwd: string
  /** The account it runs as, absent when none applies. See `SessionMeta.profileId`. */
  profileId?: string
}

/**
 * A tab, as far as this file is concerned: an id, and what it will be called
 * after the process behind it has been replaced.
 */
export interface AnchoredTab {
  id: string
  /** Absent for everything a restart does not bring back. */
  anchor?: string
}

/**
 * The part of the identity that does not depend on which of the group this is.
 *
 * NUL as the separator, for `conversationScope`'s reason: it cannot occur in a
 * path, a provider id or a profile id on any platform this runs on, so no two
 * different triples can join into the same string. A `:` can — provider `a`
 * with folder `b/c` and provider `a/b` with folder `c` would collide.
 */
export function sessionAnchor(session: AnchorableSession): string {
  return `${session.provider}${SEP}${session.cwd}${SEP}${session.profileId ?? ''}`
}

/**
 * Every tab that has one, keyed by tab id, carrying the full anchor — the base
 * plus its place among the tabs that share it.
 *
 * Built over the whole tab list in one pass rather than per tab, because the
 * occurrence number is a fact about the list and not about the tab: asking a
 * tab for its own anchor is asking a question that has no answer until you know
 * what else is open.
 */
export function anchorsByTab(tabs: readonly AnchoredTab[]): Map<string, string> {
  const counted = new Map<string, number>()
  const out = new Map<string, string>()
  for (const tab of tabs) {
    if (tab.anchor === undefined || tab.anchor === '') continue
    const nth = counted.get(tab.anchor) ?? 0
    counted.set(tab.anchor, nth + 1)
    out.set(tab.id, `${tab.anchor}${SEP}${nth}`)
  }
  return out
}

/** The same map the other way round, which is the direction a restore reads it. */
export function tabsByAnchor(anchors: ReadonlyMap<string, string>): Map<string, string> {
  const out = new Map<string, string>()
  for (const [id, anchor] of anchors) out.set(anchor, id)
  return out
}

/**
 * The arrangement to write down, given what is promoted right now.
 *
 * ## Why the previous arrangement is an argument
 *
 * Because a launch fills the tab list in waves, and this is written straight
 * through to storage. `pruneOrder` has the measured version of that hazard —
 * five promoted tabs in, four out, four times out of four — and the shape here
 * is the same: a tab whose session has not been announced yet is not in `tabs`,
 * so an arrangement rebuilt from `order` alone would drop it, permanently,
 * seconds before it arrived.
 *
 * So an anchor this window has **not yet seen a tab for** is carried over. An
 * anchor whose tab has arrived is decided by the order: in it means promoted,
 * out of it means the person folded it away, and both are current facts about a
 * window that is fully awake.
 *
 * ## Why the carried-over ones go last, and why there is a cap
 *
 * An anchor can fail to resolve for a whole run and be perfectly meaningful —
 * the folder is on a volume that is not mounted, restore-on-launch is switched
 * off, the spawn failed — so it is not evidence of anything to throw away. But
 * it is also not evidence that a tab is coming, so it must never crowd out one
 * that is here. Live anchors first, in the order the strip has them; the
 * unresolved remainder after them, in the order they were saved; the whole
 * thing truncated to {@link MAX_PROMOTED}.
 *
 * That truncation is the bound that keeps this from becoming the ghost list
 * `defaultStorage` refuses to allow in the promoted order. It is a weaker
 * problem here by construction — these are anchors and not ids, they are never
 * counted against `promote`'s cap, and one that names nothing resolves to
 * nothing — but a list that grows for ever is still a list that grows for ever.
 */
export function nextArrangement(
  order: readonly string[],
  anchors: ReadonlyMap<string, string>,
  previous: readonly string[],
  seen: ReadonlySet<string>,
): string[] {
  const live: string[] = []
  for (const id of order) {
    const anchor = anchors.get(id)
    if (anchor !== undefined) live.push(anchor)
  }

  const arrived = new Set<string>()
  for (const [id, anchor] of anchors) if (seen.has(id)) arrived.add(anchor)

  const held = new Set(live)
  const waiting = previous.filter((anchor) => !held.has(anchor) && !arrived.has(anchor))
  return [...live, ...waiting].slice(0, MAX_PROMOTED)
}

/**
 * Put the arrangement back, for the tabs that have just turned up.
 *
 * ## Why only the ones that have just turned up
 *
 * Because otherwise this undoes the user. A restored tab the person then folds
 * off the bar is a tab whose anchor is still in the saved arrangement, and a
 * pass that looked at every live tab would put it straight back on the next
 * render — a control that does nothing, which is the one thing the strip's ✕
 * has already been fixed for once. `arriving` is the strip's own `seen` ref read
 * backwards: an anchor is honoured the first time its tab exists in this window
 * and never again.
 *
 * ## Where each one goes
 *
 * Between the neighbours it was saved between. A tab that arrives in the third
 * wave of a launch has to land in the middle of the ones that arrived in the
 * first, or the bar would come back holding the right tabs in the order the
 * main process happened to spawn them — which is not an arrangement anybody
 * made. So the insertion point is just after the last already-placed tab that
 * was saved *before* this one, and 0 when there is none, which puts a tab that
 * was first back at the front.
 *
 * The cap is `promote`'s, honoured here rather than by calling through it,
 * because these insertions are positional and `promote` takes an index in the
 * resulting list. It refuses in the same direction: the tabs already placed stay
 * where they are and the surplus is simply not promoted, which leaves it visible
 * as a transient tab rather than evicting something the person kept.
 */
export function seedArrangement(
  order: readonly string[],
  arrangement: readonly string[],
  anchors: ReadonlyMap<string, string>,
  arriving: ReadonlySet<string>,
): string[] {
  const byAnchor = tabsByAnchor(anchors)
  const next = [...order]
  for (let index = 0; index < arrangement.length; index += 1) {
    const anchor = arrangement[index]
    if (anchor === undefined) continue
    const id = byAnchor.get(anchor)
    if (id === undefined || !arriving.has(id) || next.includes(id)) continue
    if (next.length >= MAX_PROMOTED) break

    let at = 0
    for (let before = 0; before < index; before += 1) {
      const earlier = arrangement[before]
      if (earlier === undefined) continue
      const placed = byAnchor.get(earlier)
      const where = placed === undefined ? -1 : next.indexOf(placed)
      if (where >= 0 && where + 1 > at) at = where + 1
    }
    next.splice(at, 0, id)
  }
  return next
}

/**
 * Whether two arrangements are the same arrangement.
 *
 * The gate on the write, and it is load-bearing rather than an optimisation.
 * `App.tsx` builds the tab list fresh on every render, so the effect that keeps
 * this current runs on every render — a session printing a line, a status dot
 * changing colour — and a `JSON.stringify` and a synchronous `setItem` on each
 * of those is a disk write per frame of terminal output.
 */
export function sameArrangement(a: readonly string[], b: readonly string[]): boolean {
  return a.length === b.length && a.every((anchor, index) => anchor === b[index])
}

/* --------------------------------------------------------------- storage -- */

/**
 * The arrangement as it was left by the last run of the app.
 *
 * Local storage, and that is the entire difference from `workspace-strip.ts`'s
 * own `readPromoted`: the promoted order is ids and must die with the window,
 * and this is anchors and must not. The two keys are separate for the same
 * reason — one of them is worthless after a quit and the other is the only
 * thing that still means anything.
 *
 * Every failure answers with an empty arrangement, which is the app as it
 * behaved before this file existed rather than an error: an unarranged bar
 * costs a drag, and refusing to render costs the window.
 */
export function readArrangement(storage: Storage | null): string[] {
  if (!storage) return []
  try {
    const raw = storage.getItem(ARRANGEMENT_KEY)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed
      .filter((entry): entry is string => typeof entry === 'string' && entry !== '')
      .slice(0, MAX_PROMOTED)
  } catch {
    return []
  }
}

export function writeArrangement(storage: Storage | null, arrangement: readonly string[]): void {
  if (!storage) return
  try {
    storage.setItem(ARRANGEMENT_KEY, JSON.stringify([...arrangement]))
  } catch {
    // Quota, or a store disabled by policy. Forgetting the arrangement costs a
    // drag on the next launch and nothing else.
  }
}

/**
 * `window.localStorage`, when this window has one.
 *
 * A try/catch and not a `typeof` test alone, because reading the property can
 * itself throw where storage is disabled by policy — the same guard
 * `defaultStorage` uses one file over, for the same reason.
 */
export function arrangementStorage(): Storage | null {
  try {
    return typeof window === 'undefined' ? null : window.localStorage
  } catch {
    return null
  }
}
