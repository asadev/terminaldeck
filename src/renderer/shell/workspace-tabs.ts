import type { ProviderId, SessionStatus } from '@shared/types'
import { COPILOT_ICON, COPILOT_NAME } from '../copilot/identity'
import { distinguishingIdLength, folderName, isMachineAndPath, shortSessionId } from '../session-title'

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
  /**
   * The machine this session is running on, when it is not this one.
   *
   * Absent on everything local, and absent is the answer rather than a gap: a
   * tab with no machine is a tab whose process belongs to this app, which is
   * every tab this window has ever had until now.
   *
   * ## Why a remote session is a tab at all now
   *
   * It deliberately was not, for one night. A remote session covered the pane
   * the way a sidebar view does and had no pill, on the argument that a ✕ on the
   * pill would promise to end something this window does not own. Asad looked at
   * that and asked for the opposite, in as many words: *"When I click on any
   * session — the shape of the icon, top bar header is not same, and I cannot
   * drag it up there… So it should be there on the top, just like the normal
   * internal local session."* The argument was not wrong about the ✕; it was
   * wrong about which half to give up. The ✕ is answered by the `close` verb on
   * the wire, which lands the request on the far machine and ends the process
   * there, and the pill is what he actually asked for.
   *
   * ## What it carries, and what it does not
   *
   * The machine's id, because that is the handle every verb needs, and its name,
   * because four surfaces print it and none of them can read the machines view.
   * Not its state, not its capabilities: whether a machine is worth drawing is
   * `reachableMachines`, one level up, and a tab that carried the answer would
   * be a second place for it to be decided.
   *
   * `closable` says whether the ✕ can act — see {@link machineTabId} for how a
   * far machine that never advertised `close` arrives here as a tab with no ✕
   * rather than a ✕ that does nothing.
   */
  machine?: { id: string; name: string }
  /**
   * The server this shell is running on, when it is on one.
   *
   * Absent on everything else, and the absence is the answer rather than a gap,
   * exactly as it is for {@link WorkspaceTab.machine} above: a tab with neither
   * field is a tab whose process belongs to this app.
   *
   * ## Why a shell on a server is a tab at all
   *
   * It deliberately was not, for a day. `SERVERS-DESIGN.md` §5.5 argued the
   * opposite in as many words — *"a server terminal is not a session — it has no
   * transcript, no account, no model, no cost, and none of the control cluster
   * that makes the strip's chrome meaningful; a pill carrying six controls that
   * all do nothing is the exact defect `panels.ts` records the copilot page
   * having had, in reverse."* — and the terminal therefore lived inside the
   * Machines panel, on a page of its own, reachable only while that panel was
   * the thing on screen.
   *
   * That argument is the same one that was made about a *remote* session the
   * night before, and it lost for the same reason. Asad has now said it three
   * times about machines that are not this one: *"Keep the same one browser
   * window for every device… the shape of the application should not be changing
   * for local and remote devices. It should act like that same."* A server was
   * getting a lesser product than a paired laptop — no row in the rail, no pill,
   * no ⌘W, nothing you could drag to the top — and that is the defect.
   *
   * The half of the old argument that was *right* is kept, and it is kept the
   * way this window already keeps it: a control that cannot act is **absent**.
   * `App.tsx` withdraws the model, effort and connector cluster over a server
   * session exactly as it withdraws it over a remote one, and for a reason that
   * is mechanical rather than a matter of taste — see the note beside
   * `SessionControls` there. A pill is not a control cluster; it is the answer
   * to *what do I have open*, and a shell on somebody's server is one of those.
   *
   * ## What it carries
   *
   * The server's id, because that is the handle every verb needs, and its name,
   * because the rail heading, the pill's tooltip, the window bar and the close
   * confirmation all print it and none of them can read the servers list.
   */
  server?: { id: string; name: string }
}

