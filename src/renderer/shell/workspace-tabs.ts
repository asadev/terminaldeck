import type { ProviderId, SessionStatus } from '@shared/types'
import { COPILOT_ICON, COPILOT_NAME } from '../copilot/identity'
import { distinguishingIdLength, folderName, shortSessionId } from '../session-title'

/**
 * A tab in the top header.
 *
 * Sessions and browsers live in ONE strip rather than a tab bar plus a
 * separate view switcher: a browser window is a window you opened, exactly
 * like a session is, and splitting them into two controls meant the switcher
 * read as a caption and the browser was effectively unreachable.
 *
 * Overview and Board are singletons — opening one twice focuses the existing
 * tab instead of stacking duplicates that show identical content.
 */
/**
 * Only the things that are a *window you opened*.
 *
 * Overview and Board are views of the current project, not windows, so they
 * live on the side rail. Mixing them into the tab strip meant the strip stopped
 * answering "what do I have open".
 */
export type TabKind = 'session' | 'browser'

export interface WorkspaceTab {
  id: string
  kind: TabKind
  label: string
  /** Sessions only; drives the coloured dot. */
  status?: SessionStatus
  /** Sessions only — the project the session runs in. */
  projectPath?: string
  /**
   * Sessions only — the account the session is signed in as.
   *
   * Absent when no account applies, which is a plain shell or an agent whose
   * config directory this app cannot redirect. Absent is not "the default": it
   * means there is nothing true to say, and a row that says nothing is better
   * than one that names an account the session is not actually isolated to.
   *
   * `provider` is the agent the session was launched as, carried here so the
   * account chip can draw that agent's mark beside the name without reading the
   * account list — which it only does when its menu is opened, because reading
   * it spawns a process per account.
   */
  account?: { id: string; name: string; provider: ProviderId }
  /**
   * Who wanted this session — carried straight off `SessionMeta.origin`.
   *
   * Absent on every session a person started, and the absence is the answer
   * rather than a gap: `shared/types.ts` states that nothing may read it as
   * unknown. The rail groups `'copilot'` under its own heading, because a tab
   * that appeared in the middle of your own work with nothing saying where it
   * came from is the one thing an app that starts processes on its own must not
   * produce. See `renderer/copilot/session-origin.ts`.
   *
   * It is a label and never a permission. A copilot-started session runs in the
   * same folder, under the same account and inside the same confinement as one
   * you started — `src/main/session-origin.test.ts` pins that.
   */
  origin?: string
  /** The action-log row of the copilot turn that started it, when one did. */
  originRunId?: string
  /**
   * True on the **copilot's own session**, and on nothing else.
   *
   * Not the same fact as `origin === 'copilot'` above, and the two are one
   * letter apart in conversation, so: `origin` says *the copilot started this
   * session*, and this says *this session **is** the copilot*. A session the
   * copilot started has `origin` and not this; the copilot has this and not
   * `origin`, because nobody started it on the copilot's behalf.
   *
   * `kind` stays `'session'`, deliberately. The copilot is a real session — a
   * pty, a transcript, a folder, an account — and every place in this window
   * that asks `kind === 'session'` is asking a question the copilot's answer to
   * is yes: draw a status dot, carry the control cluster, mount a terminal, put
   * it in a pane. A third `TabKind` would have made every one of those read
   * "session or copilot", which is the shape of a bug per site rather than a
   * decision in one place. What this flag is for is the handful of things that
   * are genuinely different: it is called Copilot rather than "Session 3", it
   * wears its own glyph, it is not listed in the rail (the pinned row is its
   * home), its folder is not a project you work in, and ⌘W puts it away instead
   * of ending it.
   */
  isCopilot?: true
  /**
   * Browsers only — where the page opens, when something named a destination.
   *
   * Empty for the globe, which goes to the start page, and set when a *link*
   * asked for this tab: a repository in the GitHub panel, or a `target="_blank"`
   * inside a page. It is read once, at mount, and never again — the address
   * after that belongs to the page and lives in the main process, and a second
   * copy here would be a URL bar and a tab label that could disagree about
   * where you are. `label` is what the strip draws, and the page renames it as
   * soon as it has a title of its own.
   */
  url?: string
  /** True for tabs the user can close. */
  closable: boolean
}

