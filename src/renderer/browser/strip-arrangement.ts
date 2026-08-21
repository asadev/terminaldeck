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
 * ## What a tab is called, and why the renderer does not decide
 *
 * `SessionMeta.tabKey` — a name the main process mints once, when it first
 * writes the session into `openSessions`, and hands back to the spawn on the
 * next launch. This module reads it and derives nothing.
 *
 * It used to derive everything, and that was the defect. The identity available
 * to a window is the one `session-restore.ts` names in a sentence — *an agent
 * of this kind, in this folder, as this profile* — and that is an identity of a
 * **session**, not of a tab: two tabs can be all three of those things at once.
 * The only discriminator a renderer can compute for such a pair is where they
 * sit in the list, so the arrangement was written as "the agent, the folder,
 * the account, and which of that group you are", and both halves of that failed
 * in the running app:
 *
 *  - **They swap.** Two identical siblings, neither typed into, are
 *    indistinguishable in fact as well as in the string — so which of them
 *    comes back as number 0 is whichever the restore happened to announce
 *    first, and the pair can arrive the other way round.
 *  - **Closing one moves the other.** Numbers are positions, so shutting the
 *    left sibling makes the right one number 0 — under the name its neighbour
 *    had — and leaves the saved arrangement holding a number nothing answers
 *    to. Bounded and harmless on its own; it still costs a slot in a capped
 *    list and it is still the bar quietly disagreeing with itself.
 *
 * Neither is fixable in this file, because neither is a computation that was
 * done wrong. They are the two shapes of "there is nothing here to tell these
 * apart", and the answer had to be a fact somebody else remembers. So a tab is
 * now called what the main process called it, and that is the whole of it: no
 * separator, no group, no number, nothing to recompute when the tabs around it
 * change.
 *
 * ## Only a tab that comes back has one
 *
 * A browser page is drawn in the strip whether or not anything promoted it (see
 * `shownTabs`), so it needs no arrangement to come back to. A session on a
 * paired machine, a shell on a server, the copilot's own session and a session
 * held inside a device's folder grant are not restored at launch at all —
 * nothing brings one back to be positioned, and `host-core.ts` mints no key for
 * any of them, from the same condition that decides whether it writes the
 * session down. So "has a key" and "is part of the saved arrangement" are one
 * fact with one owner, rather than a rule this file applied by guessing which
 * kinds of tab a restart returns.
 */

/** Where the arrangement is kept. Local storage: the point is to outlive the run. */
export const ARRANGEMENT_KEY = 'terminaldeck.strip.arrangement'

/** As much of a session as this file needs: the name the main process gave it. */
export interface AnchorableSession {
  /** See `SessionMeta.tabKey`. Absent for a session no launch brings back. */
  tabKey?: string
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
 * What this tab is called across a restart, or nothing.
 *
 * A pass-through, and deliberately still a function: it is the one place that
 * says *which* field of a session the arrangement is written in, so a change of
 * mind about that is a change in one place rather than a search for every
 * spelling. It used to join three fields with a NUL and count the duplicates;
 * the note above is why it no longer does either.
 */
export function sessionAnchor(session: AnchorableSession): string | undefined {
  return session.tabKey
}

/**
 * Every tab that has a name, keyed by tab id.
 *
 * Over the whole list in one pass rather than per tab, for one reason left over
 * from when the name depended on the list: two tabs must never end up under one
 * name. They cannot — the main process mints a key per session — but a window
 * is handed these over a bridge, and a duplicate arriving here would silently
 * make one tab shadow the other in `tabsByAnchor`. First claim wins and the
 * second tab is simply unarranged, which costs a drag; the alternative is a bar
 * that puts a tab back into somebody else's place.
 */
export function anchorsByTab(tabs: readonly AnchoredTab[]): Map<string, string> {
  const claimed = new Set<string>()
  const out = new Map<string, string>()
  for (const tab of tabs) {
    if (tab.anchor === undefined || tab.anchor === '') continue
    if (claimed.has(tab.anchor)) continue
    claimed.add(tab.anchor)
    out.set(tab.id, tab.anchor)
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
 * ## Why "seen" is a set of anchors and not of tabs
 *
 * Because a tab that is closed stops being a tab, and the question here is
 * about the *name*, which outlives it. `seen` used to be the strip's set of
 * session ids and the arrived set was derived from the tabs that are open right
 * now — so closing a window took its anchor out of the derivation, the anchor
 * fell back into "not seen yet", and it was carried over for ever after. That
 * is the stale entry a closed sibling left behind: bounded by the cap, resolving
 * to nothing on every launch, and occupying a slot a real tab could have used.
 * An anchor this window has ever had a tab for is a fact that only ever grows,
 * which is what the caller keeps and hands in.
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
  arrived: ReadonlySet<string>,
): string[] {
  const live: string[] = []
  for (const id of order) {
    const anchor = anchors.get(id)
    if (anchor !== undefined) live.push(anchor)
  }

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