/**
 * The prefix on a remote session's tab id, and the one place the joining rule
 * lives.
 *
 * A remote session has two handles — the machine and the session — and a tab has
 * one id. Something has to join them, and the thing that must not happen is that
 * two files each decide how: a separator agreed in two places is a separator
 * that will disagree in one of them. So the rule is here, in the module that
 * defines what a tab is, and {@link machineTabId} and {@link readMachineTabId}
 * are the only code that knows it.
 *
 * The separator is a space and not the NUL `PAIR_SEP` uses a few hundred lines
 * down, and the difference is not taste. That one joins two strings for a
 * *comparison*; this one produces a value that goes into the DOM — `data-tab-id`
 * on every strip tab — and is then read back through
 * `querySelector('[data-tab-id="…"]')` to scroll the selected tab into view. A
 * control character in an attribute selector is a road with no traffic on it,
 * and the failure would be the strip quietly refusing to scroll rather than
 * anything a test would trip over. A space is ordinary, escapes cleanly, and is
 * safe here for a stated reason: a machine id is minted by `machines/store.ts`
 * as a UUID, so the **first** space in the joined string is always the one this
 * function put there. Only the machine id has to be space-free; the session id
 * is whatever the far machine calls it and is taken as the whole remainder.
 */
const MACHINE_TAB_PREFIX = 'machine '

/** The tab id for one session on another machine. */
export function machineTabId(machineId: string, sessionId: string): string {
  return `${MACHINE_TAB_PREFIX}${machineId} ${sessionId}`
}

/**
 * The two handles back out of a tab id, or null when the id is a local tab's.
 *
 * Null rather than a throw, because every caller is asking the *question* — is
 * this thing on another machine — rather than asserting the answer. `selectTab`
 * and `closeTab` both take an id from a click and have to route it, and a
 * routing decision that throws on the ordinary case is not a routing decision.
 */
export function readMachineTabId(id: string): { machineId: string; sessionId: string } | null {
  if (!id.startsWith(MACHINE_TAB_PREFIX)) return null
  const rest = id.slice(MACHINE_TAB_PREFIX.length)
  const cut = rest.indexOf(' ')
  if (cut <= 0 || cut === rest.length - 1) return null
  return { machineId: rest.slice(0, cut), sessionId: rest.slice(cut + 1) }
}

/**
 * The prefix on a server shell's tab id.
 *
 * The same arrangement as {@link machineTabId} a few lines up, and written as a
 * second pair rather than folded into that one on purpose. The two handles look
 * alike — an id for the far thing, an id for the session on it — and they are
 * not interchangeable: a machine id names a paired desktop that runs this app
 * and answers `machines:*`; a server id names a stored address this app signs in
 * to over its own connection and answers `servers:*`. Routing is done by asking
 * both questions in turn, and a single shared prefix would make the answer to
 * *which bridge does this belong to* a matter of looking the id up somewhere,
 * which is the thing an id is for.
 *
 * The separator is a space, for the reason {@link MACHINE_TAB_PREFIX} gives: the
 * joined value ends up in `data-tab-id` and is read back through an attribute
 * selector, so a control character would be a road with no traffic on it. A
 * server id is minted by `main/servers/store.ts` as a UUID, so the first space
 * in the remainder is always the one this function put there.
 */
const SERVER_TAB_PREFIX = 'server '

/**
 * The tab id for one shell on one server.
 *
 * `shellKey` is minted **here**, in the renderer, and is not the far end's
 * handle. That is deliberate and it is the whole reason this feature can draw a
 * pill the instant somebody presses ＋: the id the far end hands back does not
 * exist until the connection is up and the shell has been opened, which is a
 * round trip across the internet. A tab that had to wait for it would be a press
 * with nothing on screen for a second and a half, and a failure would have
 * nowhere to be reported — see `ServerTerminal`, which says so in the terminal
 * itself, in the pane the tab already opened.
 */
export function serverTabId(serverId: string, shellKey: string): string {
  return `${SERVER_TAB_PREFIX}${serverId} ${shellKey}`
}