/**
 * The narrowest rail that can hold a session's name *and* an account beside it.
 *
 * Measured rather than guessed, off the rail this was written in. A row is 8px
 * of left pad, a 15px status dot, an 8px gap and 6px of right pad, so a 240px
 * rail leaves 203px of line. The account is capped at 12 characters of caption
 * type — about 84px — which leaves 119px, or roughly seventeen characters, for
 * the name. Seventeen is enough to read "Update the parser"; below it the row
 * starts cutting words in half, and the thing that gets cut is always the name.
 */
export const ACCOUNT_NEEDS_RAIL = 240

/**
 * Whether a list of tabs needs to say which account each session belongs to —
 * and whether there is room to say it.
 *
 * ## The first half: is it worth saying
 *
 * Only when the tabs do not all agree. On the ordinary install there is one
 * account, every row would carry the same word, and a label that is on every
 * row carries no information — the same reason the Accounts screen hides its
 * "Default" badge when there is only one account to be the default of. The
 * moment a second account is in play the rows have to be tellable apart,
 * because two sessions in the same folder under two logins are otherwise
 * identical on screen.
 *
 * Sessions with no account are not counted. A plain shell tab appearing beside
 * an agent tab is not a disagreement about accounts, and letting it flip every
 * row into carrying a name would make the label mean "you opened a shell".
 *
 * ## The second half: is there room, and what gives when there is not
 *
 * From the frames of his 2026-08-16 recording — the sidebar read
 * `Session 1, Session 2, Sess…, Session 4, Session 5`, and further in, a name
 * cut to the single character **`S…`**. The row was doing exactly what it was
 * told: the account had a fixed width and the name was the only flexible thing
 * on the line, so the name absorbed every pixel the metadata wanted. That is
 * the identifier losing to the label, which is backwards — a row whose name is
 * one character has stopped identifying anything, while the account name it
 * made room for is a fact you can still get at.
 *
 * So below {@link ACCOUNT_NEEDS_RAIL} the chip goes and the name stays whole.
 * Nothing is lost: the row's tooltip names the account either way, which is
 * where the fact belongs once the line is too short to carry it. Decided here,
 * from a width, rather than in CSS, because the alternative is a container
 * query — and giving the rail a containment context to answer a question that
 * is already a number in a prop would change what `position: fixed` means for
 * everything inside it, including the drag ghost.
 */
export function accountsWorthShowing(
  tabs: readonly WorkspaceTab[],
  railWidth = Number.POSITIVE_INFINITY,
): boolean {
  if (railWidth < ACCOUNT_NEEDS_RAIL) return false
  const seen = new Set<string>()
  for (const tab of tabs) {
    if (tab.kind !== 'session' || !tab.account) continue
    seen.add(tab.account.id)
    if (seen.size > 1) return true
  }
  return false
}

export const SINGLETON_KINDS: readonly TabKind[] = []

export function isSingleton(kind: TabKind): boolean {
  return SINGLETON_KINDS.includes(kind)
}

/** Stable ids for the singletons so they can be found without a lookup table. */
export function singletonId(kind: TabKind): string {
  return `view:${kind}`
}

export const KIND_LABEL: Record<TabKind, string> = {
  session: 'Session',
  browser: 'Browser',
}

/** 15x15 icon path per kind, matching the rail's visual weight. */
export const KIND_ICON: Record<TabKind, string> = {
  session: 'M4 17l6-6-6-6M12 19h8',
  browser: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM3 12h18M12 3c2.5 2.6 2.5 15.4 0 18M12 3c-2.5 2.6-2.5 15.4 0 18',
}

/**
 * The glyph a tab wears — its kind's, except for the one tab that has its own.
 *
 * The copilot keeps the compass it wears in the rail. It is a session and gets
 * everything a session gets, but it is also the only one of its kind in the
 * window, and a pill drawn with the same `>_` as the four beside it would be
 * asking the reader to find it by name. The mark is the same one the pinned row
 * uses, from the same constant, so the row and the pill are recognisably the
 * same thing — which is the whole reason `identity.ts` exists.
 */
export function tabIcon(tab: WorkspaceTab): string {
  return tab.isCopilot ? COPILOT_ICON : KIND_ICON[tab.kind]
}

/**
 * What to call a session on screen.
 *
 * A session starts out titled after the folder it runs in, and it is listed
 * *under* that folder in the sidebar and beside its siblings in the swarm — so
 * the untitled case printed the project's name three times down one column and
 * again across every cell of the grid. Once the agent has named the session,
 * that name is what is worth reading.
 *
 * `folderName` is optional because the swarm and the orphan list have no
 * project heading above them to be redundant with.
 */
export function sessionLabel(title: string, index: number, folderName?: string): string {
  return title && title !== folderName ? title : `Session ${index + 1}`
}

/**
 * The same name, for a tab that is being drawn away from the sidebar's tree.
 *
 * The strip drew `tab.label` raw, and the sidebar draws it through
 * {@link sessionLabel}, so one window was "terminaldeck" along the top and
 * "Session 1" down the side until the agent got round to naming it — seen on
 * screen, not reasoned about. Promoting a tab is a *placement*; it is not a
 * rename, and nothing about the top of the window should make it look like one.
 *
 * The index is recovered from the tab list rather than passed in, because the
 * strip's own order is the promoted order and the number in "Session 3" counts
 * siblings in a folder. Both ends filter the same array the same way, so the
 * numbering cannot drift.
 */
export function tabLabel(tab: WorkspaceTab, tabs: readonly WorkspaceTab[]): string {
  /*
   * The copilot is called Copilot, wherever it is drawn.
   *
   * It is a session, so without this it would be numbered like one — and its
   * title is the name of its own folder, which is exactly the case
   * {@link sessionLabel} turns into `Session N`. So the pinned row in the rail
   * would say "Copilot" and the pill three centimetres above it would say
   * "Session 4", for the same window. One thing wearing two names in two places
   * on one screen is the defect {@link tabIdentities} exists to prevent between
   * two *different* tabs; it would be worse coming from one.
   *
   * Above the `kind` test rather than below it, because the answer does not
   * depend on what else is open — there is exactly one copilot.
   */
  if (tab.isCopilot) return COPILOT_NAME
  if (tab.kind !== 'session') return tab.label
  const siblings = tabs.filter(
    (other) => other.kind === 'session' && other.projectPath === tab.projectPath,
  )
  const index = siblings.findIndex((other) => other.id === tab.id)
  return sessionLabel(
    tab.label,
    index === -1 ? 0 : index,
    tab.projectPath ? folderName(tab.projectPath) : undefined,
  )
}

/**
 * A tab's name, and — only when it needs one — the thing that tells it apart
 * from the tab beside it with the same name.
 *
 * The `qualifier` is null on the ordinary tab, and that is the point: a strip
 * where every tab carries its project name is a strip where the project name
 * carries no information, the same argument {@link accountsWorthShowing} makes
 * about accounts. It appears exactly when the name alone has stopped answering
 * "which one is this".
 */
export interface TabIdentity {
  /** What the tab is called. Never shortened to make room for the qualifier. */
  label: string
  /**
   * The fact that distinguishes it — the folder, or failing that the head of
   * its session id — and null when the name alone already does.
   */
  qualifier: string | null
}

/**
 * The character {@link tabIdentities} joins a label to its qualifier with,
 * written as an escape rather than as the byte itself.
 *
 * NUL is the right separator on the merits: it cannot occur in a POSIX path and
 * it cannot occur in a title, so no pair of genuinely different tabs can be made
 * to look identical by the joining itself. A space or a slash could not promise
 * that, because both occur in the very strings being joined.
 *
 * It is spelled `\u0000` because for a while it was not. A literal NUL byte sat
 * in this file, and one NUL is all it takes for `file`(1) to call a source file
 * `data` and for `grep`(1) to classify it as binary — at which point grep matches
 * it silently and prints nothing at all unless you pass `-a`. The damage is not
 * that a search runs slower; it is that a search *lies*. Running
 * `grep -rn ACCOUNT_NEEDS_RAIL src/` returned the four places that reference the
 * constant and not the one line in this file that declares it, so the honest
 * reading of that output was "the symbol is imported from somewhere else" — a
 * wrong conclusion drawn from a tool that gave no hint it had skipped anything.
 * That cost real time here before anyone thought to check the encoding.
 *
 * The escape compiles to the identical one-character string, so nothing about
 * the behaviour depends on which spelling is used and there is no cost to
 * preferring the one every tool can read. `encoding.test.ts` fails if a raw
 * control byte comes back, in this file or any other.
 */
const PAIR_SEP = '\u0000'