/** The two handles back out of a server tab's id, or null when it is not one. */
export function readServerTabId(id: string): { serverId: string; shellKey: string } | null {
  if (!id.startsWith(SERVER_TAB_PREFIX)) return null
  const rest = id.slice(SERVER_TAB_PREFIX.length)
  const cut = rest.indexOf(' ')
  if (cut <= 0 || cut === rest.length - 1) return null
  return { serverId: rest.slice(0, cut), shellKey: rest.slice(cut + 1) }
}

/**
 * A status string from another machine, narrowed to one this window can draw.
 *
 * The wire carries `status` as a plain string — `RemoteSession` restates the
 * far end's type rather than importing it — so it can be a state a newer build
 * over there knows about and this one does not. `idle` is the answer for those,
 * and it is the honest one: the dot means "nothing recognisable on screen",
 * which is exactly what this end knows. The alternative is a `StatusDot` handed
 * a string it has no colour for, which draws nothing at all and takes the row's
 * 15px lead-in with it — the rows either side would then be indented differently
 * from a session that is merely newer than this app.
 */
const STATUSES: readonly SessionStatus[] = [
  'idle',
  'working',
  'waiting',
  'input',
  'completed',
  'exited',
]

export function asSessionStatus(raw: string): SessionStatus {
  return STATUSES.find((known) => known === raw) ?? 'idle'
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
/**
 * The mark a session on **another machine** wears, everywhere it is listed.
 *
 * A display and a stand: the ordinary "a computer" glyph, and deliberately not a
 * second terminal prompt. His words about the localhost list apply to every
 * remote row — *"list the remote machine's ports with the machine's icon beside
 * them, so remote and local are distinguishable at a glance"* — and the only
 * thing that makes that work is that the mark is of a **machine** rather than of
 * a kind of window. A remote session and a local one are the same kind of thing;
 * what differs is where it is running.
 *
 * Here rather than in the sidebar, because four screens draw it: the rail, the
 * New Session dialog's machine step, the localhost list, and the tab strip.
 */
export const MACHINE_ICON = 'M3 5h18v11H3zM8 20h8M12 16v4'

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
  /*
   * And not the shell's own window title, which is a machine and a path.
   *
   * `%n@%m: %~` is what the stock zsh and bash profiles write into the
   * terminal's title, so an untouched shell arrives here calling itself
   * `apple@Mac-mini: ~/Projects/terminaldeck`. Asad, on the rail:
   * *"it is showing the full machine and path, everything in the pill… it
   * should only show the name of the session."*
   *
   * It is refused rather than trimmed down to its last segment, because the
   * last segment is the folder — which is the very thing the heading above the
   * row already says, and the case the line above this one already turns into
   * `Session N`. So both roads lead to the same place and there is one rule
   * rather than two.
   *
   * Here rather than in the sidebar, because this is the one function that
   * answers what a session is called on screen and four surfaces read it. A
   * cleaner applied in the rail alone is how the rail and the strip come to
   * print two different names for one window — the defect `tabLabel` above was
   * written to end.
   */
  return title && title !== folderName && !isMachineAndPath(title)
    ? title
    : `Session ${index + 1}`
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
   * The copilot is called whatever it was named, wherever it is drawn.
   *
   * It is a session, so without this it would be numbered like one — and its
   * title is the name of its own folder, which is exactly the case
   * {@link sessionLabel} turns into `Session N`. So the pinned row in the rail
   * would say "Nova" and the pill three centimetres above it would say
   * "Session 4", for the same window. One thing wearing two names in two places
   * on one screen is the defect {@link tabIdentities} exists to prevent between
   * two *different* tabs; it would be worse coming from one.
   *
   * The name arrives on the tab. It is user data — somebody typed it into the
   * setup flow and it lives in the copilot's own instruction file — so this
   * function has no way to ask for it and does not try: `App.tsx` puts it on
   * `label` where the copilot's tab is built, and {@link COPILOT_NAME} is left
   * as the fallback for a copilot nobody has named and for a tab assembled
   * without one.
   *
   * Above the `kind` test rather than below it, because the answer does not
   * depend on what else is open — there is exactly one copilot.
   */
  if (tab.isCopilot) return tab.label || COPILOT_NAME
  if (tab.kind !== 'session') return tab.label
  /*
   * Siblings are in the same folder **on the same machine**.
   *
   * Without the second half, two machines that both have a `~/projects/site`
   * open would have their untitled sessions numbered as one run — "Session 1"
   * over here and "Session 2" over there, for two sessions that have nothing to
   * do with each other and no folder heading in common to explain the numbering.
   * `machine?.id` rather than the object, because these tabs are rebuilt on
   * every push and two identical machine objects are never the same reference.
   *
   * `server?.id` is the same rule for the other kind of elsewhere, and it is not
   * covered by the machine test: a shell on a server has no machine and no
   * folder, so without it every shell on every server — and every folderless
   * local shell — fell into one run and was numbered as though they were
   * siblings. Two servers each with one terminal open would have read "Session 1"
   * and "Session 2", under two different headings, with nothing on screen
   * explaining why the second one starts at two.
   */
  const siblings = tabs.filter(
    (other) =>
      other.kind === 'session' &&
      other.projectPath === tab.projectPath &&
      other.machine?.id === tab.machine?.id &&
      other.server?.id === tab.server?.id,
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
/**
 * The id this rung is allowed to print — the **session's**, never the tab's.
 *
 * A local tab's id is the session id, so the two are the same thing and this
 * changes nothing. A remote one is not: `machineTabId` joins a machine id and a
 * session id into `machine <ULID> <n>`, and `shortSessionId` cuts at the first
 * hyphen — which a ULID does not contain — so the qualifier printed for five
 * sessions on one paired machine was the whole twenty-six-character machine id,
 * five times, identically. It is on his own screen in the recording: three rows
 * under DESKTOP-DDGMNCV reading `machine XPUSZ55CRJPKSVQ`, which identifies the
 * computer he is already looking at the heading of and separates nothing.
 *
 * What does separate them is the far machine's own session id, which is what
 * that machine calls the session, is stable for its life, and is the same string
 * the Machines page and the far window print. `readMachineTabId` and
 * `readServerTabId` are the only two functions that know how those ids are
 * joined, so this asks them rather than parsing anything here.
 */
function qualifyingId(tab: WorkspaceTab): string {
  const remote = readMachineTabId(tab.id)
  if (remote) return remote.sessionId
  const server = readServerTabId(tab.id)
  if (server) return server.shellKey
  return tab.id
}

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
   * Then **where it is running**, when that is what differs.
   *
   * A rung that did not exist while everything in this window ran here. Two
   * shells opened on two different servers are both called *Session 1* — the
   * numbering counts siblings on the same machine, deliberately, so that a
   * second server does not start at three — and in the strip there is no heading
   * above either of them to say which is which. The folder cannot separate them
   * either: a shell on a server has no folder this app knows, so both fall to
   * the empty string and the rung above declines.
   *
   * What was left was the id rung, and on these ids it is close to useless. A
   * server tab's id begins `server ` followed by a UUID, and `shortSessionId`
   * cuts at the first hyphen — so the two heads are `server 3f2a1b0c` and
   * `server 9d8e4a55`, identical for the first eight characters, and the
   * qualifier a person would have read is `server 3`. That is an identifier for
   * a machine, not for a person.
   *
   * The name is. It is the word already on the rail heading and on the ✕'s
   * tooltip, so a pill qualified with it can be matched by eye to the row it
   * belongs to — which is the whole job of a qualifier.
   *
   * A tab running **here** gets nothing, and that is the right asymmetry rather
   * than an omission: this computer is the default place, it has no name in this
   * window's vocabulary, and *Session 1 · your Mac* beside *Session 1 · web-01*
   * would be labelling the ordinary case to explain the unusual one. It needs no
   * further qualifier either — the pair is already separated, because only one
   * of them carries a name.
   *
   * In the rail this rung never fires, and that is by construction rather than
   * by luck: `rowsFor` is called once per heading, so the run it is asked about
   * is one server's rows, whose `where` is one value. The same reason the folder
   * rung goes quiet inside a project.
   */
  const wheres = new Map<string, Set<string>>()
  tabs.forEach((tab, index) => {
    const set = wheres.get(labels[index]) ?? new Set<string>()
    set.add(tab.machine?.id ?? tab.server?.id ?? '')
    wheres.set(labels[index], set)
  })

  const placed = tabs.map((tab, index) => {
    if (qualified[index] !== null) return qualified[index]
    if ((byLabel.get(labels[index]) ?? 0) <= 1) return null
    if ((wheres.get(labels[index])?.size ?? 0) <= 1) return null
    return tab.machine?.name ?? tab.server?.name ?? null
  })

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
    `${labels[index]}${PAIR_SEP}${placed[index] ?? ''}${PAIR_SEP}${separator(index)}`
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
    tabs.filter((_, index) => needsId[index]).map((tab) => qualifyingId(tab)),
  )

  return tabs.map((tab, index) => {
    if (!needsId[index]) return placed[index]
    const id = shortSessionId(qualifyingId(tab)).slice(0, idChars)
    return placed[index] ? `${placed[index]} · ${id}` : id
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
 * Measured off the real thing rather than guessed, and re-measured when the tab
 * got wider. A strip tab is `--strip-tab-w` = 232px, and its icon, status dot,
 * two trailing controls and padding take about 80 of them, leaving ~152px of
 * 11px UI text. Rendered in `.harness/strip.html`, thirty characters of a
 * mixed-case title are where the CSS backstop starts clipping, so this is two
 * short of that — the same margin the first version of this number took — and
 * the middle cut stays the only cut, which is the point of making one.
 *
 * It was 22, fitted to a 220px cap that no longer exists. Left there it undoes
 * the width he chose: *"this one is the perfect size, the one with B1 and B2,
 * this tab"* is 232px because that is what a full tab needs, and a tab cutting
 * "Fix the parser in the reader" with 77px of empty space beside it is the
 * ragged row arriving from the other direction.
 *
 * Tabs compress to `--strip-tab-min` on a crowded bar, where a budget written
 * for the full width cannot hold and `text-overflow` takes over — that is the
 * documented failure mode of a generous budget, and it is the old behaviour
 * rather than an overflowing tab.
 */
export const STRIP_LABEL_BUDGET = 28

/**
 * What a strip tab's tooltip should say: the whole title, and the folder under
 * it when there is one.
 *
 * Two lines rather than one joined by a dash, because the title can itself be a
 * sentence with dashes in it. A browser page has no folder and gets one line —
 * an empty second line would read as a missing value.
 */
export function tabTooltip(tab: WorkspaceTab, label: string): string {
  /*
   * A remote session says which machine on its own line.
   *
   * It is the one fact that separates this pill from the identical-looking one
   * beside it, and the pill itself deliberately does not draw it — the whole
   * complaint being answered is that remote work looked like a foreign kind of
   * thing, so the tab wears exactly what a local tab wears. The tooltip is where
   * the difference is stated, which is the same trade the rail already makes
   * with the account caption: the identifying fact moves off the line and into
   * the hover rather than being dropped.
   *
   * The folder is the far machine's and is printed with it, because that pair —
   * folder on machine — is what a person means when they ask which session this
   * is. It is not passed to anything that opens a path; see the `heading` in
   * `App.tsx`, which for the same reason hands `FolderChip` a null.
   */
  if (tab.machine) {
    return tab.projectPath
      ? `${label}\n${tab.projectPath} on ${tab.machine.name}`
      : `${label}\non ${tab.machine.name}`
  }
  /*
   * And a terminal on a server says which server, for the same reason and on the
   * same line.
   *
   * It cannot be left to the qualifier. That only appears when two pills collide
   * — one terminal on one server produces no collision at all — so the ordinary
   * case is a pill that says *Session 1* and nothing else, over a shell on
   * somebody's live machine, sitting between two sessions running here. The rail
   * row already answers this in its own hover; the pill has to answer it too, or
   * the two surfaces disagree about how much they are willing to say.
   *
   * No folder, and its absence is deliberate: a shell starts wherever that
   * sign-in lands and this app has not asked where that is. Printing one would
   * be the first invented fact on a screen built not to have any.
   */
  if (tab.server) return `${label}\non ${tab.server.name}`
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

/* ------------------------------------------------ the drag that ate the ✕ -- */

/**
 * The marker that says "a press here is a press, not the start of a drag".
 *
 * Put on every control that lives *inside* a draggable row or tab: the ✕, the
 * promote toggle, the "why does this exist" link. Read by
 * {@link dragStartedOnControl} below, which is what actually refuses the drag.
 *
 * An attribute rather than a class, and rather than a list of selectors kept in
 * this file, because the question being asked is behavioural and not visual —
 * "may a drag begin from this element" — and a rule keyed on `.sb-row-action`
 * would silently stop protecting a button the day somebody restyled it.
 */
export const NO_DRAG_ATTR = 'data-no-drag'

/**
 * Did this drag begin on a control rather than on the row itself?
 *
 * ## The defect, measured
 *
 * Asad, 2026-08-17: *"The ✕ sometimes does not work."* It is not sometimes and
 * it is not the ✕ — it is every control inside a draggable container, and it
 * fails on every press where the hand moves a few pixels between button-down and
 * button-up. Reproduced in the harness through CDP, with the events logged:
 *
 *     pointerdown → mousedown → dragstart          (4px of movement)
 *     pointerdown → mousedown → mouseup → click    (0px of movement)
 *
 * A sidebar row is `<div draggable>` and a strip tab is `<div draggable>`, so
 * once the browser decides a press has become a drag it *cancels the click* —
 * no `mouseup`, no `click`, and the ✕ inside the row never hears about the press
 * at all. On a trackpad, where a tap almost always slides a little, that is most
 * presses. On the sidebar the press does nothing whatsoever; on the top strip it
 * is worse, because the drag completes four pixels away and silently *reorders*
 * the bar instead of removing the tab.
 *
 * ## Why the check is a hit-test and not `event.target`
 *
 * The obvious spelling — `event.target.closest('[data-no-drag]')` inside
 * `onDragStart` — does not work, and it was tried first and measured failing.
 * `dragstart` is dispatched at the **drag source**, which is the element
 * carrying `draggable`; the deepest node under the pointer is what `mousedown`
 * gets, not this. So the handler is always told "the row", whichever pixel of
 * the row was pressed.
 *
 * `draggable={false}` on the button does not work either, and was also measured:
 * the drag source is the ancestor, and an ancestor's drag begins from a press on
 * a non-draggable descendant exactly as it does from anywhere else.
 *
 * What is left is the press point, which `dragstart` does carry. Asking the
 * document what is under it answers the real question — *was the finger on a
 * control when it went down* — with no state to keep in step and no extra
 * handler to forget on the next row somebody adds.
 *
 * A null answer (a pointer outside the viewport, a document that cannot
 * hit-test) allows the drag, which is the behaviour that existed before this and
 * is the safe way to fail: the worst case is the old bug, not a rail whose rows
 * cannot be dragged at all.
 *
 * `doc` is a parameter so this is testable in a project whose test run has no
 * DOM — `document` is the default and is what every caller passes by omission.
 */
export interface HitTestable {
  elementFromPoint(x: number, y: number): { closest(selector: string): unknown } | null
}

export function dragStartedOnControl(
  x: number,
  y: number,
  doc: HitTestable | null = typeof document === 'undefined' ? null : (document as unknown as HitTestable),
): boolean {
  if (!doc) return false
  const under = doc.elementFromPoint(x, y)
  if (!under || typeof under.closest !== 'function') return false
  return under.closest(`[${NO_DRAG_ATTR}]`) !== null
}