/**
 * Names for a run of tabs, with duplicates disambiguated.
 *
 * ## The failure this exists for
 *
 * Seen in his own recording of 2026-08-16 and reported as part of "session
 * identity is broken": two projects open, each with an unnamed first session,
 * and a tab strip reading `Session 1  Session 2  Session 1  Session 2`. Both
 * halves are individually correct — {@link sessionLabel} numbers a session
 * *within its project*, which is right in the sidebar because the project's
 * name is the heading three pixels above the row. The strip has no headings. It
 * is one flat row, so the same two labels arrive in it with nothing left to tell
 * them apart, and the window is asking the user to guess.
 *
 * ## Why the project, and why only sometimes
 *
 * The project is what actually differs, so it is what gets printed. And it is
 * printed only on the tabs that collide, and only where the project is genuinely
 * the thing that separates them — see {@link tabQualifiers}, which owns the
 * ladder and the reasoning for both rungs.
 *
 * `all` is the whole tab list rather than just the ones being drawn, because
 * {@link tabLabel} counts a session's siblings in its project to number it, and
 * that number must not change depending on which tabs happen to be on the strip.
 */
export function tabIdentities(
  shown: readonly WorkspaceTab[],
  all: readonly WorkspaceTab[] = shown,
): Map<string, TabIdentity> {
  const base = shown.map((tab) => tabLabel(tab, all))
  const qualifiers = tabQualifiers(shown, base)

  const out = new Map<string, TabIdentity>()
  shown.forEach((tab, index) => {
    out.set(tab.id, { label: base[index], qualifier: qualifiers[index] })
  })
  return out
}

/**
 * The qualifiers alone, for a list that already knows what its rows are called.
 *
 * Split out of {@link tabIdentities} for the sidebar, which numbers a session
 * against the siblings in its own project heading and so composes its own
 * labels. Handing it `tabIdentities` would have meant two functions deriving the
 * same name two ways, and the whole subject here is a window that shows one
 * thing two names.
 *
 * `labels` is positional against `tabs` — index for index. The caller supplies
 * both because only the caller knows how it named things.
 *
 * ## The ladder, and why each rung is where it is
 *
 * **The folder, but only when the folder actually separates them.** It used to
 * be applied to every colliding tab that had a project at all, which is right
 * across two projects and useless within one: two sessions in `terminaldeck`
 * whose agents wrote the same title both got the qualifier `terminaldeck`, so
 * the pair went from identical to identically qualified, and the pass that was
 * meant to be the last resort became the only one doing any work. Now the
 * question asked of a colliding group is whether its folders differ; if they do
 * not, the folder is not the distinguishing fact and is not printed. This is
 * also exactly what the sidebar needs, where the folder is the heading three
 * pixels above the row and could never have distinguished anything.
 *
 * **Then the account, but only where the caller is drawing it.** Nothing is
 * printed for this rung — the row has its own column for the account — but a
 * pair the caption already separates must not also be given an id, or the row
 * carries two answers to a question that had one. See `separator` below.
 *
 * **Then the session's own id, cut to the length that separates this run.** The
 * pass this replaces appended an ordinal — `(1)`, `(2)` — and an ordinal is not
 * a fact about a session. It is a fact about a list: close the first of the two
 * and the second silently becomes `(1)`, so the one label a person had learned
 * to recognise now belongs to nothing, and neither number can be looked up
 * anywhere else in the app. The head of the id is stable for the life of the
 * session and is a prefix of what the Inspector and the debug panel print for
 * it, so a row and an inspector can still be matched by eye.
 *
 * How much of that head gets printed is `distinguishingIdLength`'s question,
 * and it is asked rather than assumed: eight characters cost a 264px rail 50px
 * of the line its session name lives on, and the name was the thing paying. See
 * that function for the measurements and for why the length is checked against
 * the ids in play instead of fixed.
 *
 * Reported as *"two sidebar rows with the same visible name and the same
 * account chip, indistinguishable"*: `Update Claude Code terminal to new…`
 * twice, in one folder, both on the same account. Neither the name, nor the
 * folder, nor the account could separate them, and the app had one fact left.
 */
export function tabQualifiers(
  tabs: readonly WorkspaceTab[],
  labels: readonly string[],
  options: { accountsShown?: boolean } = {},
): (string | null)[] {
  const count = (keys: readonly string[]): Map<string, number> => {
    const seen = new Map<string, number>()
    for (const key of keys) seen.set(key, (seen.get(key) ?? 0) + 1)
    return seen
  }

  /*
   * Which folders each name is spread across. A name held by tabs in two
   * folders — or by one tab with a folder and one without, which is an orphaned
   * session beside its twin — is a name the folder can separate. A name whose
   * tabs are all in one folder is not, and printing it there would put the same
   * word on both rows.
   */
  const folders = new Map<string, Set<string>>()
  tabs.forEach((tab, index) => {
    const set = folders.get(labels[index]) ?? new Set<string>()
    set.add(tab.projectPath ?? '')
    folders.set(labels[index], set)
  })

  const byLabel = count(labels)
  const qualified = tabs.map((tab, index) =>
    (byLabel.get(labels[index]) ?? 0) > 1 &&
    (folders.get(labels[index])?.size ?? 0) > 1 &&
    tab.projectPath
      ? folderName(tab.projectPath)
      : null,
  )

  /*
   * The account, when the caller is already drawing it.
   *
   * Not a qualifier this function ever prints — the row prints the account
   * itself, in its own column — but a fact that has to be *counted*, because a
   * pair of rows the account already separates needs nothing further and an id
   * appended to them would be a second identifier for a question that has been
   * answered. The rail is where this matters: two sessions in one folder under
   * two logins are told apart by the caption they each carry.
   *
   * It is a parameter rather than an assumption because the same list is drawn
   * both ways. `accountsWorthShowing` takes the caption off a narrow rail and
   * off a rail where every session is on one account, and a fact that is not on
   * screen cannot distinguish anything — so there, the id is still needed.
   */
  const separator = (index: number): string =>
    options.accountsShown ? tabs[index].account?.id ?? '' : ''

  // The second pass. See {@link PAIR_SEP} for why the parts are joined with a
  // NUL, and why it is spelled as an escape.
  const key = (index: number): string =>
    `${labels[index]}${PAIR_SEP}${qualified[index] ?? ''}${PAIR_SEP}${separator(index)}`
  const byKey = count(labels.map((_, index) => key(index)))

  /*
   * How much of the id each of those rows has to print.
   *
   * Asked of the rows that reach this rung and no others, because that is the
   * set the answer has to separate: an id nobody is printing cannot be confused
   * with one that is. Handed to `distinguishingIdLength` rather than cut to a
   * fixed width here — the length has to be *checked* against the ids in play,
   * and that argument, with the measurements behind it, lives on that function.
   *
   * One length for the whole run, not one per colliding group. These land in a
   * column at the ends of rows whose names have all been cut to the same width,
   * and a column of ids that are four characters on one row and six on the next
   * reads as a value that varies rather than as an identifier.
   */
  const needsId = tabs.map((_, index) => (byKey.get(key(index)) ?? 0) > 1)
  const idChars = distinguishingIdLength(
    tabs.filter((_, index) => needsId[index]).map((tab) => tab.id),
  )

  return tabs.map((tab, index) => {
    if (!needsId[index]) return qualified[index]
    const id = shortSessionId(tab.id).slice(0, idChars)
    return qualified[index] ? `${qualified[index]} · ${id}` : id
  })
}

/**
 * A tab's name, cut to fit, with the *middle* taken out rather than the end.
 *
 * Verified against this machine rather than imagined: the window this was
 * written in had three sessions open in one folder, and every one of them was
 * an agent-written title beginning "Update Claude Code terminal to …". Cut at
 * the end — which is all `text-overflow: ellipsis` can do — the strip read
 * "Update Claude Code ter…" three times and the tabs were genuinely
 * indistinguishable. The half that tells them apart is the tail, and the only
 * way to keep both halves is to lose the middle.
 *
 * A character budget rather than a measured width, because the alternative is
 * measuring text in a layout effect and re-measuring on every resize, and
 * because a budget is a pure function that a test can hold. CSS keeps its own
 * `text-overflow` as the backstop for a run of unusually wide glyphs, so the
 * failure mode of a budget that is slightly too generous is the old behaviour,
 * not an overflowing tab.
 *
 * Budgets under four are returned untouched: there is nothing left to show on
 * either side of an ellipsis, and a lone "…" is worse than a clipped word.
 */
export function middleEllipsis(label: string, budget: number): string {
  if (!Number.isFinite(budget) || budget < 4 || label.length <= budget) return label
  const keep = Math.trunc(budget) - 1
  const head = Math.ceil(keep / 2)
  // Trimmed on the inside edges only. Without it a cut that lands on a space
  // prints "Update Claude …o new API", where the gap reads as part of the name.
  return `${label.slice(0, head).trimEnd()}…${label.slice(label.length - (keep - head)).trimStart()}`
}

/**
 * How many characters of a title a tab in the top strip can hold.
 *
 * Measured off the real thing rather than guessed: a strip tab is capped at
 * 220px, and its icon, status dot, two trailing controls and padding take
 * about 80 of them, leaving 138px of 11px UI text. Twenty-four characters
 * rendered 146px into that box and the CSS backstop clipped the last one, so
 * the tab read "…to ne…" — this is the number that lets the middle cut be the
 * only cut, which is the point of making one.
 */
export const STRIP_LABEL_BUDGET = 22

/**
 * What a strip tab's tooltip should say: the whole title, and the folder under
 * it when there is one.
 *
 * Two lines rather than one joined by a dash, because the title can itself be a
 * sentence with dashes in it. A browser page has no folder and gets one line —
 * an empty second line would read as a missing value.
 */
export function tabTooltip(tab: WorkspaceTab, label: string): string {
  return tab.projectPath ? `${label}\n${tab.projectPath}` : label
}

/**
 * Which tab should take focus after `closingId` goes away.
 *
 * Falls to the right neighbour, then the left, then nothing — the same rule
 * every tabbed editor uses, so closing a run of tabs walks predictably instead
 * of jumping back to the first one each time.
 */
export function nextActiveId(tabs: WorkspaceTab[], closingId: string): string | null {
  const index = tabs.findIndex((t) => t.id === closingId)
  if (index === -1) return tabs[0]?.id ?? null
  const remaining = tabs.filter((t) => t.id !== closingId)
  if (remaining.length === 0) return null
  return remaining[index]?.id ?? remaining[index - 1]?.id ?? remaining[0].id
}

/* ------------------------------------------------------------ dragging -- */

/**
 * The one thing a dragged tab carries, and the only format it is offered in.
 *
 * A private MIME type rather than `text/plain`, which matters more here than it
 * usually would. This window is full of drop targets that are not ours: a
 * terminal accepts dropped text and types it, the address bar accepts a dragged
 * URL, and a chat composer accepts anything at all. A tab offered as plain text
 * would be droppable into every one of them, and dropping a session onto a
 * terminal would type its opaque id into whatever agent is running there.
 * Offering only this format means every surface that did not ask for a tab
 * simply refuses the drop, which is the correct behaviour and needs no code.
 *
 * The value is the tab's `id`, which is all a receiver needs — the tab itself is
 * already in the list both ends are rendering from, and serialising a copy of it
 * would let the two drift apart mid-drag.
 */
export const TAB_DRAG_MIME = 'application/x-terminaldeck-tab'

/**
 * The slice of `DataTransfer` the helpers below touch.
 *
 * Structural rather than the DOM type, because this project's tests run in Node
 * with no DOM at all. A real `DataTransfer` satisfies it.
 */
export interface TabTransfer {
  readonly types: ReadonlyArray<string>
  setData(format: string, data: string): void
  getData(format: string): string
  effectAllowed: string
}

/** Begin dragging a tab. Call from the drag source's `onDragStart`. */
export function startTabDrag(transfer: TabTransfer, tabId: string): void {
  transfer.setData(TAB_DRAG_MIME, tabId)
  // `move`, not `copy`: promoting a tab to the strip and folding it back into
  // the rail are both moves, and the cursor is the only thing telling the user
  // which of the two they are about to do.
  transfer.effectAllowed = 'move'
}

/**
 * Is the thing being dragged one of our tabs?
 *
 * The test a `dragover` handler has to use. During a drag the browser puts the
 * data in *protected mode* — `types` is readable, `getData` returns the empty
 * string — so a target that decided whether to accept a drop by reading the
 * payload would refuse every drop it was written to accept. Verified behaviour,
 * not a precaution: it is in the HTML drag-and-drop spec and every engine
 * implements it.
 */
export function isTabDrag(transfer: TabTransfer | null | undefined): boolean {
  return transfer ? Array.from(transfer.types).includes(TAB_DRAG_MIME) : false
}

/** The tab id being dropped, or null when the drop was something else. */
export function readTabDrag(transfer: TabTransfer | null | undefined): string | null {
  if (!isTabDrag(transfer)) return null
  const id = transfer?.getData(TAB_DRAG_MIME) ?? ''
  return id === '' ? null : id
}
